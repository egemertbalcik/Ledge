import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

/// An adapter whose reads the test holds open, and which remembers whether a
/// held read was cancelled rather than answered.
///
/// A held read stands in for the expensive half of a real one: the adapter's
/// own answer is a cache read, but the scripting side behind it is a
/// subprocess, and the whole question here is how many of those a burst of
/// demand is allowed to cost.
@MainActor
private final class GatedAdapter: NowPlayingSource {

    let identifier = "gated-adapter"
    var isAvailable = true
    var value: NowPlayingSnapshot?

    private(set) var calls = 0
    private(set) var cancelledReads = 0

    /// Which reads, by call number, are held open instead of answered.
    var holds: Set<Int> = [1]

    private var held: [Int: CheckedContinuation<NowPlayingSnapshot?, Never>] = [:]

    var isHolding: Bool { !held.isEmpty }

    func snapshot() async -> NowPlayingSnapshot? {
        calls += 1
        let call = calls
        guard holds.contains(call), !Task.isCancelled else { return value }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                held[call] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.giveUp(call) }
        }
    }

    private func giveUp(_ call: Int) {
        guard let continuation = held.removeValue(forKey: call) else { return }
        cancelledReads += 1
        continuation.resume(returning: nil)
    }

    func release(_ call: Int = 1) {
        guard let continuation = held.removeValue(forKey: call) else { return }
        continuation.resume(returning: value)
    }

    /// Lets go of every held read. Called on the way out of a test so a gate
    /// that was never reached leaves a failure rather than a queue nothing can
    /// ever drain.
    func releaseEverything() {
        let waiting = held
        held = [:]
        for (_, continuation) in waiting { continuation.resume(returning: value) }
    }
}

/// A flag a task can raise the instant it starts, so the test can cancel it
/// at a known point rather than at a guessed one.
@MainActor
private final class Flag {
    var isUp = false
}

private func track(_ title: String, bundleID: String = "com.spotify.client") -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        title: title, artist: "A", isPlaying: true,
        elapsed: 5, duration: 300,
        appName: bundleID, appBundleID: bundleID
    )
}

