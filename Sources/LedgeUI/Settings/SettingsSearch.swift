import LedgeCore
import SwiftUI

/// One thing search can find: a setting, and where it lives.
struct SettingsSearchHit: Identifiable, Equatable {

    /// What it is called where it lives. This is the line somebody reads.
    let title: String

    /// Words people type for it that are not in the title — "startup" for
    /// launching at login, "lid" for the Keep Awake helper, "dnd" for Focus.
    /// Never shown; only matched.
    let aliases: String

    let pane: SettingsPane

    /// The card whose page it is on, if it is on one.
    let card: String?

    /// The Tuning tab it is on, if it is on one.
    ///
    /// Without it, every tuning result opened the pane on Shape & Motion and
    /// left somebody looking for an ear width that was on another tab.
    var tuningTab: TuningSettingsTab.Tab?

    /// The row to point at once the pane is open.
    let row: String

    var id: String { "\(pane.rawValue)|\(card ?? "")|\(row)" }

    /// Where this setting lives, in the window's own words: "Cards › Weather".
    var trail: String {
        [pane.title, card.flatMap(SettingsSearch.cardName)].compactMap { $0 }.joined(separator: " › ")
    }
}

/// What the settings window can find, and how.
///
/// A fixed list rather than a sweep of the views, because a view hierarchy
/// cannot be asked what it contains without building it, and building every
/// pane to answer a keystroke is how a search field becomes a stutter. The
/// cost is that a new setting has to be added here too. The test alongside
/// this names the controls that must stay findable, one by one, and fails
/// when one of them stops being — which is as close to a completeness check
/// as a fixed list can honestly get.
enum SettingsSearch {

    /// The cards that have a page of their own, by id, with their names.
    static let cardNames: [String: String] = [
        "nowplaying": "Music",
        "weather": "Weather",
        "timer": "Timer & Stopwatch",
        "levels": "Sound & Brightness",
        "shelf": "File Shelf",
        "calendar": "Calendar",
    ]

    static func cardName(_ id: String) -> String? { cardNames[id] }

