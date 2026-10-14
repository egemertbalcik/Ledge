import Foundation

/// A length of time as the three numbers a person sets it with.
///
/// The card used to carry one number and one gesture, which worked while the
/// longest session was a day. Asking for three days out of a single minutes
/// ladder means dragging past four thousand of them, so the number is split
/// into the units it is actually thought in — and each one is set on its own.
///
/// Days, hours and minutes, not a free-form duration: the whole span is still
/// minutes underneath, and this is only how it is read and written.
public struct KeepAwakeSpan: Equatable, Sendable {

    public var days: Int
    public var hours: Int
    public var minutes: Int

    public init(days: Int, hours: Int, minutes: Int) {
        self.days = days
        self.hours = hours
        self.minutes = minutes
    }

    /// Splits a span into its parts without holding it to the floor.
    ///
    /// The boxes start empty and are filled in a number at a time, so while
    /// the question is open the span is routinely below anything that could
    /// be started. Clamping there would have the card type numbers back at
    /// the user.
    public init(unclamped totalMinutes: Int) {
        let total = max(0, min(totalMinutes, KeepAwakeReducer.maximumMinutes))
        days = total / (24 * 60)
        hours = (total % (24 * 60)) / 60
        minutes = total % 60
    }

    /// Splits a whole span into its parts.
    public init(totalMinutes: Int) {
        let clamped = KeepAwakeReducer.clamp(minutes: totalMinutes)
        days = clamped / (24 * 60)
        hours = (clamped % (24 * 60)) / 60
        minutes = clamped % 60
    }

    /// The span these three make, as they are — zero included.
    public var totalMinutes: Int {
        min(days * 24 * 60 + hours * 60 + minutes, KeepAwakeReducer.maximumMinutes)
    }

    /// The span a session would actually run for, held to the floor.
    public var startableMinutes: Int {
        KeepAwakeReducer.clamp(minutes: totalMinutes)
    }

    /// Whether there is anything here to start.
    public var isEmpty: Bool { totalMinutes == 0 }

    /// Which part a gesture is on.
    public enum Field: String, CaseIterable, Sendable {
        case days, hours, minutes

        /// What one detent moves this field by, in minutes.
        public var step: Int {
            switch self {
            case .days: 24 * 60
            case .hours: 60
            case .minutes: 1
            }
        }

        /// Spoken aloud, and used for the accessibility label.
        public var spokenName: String { rawValue }
    }

    /// This field's own number.
    public func value(of field: Field) -> Int {
        switch field {
        case .days: days
        case .hours: hours
        case .minutes: minutes
        }
    }

    /// Moves one field by whole steps and leaves the others where they are.
    ///
    /// Each field keeps to its own range rather than carrying into the next:
    /// dragging minutes past 59 rolling the hour over would move a number the
    /// pointer is not on, and the card would be changing something the user
    /// cannot see themselves changing. The whole span is clamped afterwards,
    /// so the ceiling still holds.
    public func moving(_ field: Field, by steps: Int) -> KeepAwakeSpan {
        guard steps != 0 else { return self }
        var next = self
        switch field {
        case .days: next.days = min(Self.maximumDays, max(0, days + steps))
        case .hours: next.hours = min(23, max(0, hours + steps))
        case .minutes: next.minutes = min(59, max(0, minutes + steps))
        }
        return KeepAwakeSpan(unclamped: next.totalMinutes)
    }

    public static var maximumDays: Int { KeepAwakeReducer.maximumMinutes / (24 * 60) }
}
