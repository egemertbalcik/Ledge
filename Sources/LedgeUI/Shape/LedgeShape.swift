import CoreGraphics
import SwiftUI

/// The notch silhouette: a downward-hanging rounded body whose top corners flare
/// *outward* into the screen bezel, so the drawn shape reads as a continuation
/// of the physical cutout rather than a rectangle sitting under it.
///
/// The two bottom corners — the ones that actually read as the hanging island —
/// are drawn with Apple's *continuous* corner (the "squircle" used by
/// `RoundedRectangle(style: .continuous)` and the Dynamic Island), not a plain
/// circular arc. Each such corner is a ramp-in cubic, a real circular arc, and a
/// ramp-out cubic, following Figma's "Desperately Seeking Squircles" derivation.
///
/// The rect passed in includes both gutters. The body spans
/// `[minX + gutterRadius, maxX - gutterRadius]`; the gutters are the two
/// inverted corners either side of it.
public struct LedgeShape: Shape {

    /// Radius of the two bottom corners.
    public var bottomRadius: CGFloat

    /// Radius of the inverted flare where the body meets the screen edge.
    public var gutterRadius: CGFloat

    /// 0 = a true circular arc, 1 = a strongly continuous "squircle" corner.
    /// iOS's Dynamic Island sits around 0.6 — a gentle continuous corner, not a
    /// plain circle. Exposed as a slider because it has to be eyeballed against
    /// the real bezel.
    public var cornerSmoothing: CGFloat

    /// Pulls the shape's right edge in by this many points, leaving the rest of
    /// the silhouette untouched — the asymmetric split while the satellite is
    /// out. Inseting the *path* rather than the frame is what keeps the left
    /// edge and the cutout pixel-anchored: nothing else in the layout moves.
    public var trailingInset: CGFloat

    public init(
        bottomRadius: CGFloat,
        gutterRadius: CGFloat,
        cornerSmoothing: CGFloat = 0.6,
        trailingInset: CGFloat = 0
    ) {
        self.bottomRadius = bottomRadius
        self.gutterRadius = gutterRadius
        self.cornerSmoothing = cornerSmoothing
        self.trailingInset = trailingInset
    }

    /// Animating the radii alongside the frame keeps the corners from popping
    /// when the shape stretches; the trailing inset animates so the split's
    /// collapse is a spring, not a jump.
    public var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(bottomRadius, gutterRadius), trailingInset) }
        set {
            bottomRadius = newValue.first.first
            gutterRadius = newValue.first.second
            trailingInset = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()

        // The split simply narrows the rect the silhouette is drawn in.
        let inset = max(0, min(trailingInset, rect.width / 2))
        let rect = CGRect(
            x: rect.minX, y: rect.minY,
            width: rect.width - inset, height: rect.height
        )

        // Clamped against the height as well as the width. The gutter flare
        // descends `g` from the top edge, so a gutter taller than the shape
        // would put the body's top *below* the rect and the silhouette would
        // paint outside its own panel. Not reachable from the settings slider
        // at any real notch size, but the shape is drawn at every size between
        // closed and expanded and should not depend on that.
        let g = max(0, min(gutterRadius, min(rect.width / 2, rect.height)))
        let bodyLeft = rect.minX + g
        let bodyRight = rect.maxX - g
        let top = rect.minY
        let bottom = rect.maxY

        let smoothing = max(0, min(1, cornerSmoothing))

        // Budget: the bottom edge is shared by both corners, so each may claim at
        // most half of it; the side edges run from the gutter down to the corner.
        let sideEdge = max(0, bottom - (top + g))
        let halfBottom = max(0, (bodyRight - bodyLeft) / 2)
        let budget = min(sideEdge, halfBottom)

        // Keeping the reach `p = (1+s)R` within budget guarantees the ramp
        // "wings" never go negative and the shape never self-intersects, at any
        // size from the closed pill to the full expanded card.
        let radius = max(0, min(bottomRadius, budget / (1 + smoothing)))
        let reach = ContinuousCorner.reach(radius: radius, smoothing: smoothing)

        // Gutter flares keep a simple cubic — they are inverted notch joins, not
        // the island corners, so the continuous treatment would be wasted there.
        let gs: CGFloat = 0.55

        path.move(to: CGPoint(x: rect.minX, y: top))

        // Top-left gutter: flares out and up into the bezel.
        path.addCurve(
            to: CGPoint(x: bodyLeft, y: top + g),
            control1: CGPoint(x: rect.minX + g * gs, y: top),
            control2: CGPoint(x: bodyLeft, y: top + g * gs)
        )

        // Down the left edge to where the bottom-left corner begins.
        path.addLine(to: CGPoint(x: bodyLeft, y: bottom - reach))
        ContinuousCorner.append(
            to: &path,
            vertex: CGPoint(x: bodyLeft, y: bottom),
            inDir: CGVector(dx: 0, dy: 1),
            outDir: CGVector(dx: 1, dy: 0),
            radius: radius, smoothing: smoothing
        )

        // Across the bottom to where the bottom-right corner begins.
        path.addLine(to: CGPoint(x: bodyRight - reach, y: bottom))
        ContinuousCorner.append(
            to: &path,
            vertex: CGPoint(x: bodyRight, y: bottom),
            inDir: CGVector(dx: 1, dy: 0),
            outDir: CGVector(dx: 0, dy: -1),
            radius: radius, smoothing: smoothing
        )

        // Up the right edge to the top-right gutter.
        path.addLine(to: CGPoint(x: bodyRight, y: top + g))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: top),
            control1: CGPoint(x: bodyRight, y: top + g * gs),
            control2: CGPoint(x: rect.maxX - g * gs, y: top)
        )

        path.closeSubpath()
        return path
    }

}
