import CoreGraphics
import Foundation

/// Where everything in the level readout goes.
///
/// The readout is one row under the cutout: the glyph at the left and a long
/// segmented bar beside it, drawn in a shape taller than the compact island.
/// Every number is the owner's approved value at the reference scale, and
/// multiplied by the display's scale here, so the proportions hold on every
/// Mac. Positions are from the body's own edges, gutters excluded, and heights
/// from the bottom of the cutout.
public struct HUDRowMetrics: Equatable, Sendable {

    /// The row's height in the shape, not counting `compactExtraHeight`.
    public static let rowHeight: CGFloat = 30

    /// The approved corner. The slider's default of 30 would otherwise come
    /// through whole: the expanded clamp is half the height, which the taller
    /// shape no longer reaches.
    public static let bottomRadius: CGFloat = 26

    public static let segmentCount = 16

    /// The tallest glyph rises 1.8 above the cutout's bottom edge. At the
    /// approved centre that is only ever near the cutout's rounded corner, and
    /// only once the ears are narrower than this does it get to go behind the
    /// hardware, so narrower ears move the row down by that much.
    public static let narrowEarWidth: CGFloat = 48
    static let rowCentre: CGFloat = 9.5
    static let narrowRowCentre: CGFloat = 11.8

    /// How far the Appearance slider may move the row. The slider itself goes
    /// to ±30, which was room to spare in the old ears and here would put the
    /// glyph in the corner or under the bar.
    public static let offsetRange: ClosedRange<CGFloat> = -8...10

    public let bodyWidth: CGFloat
    /// The row's centre line, below the cutout.
    public let centreY: CGFloat
    public let iconLeading: CGFloat
    /// Fixed and wider than any glyph, so the speaker's body stays where it is
    /// as waves appear beside it.
    public let iconSlotWidth: CGFloat
    public let iconSize: CGFloat
    public let barLeading: CGFloat
    public let barWidth: CGFloat
    public let barHeight: CGFloat
    /// The top of the bar, below the cutout.
    public let barTop: CGFloat
    public let segmentGap: CGFloat
    public let innerCornerRadius: CGFloat
    /// The row's whole height, from the cutout to the bottom of the shape.
    public let height: CGFloat

    /// - Parameter earWidth: the ears this row hangs from, unscaled. Defaults
    ///   to the current setting, as `NotchLayout.cardWidth` does.
    public init(
        geometry: NotchGeometry,
        bodyWidth: CGFloat,
        contentOffset: CGFloat = 0,
        earWidth: CGFloat? = nil
    ) {
        let scale = geometry.displayScale
        let earIsNarrow = NotchLayout.earWidth(for: geometry, earWidth) < Self.narrowEarWidth * scale
        // A stored preference is only bounded by its slider, and NaN in an
        // offset draws the content off-screen or not at all.
        let offset = contentOffset.isFinite
            ? min(max(contentOffset, Self.offsetRange.lowerBound), Self.offsetRange.upperBound) * scale
            : 0
        let barHeight = 5 * scale
        let centre = (earIsNarrow ? Self.narrowRowCentre : Self.rowCentre) * scale
        let barLeading = (60 * scale + offset)
        let trailingMargin = 27 * scale + offset

        self.bodyWidth = bodyWidth
        self.centreY = centre
        self.iconLeading = 14.6 * scale + offset
        self.iconSlotWidth = 40 * scale
        self.iconSize = 22 * scale
        self.barLeading = HUDSegments.snapped(barLeading)
        self.barWidth = max(0, HUDSegments.snapped(bodyWidth - barLeading - trailingMargin))
        self.barHeight = barHeight
        self.barTop = HUDSegments.snapped(centre - barHeight / 2)
        self.segmentGap = 1 * scale
        self.innerCornerRadius = 0.5 * scale
        self.height = (Self.rowHeight * scale) + NotchLayout.compactExtraHeight
    }

    /// The level a point in the row stands for. Past either end of the bar it
    /// is that end, so a drag can run off the bar and still arrive there.
    public func level(atRowX x: CGFloat) -> Double? {
        guard barWidth > 0, x.isFinite else { return nil }
        return Double(min(max((x - barLeading) / barWidth, 0), 1))
    }
}

/// Which display a brightness row acts on.
public enum HUDRowDisplay {

    /// The display the row is showing the level of, while it can still be set.
    ///
    /// Not simply the one under the pointer. A brightness key pressed with the
    /// pointer on an external monitor shows that monitor's level in the notch,
    /// and reaching the notch moves the pointer onto the built-in screen, so
    /// the drag changed a screen other than the one the bar was showing.
    public static func target(shown: UInt32?, underCursor: UInt32?, available: [UInt32]) -> UInt32? {
        if let shown, available.contains(shown) { return shown }
        return underCursor
    }
}

/// The bar's segments, as rectangles.
///
/// Sixteen segments across a bar this size come to about 11.19 points each,
/// which does not land on pixels, and left to fractional frames the gaps
/// visibly differ from one another. So every edge is snapped here and the gaps
/// come out exactly equal; it is the segments that differ, by a pixel at most,
/// which nobody can see.
public enum HUDSegments {

    /// Every Mac with a notch draws at two pixels to the point.
    static let pixelsPerPoint: CGFloat = 2

    static func snapped(_ value: CGFloat) -> CGFloat {
        (value * pixelsPerPoint).rounded() / pixelsPerPoint
    }

    /// All the segments, left to right, filling `size` exactly.
    public static func rects(
        in size: CGSize,
        count: Int = HUDRowMetrics.segmentCount,
        gap: CGFloat
    ) -> [CGRect] {
        guard count > 0, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0
        else { return [] }
        let gap = max(0, gap.isFinite ? snapped(gap) : 0)
        let pitch = (size.width + gap) / CGFloat(count)
        return (0..<count).map { index in
            let start = snapped(CGFloat(index) * pitch)
            let end = index == count - 1 ? size.width : snapped(CGFloat(index + 1) * pitch) - gap
            return CGRect(x: start, y: 0, width: max(0, end - start), height: size.height)
        }
    }

    /// The lit part of each segment, at a level, in order from the left.
    ///
    /// A level between two segments cuts through the one it lands in: a drag,
    /// an external display's brightness and a non-default step can all land
    /// there, and rounding would show a level that isn't the real one.
    ///
    /// Each segment is clamped on its own, and that is what keeps the level
    /// spring's overshoot inside the bar at both ends.
    public static func lit(level: Double, in rects: [CGRect]) -> [CGRect] {
        guard level.isFinite, !rects.isEmpty else { return [] }
        let reach = level * Double(rects.count)
        return rects.enumerated().compactMap { index, rect in
            let fraction = min(max(reach - Double(index), 0), 1)
            guard fraction > 0 else { return nil }
            var cut = rect
            cut.size.width = rect.width * fraction
            return cut
        }
    }
}

/// Which spring the shape takes as a readout comes and goes.
public enum ReadoutShapeMotion: Equatable, Sendable {
    /// The real readout's timing, on its way in.
    case arriving
    case leaving
    /// The ordinary open-and-close spring. A whole card collapsing in an
    /// eighth of a second to make room for a volume bar would be violent, and
    /// nothing in the footage this is matched to does that.
    case ordinary

    public init(from previous: NotchPhase, to phase: NotchPhase) {
        let compact: (NotchPhase) -> Bool = { $0 == .idle || $0 == .companion || $0 == .peek }
        if phase == .hud, compact(previous) {
            self = .arriving
        } else if previous == .hud, compact(phase) {
            self = .leaving
        } else {
            self = .ordinary
        }
    }
}
