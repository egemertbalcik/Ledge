import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

/// Stands in for either side, counting calls so caching and demotion can be
/// proven by how often each side is actually asked.
@MainActor
private final class FakeSource: NowPlayingSource {
    let identifier: String
    var isAvailable = true
    var value: NowPlayingSnapshot?
    private(set) var calls = 0

    init(identifier: String, value: NowPlayingSnapshot? = nil) {
        self.identifier = identifier
        self.value = value
    }

    func snapshot() async -> NowPlayingSnapshot? {
        calls += 1
        return value
    }
}

/// Counts how often the composite would have spawned `osascript` for one
/// player, and answers with whatever it is told to.
@MainActor
private final class ScriptCounter {
    var value: NowPlayingSnapshot?
    private(set) var calls = 0

    init(value: NowPlayingSnapshot?) {
        self.value = value
    }

    func answer(_ bundleID: String) -> NowPlayingSnapshot? {
        calls += 1
        return value
    }
}

/// A clock the tests move by hand, so cadences and cooldowns need no sleeping.
@MainActor
private final class Clock {
    var now: TimeInterval = 1_000
    var lastTransportAt: TimeInterval = 0
}

private let spotify = "com.spotify.client"
private let music = "com.apple.Music"

private func snapshot(
    bundleID: String,
    title: String = "T",
    isPlaying: Bool = true,
    elapsed: TimeInterval = 10,
    duration: TimeInterval = 200,
    trackKey: String? = nil,
    artworkURL: URL? = nil,
    artworkID: String? = nil,
    artworkData: Data? = nil,
    kind: MediaKind = .audio
) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        title: title,
        artist: "A",
        isPlaying: isPlaying,
        elapsed: elapsed,
        duration: duration,
        appName: bundleID,
        appBundleID: bundleID,
        trackKey: trackKey,
        artworkURL: artworkURL,
        artworkID: artworkID,
        artworkData: artworkData,
        kind: kind
    )
}

@MainActor
private func makeComposite(
    adapter: FakeSource,
    scripting: FakeSource,
    clock: Clock,
    scripted: @escaping (String) async -> NowPlayingSnapshot? = { _ in nil },
    handles: @escaping (String) -> Bool = { $0 == spotify || $0 == music }
) -> CompositeNowPlayingSource {
    CompositeNowPlayingSource(
        adapter: adapter,
        scripting: scripting,
        scriptedSnapshot: scripted,
        scriptingHandles: handles,
        now: { clock.now },
        lastTransportAt: { clock.lastTransportAt }
    )
}

@Suite("Composite scripting cache")
@MainActor
struct CompositeScriptingCacheTests {

