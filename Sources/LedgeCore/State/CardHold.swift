import Foundation

/// Whether a card may hold the notch open.
///
/// A card that is being adjusted keeps the notch from closing under the
/// pointer, and keeps it for a moment afterwards: the hand lifts between two
/// drags of one adjustment, and the card used to vanish in that gap.
///
/// The rule that was missing is the one about *going away*. The timer card's
/// rule tells the card when a drag ends — and it also says so on the way out,
/// because tearing down a half-finished drag is the same act as finishing one.
/// The card took that as an adjustment ending and started a fresh grace, after
/// it had already been switched away from. The notch then stayed open for the
/// length of that grace over whatever card came next, which is exactly what it
/// looked like: leave the notch after seeing the timer, and it lingers.
///
/// Whether the card or its rule hears about the disappearance first is up to
/// SwiftUI and is not ordered, so both orders have to be safe: a hold taken
/// before the card knows it is gone is dropped when it finds out, and one
/// attempted afterwards is refused.
public struct CardHold: Equatable, Sendable {

    /// Whether the card is on screen. A card that has gone cannot take a hold.
    private var isOnscreen = true

    /// Whether a hold is currently taken.
    public private(set) var isHeld = false

    /// Whether the card has accepted the start of an adjustment and is still
    /// waiting for its matching end.
    public private(set) var isAdjusting = false

    public init() {}

    /// The card appeared, or came back.
    public mutating func appeared() {
        isOnscreen = true
    }

    /// The card went away.
    ///
    /// - Returns: true if a hold was being kept and must now be dropped.
    @discardableResult
    public mutating func disappeared() -> Bool {
        isOnscreen = false
        defer {
            isHeld = false
            isAdjusting = false
        }
        return isHeld
    }

    /// Accepts one balanced adjustment edge.
    ///
    /// A teardown can report `false` even when this card never saw `true`.
    /// That is cleanup, not a user interaction, and must not start a grace
    /// hold over the next card.
    @discardableResult
    public mutating func adjustmentChanged(to adjusting: Bool) -> Bool {
        guard isOnscreen, adjusting != isAdjusting else { return false }
        isAdjusting = adjusting
        return true
    }

    /// Something happened that is worth holding the notch for.
    ///
    /// - Returns: true if the hold should be taken. False once the card has
    ///   gone — the answer that stops a teardown from re-latching the notch.
    @discardableResult
    public mutating func hold() -> Bool {
        guard isOnscreen else { return false }
        isHeld = true
        return true
    }

    /// The hold is over: the gesture ended, or the card was dismissed.
    public mutating func release() {
        isHeld = false
        isAdjusting = false
    }
}