    /// Everything findable. `advanced` adds the tuning pane's own rows,
    /// because a search that offers what the sidebar is hiding would be
    /// offering a pane the person cannot get back to.
    static func index(advanced: Bool, cards: [ProviderDescriptor] = []) -> [SettingsSearchHit] {
        var hits: [SettingsSearchHit] = [
            .init(title: "Check for Updates", aliases: "version update sparkle new release",
                  pane: .general, card: nil, row: "version"),
            .init(title: "View Source on GitHub", aliases: "source code repository open",
                  pane: .general, card: nil, row: "source"),
            .init(title: "Show Me How It Works", aliases: "tour onboarding welcome help again",
                  pane: .general, card: nil, row: "tour"),
            .init(title: "Launch Ledge at login", aliases: "startup start boot open automatically",
                  pane: .general, card: nil, row: "launchAtLogin"),
            .init(title: "Match my trackpad's scroll direction", aliases: "swipe natural gesture scroll",
                  pane: .general, card: nil, row: "naturalSwipe"),
            .init(title: "Stay quiet during a Focus", aliases: "focus do not disturb dnd quiet silence",
                  pane: .general, card: nil, row: "quietDuringFocus"),
            .init(title: "Show Ledge in screenshots and recordings",
                  aliases: "screenshot recording capture share screen privacy",
                  pane: .general, card: nil, row: "hideFromScreenCapture"),
            .init(title: "Quit Ledge", aliases: "quit exit close stop",
                  pane: .general, card: nil, row: "quit"),
            .init(title: "Reset all settings", aliases: "reset defaults start over factory",
                  pane: .general, card: nil, row: "reset"),

            .init(title: "Opens first", aliases: "order pinned priority which card",
                  pane: .cards, card: nil, row: "pinnedCard"),

            .init(title: "Timer durations", aliases: "focus pomodoro break minutes length",
                  pane: .cards, card: "timer", row: "timerWorkMinutes"),
            .init(title: "Start the next session automatically", aliases: "timer cycle auto advance",
                  pane: .cards, card: "timer", row: "timerAutoAdvance"),
            .init(title: "Show a readout when I press a volume key",
                  aliases: "hud volume brightness readout keys",
                  pane: .cards, card: "levels", row: "hudEnabled"),
            .init(title: "Show one for brightness too", aliases: "brightness readout key hud",
                  pane: .cards, card: "levels", row: "hudBrightnessEnabled"),
            .init(title: "Hide the macOS volume and brightness readout",
                  aliases: "system hud replace accessibility suppress",
                  pane: .cards, card: "levels", row: "suppressSystemHUD"),
            .init(title: "Show web media cards", aliases: "browser youtube web media safari chrome",
                  pane: .cards, card: "nowplaying", row: "showWebMediaCards"),
            .init(title: "Show video in the compact view", aliases: "video compact artwork",
                  pane: .cards, card: "nowplaying", row: "showVideoInCompact"),
            .init(title: "Show web media in the compact view", aliases: "browser web compact media",
                  pane: .cards, card: "nowplaying", row: "showWebMediaInCompact"),
            .init(title: "Stays in the notch after you pause", aliases: "pause linger music companion",
                  pane: .cards, card: "nowplaying", row: "companionLinger"),
            .init(title: "Save screenshots to the Shelf", aliases: "screenshot shelf files drop",
                  pane: .cards, card: "shelf", row: "shelfAutoScreenshots"),
            .init(title: "City", aliases: "weather city town where location",
                  pane: .cards, card: "weather", row: "weatherCity"),
            .init(title: "Units", aliases: "weather celsius fahrenheit temperature degrees",
                  pane: .cards, card: "weather", row: "weatherUnits"),
            .init(title: "Calendars", aliases: "calendar accounts hide show which calendars choose",
                  pane: .cards, card: "calendar", row: "calendarList"),

            .init(title: "\(KeepAwakeCopy.lidClosed) helper",
                  aliases: "lid closed shut helper daemon root install remove awake sleep",
                  pane: .keepAwake, card: nil, row: "helper"),
            .init(title: "\(KeepAwakeCopy.lidClosed) opens on",
                  aliases: "keep awake length default minutes",
                  pane: .keepAwake, card: nil, row: "keepAwakeDefaultMinutes"),
            .init(title: "End at (battery)", aliases: "keep awake battery floor percent",
                  pane: .keepAwake, card: nil, row: "keepAwakeBatteryFloor"),
            .init(title: "Apps that must keep working",
                  aliases: "agents app nap terminal roster claude codex full speed",
                  pane: .keepAwake, card: nil, row: "keepAwakeDisableAppNap"),
            .init(title: "Browsers that would stall",
                  aliases: "chrome chromium arc browser flags lid",
                  pane: .keepAwake, card: nil, row: "browsers"),

            .init(title: "Battery alerts", aliases: "alerts low charged notification airpods device",
                  pane: .devices, card: nil, row: "alerts"),
            .init(title: "Delete Device History", aliases: "history battery delete readings",
                  pane: .devices, card: nil, row: "history"),

            .init(title: "Focus folder", aliases: "focus folder database full disk access",
                  pane: .permissions, card: nil, row: "focusFolder"),
        ]

        hits += PermissionKind.allCases.map { kind in
            .init(title: kind.displayName,
                  aliases: "permission grant allow \(kind.rawValue) \(kind.rationale)",
                  pane: .permissions, card: nil, row: "perm:\(kind.rawValue)")
        }

        // Every card, by its own name, so "notes" finds the Notes switch.
        hits += cards.map { card in
            .init(title: card.displayName,
                  aliases: "card show hide \(card.id)",
                  pane: card.id == "keep-awake" ? .keepAwake : .cards,
                  card: nil,
                  row: "card:\(card.id)")
        }

        if advanced {
            hits += [
                .init(title: "Corner radius and smoothing", aliases: "shape corners radius rounded smoothing",
                      pane: .tuning, card: nil, tuningTab: .shape, row: "bottomRadius"),
                .init(title: "Outline", aliases: "edge outline shape border",
                      pane: .tuning, card: nil, tuningTab: .shape, row: "outlineEnabled"),
                .init(title: "Card height", aliases: "expanded height size shape",
                      pane: .tuning, card: nil, tuningTab: .shape, row: "expandedHeight"),
                .init(title: "Side readout position", aliases: "satellite side readout offset",
                      pane: .tuning, card: nil, tuningTab: .shape, row: "satelliteOffset"),
                .init(title: "Spring response and damping", aliases: "motion animation spring bounce damping",
                      pane: .tuning, card: nil, tuningTab: .shape, row: "springResponse"),
                .init(title: "Ear width", aliases: "ears compact width",
                      pane: .tuning, card: nil, tuningTab: .ears, row: "earWidth"),
                .init(title: "Leading and trailing nudge", aliases: "ears offset nudge leading trailing",
                      pane: .tuning, card: nil, tuningTab: .ears, row: "earLeadingOffset"),
                .init(title: "Hover delays", aliases: "timing open close delay hover",
                      pane: .tuning, card: nil, tuningTab: .timing, row: "hoverOpenDelay"),
                .init(title: "How long things stay", aliases: "announcement peek readout duration timing",
                      pane: .tuning, card: nil, tuningTab: .timing, row: "peekDuration"),
                .init(title: "Swipe distance", aliases: "gesture swipe threshold distance",
                      pane: .tuning, card: nil, tuningTab: .timing, row: "swipeThreshold"),
                .init(title: "Volume and brightness steps", aliases: "step keys increment timing",
                      pane: .tuning, card: nil, tuningTab: .timing, row: "hudVolumeStep"),
                .init(title: "Readout layout", aliases: "glow bar glyph offset readout layout",
                      pane: .tuning, card: nil, tuningTab: .timing, row: "hudGlowBar"),
                .init(title: "Hide Tuning", aliases: "advanced hide developer tuning off",
                      pane: .tuning, card: nil, tuningTab: .timing, row: "hideTuning"),
            ]
        }
        return hits
    }

