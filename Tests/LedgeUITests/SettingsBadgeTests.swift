import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

@Suite("What the Cards badge counts")
struct SettingsBadgeTests {

    private func card(
        _ id: String,
        enabled: Bool,
        available: Bool,
        byHand: Bool
    ) -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            displayName: id.capitalized,
            kind: .message,
            permission: .accessibility,
            isEnabled: enabled,
            isAvailable: available,
            wasSwitchedOnByHand: byHand
        )
    }

    @Test("A card somebody switched on that cannot run is waiting on them")
    func switchedOnByHand() {
        let cards = [card("notes", enabled: true, available: false, byHand: true)]
        #expect(SettingsBadge.waitingCards(cards) == 1)
    }

    @Test("A default-on card blocked on a declined permission is not")
    func onByDefault() {
        // Caps Lock on a fresh Mac: on by default, needs Accessibility, and
        // the tour lets Accessibility be declined at no cost.
        let cards = [card("caps-lock", enabled: true, available: false, byHand: false)]
        #expect(SettingsBadge.waitingCards(cards) == 0)
    }

    @Test("A card that can run, or is switched off, counts for nothing")
    func theRest() {
        let cards = [
            card("weather", enabled: true, available: true, byHand: true),
            card("shelf", enabled: false, available: false, byHand: true),
        ]
        #expect(SettingsBadge.waitingCards(cards) == 0)
    }
}
