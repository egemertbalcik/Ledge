import CoreGraphics
import Foundation

/// Dragging the timer's duration sideways to change it.
///
/// The card used to carry a separate instrument for this — chips, then a
/// button, then a ruler that appeared underneath. All of them were a second
/// control for a value already on the card. Now the value is the control: put
/// the pointer on it, drag sideways, let go.
///
/// A ruler could afford one minute per tick because it showed where the ticks
/// were. Without one, a linear rate has to choose between reaching three hours
/// in a sane distance and setting seven minutes precisely. So the rate is not
/// linear: the drag moves between *detents* whose spacing grows with the
/// number, the way a watch crown coarsens as the value gets large. Twenty-eight
/// detents cover the whole range in one comfortable sweep, and holding Option
/// swaps in a detent per minute for anything in between.
///
/// Pure and unit-free apart from points, like the rest of this folder — the
/// part that can be wrong in ways a screenshot will not show.
public enum DurationScrub {

    /// How far the pointer travels between two detents.
    ///
    /// Fourteen points is about a finger's worth of deliberate movement on a
    /// trackpad: small enough that the whole range is one sweep of the card's
    /// width, large enough that a hand resting on the glass does not change
    /// the number.
    public static let pointsPerDetent: CGFloat = 14

    /// The values a coarse drag stops on: every minute under ten, every fifth
    /// up to an hour, every quarter-hour beyond it.
    ///
    /// Under ten minutes a single minute is a large proportion of the timer, so
    /// it is worth a detent. At two hours it is noise, and stopping on it would
    /// cost the user a longer drag for a difference they did not ask for.
    public static let coarse: [Int] = {
        var values = Array(DurationDial.range.lowerBound..<10)
        values += stride(from: 10, through: 60, by: 5)
        values += stride(from: 75, through: DurationDial.range.upperBound, by: 15)
        return values
    }()

    /// Every minute in range — what Option gives you, for the values between
    /// the detents.
    public static let fine: [Int] = Array(DurationDial.range)

    public static func ladder(fine useFine: Bool) -> [Int] { useFine ? fine : coarse }

    /// The same two ladders over a different span.
    ///
    /// The dial's own range is the timer's, and Keep Awake runs to a day. Rather
    /// than widen a range the timer shares — which would put detents on its
    /// dial that nobody asked for — a caller with its own span supplies it
    /// here and gets the same stepping within it.
    public static func ladder(fine useFine: Bool, range: ClosedRange<Int>) -> [Int] {
        guard range != DurationDial.range else { return ladder(fine: useFine) }
        if useFine { return Array(range) }
        var values = Array(range.lowerBound ..< min(10, range.upperBound))
        values += stride(from: max(10, range.lowerBound), through: min(60, range.upperBound), by: 5)
        values += stride(from: 75, through: min(180, range.upperBound), by: 15)
        // Beyond three hours a quarter of an hour is noise; whole hours are
        // what anybody setting a keep-awake is actually choosing between.
        if range.upperBound > 180 {
            values += stride(from: 240, through: range.upperBound, by: 60)
        }
        return values.filter(range.contains)
    }

    /// Where a drag has landed, on a caller's own span.
    public static func minutes(
        anchor: Int, translation: CGFloat, fine useFine: Bool, range: ClosedRange<Int>
    ) -> Int {
        let values = ladder(fine: useFine, range: range)
        let clamp = { (value: Int) in min(max(value, range.lowerBound), range.upperBound) }
        guard translation.isFinite else { return clamp(anchor) }
        let steps = Int((translation / pointsPerDetent).rounded())
        guard steps != 0 else { return clamp(anchor) }
        var from = 0
        var best = Int.max
        for (index, value) in values.enumerated() {
            let distance = abs(value - clamp(anchor))
            if distance < best { best = distance; from = index }
        }
        return values[min(max(from + steps, 0), values.count - 1)]
    }

    /// Where a drag has landed.
    ///
    /// - Parameters:
    ///   - anchor: the value the drag started from. It need not be a detent —
    ///     a length that came from Option-dragging, or from a recent timer, is
    ///     kept exactly until the drag actually moves.
    ///   - translation: horizontal distance in points; rightwards is longer,
    ///     the direction every scrubber on the system moves.
    ///   - fine: Option held.
    public static func minutes(anchor: Int, translation: CGFloat, fine useFine: Bool) -> Int {
        guard translation.isFinite else { return DurationDial.clamp(anchor) }
        // Rounded, so the number changes as the pointer crosses the halfway
        // point between two detents rather than a whole detent later.
        let steps = Int((translation / pointsPerDetent).rounded())
        guard steps != 0 else { return DurationDial.clamp(anchor) }
        let values = ladder(fine: useFine)
        let from = nearestIndex(to: anchor, in: values)
        // Clamped at the index rather than at the value, so a drag that runs
        // past three hours and comes back is one detent down from three hours
        // — nothing is banked up while the number sits at the end.
        let landed = min(max(from + steps, 0), values.count - 1)
        return values[landed]
    }

    /// The detent nearest a value, for a drag that starts between two.
    public static func nearestIndex(to minutes: Int, in values: [Int]) -> Int {
        let target = DurationDial.clamp(minutes)
        var best = 0
        var bestDistance = Int.max
        for (index, value) in values.enumerated() {
            let distance = abs(value - target)
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }
}
