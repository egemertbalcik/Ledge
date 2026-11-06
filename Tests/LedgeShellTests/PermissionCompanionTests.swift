import AppKit
import LedgeCore
import LedgeUI
import SwiftUI
import Testing

@testable import LedgeShell

/// The panel follows the model's handoff and nothing else.
@MainActor
@Suite("The panel during a handoff")
struct PermissionCompanionTests {

    private static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    nonisolated private static let window = CGRect(x: 300, y: 200, width: 715, height: 600)

    private final class FakeSurface: PermissionCompanionSurface {
        var isShown = false
        var contentHeight: CGFloat = 400
        var said: [PermissionCompanionContent] = []
        var shownAt: CGRect?
        var hides = 0
        var announced: [String] = []
        func say(_ content: PermissionCompanionContent) { said.append(content) }
        func show(at frame: CGRect) { isShown = true; shownAt = frame }
        func hide() { if isShown { hides += 1 }; isShown = false }
        func announce(_ text: String) { announced.append(text) }
    }

    /// Everything from outside the app, under the test's control.
    private final class World {
        var front: PermissionCompanionDock.Front = .systemSettings
        var window: CGRect? = PermissionCompanionTests.window
        var reads = 0
        var holdReleased = false
        var staysUp = false
    }

    private func make() -> (PermissionCompanion, SettingsModel, FakeSurface, World) {
        let model = SettingsModel()
        model.permissions = PermissionKind.allCases.map { PermissionRow(kind: $0, status: .notDetermined) }
        let surface = FakeSurface()
        let world = World()
        let companion = PermissionCompanion(
            model: model,
            surface: surface,
            read: { height in
                world.reads += 1
                return PermissionCompanionDock.Reading(
                    front: world.front,
                    window: world.window,
                    visible: world.window == nil ? nil : Self.screen,
                    panelHeight: height
                )
            },
            sleep: { duration in
                // The arrival hold is the only pause that is not a poll: it
                // stays until the test says it is over.
                if duration == .seconds(2.8) {
                    while !world.holdReleased, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(1))
                    }
                } else {
                    try? await Task.sleep(for: .milliseconds(1))
                }
            },
            arrivalHold: { 2.8 },
            arrivalStaysUp: { world.staysUp }
        )
        return (companion, model, surface, world)
    }

    /// Polled against a deadline, so something that never happens is a
    /// failure rather than a hung run.
    private func arrive(
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("never happened: \(what)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Long enough for a poll that should not be happening to have happened.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func grant(_ model: SettingsModel, _ kind: PermissionKind = .accessibility) {
        model.permissions = PermissionKind.allCases.map {
            PermissionRow(kind: $0, status: $0 == kind ? .granted : .notDetermined)
        }
    }

    @Test("With no handoff nothing is read and nothing is shown")
    func noHandoffNoPolling() async {
        let (companion, _, surface, world) = make()
        companion.start()
        await settle()
        #expect(world.reads == 0)
        #expect(!surface.isShown)
        companion.stop()
    }

    @Test("A press puts it beside System Settings, saying what it is waiting for")
    func opens() async {
        let (companion, model, surface, _) = make()
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        #expect(surface.said.last == .waiting(PermissionHandoff(kind: .accessibility)))
        #expect(surface.shownAt?.minX == Self.window.maxX + PermissionCompanionDock.gap)
        #expect(surface.shownAt?.maxY == Self.window.maxY)
        companion.stop()
    }

    /// Ledge's own window is in front at the press, and macOS's one-time
    /// message may be up. It waits for System Settings.
    @Test("Not until System Settings is in front")
    func waitsForSystemSettings() async {
        let (companion, model, surface, world) = make()
        world.front = .passing
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("reading") { world.reads > 3 }
        #expect(!surface.isShown)
        world.front = .systemSettings
        await arrive("shown") { surface.isShown }
        companion.stop()
    }

    @Test("Ledge coming back to the front closes it and stops the polling")
    func cameBack() async {
        let (companion, model, surface, world) = make()
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        model.cameBackFromSystemSettings()
        #expect(model.handoff?.phase == .back)
        await arrive("hidden") { !surface.isShown }
        let reads = world.reads
        await settle()
        #expect(world.reads == reads)
        companion.stop()
    }

    @Test("A second press after coming back opens it again")
    func opensAgain() async {
        let (companion, model, surface, _) = make()
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        model.cameBackFromSystemSettings()
        await arrive("hidden") { !surface.isShown }
        model.beganHandoff(for: .accessibility)
        await arrive("shown again") { surface.isShown }
        companion.stop()
    }

    @Test("Stop Waiting closes it without claiming anything")
    func stopWaiting() async {
        let (companion, model, surface, world) = make()
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        model.endedHandoff()
        await arrive("hidden") { !surface.isShown }
        #expect(surface.said.allSatisfy { if case .arrived = $0 { false } else { true } })
        #expect(surface.announced.isEmpty)
        let reads = world.reads
        await settle()
        #expect(world.reads == reads)
        companion.stop()
    }

    @Test("A refusal closes it without claiming anything")
    func refusal() async {
        let (companion, model, surface, _) = make()
        companion.start()
        model.beganHandoff(for: .calendars)
        await arrive("shown") { surface.isShown }
        model.permissions = PermissionKind.allCases.map {
            PermissionRow(kind: $0, status: $0 == .calendars ? .denied : .notDetermined)
        }
        model.endedHandoff()
        await arrive("hidden") { !surface.isShown }
        #expect(surface.announced.isEmpty)
        companion.stop()
    }

    @Test("A grant says it is on, for the hold, and then it goes")
    func grantHolds() async {
        let (companion, model, surface, world) = make()
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        grant(model)
        model.endedHandoff()
        await arrive("says it is on") { surface.said.last == .arrived(.accessibility) }
        #expect(surface.announced == [PermissionGuideCopy.arrivedTitle("Accessibility")])
        await settle()
        #expect(surface.isShown)
        world.holdReleased = true
        await arrive("gone") { !surface.isShown }
        let reads = world.reads
        await settle()
        #expect(world.reads == reads, "still polling after it went")
        companion.stop()
    }

    /// With the asking window waiting behind System Settings, this is the only
    /// way back to it on screen.
    @Test("With the asking window still owed the front, it stays past the hold")
    func staysWhileOwed() async {
        let (companion, model, surface, world) = make()
        world.staysUp = true
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        grant(model)
        model.endedHandoff()
        await arrive("says it is on") { surface.said.last == .arrived(.accessibility) }
        world.holdReleased = true
        await settle()
        #expect(surface.isShown)
        companion.endArrival()
        #expect(!surface.isShown)
        let reads = world.reads
        await settle()
        #expect(world.reads == reads, "still polling after it was ended")
        companion.stop()
    }

    @Test("While it says it is on it still follows the window")
    func followsDuringArrival() async {
        let (companion, model, surface, world) = make()
        world.staysUp = true
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        grant(model)
        model.endedHandoff()
        await arrive("says it is on") { surface.said.last == .arrived(.accessibility) }
        let moved = Self.window.offsetBy(dx: 30, dy: 0)
        world.window = moved
        await arrive("beside the moved window") { surface.shownAt?.minX == moved.maxX + PermissionCompanionDock.gap }
        companion.stop()
    }

    @Test("Ending an arrival that is not happening does nothing")
    func endArrivalWhenWaiting() async {
        let (companion, model, surface, _) = make()
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        companion.endArrival()
        #expect(surface.isShown)
        companion.stop()
    }

    @Test("Whether it is up is what the notch asks before saying the same thing")
    func isUp() async {
        let (companion, model, surface, _) = make()
        companion.start()
        #expect(!companion.isUp)
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        #expect(companion.isUp)
        companion.stop()
        #expect(!companion.isUp)
    }

    /// The notch says it either way. Opening a panel just to say it would be
    /// the panel opening on its own.
    @Test("A grant while it was not up does not bring it up")
    func grantWhileHidden() async {
        let (companion, model, surface, world) = make()
        world.front = .regularApp
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("reading") { world.reads > 3 }
        grant(model)
        model.endedHandoff()
        await settle()
        #expect(!surface.isShown)
        #expect(surface.announced.isEmpty)
        companion.stop()
    }

    @Test("A new press during the hold takes over, and the old hold does not close it")
    func pressDuringHold() async {
        let (companion, model, surface, world) = make()
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        grant(model)
        model.endedHandoff()
        await arrive("says it is on") { surface.said.last == .arrived(.accessibility) }
        model.beganHandoff(for: .calendars)
        await arrive("waiting again") { surface.said.last == .waiting(PermissionHandoff(kind: .calendars)) }
        // Counted, not just looked at afterwards: polling would put it back up
        // within a reading, and that blink is the bug.
        let hides = surface.hides
        world.holdReleased = true
        await settle()
        #expect(surface.isShown)
        #expect(surface.hides == hides)
        companion.stop()
    }

    @Test("A second handoff replacing the first changes what it says, and stays up")
    func replaced() async {
        let (companion, model, surface, _) = make()
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        let hides = surface.hides
        model.beganHandoff(for: .calendars)
        await arrive("says calendars") { surface.said.last == .waiting(PermissionHandoff(kind: .calendars)) }
        await settle()
        #expect(surface.isShown)
        #expect(surface.hides == hides)
        companion.stop()
    }

    @Test("Stopping takes it down and stops everything")
    func stops() async {
        let (companion, model, surface, world) = make()
        companion.start()
        model.beganHandoff(for: .accessibility)
        await arrive("shown") { surface.isShown }
        companion.stop()
        #expect(!surface.isShown)
        let reads = world.reads
        await settle()
        #expect(world.reads == reads)
        // And a handoff after that is nobody's business.
        model.endedHandoff()
        model.beganHandoff(for: .accessibility)
        await settle()
        #expect(world.reads == reads)
        #expect(!surface.isShown)
    }

    // MARK: - The real window

    /// Ledge treats becoming active as somebody coming back from System
    /// Settings, so a window that activates would end the wait on its first
    /// click. This is the one that can break everything.
    @Test("The panel can never activate Ledge or take the keyboard")
    func panelIsNonActivating() {
        let panel = PermissionCompanionPanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.isMovable)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
    }

    @Test("Every click in the panel is a first click, and the tile takes it there only")
    func firstMouse() {
        let hosting = NotchHostingView(rootView: AnyView(EmptyView()))
        #expect(hosting.acceptsFirstMouse(for: nil))
        let url = URL(fileURLWithPath: "/Applications/Ledge.app")
        let inPanel = AppTileView(url: url, name: "Ledge", onDragEnded: { _ in }, onCopyLocation: {}, worksWithoutKey: true)
        #expect(inPanel.acceptsFirstMouse(for: nil))
        let inline = AppTileView(url: url, name: "Ledge", onDragEnded: { _ in }, onCopyLocation: {})
        #expect(!inline.acceptsFirstMouse(for: nil))
    }

    @Test("Nothing about a window is made until there is something to say")
    func lazyWindow() {
        let window = PermissionCompanionWindow(hidesFromCapture: { true }, makeContent: { _ in AnyView(EmptyView()) })
        #expect(window.contentHeight == 0)
        window.hide()
        #expect(!window.isShown)
    }

    // MARK: - Reading System Settings

    @Test("Who counts as in front", arguments: [
        ("com.apple.systempreferences", true, false, PermissionCompanionDock.Front.systemSettings),
        ("com.apple.Safari", true, false, .regularApp),
        ("com.apple.SecurityAgent", false, false, .passing),
        ("com.apple.universalaccessAuthWarn", false, false, .passing),
        ("com.egemert.ledge", false, true, .passing),
    ])
    func classify(id: String, regular: Bool, isSelf: Bool, front: PermissionCompanionDock.Front) {
        #expect(SystemSettingsWindow.classify(bundleIdentifier: id, isRegular: regular, isSelf: isSelf) == front)
    }

    @Test("The window server's frame is turned the right way up")
    func coordinates() {
        let frame = SystemSettingsWindow.appKitFrame(
            fromWindowServer: CGRect(x: 100, y: 50, width: 715, height: 600), primaryHeight: 1117
        )
        #expect(frame == CGRect(x: 100, y: 467, width: 715, height: 600))
    }

    // MARK: - Wiring

    @Test("The coordinator starts it with the app and stops it with the app")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/LedgeShell/Coordinator/LedgeCoordinator.swift"), encoding: .utf8
        )
        #expect(source.contains("permissionCompanion.start()"))
        #expect(source.contains("permissionCompanion.stop()"))
        // `PermissionFlowTests` runs the decisions. These are the two facts it
        // has to be handed: the real front, and a diff's gain reaching it.
        #expect(source.contains("systemSettingsHoldsTheFront: { SystemSettingsWindow.holdsTheFront() }"))
        let granted = try #require(source.range(of: "private func permissionGranted("))
        #expect(source[granted.upperBound...].range(of: "permissionFlow.grantArrived(kind)") != nil)
        // The inline tile keeps its old behaviour; only the panel's takes first clicks.
        #expect(source.contains("appTile: { [weak self] in self?.appTile(worksWithoutKey: false) }"))
        #expect(source.contains("tile: self.appTile(worksWithoutKey: true)"))
    }
}