    @Test("A playing Spotify is scripted once per cadence, not once per poll")
    func playingIsScriptedOnCadence() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: snapshot(bundleID: spotify, trackKey: "s|1"))
        let counter = ScriptCounter(value: snapshot(bundleID: spotify, title: "scripted", elapsed: 10))
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            clock: clock,
            scripted: { counter.answer($0) }
        )

        // Thirty one-second polls with nothing changing on the adapter's side.
        for _ in 0..<30 {
            _ = await composite.snapshot()
            clock.now += 1
        }
        let cadence = CompositeNowPlayingSource.scriptingCadenceWhilePlaying
        let expected = Int((30 / cadence).rounded(.up))
        #expect(counter.calls <= expected + 1, "scripted \(counter.calls) times in 30 polls")
        #expect(counter.calls >= 2, "the cadence must still refresh the answer")
    }

    @Test("A paused player is scripted even less often")
    func pausedIsScriptedRarely() async {
        let clock = Clock()
        let adapter = FakeSource(
            identifier: "adapter",
            value: snapshot(bundleID: spotify, isPlaying: false, trackKey: "s|1")
        )
        let counter = ScriptCounter(value: snapshot(bundleID: spotify, isPlaying: false))
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            clock: clock,
            scripted: { counter.answer($0) }
        )

        // Fifteen four-second polls: a minute of pause.
        for _ in 0..<15 {
            _ = await composite.snapshot()
            clock.now += 4
        }
        let cadence = CompositeNowPlayingSource.scriptingCadenceWhilePaused
        #expect(counter.calls <= Int((60 / cadence).rounded(.up)) + 1)
    }

    @Test("Between scripted reads the position is projected forward, and clamped")
    func cachedPositionIsProjected() async throws {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: snapshot(bundleID: spotify, trackKey: "s|1"))
        let counter = ScriptCounter(value: snapshot(bundleID: spotify, elapsed: 10, duration: 14))
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            clock: clock,
            scripted: { counter.answer($0) }
        )

        let first = try #require(await composite.snapshot())
        #expect(first.elapsed == 10)

        clock.now += 2
        adapter.value?.elapsed += 2
        let second = try #require(await composite.snapshot())
        #expect(second.elapsed == 12, "the cached answer moves with the clock")
        #expect(counter.calls == 1)

        clock.now += 5
        adapter.value?.elapsed += 5
        let third = try #require(await composite.snapshot())
        #expect(third.elapsed == 14, "never past the end of the track")
    }

    @Test("A paused cached answer does not advance")
    func pausedCacheHolds() async throws {
        let clock = Clock()
        let adapter = FakeSource(
            identifier: "adapter",
            value: snapshot(bundleID: spotify, isPlaying: false, trackKey: "s|1")
        )
        let counter = ScriptCounter(value: snapshot(bundleID: spotify, isPlaying: false, elapsed: 30))
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            clock: clock,
            scripted: { counter.answer($0) }
        )
        _ = await composite.snapshot()
        clock.now += 8
        let later = try #require(await composite.snapshot())
        #expect(later.elapsed == 30)
        #expect(counter.calls == 1)
    }

    @Test("A track change on the adapter's side re-scripts at once")
    func trackChangeRescripts() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: snapshot(bundleID: spotify, trackKey: "s|1"))
        let counter = ScriptCounter(value: snapshot(bundleID: spotify))
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            clock: clock,
            scripted: { counter.answer($0) }
        )
        _ = await composite.snapshot()
        clock.now += 1
        _ = await composite.snapshot()
        #expect(counter.calls == 1)

        adapter.value = snapshot(bundleID: spotify, title: "next", trackKey: "s|2")
        clock.now += 1
        _ = await composite.snapshot()
        #expect(counter.calls == 2)
    }

    @Test("A play-state change on the adapter's side re-scripts at once")
    func playStateChangeRescripts() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: snapshot(bundleID: spotify, trackKey: "s|1"))
        let counter = ScriptCounter(value: snapshot(bundleID: spotify))
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            clock: clock,
            scripted: { counter.answer($0) }
        )
        _ = await composite.snapshot()
        clock.now += 1
        adapter.value?.isPlaying = false
        counter.value = snapshot(bundleID: spotify, isPlaying: false)
        let paused = await composite.snapshot()
        #expect(counter.calls == 2)
        #expect(paused?.isPlaying == false)
    }

    @Test("A transport command invalidates the cache and re-scripts for a burst")
    func transportCommandRescripts() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: snapshot(bundleID: spotify, trackKey: "s|1"))
        let counter = ScriptCounter(value: snapshot(bundleID: spotify))
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            clock: clock,
            scripted: { counter.answer($0) }
        )
        _ = await composite.snapshot()
        clock.now += 1
        _ = await composite.snapshot()
        #expect(counter.calls == 1)

        // The user scrubbed. The provider then reads three times in under a
        // second; each of those must hit the player, not the cache.
        clock.lastTransportAt = clock.now
        clock.now += 0.12
        _ = await composite.snapshot()
        clock.now += 0.26
        _ = await composite.snapshot()
        clock.now += 0.5
        _ = await composite.snapshot()
        #expect(counter.calls == 4)

        // And once the burst is over, the cache is trusted again.
        clock.now += CompositeNowPlayingSource.rescriptBurst
        _ = await composite.snapshot()
        clock.now += 1
        _ = await composite.snapshot()
        #expect(counter.calls == 4)
    }

    @Test("A seek made in the player itself shows as a position jump and re-scripts")
    func adapterPositionJumpRescripts() async throws {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: snapshot(bundleID: spotify, elapsed: 10, trackKey: "s|1"))
        let counter = ScriptCounter(value: snapshot(bundleID: spotify, elapsed: 10))
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            clock: clock,
            scripted: { counter.answer($0) }
        )
        _ = await composite.snapshot()
        clock.now += 1
        adapter.value?.elapsed = 11
        _ = await composite.snapshot()
        #expect(counter.calls == 1)

        clock.now += 1
        adapter.value?.elapsed = 90  // scrubbed in Spotify's own window
        counter.value = snapshot(bundleID: spotify, elapsed: 90)
        let after = try #require(await composite.snapshot())
        #expect(counter.calls == 2)
        #expect(after.elapsed == 90)
    }

    @Test("With the adapter silent, the scripting source is asked on cadence, not per poll")
    func silentAdapterFallbackIsCached() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: nil)
        // Music merely open: nothing playing, but each ask would spawn.
        let scripting = FakeSource(identifier: "scripting", value: nil)
        let composite = makeComposite(adapter: adapter, scripting: scripting, clock: clock)

        for _ in 0..<15 {
            _ = await composite.snapshot()
            clock.now += 4
        }
        let cadence = CompositeNowPlayingSource.scriptingCadenceWhilePaused
        #expect(scripting.calls <= Int((60 / cadence).rounded(.up)) + 1)
    }

    @Test("Music's scripted answer borrows the adapter's artwork bytes")
    func musicBorrowsAdapterArtwork() async throws {
        let clock = Clock()
        let cover = Data([0xFF, 0xD8, 0xFF])
        let adapter = FakeSource(
            identifier: "adapter",
            value: snapshot(bundleID: music, trackKey: "m|adapter", artworkID: "cover-1", artworkData: cover)
        )
        // Music's dictionary has no artwork URL, so the scripted answer has no
        // artwork at all.
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            clock: clock,
            scripted: { _ in snapshot(bundleID: music, title: "scripted", trackKey: "m|scripted") }
        )
        let result = try #require(await composite.snapshot())
        #expect(result.title == "scripted")
        #expect(result.trackKey == "m|scripted", "the scripted identity is kept")
        #expect(result.artworkData == cover)
        #expect(result.artworkID == "cover-1")

        // The cached, projected answer carries it too.
        clock.now += 1
        let later = try #require(await composite.snapshot())
        #expect(later.artworkData == cover)
    }

    @Test("Spotify's own artwork URL is not overridden by adapter bytes")
    func spotifyKeepsItsURL() async throws {
        let clock = Clock()
        let url = URL(string: "https://i.scdn.co/image/abc")!
        let adapter = FakeSource(
            identifier: "adapter",
            value: snapshot(bundleID: spotify, artworkID: "x", artworkData: Data([1]))
        )
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            clock: clock,
            scripted: { _ in snapshot(bundleID: spotify, artworkURL: url) }
        )
        let result = try #require(await composite.snapshot())
        #expect(result.artworkURL == url)
        #expect(result.artworkData == nil)
    }
}

