import Foundation
import LedgeCore
import Testing

/// Scrolling one of the Keep Awake length's numbers.
///
/// Travel arrives a little at a time and the number moves in whole steps, so
/// everything here is about where the steps fall: none early, none lost, and
/// none owed after the hand turns back.
@Suite("Scrolling a number")
struct ScrollDetentsTests {

    private let step = ScrollDetents.trackpadStep

    @Test("Up is more and down is less")
    func direction() {
        var detents = ScrollDetents()
        #expect(detents.feed(step, step: step) == 1)
        #expect(detents.feed(-step, step: step) == -1)
    }

    @Test("Nothing moves short of a whole step")
    func shortOfAStep() {
        var detents = ScrollDetents()
        #expect(detents.feed(step - 1, step: step) == 0)
        #expect(detents.feed(1, step: step) == 1, "the travel was banked, not dropped")
    }

    @Test("A long movement is every step it covered")
    func longMovement() {
        var detents = ScrollDetents()
        #expect(detents.feed(step * 3.5, step: step) == 3)
        #expect(detents.feed(step / 2, step: step) == 1, "the half step left over counts")
    }

    @Test("Turning back answers at once rather than undoing what was banked")
    func turningBack() {
        var detents = ScrollDetents()
        #expect(detents.feed(step - 1, step: step) == 0)
        #expect(detents.feed(-step, step: step) == -1)
    }

    @Test("Moving to another number starts it from nothing")
    func resetForgets() {
        var detents = ScrollDetents()
        #expect(detents.feed(step - 1, step: step) == 0)
        detents.reset()
        #expect(detents.feed(1, step: step) == 0)
    }

    @Test("One click of a wheel is one number")
    func wheelClick() {
        var detents = ScrollDetents()
        #expect(detents.feed(WheelNavigator.linePoints, step: ScrollDetents.wheelStep) == 1)
    }

    // MARK: - The wheel's pace

    @Test("A wheel moves one step per event, however many lines it reports")
    func wheelOneStepPerEvent() {
        var detents = ScrollDetents()
        #expect(detents.feedWheel(ScrollDetents.wheelStep * 4, at: 0) == 1)
        #expect(detents.feedWheel(-ScrollDetents.wheelStep * 3, at: 1) == -1)
    }

    @Test("A wheel spun fast is held to its pace, and does not catch up afterwards")
    func wheelPace() {
        var detents = ScrollDetents()
        let click = ScrollDetents.wheelStep
        let gap = ScrollDetents.wheelInterval
        #expect(detents.feedWheel(click, at: 0) == 1)
        #expect(detents.feedWheel(click, at: gap / 2) == 0, "too soon after the last step")
        #expect(detents.feedWheel(click / 2, at: gap * 3) == 0,
                "the click held back was dropped, not banked: banked, this would complete it")
        #expect(detents.feedWheel(click / 2, at: gap * 4) == 1, "the pace allows the next")
    }

    @Test("Moving to another number lets its first click through at once")
    func wheelResetClearsPace() {
        var detents = ScrollDetents()
        #expect(detents.feedWheel(ScrollDetents.wheelStep, at: 0) == 1)
        detents.reset()
        #expect(detents.feedWheel(ScrollDetents.wheelStep, at: 0.01) == 1)
    }

    @Test("Nonsense travel moves nothing")
    func nonsense() {
        var detents = ScrollDetents()
        #expect(detents.feed(.nan, step: step) == 0)
        #expect(detents.feed(.infinity, step: step) == 0)
        #expect(detents.feed(step, step: 0) == 0)
        #expect(detents.feed(step, step: step) == 1, "and leaves nothing behind")
    }
}
