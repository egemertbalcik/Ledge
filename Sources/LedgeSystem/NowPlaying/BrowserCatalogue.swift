import AppKit
import Foundation
import LedgeCore
import os

/// Which applications own web pages rather than media of their own.
///
/// Two sources, and neither is "everything that can open a link". That query —
/// `urlsForApplications(toOpen:)` — returns every registered HTTPS handler,
/// which on a normal Mac means Parallels Desktop, ChatGPT and iTerm alongside
/// Safari and Chrome. Treating those as pages would hide their media by
/// default, refuse to bring them forward, and give them a browser's handover
/// rules: a worse failure than the one a fixed list has.
///
/// So:
///
/// 1. `MediaOwner.browsers`, the curated set — the browsers we know, plus the
///    helper processes a browser's audio is attributed to, which are
///    registered to open nothing at all.
/// 2. The user's *preferred* HTTPS handler, from the singular
///    `urlForApplication(toOpen:)`. One answer, and the one that matters: the
///    browser somebody actually browses with, including one that did not exist
///    when the curated set was written.
///
/// A secondary browser that is neither the default nor curated reads as an
/// application until its identifier is added to `MediaOwner.browsers`. That is
/// the known limit of this, and it fails in the quieter direction — media
/// shown, card openable — rather than hiding an app's own player.
///
/// The preferred handler is resolved once and cached. It changes when somebody
/// changes their default browser, which happens after an install, which is
/// what the launch notification catches.
@MainActor
public final class BrowserCatalogue {

    public static let shared = BrowserCatalogue()

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "nowplaying")

    /// The curated identifiers, lowercased once: LaunchServices is
    /// case-insensitive about them and a media source need not report the same
    /// case the application registered.
    private static let curated = Set(MediaOwner.browsers.map { $0.lowercased() })

    /// The default browser's identifier, lowercased, or nil until asked.
    private var preferred: String??

    private var observer: NSObjectProtocol?

    /// Where the default browser comes from. Injectable so a test can ask what
    /// happens with a browser that is not installed here and not curated,
    /// which is the case this type exists for.
    private let lookup: @MainActor () -> String?

    init(lookup: @escaping @MainActor () -> String? = BrowserCatalogue.preferredWebHandler) {
        self.lookup = lookup
        // A browser installed while Ledge runs — and made the default, which
        // is what installing one usually means — would otherwise read as a
        // native player until the next launch. There is no "an app was
        // installed" notification, but a newly installed application gets
        // launched, so an unfamiliar one launching is the signal: drop the
        // cached answer and let the next question re-read it.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier?.lowercased()
            Task { @MainActor in
                guard let self else { return }
                // The browser we already resolved, or a curated one, tells us
                // nothing new. Anything else costs one LaunchServices read at
                // the next question — a few milliseconds, against an event
                // that happens a handful of times an hour.
                if let id, id == (self.preferred ?? nil) || Self.curated.contains(id) { return }
                self.preferred = nil
            }
        }
    }

    /// Whether this is a web page's owner rather than an application's.
    ///
    /// True for a browser, for a browser's content or GPU helper process, and
    /// for anything that could not name itself — an empty identifier belongs
    /// to a source with nothing to bring forward, and the quieter reading of
    /// an unknown is that it is not an app of its own.
    public func isWebOwner(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return true }
        let id = bundleID.lowercased()
        if Self.curated.contains(id) { return true }
        return id == defaultBrowser()
    }

    /// Whether clicking this card should bring its owner forward — the
    /// question `MediaOwner.isOpenableApp` answers, asked of the system.
    public func isOpenableApp(bundleID: String) -> Bool {
        !isWebOwner(bundleID: bundleID)
    }

    /// The default browser's identifier, lowercased, or nil if the system
    /// names none.
    func defaultBrowser() -> String? {
        if let preferred { return preferred }
        let found = lookup()?.lowercased()
        // A nil answer is not cached as an answer: a LaunchServices database
        // that has not finished rebuilding after an OS update would otherwise
        // make the default browser look like a native player for the rest of
        // the session.
        guard let found else { return nil }
        preferred = found
        Self.log.notice("default browser: \(found, privacy: .public)")
        return found
    }

    /// The application the system would open a web page with.
    ///
    /// Singular on purpose — see the note on this type. The plural query
    /// returns every registered HTTPS handler, most of which are not browsers.
    static func preferredWebHandler() -> String? {
        guard let probe = URL(string: "https://example.com"),
              let url = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
