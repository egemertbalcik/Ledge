import CoreGraphics
import Testing

@testable import LedgeCore

/// Where the panel sits beside System Settings, and when it gives way.
@Suite("The panel beside System Settings")
struct PermissionCompanionDockTests {

    private typealias Dock = PermissionCompanionDock

    private static let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    private static let window = CGRect(x: 300, y: 200, width: 715, height: 600)

    private func reading(
        front: Dock.Front = .systemSettings,
        window: CGRect? = Self.window,
        height: CGFloat = 400
    ) -> Dock.Reading {
        Dock.Reading(front: front, window: window, visible: window == nil ? nil : Self.screen, panelHeight: height)
    }

    /// A dock that has already put the panel up.
    private func upDock() -> Dock {
        var dock = Dock()
        _ = dock.read(reading())
        _ = dock.read(reading())
        return dock
    }

    // MARK: - Placing it

    @Test("To the right first, with the gap and the tops aligned")
    func rightFirst() throws {
        let frame = try #require(Dock.place(window: Self.window, visible: Self.screen, panelHeight: 400))
        #expect(frame.minX == Self.window.maxX + Dock.gap)
        #expect(frame.maxY == Self.window.maxY)
        #expect(frame.width == Dock.panelWidth)
        #expect(frame.height == 400)
    }

    @Test("To the left when the right side has no room")
    func leftSecond() throws {
        let window = CGRect(x: 1000, y: 200, width: 715, height: 600)
        let frame = try #require(Dock.place(window: window, visible: Self.screen, panelHeight: 400))
        #expect(frame.maxX == window.minX - Dock.gap)
        #expect(frame.maxY == window.maxY)
    }

