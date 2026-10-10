import Foundation
import LedgeCore

/// What is playing, right now, wherever it is playing.
public struct NowPlayingSnapshot: Equatable, Sendable {

    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    public var elapsed: TimeInterval
    public var duration: TimeInterval

    /// Human-readable name of the app producing the audio.
    public var appName: String

    /// Bundle id, used as the activity's source key so two players can coexist.
    public var appBundleID: String

    /// Stable identity for the track, for artwork caching. Usually a URL or id
    /// from the player; falls back to the metadata itself.
    public var trackKey: String

    /// Where the artwork can be fetched from, when the player exposes it.
    public var artworkURL: URL?

    /// Identity of artwork that arrived as bytes rather than a URL. Compared
    /// instead of the bytes themselves — see `==` below.
    public var artworkID: String?

    /// Artwork bytes, when the source hands them over directly (MediaRemote
    /// does; AppleScript gives a URL instead).
    public var artworkData: Data?

    /// No end to count down to: a broadcast, a radio station, a match being
    /// played right now.
    public var isLive: Bool

    /// Whether this is watched or listened to. Scripted players (Music,
    /// Spotify) are audio by definition; the adapter path resolves it.
    public var kind: MediaKind

    public init(
        title: String,
        artist: String,
        album: String = "",
        isPlaying: Bool = false,
        elapsed: TimeInterval = 0,
        duration: TimeInterval = 0,
        appName: String,
        appBundleID: String,
        trackKey: String? = nil,
        artworkURL: URL? = nil,
        artworkID: String? = nil,
        artworkData: Data? = nil,
        isLive: Bool = false,
        kind: MediaKind = .audio
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.elapsed = elapsed
        self.duration = duration
        self.appName = appName
        self.appBundleID = appBundleID
        self.trackKey = trackKey ?? "\(appBundleID)|\(artist)|\(album)|\(title)"
        self.artworkURL = artworkURL
        self.artworkID = artworkID
        self.artworkData = artworkData
        self.isLive = isLive
        self.kind = kind
    }

    /// Which cover this item is carrying, as distinct from which item it is.
    ///
    /// The system's artwork id where there is one, the artwork URL otherwise,
    /// and nil when there is no cover at all. Kept apart from `trackKey` on
    /// purpose: covers arrive late, get replaced by better ones, and are
    /// shared between the songs of an album. None of that is a song changing.
    public var artworkRevision: String? {
        if let artworkID, !artworkID.isEmpty { return artworkID }
        return artworkURL?.absoluteString
    }

    /// The key this item's cover is filed under: the item, and which cover it
    /// has.
    ///
    /// The cache was keyed on the item alone, so a revised cover for the same
    /// song found the old image already there and stopped — the better art was
    /// fetched, decoded, and then never shown. With the revision in the key a
    /// replacement is a miss, which is what makes it actually replace.
    public var coverKey: String {
        guard let artworkRevision else { return trackKey }
        return "\(trackKey)#\(artworkRevision)"
    }

    /// Compares artwork by identity, never by bytes.
    ///
    /// This runs on every poll. A cover image is hundreds of kilobytes, and
    /// memcmp-ing it several times a second to learn what `artworkID` already
    /// says would be pure waste — the same lesson `NowPlayingPayload` learned.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.isPlaying == rhs.isPlaying
            && lhs.elapsed == rhs.elapsed
            && lhs.duration == rhs.duration
            && lhs.appName == rhs.appName
            && lhs.appBundleID == rhs.appBundleID
            && lhs.trackKey == rhs.trackKey
            && lhs.artworkURL == rhs.artworkURL
            && lhs.artworkID == rhs.artworkID
            && lhs.kind == rhs.kind
            && lhs.isLive == rhs.isLive
            && (lhs.artworkData == nil) == (rhs.artworkData == nil)
    }
}

/// A place now-playing information can come from.
///
/// Every implementation is interchangeable, which is the whole point: reads via
/// MediaRemote are gated behind an entitlement Apple does not grant, so the
/// working source today is AppleScript. If that changes — or a helper that can
/// read MediaRemote is added — it slots in here and nothing else moves.
@MainActor
public protocol NowPlayingSource: AnyObject {

