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
        momentum: CGMomentumScrollPhase? = nil,
        at seconds: TimeInterval? = nil,
        natural: Bool = false
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
        // Wheel steps are paced, so a test that clicks twice says when.
        if let seconds { event.timestamp = CGEventTimestamp(seconds * 1_000_000_000) }
        if natural { Self.markNatural(event) }
        return NSEvent(cgEvent: event)!
    }

    /// Marks an event as natural scrolling's: deltas reported against the
    /// hand, and `isDirectionInvertedFromDevice` true. Field 137 is the
    /// window server's own flag for it; it has no public name.
    private static func markNatural(_ event: CGEvent) {
        event.setIntegerValueField(CGEventField(rawValue: 137)!, value: 1)
    }

    @Test("A natural-scrolling event says it is inverted")
    func naturalFixture() {
        // Every natural test below rests on this.
        #expect(scroll(pointsX: 1, phase: .began, natural: true).isDirectionInvertedFromDevice)
        #expect(!scroll(pointsX: 1, phase: .began).isDirectionInvertedFromDevice)
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

    // MARK: - A number under the pointer

    /// A monitor with a Keep Awake length number under the pointer.
    private func overNumber() -> (GestureMonitor, Box, Steps) {
        let (monitor, box) = self.monitor()
        let steps = Steps()
        monitor.claimScroll(
            ScrollClaim(owner: .keepAwakeLength, axis: .vertical) { steps.taken.append($0) }
        )
        return (monitor, box, steps)
    }

    @MainActor final class Steps {
        var taken: [Int] = []
    }

    @Test("A wheel over a number moves the number, one click at a time, and not the cards")
    func wheelMovesNumber() {
        let (monitor, box, steps) = overNumber()
        let returned = monitor.handle(scroll(lines: 1, at: 100))
        _ = monitor.handle(scroll(lines: -1, at: 101))
        #expect(steps.taken == [1, -1], "up is more")
        #expect(box.swipes.isEmpty, "no card changed")
        #expect(returned == nil, "the event is the number's")
    }

    @Test("A trackpad's vertical scroll over a number moves it every fourteen points")
    func trackpadMovesNumber() {
        let (monitor, box, steps) = overNumber()
        for _ in 0..<4 {
            _ = monitor.handle(scroll(pointsY: 7, phase: .changed))
        }
        #expect(steps.taken == [1, 1])
        #expect(box.swipes.isEmpty)
    }

    @Test("Short of a step, the scroll is still the number's")
    func shortStepIsSwallowed() {
        let (monitor, box, steps) = overNumber()
        let returned = monitor.handle(scroll(pointsY: 3, phase: .changed))
        #expect(steps.taken.isEmpty)
        #expect(returned == nil, "handed back, it would reach the cards behind")
        #expect(box.swipes.isEmpty)
    }

    @Test("A trackpad's sideways swipe over a number still moves between cards")
    func sidewaysStillSwipes() {
        let (monitor, box, steps) = overNumber()
        for _ in 0..<4 {
            _ = monitor.handle(scroll(pointsX: -10, phase: .changed))
        }
        #expect(box.swipes == [.left])
        #expect(steps.taken.isEmpty)
    }

    @Test("Coasting after a flick does not keep counting")
    func momentumDoesNotCount() {
        let (monitor, _, steps) = overNumber()
        let returned = monitor.handle(scroll(pointsY: 60, momentum: .continuous))
        #expect(steps.taken.isEmpty)
        #expect(returned == nil)
    }

    /// The cards follow Ledge's "match my trackpad" setting; a number follows
    /// the hand, like dragging it, so the setting must not turn it round.
    @Test("The cards' direction setting does not turn a number round")
    func numberIgnoresCardSetting() {
        let (monitor, _, steps) = overNumber()
        monitor.updateSettings(threshold: 28, isNatural: false)
        _ = monitor.handle(scroll(lines: 1))
        #expect(steps.taken == [1])
    }

    /// With natural scrolling the delta arrives against the hand: fingers
    /// up are reported negative, and the event says it is inverted.
    @Test("Up is the hand moving up, whichever way the system reports it")
    func physicalDirection() {
        #expect(GestureMonitor.physicalUp(-10, invertedFromDevice: true) == 10,
                "natural scrolling: fingers up arrive negative")
        #expect(GestureMonitor.physicalUp(10, invertedFromDevice: true) == -10)
        #expect(GestureMonitor.physicalUp(10, invertedFromDevice: false) == 10,
                "classic scrolling: up arrives positive")
    }

    /// The reviewer's repro: vertical overall, but half its events lean
    /// sideways. Judged one event at a time, the recogniser saw only the
    /// sideways ones and paged the card away mid-question.
    @Test("A slanted, mostly vertical stroke over a number moves the number and never pages")
    func slantedStrokeDoesNotPage() {
        let (monitor, box, steps) = overNumber()
        for i in 0..<10 {
            let (dx, dy): (Double, Double) = i.isMultiple(of: 2) ? (-6, 5) : (-4, 7)
            _ = monitor.handle(scroll(pointsY: dy, pointsX: dx, phase: .changed))
        }
        #expect(box.swipes.isEmpty, "the stroke was vertical")
        #expect(!steps.taken.isEmpty, "and the number took it")
    }

    @Test("Without a number, the same slanted stroke does not page either")
    func slantedStrokeBaseline() {
        let (monitor, box) = self.monitor()
        for i in 0..<10 {
            let (dx, dy): (Double, Double) = i.isMultiple(of: 2) ? (-6, 5) : (-4, 7)
            _ = monitor.handle(scroll(pointsY: dy, pointsX: dx, phase: .changed))
        }
        #expect(box.swipes.isEmpty)
    }

    @Test("A wheel event reporting several lines is still one step")
    func acceleratedWheelIsOneStep() {
        let (monitor, _, steps) = overNumber()
        _ = monitor.handle(scroll(lines: 4))
        #expect(steps.taken == [1])
    }

    @Test("A sideways wheel tilt over a number is not the number's")
    func wheelTiltPassesOn() {
        let (monitor, _, steps) = overNumber()
        let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 2, wheel1: 0, wheel2: 1, wheel3: 0
        )!
        _ = monitor.handle(NSEvent(cgEvent: event)!)
        #expect(steps.taken.isEmpty)
    }

    @Test("What one number left short of a step is not owed to the next")
    func changingNumberForgets() {
        let (monitor, _, steps) = overNumber()
        _ = monitor.handle(scroll(pointsY: 10, phase: .changed))
        let next = Steps()
        monitor.claimScroll(
            ScrollClaim(owner: .keepAwakeLength, axis: .vertical) { next.taken.append($0) }
        )
        _ = monitor.handle(scroll(pointsY: 10, phase: .changed))
        #expect(steps.taken.isEmpty)
        #expect(next.taken.isEmpty, "ten and ten would have been a step")
    }

    @Test("Fingers up are more with natural scrolling too")
    func naturalNumber() {
        let (monitor, _, steps) = overNumber()
        _ = monitor.handle(scroll(pointsY: -14, phase: .changed, natural: true))
        #expect(steps.taken == [1], "natural scrolling reports fingers up as negative")
    }

    // MARK: - The timer's open rule under the pointer

    /// A monitor with the timer's open rule under the pointer. Steps are
    /// minutes, positive for more.
    private func overRule() -> (GestureMonitor, Box, Steps) {
        let (monitor, box) = self.monitor()
        let steps = Steps()
        monitor.claimScroll(
            ScrollClaim(owner: .timerRule, axis: .horizontal) { steps.taken.append($0) }
        )
        return (monitor, box, steps)
    }

    /// A sideways stroke, as a trackpad sends it: the first event begins it.
    private func sidewaysStroke(_ deltas: [Double], over monitor: GestureMonitor) -> [NSEvent?] {
        deltas.enumerated().map { index, dx in
            monitor.handle(scroll(pointsX: dx, phase: index == 0 ? .began : .changed))
        }
    }

    /// Synthetic events are not inverted, which is classic scrolling: fingers
    /// left arrive positive. Fingers left pull the rule left, which brings
    /// larger numbers under the marker, as dragging it does.
    @Test("A sideways stroke on the rule moves it a minute every six points, and never the cards")
    func strokeMovesRule() {
        let (monitor, box, steps) = overRule()
        let returned = sidewaysStroke([12, 12, 12, 12, 12], over: monitor)
        #expect(steps.taken.reduce(0, +) == 10, "sixty points is ten minutes")
        #expect(steps.taken.allSatisfy { $0 > 0 }, "fingers left is more")
        #expect(box.swipes.isEmpty, "well past the swipe threshold, and still no card changed")
        #expect(returned.allSatisfy { $0 == nil }, "every event was the rule's")
    }

    @Test("Fingers the other way take minutes off")
    func strokeBackTakesOff() {
        let (monitor, _, steps) = overRule()
        _ = sidewaysStroke([-6, -6, -6], over: monitor)
        #expect(steps.taken.reduce(0, +) == -3)
    }

    @Test("The first points of a stroke, spent judging it, still move the rule")
    func judgingIsNotLost() {
        let (monitor, _, steps) = overRule()
        _ = sidewaysStroke([2, 2, 2], over: monitor)
        #expect(steps.taken == [1], "six points in all, though no single event reached the lean")
    }

    @Test("A vertical stroke on the rule is handed back, and moves nothing")
    func verticalOnRulePassesOn() {
        let (monitor, box, steps) = overRule()
        _ = monitor.handle(scroll(pointsY: 2, phase: .began))
        let returned = monitor.handle(scroll(pointsY: 8, phase: .changed))
        let later = monitor.handle(scroll(pointsY: 1, pointsX: 9, phase: .changed))
        #expect(returned != nil)
        #expect(later != nil, "judged vertical once, for the whole stroke")
        #expect(steps.taken.isEmpty)
        #expect(box.swipes.isEmpty)
    }

    /// The card can slide in under a still pointer while the swipe that
    /// brought it is still going.
    @Test("A stroke that began somewhere else is not the rule's")
    func strokeFromElsewhere() {
        let (monitor, box, steps) = overRule()
        for _ in 0..<4 {
            _ = monitor.handle(scroll(pointsX: -10, phase: .changed))
        }
        #expect(steps.taken.isEmpty)
        #expect(box.swipes == [.left], "the swipe it was still pages")
    }

    @Test("The coast after a stroke on the rule keeps moving it, and stops with the stroke")
    func coastMovesRule() {
        let (monitor, box, steps) = overRule()
        _ = sidewaysStroke([6], over: monitor)
        _ = monitor.handle(scroll(pointsX: 0, phase: .ended))
        _ = monitor.handle(scroll(pointsX: 12, momentum: .begin))
        _ = monitor.handle(scroll(pointsX: 6, momentum: .end))
        #expect(steps.taken.reduce(0, +) == 4)
        let after = monitor.handle(scroll(pointsX: 12, momentum: .continuous))
        #expect(steps.taken.reduce(0, +) == 4, "a coast with no stroke behind it is not the rule's")
        #expect(after == nil, "and is left to the cards, which ignore a coast")
        #expect(box.swipes.isEmpty)
    }

    @Test("The coast of a vertical stroke is not the rule's either")
    func verticalCoastPassesOn() {
        let (monitor, _, steps) = overRule()
        _ = monitor.handle(scroll(pointsY: 8, phase: .began))
        _ = monitor.handle(scroll(pointsY: 0, phase: .ended))
        _ = monitor.handle(scroll(pointsX: 20, momentum: .begin))
        _ = monitor.handle(scroll(pointsX: 20, momentum: .continuous))
        #expect(steps.taken.isEmpty)
    }

    @Test("A wheel on the rule turns it a minute a click, up for more, and not the cards")
    func wheelTurnsRule() {
        let (monitor, box, steps) = overRule()
        let returned = monitor.handle(scroll(lines: 1, at: 100))
        _ = monitor.handle(scroll(lines: -1, at: 101))
        #expect(steps.taken == [1, -1])
        #expect(box.swipes.isEmpty)
        #expect(returned == nil)
    }

    @Test("A sideways wheel turns the rule too")
    func tiltTurnsRule() {
        let (monitor, box, steps) = overRule()
        let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .line,
            wheelCount: 2, wheel1: 0, wheel2: 1, wheel3: 0
        )!
        let returned = monitor.handle(NSEvent(cgEvent: event)!)
        #expect(steps.taken.count == 1)
        #expect(box.swipes.isEmpty)
        #expect(returned == nil)
    }

    @Test("A stroke the rule took is forgotten when the pointer moves on")
    func claimChangeForgetsStroke() {
        let (monitor, _, steps) = overRule()
        _ = sidewaysStroke([6], over: monitor)
        // Off the rule and back on: the cards tell the monitor each time.
        monitor.releaseScroll(.timerRule)
        monitor.claimScroll(
            ScrollClaim(owner: .timerRule, axis: .horizontal) { steps.taken.append($0) }
        )
        _ = monitor.handle(scroll(pointsX: 12, phase: .changed))
        #expect(steps.taken == [1], "the rest of that stroke began before the claim")
    }

    /// The reviewer's repro. The stroke spends its first three points going
    /// up, which rules out a swipe anywhere on the card; the rule must not
    /// hide those points from the recogniser and let the rest page.
    @Test("A stroke that starts up and turns sideways pages nothing from the rule")
    func lShapedStroke() {
        let (monitor, box, steps) = overRule()
        _ = monitor.handle(scroll(pointsY: 1, phase: .began))
        _ = monitor.handle(scroll(pointsY: 1, phase: .changed))
        _ = monitor.handle(scroll(pointsY: 1.2, phase: .changed))
        for _ in 0..<6 {
            _ = monitor.handle(scroll(pointsY: 1, pointsX: -6, phase: .changed))
        }
        #expect(box.swipes.isEmpty, "the same stroke beside the rule pages nothing")
        #expect(steps.taken.isEmpty, "and it was vertical, so not the rule's either")
    }

    @Test("The same stroke beside the rule pages nothing")
    func lShapedStrokeBaseline() {
        let (monitor, box) = self.monitor()
        _ = monitor.handle(scroll(pointsY: 1, phase: .began))
        _ = monitor.handle(scroll(pointsY: 1, phase: .changed))
        _ = monitor.handle(scroll(pointsY: 1.2, phase: .changed))
        for _ in 0..<6 {
            _ = monitor.handle(scroll(pointsY: 1, pointsX: -6, phase: .changed))
        }
        #expect(box.swipes.isEmpty)
    }

    @Test("Fingers left are more with natural scrolling too")
    func naturalStroke() {
        let (monitor, _, steps) = overRule()
        let returned = monitor.handle(scroll(pointsX: -6, phase: .began, natural: true))
        _ = monitor.handle(scroll(pointsX: -6, phase: .changed, natural: true))
        #expect(returned == nil)
        #expect(steps.taken == [1, 1], "natural scrolling reports fingers left as negative")
    }

    @Test("A wheel rolled up is more with natural scrolling too")
    func naturalWheel() {
        let (monitor, _, steps) = overRule()
        _ = monitor.handle(scroll(lines: -1, natural: true))
        #expect(steps.taken == [1])
    }

    /// The same physical tilt reports opposite signs under the two settings,
    /// and must turn the rule the same way under both.
    @Test("A sideways wheel turns the rule the same way under either setting")
    func tiltDirection() {
        func tilt(_ amount: Int32, natural: Bool) -> NSEvent {
            let event = CGEvent(
                scrollWheelEvent2Source: nil, units: .line,
                wheelCount: 2, wheel1: 0, wheel2: amount, wheel3: 0
            )!
            if natural { Self.markNatural(event) }
            return NSEvent(cgEvent: event)!
        }
        let (classic, _, classicSteps) = overRule()
        _ = classic.handle(tilt(1, natural: false))
        let (natural, _, naturalSteps) = overRule()
        _ = natural.handle(tilt(-1, natural: true))
        #expect(classicSteps.taken == [1])
        #expect(naturalSteps.taken == [1])
    }

    @Test("The pointer leaving the notch gives the scrolling back")
    func leavingNotchReleases() {
        let (monitor, box, steps) = overRule()
        monitor.releaseAllScroll()
        for _ in 0..<4 {
            _ = monitor.handle(scroll(pointsX: -10, phase: .changed))
        }
        #expect(steps.taken.isEmpty)
        #expect(box.swipes == [.left], "a sideways stroke pages again")
    }

    @Test("Another card cannot give back the rule's scrolling")
    func otherOwnerCannotRelease() {
        let (monitor, box, steps) = overRule()
        monitor.releaseScroll(.keepAwakeLength)
        _ = sidewaysStroke([6, 6, 6, 6, 6], over: monitor)
        #expect(steps.taken.reduce(0, +) == 5)
        #expect(box.swipes.isEmpty)
    }

    @Test("Right is the hand moving right, whichever way the system reports it")
    func physicalSideways() {
        #expect(GestureMonitor.physicalRight(10, invertedFromDevice: true) == 10,
                "natural scrolling: the content follows the fingers")
        #expect(GestureMonitor.physicalRight(10, invertedFromDevice: false) == -10,
                "classic scrolling: the content goes the other way")
    }

    @Test("Scroll direction follows the system setting")
    func respectsScrollDirection() {
        let (monitor, box) = self.monitor()
        monitor.updateSettings(threshold: 28, isNatural: false)
        _ = monitor.handle(scroll(lines: -1))
        #expect(box.swipes == [.right], "with natural scrolling off, down goes back")
    }
}
