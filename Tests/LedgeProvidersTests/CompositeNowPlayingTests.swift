import Foundation
import Testing

@testable import LedgeSystem

/// Stands in for either side, counting calls so a demotion can be proven to
/// actually stop the traffic.
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

private func snapshot(bundleID: String, title: String = "T") -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        title: title,
        artist: "A",
        isPlaying: true,
        appName: bundleID,
        appBundleID: bundleID
    )
}

/// Nothing here touches `osascript` or a real player, so the result cannot
/// depend on what happens to be running on the machine.
@MainActor
private func makeComposite(
    adapter: FakeSource,
    scripting: FakeSource,
    scripted: @escaping (String) async -> NowPlayingSnapshot? = { _ in nil },
    handles: @escaping (String) -> Bool = { $0 == "com.spotify.client" || $0 == "com.apple.Music" },
    now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
) -> CompositeNowPlayingSource {
    CompositeNowPlayingSource(
        adapter: adapter,
        scripting: scripting,
        scriptedSnapshot: scripted,
        scriptingHandles: handles,
        now: now
    )
}

/// A browser track, with a length so "did it finish" can be asked of it.
private func track(
    _ title: String,
    bundleID: String = "com.apple.Safari",
    elapsed: TimeInterval = 10,
    duration: TimeInterval = 200,
    playing: Bool = true
) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        title: title,
        artist: "A",
        isPlaying: playing,
        elapsed: elapsed,
        duration: duration,
        appName: bundleID,
        appBundleID: bundleID
    )
}

@Suite("Composite now playing")
@MainActor
struct CompositeNowPlayingTests {

    @Test("An app AppleScript cannot script is answered by the adapter")
    func browserComesFromAdapter() async {
        let adapter = FakeSource(
            identifier: "adapter",
            value: snapshot(bundleID: "com.google.Chrome", title: "Video")
        )
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting")
        )
        let result = await composite.snapshot()
        #expect(result?.appBundleID == "com.google.Chrome")
        #expect(result?.title == "Video")
    }

    @Test("Spotify is handed back to the scripting path, unchanged")
    func spotifyGoesToScripting() async {
        // This is the guarantee that the two working players cannot regress.
        let adapter = FakeSource(
            identifier: "adapter",
            value: snapshot(bundleID: "com.spotify.client", title: "from-adapter")
        )
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            scripted: { bundleID in
                bundleID == "com.spotify.client"
                    ? snapshot(bundleID: bundleID, title: "from-applescript")
                    : nil
            }
        )
        let result = await composite.snapshot()
        #expect(result?.title == "from-applescript")
    }

    @Test("If the scripted player quit mid-query, the adapter's answer stands")
    func fallsBackToAdapterWhenScriptingFails() async {
        let adapter = FakeSource(
            identifier: "adapter",
            value: snapshot(bundleID: "com.spotify.client", title: "from-adapter")
        )
        let composite = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            scripted: { _ in nil }
        )
        #expect(await composite.snapshot()?.title == "from-adapter")
    }

    @Test("Silence while a player is plainly playing demotes the adapter")
    func demotesWhenAdapterGoesBlind() async {
        // The defence against Apple closing the gate: no probe can tell that
        // apart from an idle machine, but this can.
        let adapter = FakeSource(identifier: "adapter", value: nil)
        let scripting = FakeSource(
            identifier: "scripting",
            value: snapshot(bundleID: "com.spotify.client")
        )
        let composite = makeComposite(adapter: adapter, scripting: scripting)

        for _ in 0..<CompositeNowPlayingSource.demotionThreshold {
            _ = await composite.snapshot()
        }
        #expect(composite.isDemoted)

        let before = adapter.calls
        _ = await composite.snapshot()
        _ = await composite.snapshot()
        #expect(adapter.calls == before, "a demoted adapter must not be asked again")
    }

    @Test("A paused player answering AppleScript is not a demotion")
    func pausedPlayerDoesNotDemote() async {
        // A paused Spotify still answers AppleScript while the adapter rightly
        // reports nothing. Counting that demoted a healthy adapter during any
        // long pause and silently killed browser media for the run.
        var paused = snapshot(bundleID: "com.spotify.client")
        paused.isPlaying = false
        let adapter = FakeSource(identifier: "adapter", value: nil)
        let scripting = FakeSource(identifier: "scripting", value: paused)
        let composite = makeComposite(adapter: adapter, scripting: scripting)

        for _ in 0..<(CompositeNowPlayingSource.demotionThreshold + 3) {
            _ = await composite.snapshot()
        }
        #expect(composite.isDemoted == false)
    }

    @Test("A silent adapter on an idle machine is not a demotion")
    func silenceAloneDoesNotDemote() async {
        let adapter = FakeSource(identifier: "adapter", value: nil)
        let scripting = FakeSource(identifier: "scripting", value: nil)
        let composite = makeComposite(adapter: adapter, scripting: scripting)

        for _ in 0..<(CompositeNowPlayingSource.demotionThreshold + 3) {
            _ = await composite.snapshot()
        }
        #expect(composite.isDemoted == false)
    }

    @Test("A single answer resets the silence counter")
    func oneGoodAnswerResets() async {
        let adapter = FakeSource(identifier: "adapter", value: nil)
        let scripting = FakeSource(
            identifier: "scripting",
            value: snapshot(bundleID: "com.spotify.client")
        )
        let composite = makeComposite(adapter: adapter, scripting: scripting)

        for _ in 0..<(CompositeNowPlayingSource.demotionThreshold - 1) {
            _ = await composite.snapshot()
        }
        adapter.value = snapshot(bundleID: "com.google.Chrome")
        _ = await composite.snapshot()
        adapter.value = nil
        for _ in 0..<(CompositeNowPlayingSource.demotionThreshold - 1) {
            _ = await composite.snapshot()
        }
        #expect(composite.isDemoted == false)
    }

    @Test("The real scripting source claims exactly Spotify and Music")
    func scriptedPlayersAreRecognised() {
        #expect(ScriptingNowPlayingSource.handles("com.spotify.client"))
        #expect(ScriptingNowPlayingSource.handles("com.apple.Music"))
        #expect(ScriptingNowPlayingSource.handles("com.google.Chrome") == false)
    }
}

