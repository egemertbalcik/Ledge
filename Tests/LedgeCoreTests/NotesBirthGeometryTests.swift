import CoreGraphics
import Testing
@testable import LedgeCore

@Suite("Notes flight geometry")
struct NotesBirthGeometryTests {
    @Test("Landing stays near the corner and fits displays with different origins", arguments: [CGFloat(1), 1.03, 1.2])
    func landing(scale: CGFloat) {
        for offset in [CGPoint.zero, CGPoint(x: -1800, y: 250)] {
            let visible = CGRect(x: offset.x, y: offset.y, width: 1470, height: 923)
            let island = CGRect(x: offset.x + 590, y: visible.maxY - 200 * scale,
                                width: 280 * scale, height: 220 * scale)
            let target = NotesBirthGeometry.landing(island: island, visible: visible, scale: scale)
            #expect(visible.contains(target))
            #expect(abs(target.maxY - (island.minY - 16 * scale)) < 0.001)
            #expect(target.minX < island.maxX)
            let panel = CGRect(x: offset.x, y: offset.y + 956 - 800, width: 1470, height: 800)
            let local = NotesBirthGeometry.local(target, in: panel)
            #expect(local.maxY <= panel.height)
            #expect(local.minY == panel.maxY - target.maxY)
        }
    }

    @Test("Small desktops and edge notches keep the editor on screen")
    func smallScreens() {
        let visible = CGRect(x: -600, y: -250, width: 400, height: 350)
        for x in [visible.minX, visible.maxX] {
            let target = NotesBirthGeometry.landing(island: CGRect(x: x, y: 0, width: 100, height: 100), visible: visible)
            #expect(visible.contains(target))
            #expect(target.width > 0 && target.height > 0)
        }
    }

    @Test("The entire flight fits the reserved panel", arguments: [CGFloat(1), 1.03, 1.2])
    func fits(scale: CGFloat) {
        let geometry = NotchGeometry(screenSize: CGSize(width: 1470, height: 956),
                                     notchSize: CGSize(width: 179, height: 32), notchCenterX: 735,
                                     isHardwareNotch: true, displayScale: scale)
        let size = NotchLayout.panelSize(for: geometry)
        let panel = CGRect(x: 0, y: 956 - size.height, width: size.width, height: size.height)
        let source = CGRect(x: 590, y: 956 - 240 * scale, width: 280 * scale, height: 240 * scale)
        let island = NotesBirthGeometry.local(source, in: panel)
        let target = NotesBirthGeometry.local(NotesBirthGeometry.landing(
            island: source, visible: CGRect(x: 0, y: 0, width: 1470, height: 923), scale: scale), in: panel)
        let bounds = CGRect(origin: .zero, size: size)
        for i in 0...100 {
            let rect = NotesBirthGeometry.drop(at: Double(i) / 100, island: island, target: target, scale: scale)
            #expect(bounds.contains(rect), "clipped at \(i)% on scale \(scale)")
        }
    }

    @Test("Scaling preserves the liquid's proportions")
    func proportional() {
        let island = CGRect(x: 100, y: 0, width: 280, height: 220)
        let target = CGRect(x: 300, y: 250, width: 360, height: 420)
        let transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        for i in 0...100 {
            let t = Double(i) / 100
            let a = NotesBirthGeometry.drop(at: t, island: island, target: target, scale: 1).applying(transform)
            let b = NotesBirthGeometry.drop(at: t, island: island.applying(transform), target: target.applying(transform), scale: 1.2)
            #expect(abs(a.minX - b.minX) < 0.0001)
            #expect(abs(a.width - b.width) < 0.0001)
            #expect(abs(NotesBirthGeometry.sag(at: t, scale: 1) * 1.2 - NotesBirthGeometry.sag(at: t, scale: 1.2)) < 0.0001)
        }
    }

    @Test("Settling overshoots gently and lands exactly")
    func settling() {
        let island = CGRect(x: 100, y: 0, width: 280, height: 220)
        let target = CGRect(x: 280, y: 240, width: 360, height: 420)
        let samples = (85...99).map { NotesBirthGeometry.drop(at: Double($0) / 100, island: island, target: target, scale: 1) }
        #expect(samples.contains { $0.midY > target.midY })
        #expect(samples.allSatisfy { $0.midY < target.midY + 9 })
        #expect(NotesBirthGeometry.drop(at: 1, island: island, target: target, scale: 1) == target)
        // The corner gathers, then drains while the drop fills, and has
        // recovered by the end. Asserted as that shape rather than against a
        // fixed depth at a fixed moment — the old check pinned a magic number
        // to where the strand used to part and broke the moment that moved.
        let peak = stride(from: 0.0, through: 1.0, by: 0.01)
            .map { NotesBirthGeometry.sag(at: $0) }.max() ?? 0
        #expect(peak > 55, "the corner barely droops")
        let peakAt = stride(from: 0.0, through: 1.0, by: 0.01)
            .first { NotesBirthGeometry.sag(at: $0) >= peak - 0.01 } ?? 1
        #expect(peakAt < NotesBirthGeometry.snap, "the droop peaks after the strand parts")
        #expect(NotesBirthGeometry.sag(at: NotesBirthGeometry.snap) < peak,
                "the corner never gives any mass up")
        #expect(NotesBirthGeometry.sag(at: 1) == 0)
        #expect(NotesBirthGeometry.scale(.nan) == 1)
    }
}
