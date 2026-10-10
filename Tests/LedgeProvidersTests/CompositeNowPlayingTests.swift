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

    /// Reads of this source overlap in real use — the provider's steady poll,
    /// its burst after a transport press and an immediate refresh all ask it —
    /// and a read is several awaits with cache writes between them.
    /// Interleaved, the one that started earlier could finish later and commit
    /// its older answer over the newer one, after which the next several polls
    /// projected the card from a reading taken before the press.
    @Test("Overlapping reads take their turn instead of interleaving")
    func overlappingReadsAreSerialised() async {
        var steps: [String] = []
        var asked = 0
        let adapter = FakeSource(
            identifier: "adapter",
            value: snapshot(bundleID: "com.spotify.client", title: "Track")
        )
        let composite = CompositeNowPlayingSource(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            scriptedSnapshot: { bundleID in
                asked += 1
                let n = asked
                steps.append("start \(n)")
                // The earlier read is the slower one, which is the ordering
                // that let it finish last and hand its older position to the
                // caller that had asked later.
                for _ in 0..<(n == 1 ? 8 : 1) { await Task.yield() }
                steps.append("end \(n)")
                var answer = snapshot(bundleID: bundleID, title: "Track")
                answer.elapsed = n == 1 ? 10 : 20
                return answer
            },
            scriptingHandles: { $0 == "com.spotify.client" },
            now: { 0 },
            // A transport press has just gone out, which is exactly when the
            // provider reads this source three times in quick succession.
            lastTransportAt: { 100 }
        )

        async let earlier = composite.snapshot()
        async let later = composite.snapshot()
        let answers = await (earlier, later)

        #expect(steps == ["start 1", "end 1", "start 2", "end 2"], "the reads interleaved: \(steps)")
        #expect(answers.0?.elapsed == 10)
        #expect(answers.1?.elapsed == 20, "the later read was handed the earlier reading")
    }
}

@Suite("One song keeps one name")
@MainActor
struct CompositeSongIdentityTests {

    // The card turns the cover over when the song changes, and it knows the
    // song by the key the composite publishes. Two sources answer here, and
    // they name the same song differently: the script knows the player's own
    // track id, the adapter has only the metadata. A song whose name changes
    // because the *answer* came from somewhere else is a song change as far as
    // anything downstream can tell.

    private func spotify(
        _ title: String = "Song",
        trackKey: String? = nil,
        elapsed: TimeInterval = 10
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title,
            artist: "A",
            album: "Alb",
            isPlaying: true,
            elapsed: elapsed,
            duration: 200,
            appName: "Spotify",
            appBundleID: "com.spotify.client",
            trackKey: trackKey
        )
    }

    @Test("A scripted answer that goes missing does not rename the song")
    func scriptingSkipDoesNotRenameTheSong() async {
        // The script answers, then one read does not — it timed out, or the
        // queue dropped it for being late — then it answers again. The song
        // never changed.
        var clock: TimeInterval = 1_000
        var answers: [NowPlayingSnapshot?] = [
            spotify(trackKey: "com.spotify.client|id-1"),
            nil,
            spotify(trackKey: "com.spotify.client|id-1")
        ]
        let adapter = FakeSource(identifier: "adapter", value: spotify())
        let source = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            scripted: { _ in answers.isEmpty ? nil : answers.removeFirst() },
            now: { clock }
        )

        let first = await source.snapshot()
        clock += 60
        let second = await source.snapshot()
        clock += 60
        let third = await source.snapshot()

        #expect(first?.trackKey == second?.trackKey,
                "the script missing one answer is not a new song")
        #expect(second?.trackKey == third?.trackKey,
                "and neither is it coming back")
    }

    @Test("A different song does get a different name")
    func realTrackChangeStillRenames() async {
        // The other half of the rule: keeping a name must not mean keeping it
        // through an actual track change, or the cover would never turn over
        // at all.
        var clock: TimeInterval = 1_000
        var answers: [NowPlayingSnapshot?] = [
            spotify("First", trackKey: "com.spotify.client|id-1"),
            spotify("Second", trackKey: "com.spotify.client|id-2")
        ]
        let adapter = FakeSource(identifier: "adapter", value: spotify("First"))
        let source = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            scripted: { _ in answers.isEmpty ? nil : answers.removeFirst() },
            now: { clock }
        )

        let first = await source.snapshot()
        clock += 60
        adapter.value = spotify("Second")
        let second = await source.snapshot()

        #expect(first?.title == "First")
        #expect(second?.title == "Second")
        #expect(first?.trackKey != second?.trackKey,
                "a new song brings a new name with it")
    }

    @Test("A script that never names the track still names it the same way twice")
    func missingTrackIDIsStableAcrossReads() async {
        // The player answers but has no id for the track, so the name falls
        // back to the metadata. That has to be the *same* fallback each time.
        var clock: TimeInterval = 1_000
        var answers: [NowPlayingSnapshot?] = [
            spotify(trackKey: "com.spotify.client|id-1"),
            spotify(trackKey: nil, elapsed: 70),
            spotify(trackKey: "com.spotify.client|id-1", elapsed: 130)
        ]
        let adapter = FakeSource(identifier: "adapter", value: spotify())
        let source = makeComposite(
            adapter: adapter,
            scripting: FakeSource(identifier: "scripting"),
            scripted: { _ in answers.isEmpty ? nil : answers.removeFirst() },
            now: { clock }
        )

        let first = await source.snapshot()
        clock += 60
        let second = await source.snapshot()
        clock += 60
        let third = await source.snapshot()

        #expect(first?.trackKey == second?.trackKey,
                "losing the player's own id is not a new song")
        #expect(second?.trackKey == third?.trackKey)
    }
}