@Suite("Composite demotion cooldown")
@MainActor
struct CompositeDemotionTests {

    private func demote(_ composite: CompositeNowPlayingSource, clock: Clock) async {
        for _ in 0..<CompositeNowPlayingSource.demotionThreshold {
            _ = await composite.snapshot()
            clock.now += 1
        }
    }

    @Test("An unavailable adapter is not counted toward demotion")
    func unavailableAdapterDoesNotCount() async {
        // The first seconds after wake, or a helper mid-restart: absent, not
        // silent. Spotify plainly playing through all of it must not demote.
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: nil)
        adapter.isAvailable = false
        let scripting = FakeSource(identifier: "scripting", value: snapshot(bundleID: spotify))
        let composite = makeComposite(adapter: adapter, scripting: scripting, clock: clock)

        for _ in 0..<(CompositeNowPlayingSource.demotionThreshold * 3) {
            _ = await composite.snapshot()
            clock.now += 1
        }
        #expect(composite.isDemoted == false)
    }

    @Test("Demotion is a cooldown, not the rest of the run")
    func demotionExpires() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: nil)
        let scripting = FakeSource(identifier: "scripting", value: snapshot(bundleID: spotify))
        let composite = makeComposite(adapter: adapter, scripting: scripting, clock: clock)

        await demote(composite, clock: clock)
        #expect(composite.isDemoted)

        clock.now += CompositeNowPlayingSource.demotionCooldown
        #expect(composite.isDemoted == false)

        // And after it, the adapter is asked again on the next poll.
        adapter.value = snapshot(bundleID: "com.google.Chrome", title: "Video")
        let result = await composite.snapshot()
        #expect(result?.title == "Video")
    }

    @Test("An adapter that answers while demoted is restored at once")
    func adapterAnswerUndemotes() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: nil)
        let scripting = FakeSource(identifier: "scripting", value: snapshot(bundleID: spotify))
        let composite = makeComposite(adapter: adapter, scripting: scripting, clock: clock)

        await demote(composite, clock: clock)
        #expect(composite.isDemoted)

        // A browser tab starts playing: the adapter has an answer again.
        adapter.value = snapshot(bundleID: "com.google.Chrome", title: "Video")
        clock.now += CompositeNowPlayingSource.demotedProbeInterval
        let result = await composite.snapshot()
        #expect(result?.title == "Video")
        #expect(composite.isDemoted == false)
    }

    @Test("While demoted the adapter is peeked at only occasionally")
    func demotedProbesAreSparse() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: nil)
        let scripting = FakeSource(identifier: "scripting", value: snapshot(bundleID: spotify))
        let composite = makeComposite(adapter: adapter, scripting: scripting, clock: clock)

        await demote(composite, clock: clock)
        let before = adapter.calls
        // Written against the constant, not a number that happened to be under
        // it: the probe interval has changed once already and this test failed
        // for saying "ten" rather than "less than the interval".
        for _ in 0..<Int(CompositeNowPlayingSource.demotedProbeInterval - 1) {
            _ = await composite.snapshot()
            clock.now += 1
        }
        #expect(adapter.calls == before, "polls inside the interval, no probe yet")
        clock.now += CompositeNowPlayingSource.demotedProbeInterval
        _ = await composite.snapshot()
        #expect(adapter.calls == before + 1)
    }
}


