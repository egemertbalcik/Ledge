import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

/// The web-media switches are only as good as the answer to "is this a
/// browser", and neither a fixed list nor "everything that can open a link"
/// is that answer on its own.
@Suite("Browser catalogue")
@MainActor
struct BrowserCatalogueTests {

    private func catalogue(default browser: String?) -> BrowserCatalogue {
        BrowserCatalogue(lookup: { browser })
    }

    @Test("A player is not a web owner")
    func playersAreApps() {
        let catalogue = catalogue(default: "com.apple.Safari")
        #expect(catalogue.isWebOwner(bundleID: "com.spotify.client") == false)
        #expect(catalogue.isOpenableApp(bundleID: "com.apple.Music"))
    }

    @Test("The browsers we list, and their helper processes, are web owners")
    func knownBrowsers() {
        let catalogue = catalogue(default: nil)
        #expect(catalogue.isWebOwner(bundleID: "com.apple.Safari"))
        #expect(catalogue.isWebOwner(bundleID: "com.google.Chrome"))
        #expect(catalogue.isWebOwner(bundleID: "com.apple.WebKit.GPU"))
    }

    /// The curated identifiers are written in the case their applications
    /// register, and a media source need not report the same case.
    @Test("The curated list is matched without regard to case")
    func curatedIsCaseInsensitive() {
        let catalogue = catalogue(default: nil)
        #expect(catalogue.isWebOwner(bundleID: "COM.APPLE.SAFARI"))
        #expect(catalogue.isWebOwner(bundleID: "com.Google.chrome"))
    }

    /// A source that cannot name itself has nothing to bring forward, and the
    /// quieter reading of an unknown is that it is not an app of its own.
    @Test("An unnamed source is treated as a page")
    func unnamedIsWeb() {
        #expect(catalogue(default: nil).isWebOwner(bundleID: ""))
    }

    /// The case the type exists for: the browser somebody actually browses
    /// with, which nobody here listed. With a fixed list alone its media
    /// would be shown despite the switch being off.
    @Test("An unlisted default browser is still read as a page")
    func unlistedDefaultRecognised() {
        let catalogue = catalogue(default: "com.example.NewBrowser")
        #expect(catalogue.isWebOwner(bundleID: "com.example.newbrowser"))
        #expect(catalogue.isWebOwner(bundleID: "com.example.NEWBROWSER"), "either way round")
        #expect(catalogue.isOpenableApp(bundleID: "com.example.newbrowser") == false)
        #expect(MediaOwner.browsers.contains("com.example.NewBrowser") == false, "truly unlisted")
    }

    /// The regression this design exists to prevent. Every one of these is a
    /// registered HTTPS handler on a normal Mac — measured on this one, by
    /// querying LaunchServices — and not one of them is a browser. Reading
    /// them as pages would hide their media by default, refuse to bring them
    /// forward, and hand them a browser's handover rules.
    @Test("Registered HTTPS handlers that are not browsers stay applications", arguments: [
        "com.parallels.desktop.console",
        "com.openai.codex",
        "com.openai.chat",
        "com.googlecode.iterm2",
    ])
    func otherHandlersAreNotBrowsers(bundleID: String) {
        // Safari is the default here, as it is out of the box; the others are
        // handlers alongside it, and only the default one counts.
        let catalogue = catalogue(default: "com.apple.Safari")
        #expect(catalogue.isWebOwner(bundleID: bundleID) == false)
        #expect(catalogue.isOpenableApp(bundleID: bundleID))
        #expect(catalogue.isWebOwner(bundleID: "com.apple.Safari"), "while the browser is one")
    }