    /// The list is on the right of System Settings. Only the sidebar, on the
    /// left, may ever be covered.
    @Test("On the left it may cover the sidebar by a little, against the screen edge")
    func sidebarOverlap() throws {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 1080)
        let window = CGRect(x: 270, y: 200, width: 715, height: 600)
        let frame = try #require(Dock.place(window: window, visible: visible, panelHeight: 400))
        #expect(frame.minX == visible.minX)
        #expect(frame.maxX - window.minX <= Dock.sidebarOverlap)
        #expect(frame.maxX > window.minX)
    }

    @Test("No room on either side means no panel, however close")
    func noRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 1080)
        // One point more overlap than the sidebar allows.
        let window = CGRect(x: Dock.panelWidth - Dock.sidebarOverlap - 1, y: 200, width: 715, height: 600)
        #expect(Dock.place(window: window, visible: visible, panelHeight: 400) == nil)
    }

    @Test("A panel taller than the screen is not shown")
    func tooTall() {
        #expect(Dock.place(window: Self.window, visible: Self.screen, panelHeight: 1081) == nil)
    }

    @Test("A low window pulls the panel up onto the screen rather than off the bottom")
    func lowWindow() throws {
        let window = CGRect(x: 300, y: 0, width: 715, height: 200)
        let frame = try #require(Dock.place(window: window, visible: Self.screen, panelHeight: 400))
        #expect(frame.minY == Self.screen.minY)
    }

    @Test("Never above the top of the usable screen")
    func highWindow() throws {
        let window = CGRect(x: 300, y: 600, width: 715, height: 600)
        let frame = try #require(Dock.place(window: window, visible: Self.screen, panelHeight: 400))
        #expect(frame.maxY == Self.screen.maxY)
    }

    // MARK: - When it shows

    /// A window that opens after the press is often still opening.
    @Test("A window that opens after the press has to be seen in the same place twice")
    func coldOpenWaitsForStillness() {
        var dock = Dock()
        #expect(dock.read(reading(window: nil)) == .hidden)
        #expect(dock.read(reading()) == .hidden)
        guard case .shown = dock.read(reading()) else {
            Issue.record("still hidden with the window sitting still")
            return
        }
    }

    /// So the panel arrives with System Settings, not after it.
    @Test("A window already open at the press has nothing to wait for")
    func warmOpenShowsAtOnce() {
        var dock = Dock()
        guard case .shown = dock.read(reading()) else {
            Issue.record("waited for a window that was already there")
            return
        }
    }

    /// Ledge's own window is usually in front at the press.
    @Test("A window already open still waits for System Settings to be in front")
    func warmOpenWaitsForTheFront() {
        var dock = Dock()
        #expect(dock.read(reading(front: .passing)) == .hidden)
        guard case .shown = dock.read(reading()) else {
            Issue.record("hidden with System Settings in front and its window still")
            return
        }
    }

    @Test("Moving the window hides the panel until it stops, then it comes back beside it")
    func neverChases() {
        var dock = upDock()
        let moved = Self.window.offsetBy(dx: 40, dy: 0)
        #expect(dock.read(reading(window: moved)) == .hidden)
        let expected = Dock.place(window: moved, visible: Self.screen, panelHeight: 400)
        #expect(dock.read(reading(window: moved)) == expected.map(Dock.Answer.shown))
    }

    @Test("An app taking the front holds for one reading, then the panel gives way")
    func debouncesLeaving() {
        var dock = upDock()
        let up = dock.answer
        #expect(up != .hidden)
        #expect(dock.read(reading(front: .regularApp)) == up)
        #expect(dock.read(reading(front: .regularApp)) == .hidden)
    }

    @Test("One reading away and back does not blink it or start the count over wrongly")
    func aBlipIsForgotten() {
        var dock = upDock()
        let up = dock.answer
        #expect(dock.read(reading(front: .regularApp)) == up)
        #expect(dock.read(reading()) == up)
        #expect(dock.read(reading(front: .regularApp)) == up)
    }

    @Test("Going away and coming back brings it back")
    func comesBack() {
        var dock = upDock()
        let up = dock.answer
        _ = dock.read(reading(front: .regularApp))
        #expect(dock.read(reading(front: .regularApp)) == .hidden)
        #expect(dock.read(reading()) == up)
    }

    /// Touch ID, the password dialog and macOS's one-time message.
    @Test("Something passing through keeps a panel that is up")
    func passingKeeps() {
        var dock = upDock()
        let up = dock.answer
        for _ in 0..<8 { #expect(dock.read(reading(front: .passing)) == up) }
    }

    @Test("Something passing through never brings one up")
    func passingDoesNotOpen() {
        var dock = Dock()
        for _ in 0..<8 { #expect(dock.read(reading(front: .passing)) == .hidden) }
    }

    @Test("An app in front never brings one up")
    func regularDoesNotOpen() {
        var dock = Dock()
        for _ in 0..<8 { #expect(dock.read(reading(front: .regularApp)) == .hidden) }
    }

    @Test("No window on screen hides it, and it waits for stillness again when one returns")
    func windowGone() {
        var dock = upDock()
        let up = dock.answer
        #expect(dock.read(reading(window: nil)) == .hidden)
        // Only the very first reading gets the benefit of the doubt.
        #expect(dock.read(reading()) == .hidden)
        #expect(dock.read(reading()) == up)
    }

    /// A drag that missed adds a line of text, and the panel grows downwards.
    @Test("Growing the content keeps the top where it was")
    func growsDownwards() {
        var dock = upDock()
        guard case .shown(let before) = dock.answer,
              case .shown(let after) = dock.read(reading(height: 460))
        else {
            Issue.record("the panel went away")
            return
        }
        #expect(after.maxY == before.maxY)
        #expect(after.height == 460)
    }
}

/// What a grant does to the window that asked.
@Suite("A grant arriving")
struct GrantArrivalTests {

    private func arrival(
        kind: PermissionKind? = .accessibility,
        press: PermissionKind? = .accessibility,
        watching: Bool = true,
        atSettings: Bool = false
    ) -> GrantArrival {
        GrantArrival(kind: kind, pressKind: press, isWatching: watching, isStillAtSystemSettings: atSettings)
    }

    /// The jolt the whole change is for. Nothing else may produce a raise here.
    @Test("Somebody still at System Settings is left there, and the window waits")
    func stillThere() {
        #expect(arrival(atSettings: true) == .owe)
    }

    @Test("Somebody who has left gets the window back")
    func left() {
        #expect(arrival(atSettings: false) == .raise)
    }

    /// A click on the notch is asked for, wherever they are.
    @Test("Clicking the notch to go back is honoured even from System Settings", arguments: [true, false])
    func notchClick(atSettings: Bool) {
        #expect(arrival(kind: nil, atSettings: atSettings) == .raise)
    }

    @Test("A different permission's answer moves nothing", arguments: [true, false])
    func other(atSettings: Bool) {
        #expect(arrival(kind: .calendars, atSettings: atSettings) == .nothing)
    }

    @Test("With no press out, or no watch running, nothing moves", arguments: [true, false])
    func noPress(atSettings: Bool) {
        #expect(arrival(press: nil, atSettings: atSettings) == .nothing)
        #expect(arrival(watching: false, atSettings: atSettings) == .nothing)
        #expect(arrival(kind: nil, watching: false, atSettings: atSettings) == .nothing)
    }
}