private let chrome = "com.google.Chrome"

@Suite("Whoever was playing first keeps the notch")
@MainActor
struct CompositeIncumbencyTests {

    /// The system names whichever player spoke last, so starting a video with
    /// music already going used to hand the compact view straight to the
    /// video — replacing the thing the user had been listening to with the
    /// thing they had not chosen to look at.
    @Test("A newcomer does not displace a player that is still going")
    func incumbentKeepsTheSeat() async {
        let clock = Clock()
        let scripting = FakeSource(
            identifier: "scripting",
            value: snapshot(bundleID: spotify, title: "Bad Habit")
        )
        let adapter = FakeSource(identifier: "adapter", value: snapshot(bundleID: spotify, title: "Bad Habit"))
        let composite = makeComposite(adapter: adapter, scripting: scripting, clock: clock)

        // Spotify takes the seat first.
        #expect(await composite.snapshot()?.title == "Bad Habit")

        // A video starts; the system now names the browser.
        clock.now += 5
        adapter.value = snapshot(bundleID: chrome, title: "Dune", duration: 9000, kind: .video)
        #expect(await composite.snapshot()?.title == "Bad Habit", "the music was here first")
    }

    @Test("Pausing gives up the seat, and resuming does not take it back")
    func pauseResetsSeniority() async {
        let clock = Clock()
        let scripting = FakeSource(identifier: "scripting", value: snapshot(bundleID: spotify))
        let adapter = FakeSource(identifier: "adapter", value: snapshot(bundleID: spotify))
        let composite = makeComposite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await composite.snapshot()

        // Paused: seniority is continuous play, not mere presence.
        clock.now += 5
        adapter.value = snapshot(bundleID: spotify, isPlaying: false)
        _ = await composite.snapshot()

        // A video starts while it is paused, and takes the seat.
        clock.now += 5
        adapter.value = snapshot(bundleID: chrome, title: "Dune", duration: 9000, kind: .video)
        scripting.value = snapshot(bundleID: spotify, isPlaying: false)
        #expect(await composite.snapshot()?.title == "Dune")
    }

