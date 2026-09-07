import Foundation
import Testing

@testable import LedgeCore
@testable import LedgeSystem

/// What happens when two things are making sound at once.
///
/// The notch has one seat and no way to ask which one the user means, so the
/// rules are about *what kind* of thing each one is. A page that starts while
/// an app plays is autoplay until proven otherwise; anything else is somebody
/// pressing play.
@Suite("Media handover between players")
@MainActor
struct MediaHandoverTests {

    private final class Source: NowPlayingSource {
        let identifier: String
        var isAvailable = true
        var value: NowPlayingSnapshot?
        init(identifier: String, value: NowPlayingSnapshot? = nil) {
            self.identifier = identifier
            self.value = value
        }
        func snapshot() async -> NowPlayingSnapshot? { value }
        func expectChange() {}
    }

    private final class Clock { var now: TimeInterval = 1_000 }

    private static let spotify = "com.spotify.client"
    private static let chrome = "com.google.Chrome"
    private static let safari = "com.apple.Safari"

    private func track(
        _ bundleID: String,
        title: String,
        playing: Bool = true,
        elapsed: TimeInterval = 10
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title,
            artist: "A",
            isPlaying: playing,
            elapsed: elapsed,
            duration: 300,
            appName: bundleID,
            appBundleID: bundleID,
            trackKey: "\(bundleID)-\(title)"
        )
    }

    private func composite(
        adapter: Source,
        scripting: Source,
        clock: Clock
    ) -> CompositeNowPlayingSource {
        CompositeNowPlayingSource(
            adapter: adapter,
            scripting: scripting,
            scriptedSnapshot: { _ in nil },
            scriptingHandles: { $0 == Self.spotify },
            now: { clock.now },
            lastTransportAt: { 0 }
        )
    }

    @Test("A page that starts playing does not take the notch from an app")
    func autoplayDoesNotStealFromAnApp() async {
        let clock = Clock()
        // Spotify is playing and holds the seat.
        let adapter = Source(identifier: "adapter", value: track(Self.spotify, title: "Song"))
        let scripting = Source(identifier: "scripting", value: track(Self.spotify, title: "Song"))
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        // A tab starts playing — and keeps claiming to, for a good while.
        adapter.value = track(Self.chrome, title: "Autoplaying clip")
        for _ in 0..<10 {
            clock.now += 1
            let answer = await source.snapshot()
            #expect(answer?.appBundleID == Self.spotify, "the music keeps the notch")
        }
    }

    @Test("An app that starts playing takes the notch from a page")
    func appTakesOverFromAPage() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.chrome, title: "Video"))
        let scripting = Source(identifier: "scripting", value: track(Self.chrome, title: "Video"))
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        adapter.value = track(Self.spotify, title: "Song")
        var answer: NowPlayingSnapshot?
        for _ in 0..<6 {
            clock.now += 1
            answer = await source.snapshot()
        }
        #expect(answer?.appBundleID == Self.spotify)
    }

    @Test("A paused incumbent gives the seat up at once")
    func pausedIncumbentYields() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.spotify, title: "Song"))
        let scripting = Source(identifier: "scripting", value: track(Self.spotify, title: "Song"))
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        // The music is paused, and a page is playing.
        scripting.value = track(Self.spotify, title: "Song", playing: false)
        adapter.value = track(Self.chrome, title: "Video")
        clock.now += 1
        var answer = await source.snapshot()
        // Corroboration still applies within the stream, so give it a beat.
        clock.now += 2
        answer = await source.snapshot()
        #expect(answer?.appBundleID == Self.chrome, "nothing is holding the seat")
    }

    @Test("One page does not hold the notch against another page")
    func pageYieldsToPage() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.chrome, title: "First"))
        let scripting = Source(identifier: "scripting", value: nil)
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        adapter.value = track(Self.safari, title: "Second")
        var answer: NowPlayingSnapshot?
        for _ in 0..<6 {
            clock.now += 1
            answer = await source.snapshot()
        }
        #expect(answer?.appBundleID == Self.safari)
    }
}
