import CoreGraphics

/// A level readout standing in front of a card the pointer had open.
///
/// A volume, mute or brightness key over a hovered or pinned card swaps the
/// card for the readout until it times out, and the readout is a fraction of
/// the card's size. Measured against the readout alone, a pointer resting on
/// the card body below it had "left": the tracker reported an exit, the
/// reducer retired into an empty notch, and a pinned card was dismissed. And
/// a pointer resting inside the readout was judged against the closed notch,
/// called "never a hover", and the card was closed the same way. The pointer
/// had not moved at all; the card it was on simply went away.
///
/// Pure, so the rule can be checked against real layouts without a panel.
public enum ReadoutOverCard {

    /// Whether the readout is up in front of a card the pointer had open,
    /// rather than over the resting notch.
    public static func coversCard(_ state: NotchState) -> Bool {
        state.phase == .hud && (state.suspended == .hover || state.suspended == .expanded)
    }

    /// The region a pointer may rest in and still be on the notch: the
    /// readout, and the card it is standing in for.
    public static func trackingRegion(readout: CGRect?, card: CGRect?) -> CGRect? {
        switch (readout, card) {
        case let (readout?, card?): readout.union(card)
        case let (readout?, nil): readout
        case let (nil, card?): card
        case (nil, nil): nil
        }
    }

    /// Whether a readout held open under the pointer should hand the card
    /// back now: the pointer is on the card, not on the readout, so there is
    /// no slider being reached for and nothing to hold.
    public static func handsCardBack(pointer: CGPoint, readout: CGRect?, card: CGRect?) -> Bool {
        guard let card, contains(card, pointer) else { return false }
        guard let readout else { return true }
        return !contains(readout, pointer)
    }

    /// Whether a pointer parked since the key was pressed was resting on the
    /// card: a real hover, which the card must come back to.
    public static func restsOnCard(pointer: CGPoint, card: CGRect?) -> Bool {
        guard let card else { return false }
        return contains(card, pointer)
    }

    /// The hit test's own slack, so the edges agree with it.
    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        rect.insetBy(dx: 0, dy: -DisplayHitTest.slack).contains(point)
    }
}
