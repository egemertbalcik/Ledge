import Foundation

/// Retires the global web-media switches, deliberately granting nothing.
///
/// Three generations of the same setting have existed:
///
/// 1. `nowplaying.appMediaOnly` + `nowplaying.hideWebMediaCard` — two
///    negatives, defaulting to showing every website.
/// 2. `nowplaying.showWebMediaCards` + `nowplaying.showWebMediaInCompact` —
///    two positives, defaulting to hiding every website.
/// 3. `nowplaying.websiteRules` — a rule per website, defaulting to none.
///
/// **Nothing is carried forward, and that is the decision, not an omission.**
/// The old settings could only say "all websites" or "none". "None" is already
/// the new default, so it needs no rule. "All websites" cannot be expressed as
/// rules without inventing a list of sites the user never named — which would
/// take a single switch they flipped once and turn it into standing permission
/// for every site they ever visit. The safe reading of an unrepresentable
/// choice is the narrower one.
///
/// So the old keys are read, a notice is raised, and they are retired. A user
/// who had web media on finds it off, with a line in Settings saying why and a
/// list they can add to in seconds — rather than a hidden set of permissions
/// nobody chose.
public enum WebMediaMigration {

    static let appMediaOnly = PrefKey<Bool>("nowplaying.appMediaOnly", default: false)
    static let hideWebMediaCard = PrefKey<Bool>("nowplaying.hideWebMediaCard", default: false)
    static let showWebMediaCards = PrefKey<Bool>("nowplaying.showWebMediaCards", default: false)
    static let showWebMediaInCompact = PrefKey<Bool>("nowplaying.showWebMediaInCompact", default: false)

    /// Whether a stored installation had web media *showing*, in either of the
    /// older shapes.
    ///
    /// The first generation's truth table, in full — the thing a partial
    /// reading got wrong:
    ///
    /// | appMediaOnly | hideWebMediaCard | cards | compact |
    /// |---|---|---|---|
    /// | false        | either           | yes   | yes     |
    /// | true         | false            | yes   | no      |
    /// | true         | true             | no    | no      |
    ///
    /// So web media was showing unless *both* were on. Reading only
    /// `!appMediaOnly` missed the middle row, where cards were showing all
    /// along — and that user would have been told nothing about why they
    /// stopped.
    public static func hadWebMediaEnabled(store: PreferenceStoring) -> Bool {
        // The newer pair is authoritative when present: it replaced the older
        // one, so an installation carrying both has already been migrated once.
        if store.hasValue(named: showWebMediaCards.name) {
            return store.value(for: showWebMediaCards)
        }
        let hasOldPair = store.hasValue(named: appMediaOnly.name)
            || store.hasValue(named: hideWebMediaCard.name)
        guard hasOldPair else { return false }
        let keptOutOfCompact = store.value(for: appMediaOnly)
        let hidTheCard = store.value(for: hideWebMediaCard)
        return !(keptOutOfCompact && hidTheCard)
    }

    /// Reads the old keys once, leaves no rules behind, and raises the notice
    /// if there is something to explain.
    public static func run(store: PreferenceStoring) {
        // Already using rules — a second launch. Nothing to retire.
        guard !store.hasValue(named: Prefs.websiteRules.name) else { return }
        let hasAnyOldKey = [
            appMediaOnly.name, hideWebMediaCard.name,
            showWebMediaCards.name, showWebMediaInCompact.name,
        ].contains { store.hasValue(named: $0) }
        guard hasAnyOldKey else { return }

        // Persisted, not held in memory: the explanation has to survive the
        // relaunch that follows an update, or somebody who did not open
        // Settings that afternoon never learns why their web media went away.
        if hadWebMediaEnabled(store: store) {
            store.set(true, for: Prefs.webMediaNoticePending)
        }

        // Deliberately empty: see the note on this type. The old keys
        // themselves are swept by `Prefs.retiredNames` immediately after this.
        store.set("", for: Prefs.websiteRules)
    }
}
