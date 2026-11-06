import AppKit
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// The panel's words, and that each state lays out at its one width.
@MainActor
@Suite("What the panel says")
struct PermissionCompanionViewTests {

    private func size(
        _ content: PermissionCompanionContent,
        location: String? = "/Applications/Ledge.app",
        outcome: AppDragOutcome? = nil
    ) -> CGSize {
        let model = SettingsModel()
        model.appLocation = location
        model.appDragEnded = outcome
        let view = PermissionCompanionView(
            content: content, model: model, actions: SettingsActions.preview, tile: AnyView(Color.gray)
        )
        return NSHostingView(rootView: view).fittingSize
    }

    @Test("Every state is the one width, and has a height")
    func width() {
        let states: [PermissionCompanionContent] = [
            .waiting(PermissionHandoff(kind: .accessibility)),
            .waiting(PermissionHandoff(kind: .accessibility, isFirstTime: true)),
            .waiting(PermissionHandoff(kind: .calendars)),
            .arrived(.accessibility),
            .arrived(.calendars),
        ]
        for state in states {
            let size = size(state)
            #expect(size.width == PermissionCompanionDock.panelWidth, "\(state)")
            #expect(size.height > 60, "\(state)")
        }
    }

    /// The rescue is only for the one list macOS lets an app be dragged into.
    @Test("Only Accessibility gets the rescue, so it is the taller one")
    func rescueOnlyForAccessibility() {
        #expect(size(.waiting(PermissionHandoff(kind: .accessibility))).height
            > size(.waiting(PermissionHandoff(kind: .calendars))).height + 60)
    }

    @Test("A drag that missed makes the panel taller, and says so")
    func dragOutcome() {
        let handoff = PermissionCompanionContent.waiting(PermissionHandoff(kind: .accessibility))
        #expect(size(handoff, outcome: .missed).height > size(handoff).height)
    }

    /// By the time the panel shows, macOS's message has been dealt with: it
    /// is what opens System Settings.
    @Test("The panel says nothing about macOS's first message")
    func noFirstTimeNote() {
        #expect(size(.waiting(PermissionHandoff(kind: .accessibility, isFirstTime: true))).height
            == size(.waiting(PermissionHandoff(kind: .accessibility))).height)
    }

    @Test("Saying it is on is shorter than asking")
    func arrivedIsShort() {
        #expect(size(.arrived(.accessibility)).height < size(.waiting(PermissionHandoff(kind: .accessibility))).height)
    }

    @Test("The words")
    func words() {
        #expect(PermissionGuideCopy.companionTitle(.accessibility) == "Turn on Accessibility")
        #expect(PermissionGuideCopy.companionTitle(.calendars) == "Turn on Calendars")
        #expect(PermissionGuideCopy.backToLedge == "Back to Ledge")
        #expect(PermissionGuideCopy.companionRescue == "Not in the list, or already on and nothing happens?")
        #expect(PermissionGuide.bolded(PermissionGuideCopy.caption(.accessibility))
            .hasPrefix("**Find Ledge in the list and switch it on.**"))
    }

    /// Nobody may name another app in what Ledge says, and the panel must not
    /// claim anything the app cannot read from the list.
    @Test("The panel's new words make no claim about what is in the list")
    func noClaims() {
        #expect(PermissionGuideCopy.companionWaiting == "Waiting for you")
        #expect(PermissionGuideCopy.companionRescueBody.contains("If the list already shows"))
    }
}
