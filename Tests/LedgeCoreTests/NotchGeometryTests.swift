import Foundation
import Testing

@testable import LedgeCore

@Suite("Notch geometry and layout")
struct NotchGeometryTests {

    private let air = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 180, height: 32),
        notchCenterX: 735,
        isHardwareNotch: true
    )

    @Test("Closed layout matches the physical cutout exactly")
    func closedMatchesCutout() {
        let layout = NotchLayout.closed(air, bottomRadius: 14, gutterRadius: 10)
        #expect(layout.bodySize == air.notchSize)
    }

    @Test("Bounding size accounts for both gutters")
    func boundingIncludesGutters() {
        let layout = NotchLayout.closed(air, bottomRadius: 14, gutterRadius: 10)
        #expect(layout.boundingSize.width == air.notchSize.width + 20)
        #expect(layout.boundingSize.height == air.notchSize.height)
    }

    @Test("Expanded layout never runs off the screen edge")
    func expandedClampsToScreen() {
        let layout = NotchLayout.expanded(
            air,
            size: CGSize(width: 5000, height: 200),
            bottomRadius: 14,
            gutterRadius: 10
        )
        #expect(layout.boundingSize.width <= air.screenSize.width)
    }

    @Test("Expanded layout never shrinks below the cutout")
    func expandedNeverSmallerThanCutout() {
        let layout = NotchLayout.expanded(
            air,
            size: CGSize(width: 10, height: 5),
            bottomRadius: 14,
            gutterRadius: 10
        )
        #expect(layout.bodySize.width >= air.notchSize.width)
        #expect(layout.bodySize.height >= air.notchSize.height)
    }

    @Test("A display with no cutout gets a simulated pill centred on screen")
    func simulatedFallback() {
        let geometry = NotchGeometry.simulated(screenSize: CGSize(width: 2560, height: 1440))
        #expect(geometry.isHardwareNotch == false)
        #expect(geometry.notchCenterX == 1280)
        #expect(geometry.notchSize.height > 0)
    }
}

/// NaN radii from a corrupted defaults database must degrade to the cutout,
/// never poison the layout — min/max keep their first argument when a
/// comparison fails, so nothing downstream can repair it.
@Suite("Layout NaN hardening")
struct LayoutNaNTests {

    private let geometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 180, height: 32),
        notchCenterX: 735,
        isHardwareNotch: true
    )

    @Test("NaN radii yield a finite, non-degenerate layout in every phase")
    func nanRadiiDegrade() {
        for phase in [NotchPhase.idle, .peek, .hud, .companion, .hover, .expanded] {
            let layout = NotchLayout.layout(
                for: phase,
                geometry: geometry,
                expandedSize: CGSize(width: 420, height: 180),
                bottomRadius: .nan,
                closedBottomRadius: .nan,
                gutterRadius: .nan
            )
            #expect(layout.bodySize.width.isFinite && layout.bodySize.width >= geometry.notchSize.width)
            #expect(layout.bodySize.height.isFinite && layout.bodySize.height >= geometry.notchSize.height)
            #expect(layout.bottomRadius.isFinite && layout.bottomRadius >= 0)
            #expect(layout.gutterRadius.isFinite && layout.gutterRadius >= 0)
        }
    }
}


/// The adjustable ear width: clamped, NaN-proof, and restored after each
/// check so the shared static cannot bleed into other suites.
@Suite("Ear width", .serialized)
struct EarWidthTests {

    @Test("Set, clamp, and degrade")
    func setAndClamp() {
        defer { NotchLayout.setEarWidth(NotchLayout.defaultEarWidth) }
        NotchLayout.setEarWidth(70)
        #expect(NotchLayout.hudEarWidth == 70)
        #expect(NotchLayout.peekEarWidth == 70)
        NotchLayout.setEarWidth(10)
        #expect(NotchLayout.hudEarWidth == 36, "floored")
        NotchLayout.setEarWidth(500)
        #expect(NotchLayout.hudEarWidth == 90, "capped")
        NotchLayout.setEarWidth(.nan)
        #expect(NotchLayout.hudEarWidth == NotchLayout.defaultEarWidth, "NaN degrades")
    }

    @Test("The width discipline follows the ear width")
    func disciplineFollows() {
        defer { NotchLayout.setEarWidth(NotchLayout.defaultEarWidth) }
        let geometry = NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 180, height: 32),
            notchCenterX: 735,
            isHardwareNotch: true
        )
        NotchLayout.setEarWidth(60)
        let size = NotchLayout.cardSize(
            kind: .nowPlaying, phase: .hover,
            base: CGSize(width: 420, height: 160),
            geometry: geometry, routePickerRows: 0, hasSelection: true
        )
        #expect(abs(size.width - (300 + NotchLayout.openCardGrowth)) < 0.001)
    }
}
