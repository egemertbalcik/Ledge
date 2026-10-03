import Foundation

/// Carries a choice made with the old web-media switches over to the new pair.
///
/// The old pair said the same thing in negatives — "keep web pages out of the
/// compact view", and then "hide their card as well" — and defaulted to
/// showing everything. The new pair says it in positives and defaults to
/// showing nothing.
///
/// Changing a default is only honest for people who never answered the
/// question. Somebody who went into Settings and decided what browsers may do
/// answered it, and that answer is kept:
///
/// | appMediaOnly | hideWebMediaCard | cards | compact |
/// |---|---|---|---|
/// | off | (either)        | on  | on  | web media was fully shown |
/// | on  | off             | on  | off | card kept, ears refused   |
/// | on  | on              | off | off | refused outright          |
///
/// Runs once: the old keys are swept by `Prefs.retiredNames` immediately
/// afterwards, and nothing writes them again. An installation with neither
/// key stored is left alone, so the new defaults apply.
public enum WebMediaMigration {

    static let appMediaOnly = PrefKey<Bool>("nowplaying.appMediaOnly", default: false)
    static let hideWebMediaCard = PrefKey<Bool>("nowplaying.hideWebMediaCard", default: false)

    public static func run(store: PreferenceStoring) {
        // Already answered in the new language — on a second launch, or by a
        // build that wrote the new keys. Nothing to carry.
        guard !store.hasValue(named: Prefs.showWebMediaCards.name),
              !store.hasValue(named: Prefs.showWebMediaInCompact.name)
        else { return }
        // Never answered in the old language either: this is a new
        // installation, or one that left the switches alone. It gets the new
        // default, which is the whole point of changing it.
        guard store.hasValue(named: appMediaOnly.name)
                || store.hasValue(named: hideWebMediaCard.name)
        else { return }

        let keptOutOfCompact = store.value(for: appMediaOnly)
        let hidTheCard = keptOutOfCompact && store.value(for: hideWebMediaCard)

        store.set(!hidTheCard, for: Prefs.showWebMediaCards)
        store.set(!keptOutOfCompact, for: Prefs.showWebMediaInCompact)
    }
}
