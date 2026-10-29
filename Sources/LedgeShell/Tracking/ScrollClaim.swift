/// Something under the pointer that takes scrolling for itself, and how.
///
/// Two controls do: the Keep Awake length's days, hours and minutes, which
/// scroll up and down, and the timer's open rule, which scrolls sideways.
public struct ScrollClaim {

    /// Which card made the claim. Only that card can take it back.
    public enum Owner: Equatable, Sendable {
        case keepAwakeLength
        case timerRule
    }

    /// The direction the control itself moves in.
    public enum Axis: Equatable, Sendable {
        /// Up and down. Sideways scrolling is left alone, so a trackpad swipe
        /// still moves between cards.
        case vertical
        /// Sideways, on a trackpad, for a stroke that begins on the control;
        /// vertical strokes are handed back. A wheel turns it either way.
        case horizontal
    }

    public let owner: Owner
    public let axis: Axis
    /// Whole steps, positive for more.
    public let step: (Int) -> Void

    public init(owner: Owner, axis: Axis, step: @escaping (Int) -> Void) {
        self.owner = owner
        self.axis = axis
        self.step = step
    }
}

/// The one claim in force, if any.
///
/// Cards claim on hover and give back on leaving or going away, and SwiftUI
/// does not order one card's teardown against the next card's arrival. Taken
/// at face value, a card going away would release the claim the card replacing
/// it had just made, and the scrolling would fall through to the cards behind
/// a control still under the pointer.
struct ScrollClaims {

    private(set) var current: ScrollClaim?

    /// A control under the pointer takes the scrolling, from whoever had it.
    mutating func claim(_ claim: ScrollClaim) {
        current = claim
    }

    /// The owner gives the scrolling back. True when that changed anything:
    /// a card can only give back what it holds.
    mutating func release(_ owner: ScrollClaim.Owner) -> Bool {
        guard current?.owner == owner else { return false }
        current = nil
        return true
    }

    /// Nothing is under the pointer any more. True when that changed
    /// anything.
    mutating func releaseAll() -> Bool {
        guard current != nil else { return false }
        current = nil
        return true
    }
}
