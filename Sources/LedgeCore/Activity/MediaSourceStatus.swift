import Foundation

/// Where the app's knowledge of what is playing comes from, in the user's
/// terms rather than the implementation's.
///
/// It matters because the answer can change while the app runs and the
/// difference is visible: with the system-wide route working, a video in a
/// browser appears in the notch; without it, only Music and Spotify do. When
/// that route quietly stopped working there was nothing anywhere — no card, no
/// setting, no log a user could reach — to say why YouTube had stopped
/// showing up. This is that missing sentence.
public enum MediaSourceStatus: Equatable, Sendable {

    /// The system-wide route works: anything the Mac is playing can appear.
    case systemWide(host: String)

    /// The route was working and stopped answering, so the app has fallen back
    /// to asking Music and Spotify directly. It retries on its own.
    case degraded(retryingInSeconds: Int)

    /// No system-wide route on this Mac at all — nothing to fall back *from*.
    case playersOnly

    public var headline: String {
        switch self {
        case .systemWide: "Everything playing on this Mac"
        case .degraded: "Music and Spotify only"
        case .playersOnly: "Music and Spotify only"
        }
    }

    public var detail: String {
        switch self {
        case .systemWide(let host):
            return "Ledge can see any player, including video in a browser. It reads this through \(host), a component macOS ships."
        case .degraded(let seconds):
            let minutes = max(1, Int((Double(seconds) / 60).rounded()))
            return "The system-wide reader stopped answering, so Ledge is asking Music and Spotify directly. Video in a browser will not appear until it recovers. Trying again in about \(minutes) minute\(minutes == 1 ? "" : "s")."
        case .playersOnly:
            return "This Mac has no component Ledge can use to read system-wide playback, so only Music and Spotify appear. Video in a browser will not."
        }
    }

    /// Whether this is the good state. Drives the colour of the row.
    public var isFull: Bool {
        if case .systemWide = self { return true }
        return false
    }
}
