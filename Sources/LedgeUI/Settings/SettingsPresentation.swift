import LedgeCore
import SwiftUI

/// The decisions the settings window makes, worked out away from the views.
///
/// Everything here is a pure function of values: which pane a name refers to,
/// what a card row says, the one action a permission row can offer, and what
/// the Keep Awake helper's state means. They live here for the same reason
/// `DeviceRowPresentation` does — the states that are easy to get wrong are
/// the ones nobody can see by reading a `body`, and a `@ViewBuilder switch`
/// cannot be checked by a test.

// MARK: - Panes

/// One page of the settings window.
///
/// A `String` raw value, so the debug switch that opens the window on a page
/// needs no second table to keep in step with this one — the old one had
/// drifted: the sidebar said "Sound & Brightness", the title bar said
/// "Levels", and the switch wanted "hud".
enum SettingsPane: String, Hashable, CaseIterable {
    /// How Ledge behaves, what version it is, and how to be rid of it.
    case general
    /// What it can show you, and why one of them is empty.
    case cards
    /// The one feature that installs something running as root.
    case keepAwake = "keep-awake"
    /// Batteries, and when to be told about them.
    case devices
    /// What it is allowed to do.
    case permissions

    /// Everything for shaping the app rather than using it, in one pane,
    /// shown only when `Prefs.advanced` is on.
    case tuning

    /// The pane's name — in the sidebar, in the title bar, and in the debug
    /// switch. One name each, used in all three places.
    var title: String {
        switch self {
        case .general: "General"
        case .cards: "Cards"
        case .keepAwake: "Keep Awake"
        case .devices: "Devices"
        case .permissions: "Permissions"
        case .tuning: "Tuning"
        }
    }

    /// The panes anyone needs, in the order the questions arrive.
    ///
    /// About folded into General, where macOS keeps its own: it was a version
    /// number, an update button, a link, and a second copy of General's tour
    /// button. Keep Awake came out of Cards for the opposite reason — it is
    /// the one page that installs a daemon running as root, and the notch
    /// card's own sentence already sent people to "Settings › Keep Awake".
    static let everyday: [SettingsPane] = [.general, .cards, .keepAwake, .devices, .permissions]

    /// The panes `Prefs.advanced` reveals. Three became one: they were
    /// sliders for shaping the app, and which of three panes a slider lived
    /// on was not something anybody could guess.
    static let tuningPanes: [SettingsPane] = [.tuning]

    /// Which pane a debug switch means.
    ///
    /// The retired names still work: a shell script or a habit that says
    /// `hud`, `about` or `compact` should not stop opening the pane those
    /// settings now live on.
    static func named(_ name: String?) -> SettingsPane? {
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        switch name {
        case "hud", "levels", "sound": return .cards
        case "about": return .general
        case "advanced", "developer", "appearance", "compact": return .tuning
        case "keepawake", "keep-awake", "espresso": return .keepAwake
        // A card is opened inside Cards, so naming one names that pane too.
        case let name where name.hasPrefix("card:"):
            return SettingsPane.card(named: name) == "keep-awake" ? .keepAwake : .cards
        default: return SettingsPane(rawValue: name)
        }
    }

    /// The card a debug switch wants pushed, if it names one.
    ///
    /// `LEDGE_SETTINGS_TAB=card:weather` opens Cards with Weather open, which
    /// is how a card's own pane gets looked at without clicking to it. The
    /// readout panes keep their old names: `hud` lands on Sound & Brightness,
    /// which is where those settings now live.
    static func card(named name: String?) -> String? {
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        switch name {
        case "hud", "levels", "sound": return "levels"
        default:
            guard name.hasPrefix("card:") else { return nil }
            return String(name.dropFirst("card:".count))
        }
    }
}

/// The icon and tint for a row, in the macOS System-Settings idiom: a white SF
/// Symbol on a rounded colour tile. Used by the sidebar and by the card rows,
/// so a card wears the same face in both places.
struct SettingsIcon {

    let symbol: String
    let color: Color

    static func forPane(_ pane: SettingsPane) -> SettingsIcon {
        switch pane {
        case .general: SettingsIcon(symbol: "gearshape.fill", color: .gray)
        case .cards: SettingsIcon(symbol: "rectangle.stack.fill", color: .orange)
        case .keepAwake: SettingsIcon(symbol: "cup.and.saucer.fill", color: .brown)
        case .devices: SettingsIcon(symbol: "airpods.pro", color: .green)
        case .permissions: SettingsIcon(symbol: "lock.fill", color: .blue)
        case .tuning: SettingsIcon(symbol: "slider.horizontal.3", color: .pink)
        }
    }

