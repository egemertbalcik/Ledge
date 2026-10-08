import Foundation
import CoreGraphics

/// Geometry shared by the liquid silhouette, drop, editor placement and tests.
/// Coordinates here run down from the panel's top-left corner.
public enum NotesBirthGeometry {
    public static let duration: TimeInterval = 0.62
    /// Where the strand finally parts.
    ///
    /// Late, deliberately. The drop has to reach very nearly its full size
    /// *while still joined* — a neck that lets go early leaves a small blob
    /// inflating on its own for the rest of the flight, which reads as an
    /// appendage detaching and a window growing where it pointed, rather than
    /// as the card's own substance flowing out into one.
    public static let snap = 0.80
    public static let editorSize = CGSize(width: 360, height: 420)

    public static func scale(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(1.2, max(1, value)) : 1
    }

    public static func progress(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    public static func smooth(_ a: Double, _ b: Double, _ value: Double) -> CGFloat {
        let t = min(1, max(0, (progress(value) - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The deepest the corner ever hangs during a flight.
    ///
    /// The clip needs a shape that cannot cut the droop at any moment, and a
    /// clip that merely *contains* every frame is enough — it does not have to
    /// hug the silhouette. One fixed shape for the whole flight also keeps the
    /// stack from relaying out every frame.
    public static func peakSag(scale value: CGFloat = 1) -> CGFloat {
        66 * scale(value)
    }

    public static func sag(at t: Double, scale value: CGFloat = 1) -> CGFloat {
        // Gathers, then *drains*. The corner does not simply hold its droop and
        // snap back: it gives mass up steadily while the drop fills, so the
        // card is visibly the source of what is leaving it. It finishes
        // recovering only after the strand has parted.
        let gather = smooth(0, 0.22, t)
        let drain = 1 - 0.62 * smooth(0.26, snap, t)
        let recover = 1 - smooth(snap, 0.94, t)
        return 66 * scale(value) * gather * drain * recover
    }

    public static func origin(in island: CGRect, scale value: CGFloat) -> CGPoint {
        let s = scale(value)
        return CGPoint(x: island.maxX - 12 * s, y: island.maxY - 8 * s)
    }

    /// Inside the lobe, rather than its bounding box's corner. Both ends of
    /// the neck stay buried in their bodies while the waist parts.
    public static func lip(in island: CGRect, at t: Double, scale value: CGFloat) -> CGPoint {
        let hang = sag(at: t, scale: value)
        return CGPoint(x: island.maxX + hang * 0.30 - 6 * scale(value),
                       y: island.maxY + hang * 0.65 - 6 * scale(value))
    }

    /// A curved descent with a small, finite settling overshoot. The terminal
    /// sample is exactly the editor rect; no spring is still moving at handoff.
    public static func drop(at value: Double, island: CGRect, target: CGRect, scale rawScale: CGFloat) -> CGRect {
        let t = progress(value)
        if t >= 1 { return target }
        let s = scale(rawScale)
        let start = origin(in: island, scale: s)
        // Nearly full before the strand lets go, so what parts is already the
        // window rather than a bead that becomes one afterwards.
        let size = smooth(0.04, 0.84, t)
        let travel = smooth(0.06, 0.88, t)
        let u = 1 - pow(1 - travel, 3)
        let control = CGPoint(x: start.x + 55 * s, y: start.y + 150 * s)
        let inv = 1 - u
        let settle = smooth(snap, 1, t)
        let bounce = pow(sin(.pi * settle), 2)
        let w = 24 * s + (target.width - 24 * s) * size + 6 * s * bounce
        let h = 24 * s + (target.height - 24 * s) * size - 4 * s * bounce
        let x = inv * inv * start.x + 2 * inv * u * control.x + u * u * target.midX
        let y = inv * inv * start.y + 2 * inv * u * control.y + u * u * target.midY + 8 * s * bounce
        return CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
    }

    /// Screen coordinates (bottom-up). Place the note near the emitting
    /// corner, with a gap below it, and fit it to the visible desktop.
    public static func landing(island: CGRect, visible: CGRect, scale rawScale: CGFloat = 1) -> CGRect {
        let s = scale(rawScale)
        let margin = min(16 * s, min(visible.width, visible.height) / 4)
        let room = visible.insetBy(dx: margin, dy: margin)
        let size = CGSize(width: min(editorSize.width, room.width), height: min(editorSize.height, room.height))
        let x = min(max(island.midX + 24 * s, room.minX), room.maxX - size.width)
        let y = min(max(island.minY - 16 * s - size.height, room.minY), room.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    public static func local(_ screenRect: CGRect, in panel: CGRect) -> CGRect {
        CGRect(x: screenRect.minX - panel.minX, y: panel.maxY - screenRect.maxY,
               width: screenRect.width, height: screenRect.height)
    }
}
