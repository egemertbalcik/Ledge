import AppKit
import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// The readout as a control: real mouse events through the real overlay, in a
/// window nobody can see. What decides a click here is SwiftUI's arbitration
/// between the row's gestures and the shape's own tap, and that can only be
/// found out by clicking.
@Suite("Using the readout with the pointer", .serialized)
@MainActor
struct HUDRowControlTests {

    private static let geometry = NotchGeometry(
        screenSize: CGSize(width: 1512, height: 982),
        notchSize: CGSize(width: 185, height: 32),
        notchCenterX: 756,
        isHardwareNotch: true
    )

    /// The panel takes first clicks in the shipping app, because it never
    /// becomes key. See `LedgePanel`.
    private final class FirstMouseHost<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// One overlay in a window, and everything it asked for.
    @MainActor
    private final class Rig {
        let presentation = NotchPresentation()
        let preferences = Preferences(store: MemoryPreferenceStore())
        let size = NotchLayout.panelSize(for: HUDRowControlTests.geometry)
        var window: NSWindow!
        var levels: [(kind: HUDReadout.Kind, level: Double)] = []
        var mutes = 0
        var drags: [Bool] = []
        var taps = 0

        init(phase: NotchPhase, readout: HUDReadout?) {
            presentation.phase = phase
            presentation.hud = readout
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.prohibited)
            window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let host = FirstMouseHost(rootView: NotchOverlayView(
                geometry: HUDRowControlTests.geometry,
                preferences: preferences,
                presentation: presentation,
                onTap: { [unowned self] in taps += 1 },
                onHUDAdjust: { [unowned self] kind, level in levels.append((kind, level)) },
                onHUDToggleMute: { [unowned self] in mutes += 1 },
                onHUDRowDragging: { [unowned self] dragging in drags.append(dragging) }
            ).frame(width: size.width, height: size.height))
            host.sizingOptions = []
            window.contentView = host
            window.setContentSize(size)
            window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
            window.orderFrontRegardless()
            settle(0.5)
        }

        func close() {
            window.orderOut(nil)
            window.close()
        }

        func settle(_ seconds: TimeInterval = 0.05) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        var metrics: HUDRowMetrics {
            let body = presentation.layout(
                preferences: preferences, geometry: HUDRowControlTests.geometry, phase: .hud
            ).bodySize.width
            return HUDRowMetrics(
                geometry: HUDRowControlTests.geometry, bodyWidth: body,
                contentOffset: preferences.hudContentOffset
            )
        }

        /// A point in the row, as the window counts it: the row hangs from the
        /// cutout, in the middle of the panel, and AppKit counts from the bottom.
        func inRow(x: CGFloat, y: CGFloat? = nil) -> NSPoint {
            let left = (size.width - metrics.bodyWidth) / 2
            let top = HUDRowControlTests.geometry.notchSize.height + (y ?? metrics.centreY)
            return NSPoint(x: left + x, y: size.height - top)
        }

        func onBar(_ fraction: CGFloat) -> NSPoint {
            inRow(x: metrics.barLeading + metrics.barWidth * fraction)
        }

