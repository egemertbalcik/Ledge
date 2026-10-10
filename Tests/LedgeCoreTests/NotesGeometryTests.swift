import CoreGraphics
import Testing
@testable import LedgeCore

@Suite("Notes window placement")
struct NotesGeometryTests {
    @Test("Landing stays near the corner and fits displays with different origins", arguments: [CGFloat(1), 1.03, 1.2])
    func landing(scale: CGFloat) {
        for offset in [CGPoint.zero, CGPoint(x: -1800, y: 250)] {
            let visible = CGRect(x: offset.x, y: offset.y, width: 1470, height: 923)
            let island = CGRect(x: offset.x + 590, y: visible.maxY - 200 * scale,
                                width: 280 * scale, height: 220 * scale)
            let target = NotesGeometry.landing(island: island, visible: visible, scale: scale)
            #expect(visible.contains(target))
            #expect(abs(target.maxY - (island.minY - 16 * scale)) < 0.001)
            #expect(target.minX < island.maxX)
            let panel = CGRect(x: offset.x, y: offset.y + 956 - 800, width: 1470, height: 800)
            let local = NotesGeometry.local(target, in: panel)
            #expect(local.maxY <= panel.height)
            #expect(local.minY == panel.maxY - target.maxY)
        }
    }

    @Test("Small desktops and edge notches keep the editor on screen")
    func smallScreens() {
        let visible = CGRect(x: -600, y: -250, width: 400, height: 350)
        for x in [visible.minX, visible.maxX] {
            let target = NotesGeometry.landing(island: CGRect(x: x, y: 0, width: 100, height: 100), visible: visible)
            #expect(visible.contains(target))
            #expect(target.width > 0 && target.height > 0)
        }
    }

    @Test("The window fits the panel the notch reserves", arguments: [CGFloat(1), 1.03, 1.2])
    func fits(scale: CGFloat) {
        let geometry = NotchGeometry(screenSize: CGSize(width: 1470, height: 956),
                                     notchSize: CGSize(width: 179, height: 32), notchCenterX: 735,
                                     isHardwareNotch: true, displayScale: scale)
        let size = NotchLayout.panelSize(for: geometry)
        let panel = CGRect(x: 0, y: 956 - size.height, width: size.width, height: size.height)
        let island = CGRect(x: 735 - 140, y: 956 - 220, width: 280, height: 220)
        let visible = CGRect(x: 0, y: 0, width: 1470, height: 923)
        let local = NotesGeometry.local(
            NotesGeometry.landing(island: island, visible: visible, scale: scale), in: panel)
        #expect(local.minY >= 0)
        #expect(local.minX >= 0)
        #expect(local.maxX <= panel.width)
    }
}
