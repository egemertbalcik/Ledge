import Foundation
import os

/// Chooses which now-playing source to use, once, at startup.
///
/// Three outcomes, in descending order of preference:
///
/// 1. **MediaRemote in-process.** Free and system-wide. Gated since macOS 15.4,
///    so this is not reachable today — but if Apple ever lifts it, this costs
///    nothing and needs no subprocess.
/// 2. **The bundled adapter**, run inside `/usr/bin/perl`, which *is* entitled.
///    System-wide: a YouTube tab, VLC, anything. Paired with AppleScript through
///    `CompositeNowPlayingSource` so Music and Spotify keep their existing,
///    known-good path.
/// 3. **AppleScript alone** — the previous behaviour, covering only the players
///    that publish a scripting dictionary.
///
/// `LEDGE_NO_ADAPTER=1` forces (3), for isolating a problem to the adapter.
@MainActor
public enum NowPlayingSourceSelector {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "nowplaying")

    public struct Choice {
        public let source: any NowPlayingSource
        public let reason: String
    }

    public static func choose(
        forceStub: Bool = false,
        probe: @MainActor () async -> Bool = { await MediaRemoteBridge.probeReadAccess() },
        adapterProbe: @MainActor () async -> (dylib: URL, host: AdapterHost)? = {
            await NowPlayingProbe.workingAdapter()
        }
    ) async -> Choice {
        if forceStub {
            // Carries sample data rather than nothing, so the card — marquee,
            // scrubber, transport — can be developed and inspected with no
            // player running and no Automation permission involved.
            return Choice(source: StubNowPlayingSource(value: sampleSnapshot), reason: "forced stub")
        }

        let scripting = ScriptingNowPlayingSource()

        if await probe() {
            // Not reachable on macOS 26.4 today. Left in so the day it becomes
            // reachable is a one-line log change rather than an investigation.
            log.notice("now playing: MediaRemote reads are available in-process")
            return Choice(source: scripting, reason: "MediaRemote readable in-process")
        }

        if let found = await adapterProbe() {
            let adapter = MediaRemoteAdapterSource(dylibURL: found.dylib, host: found.host)
            adapter.start()
            let composite = CompositeNowPlayingSource(adapter: adapter, scripting: scripting)
            log.notice("now playing: using the MediaRemote adapter (system-wide)")
            return Choice(source: composite, reason: "MediaRemote adapter via \(found.host.name)")
        }

        log.notice("""
            now playing: MediaRemote reads gated and no adapter — using AppleScript \
            (available=\(scripting.isAvailable, privacy: .public))
            """)
        return Choice(source: scripting, reason: "MediaRemote gated, using AppleScript")
    }

    /// Invented placeholder data. Long enough to make the title marquee scroll.
    private static var sampleSnapshot: NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: "A Deliberately Overlong Sample Title For Testing",
            artist: "Placeholder Artist",
            album: "Sample Album",
            isPlaying: true,
            elapsed: 74,
            duration: 208,
            appName: "Stub Player",
            appBundleID: "com.egemert.ledge.stub",
            trackKey: "stub"
        )
    }
}
