import Foundation
import LedgeCore
import Testing

/// Which trackpad strokes the timer's open rule takes for itself.
///
/// Sideways is also how the notch moves between cards, so the rule must take
/// only strokes that are its own: begun on it, sideways from the start, and
/// nothing after they are over.
@Suite("Strokes over the timer's rule")
struct SidewaysStrokeTests {

    private func sample(_ dx: Double, _ dy: Double = 0, momentum: Bool = false) -> ScrollSample {
        ScrollSample(dx: dx, dy: dy, timestamp: 0, isMomentum: momentum)
    }

    @Test("A sideways stroke begun on the rule is the rule's, first points included")
    func sidewaysIsTaken() {
        var stroke = SidewaysStroke()
        #expect(stroke.feed(sample(2), began: true) == .undecided)
        #expect(stroke.feed(sample(2), began: false) == .sideways(4), "what judging held is paid out")
        #expect(stroke.feed(sample(5, 1), began: false) == .sideways(5))
    }

    @Test("A vertical stroke is not the rule's, to its end")
    func verticalIsHandedBack() {
        var stroke = SidewaysStroke()
        #expect(stroke.feed(sample(0, 4), began: true) == .notOurs)
        #expect(stroke.feed(sample(20, 0), began: false) == .notOurs, "judged once, not per event")
        #expect(stroke.feed(sample(20, 0, momentum: true), began: false) == .notOurs)
    }

    @Test("A slanted, mostly vertical start is vertical")
    func slantedIsVertical() {
        var stroke = SidewaysStroke()
        #expect(stroke.feed(sample(1, 2), began: true) == .undecided)
        #expect(stroke.feed(sample(1, 2), began: false) == .notOurs)
    }

    @Test("A stroke that did not begin here is never the rule's")
    func notBegunHere() {
        var stroke = SidewaysStroke()
        #expect(stroke.feed(sample(30), began: false) == .notOurs)
        #expect(stroke.feed(sample(30, momentum: true), began: false) == .notOurs)
    }

    @Test("The coast of a stroke the rule took stays the rule's, and ends with it")
    func coastStaysThenEnds() {
        var stroke = SidewaysStroke()
        _ = stroke.feed(sample(5), began: true)
        #expect(stroke.feed(sample(8, momentum: true), began: false) == .sideways(8))
        #expect(stroke.feed(sample(1, momentum: true), began: false, coastEnded: true) == .sideways(1))
        #expect(stroke.feed(sample(8, momentum: true), began: false) == .notOurs)
    }

    @Test("A coast with nothing judged before it moves nothing")
    func coastOfTinyStroke() {
        var stroke = SidewaysStroke()
        _ = stroke.feed(sample(1), began: true)
        #expect(stroke.feed(sample(10, momentum: true), began: false) == .undecided)
    }

    @Test("Each stroke is judged afresh")
    func newStrokeResets() {
        var stroke = SidewaysStroke()
        _ = stroke.feed(sample(0, 5), began: true)
        #expect(stroke.feed(sample(5), began: true) == .sideways(5))
    }

    @Test("Forgetting the stroke gives the rest of it away")
    func resetGivesAway() {
        var stroke = SidewaysStroke()
        _ = stroke.feed(sample(5), began: true)
        stroke.reset()
        #expect(stroke.feed(sample(5), began: false) == .notOurs)
    }

    @Test("A broken delta moves nothing and does not poison the stroke")
    func nonFinite() {
        var stroke = SidewaysStroke()
        #expect(stroke.feed(sample(.nan), began: true) == .undecided)
        #expect(stroke.feed(sample(4), began: false) == .sideways(4))
        #expect(stroke.feed(sample(.infinity), began: false) == .undecided)
        #expect(stroke.feed(sample(3), began: false) == .sideways(3))
    }

    @Test("A minute on the rule is one tick's distance")
    func rulerStep() {
        #expect(ScrollDetents.rulerStep == Double(DurationDial.pointsPerMinute))
    }
}