    var identifier: String { get }

    /// Whether this source can currently produce anything at all.
    var isAvailable: Bool { get }

    /// How long since this source last had anything to say.
    ///
    /// Only the adapter really has an answer: it is fed by a helper that
    /// speaks on change and heartbeats every thirty seconds, so a long gap
    /// means it has stopped watching even though it is still running. Sources
    /// that are asked rather than pushed answer zero — they are never stale,
    /// because they are read on demand.
    var secondsSinceLastLine: TimeInterval { get }

    /// The current state, or nil when nothing is playing.
    func snapshot() async -> NowPlayingSnapshot?

    /// The user just asked for a change — a transport button, a media key.
    ///
    /// Sources that hold a track against interlopers need to know the
    /// difference between a browser handing its slot around and the user
    /// pressing Next. Only the first should be resisted. Default: nothing to
    /// do, because only the composite resists anything.
    func expectChange()
}

extension NowPlayingSource {
    /// Read on demand, so never stale.
    public var secondsSinceLastLine: TimeInterval { 0 }
}

public extension NowPlayingSource {
    func expectChange() {}
}

/// A source that can say when something changed, instead of waiting to be
/// asked again.
///
/// The adapter learns of a play, a pause or a track change the instant the
/// system posts it — but the provider that reads the adapter is a poller, so
/// the news sat in a cache until the next tick. For Music and Spotify that
/// never showed: they post their own notifications and the provider already
/// listens for those. A video in a browser posts nothing of the sort, so
/// pressing play could take the whole idle interval to reach the notch.
@MainActor
public protocol NowPlayingChangePublishing: AnyObject {
    /// Called on the main actor when the source's answer has changed in a way
    /// worth redrawing for. Set to nil to stop listening.
    var onChange: (() -> Void)? { get set }
}

public enum NowPlayingCommand: Equatable, Sendable {
    case playPause
    case next
    case previous
    case seek(TimeInterval)
}

/// What became of a transport command.
///
/// Three answers rather than a Bool, because the two ways of not being
/// confirmed mean opposite things to the card and must not share a value. A
/// press that was refused changed nothing anywhere, so nothing downstream may
/// animate, mark a cache stale or grant a source handover on its account. A
/// press that went out through MediaRemote did happen — it simply cannot be
/// confirmed, and reading that as a refusal would freeze the transport for
/// every player without a scripting dictionary, which is every browser.
public enum NowPlayingDispatch: Equatable, Sendable {

    /// Queued for the player named on the card, in order, and it will run.
    case queued

    /// Sent, but through MediaRemote, which acts on whatever the system
    /// considers now-playing. Nothing comes back to say it landed.
    case unconfirmed

    /// Refused: the player's queue is full, so nothing was sent at all.
    case refused

    /// Refused because the only way left to reach this player would have been
    /// a command the system aims somewhere else.
    ///
    /// Its own case rather than a kind of `refused`, because this one is not
    /// about a player falling behind: it is about not being able to address
    /// the player at all, which is a standing property of that player on this
    /// machine and not a passing condition.
    case wrongPlayer

    /// Whether anything left the app. The card may only show what it asked
    /// for when something did.
    public var wasSent: Bool { self == .queued || self == .unconfirmed }
}

@MainActor
public protocol NowPlayingCommanding: AnyObject {
    /// Says what became of the command. `.refused` means the caller must not
    /// optimistically update the UI, mark caches stale or grant a handover —
    /// nothing was sent.
    @discardableResult
    func send(_ command: NowPlayingCommand, to bundleID: String) -> NowPlayingDispatch
}

/// Fixed data, for previews and for developing the card without a player.
@MainActor
public final class StubNowPlayingSource: NowPlayingSource {

    public let identifier = "stub"
    public var isAvailable: Bool { true }

    private var value: NowPlayingSnapshot?

    public init(value: NowPlayingSnapshot? = nil) {
        self.value = value
    }

    public func set(_ value: NowPlayingSnapshot?) {
        self.value = value
    }

    public func snapshot() async -> NowPlayingSnapshot? { value }
}
