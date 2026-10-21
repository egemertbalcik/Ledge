import Foundation

/// Carries 1.2.1's open player gate onto the Automation press that replaced it.
///
/// Up to 1.2.1, finishing the tour opened the gate, so anyone who had been
/// through it was already asked at launch and has an answer in TCC. 1.2.2
/// opens the gate only once Automation is pressed in the Permissions tab, and
/// remembers that press in `automationWasAsked`. Read on its own, that would
/// switch Music and Spotify off for every upgrader who had granted them, with
/// the row reading "Not requested" until they pressed it again.
///
/// So the first launch that finds no answer under the new key writes one:
/// true when the tour had been finished, false otherwise. Writing it either
/// way is what makes this run once — a fresh install records false at its
/// first launch, and finishing the tour later does not reopen the gate.
public enum AutomationMigration {

    public static func run(store: PreferenceStoring) {
        guard !store.hasValue(named: Prefs.automationWasAsked.name) else { return }
        let finishedTour = store.value(for: Prefs.hasCompletedOnboarding)
        store.set(finishedTour, for: Prefs.automationWasAsked)
    }
}
