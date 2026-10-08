import LedgeCore
import SwiftUI

/// One flight, frozen in the emitting panel's coordinates. Display identity
/// keeps the shared presentation from drawing the same flight on every Mac.
public struct NotesBirth: Equatable, Sendable {
    public var to: CGRect
    public var cornerRadius: CGFloat
    public var token: Int
    public var startedAt: Date
    public var displayScale: CGFloat
    public var displayID: UInt32?
    public var islandRect: CGRect?
    public var sourceLayout: NotchLayout?

    public init(to: CGRect, cornerRadius: CGFloat = 14, token: Int, startedAt: Date = Date(),
                displayScale: CGFloat = 1, displayID: UInt32? = nil,
                islandRect: CGRect? = nil, sourceLayout: NotchLayout? = nil) {
        self.to = to
        self.cornerRadius = cornerRadius
        self.token = token
        self.startedAt = startedAt
        self.displayScale = NotesBirthGeometry.scale(displayScale)
        self.displayID = displayID
        self.islandRect = islandRect
        self.sourceLayout = sourceLayout
    }

    public static let duration = NotesBirthGeometry.duration
    public func progress(at date: Date) -> Double {
        NotesBirthGeometry.progress(date.timeIntervalSince(startedAt) / Self.duration)
    }
}

/// A real, two-sided neck, softened at its joins. Fixed-progress rendering
/// runs exactly the same Canvas as playback, without a wall-clock race.
struct NotesBirthView: View {
    let birth: NotesBirth
    let islandRect: CGRect
    let tint: Color
    var fixedProgress: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var island: CGRect { birth.islandRect ?? islandRect }
    private var scale: CGFloat { birth.displayScale }

    var body: some View {
        Group {
            if let fixedProgress {
                frame(at: NotesBirthGeometry.progress(fixedProgress))
            } else if reduceMotion {
                frame(at: 1)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
                    frame(at: birth.progress(at: timeline.date))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func frame(at t: Double) -> some View {
        Canvas { context, _ in
            let blur = 8 * scale * (1 - NotesBirthGeometry.smooth(0.38, 0.84, t))
            context.addFilter(.alphaThreshold(min: 0.42, color: tint))
            if blur > 0.01 { context.addFilter(.blur(radius: blur)) }
            context.drawLayer { layer in
                let rect = rectForTesting(progress: t)
                if let neck = neck(at: t, blob: rect) {
                    layer.fill(neck, with: .color(.white))
                }
                layer.fill(Path(roundedRect: rect, cornerRadius: radius(at: t, in: rect), style: .continuous),
                           with: .color(.white))
            }
        }
    }

    static let snap = NotesBirthGeometry.snap
    static func sag(at t: Double, scale: CGFloat = 1) -> CGFloat {
        NotesBirthGeometry.sag(at: t, scale: scale)
    }

    /// Two cubic halves meet AT the waist. Positive interpolated offsets on
    /// either side of the centreline cannot cross, even with unequal ends.
    /// Unlike a single quadratic, this reaches the requested waist exactly.
    func neck(at t: Double, blob: CGRect) -> Path? {
        guard t < Self.snap else { return nil }
        let start = NotesBirthGeometry.lip(in: island, at: t, scale: scale)
        let end = CGPoint(x: blob.midX, y: blob.midY)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > scale else { return nil }
        let px = -dy / length, py = dx / length
        // The waist thins from early on; the two ends keep their body until
        // late. Thinning the whole band together made a rope — a string between
        // two objects — where this wants to be a column of the card's own
        // substance that narrows as it drains and only gives way at the end.
        let collapse = NotesBirthGeometry.smooth(0.22, Self.snap, t)
        let endFade = NotesBirthGeometry.smooth(0.56, Self.snap, t)
        let swell = Self.sag(at: t, scale: scale) / (66 * scale)
        // Wide enough to read as the corner itself being drawn out. At a
        // seventeen-point half-width this was a thirty-four-point thread
        // against a card nearly three hundred wide.
        let anchor = 32 * scale * max(swell, 0.52)
        let recoil = 1 - 0.78 * endFade
        let a = anchor * 0.86 * recoil
        let b = min(a * 1.5, min(blob.width, blob.height) * 0.34 * recoil)
        let waist = min(a, b) * 0.64 * (1 - collapse)
        func point(_ u: CGFloat, _ width: CGFloat) -> CGPoint {
            CGPoint(x: start.x + dx * u + px * width, y: start.y + dy * u + py * width)
        }
        var path = Path()
        path.move(to: point(0, a))
        path.addCurve(to: point(0.5, waist), control1: point(0.18, a), control2: point(0.34, waist))
        path.addCurve(to: point(1, b), control1: point(0.66, waist), control2: point(0.82, b))
        path.addLine(to: point(1, -b))
        path.addCurve(to: point(0.5, -waist), control1: point(0.82, -b), control2: point(0.66, -waist))
        path.addCurve(to: point(0, -a), control1: point(0.34, -waist), control2: point(0.18, -a))
        path.closeSubpath()
        return path
    }

    func hasNeckForTesting(progress: Double) -> Bool {
        neck(at: progress, blob: rectForTesting(progress: progress)) != nil
    }

    private func radius(at t: Double, in rect: CGRect) -> CGFloat {
        let roundness = 1 - NotesBirthGeometry.smooth(0.42, 0.88, t)
        return birth.cornerRadius + (min(rect.width, rect.height) / 2 - birth.cornerRadius) * roundness
    }

    func rectForTesting(progress: Double) -> CGRect {
        NotesBirthGeometry.drop(at: progress, island: island, target: birth.to, scale: scale)
    }

    func radiusForTesting(progress: Double) -> CGFloat {
        radius(at: progress, in: rectForTesting(progress: progress))
    }
}