    /// A browser video keeps the notch while it is still playing, even against
    /// music started afterwards — first come, first served does not care which
    /// app is which. Once it goes quiet, the music takes over.
    @Test("A browser video holds the notch until it stops")
    func browserIncumbentHoldsThenYields() async {
        let clock = Clock()
        let scripting = FakeSource(identifier: "scripting", value: nil)
        let adapter = FakeSource(
            identifier: "adapter",
            value: snapshot(bundleID: chrome, title: "Dune", duration: 9000, kind: .video)
        )
        let composite = makeComposite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await composite.snapshot()

        clock.now += 5
        adapter.value = snapshot(bundleID: spotify, title: "Bad Habit")
        scripting.value = snapshot(bundleID: spotify, title: "Bad Habit")
        #expect(await composite.snapshot()?.title == "Dune", "the film was here first")

        clock.now += CompositeNowPlayingSource.heldGrace
        #expect(await composite.snapshot()?.title == "Bad Habit", "and has since gone quiet")
    }

    @Test("A player the adapter names alone costs no extra script")
    func steadyStateCostsNothing() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: snapshot(bundleID: chrome, title: "A podcast"))
        let scripting = FakeSource(identifier: "scripting")
        let composite = makeComposite(adapter: adapter, scripting: scripting, clock: clock)

        _ = await composite.snapshot()
        _ = await composite.snapshot()
        #expect(scripting.calls == 0, "the incumbent and the reported player are the same")
    }
}

@Suite("Two tabs, one now-playing slot")
@MainActor
struct BrowserTabTests {

    private func video(_ title: String, track: String, playing: Bool, elapsed: TimeInterval = 10) -> NowPlayingSnapshot {
        snapshot(
            bundleID: chrome, title: title, isPlaying: playing,
            elapsed: elapsed, duration: 900, trackKey: track, kind: .video
        )
    }

