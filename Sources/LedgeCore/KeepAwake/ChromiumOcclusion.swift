import Foundation

/// Chromium stops working when nobody can see it.
///
/// Chromium throttles windows macOS reports as occluded — and with the lid shut
/// and no external display, every window is occluded. Timers drop to about 1 Hz,
/// animation frames stop entirely, and pages report themselves hidden. For a
/// browser somebody is merely leaving open that is exactly right. For a browser
/// an agent is driving it is the end of the work, and it fails silently: the
/// page is still there, the agent is still waiting, and nothing is happening.
///
/// The two flags below are the only way to turn it off, and they can only be
/// given at launch. So this type never acts — it reports, and the user decides
/// whether their browser is worth restarting. A browser that closed itself and
/// came back while somebody was mid-task would be a worse surprise than a slow
/// one.
public enum ChromiumOcclusion {

    /// Both are needed. The first stops windows being backgrounded when
    /// occluded, the second stops the renderer processes behind them being
    /// deprioritised; with only one, the work still stalls, just differently.
    public static let flags = [
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
    ]

    /// The Chromium-family browsers an agent is likely to be driving.
    ///
    /// Firefox is not here: it is not Chromium and does not take these flags.
    /// Safari is not here either — it has no equivalent switch at all, which is
    /// worth saying out loud rather than leaving somebody to wonder.
    public static let browsers = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
    ]

    public static func isChromium(_ bundleID: String) -> Bool {
        browsers.contains(bundleID)
    }

    /// Whether a launched process already has what it needs.
    ///
    /// Read from the command line it was actually started with, not from
    /// anything the browser reports about itself: the flags take effect at
    /// launch and nothing afterwards can add them, so the command line is the
    /// only honest source.
    public static func isProtected(commandLine: String) -> Bool {
        flags.allSatisfy { flag in
            // Matched as a whole argument. A plain `contains` would accept
            // `--disable-renderer-backgrounding-except-this`, which is not a
            // flag anybody passes but is exactly the kind of near-miss that
            // makes a check look like it works.
            commandLine.split(whereSeparator: { $0 == " " || $0 == "\n" })
                .contains { $0 == Substring(flag) || $0.hasPrefix(Substring(flag + "=")) }
        }
    }
}

/// One running browser, and whether its work will survive a shut lid.
public struct ChromiumBrowser: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let isProtected: Bool

    public init(bundleID: String, name: String, isProtected: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isProtected = isProtected
    }
}

public enum ChromiumAdvice {

    /// Which running browsers would stall, given a roster.
    ///
    /// Only browsers on the roster. A Chromium window somebody left open is
    /// not a reason to suggest restarting anything — the advice is for the
    /// browser an agent is driving, and the roster is where the user says
    /// which that is.
    public static func stalling(_ running: [ChromiumBrowser],
                                roster: AgentRoster) -> [ChromiumBrowser] {
        running.filter { roster.carries($0.bundleID) && !$0.isProtected }
    }

    /// The command that would start one with what it needs, for a user who
    /// would rather do it themselves than have an app restart their browser.
    public static func launchCommand(for browser: ChromiumBrowser) -> String {
        "open -b \(browser.bundleID) --args " + ChromiumOcclusion.flags.joined(separator: " ")
    }
}
