import CoreGraphics
import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// The drawn shape and the region that answers the cursor are the same size,
/// because they are now the same call.
///
/// They were two identical ten-argument calls in two files — one in the view
/// that draws the card, one in the panel that decides where it responds. This
/// suite exists so that if anyone reintroduces a second copy, the sizes have to
/// be argued about here first.
@Suite("One card size, asked for twice")
@MainActor
struct CardSizingTests {

    private let geometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 179, height: 32),
        notchCenterX: 735,
        isHardwareNotch: true
    )

    private func presentation(_ configure: (NotchPresentation) -> Void = { _ in }) -> NotchPresentation {
        let presentation = NotchPresentation()
        configure(presentation)
        return presentation
    }

    private var preferences: Preferences { Preferences(store: MemoryPreferenceStore()) }

    @Test("The accessor is the layout's own answer, argument for argument")
    func matchesTheLayout() {
        let media = Activity(
            id: ActivityID(kind: .nowPlaying, source: "spotify"),
            createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(title: "Track", artist: "Artist"))
        )
        let presentation = presentation { $0.selected = media }
        let preferences = preferences

        for phase in [NotchPhase.hover, .expanded] {
            let asked = presentation.cardSize(
                preferences: preferences, geometry: geometry, phase: phase
            )
            let direct = NotchLayout.cardSize(
                kind: media.kind,
                phase: phase,
                base: CGSize(width: preferences.expandedWidth, height: preferences.expandedHeight),
                payload: media.payload,
                calendarWeekRows: presentation.calendarWeekRows,
                timerContentHeight: presentation.timerContentHeight,
                geometry: geometry,
                routePickerRows: presentation.routePickerRows,
                hasSelection: true
            )
            #expect(asked == direct)
        }
    }

    @Test("The readout's extra height follows the rows, and only while hovered")
    func readoutHeightFollowsItsRows() {
        let presentation = presentation {
            $0.hud = HUDReadout(kind: .volume, level: 0.5)
            $0.hudOutputs = [
                AudioOutputOption(id: 1, name: "MacBook Air Speakers", isCurrent: true, level: 0.5),
                AudioOutputOption(id: 2, name: "AirPods", isCurrent: false, level: 0.3),
                AudioOutputOption(id: 3, name: "Display", isCurrent: false, level: 0.7),
            ]
        }
        // Three routes, two of them extra rows.
        #expect(presentation.hudExtraHeight(hovered: true) == NotchLayout.hudFadedRowHeight * 2)
        // Not hovered, no rows: the caller's own guard decides that, and both
        // callers guard differently — which is exactly why it is a parameter.
        #expect(presentation.hudExtraHeight(hovered: false) == 0)
    }
}
