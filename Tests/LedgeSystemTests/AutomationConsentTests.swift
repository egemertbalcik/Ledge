import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

/// When Ledge may first send Music or Spotify an Apple Event.
///
/// On macOS 26 the first read of an undecided player, and the first grant
/// query against it, are each the Automation dialog. The gate opened when the
/// tour finished — and the tour never mentions Automation — so the dialog came
/// with no button pressed: seconds after the tour closed, or at the launch of
/// anybody who had finished it. The README says nothing is asked for at
/// launch, only from the Permissions tab.
@Suite("Automation is asked for only from its button")
@MainActor
struct AutomationConsentTests {

    @Test("Finishing the tour does not open the player gate")
    func theTourIsNotConsent() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.hasCompletedOnboarding = true
        // Reached: this is the returning user the dialog ambushed.
        #expect(preferences.hasCompletedOnboarding)

        let center = PermissionCenter(preferences: preferences)
        #expect(center.mayAskAboutPlayers == false, "a finished tour let Ledge ask players on its own")
    }

    @Test("The Automation press opens it, and the next launch remembers")
    func thePressIsRemembered() {
        let store = MemoryPreferenceStore()
        let first = Preferences(store: store)
        #expect(PermissionCenter(preferences: first).mayAskAboutPlayers == false)

        // What `request(.automation)` writes. The request itself scripts a
        // player, so it is not run here.
        first.automationWasAsked = true
        #expect(PermissionCenter(preferences: first).mayAskAboutPlayers)

        let nextLaunch = Preferences(store: store)
        #expect(PermissionCenter(preferences: nextLaunch).mayAskAboutPlayers, "the press was forgotten")
    }

    @Test("Resetting settings does not forget the press")
    func resetKeepsThePress() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.automationWasAsked = true
        preferences.resetToDefaults()
        #expect(preferences.automationWasAsked)
    }
}

/// Upgrading from 1.2.1, where a finished tour already held the gate open.
@Suite("Automation gate carries over from 1.2.1")
@MainActor
struct AutomationMigrationTests {

    @Test("An upgrader who finished the tour keeps Music and Spotify")
    func upgraderKeepsTheGate() {
        let store = MemoryPreferenceStore()
        // What 1.2.1 left: the tour done, no Automation key at all.
        store.set(true, for: Prefs.hasCompletedOnboarding)
        #expect(!store.hasValue(named: Prefs.automationWasAsked.name))

        let preferences = Preferences(store: store)
        #expect(PermissionCenter(preferences: preferences).mayAskAboutPlayers)
    }

    @Test("A fresh install stays shut, and finishing the tour later does not open it")
    func freshInstallStaysShut() {
        let store = MemoryPreferenceStore()
        let first = Preferences(store: store)
        #expect(!first.hasCompletedOnboarding)
        #expect(PermissionCenter(preferences: first).mayAskAboutPlayers == false)

        first.hasCompletedOnboarding = true
        // Reached: the tour is done and saved, as the next launch reads it.
        #expect(store.value(for: Prefs.hasCompletedOnboarding))

        let nextLaunch = Preferences(store: store)
        #expect(PermissionCenter(preferences: nextLaunch).mayAskAboutPlayers == false,
                "the migration ran again and treated the tour as consent")
    }

    @Test("An upgrader who never finished the tour stays shut")
    func unfinishedTourStaysShut() {
        let store = MemoryPreferenceStore()
        store.set(false, for: Prefs.hasCompletedOnboarding)
        #expect(store.hasValue(named: Prefs.hasCompletedOnboarding.name))

        let preferences = Preferences(store: store)
        #expect(PermissionCenter(preferences: preferences).mayAskAboutPlayers == false)
    }
}
