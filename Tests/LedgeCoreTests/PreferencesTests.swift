import Foundation
import Testing

@testable import LedgeCore

@Suite("Preferences")
@MainActor
struct PreferencesTests {

    @Test("Defaults come through when nothing is stored")
    func defaultsApply() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        #expect(preferences.bottomRadius == Prefs.bottomRadius.defaultValue)
        #expect(preferences.hoverOpenDelay == Prefs.hoverOpenDelay.defaultValue)
    }

    @Test("Edits are written through and survive a reload")
    func writesPersist() {
        let store = MemoryPreferenceStore()
        let first = Preferences(store: store)
        first.bottomRadius = 21
        first.hoverOpenDelay = 0.4

        let reloaded = Preferences(store: store)
        #expect(reloaded.bottomRadius == 21)
        #expect(reloaded.hoverOpenDelay == 0.4)
    }

    @Test("Reset clears the store as well as the in-memory values")
    func resetClearsStore() {
        let store = MemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.bottomRadius = 33
        preferences.resetToDefaults()

        #expect(preferences.bottomRadius == Prefs.bottomRadius.defaultValue)
        // A reload must not resurrect the old value from the store.
        let reloaded = Preferences(store: store)
        #expect(reloaded.bottomRadius == Prefs.bottomRadius.defaultValue)
    }

    @Test("Every registered key is covered by reset")
    func resetCoversEveryKey() {
        // Guards against adding a preference and forgetting to list it, which
        // would leave a stale value behind after "reset all".
        #expect(Set(Prefs.allNames).count == Prefs.allNames.count)
        #expect(Prefs.allNames.contains(Prefs.debugTint.name))
        #expect(Prefs.allNames.contains(Prefs.hideFromScreenCapture.name))

        // Completeness, not spot checks: every stored property on the façade
        // is one preference (`@Observable` stores them as `_name`, and its
        // own registrar as `_$observationRegistrar`), and every one of them
        // must be in `allNames` — except the store, the loading latch, and the
        // two onboarding flags, which reset deliberately leaves alone.
        let mirror = Mirror(reflecting: Preferences(store: MemoryPreferenceStore()))
        let excluded: Set<String> = [
            "_store", "_isLoading", "_hasCompletedOnboarding", "_hasBeenIntroduced",
            "_tourPage", "_focusFolderBookmark",
        ]
        let stored = mirror.children.compactMap { child -> String? in
            guard let label = child.label,
                  label.hasPrefix("_"), !label.hasPrefix("_$"),
                  !excluded.contains(label)
            else { return nil }
            return label
        }
        #expect(stored.count == Prefs.allNames.count, "stored: \(stored)")
    }

    @Test("Reset removes every registered key from the store")
    func resetRemovesEveryStoredKey() {
        // Written straight to the store rather than through the façade: the
        // point is that `removeAll(named:)` gets the full list, whatever the
        // properties do afterwards.
        let store = MemoryPreferenceStore()
        for name in Prefs.allNames {
            store.set("sentinel", for: PrefKey<String>(name, default: ""))
            #expect(store.hasValue(named: name))
        }
        Preferences(store: store).resetToDefaults()
        for name in Prefs.allNames {
            #expect(!store.hasValue(named: name), "\(name)")
        }
    }
}
