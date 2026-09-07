import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

/// Answers whatever the test last set, so the clock is the only thing moving.
@MainActor
private final class ScriptedNowPlayingSource: NowPlayingSource {
    let identifier = "scripted"
    var isAvailable = true
    var current: NowPlayingSnapshot?
    func snapshot() async -> NowPlayingSnapshot? { current }
}

private func track(_ title: String, playing: Bool) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        title: title, artist: "Artist", isPlaying: playing,
        appName: "Spotify", appBundleID: "com.spotify.client", trackKey: title
    )
}

@Suite("A paused player lets go of its card")
@MainActor
struct PausedMediaTests {

    /// Drains the stream after stopping — `AsyncStream` buffers, so events
    /// emitted synchronously are still there.
    private func collect(_ provider: NowPlayingProvider, while body: () async -> Void) async -> [ProviderEvent] {
        let stream = provider.start()
        await body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func provider(
        _ source: ScriptedNowPlayingSource,
        now: @escaping () -> TimeInterval
    ) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source,
            artwork: ArtworkLoader(),
            playingInterval: 60,
            idleInterval: 60,
            playbackWatcher: nil,
            now: now
        )
    }

    @Test("A track paused for three quarters of an hour loses its card")
    func pausedCardRetires() async {
        var clock: TimeInterval = 1000
        let source = ScriptedNowPlayingSource()
        let provider = provider(source, now: { clock })

        source.current = track("Bad Habit", playing: false)
        let events = await collect(provider) {
            // First look: paused, but only just — the card belongs on screen.
            await provider.refreshNow()
            clock += NowPlayingProvider.pausedCardLifetime - 60
            await provider.refreshNow()
            // Past the hour's three quarters: nobody is coming back to this.
            clock += 120
            await provider.refreshNow()
        }

        let published = events.filter { if case .publish = $0 { return true } else { return false } }
        let retracted = events.filter { if case .retract = $0 { return true } else { return false } }
        #expect(published.count >= 2, "the card stands while the pause is fresh")
        #expect(retracted.count == 1, "and is taken away once it is stale")
    }

    @Test("Pressing play, or skipping a track, resets the clock")
    func activityResetsTheClock() async {
        var clock: TimeInterval = 1000
        let source = ScriptedNowPlayingSource()
        let provider = provider(source, now: { clock })

        source.current = track("Bad Habit", playing: false)
        let events = await collect(provider) {
            await provider.refreshNow()
            clock += NowPlayingProvider.pausedCardLifetime - 30
            // Somebody is at the keyboard: a different track, still paused.
            source.current = track("Loser", playing: false)
            await provider.refreshNow()
            // Which buys the full lifetime again.
            clock += NowPlayingProvider.pausedCardLifetime - 30
            await provider.refreshNow()
        }

        let retracted = events.contains { if case .retract = $0 { return true } else { return false } }
        #expect(!retracted, "the clock restarted when the track changed")
    }

    @Test("Playing music is never retired, however long it plays")
    func playingIsNeverRetired() async {
        var clock: TimeInterval = 1000
        let source = ScriptedNowPlayingSource()
        let provider = provider(source, now: { clock })

        source.current = track("Bad Habit", playing: true)
        let events = await collect(provider) {
            await provider.refreshNow()
            clock += NowPlayingProvider.pausedCardLifetime * 3
            await provider.refreshNow()
        }
        #expect(!events.contains { if case .retract = $0 { return true } else { return false } })
    }

    @Test("Being interrupted does not restart the pause clock")
    func republishKeepsTheOriginalPauseTime() async {
        var clock: TimeInterval = 1000
        let source = ScriptedNowPlayingSource()
        let provider = provider(source, now: { clock })

        // Paused, then interrupted again and again — a browser clip taking the
        // system's now-playing slot and handing it back, which is what
        // scrolling a feed looks like from in here. Each return used to date
        // the pause afresh, so the card never aged out of the cycle.
        let events = await collect(provider) {
            source.current = track("Bad Habit", playing: false)
            await provider.refreshNow()

            for _ in 0..<4 {
                clock += NowPlayingProvider.pausedCardLifetime / 5
                source.current = nil
                await provider.refreshNow()
                source.current = track("Bad Habit", playing: false)
                await provider.refreshNow()
            }

            clock += NowPlayingProvider.pausedCardLifetime / 5 + 1
            await provider.refreshNow()
        }

        if case .retract = events.last {} else {
            Issue.record("the card outlived its pause: \(String(describing: events.last))")
        }
    }

    @Test("Playing again gives the track a fresh quarter of an hour")
    func playingResetsTheClock() async {
        var clock: TimeInterval = 1000
        let source = ScriptedNowPlayingSource()
        let provider = provider(source, now: { clock })

        let events = await collect(provider) {
            source.current = track("Bad Habit", playing: false)
            await provider.refreshNow()
            clock += NowPlayingProvider.pausedCardLifetime - 60

            source.current = track("Bad Habit", playing: true)
            await provider.refreshNow()
            clock += 120

            source.current = track("Bad Habit", playing: false)
            await provider.refreshNow()
            clock += NowPlayingProvider.pausedCardLifetime - 60
            await provider.refreshNow()
        }

        if case .retract = events.last {
            Issue.record("the pause clock kept counting while the track played")
        }
    }
}

@Suite("Looking at a paused track does not put it back in the ears")
struct PausedMusicRestTests {

    private func music(playing: Bool) -> Activity {
        Activity(
            id: ActivityID(kind: .nowPlaying, source: "spotify"), createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(title: "Track", artist: "Artist", isPlaying: playing))
        )
    }

    @Test("Playing music rests; paused music does not")
    func onlyPlayingRests() {
        #expect(music(playing: true).restsInEars)
        #expect(music(playing: false).restsInEars == false)
    }

    @Test("Opening the card and walking away leaves the notch empty")
    func noFarewellForPausedMusic() {
        // The last resort of the resting chain is the card you last read. A
        // paused track has to earn that seat, and it cannot.
        let paused = music(playing: false)
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: nil, nowPlaying: nil, selected: paused
        ) == nil)
    }

    @Test("A paused track arriving is never an announcement")
    func pausedArrivalIsNotNews() {
        // The card is republished every time something else lets go of the
        // system's now-playing slot, which while a feed scrolls is every few
        // seconds. Each of those is an arrival, and each used to flash a track
        // that stopped hours ago into the notch for a couple of seconds.
        #expect(music(playing: false).isWorthAnnouncing == false)
        #expect(music(playing: true).isWorthAnnouncing)
    }

    @Test("Its linger is untouched — that is the companion's job, not the card's")
    func lingerStillShowsPausedMusic() {
        let paused = music(playing: false)
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: nil, nowPlaying: paused, selected: nil
        ) == paused)
    }
}