    /// The same tile for a permission, so the Permissions pane reads as part
    /// of the same window rather than as a list of system jargon. The symbols
    /// are the tour's, which is where a user met these first.
    static func forPermission(_ kind: PermissionKind) -> SettingsIcon {
        switch kind {
        case .accessibility: SettingsIcon(symbol: "speaker.wave.2.fill", color: .teal)
        case .automation: SettingsIcon(symbol: "music.note", color: .red)
        case .calendars: SettingsIcon(symbol: "calendar", color: .red)
        case .bluetooth: SettingsIcon(symbol: "airpods", color: .green)
        case .location: SettingsIcon(symbol: "location.fill", color: .blue)
        case .focusStatus: SettingsIcon(symbol: "moon.fill", color: .indigo)
        }
    }

    static func forProvider(_ id: String) -> SettingsIcon {
        switch id {
        case "nowplaying": SettingsIcon(symbol: "play.fill", color: .red)
        case "battery": SettingsIcon(symbol: "bolt.fill", color: .orange)
        case "bluetooth": SettingsIcon(symbol: "headphones", color: .green)
        case "calendar": SettingsIcon(symbol: "calendar", color: .red)
        case "focus": SettingsIcon(symbol: "moon.fill", color: .indigo)
        case "weather": SettingsIcon(symbol: "cloud.fill", color: .blue)
        case "timer": SettingsIcon(symbol: "timer", color: .orange)
        case "keep-awake": SettingsIcon(symbol: "cup.and.saucer", color: .brown)
        case "shelf": SettingsIcon(symbol: "tray.full.fill", color: .teal)
        case "notes": SettingsIcon(symbol: "note.text", color: .yellow)
        case "privacy": SettingsIcon(symbol: "video.fill", color: .green)
        case "airpods-proximity": SettingsIcon(symbol: "airpods.gen3", color: .gray)
        case "devicealerts": SettingsIcon(symbol: "battery.25percent", color: .red)
        case "audioroute": SettingsIcon(symbol: "hifispeaker.fill", color: .teal)
        case "bluetooth-power": SettingsIcon(symbol: "dot.radiowaves.left.and.right", color: .blue)
        case "levels": SettingsIcon(symbol: "speaker.wave.2.fill", color: .teal)
        case "keyboard": SettingsIcon(symbol: "keyboard.fill", color: .purple)
        case "capslock": SettingsIcon(symbol: "capslock.fill", color: .purple)
        default: SettingsIcon(symbol: "circle.fill", color: .gray)
        }
    }

