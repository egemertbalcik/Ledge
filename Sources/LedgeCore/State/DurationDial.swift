import CoreGraphics
import Foundation

/// The arithmetic behind the timer's duration dial: where a drag lands, and
/// what the ruler is showing while it is under way.
///
/// Separated from the view because it is the part that can be wrong in ways a
/// screenshot will not show — an off-by-one at the ends, a drag that changes
/// the value at a different rate than the ruler moves under the marker, a
/// rounding rule that makes the number flicker between two minutes at the
/// midpoint. All of that is arithmetic, so it is tested arithmetic.
///
/// Pure and unit-free apart from points, like the other rules in this folder.
public enum DurationDial {

    /// What can be dialled. One minute is the shortest timer worth setting;
    /// three hours is past the point where anyone would rather type a number,
    /// and the chips cover the common lengths anyway.
    public static let range: ClosedRange<Int> = 1...180

    /// How far the ruler travels per minute.
    ///
    /// Six points puts a five-minute step 30 points apart — wide enough to
    /// label, close enough that an hour is a comfortable drag rather than a
    /// marathon. It is also the number the tick spacing is drawn at, so the
    /// value under the marker is exactly the tick under the marker.
    public static let pointsPerMinute: CGFloat = 6

    /// Every fifth minute takes a taller tick, and every thirtieth a label.
    public static let majorEvery = 5
    /// Every quarter of an hour carries a number. Half-hour marks left the
    /// rule with one label on screen at a time, which is not enough to know
    /// where you are without reading the big number instead.
    public static let labelEvery = 15

    public static func clamp(_ minutes: Int) -> Int {
        min(max(minutes, range.lowerBound), range.upperBound)
    }

    /// Where the dial sits mid-drag, in minutes, as a continuous value.
    ///
    /// Dragging left pulls the ruler left, which brings *larger* numbers under
    /// a fixed marker — the direction a physical dial would turn.
    ///
    /// - Parameters:
    ///   - anchor: the value the drag started from.
    ///   - translation: horizontal drag distance in points; negative leftwards.
    public static func position(anchor: Int, translation: CGFloat) -> CGFloat {
        let raw = CGFloat(anchor) - translation / pointsPerMinute
        return min(max(raw, CGFloat(range.lowerBound)), CGFloat(range.upperBound))
    }

    /// The whole minute a position reads as. Half-way rounds up, so the number
    /// changes as the marker crosses a tick rather than after it.
    public static func minutes(at position: CGFloat) -> Int {
        clamp(Int((position).rounded()))
    }

    /// The value a drag lands on, as one call.
    public static func minutes(anchor: Int, translation: CGFloat) -> Int {
        minutes(at: position(anchor: anchor, translation: translation))
    }

    /// "25 min", "1 hr", "1 hr 30 min" — spoken form, for the label under the
    /// number and for VoiceOver. The chips have their own compact form
    /// ("1h 30m"); this one is read aloud and reads badly abbreviated.
    public static func spoken(_ minutes: Int) -> String {
        let sane = clamp(minutes)
        let hours = sane / 60
        let rest = sane % 60
        switch (hours, rest) {
        case (0, let m): return "\(m) min"
        case (let h, 0): return h == 1 ? "1 hr" : "\(h) hr"
        case (let h, let m): return h == 1 ? "1 hr \(m) min" : "\(h) hr \(m) min"
        }
    }
}
