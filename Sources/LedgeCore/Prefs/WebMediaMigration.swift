import Foundation

/// Carries an existing web-media choice onto the two switches that express it.
///
/// Three shapes of this setting have existed:
///
/// 1. `nowplaying.appMediaOnly` + `nowplaying.hideWebMediaCard` — two
///    negatives, defaulting to showing every website.
/// 2. `nowplaying.showWebMediaCards` + `nowplaying.showWebMediaInCompact` —
///    the two switches in force now, defaulting to off.
/// 3. `nowplaying.websiteRules` — a rule per website, shipped in 1.0.9 and
///    withdrawn. macOS does not report which site browser media came from, so
///    the list could never match anything; there is nothing in it to carry.
///
/// The first pair maps onto the second exactly, so a choice somebody made is
/// kept rather than reset:
///
/// | appMediaOnly | hideWebMediaCard | cards | compact |
/// |---|---|---|---|
/// | false        | either           | on    | on      |
/// | true         | false            | on    | off     |
/// | true         | true             | off   | off     |
///
/// An installation that never touched the setting gets the new default, which
/// is off. That is the only behaviour change: somebody who had web media on
/// keeps it, and somebody who never chose starts from quiet.
public enum WebMediaMigration {

    static let appMediaOnly = PrefKey<Bool>("nowplaying.appMediaOnly", default: false)
    static let hideWebMediaCard = PrefKey<Bool>("nowplaying.hideWebMediaCard", default: false)

    /// 1.0.9's website list. Read only to know it was there; it holds nothing
    /// worth carrying, since no rule in it could ever have matched.
    static let websiteRules = PrefKey<String>("nowplaying.websiteRules", default: "")

    public static func run(store: PreferenceStoring) {
        // Already answered in the current language — an ordinary launch.
        guard !store.hasValue(named: Prefs.showWebMediaCards.name) else { return }

        // Came through 1.0.9: the old pair was swept then, so there is nothing
        // left to read. The defaults are what 1.0.9 already gave them.
        guard !store.hasValue(named: websiteRules.name) else { return }

        let hasOldPair = store.hasValue(named: appMediaOnly.name)
            || store.hasValue(named: hideWebMediaCard.name)
        guard hasOldPair else { return }

        let keptOutOfCompact = store.value(for: appMediaOnly)
        let hidTheCard = keptOutOfCompact && store.value(for: hideWebMediaCard)
        store.set(!hidTheCard, for: Prefs.showWebMediaCards)
        store.set(!keptOutOfCompact, for: Prefs.showWebMediaInCompact)
    }
}