    /// Installing a browser, making it the default and playing something in
    /// it must not need a relaunch of Ledge. The launch notification only
    /// covers applications started after the cache was filled, so an owner
    /// nobody has classified before is asked about afresh.
    @Test("An unfamiliar owner revalidates the cached default")
    func unfamiliarOwnerRevalidates() {
        let answers = Box(["com.apple.safari", "com.example.newbrowser"])
        let catalogue = BrowserCatalogue(lookup: {
            answers.value.isEmpty ? nil : answers.value.removeFirst()
        })

        #expect(catalogue.isWebOwner(bundleID: "com.apple.Safari"), "the curated list, no lookup needed")
        // The cache now holds Safari. A stranger arrives.
        #expect(
            catalogue.isWebOwner(bundleID: "com.example.NewBrowser"),
            "an unfamiliar owner was judged against a stale answer"
        )
    }

    /// And the re-reading is bounded: a stranger is only a stranger once, so
    /// a player that is not a browser does not cost a LaunchServices read on
    /// every poll.
    @Test("A familiar owner is not re-judged")
    func familiarOwnerIsNotReJudged() {
        let reads = Box(0)
        let catalogue = BrowserCatalogue(lookup: {
            reads.value += 1
            return "com.apple.safari"
        })
        for _ in 0..<10 {
            #expect(catalogue.isWebOwner(bundleID: "com.spotify.client") == false)
        }
        #expect(reads.value <= 2, "LaunchServices was read \(reads.value) times for one owner")
    }

    /// The gap the launch notification cannot cover: an application that was
    /// already running — judged a native player then — and is afterwards made
    /// the default browser. Nothing launches, so nothing invalidates; the TTL
    /// is what reconsiders it.
    @Test("An app that becomes the default while running is reconsidered")
    func alreadyRunningAppBecomesDefault() {
        let clock = Box(TimeInterval(1_000))
        let handler = Box("com.apple.safari")
        let catalogue = BrowserCatalogue(lookup: { handler.value }, now: { clock.value })

        // Seen while Safari is the default: an application, and its media is
        // shown.
        #expect(catalogue.isWebOwner(bundleID: "com.example.player") == false)

        // The user makes it their default browser. It never relaunched.
        handler.value = "com.example.player"
        #expect(
            catalogue.isWebOwner(bundleID: "com.example.player") == false,
            "the cached answer is still inside its window"
        )

        clock.value += BrowserCatalogue.defaultBrowserTTL + 1
        #expect(
            catalogue.isWebOwner(bundleID: "com.example.player"),
            "a browser that became the default while running was never reconsidered"
        )
    }

    /// And the window is what keeps this off the media poll: a familiar owner
    /// with a fresh answer asks LaunchServices nothing.
    @Test("A familiar owner inside the window costs no query")
    func familiarOwnerInsideWindowCostsNothing() {
        let reads = Box(0)
        let clock = Box(TimeInterval(1_000))
        let catalogue = BrowserCatalogue(
            lookup: { reads.value += 1; return "com.apple.safari" },
            now: { clock.value }
        )
        for _ in 0..<50 {
            clock.value += 1   // a poll a second, as the provider does
            _ = catalogue.isWebOwner(bundleID: "com.spotify.client")
        }
        #expect(
            reads.value <= 2,
            "LaunchServices was read \(reads.value) times across fifty polls"
        )
    }

    /// The false positives stay protected: these are all registered HTTPS
    /// handlers on a normal Mac, and the TTL must not start letting them in.
    @Test("Non-browser handlers stay applications across the window", arguments: [
        "com.parallels.desktop.console", "com.openai.codex", "com.googlecode.iterm2",
    ])
    func handlersStayApplicationsAcrossTheWindow(bundleID: String) {
        let clock = Box(TimeInterval(1_000))
        let catalogue = BrowserCatalogue(lookup: { "com.apple.safari" }, now: { clock.value })
        for _ in 0..<5 {
            #expect(catalogue.isWebOwner(bundleID: bundleID) == false)
            clock.value += BrowserCatalogue.defaultBrowserTTL + 1
        }
    }

    /// A LaunchServices database that answers nothing — mid-rebuild after an
    /// OS update — must not make the default browser look like a native
    /// player for the rest of the session, so no answer is not cached.
    @Test("A missing answer is retried rather than believed")
    func emptyLookupNotCached() {
        let answers = Box([String?](repeating: nil, count: 2))
        let catalogue = BrowserCatalogue(
            lookup: { answers.value.isEmpty ? nil : answers.value.removeFirst() }
        )
        // Nothing to go on: the owner is treated as an application, which is
        // the quieter mistake — its media stays visible.
        #expect(catalogue.isWebOwner(bundleID: "com.example.newbrowser") == false)

        // And the nil was never cached as an answer, so a database that has
        // finished rebuilding is believed as soon as it speaks.
        let later = Box<[String?]>(["com.example.newbrowser"])
        let recovered = BrowserCatalogue(
            lookup: { later.value.isEmpty ? nil : later.value.removeFirst() }
        )
        #expect(recovered.isWebOwner(bundleID: "com.example.newbrowser"))
    }

    /// And the production lookup works: Safari is the handler for web pages
    /// out of the box, so an empty answer here means the query is broken
    /// rather than that this Mac has no browser.
    @Test("The system names a default browser")
    func systemNamesOne() {
        let found = BrowserCatalogue.preferredWebHandler()?.lowercased()
        #expect(found != nil, "LaunchServices named no handler for https")
        if let found {
            #expect(
                BrowserCatalogue.shared.isWebOwner(bundleID: found),
                "whatever it is, the default browser is a page's owner"
            )
        }
    }
}

/// A value a test can change while a `@Sendable` closure reads it. The
/// closures here are `@MainActor`, and every test using one is too, so a plain
/// box is enough — capturing a `var` directly is what the compiler objects to.
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
