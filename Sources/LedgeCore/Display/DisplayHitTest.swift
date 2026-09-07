import CoreGraphics

/// Decides which display's overlay the cursor is on.
///
/// With one display this is the old inside/outside question. With several, the
/// answer has to name *which* one, because only the panel under the cursor may
/// stop being click-through — leaving every panel interactive would turn each
/// external display's full-width top strip into an invisible click-eater.
///
/// Pure and in `LedgeCore` so it can be tested without a `WindowServer`.
public enum DisplayHitTest {

    /// The cursor reads as a point above the screen's top edge when reaching for
    /// the notch, so every region gets a little vertical slack.
    public static let slack: CGFloat = 2

    /// - Parameters:
    ///   - point: the cursor, in global screen coordinates.
    ///   - current: the display whose overlay is already open, if any.
    ///   - currentOpenRegion: that overlay's *grown* region.
    ///   - closedRegions: every display's resting region, in test order.
    public static func hit<Key: Equatable>(
        point: CGPoint,
        current: Key?,
        currentOpenRegion: CGRect?,
        closedRegions: [(key: Key, rect: CGRect)]
    ) -> Key? {
        // Sticky first: an open overlay has grown well past its closed
        // footprint, and the cursor must be allowed to stay on it.
        if let current, let open = currentOpenRegion,
           open.insetBy(dx: 0, dy: -slack).contains(point) {
            return current
        }
        // Falling through to the closed scan in the same tick means moving from
        // one display's notch straight to another's is a single transition
        // rather than a detour through nil — so the overlay never flickers shut
        // in between.
        return closedRegions.first {
            $0.rect.insetBy(dx: 0, dy: -slack).contains(point)
        }?.key
    }
}
