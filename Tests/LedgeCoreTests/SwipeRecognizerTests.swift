import Foundation
import Testing

@testable import LedgeCore

@Suite("Swipe recogniser")
struct SwipeRecognizerTests {

    private func sample(
        _ dx: Double,
        _ dy: Double,
        at time: TimeInterval = 0,
        momentum: Bool = false,
        ended: Bool = false
    ) -> ScrollSample {
        ScrollSample(dx: dx, dy: dy, timestamp: time, isMomentum: momentum, isEnded: ended)
    }

    @Test("Deltas accumulate until the threshold is crossed")
    func accumulatesToThreshold() {
        var recognizer = SwipeRecognizer(threshold: 30)
        #expect(recognizer.feed(sample(10, 0, at: 0)) == .pending)
        #expect(recognizer.feed(sample(10, 0, at: 0.01)) == .pending)
        #expect(recognizer.feed(sample(10, 0, at: 0.02)) == .swipe(.right))
    }

    @Test("One gesture fires at most one swipe")
    func onlyOnePerGesture() {
        var recognizer = SwipeRecognizer(threshold: 20)
        #expect(recognizer.feed(sample(30, 0, at: 0)) == .swipe(.right))
        // A single flick keeps producing deltas; without the lock this would
        // cycle through every activity at once.
        #expect(recognizer.feed(sample(30, 0, at: 0.01)) == .pending)
        #expect(recognizer.feed(sample(30, 0, at: 0.02)) == .pending)
    }

    @Test("A new gesture is recognised after the previous one ends")
    func rearmsAfterEnd() {
        var recognizer = SwipeRecognizer(threshold: 20)
        #expect(recognizer.feed(sample(30, 0, at: 0)) == .swipe(.right))
        _ = recognizer.feed(sample(0, 0, at: 0.05, ended: true))
        #expect(recognizer.feed(sample(30, 0, at: 0.06)) == .swipe(.right))
    }

    @Test("Momentum after a flick is ignored")
    func momentumIgnored() {
        var recognizer = SwipeRecognizer(threshold: 20)
        #expect(recognizer.feed(sample(25, 0, at: 0)) == .swipe(.right))
        _ = recognizer.feed(sample(0, 0, at: 0.05, ended: true))
        // Coasting deltas arrive after the fingers lift.
        #expect(recognizer.feed(sample(40, 0, at: 0.06, momentum: true)) == .pending)
        #expect(recognizer.feed(sample(40, 0, at: 0.07, momentum: true)) == .pending)
    }

    @Test("A long pause ends the gesture even with no end event")
    func idleTimeoutResets() {
        var recognizer = SwipeRecognizer(threshold: 30, idleTimeout: 0.25)
        #expect(recognizer.feed(sample(20, 0, at: 0)) == .pending)
        // A mouse wheel sends no phase events, so the only signal is the gap.
        #expect(recognizer.feed(sample(20, 0, at: 1.0)) == .pending, "accumulation restarted")
        #expect(recognizer.feed(sample(20, 0, at: 1.01)) == .swipe(.right))
    }

    @Test("A gesture that leans vertical is disclaimed, not turned into a swipe")
    func verticalIsNotOurs() {
        // Vertical scrolling used to open a card, throw the open one away, or
        // collapse it. It does nothing now, and — just as importantly — the
        // event is handed back so whatever is under the pointer can use it.
        var recognizer = SwipeRecognizer(threshold: 20)
        #expect(recognizer.feed(sample(2, 25, at: 0)) == .notOurs)
        #expect(recognizer.feed(sample(40, 0, at: 0.02)) == .notOurs, "the axis holds for the whole gesture")
    }

    @Test("A mostly-sideways gesture still swipes")
    func diagonalStillSwipes() {
        var recognizer = SwipeRecognizer(threshold: 20)
        #expect(recognizer.feed(sample(25, 6, at: 0)) == .swipe(.right))
    }

    @Test("Vertical is disclaimed early, before the swipe threshold")
    func verticalDisclaimedEarly() {
        // A list under the pointer must start scrolling at once rather than
        // after a threshold's worth of stalled movement.
        var recognizer = SwipeRecognizer(threshold: 60)
        #expect(recognizer.feed(sample(0, 4, at: 0)) == .notOurs)
    }

    @Test("Reset clears part-way accumulation")
    func resetClearsAccumulation() {
        var recognizer = SwipeRecognizer(threshold: 30)
        _ = recognizer.feed(sample(20, 0, at: 0))
        recognizer.reset()
        #expect(recognizer.feed(sample(20, 0, at: 0.01)) == .pending)
    }
}

@Suite("Swipe intent")
struct SwipeIntentTests {

    @Test("Horizontal swipes cycle regardless of phase")
    func horizontalCycles() {
        #expect(SwipeIntent.from(.left, phase: .idle) == .cycleForward)
        #expect(SwipeIntent.from(.right, phase: .expanded) == .cycleBackward)
    }

    @Test("There are no vertical intents left to have")
    func onlyHorizontalIntents() {
        // The enum itself is the guarantee: `Swipe` has two cases, and every
        // one of them cycles. Nothing about scrolling can dismiss a card, in
        // any phase.
        for phase in NotchPhase.allCases {
            #expect(SwipeIntent.from(.left, phase: phase) == .cycleForward)
            #expect(SwipeIntent.from(.right, phase: phase) == .cycleBackward)
        }
    }
}
