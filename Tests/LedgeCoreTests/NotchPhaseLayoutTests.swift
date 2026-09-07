import Foundation
import Testing

@testable import LedgeCore

@Suite("Phase layouts")
struct NotchPhaseLayoutTests {

    private let air = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 179, height: 32),
        notchCenterX: 735.5,
        isHardwareNotch: true
    )

    private func layout(_ phase: NotchPhase) -> NotchLayout {
        .layout(
            for: phase,
            geometry: air,
            expandedSize: CGSize(width: 420, height: 160),
            bottomRadius: 14,
            closedBottomRadius: 10,
            gutterRadius: 10
        )
    }

    @Test("Idle is smallest, expanded is largest, compact states sit between")
    func phasesGrowMonotonically() {
        let idle = layout(.idle).bodySize.width
        let peek = layout(.peek).bodySize.width
        let hud = layout(.hud).bodySize.width
        let expanded = layout(.expanded).bodySize.width

        // Idle matches the cutout, expanded is the full card, and the compact
        // effects sit between. Peek, HUD, and the companion deliberately share
        // one compact size, so peek == hud is expected; only the three tiers
        // (idle, compact, expanded) must be distinct.
        #expect(idle < peek)
        #expect(idle < hud)
        #expect(peek < expanded)
        #expect(hud < expanded)
        #expect(peek == hud, "the compact effects share one size")
        #expect(Set([idle, peek, expanded]).count == 3, "the three size tiers must be distinct")
    }

    @Test("Idle uses the closed corner radius, not the open one")
    func idleUsesClosedRadius() {
        // These are different numbers on real hardware; using the open radius
        // when closed is what makes the overlay look stuck on rather than part
        // of the machine.
        #expect(layout(.idle).bottomRadius == 10)
        #expect(layout(.expanded).bottomRadius == 14)
    }

    @Test("Idle matches the cutout exactly so the overlay is invisible at rest")
    func idleMatchesCutout() {
        #expect(layout(.idle).bodySize == air.notchSize)
    }

    @Test("Hover and expanded are the same size — only their persistence differs")
    func hoverMatchesExpanded() {
        #expect(layout(.hover).bodySize == layout(.expanded).bodySize)
    }

    @Test("The closed corner radius can never exceed half the cutout height")
    func closedRadiusClamped() {
        let clamped = NotchLayout.layout(
            for: .idle,
            geometry: air,
            expandedSize: CGSize(width: 420, height: 160),
            bottomRadius: 14,
            closedBottomRadius: 999,
            gutterRadius: 10
        )
        #expect(clamped.bottomRadius == air.notchSize.height / 2)
    }
}
