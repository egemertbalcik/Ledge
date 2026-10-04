import Foundation
import LedgeCore

/// One JSON line emitted by `LedgeMediaAdapter`.
///
/// Deliberately separate from `NowPlayingSnapshot` and completely pure: no
/// subprocess, no AppKit, no clock of its own. That makes the whole decode path
/// — which is the part most likely to break when Apple changes a key — testable
/// against captured fixture lines.
public struct AdapterPayload: Decodable, Equatable, Sendable {

    public enum Kind: String, Decodable, Sendable {
        case hello
        case now
        case heartbeat
    }

    public var adapter: Int?
    public var ok: Bool?
    public var kind: Kind?
    /// When the helper built this line, epoch seconds.
    public var t: Double?

    /// `nil` means nothing is loaded at all. `false` means loaded but paused.
    public var playing: Bool?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: Double?
    public var elapsed: Double?
    /// The instant `elapsed` was measured, epoch seconds. Without this the
    /// position would freeze between updates.
    public var elapsedAt: Double?
    public var rate: Double?
    public var trackID: String?

    public var bundleID: String?
    public var parentBundleID: String?
    public var displayName: String?
    public var pid: Int?

    /// `"audio"`, `"video"`, or absent. Only the players that bother to set
    /// the system's media type report anything here — a browser sends nothing,
    /// which is why `MediaKind.resolve` exists.
    public var mediaType: String?

    /// The system's own word that this has no end: a broadcast, a radio
    /// station, a match being played right now. Absent for anything that has
    /// never had to say.
    public var live: Bool?

    public var artworkID: String?
    public var artworkMIME: String?
    /// Base64. Sent only when `artworkID` changes, so most lines omit it.
    public var artwork: String?

    /// Whether this line carries playable metadata rather than a handshake,
    /// a heartbeat, or an explicit "nothing is loaded".
    public var describesTrack: Bool {
        kind == .now && playing != nil && !(title ?? "").isEmpty
    }

    /// Turns the line into a snapshot, projecting the elapsed time forward to
    /// `now`.
    ///
    /// The projection is what lets a *pull*-based `NowPlayingSource` sit on top
    /// of a *push* stream: MediaRemote reports the position once, stamped with
    /// the moment it was measured, so a cached value replayed verbatim would
    /// freeze the scrub bar. Extrapolating from the stamp gives a fresh, correct
    /// position on every poll from a single stale event.
    ///
    /// - Parameter resolveApp: supplies a display name for a pid when the
    ///   helper could not name the app. Injected so this file never needs
    ///   AppKit.
    public func snapshot(
        at now: Double,
        resolveApp: (Int) -> (name: String, bundleID: String)? = { _ in nil }
    ) -> NowPlayingSnapshot? {
        guard describesTrack else { return nil }

        let resolved = pid.flatMap(resolveApp)
        // The *parent* first: a browser reports its media through a helper
        // process (`com.apple.WebKit.GPU`), and every question worth asking
        // about the owner — which app is this, is it the one covering the
        // screen, what should the card be called — is a question about Safari.
        let bundle = parentBundleID ?? bundleID ?? resolved?.bundleID
        guard let bundle, !bundle.isEmpty else { return nil }

        let name = displayName ?? resolved?.name ?? bundle
        let total = max(0, duration ?? 0)
        let playbackRate = rate ?? (playing == true ? 1 : 0)

        var position = max(0, elapsed ?? 0)
        if let elapsedAt, playbackRate > 0 {
            // A stamp in the future (clock skew) must not rewind the bar.
            let delta = max(0, now - elapsedAt)
            position += delta * playbackRate
        }
        if total > 0 { position = min(position, total) }

        return NowPlayingSnapshot(
            title: title ?? "",
            artist: artist ?? "",
            album: album ?? "",
            isPlaying: playing ?? false,
            elapsed: position,
            duration: total,
            appName: name,
            appBundleID: bundle,
            // Prefer the player's own identity; fall back to the artwork digest,
            // then to the default metadata key.
            trackKey: trackID.map { "\(bundle)|\($0)" } ?? artworkID.map { "\(bundle)|\($0)" },
            artworkID: artworkID,
            artworkData: artwork.flatMap { Data(base64Encoded: $0) },
            // The system's word when it gives one. When it does not, a thing
            // that is playing with no duration at all has no end to show, and
            // whether that is a broadcast or a stream of unknown length makes
            // no difference to how it should be drawn.
            isLive: live ?? (total <= 0 && playing == true),
            kind: MediaKind.resolve(
                reported: mediaType.flatMap(MediaKind.init(rawValue:)),
                bundleID: bundle,
                duration: total
            )
        )
    }
}

/// Splits a byte stream into newline-delimited lines.
///
/// A pipe hands over arbitrary chunks — half a line, three lines, a line split
/// mid-UTF8 — so the reader cannot assume one read is one message.
public struct LineBuffer: Sendable {

    /// Beyond this a single line is assumed to be corrupt and dropped, rather
    /// than growing the buffer without limit.
    public static let maximumLineLength = 8 * 1024 * 1024

    private var pending = Data()
    /// Set while discarding an over-long line, so its tail is not mistaken for
    /// the start of the next one.
    private var discarding = false

    public init() {}

    /// Appends a chunk and returns whatever complete lines it finished.
    public mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []

        while let index = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<index]
            pending = pending[pending.index(after: index)...]
            if discarding {
                discarding = false
            } else if !line.isEmpty {
                lines.append(Data(line))
            }
        }

        if pending.count > Self.maximumLineLength {
            pending.removeAll(keepingCapacity: false)
            discarding = true
        }
        return lines
    }
}
