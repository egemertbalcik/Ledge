import Foundation
import Testing

@testable import LedgeCore

/// The whole table, in one place, because every other part of the app asks
/// this type rather than reading the two switches itself.
@Suite("Web media: the four states")
struct WebMediaPolicyTableTests {

    @Test("Both off: a page's media does not exist as far as the notch knows")
    func bothOff() {
        let policy = WebMediaPolicy(showsCards: false, showsInCompact: false)
        #expect(policy.allowsCard(ownerIsApp: false) == false)
        #expect(policy.allowsCompact(ownerIsApp: false) == false)
    }

    @Test("Cards on, compact off: a card to go and look at, and nothing more")
    func cardOnly() {
        let policy = WebMediaPolicy(showsCards: true, showsInCompact: false)
        #expect(policy.allowsCard(ownerIsApp: false))
        #expect(policy.allowsCompact(ownerIsApp: false) == false)
    }

    @Test("Both on: a card and a place in the ears, as a player has")
    func cardAndCompact() {
        let policy = WebMediaPolicy(showsCards: true, showsInCompact: true)
        #expect(policy.allowsCard(ownerIsApp: false))
        #expect(policy.allowsCompact(ownerIsApp: false))
    }

    /// Not reachable through Settings, but reachable by hand-editing the
    /// preference file or by leaving an older build's pair behind. Read as
    /// both off, so compact content cannot reappear on its own.
    @Test("Compact without cards is invalid and reads as both off")
    func compactWithoutCardsIsInvalid() {
        let policy = WebMediaPolicy(showsCards: false, showsInCompact: true)
        #expect(policy.showsInCompact == false)
        #expect(policy == .hidden)
        #expect(policy.allowsCard(ownerIsApp: false) == false)
        #expect(policy.allowsCompact(ownerIsApp: false) == false)
    }

    @Test("Neither switch has anything to say about an app's own media")
    func nativeMediaUntouched() {
        for policy in [
            WebMediaPolicy.hidden,
            WebMediaPolicy(showsCards: true, showsInCompact: false),
            WebMediaPolicy(showsCards: true, showsInCompact: true),
            WebMediaPolicy(showsCards: false, showsInCompact: true),
        ] {
            #expect(policy.allowsCard(ownerIsApp: true))
            #expect(policy.allowsCompact(ownerIsApp: true))
        }
    }
}

@Suite("Web media preferences")
@MainActor
struct WebMediaPreferencesTests {