    var view: some View {
        Image(systemName: symbol)
            .font(.cardLabel)
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Card rows

/// What one row of the Cards list says.
///
/// Eighteen rows in one list is a wall; they are grouped by what they are
/// *about*, because that is what somebody has in mind when they come looking
/// for the one that has gone quiet.
enum CardGroup: String, CaseIterable {
    case media = "Media & time"
    case mac = "Your Mac"
    case devices = "Devices"
    case files = "Files & notes"
    /// Anything added later and not yet placed. Never empty-headed: a new
    /// provider appears somewhere rather than nowhere.
    case other = "More"

    static func of(_ id: String) -> CardGroup {
        switch id {
        case "nowplaying", "timer", "calendar", "weather": .media
        case "battery", "levels", "keep-awake", "privacy", "focus",
             "keyboard", "capslock", "audioroute", "bluetooth-power": .mac
        case "bluetooth", "airpods-proximity", "devicealerts": .devices
        case "shelf", "notes": .files
        default: .other
        }
    }
}

struct CardRowPresentation: Equatable {

    /// The provider's id, which is what picks its icon.
    var id: String

    /// The card's name.
    var name: String

    /// One line on what it shows, from the user's side of the screen.
    var summary: String

    /// What is standing between this card and showing anything — only when
    /// the card is actually switched on.
    ///
    /// A card that is off is not waiting for a permission: it will never ask
    /// for one and it does no work. Saying "Waiting for Calendar access" in
    /// orange beside a switch the user has deliberately turned off is a
    /// warning about nothing, and the Cards pane was full of them.
    var warning: String?

    /// Whether this card has anything to set beyond being on or off. The ones
    /// that do get a pane; the rest wear their switch in the list, because a
    /// row that opens a pane holding a single toggle is a click asking to be
    /// a click.
    var hasSettings: Bool

    init(provider: ProviderDescriptor) {
        id = provider.id
        name = provider.displayName
        summary = Self.summary(for: provider.id)
        hasSettings = Self.hasSettings(provider.id)
        if let permission = provider.permission, provider.isEnabled, !provider.isAvailable {
            warning = "Needs \(permission.displayName) access"
        } else {
            warning = nil
        }
    }

    static func hasSettings(_ id: String) -> Bool {
        ["timer", "nowplaying", "shelf", "weather", "keep-awake", "levels", "calendar"].contains(id)
    }

    static func summary(for id: String) -> String {
        switch id {
        case "nowplaying": "What Music, Spotify or a browser is playing, with artwork and controls."
        case "battery": "Charging, unplugging and low-battery warnings."
        case "bluetooth": "A card when AirPods or another device connects, with battery levels."
        case "calendar": "Your next event, and a month view when expanded."
        case "focus": "A card when a Focus mode turns on or off."
        case "weather": "Current conditions for your location, or a city you choose."
        case "timer": "A focus timer and pomodoro cycle, counted down in the notch."
        case "keep-awake": KeepAwakeCopy.settingsSummary
        case "shelf": "Drop files on the notch to park them, then drag them out anywhere."
        case "notes": "A scratch pad in the notch, kept on this Mac."
        case "privacy": "A dot while the camera or microphone is in use by an app."
        case "levels": "The readout when you press a volume or brightness key, and a card with sliders."
        case "airpods-proximity": "A card when an AirPods case opens nearby."
        case "devicealerts": "A word when a device's battery gets low, or finishes charging."
        case "keyboard": "A brief note when the keyboard layout switches."
        case "capslock": "A flash in the notch when Caps Lock toggles."
        case "audioroute": "A glance at where sound is going when the output changes."
        case "bluetooth-power": "A note when Bluetooth is switched on or off — the reason devices go quiet."
        default: "One of the things Ledge can show."
        }
    }
}

// MARK: - Permissions

/// How a permission's face reads in the settings window's own vocabulary.
///
/// The decision itself is `PermissionPresentation.face`, in LedgeCore, where
/// the tour can reach it too. This is only the translation into the tones the
/// rest of this window already uses.
extension PermissionTone {
    var settingsTone: SettingsTone {
        switch self {
        case .ok: .ok
        case .attention: .attention
        case .problem: .problem
        case .quiet: .quiet
        }
    }
}



// MARK: - Keep Awake's helper

/// What the lid-closed helper's state means in the Keep Awake pane: a
/// headline, a sentence, and which buttons are worth offering.
///
/// The sentence matters. The pane was rendering `KeepAwakeCopy.lidNotInstalled`
/// — which is the *card's* sentence, and ends "Settings › Keep Awake has it."
/// Somebody standing in Settings › Keep Awake was being told to go to Settings
/// › Keep Awake. Every other state's sentence is written for a reader who
/// could be anywhere, so those are still the shared ones.
struct KeepAwakeSetupPresentation: Equatable {

    var headline: String
    var tone: SettingsTone
    var detail: String

    /// Offered only where pressing it could do something. On an unsigned
    /// build macOS refuses before it begins, and a button that fails every
    /// time teaches people the feature is broken rather than unavailable.
    var offersSetUp: Bool
    /// Offered from the state, not only from the press that produced it.
    /// Somebody who pressed Set Up yesterday needs the way back without
    /// pressing a button that would register something already registered.
    var offersApproval: Bool
    /// The way back out, from the same place it went in. Anything that runs
    /// as root should be removable without hunting for a terminal command —
    /// and it is the only way to try the setup again from scratch.
    var offersRemoval: Bool

    init(_ state: KeepAwakeHelperInstallation) {
        switch state {
        case .installed:
            headline = "Set up"
            tone = .ok
            detail = KeepAwakeCopy.lidInstallation(.installed)
            offersSetUp = false
            offersApproval = false
            offersRemoval = true
        case .needsApproval:
            headline = "Waiting for your OK"
            tone = .attention
            detail = KeepAwakeCopy.lidNeedsApproval
            offersSetUp = false
            offersApproval = true
            offersRemoval = true
        case .notInstalled:
            headline = "Not set up"
            tone = .attention
            detail = "Holding your Mac awake with the lid shut needs a small helper "
                + "that runs underneath. Setting it up asks macOS for permission once. "
                + "Removing it is a button in this same place."
            offersSetUp = true
            offersApproval = false
            offersRemoval = false
        case .unsignedBuild:
            headline = "Unavailable in this build"
            tone = .quiet
            detail = KeepAwakeCopy.lidUnsignedBuild
            offersSetUp = false
            offersApproval = false
            offersRemoval = false
        }
    }
}


/// What the sidebar's one badge counts.
///
/// Its own place, because the rule is a judgement rather than a sum: a card
/// that is on by default and blocked on a permission somebody declined is not
/// waiting on them. Counting those put a badge on every fresh Mac — Caps Lock
/// is on by default and needs Accessibility, which the tour lets you decline
/// at no cost — so the badge said "one card waiting" to somebody who had just
/// said no, which is the app asking again in a different place.
enum SettingsBadge {

    static func waitingCards(_ providers: [ProviderDescriptor]) -> Int {
        providers.filter { $0.isEnabled && !$0.isAvailable && $0.wasSwitchedOnByHand }.count
    }
}
