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

    /// A LaunchServices database that answers nothing — mid-rebuild after an
    /// OS update — must not make the default browser look like a native
    /// player for the rest of the session, so no answer is not cached.
    @Test("A missing answer is retried rather than believed")
    func emptyLookupNotCached() {
        var answers: [String?] = [nil, "com.example.newbrowser"]
        let catalogue = BrowserCatalogue(
            lookup: { answers.isEmpty ? nil : answers.removeFirst() }
        )
        #expect(catalogue.isWebOwner(bundleID: "com.example.newbrowser") == false, "nothing known yet")
        #expect(catalogue.isWebOwner(bundleID: "com.example.newbrowser"), "the second answer sticks")
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
