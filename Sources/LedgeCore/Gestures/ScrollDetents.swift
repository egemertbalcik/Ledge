import Foundation

/// Turns scrolling over a number into whole steps of that number.
///
/// The Keep Awake length is three numbers — days, hours, minutes — and each
/// one can be scrolled while the pointer is over it; so can the timer's rule,
/// sideways, a minute at a time. Scrolling arrives as a
/// distance, a little at a time; the number moves in whole steps. This is the
/// arithmetic between the two, kept out of the event handling so it can be
/// tested without one.
///
/// Up is more, the same as dragging the number up. The caller hands in travel
/// that is already positive for the hand moving up — fingers up, a wheel
/// rolled away — so how the system reports direction is decided in one place,
/// where the events arrive.
///
/// Pure and clockless, like the wheel navigator beside it.
public struct ScrollDetents: Equatable, Sendable {

    /// How far a trackpad travels between two numbers. The figure the drag on
    /// the same numbers uses, so the finger learns one distance, not two.
    public static let trackpadStep: Double = 14

    /// How far a trackpad travels sideways between two minutes on the timer's
    /// rule: exactly the distance between two of its ticks, so the rule moves
    /// under the fingers the way it moves under a drag.
    public static let rulerStep = Double(DurationDial.pointsPerMinute)

    /// How far a wheel travels between two numbers: one click. A notched
    /// wheel reports a line per click and a high-resolution one reports
    /// points, ten to the line, which is what `WheelNavigator.linePoints`
    /// already says a line is worth.
    public static let wheelStep: Double = WheelNavigator.linePoints

    /// The least time between two steps from a wheel.
    ///
    /// One click is one step, but a wheel spun fast reports several lines in
    /// one event, and a free-spinning one sends a burst after the hand has
    /// let go: without a pace, a flick ran the hours from 0 to 23. Shorter
    /// than the card wheel's own pace, because a number is often a long way
    /// from where it needs to be.
    public static let wheelInterval: TimeInterval = 0.05

    private var banked: Double = 0
    private var lastWheelStep: TimeInterval?

    public init() {}

    /// Forgets any travel short of a whole step. Called when the pointer
    /// moves to another number, which should start from nothing rather than
    /// from what the last one left over.
    public mutating func reset() {
        banked = 0
        lastWheelStep = nil
    }

    /// Feeds one wheel event, in points with up positive. Returns one step
    /// at most, and none sooner than `wheelInterval` after the last.
    ///
    /// Travel over the limit is dropped rather than banked, so a spin stops
    /// where the hand stops instead of catching up afterwards.
    public mutating func feedWheel(_ travel: Double, at timestamp: TimeInterval) -> Int {
        let steps = feed(travel, step: Self.wheelStep)
        guard steps != 0, timestamp.isFinite else { return 0 }
        if let last = lastWheelStep, abs(timestamp - last) < Self.wheelInterval {
            return 0
        }
        lastWheelStep = timestamp
        return steps > 0 ? 1 : -1
    }

    /// Feeds one movement, in points with up positive. Returns how many steps
    /// it completed: positive is up, negative is down, zero is not yet.
    public mutating func feed(_ travel: Double, step: Double) -> Int {
        guard travel.isFinite, step > 0 else { return 0 }
        // Turning back is a change of mind: whatever was banked the other way
        // is dropped, so the first notch back answers at once instead of
        // undoing the previous movement first.
        if travel != 0, banked != 0, (travel < 0) != (banked < 0) {
            banked = 0
        }
        banked += travel
        let steps = Int((banked / step).rounded(.towardZero))
        // The remainder is kept, so a trackpad's travel is not thrown away a
        // fraction at a time.
        banked -= Double(steps) * step
        return steps
    }
}