    /// What matches a query.
    ///
    /// Every word has to match the start of some word in the title or the
    /// aliases. Prefixes rather than substrings: typing "cit" finds "City"
    /// and not "Opacity", which is what people expect of a settings search
    /// and what keeps a two-letter query from returning the whole window.
    static func matches(_ query: String, in hits: [SettingsSearchHit]) -> [SettingsSearchHit] {
        let words = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return [] }
        return hits.filter { hit in
            let haystack = (hit.title + " " + hit.aliases)
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            return words.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
        }
    }
}

/// What search found, as a list that goes somewhere.
struct SettingsSearchResults: View {

    let query: String
    let model: SettingsModel
    let advanced: Bool
    let onOpen: (SettingsSearchHit) -> Void

    private var hits: [SettingsSearchHit] {
        SettingsSearch.matches(
            query,
            in: SettingsSearch.index(advanced: advanced, cards: model.providers)
        )
    }

    var body: some View {
        SettingsPage {
            if hits.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No settings match “\(query)”.")
                        SettingsNote("Search looks through every setting's name and a few words people use for it. Clear the field to go back.")
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Section {
                    // Capped, and said when it is: a list that scrolls past
                    // the window is a list nobody reads to the end of.
                    ForEach(hits.prefix(12)) { hit in
                        Button { onOpen(hit) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.title)
                                    SettingsNote(hit.trail)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Results for “\(query)”")
                } footer: {
                    if hits.count > 12 {
                        SettingsNote("\(hits.count - 12) more match. Try another word.")
                    }
                }
            }
        }
    }
}
