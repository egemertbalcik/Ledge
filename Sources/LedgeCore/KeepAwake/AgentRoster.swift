import Foundation

/// The apps whose work is the reason the Mac is being kept awake.
///
/// Everything else about the lid-closed mode is about spending less. This is
/// the list of things that must keep spending — and the two halves only make
/// sense together, because "stop wasting power" and "keep working" are the same
/// instruction applied to different processes.
///
/// A roster, not a denylist. macOS already winds down what it thinks nobody is
/// watching, and with the lid shut it thinks that about everything, so the
/// default state of a closed Mac is already frugal. What it cannot know is
/// which of those invisible things somebody is waiting on.
public struct AgentRoster: Sendable, Equatable {

    /// Bundle ids, in the order the user sees them.
    public private(set) var bundleIDs: [String]

    public init(_ bundleIDs: [String] = AgentRoster.shipped) {
        self.bundleIDs = AgentRoster.tidy(bundleIDs)
    }

    /// What ships, and why these.
    ///
    /// The agents this is built for — Claude Code, Codex — are command-line
    /// processes that run *inside* a terminal. The terminal is the app macOS
    /// knows about and the app App Nap acts on, so terminals come first and
    /// matter most; the agent's own process is a child of one.
    ///
    /// Editors earn their place the same way, by hosting an agent in a pane.
    /// Browsers are here for the agents that drive them. Everything on this
    /// list is an app whose preferences Ledge may write, which is why it is
    /// short and why the user can see it.
    public static let shipped: [String] = [
        // Terminals — where Claude Code and Codex actually run.
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        // org, not io. Checked against an installed copy where there was one
        // and against Insomnia's own verified list where there was not; this
        // is the entry that was wrong on the first pass, and a bundle id that
        // names nothing fails silently — the app is simply never written to.
        "org.alacritty",
        // Editors that host an agent in a pane.
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "dev.zed.Zed",
        // The agent apps themselves.
        "com.anthropic.claudefordesktop",
        "com.openai.chat",
        // Browsers, for the agents that drive one.
        "com.google.Chrome",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",      // Arc
        // Long-running local work an agent leans on.
        "com.docker.docker",
        "com.exafunction.windsurf",
    ]

    /// Whether this app is on the roster.
    public func carries(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    public mutating func add(_ bundleID: String) {
        bundleIDs = AgentRoster.tidy(bundleIDs + [bundleID])
    }

    public mutating func remove(_ bundleID: String) {
        bundleIDs.removeAll { $0 == bundleID }
    }

    /// Drops what cannot be acted on, keeping the order the user put things in.
    ///
    /// An entry that `defaults` would not read as a bundle's own domain is not
    /// merely useless — it is dangerous. A leading `-` is a flag, a path is a
    /// file, and `NSGlobalDomain` is every app on the Mac at once. Writing
    /// `NSAppSleepDisabled` there would turn App Nap off for everything, which
    /// is the exact opposite of this feature, and nothing would ever put it
    /// back because the recovery agent could not name what it had changed.
    static func tidy(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            guard AgentRoster.isWritableDomain(id) else { return false }
            return seen.insert(id).inserted
        }
    }

    /// The names that mean "not one application".
    ///
    /// CFPreferences' sentinels are ordinary strings — `kCFPreferencesAnyApplication`
    /// is literally the text `"kCFPreferencesAnyApplication"` — so a guard that
    /// only looked for suspicious *characters* let them straight through: they
    /// are plain letters and break none of the shape rules below. Passed as an
    /// application id they address global preferences, and writing
    /// `NSAppSleepDisabled` there turns App Nap off for every app on the Mac.
    ///
    /// Matched without regard to case, because the damage does not care.
    static func isGlobalDomain(_ id: String) -> Bool {
        let folded = id.lowercased()
        return [
            "nsglobaldomain",
            ".globalpreferences",
            "apple.com",
            "kcfpreferencesanyapplication",
            "kcfpreferencescurrentapplication",
            "kcfpreferencesanyuser",
            "kcfpreferencescurrentuser",
            "kcfpreferencesanyhost",
            "kcfpreferencescurrenthost",
        ].contains(folded)
    }

    /// Whether this is a bundle id whose preference domain can be written and,
    /// just as importantly, written back.
    public static func isWritableDomain(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 200 else { return false }
        guard !isGlobalDomain(id) else { return false }
        guard !id.hasPrefix("-"), !id.hasPrefix("."), !id.hasSuffix(".") else { return false }
        guard !id.contains("/"), !id.contains("..") else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Storage

    /// Stored as one newline-separated string, matching how the other list
    /// preferences in this app are kept.
    public init(stored: String) {
        self.init(stored.split(separator: "\n").map(String.init))
    }

    public var stored: String { bundleIDs.joined(separator: "\n") }
}

/// What Ledge did to one app's App Nap preference, so it can be undone.
///
/// The previous value has three states and all three matter: the key was
/// `true`, the key was `false`, or there was no key at all. Putting back
/// `false` where there had been nothing leaves a trace of Ledge in somebody
/// else's preferences forever, and the user never asked for that.
public struct AppNapOverride: Sendable, Equatable, Codable {

    public let bundleID: String
    /// What the key held before Ledge touched it. Nil means it was absent, and
    /// an absent key is restored by removing it, not by writing `false`.
    public let previous: Bool?

    public init(bundleID: String, previous: Bool?) {
        self.bundleID = bundleID
        self.previous = previous
    }
}

public enum AppNapPlan {

    /// Which apps are worth writing to, and which are already as we want them.
    ///
    /// An app whose key already reads `true` is skipped: there is nothing to
    /// put back, so journalling it would mean a restore that writes `true`
    /// over the user's own `true` and then deletes it. The one case where
    /// doing nothing is strictly better than doing the right thing.
    public static func writes(for roster: AgentRoster,
                              reading: (String) -> Bool??) -> [AppNapOverride] {
        roster.bundleIDs.compactMap { id in
            // Two levels of optional on purpose: the outer one is "could not
            // be read at all", the inner one is "no such key". A preference
            // nobody could read is a preference nobody could write back, so
            // it is left alone rather than guessed at.
            guard let value = reading(id) else { return nil }
            if value == true { return nil }
            return AppNapOverride(bundleID: id, previous: value)
        }
    }
}