    @Test("An empty store resolves both switches to off")
    func emptyStoreIsOff() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        #expect(preferences.showWebMediaCards == false)
        #expect(preferences.showWebMediaInCompact == false)
        #expect(preferences.webMedia == .hidden)
    }

    @Test("Both switches persist and come back after a reload")
    func persists() {
        let store = MemoryPreferenceStore()
        let first = Preferences(store: store)
        first.showWebMediaCards = true
        first.showWebMediaInCompact = true

        let reloaded = Preferences(store: store)
        #expect(reloaded.showWebMediaCards)
        #expect(reloaded.showWebMediaInCompact)
        #expect(reloaded.webMedia == WebMediaPolicy(showsCards: true, showsInCompact: true))
    }

    @Test("Turning cards off clears the compact switch, in memory and in the store")
    func cardsOffClearsCompact() {
        let store = MemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.showWebMediaCards = true
        preferences.showWebMediaInCompact = true

        preferences.showWebMediaCards = false
        #expect(preferences.showWebMediaInCompact == false)
        #expect(Preferences(store: store).showWebMediaInCompact == false, "and it stays off")
    }

    /// The dependency is enforced twice on purpose: Settings disables the
    /// second switch, and the policy ignores it. A stored pair that says
    /// otherwise — hand-edited, or left by a build that let it happen — is
    /// still read as both off.
    @Test("Compact alone in the store has no effect")
    func compactAloneInStoreDoesNothing() {
        let store = MemoryPreferenceStore()
        store.set(true, for: Prefs.showWebMediaInCompact)
        let preferences = Preferences(store: store)
        #expect(preferences.webMedia == .hidden)
    }

    @Test("Both switches are covered by reset")
    func resetCoversThem() {
        #expect(Prefs.allNames.contains(Prefs.showWebMediaCards.name))
        #expect(Prefs.allNames.contains(Prefs.showWebMediaInCompact.name))

        let store = MemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.showWebMediaCards = true
        preferences.showWebMediaInCompact = true
        preferences.resetToDefaults()
        #expect(preferences.showWebMediaCards == false)
        #expect(preferences.showWebMediaInCompact == false)
        #expect(Preferences(store: store).webMedia == .hidden)
    }

    /// The pair that replaced two negatives with two positives, and changed
    /// the default while doing it. Somebody who answered the old question
    /// keeps their answer; an installation that never touched the switches
    /// takes the new default.
    @Test("An explicit old choice is carried over", arguments: [
        // appMediaOnly, hideWebMediaCard, cards, compact
        (false, false, true, true),
        (false, true, true, true),
        (true, false, true, false),
        (true, true, false, false),
    ])
    func oldChoiceMigrates(
        keptOutOfCompact: Bool, hidTheCard: Bool, cards: Bool, compact: Bool
    ) {
        let store = MemoryPreferenceStore()
        store.set(keptOutOfCompact, for: WebMediaMigration.appMediaOnly)
        store.set(hidTheCard, for: WebMediaMigration.hideWebMediaCard)

        let preferences = Preferences(store: store)
        #expect(preferences.showWebMediaCards == cards)
        #expect(preferences.showWebMediaInCompact == compact)
        #expect(preferences.webMedia == WebMediaPolicy(showsCards: cards, showsInCompact: compact))
    }

    @Test("The old keys are swept once they have been read")
    func oldKeysAreRetiredAfterReading() {
        #expect(Prefs.retiredNames.contains("nowplaying.appMediaOnly"))
        #expect(Prefs.retiredNames.contains("nowplaying.hideWebMediaCard"))

        let store = MemoryPreferenceStore()
        store.set(true, for: WebMediaMigration.appMediaOnly)
        _ = Preferences(store: store)
        #expect(store.hasValue(named: "nowplaying.appMediaOnly") == false)
        // And the migrated answer is what a second launch reads.
        #expect(Preferences(store: store).showWebMediaCards)
    }

    @Test("An installation that never answered gets the new default")
    func untouchedInstallTakesTheDefault() {
        let store = MemoryPreferenceStore()
        store.set(true, for: Prefs.showVideoInCompact)  // some other preference
        #expect(Preferences(store: store).webMedia == .hidden)
    }

    /// Migration must not overrule an answer given in the new language — a
    /// second launch, where the old keys are long gone, must read the pair
    /// the user actually set.
    @Test("A new-language answer is never overwritten")
    func newAnswerWins() {
        let store = MemoryPreferenceStore()
        store.set(false, for: Prefs.showWebMediaCards)
        store.set(false, for: Prefs.showWebMediaInCompact)
        store.set(false, for: WebMediaMigration.appMediaOnly)
        #expect(Preferences(store: store).webMedia == .hidden)
    }
}

/// Carrying a web-media choice across the versions that changed how it was
/// spelled — including 1.0.9, which briefly replaced it with a list of
/// websites that could never match anything.
@Suite("Web media settings, across versions")
@MainActor
struct WebMediaMigrationTests {

    private let appMediaOnly = PrefKey<Bool>("nowplaying.appMediaOnly", default: false)
    private let hideWebMediaCard = PrefKey<Bool>("nowplaying.hideWebMediaCard", default: false)
    private let websiteRules = PrefKey<String>("nowplaying.websiteRules", default: "")