/// Hands the run loop back until the condition holds.
///
/// Every step waited on here is a scheduler step — a main-actor hop, a task
/// resuming — so yielding is a barrier rather than a guess at a duration. The
/// bound only exists so a test that will never pass fails instead of hanging.
@MainActor
@discardableResult
private func settle(until condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// How much work a burst of demand for fresh media state is allowed to cost.
///
/// Reads of the composite source take their turn, which is what keeps an older
/// answer from committing over a newer one. Taking turns is not enough on its
/// own: a queue of callers each waiting to start a read of their own is a
/// backlog, and `refreshSoon` fills it — it cancels and replaces its own work
/// every time a player announces anything. Chained one read per caller, those
/// abandoned replacements each still had a subprocess waiting behind the slow
/// read, so fifty dropped notifications meant fifty `osascript` runs after the
/// fact: work nobody was waiting for, holding the fresh answer up behind it and
/// carrying on past `stop`.
@Suite("What a burst of media refreshes costs", .serialized)
@MainActor
struct MediaReadQueueTests {

    private func composite(
        _ adapter: GatedAdapter,
        scripting: GatedAdapter = GatedAdapter()
    ) -> CompositeNowPlayingSource {
        scripting.holds = []
        return CompositeNowPlayingSource(
            adapter: adapter,
            scripting: scripting,
            scriptedSnapshot: { _ in nil },
            scriptingHandles: { _ in false },
            now: { 0 },
            lastTransportAt: { 0 },
            playbackWatcher: nil
        )
    }

    @Test("Refreshes that are cancelled while waiting never become reads of their own")
    func cancelledWaitersNeverRead() async throws {
        let adapter = GatedAdapter()
        adapter.value = track("Held")
        let source = composite(adapter)
        defer { adapter.releaseEverything() }

        let live = Task { await source.snapshot() }
        try #require(await settle { adapter.isHolding }, "the first read never started")

        // Fifty notifications arrive while that read is stuck, each replacing
        // the one before it — which is exactly what `refreshSoon` does.
        var abandoned: [Task<NowPlayingSnapshot?, Never>] = []
        for _ in 0..<50 {
            let started = Flag()
            let read = Task { @MainActor in
                started.isUp = true
                return await source.snapshot()
            }
            abandoned.append(read)
            try #require(await settle { started.isUp })
            read.cancel()
        }

        adapter.release()
        _ = await live.value
        for read in abandoned { _ = await read.value }
        await settle { source.waitingForNextPass == 0 }

        #expect(
            adapter.calls == 1,
            "fifty abandoned refreshes cost \(adapter.calls - 1) further read passes"
        )
        #expect(source.passesBegun == 1)
    }

    @Test("A burst of live refreshes shares one further read, not one each")
    func liveBurstCoalescesIntoOnePass() async throws {
        let adapter = GatedAdapter()
        adapter.value = track("Held")
        let source = composite(adapter)
        defer { adapter.releaseEverything() }

        let live = Task { await source.snapshot() }
        try #require(await settle { adapter.isHolding })

        // Twenty callers that all stay interested. Each wants the state *after*
        // the read in flight, and that is one and the same thing, so one read
        // answers all of them.
        let burst = (0..<20).map { _ in Task { await source.snapshot() } }
        try #require(
            await settle { source.waitingForNextPass == 20 },
            "only \(source.waitingForNextPass) of twenty joined the waiting pass"
        )

        adapter.release()
        _ = await live.value
        for read in burst { _ = await read.value }

        #expect(adapter.calls == 2, "twenty refreshes cost \(adapter.calls - 1) further reads")
        #expect(source.passesBegun == 2)
    }

    @Test("One caller leaving does not take the answer from the others")
    func sharedReadSurvivesOneLeaver() async throws {
        let adapter = GatedAdapter()
        adapter.value = track("Held")
        adapter.holds = [1, 2]
        let source = composite(adapter)
        defer { adapter.releaseEverything() }

        let live = Task { await source.snapshot() }
        try #require(await settle { adapter.isHolding })

        let leaver = Task { await source.snapshot() }
        let stayers = (0..<3).map { _ in Task { await source.snapshot() } }
        try #require(await settle { source.waitingForNextPass == 4 })

        // The first read finishes, so the four waiting share the second one.
        adapter.release(1)
        _ = await live.value
        try #require(await settle { adapter.calls == 2 })

        leaver.cancel()
        _ = await leaver.value
        // Nothing may be taken away: three callers are still waiting on this
        // very read, and shared work is not cancelled because one of them left.
        await settle { adapter.cancelledReads > 0 }
        #expect(adapter.cancelledReads == 0, "the read was cancelled out from under the others")

        adapter.release(2)
        for read in stayers {
            #expect(await read.value?.title == "Held")
        }
        #expect(adapter.calls == 2)
    }

    @Test("Stopping the provider cancels the read it alone was waiting for")
    func stoppingCancelsTheReadItOwns() async throws {
        let adapter = GatedAdapter()
        adapter.value = track("Playing")
        let source = composite(adapter)
        defer { adapter.releaseEverything() }
        let provider = NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 3600, idleInterval: 3600, playbackWatcher: nil
        )

        let stream = provider.start()
        try #require(await settle { adapter.isHolding }, "the opening poll never reached the source")

        provider.stop()
        #expect(
            await settle { adapter.cancelledReads == 1 },
            "the subprocess the stopped provider alone was waiting for ran on"
        )

        var published = 0
        for await event in stream {
            if case .publish = event { published += 1 }
        }
        #expect(published == 0, "a stopped provider published a reading anyway")
        #expect(adapter.calls == 1, "reads kept going after the provider stopped")
    }

    @Test("Starting again reads afresh rather than inheriting the old queue")
    func restartReadsAfresh() async throws {
        let adapter = GatedAdapter()
        adapter.value = track("Before")
        let source = composite(adapter)
        let provider = NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 3600, idleInterval: 3600, playbackWatcher: nil
        )

        let old = provider.start()
        try #require(await settle { adapter.isHolding })
        provider.stop()
        // Whichever got there first — the cancellation, or this. What the
        // restart must not do is inherit the abandoned read, and that is the
        // same question either way. Cancellation itself is asserted above, in
        // the test that is about it.
        adapter.releaseEverything()
        try #require(await settle { !adapter.isHolding })

        adapter.holds = []
        adapter.value = track("After")
        let fresh = provider.start()
        await provider.refreshNow()
        provider.stop()

        for await _ in old {}
        var titles: [String] = []
        for await event in fresh {
            if case .publish(let activity) = event,
               case .nowPlaying(let payload) = activity.payload {
                titles.append(payload.title)
            }
        }
        #expect(titles.contains("After"), "the restarted provider published nothing: \(titles)")
        #expect(!titles.contains("Before"), "the abandoned read answered the new run")
    }
}
