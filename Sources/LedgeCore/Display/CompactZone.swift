import CoreGraphics

/// Which part of the resting island the cursor is over.
///
/// The ears are one hover surface but not one subject: while a duo rests —
/// music in the island, a level readout or a timer in the satellite seat —
/// the trailing side belongs to the satellite's own card and everywhere else
/// belongs to the resident's. The zones split at the hardware cutout's edges,
/// so the boundary the user perceives (art | notch | readout) is exactly the
/// boundary that decides.
public enum CompactZone: Equatable, Sendable {
    case leading
    case cutout
    case trailing
}

extension NotchLayout {

    /// Zones a pointer x-position against a resting island rect.
    ///
    /// The cutout is centred in the rect (the resting shape grows symmetric
    /// ears around the hardware notch). Non-finite input answers `.cutout` —
    /// the neutral zone that opens the main card — and a cutout wider than
    /// the rect degenerates to the same answer for every point inside it.
    public static func compactZone(
        x: CGFloat,
        restingRect: CGRect,
        cutoutWidth: CGFloat
    ) -> CompactZone {
        guard x.isFinite, restingRect.width.isFinite, cutoutWidth.isFinite else { return .cutout }
        let half = max(0, cutoutWidth) / 2
        if x < restingRect.midX - half { return .leading }
        if x > restingRect.midX + half { return .trailing }
        return .cutout
    }
}
