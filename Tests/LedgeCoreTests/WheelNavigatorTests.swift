import Foundation
import LedgeCore
import Testing

/// Moving between cards with a mouse wheel.
///
/// The wheel is the one input with a single axis, and vertical scrolling is
/// deliberately not a gesture this app claims — so everything here is about
/// claiming exactly the wheel and nothing else.
@Suite("Wheel navigation")
struct WheelNavigatorTests {

    private let step = WheelNavigator.step

    private func sample(_ dy: Double, at timestamp: TimeInterval = 0) -> ScrollSample {
        ScrollSample(dx: 0, dy: dy, timestamp: timestamp)
    }

    // MARK: - Direction

    @Test("Wheel down is the next card, the same as swiping left")
    func downIsForward() {
        var wheel = WheelNavigator()
        #expect(wheel.feed(sample(-step)) == .left)
    }

    @Test("Wheel up is the previous card")
    func upIsBackward() {
        var wheel = WheelNavigator()
        #expect(wheel.feed(sample(step)) == .right)
    }

    /// With natural scrolling off the delta describes where the content should
    /// go, which is the opposite of where the wheel went.
    @Test("Scroll direction setting flips it, as it does for swipes")
    func respectsScrollDirection() {
        var natural = WheelNavigator(isNatural: true)
        var classic = WheelNavigator(isNatural: false)
        #expect(natural.feed(sample(-step)) == .left)
        #expect(classic.feed(sample(-step)) == .right)
    }

    // MARK: - One card per movement

    @Test("A nudge is not a card")
    func smallMovementDoesNothing() {
        var wheel = WheelNavigator()
        #expect(wheel.feed(sample(-step / 4)) == nil)
        #expect(wheel.feed(sample(-step / 4)) == nil)
    }

    /// One click of a notched wheel is about ten points, and is one card.
    @Test("A single click moves exactly one card")
    func oneClickOneCard() {
        var wheel = WheelNavigator()
        #expect(wheel.feed(sample(-10, at: 0)) == .left)
        #expect(wheel.feed(sample(-10, at: 0.01)) == nil, "too soon to be another card")
    }

    @Test("Small deltas add up to exactly one card")
    func smoothWheelAccumulates() {
        var wheel = WheelNavigator()
        var fired: [Swipe] = []
        // A high-resolution wheel, a few points at a time.
        for tick in 0..<8 {
            if let swipe = wheel.feed(sample(-step / 4, at: Double(tick) * 0.01)) {
                fired.append(swipe)
            }
        }
        #expect(fired == [.left], "twice the threshold, once through the queue")
    }

    /// The failure this guards against: one flick of a free-spinning wheel
    /// running through every card at once.
    @Test("A fast spin moves at a readable pace, not one card per event")
    func fastSpinIsPaced() {
        var wheel = WheelNavigator()
        var fired: [Swipe] = []
        // Half a second of a free-spinning wheel: 50 events, a step each.
        for tick in 0..<50 {
            if let swipe = wheel.feed(sample(-step, at: Double(tick) * 0.01)) {
                fired.append(swipe)
            }
        }
        #expect(fired.count <= 5, "paced by the interval, not by the event rate")
        #expect(fired.count >= 3, "but a long spin does travel")
        #expect(fired.allSatisfy { $0 == .left })
    }

    /// Held rather than banked: when the hand stops, the cards stop with it.
    @Test("A spin does not deal out cards after it has stopped")
    func spinDoesNotBank() {
        var wheel = WheelNavigator()
        var fired: [Swipe] = []
        // A burst far beyond the pace limit, all within one interval.
        for tick in 0..<20 {
            if let swipe = wheel.feed(sample(-40, at: Double(tick) * 0.002)) {
                fired.append(swipe)
            }
        }
        let duringBurst = fired.count
        // Then the hand stops; one straggling event arrives after the limit.
        if let swipe = wheel.feed(sample(0, at: 0.5)) { fired.append(swipe) }
        #expect(duringBurst == 1, "800 points in 40ms is one card, not eighty")
        #expect(fired.count == duringBurst, "and nothing was saved up for afterwards")
    }

    @Test("Stopping and turning again is a second card")
    func secondMovementFiresAgain() {
        var wheel = WheelNavigator()
        #expect(wheel.feed(sample(-step, at: 0)) == .left)
        // A pause longer than the idle timeout: the hand left the wheel.
        #expect(wheel.feed(sample(-step, at: 1)) == .left)
    }

    @Test("Turning back the other way goes back")
    func reversalFiresTheOtherWay() {
        var wheel = WheelNavigator()
        #expect(wheel.feed(sample(-step, at: 0)) == .left)
        // Far enough after the pace limit to be a deliberate change of mind.
        #expect(wheel.feed(sample(step, at: 0.2)) == .right)
    }

    @Test("Movement banked one way is dropped when the wheel turns back")
    func reversalDropsTheOldDirection() {
        var wheel = WheelNavigator()
        // Not quite a card's worth downward...
        #expect(wheel.feed(sample(-step * 0.9, at: 0)) == nil)
        // ...then upward: the reversal starts from nothing, so this is not a
        // card yet either, rather than being cancelled out by what came before.
        #expect(wheel.feed(sample(step * 0.9, at: 0.02)) == nil)
        #expect(wheel.feed(sample(step * 0.2, at: 0.04)) == .right)
    }

    @Test("Rapid events are paced rather than counted")
    func rapidInput() {
        var wheel = WheelNavigator()
        var fired: [Swipe] = []
        // Twenty events in a tenth of a second — inside one pace interval.
        for tick in 0..<20 {
            if let swipe = wheel.feed(sample(-step, at: Double(tick) * 0.005)) {
                fired.append(swipe)
            }
        }
        #expect(fired.count == 1, "a fast spin is a movement, not a card each")
    }

    /// Deliberate clicks, a third of a second apart, each move one card.
    @Test("Separate clicks each move a card")
    func deliberateClicks() {
        var wheel = WheelNavigator()
        var fired: [Swipe] = []
        for tick in 0..<4 {
            if let swipe = wheel.feed(sample(-10, at: Double(tick) * 0.3)) {
                fired.append(swipe)
            }
        }
        #expect(fired == [.left, .left, .left, .left])
    }

    // MARK: - Whose event is it

    @Test("A trackpad's scroll is not a wheel")
    func trackpadIsNotAWheel() {
        #expect(!WheelNavigator.isWheel(hasPhase: true, isMomentum: false))
        #expect(!WheelNavigator.isWheel(hasPhase: true, isMomentum: true))
    }

    @Test("Coasting after a flick is not a wheel either")
    func momentumIsNotAWheel() {
        #expect(!WheelNavigator.isWheel(hasPhase: false, isMomentum: true))
    }

    @Test("A wheel has no phase to report")
    func wheelHasNoPhase() {
        #expect(WheelNavigator.isWheel(hasPhase: false, isMomentum: false))
    }

    // MARK: - Not poisoned by nonsense

    @Test("A non-finite delta is ignored rather than poisoning the total")
    func nonFiniteIgnored() {
        var wheel = WheelNavigator()
        #expect(wheel.feed(sample(.nan)) == nil)
        #expect(wheel.feed(sample(.infinity)) == nil)
        #expect(wheel.feed(sample(-step)) == .left, "still working afterwards")
    }
}
