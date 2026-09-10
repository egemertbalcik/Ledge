import CoreGraphics
import LedgeCore
import SwiftUI

/// The size of the open card, and the extra height a hovered readout adds.
///
/// Both of these used to be written out twice, in the view that *draws* the
/// shape and in the panel that decides where the shape *responds* — the same
/// arithmetic, kept in step by hand. A card drawn one size and clicked at
/// another is the failure that costs, so there is one of each now and both
/// callers ask for it.
extension NotchPresentation {

    /// Shared drawing and interaction geometry, including temporary announcements.
    public func layout(
        preferences: Preferences,
        geometry: NotchGeometry,
        phase: NotchPhase,
        hudHovered: Bool = false,
        hudExtraHeight: CGFloat = 0
    ) -> NotchLayout {
        NotchLayout.layout(
            for: phase, geometry: geometry,
            expandedSize: cardSize(preferences: preferences, geometry: geometry, phase: phase),
            bottomRadius: preferences.bottomRadius,
            closedBottomRadius: preferences.closedBottomRadius,
            gutterRadius: preferences.gutterRadius,
            isHudInteractive: hudHovered,
            hudExtraHeight: hudExtraHeight,
            isAnnouncing: announcement != nil
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
            geometry: geometry,
            routePickerRows: routePickerRows,
            hasSelection: selected != nil
        )
    }

    /// Extra height for the hovered readout's sections beyond the first.
    ///
    /// A point budget, not a row count: brightness rows are live sliders
    /// (48pt), while sound's non-current routes are faded bars (36pt) —
    /// budgeting both at the live height opened a dead band over the list.
    ///
    /// - Parameter hovered: whether the readout is currently expanded. The
    ///   two callers decide that differently — the view knows it is hovering,
    ///   the coordinator also checks the phase — so the answer is passed in
    ///   rather than guessed at here.
    public func hudExtraHeight(hovered: Bool) -> CGFloat {
        guard hovered else { return 0 }
        switch hud?.kind {
        case .volume:
            let extras = max(0, min(hudOutputs.count, 5) - 1)
            return CGFloat(extras) * NotchLayout.hudFadedRowHeight
        case .brightness:
            let count = hudDisplays.count
            let extras = count > 1 ? max(0, min(count, 4) - 1) : 0
            return CGFloat(extras) * NotchLayout.hudDeviceRowHeight
        default:
            return 0
        }
    }
}
