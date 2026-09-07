import CoreGraphics
import SwiftUI

/// Apple's *continuous* corner — the "squircle" used by
/// `RoundedRectangle(style: .continuous)` and by the Dynamic Island — as a
/// reusable path fragment.
///
/// One corner is a ramp-in cubic, a real circular arc, and a ramp-out cubic,
/// following Figma's "Desperately Seeking Squircles" derivation. It is emphatically
/// *not* a single bezier with the control points pulled in: that approximation is
/// what makes a corner read as a chevron at large radii.
///
/// Kept as its own unit so the construction is testable on its own, and so a
/// second shape (there was once a notchless pill) could never drift from it.
enum ContinuousCorner {

    /// How far from the corner vertex the shape stops being straight, for a
    /// given radius and smoothing. Callers need this to know where to end the
    /// straight edge that precedes the corner.
    static func reach(radius: CGFloat, smoothing: CGFloat) -> CGFloat {
        (1 + max(0, min(1, smoothing))) * radius
    }

    /// Appends one corner. The current point must already sit at
    /// `vertex - inDir * reach`, and afterwards it sits at `vertex + outDir * reach`.
    ///
    /// - Parameters:
    ///   - inDir: unit vector along the incoming edge, pointing at the vertex.
    ///   - outDir: unit vector along the outgoing edge, pointing away from it.
    static func append(
        to path: inout Path,
        vertex: CGPoint,
        inDir: CGVector,
        outDir: CGVector,
        radius: CGFloat,
        smoothing: CGFloat
    ) {
        let s = max(0, min(1, smoothing))
        let reach = reach(radius: radius, smoothing: s)
        guard radius > 0, reach > 0 else {
            path.addLine(to: vertex)
            return
        }

        let d2r = CGFloat.pi / 180

        // Segment lengths, per the figma-squircle construction.
        let arcMeasure = 90 * (1 - s)                          // degrees of true arc
        let arcLen = sin(arcMeasure / 2 * d2r) * radius * sqrt(2)
        let angleAlpha = (90 - arcMeasure) / 2
        let p3p4 = radius * tan(angleAlpha / 2 * d2r)
        let angleBeta = 45 * s
        let c = p3p4 * cos(angleBeta * d2r)
        let d = c * tan(angleBeta * d2r)
        let b = max(0, (reach - arcLen - c - d) / 3)
        let a = 2 * b

        // Local frame: origin at the vertex, x along `inDir`, y along `outDir`.
        func place(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: vertex.x + inDir.dx * x + outDir.dx * y,
                y: vertex.y + inDir.dy * x + outDir.dy * y
            )
        }

        // Ramp in, hugging the incoming edge.
        let p2 = CGPoint(x: -reach + a + b + c, y: d)
        path.addCurve(
            to: place(p2.x, p2.y),
            control1: place(-reach + a, 0),
            control2: place(-reach + a + b, 0)
        )

        // The circular arc, as one cubic — its sweep is only `arcMeasure`
        // degrees, where a single cubic is exact to well under a pixel.
        let p3 = CGPoint(x: p2.x + arcLen, y: p2.y + arcLen)
        let center = CGPoint(x: -radius, y: radius)
        let k = (4.0 / 3.0) * tan(arcMeasure / 4 * d2r)
        let chord = CGVector(dx: p3.x - p2.x, dy: p3.y - p2.y)

        func tangent(at point: CGPoint) -> CGVector {
            let radial = CGVector(dx: point.x - center.x, dy: point.y - center.y)
            let candidate = CGVector(dx: -radial.dy, dy: radial.dx)
            let dot = candidate.dx * chord.dx + candidate.dy * chord.dy
            let directed = dot >= 0 ? candidate : CGVector(dx: -candidate.dx, dy: -candidate.dy)
            let length = max(0.0001, (directed.dx * directed.dx + directed.dy * directed.dy).squareRoot())
            return CGVector(dx: directed.dx / length, dy: directed.dy / length)
        }

        let t2 = tangent(at: p2)
        let t3 = tangent(at: p3)
        path.addCurve(
            to: place(p3.x, p3.y),
            control1: place(p2.x + t2.dx * k * radius, p2.y + t2.dy * k * radius),
            control2: place(p3.x - t3.dx * k * radius, p3.y - t3.dy * k * radius)
        )

        // Ramp out, easing onto the outgoing edge.
        path.addCurve(
            to: place(0, reach),
            control1: place(p3.x + d, p3.y + c),
            control2: place(p3.x + d, p3.y + b + c)
        )
    }
}
