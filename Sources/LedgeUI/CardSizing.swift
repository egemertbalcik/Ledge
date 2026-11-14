import CoreGraphics
import LedgeCore
import SwiftUI

/// The size of the open card.
///
/// This used to be written out twice, in the view that *draws* the shape and in
/// the panel that decides where the shape *responds* — the same arithmetic, kept
/// in step by hand. A card drawn one size and clicked at another is the failure
/// that costs, so there is one now and both callers ask for it.
extension NotchPresentation {

    /// Shared drawing and interaction geometry, including temporary announcements.
    public func layout(
        preferences: Preferences,
        geometry: NotchGeometry,
        phase: NotchPhase
    ) -> NotchLayout {
        NotchLayout.layout(
            for: phase, geometry: geometry,
            expandedSize: cardSize(preferences: preferences, geometry: geometry, phase: phase),
            bottomRadius: preferences.bottomRadius,
            closedBottomRadius: preferences.closedBottomRadius,
            gutterRadius: preferences.gutterRadius,
            isAnnouncing: announcement != nil,
            // A device's stand-up is sized to what it says; see
            // `DeviceAnnouncementMetrics`.
            announceContent: announcement.flatMap {
                $0.style == .device
                    ? DeviceAnnouncementMetrics.size(for: $0, bottomRadius: preferences.bottomRadius)
                    : nil
            }
        )
    }

    /// The size the open card wants, for a phase.
    ///
    /// The panel asks for a phase it is about to move to; the view asks for
    /// the one it is in. Everything else comes from here.
    public func cardSize(
        preferences: Preferences,
        geometry: NotchGeometry,
        phase: NotchPhase
    ) -> CGSize {
        NotchLayout.cardSize(
            kind: selected?.kind,
            phase: phase,
            base: CGSize(width: preferences.expandedWidth, height: preferences.expandedHeight),
            payload: selected?.payload,
            calendarWeekRows: calendarWeekRows,
            timerContentHeight: timerContentHeight,
            // This card's own measurement, or none. A card that has never
            // measured itself gets the fixed height, which is tall enough for
            // any of them and so can only be too generous.
            cardContentHeight: cardContentHeight(for: selected?.id),
            geometry: geometry,
            routePickerRows: routePickerRows,
            hasSelection: selected != nil
        )
    }
}