        var onGlyph: NSPoint { inRow(x: metrics.barLeading / 2) }
        var onCutout: NSPoint { NSPoint(x: size.width / 2, y: size.height - 10) }

        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            ) else { return }
            window.sendEvent(event)
            settle()
        }

        func click(_ point: NSPoint) {
            send(.leftMouseDown, point)
            send(.leftMouseUp, point)
        }

        /// Everything in the row's own area, as pixels.
        func picture() -> Data? {
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.tiffRepresentation
        }
    }

    // MARK: - The bar

    @Test("Pressing on the bar sets the level there, and dragging follows", arguments: [
        HUDReadout.Kind.volume, .brightness,
    ])
    func pressAndDrag(kind: HUDReadout.Kind) throws {
        let rig = Rig(phase: .hud, readout: HUDReadout(kind: kind, level: 0.25))
        defer { rig.close() }

        rig.send(.leftMouseDown, rig.onBar(0.5))
        let pressed = try #require(rig.levels.last, "the press never reached the bar")
        #expect(pressed.kind == kind)
        #expect(abs(pressed.level - 0.5) < 0.02)
        #expect(rig.drags == [true])

        rig.send(.leftMouseDragged, rig.onBar(0.75))
        #expect(abs(try #require(rig.levels.last).level - 0.75) < 0.02)

        rig.send(.leftMouseUp, rig.onBar(0.75))
        #expect(rig.drags == [true, false])
        #expect(rig.taps == 0, "a press on the bar must not also pin a card")
        #expect(rig.mutes == 0)
    }

    @Test("A drag past either end, or off the row altogether, is that end")
    func dragPastTheEnds() throws {
        let rig = Rig(phase: .hud, readout: HUDReadout(kind: .volume, level: 0.5))
        defer { rig.close() }

        rig.send(.leftMouseDown, rig.onBar(0.5))
        rig.send(.leftMouseDragged, NSPoint(x: rig.size.width + 300, y: 40))
        #expect(try #require(rig.levels.last).level == 1)
        rig.send(.leftMouseDragged, NSPoint(x: -300, y: 40))
        #expect(try #require(rig.levels.last).level == 0)
        rig.send(.leftMouseUp, NSPoint(x: -300, y: 40))
        #expect(rig.drags == [true, false])
    }

    @Test("The whole height of the row answers, not the five points of the bar")
    func rowHeightIsTheTarget() throws {
        let rig = Rig(phase: .hud, readout: HUDReadout(kind: .volume, level: 0.5))
        defer { rig.close() }
        let x = rig.metrics.barLeading + rig.metrics.barWidth * 0.5
        rig.click(rig.inRow(x: x, y: 1))
        #expect(rig.levels.count == 1, "just under the cutout")
        rig.click(rig.inRow(x: x, y: rig.metrics.height - 8))
        #expect(rig.levels.count == 2, "near the bottom of the shape")
        #expect(rig.taps == 0)
    }

    /// A click aimed at a tab under the notch's corner must not turn the
    /// sound all the way up. The click just inside the end is the fixture's
    /// proof that the row was taking clicks at all.
    @Test("A press past the bar's end does nothing")
    func marginPastTheBar() throws {
        let rig = Rig(phase: .hud, readout: HUDReadout(kind: .volume, level: 0.5))
        defer { rig.close() }
        rig.click(rig.inRow(x: rig.metrics.barLeading + rig.metrics.barWidth - 2))
        #expect(rig.levels.count == 1)

        rig.send(.leftMouseDown, rig.inRow(x: rig.metrics.barLeading + rig.metrics.barWidth + 4))
        rig.send(.leftMouseDragged, rig.onBar(0.5))
        rig.send(.leftMouseUp, rig.onBar(0.5))
        #expect(rig.levels.count == 1, "a drag can't start out there either")
        #expect(rig.drags == [true, false])
        #expect(rig.taps == 0)
    }

    // MARK: - The speaker

    @Test("Clicking the speaker mutes, once, and sets no level")
    func speakerMutes() {
        let rig = Rig(phase: .hud, readout: HUDReadout(kind: .volume, level: 0.5))
        defer { rig.close() }
        rig.click(rig.onGlyph)
        #expect(rig.mutes == 1)
        #expect(rig.levels.isEmpty)
        #expect(rig.drags.isEmpty)
        #expect(rig.taps == 0, "a click on the speaker must not also pin a card")
    }

    @Test("The sun is not a button, and a click on it does nothing at all")
    func sunDoesNothing() {
        let rig = Rig(phase: .hud, readout: HUDReadout(kind: .brightness, level: 0.5))
        defer { rig.close() }
        rig.click(rig.onGlyph)
        #expect(rig.mutes == 0)
        #expect(rig.levels.isEmpty)
        #expect(rig.taps == 0)
    }

    @Test("A level nothing can write takes no drag")
    func keyboardTakesNothing() {
        let rig = Rig(phase: .hud, readout: HUDReadout(kind: .keyboardBacklight, level: 0.5))
        defer { rig.close() }
        rig.click(rig.onBar(0.5))
        rig.click(rig.onGlyph)
        #expect(rig.levels.isEmpty)
        #expect(rig.mutes == 0)
        #expect(rig.drags.isEmpty)
        #expect(rig.taps == 0)
    }

    // MARK: - The shape around it

    /// The fixture's own proof: the same click on the same place does reach
    /// the tap when no readout is up, so the zero above is not a click that
    /// never arrived.
    @Test("A click on the cutout pins a card, except during a readout")
    func cutoutClick() {
        let resting = Rig(phase: .idle, readout: nil)
        defer { resting.close() }
        resting.click(resting.onCutout)
        #expect(resting.taps == 1)

        let readout = Rig(phase: .hud, readout: HUDReadout(kind: .volume, level: 0.5))
        defer { readout.close() }
        readout.click(readout.onCutout)
        #expect(readout.taps == 0)
    }

    /// The whole request: hovering changes nothing that can be seen.
    @Test("Hovering leaves every pixel where it was", arguments: [
        HUDReadout(kind: .volume, level: 0.5),
        HUDReadout(kind: .volume, level: 0.5, isMuted: true),
        HUDReadout(kind: .brightness, level: 0.62),
    ])
    func hoverChangesNothing(readout: HUDReadout) throws {
        let rig = Rig(phase: .hud, readout: readout)
        defer { rig.close() }
        rig.presentation.isHovering = false
        rig.settle(0.5)
        let away = try #require(rig.picture())

        rig.presentation.isHovering = true
        rig.settle(0.5)
        #expect(rig.presentation.isHovering)
        #expect(try #require(rig.picture()) == away)

        // The pictures have something in them.
        let image = try #require(NSBitmapImageRep(data: away))
        let point = rig.onBar(0)
        let lit = (0..<Int(rig.size.width)).contains { x in
            let colour = image.colorAt(x: x, y: Int(rig.size.height - point.y))
            return (colour?.brightnessComponent ?? 0) > 0.5
        }
        #expect(lit, "the row was not drawn")
    }

    // MARK: - The unfilled part of the bar

    /// How bright the middle of one segment is, on the row as drawn.
    private func brightness(ofSegment index: Int, in rig: Rig) throws -> CGFloat {
        let metrics = rig.metrics
        let view = try #require(rig.window.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let segments = HUDSegments.rects(
            in: CGSize(width: metrics.barWidth, height: metrics.barHeight), gap: metrics.segmentGap
        )
        let x = metrics.barLeading + segments[index].midX
        let point = rig.inRow(x: x, y: metrics.barTop + metrics.barHeight / 2)
        // AppKit counts from the bottom and the bitmap from the top.
        let colour = try #require(rep.colorAt(
            x: Int(point.x * scale), y: Int((view.bounds.height - point.y) * scale)
        )?.usingColorSpace(.deviceRGB))
        return colour.brightnessComponent
    }

    /// The owner saw the unfilled part vanish for a while with the filled part
    /// still there, and the cause wasn't found. So this looks at the pixels
    /// after everything that happens to the row, including what interrupts it.
    @Test("The unfilled part of the bar is there whatever has just happened", arguments: [
        HUDReadout.Kind.volume, .brightness,
    ])
    func trackStaysDrawn(kind: HUDReadout.Kind) throws {
        let rig = Rig(phase: .hud, readout: HUDReadout(kind: kind, level: 0.25))
        defer { rig.close() }
        let resting = HUDReadout(kind: kind, level: 0.25)

        func check(_ moment: Comment, muted: Bool = false) throws {
            rig.settle(0.4)
            let track = try brightness(ofSegment: 12, in: rig)
            #expect(track > 0.2 && track < 0.6, "\(moment): unfilled segment at \(track)")
            if !muted {
                let filled = try brightness(ofSegment: 1, in: rig)
                #expect(filled > 0.9, "\(moment): filled segment at \(filled)")
            }
        }

        try check("on arrival")

        for step in 0..<8 {
            rig.presentation.hud = HUDReadout(kind: kind, level: 0.25 + Double(step) / 16)
            rig.settle(0.02)
        }
        rig.presentation.hud = resting
        try check("after a held key")

        rig.send(.leftMouseDown, rig.onBar(0.25))
        rig.presentation.hud = resting
        rig.settle(0.1)
        let mid = try brightness(ofSegment: 12, in: rig)
        #expect(mid > 0.2 && mid < 0.6, "during a press: unfilled segment at \(mid)")
        rig.send(.leftMouseDragged, rig.onBar(0.6))
        rig.send(.leftMouseUp, rig.onBar(0.6))
        rig.presentation.hud = resting
        try check("after a drag")

        rig.presentation.isHovering = true
        try check("hovered")
        rig.presentation.isHovering = false
        try check("after the pointer left")

        if kind == .volume {
            rig.presentation.hud = HUDReadout(kind: kind, level: 0.25, isMuted: true)
            try check("muted", muted: true)
            rig.presentation.hud = resting
            try check("unmuted")
        }

        // Back in the middle of its fade out, as a repeat press does.
        rig.presentation.phase = .idle
        rig.settle(0.03)
        rig.presentation.phase = .hud
        try check("back in the middle of leaving")

        // And out again in the middle of arriving.
        rig.presentation.phase = .idle
        rig.settle(0.4)
        rig.presentation.phase = .hud
        rig.settle(0.03)
        rig.presentation.phase = .idle
        rig.settle(0.03)
        rig.presentation.phase = .hud
        try check("after arriving twice")
    }

    // MARK: - A drag's own life

    /// A row of its own, so the test can change what it reads and whether it
    /// is there at all, with the row's state surviving as it does in the app.
    private struct Holder: View {
        let readout: HUDReadout
        let isThere: Bool
        let metrics: HUDRowMetrics
        let actions: HUDRowActions

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                if isThere {
                    HUDRowView(readout: readout, metrics: metrics, actions: actions)
                }
            }
        }
    }

    @MainActor
    private final class Solo {
        let metrics = HUDRowMetrics(geometry: HUDRowControlTests.geometry, bodyWidth: 281)
        var window: NSWindow!
        var host: FirstMouseHost<Holder>!
        var levels: [(kind: HUDReadout.Kind, level: Double)] = []
        var drags: [Bool] = []
        let size = CGSize(width: 281, height: 60)

        private var actions: HUDRowActions {
            HUDRowActions(
                setLevel: { [unowned self] kind, level in levels.append((kind, level)) },
                toggleMute: {},
                setDragging: { [unowned self] dragging in drags.append(dragging) }
            )
        }

        init() {
            _ = NSApplication.shared
            window = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            host = FirstMouseHost(rootView: Holder(
                readout: HUDReadout(kind: .volume, level: 0.5), isThere: true,
                metrics: metrics, actions: actions
            ))
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            window.contentView = host
            window.orderFrontRegardless()
            settle(0.3)
        }

        func show(_ readout: HUDReadout, isThere: Bool = true) {
            host.rootView = Holder(readout: readout, isThere: isThere, metrics: metrics, actions: actions)
            settle(0.2)
        }

        func settle(_ seconds: TimeInterval = 0.05) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        func point(_ fraction: CGFloat) -> NSPoint {
            NSPoint(x: metrics.barLeading + metrics.barWidth * fraction, y: size.height - metrics.centreY)
        }

        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            ) else { return }
            window.sendEvent(event)
            settle()
        }

        func close() {
            window.orderOut(nil)
            window.close()
        }
    }

    @Test("A key pressed during a drag doesn't move the drag to another control")
    func dragKeepsItsKind() throws {
        let solo = Solo()
        defer { solo.close() }
        solo.send(.leftMouseDown, solo.point(0.5))
        #expect(try #require(solo.levels.last).kind == .volume)

        solo.show(HUDReadout(kind: .brightness, level: 0.9))
        solo.send(.leftMouseDragged, solo.point(0.25))
        let moved = try #require(solo.levels.last)
        #expect(moved.kind == .volume)
        #expect(abs(moved.level - 0.25) < 0.02)
        solo.send(.leftMouseUp, solo.point(0.25))
    }

    /// Left latched, the shell swallows every hover exit from then on, and the
    /// notch stays open and eating clicks until something collapses it.
    @Test("The row going away under a held button lets go of the drag", arguments: [true, false])
    func severedDrag(rowGoes: Bool) {
        let solo = Solo()
        defer { solo.close() }
        solo.send(.leftMouseDown, solo.point(0.5))
        #expect(solo.drags == [true], "the drag never started")
        if rowGoes {
            solo.show(HUDReadout(kind: .volume, level: 0.5), isThere: false)
        } else {
            // Still drawn, but its controls have nothing to offer.
            solo.show(HUDReadout(kind: .keyboardBacklight, level: 0.5))
        }
        #expect(solo.drags == [true, false])
    }

    @Test("A release after the row has gone doesn't let go twice")
    func severedThenReleased() {
        let solo = Solo()
        defer { solo.close() }
        solo.send(.leftMouseDown, solo.point(0.5))
        solo.show(HUDReadout(kind: .volume, level: 0.5), isThere: false)
        solo.send(.leftMouseUp, solo.point(0.5))
        #expect(solo.drags == [true, false])
    }

    // MARK: - VoiceOver

    @Test("One VoiceOver step is five percent, clamped")
    func voiceOverStep() {
        #expect(HUDRowView.stepped(0.5, .increment) == 0.55)
        #expect(HUDRowView.stepped(0.5, .decrement) == 0.45)
        #expect(HUDRowView.stepped(0.98, .increment) == 1)
        #expect(HUDRowView.stepped(0.02, .decrement) == 0)
    }

    // MARK: - The wiring no test can run

    /// `LedgeCoordinator` can't be built in a test, so this reads it.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    private func body(of signature: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: signature), "\(signature)")
        let tail = source[start.upperBound...]
        let end = tail.range(of: "\n    }\n")?.lowerBound ?? tail.endIndex
        return tail[..<end]
    }

    /// Each of these is a way for the feature to die quietly: the speaker
    /// doing nothing, the row retiring from under a quick press, the drag
    /// moving to whichever screen the pointer slid onto.
    @Test("The shell answers the row")
    func wiring() throws {
        let coordinator = try source("Sources/LedgeShell/Coordinator/LedgeCoordinator.swift")
        #expect(coordinator.contains("onHUDToggleMute: { [weak self] in self?.toggleMuteFromRow() }"))
        #expect(coordinator.contains("onHUDRowDragging: { [weak self] dragging in self?.setRowDragging(dragging) }"))

        let dragging = try body(of: "private func setRowDragging(", in: coordinator)
        #expect(dragging.contains("hud.setRowDragging(dragging)"))
        #expect(dragging.contains("setHUDDragging(dragging)"))
        #expect(dragging.contains("if dragging { holdReadoutUnderThePointer() }"))

        let mute = try body(of: "private func toggleMuteFromRow(", in: coordinator)
        #expect(mute.contains("hud.toggleMute()"))
        #expect(mute.contains("holdReadoutUnderThePointer()"))

        let hold = try body(of: "private func holdReadoutUnderThePointer(", in: coordinator)
        #expect(hold.contains("if state.phase == .hud, !state.isHovering"))
        #expect(hold.contains("send(.hoverChanged(true))"))

        // A collapse or a closing card severs a drag with no release.
        let settle = try body(of: "private func settleBeforeReducing(", in: coordinator)
        #expect(settle.contains("hud.setRowDragging(false)"))
        #expect(coordinator.contains("self?.setRowDragging(false)"))

        let overlay = try source("Sources/LedgeUI/NotchOverlayView.swift")
        #expect(overlay.contains("setLevel: onHUDAdjust"))
        #expect(overlay.contains("toggleMute: onHUDToggleMute"))
        #expect(overlay.contains("setDragging: onHUDRowDragging"))

        let hud = try source("Sources/LedgeShell/Coordinator/HUDCoordinator.swift")
        let adjust = try body(of: "public func adjust(", in: hud)
        #expect(adjust.contains("rowDrag?.output ?? VolumeController.defaultOutputDevice()"))
        #expect(adjust.contains("rowDrag?.display ?? brightnessDisplayForTheRow()"))
        let key = try body(of: "private func handleVolume(", in: hud)
        #expect(key.contains("return toggleMute(on: device)"), "the key and the speaker are one action")

        // Whatever says which display a readout is about has to say it to `show`.
        let brightnessKey = try body(of: "private func handleBrightness(", in: hud)
        #expect(brightnessKey.contains("about: display.id)"))
        let oneDisplay = try body(of: "public func adjustBrightness(", in: hud)
        #expect(oneDisplay.contains("about: display.id)"))
        let shown = try body(of: "private func show(", in: hud)
        #expect(shown.contains("if readout.kind == .brightness { shownBrightnessDisplay = display }"))
    }
}