    /// The reported sequence: two YouTube tabs, one paused. Switching to the
    /// paused tab handed the notch to it — nothing was pressed, and the video
    /// actually making sound was replaced by the one that was not.
    @Test("Bringing a paused tab forward does not displace the playing one")
    func pausedTabDoesNotSteal() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: video("Watching", track: "b", playing: true))
        let composite = makeComposite(
            adapter: adapter, scripting: FakeSource(identifier: "scripting"), clock: clock
        )
        #expect(await composite.snapshot()?.title == "Watching")

        // Switching tabs: the system now names the other, paused video.
        clock.now += 3
        adapter.value = video("The other one", track: "a", playing: false)
        #expect(await composite.snapshot()?.title == "Watching", "nothing was pressed")

        // And back again, which is where the paused one used to win for good.
        clock.now += 3
        #expect(await composite.snapshot()?.title == "Watching")
    }

    /// The item on screen is still master of its own state: pausing the thing
    /// you are watching arrives under the same identity and is honoured.
    @Test("Pausing what you are watching is honoured at once")
    func pausingTheShownItemWorks() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: video("Watching", track: "b", playing: true))
        let composite = makeComposite(
            adapter: adapter, scripting: FakeSource(identifier: "scripting"), clock: clock
        )
        _ = await composite.snapshot()

        clock.now += 2
        adapter.value = video("Watching", track: "b", playing: false)
        let answer = await composite.snapshot()
        #expect(answer?.title == "Watching")
        #expect(answer?.isPlaying == false)
    }

    /// The measured failure: over nine minutes Safari named a different item
    /// eighty times — autoplaying videos in a timeline, each claiming to be
    /// playing — while one video was actually being watched. Interleaved
    /// sightings of the real track keep renewing its claim.
    @Test("Autoplaying videos in another tab never take the notch")
    func autoplayingTabsAreIgnored() async {
        let clock = Clock()
        let watched = video("Watching", track: "b", playing: true, elapsed: 100)
        let adapter = FakeSource(identifier: "adapter", value: watched)
        let composite = makeComposite(
            adapter: adapter, scripting: FakeSource(identifier: "scripting"), clock: clock
        )
        _ = await composite.snapshot()

        // The pattern from the capture: the timeline video and the real one,
        // alternating every few seconds, both claiming to play.
        for step in 1...6 {
            clock.now += 3
            adapter.value = video("Timeline clip", track: "x", playing: true, elapsed: 2)
            #expect(await composite.snapshot()?.title == "Watching", "step \(step)")

            clock.now += 3
            adapter.value = video("Watching", track: "b", playing: true, elapsed: 100 + Double(step) * 6)
            #expect(await composite.snapshot()?.title == "Watching", "step \(step)")
        }
    }

    /// Pausing what you are watching is the decision that lets the next thing
    /// through — immediately, with no waiting.
    @Test("Pausing the watched video hands the notch straight over")
    func pausingReleasesTheHold() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: video("Watching", track: "b", playing: true))
        let composite = makeComposite(
            adapter: adapter, scripting: FakeSource(identifier: "scripting"), clock: clock
        )
        _ = await composite.snapshot()

        clock.now += 2
        adapter.value = video("Watching", track: "b", playing: false)
        _ = await composite.snapshot()

        clock.now += 1
        adapter.value = video("The other one", track: "a", playing: true)
        #expect(await composite.snapshot()?.title == "The other one")
    }

    /// And when the watched video simply stops being mentioned — closed, or
    /// ended — the notch moves on rather than holding a ghost.
    @Test("A track that goes quiet gives the notch up")
    func silenceReleasesTheHold() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: video("Watching", track: "b", playing: true))
        let composite = makeComposite(
            adapter: adapter, scripting: FakeSource(identifier: "scripting"), clock: clock
        )
        _ = await composite.snapshot()

        adapter.value = video("The other one", track: "a", playing: true)
        clock.now += CompositeNowPlayingSource.heldGrace + 1
        #expect(await composite.snapshot()?.title == "The other one")
    }

    /// A video that genuinely ended must not haunt the notch for ever.
    @Test("The held track is given up after its grace")
    func heldTrackExpires() async {
        let clock = Clock()
        let adapter = FakeSource(identifier: "adapter", value: video("Watching", track: "b", playing: true))
        let composite = makeComposite(
            adapter: adapter, scripting: FakeSource(identifier: "scripting"), clock: clock
        )
        _ = await composite.snapshot()

        adapter.value = video("The other one", track: "a", playing: false)
        clock.now += CompositeNowPlayingSource.heldGrace + 1
        #expect(await composite.snapshot()?.title == "The other one")
    }

    /// While it is held its position keeps moving, so the scrub bar does not
    /// freeze while the system is looking at another tab.
    @Test("A held track keeps running")
    func heldTrackKeepsTime() async {
        let clock = Clock()
        let adapter = FakeSource(
            identifier: "adapter", value: video("Watching", track: "b", playing: true, elapsed: 10)
        )
        let composite = makeComposite(
            adapter: adapter, scripting: FakeSource(identifier: "scripting"), clock: clock
        )
        _ = await composite.snapshot()

        adapter.value = video("The other one", track: "a", playing: false)
        clock.now += 5
        let answer = await composite.snapshot()
        #expect(answer?.title == "Watching")
        #expect((answer?.elapsed ?? 0) > 10)
    }
}
