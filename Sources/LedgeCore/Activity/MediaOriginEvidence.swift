import Foundation

/// What Ledge actually knows about where a piece of browser media came from.
///
/// **An asset URL is not a page.** The only URL-shaped thing MediaRemote
/// reports is `kMRMediaRemoteNowPlayingInfoAssetURL`, which describes the
/// *media asset* — and the asset for a YouTube video is served from
/// `googlevideo.com`, a Twitch stream from a Twitch CDN, an embedded player
/// from whatever host the embed uses. Taking that host for the website in the
/// tab gets it wrong in both directions: a rule for `youtube.com` would never
/// match the video actually playing, and a rule for a CDN host would authorise
/// every unrelated site sharing it.
///
/// So the host is never carried on its own. It arrives with how it was
/// learned, and only evidence that can honestly stand for a *web content
/// origin* is allowed to match a user's rule. Everything else is unverified,
/// and unverified browser media stays hidden.
public enum MediaOriginEvidence: Hashable, Sendable {

    /// Nothing at all: no asset URL, or one that is not a web resource.
    case none

    /// A `blob:` URL's inner origin.
    ///
    /// The one signal here that means something. A blob URL's origin is the
    /// origin of the *document that created the blob*, and media-source
    /// playback — which is how YouTube, Twitch and SoundCloud all deliver
    /// audio and video — creates its blob from the page's own script. So
    /// `blob:https://music.youtube.com/…` was made by a document on
    /// `music.youtube.com`.
    ///
    /// **Documented limit:** that is the blob *creator's* origin, not
    /// necessarily the top-level tab. Media inside an embedded iframe reports
    /// the iframe's origin — so a YouTube video embedded in a blog reads as
    /// `youtube.com`, which is the site whose media it is, but is not the
    /// address in the location bar. For an allow list about *whose media may
    /// appear*, the creator origin is the more useful of the two; it is
    /// recorded here so nobody later mistakes it for the tab's address.
    case blobOrigin(WebsiteHost)

    /// An ordinary `http(s)` asset URL: a CDN, a media server, a file on some
    /// host that is almost never the site the user is looking at.
    ///
    /// Kept as a distinct case rather than thrown away, so the reason a page
    /// stays hidden can be explained — but it never matches a rule.
    case directAsset(WebsiteHost)

    /// The website a user's rule may be matched against.
    ///
    /// Nil for everything but a blob origin. This is the single place that
    /// decides what counts as knowing the website, which is why
    /// `WebsitePolicy` takes the evidence rather than a bare host: there is no
    /// shape in the model that can smuggle a CDN host into a rule match.
    public var verifiedWebsite: WebsiteHost? {
        switch self {
        case .blobOrigin(let host): host
        case .none, .directAsset: nil
        }
    }

    /// Whether anything was reported at all — for explaining a hidden card,
    /// never for authorising one.
    public var hasAnyHost: Bool {
        switch self {
        case .none: false
        case .blobOrigin, .directAsset: true
        }
    }

    /// Builds evidence from what the helper reported.
    ///
    /// - Parameters:
    ///   - host: the host of the asset URL, already extracted — never a path
    ///     or a query, which do not travel this far.
    ///   - isBlob: whether that host came from inside a `blob:` URL.
    public static func from(host: String?, isBlob: Bool) -> MediaOriginEvidence {
        guard let host, let website = WebsiteHost(host) else { return .none }
        return isBlob ? .blobOrigin(website) : .directAsset(website)
    }
}
