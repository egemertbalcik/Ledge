import AppKit
import LedgeCore
import Testing

@testable import LedgeShell

/// The boundary between AppKit's scroll events and the gesture rules.
///
/// Worth testing at this level because the interesting mistakes are here
/// rather than in the arithmetic: a notched wheel reports *lines* where the
/// rules count points, and a trackpad must never take the wheel's path at all.
@Suite("Scroll events reaching the notch")
@MainActor
struct GestureMonitorTests {

    /// A scroll event as the window server would deliver it.
    ///
    /// - Parameters:
    ///   - lines: line-based deltas, as a notched wheel sends.
    ///   - points: precise deltas, as a trackpad or high-resolution wheel sends.
    ///   - phase: a touch phase, which only a touch device reports.
    private func scroll(
        lines: Int32 = 0,
        pointsY: Double? = nil,
        pointsX: Double? = nil,
        phase: CGScrollPhase? = nil,
        momentum: CGMomentumScrollPhase? = nil
    ) -> NSEvent {
        let event: CGEvent
        if pointsY != nil || pointsX != nil {
            event = CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0
            )!
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: pointsY ?? 0)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: pointsX ?? 0)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        } else {
            event = CGEvent(
                scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0
            )!
        }
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        if let momentum {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        }
        return NSEvent(cgEvent: event)!
    }

    private func monitor() -> (GestureMonitor, Box) {
        let box = Box()
        let monitor = GestureMonitor(threshold: 28, isNatural: true)
        monitor.onSwipe = { box.swipes.append($0) }
        return (monitor, box)
    }

    @MainActor final class Box {
        var swipes: [Swipe] = []
    }

    /// The bug this suite exists for: one click is one line, not one point, so
    /// taken at face value a card cost ten clicks.
    @Test("One click of a notched wheel is one card")
    func oneClickIsOneCard() {
        let (monitor, box) = self.monitor()
        let swallowed = monitor.handle(scroll(lines: -1))
        #expect(box.swipes == [.left], "wheel down is the next card")
        #expect(swallowed == nil, "and the event is ours, not the list's behind")
    }

    @Test("Wheel up goes back")
    func wheelUpGoesBack() {
        let (monitor, box) = self.monitor()
        _ = monitor.handle(scroll(lines: 1))
        #expect(box.swipes == [.right])
    }

    /// A trackpad's vertical scroll belongs to whatever is under the pointer.
    @Test("A trackpad's vertical scroll is handed back, not turned into a card")
    func trackpadVerticalPassesThrough() {
        let (monitor, box) = self.monitor()
        let returned = monitor.handle(scroll(pointsY: -40, phase: .changed))
        #expect(box.swipes.isEmpty, "no card")
        #expect(returned != nil, "and the list scrolls")
    }

    /// And its horizontal swipe still works exactly as before.
    @Test("A trackpad's horizontal swipe still moves between cards")
    func trackpadSwipeStillWorks() {
        let (monitor, box) = self.monitor()
        for _ in 0..<4 {
            _ = monitor.handle(scroll(pointsX: -10, phase: .changed))
        }
        #expect(box.swipes == [.left])
    }

    /// Coasting after a flick must not deal out more cards.
    @Test("Momentum is not a wheel")
    func momentumIsIgnored() {
        let (monitor, box) = self.monitor()
        _ = monitor.handle(scroll(pointsY: -60, momentum: .continuous))
        #expect(box.swipes.isEmpty)
    }

    /// A list under the pointer owns the wheel while it is open.
    @Test("Scrollable content keeps the wheel")
    func listKeepsTheWheel() {
        let (monitor, box) = self.monitor()
        monitor.wheelBelongsToContent = { true }
        let returned = monitor.handle(scroll(lines: -1))
        #expect(box.swipes.isEmpty, "the list scrolls instead")
        #expect(returned != nil)
    }

    /// Windows that are not the notch are none of this monitor's business.
    @Test("Another window's scrolling is left alone")
    func otherWindowsUntouched() {
        let (monitor, box) = self.monitor()
        monitor.shouldHandle = { _ in false }
        let returned = monitor.handle(scroll(lines: -1))
        #expect(box.swipes.isEmpty)
        #expect(returned != nil)
    }

    @Test("Scroll direction follows the system setting")
    func respectsScrollDirection() {
        let (monitor, box) = self.monitor()
        monitor.updateSettings(threshold: 28, isNatural: false)
        _ = monitor.handle(scroll(lines: -1))
        #expect(box.swipes == [.right], "with natural scrolling off, down goes back")
    }
}
