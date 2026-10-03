import Foundation

/// Whether the thing playing belongs to an application or to a web page.
///
/// The distinction decides whether the media card is a doorway. Clicking a
/// Music or Spotify card and having the app come forward is the same gesture
/// as clicking a widget; clicking a card that says "YouTube" and having the
/// browser come forward is not the same promise at all — the browser may be on
/// another Space, showing a different tab entirely, and the page that owns the
/// sound is one of forty. So a website's card stays a card.
public enum MediaOwner {

    /// The browsers we know by name.
    ///
    /// Identified by bundle id rather than by title: every browser reports its
    /// own, they are stable across versions, and the alternative — guessing
    /// from a title — would call a music player named "Safari Sessions" a
    /// browser.
    ///
    /// Not the whole answer, and not meant to be. A browser is something the
    /// *system* can identify — an application registered to open `https` —
    /// and `BrowserCatalogue` asks it that, so a browser nobody here has
    /// heard of is still recognised. This list is the part that needs no
    /// LaunchServices query: the common browsers, and the helper processes
    /// that are registered to open nothing at all.
    public static let browsers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.duckduckgo.macos.browser",
        // The helper processes a browser's audio can be attributed to. The
        // adapter already resolves these to their parent, and naming them here
        // costs nothing against the day one slips through.
        "com.apple.WebKit.GPU",
        "com.apple.WebKit.WebContent",
    ]

    /// Whether clicking this card should bring its owner forward, judged by
    /// the known list alone.
    ///
    /// False for a browser, and false for anything unnamed: an empty bundle id
    /// belongs to a source that could not identify itself, and there is nothing
    /// to bring forward.
    ///
    /// The pure reading, for `LedgeCore` and for tests. Anything that can see
    /// the system should ask `BrowserCatalogue.isOpenableApp(bundleID:)`,
    /// which knows about the browsers this list does not.
    public static func isOpenableApp(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return !browsers.contains(bundleID)
    }
}
