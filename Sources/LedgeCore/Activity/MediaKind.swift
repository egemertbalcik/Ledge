import Foundation

/// Whether what is playing is something you listen to or something you watch.
///
/// The distinction decides how much of the notch a player may take: music
/// earns a resting place in the ears, because glancing at what is playing is
/// the whole point. A film does not — the screen already has your attention,
/// and a countdown of the runtime hanging off the top of it is the opposite of
/// what anyone wants while watching.
public enum MediaKind: String, Equatable, Sendable, Codable {
    case audio
    case video

    /// Long enough that nothing shorter is worth a card at all. Notification
    /// stings, autoplaying advertisements and preview clips all register with
    /// the system exactly as music does; a card that appears and leaves before
    /// it can be read is noise with a scrub bar.
    public static let shortestWorthShowing: TimeInterval = 60

    /// Long enough to be worth the compact view — and, for the sources that
    /// will not say what they are, the line between a clip and something being
    /// watched properly.
    ///
    /// Two minutes, doing both jobs with one number: below it a video is a
    /// clip that will be gone before the ears finish opening, and above it the
    /// notch treats it as it treats a track.
    public static let longFormDuration: TimeInterval = 2 * 60

    /// Apps whose media is always watched, whatever they report.
    static let videoApps: Set<String> = [
        "com.apple.TV",
        "com.apple.QuickTimePlayerX",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "com.firecore.infuse",
        "tv.plex.desktop",
        "com.netflix.Netflix",
    ]

    /// Apps whose media is always listened to.
    static let audioApps: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
        "com.apple.podcasts",
        "com.apple.iTunes",
        "com.tidal.desktop",
        "com.soundcloud.desktop",
        "org.videolan.vlc.audio",
    ]

    /// Decides what is playing, from the strongest signal available.
    ///
    /// The system reports a media type — but only for apps that bother to set
    /// it. Measured on macOS 26: Spotify sets it, and a video playing in a
    /// browser sends no type, no artwork and no album, just a title, a channel
    /// name and a runtime. Browsers are also where films and episodes actually
    /// live, so the ladder cannot stop at the reported type:
    ///
    /// 1. What the source says, when it says anything.
    /// 2. What the app is, for the players that are only ever one or the other.
    /// 3. How long it runs — the last resort, and the only signal a browser
    ///    gives us. Anything past `longFormDuration` from a source that will
    ///    not identify itself is treated as watched.
    ///
    /// That last rung is coarse on purpose: a song streamed through a browser
    /// lands on the video side of it. Nothing is lost by that while video is
    /// shown in the compact view, which is the default — it only matters to
    /// someone who has turned video off, and they have said what they want.
    ///
    /// A source of unknown length (a live stream reports no duration) is taken
    /// as audio: radio is the common case, and the cost of being wrong is a
    /// companion the user can switch off.
    public static func resolve(
        reported: MediaKind?,
        bundleID: String,
        duration: TimeInterval
    ) -> MediaKind {
        if let reported { return reported }
        if videoApps.contains(bundleID) { return .video }
        if audioApps.contains(bundleID) { return .audio }
        return duration >= longFormDuration ? .video : .audio
    }

    /// Whether something this short should appear at all. Unknown lengths pass:
    /// a live stream reports nothing, and silence is not a reason to hide it.
    public static func isWorthShowing(duration: TimeInterval) -> Bool {
        guard duration > 0 else { return true }
        return duration >= shortestWorthShowing
    }
}
