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

@MainActor
public protocol NowPlayingCommanding: AnyObject {
    /// Returns whether the command was dispatched. `false` means the caller
    /// should not optimistically update the UI.
    @discardableResult
    func send(_ command: NowPlayingCommand, to bundleID: String) -> Bool
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
