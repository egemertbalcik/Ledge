import CoreGraphics
import Testing

@testable import LedgeCore

/// The app is tuned on one Mac and runs on five. These are the rules that keep
/// the other four from being an accident: the compact island never moves, the
/// cards make room for whatever cutout they are actually under, and a bigger
/// panel gets proportionally bigger cards.
@Suite("Display adaptation")
struct DisplayAdaptationTests {

    /// The Mac every number in `NotchLayout` was measured against.
    private func air13(scale: CGFloat = 1) -> NotchGeometry {
        NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: 735,
            isHardwareNotch: true,
            displayScale: scale
        )
    }

    /// A 14-inch Pro: taller cutout, barely wider panel.
    private func pro14() -> NotchGeometry {
        NotchGeometry(
            screenSize: CGSize(width: 1512, height: 982),
            notchSize: CGSize(width: 190, height: 38),
            notchCenterX: 756,
            isHardwareNotch: true,
            displayScale: 1.03
        )
    }

    private func card(_ geometry: NotchGeometry, kind: ActivityKind, weekRows: Int = 5) -> CGSize {
        NotchLayout.cardSize(
            kind: kind,
            phase: .expanded,
            base: CGSize(width: 420, height: 160),
            calendarWeekRows: weekRows,
            geometry: geometry,
            routePickerRows: 0,
            hasSelection: true
        )
    }

    @Test("A taller cutout does not eat into the card's content")
    func tallerCutoutGrowsTheCard() {
        // The 14-inch Pro's notch is six points taller. Without this the card
        // kept its height and the content lost those six points — the report
        // that started this: "the padding looks different on my Mac".
        let reference = card(air13(), kind: .weather)
        let pro = card(pro14(), kind: .weather)
        let cutout = pro14().notchSize.height - air13().notchSize.height

        // Six points for the cutout, then the panel scale on top.
        #expect(pro.height >= (reference.height + cutout) * 0.99)
    }

    @Test("The compact island is the hardware's, at every scale")
    func compactNeverScales() {
        for scale in [1.0, 1.03, 1.16, 1.20] as [CGFloat] {
            let geometry = air13(scale: scale)
            let peek = NotchLayout.peek(geometry, bottomRadius: 12, gutterRadius: 8)
            let hud = NotchLayout.hud(geometry, bottomRadius: 12, gutterRadius: 8)
            #expect(peek.bodySize.height == geometry.notchSize.height + NotchLayout.compactExtraHeight)
            #expect(hud.bodySize.height == geometry.notchSize.height + NotchLayout.compactExtraHeight)
        }
    }

    @Test("A bigger panel gets a proportionally bigger card")
    func biggerPanelBiggerCard() {
        let small = card(air13(), kind: .nowPlaying)
        let large = card(air13(scale: 1.18), kind: .nowPlaying)
        #expect(large.height > small.height)
        #expect(large.width > small.width)
        // Scaled, not doubled: the ratio follows the panel.
        #expect(large.height / small.height < 1.25)
    }

    @Test("The reference Mac is untouched")
    func referenceMacUnchanged() {
        // Every card on the machine these numbers came from must be exactly
        // what it was before any of this existed.
        let geometry = air13()
        // The floors, plus the ten points the dots band has always added to a
        // selected card. Exact numbers on purpose: this test exists to fail
        // the day the reference Mac's rendering moves by a point.
        #expect(card(geometry, kind: .nowPlaying).height == 174)
        #expect(card(geometry, kind: .levels).height == 170)
        #expect(card(geometry, kind: .weather).height == 200)
        #expect(card(geometry, kind: .event, weekRows: 5).width == NotchLayout.calendarWidth)
        #expect(NotchLayout.calendarHeight(weekRows: 5, notchHeight: 32) == NotchLayout.calendarHeight(weekRows: 5))
    }

    @Test("No card can be wider than the display it is drawn on")
    func neverWiderThanTheScreen() {
        let narrow = NotchGeometry(
            screenSize: CGSize(width: 800, height: 600),
            notchSize: CGSize(width: 179, height: 38),
            notchCenterX: 400,
            isHardwareNotch: true,
            displayScale: 1.20
        )
        for kind in [ActivityKind.nowPlaying, .event, .weather, .timer] {
            let size = card(narrow, kind: kind)
            let layout = NotchLayout.expanded(narrow, size: size, bottomRadius: 12, gutterRadius: 8)
            #expect(layout.bodySize.width <= narrow.screenSize.width)
        }
    }

    @Test("A nonsense scale is ignored rather than propagated")
    func scaleIsSanitised() {
        let broken = NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: 735,
            isHardwareNotch: true,
            displayScale: .nan
        )
        #expect(broken.displayScale == 1)
        #expect(card(broken, kind: .weather).height == 200)
    }
}
