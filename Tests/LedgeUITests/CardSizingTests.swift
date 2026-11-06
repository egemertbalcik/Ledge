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
}

@Suite("Announcement interaction layout")
@MainActor
struct AnnouncementLayoutTests {
    @Test("The strip belongs to the shared drawing and hit region only while announcing")
    func stripIncluded() {
        let geometry = NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 180, height: 38),
            notchCenterX: 735, isHardwareNotch: true
        )
        let preferences = Preferences(store: MemoryPreferenceStore())
        let presentation = NotchPresentation()
        let compact = presentation.layout(preferences: preferences, geometry: geometry, phase: .peek)
        presentation.announcement = NotchAnnouncement(title: "Charging", symbolName: "bolt.fill")
        let announcing = presentation.layout(preferences: preferences, geometry: geometry, phase: .peek)
        #expect(announcing.boundingSize.height == compact.boundingSize.height + 38)
        #expect(announcing.boundingSize.width == compact.boundingSize.width)
        presentation.announcement = nil
        #expect(presentation.layout(preferences: preferences, geometry: geometry, phase: .peek) == compact)
    }
}
