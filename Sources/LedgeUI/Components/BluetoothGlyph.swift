import LedgeCore
import SwiftUI

/// The Bluetooth rune, drawn.
///
/// SF Symbols has no Bluetooth glyph — the mark is a registered trademark and
/// Apple does not ship it in the set — so the alternatives are a stand-in that
/// means something else (radio waves, a lightning bolt) or the real thing,
/// drawn. It is a rune of five straight strokes: the bind of the Younger
/// Futhark ᚼ and ᛒ, Harald Bluetooth's initials. Five lines is less code than
/// the paragraph explaining why it is not a symbol.
///
/// There is no slashed variant. A strike drawn at the same weight over a mark
/// this dense stops reading as a strike and starts reading as a sixth stroke —
/// and it is not needed, because the far ear already says On or Off. The same
/// division of labour Caps Lock uses: identity on one side, state on the other.
struct BluetoothGlyph: View {

    /// Stroke weight as a fraction of the glyph's height.
    ///
    /// Proportional rather than fixed, because this sits beside SF Symbols and
    /// has to match their weight at whatever size it is drawn. A constant
    /// looked passable at one size and spindly at every other — and spindly
    /// beside a semibold `wifi` reads as a different, lesser thing.
    private static let weight: CGFloat = 0.12

    /// The mark is tall and narrow, but drawn *too* narrow it stops reading as
    /// itself at ear size: the two wings collapse towards the spine and the
    /// crossing disappears.
    private static let aspect: CGFloat = 0.68

    var body: some View {
        GeometryReader { proxy in
            Rune()
                .stroke(
                    style: StrokeStyle(
                        lineWidth: max(1.2, proxy.size.height * Self.weight),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
    }

    private struct Rune: Shape {

        func path(in rect: CGRect) -> Path {
            var path = Path()
            // One unbroken polyline, which is how the mark is actually drawn:
            // a wing from the left, across to the right, down to the foot of
            // the spine, up the spine to its head, out to the right again and
            // back to the left. The two wings cross each other at the spine's
            // middle — that crossing is what makes it read as Bluetooth
            // rather than as a scribble, and joining the wings to the wrong
            // ends of the spine loses it entirely.
            let w = rect.width
            let h = rect.height
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
            }

            path.move(to: point(0, 0.30))
            path.addLine(to: point(1, 0.70))
            path.addLine(to: point(0.5, 1))
            path.addLine(to: point(0.5, 0))
            path.addLine(to: point(1, 0.30))
            path.addLine(to: point(0, 0.70))
            return path
        }
    }
}