/// One browser holds one now-playing slot for every tab, and hands it around:
/// measured at eighty changes in nine minutes, mostly autoplaying video nobody
/// chose. The card has to sit still through that — and must not sit still
/// through the user pressing Next, which is the same event from the outside.
@Suite("Holding a track against interlopers")
@MainActor
struct IncumbentTrackTests {

    private func composite(
        _ adapter: FakeSource,
        clock: @escaping () -> TimeInterval
    ) -> CompositeNowPlayingSource {
        makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            handles: { _ in false },
            now: clock
        )
    }

    @Test("An interloper that flickers past never takes the card")
    func flickeringInterloperIgnored() async {
        var time: TimeInterval = 0
        let adapter = FakeSource(identifier: "adapter", value: track("Real"))
        let source = composite(adapter) { time }

        #expect(await source.snapshot()?.title == "Real")
        // Each interloper appears once and is replaced by another, which is
        // what the browser's slot churn looks like.
        for (index, name) in ["Ad", "Timeline clip", "Another ad"].enumerated() {
            time += 1
            adapter.value = track(name, elapsed: TimeInterval(index))
            #expect(await source.snapshot()?.title == "Real")
        }
    }

    @Test("A track that stays becomes the card")
    func persistentTrackWins() async {
        var time: TimeInterval = 0
        let adapter = FakeSource(identifier: "adapter", value: track("Real"))
        let source = composite(adapter) { time }
        #expect(await source.snapshot()?.title == "Real")

        adapter.value = track("Chosen")
        time += 1
        #expect(await source.snapshot()?.title == "Real", "seen once — not yet")
        time += 1.5
        #expect(await source.snapshot()?.title == "Chosen", "still there — it is real")
    }

    @Test("Pressing Next is honoured at once")
    func expectedChangeIsImmediate() async {
        var time: TimeInterval = 0
        let adapter = FakeSource(identifier: "adapter", value: track("Real"))
        let source = composite(adapter) { time }
        #expect(await source.snapshot()?.title == "Real")

        // What the card's Next button does before re-reading. Without it the
        // new song played while the card kept the old title, artwork and
        // duration for as long as fifteen seconds.
        source.expectChange()
        adapter.value = track("Next song")
        time += 0.2
        #expect(await source.snapshot()?.title == "Next song")
    }

    @Test("A track that has played out lets its successor through")
    func finishedTrackYields() async {
        var time: TimeInterval = 0
        let adapter = FakeSource(identifier: "adapter", value: track("Ending", elapsed: 199, duration: 200))
        let source = composite(adapter) { time }
        #expect(await source.snapshot()?.title == "Ending")

        time += 2  // it would be past its end by now
        adapter.value = track("Next in the album", elapsed: 0)
        #expect(await source.snapshot()?.title == "Next in the album")
    }

    @Test("The held track's position keeps moving, and never past its end")
    func heldTrackIsProjectedAndClamped() async {
        var time: TimeInterval = 0
        let adapter = FakeSource(identifier: "adapter", value: track("Real", elapsed: 10, duration: 200))
        let source = composite(adapter) { time }
        _ = await source.snapshot()

        adapter.value = track("Interloper")
        time += 5
        #expect(await source.snapshot()?.elapsed == 15, "the bar keeps running while the system looks away")
    }
}