    @Test("A fresh install starts with web media off")
    func freshInstall() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        #expect(preferences.showWebMediaCards == false)
        #expect(preferences.showWebMediaInCompact == false)
        #expect(preferences.webMedia == .hidden)
    }

    /// The old pair maps onto the new one exactly, so somebody who had web
    /// media showing keeps it rather than finding it switched off.
    @Test("The old pair is carried across", arguments: [
        // appMediaOnly, hideWebMediaCard, cards, compact
        (false, false, true, true),
        (false, true, true, true),
        (true, false, true, false),
        (true, true, false, false),
    ])
    func oldPairCarried(keptOut: Bool, hidCard: Bool, cards: Bool, compact: Bool) {
        let store = MemoryPreferenceStore()
        store.set(keptOut, for: appMediaOnly)
        store.set(hidCard, for: hideWebMediaCard)

        let preferences = Preferences(store: store)
        #expect(preferences.showWebMediaCards == cards, "appMediaOnly=\(keptOut) hid=\(hidCard)")
        #expect(preferences.showWebMediaInCompact == compact)
    }

    @Test("The carried choice survives a relaunch")
    func carriedChoiceIsDurable() {
        let store = MemoryPreferenceStore()
        store.set(false, for: appMediaOnly)
        #expect(Preferences(store: store).showWebMediaCards)
        #expect(Preferences(store: store).showWebMediaCards, "it was not written down")
    }

    @Test("The old keys are swept once they have been read")
    func oldKeysSwept() {
        let store = MemoryPreferenceStore()
        store.set(true, for: appMediaOnly)
        _ = Preferences(store: store)
        #expect(store.hasValue(named: "nowplaying.appMediaOnly") == false)
        #expect(store.hasValue(named: "nowplaying.hideWebMediaCard") == false)
    }

    /// 1.0.9 swept the old pair and wrote a website list instead. There is
    /// nothing in that list worth carrying — no rule in it could ever match —
    /// so those installations land on the default, which is what 1.0.9 was
    /// already giving them.
    @Test("A 1.0.9 installation lands on the default")
    func fromTheWebsiteListVersion() {
        let store = MemoryPreferenceStore()
        store.set("[{\"host\":\"youtube.com\",\"appearance\":\"cardAndCompact\"}]", for: websiteRules)
        let preferences = Preferences(store: store)
        #expect(preferences.showWebMediaCards == false)
        #expect(preferences.showWebMediaInCompact == false)
    }

    @Test("The withdrawn website keys are swept")
    func websiteKeysSwept() {
        let store = MemoryPreferenceStore()
        store.set("[]", for: websiteRules)
        store.set(true, for: PrefKey<Bool>("nowplaying.webMediaNoticePending", default: false))
        _ = Preferences(store: store)
        #expect(store.hasValue(named: "nowplaying.websiteRules") == false)
        #expect(store.hasValue(named: "nowplaying.webMediaNoticePending") == false)
    }

    /// An explicit choice made in the current version is never overwritten by
    /// a stale key from an older one.
    @Test("A current choice wins over anything older")
    func currentChoiceWins() {
        let store = MemoryPreferenceStore()
        let first = Preferences(store: store)
        first.showWebMediaCards = true
        first.showWebMediaInCompact = true
        // A stray old key, as a hand-edited file might hold.
        store.set(true, for: appMediaOnly)

        let second = Preferences(store: store)
        #expect(second.showWebMediaCards, "an old key overrode a current choice")
        #expect(second.showWebMediaInCompact)
    }

    @Test("Both switches are covered by reset")
    func resetCoversBoth() {
        #expect(Prefs.allNames.contains(Prefs.showWebMediaCards.name))
        #expect(Prefs.allNames.contains(Prefs.showWebMediaInCompact.name))
        let store = MemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.showWebMediaCards = true
        preferences.showWebMediaInCompact = true
        preferences.resetToDefaults()
        #expect(preferences.webMedia == .hidden)
        #expect(Preferences(store: store).webMedia == .hidden)
    }
}
