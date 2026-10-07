import Foundation
import Testing
import os

@testable import LedgeSystem

/// The real watcher against the real audio system.
///
/// The safety poll fires once a minute in the app, and a crash on its very
/// first tick therefore looked like a crash out of nowhere a minute after
/// launch. An earlier version of this suite started the watcher and waited
/// three seconds, which never reached the tick and so proved nothing. The poll
/// interval is injectable now for exactly that reason.
@Suite("Recording watcher live", .serialized)
struct RecordingWatcherLiveTests {

    @Test("The safety poll can fire without tripping an isolation assertion")
    @MainActor
    func pollTickIsSafe() async throws {
        // Fast enough to tick several times inside the test.
        let source = SystemRecordingSource(pollInterval: 0.2)
        let fired = Counter()
        source.startWatching { fired.bump() }

        // If the timer handler inherits an isolation it cannot honour, the
        // first tick takes the process down with SIGTRAP — the test crashes
        // rather than fails, which is the loudest possible signal.
        try await Task.sleep(for: .seconds(2))
        source.stopWatching()
        try await Task.sleep(for: .milliseconds(300))

        #expect(
            fired.count > 0,
            "the poll never delivered — the timer may not be running at all"
        )
    }

    @Test("Starting and stopping repeatedly against the real audio system is safe")
    @MainActor
    func repeatedStartStop() async throws {
        let source = SystemRecordingSource(pollInterval: 0.2)
        for _ in 0..<10 {
            source.startWatching {}
            source.stopWatching()
        }
        source.startWatching {}
        try await Task.sleep(for: .milliseconds(600))
        source.stopWatching()
        try await Task.sleep(for: .milliseconds(200))
        #expect(true, "reached the end without trapping")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    func bump() { lock.withLock { $0 += 1 } }
    var count: Int { lock.withLock { $0 } }
}

/// Dictation has no interface in Ledge and no indicator either: the system
/// transcribing at the user's own keystroke, with the menu bar already saying
/// so, is not an app listening to them. The exclusion is internal — nothing
/// downstream knows it exists — so this is where it is held in place.
@Suite("The system's own speech input is not an indicator")
struct SystemSpeechExclusionTests {

    @Test("Apple's speech processes are recognised", arguments: [
        "com.apple.SpeechRecognitionCore",
        "com.apple.speech.recognitionserver",
        "com.apple.corespeechd",
        "com.apple.DictationIM",
        "com.apple.siri.embeddedspeech",
        "com.apple.assistantd",
    ])
    func speechProcesses(bundleID: String) {
        #expect(SystemRecordingSource.isSystemSpeech(bundleID))
    }

    /// Apple's own identifiers only. An app with "speech" in its name is an
    /// app recording you, and gets the dot it has earned.
    @Test("Everything else is an app recording you", arguments: [
        "com.apple.Music",
        "com.apple.FaceTime",
        "us.zoom.xos",
        "com.hegenberg.BetterSpeech",
        "org.speech.recorder",
        "(unnamed)",
        "",
    ])
    func otherProcesses(bundleID: String) {
        #expect(SystemRecordingSource.isSystemSpeech(bundleID) == false)
    }

    @Test("Dictation alone lights nothing")
    func dictationAloneIsSilent() {
        #expect(SystemRecordingSource.microphoneHeld(by: []) == false)
        #expect(SystemRecordingSource.microphoneHeld(by: ["com.apple.corespeechd"]) == false)
        #expect(SystemRecordingSource.microphoneHeld(
            by: ["com.apple.corespeechd", "com.apple.SpeechRecognitionCore"]
        ) == false)
    }

    /// A filter, not a short circuit: dictation running is no excuse for
    /// missing the call that is recording at the same time.
    @Test("An app recording alongside dictation still lights the dot")
    func appAlongsideDictation() {
        #expect(SystemRecordingSource.microphoneHeld(by: ["us.zoom.xos"]))
        #expect(SystemRecordingSource.microphoneHeld(by: ["com.apple.corespeechd", "us.zoom.xos"]))
        #expect(SystemRecordingSource.microphoneHeld(by: ["(unnamed)"]))
    }
}

/// A provider switched off and on again must not be told the previous
/// session's state — and a hardware sweep already running when the stop lands
/// must not be able to put it back. The sweep takes milliseconds; the stop is
/// instant; checking the session only *after* writing the cache left exactly
/// that window open.
///
/// Driven by an injected sweep the test holds open, so none of this depends on
/// real hardware or on timing guesses.
@Suite("Privacy state across a restart", .serialized)
@MainActor
struct RecordingRestartTests {

    /// A watcher whose sweep the test controls.
    private func watcher(
        sweep: @escaping @Sendable () -> RecordingState = { RecordingState() }
    ) -> SystemRecordingSource {
        SystemRecordingSource(pollInterval: 3600, sweep: sweep)
    }

    private let recording = RecordingState(camera: true, microphone: true)

    @Test("Stopping clears the cached state at once, not on a queue")
    func stopClearsSynchronously() {
        let source = watcher()
        source.startWatching {}
        source.setCachedStateForTesting(recording)
        source.stopWatching()
        #expect(
            source.current() == RecordingState(),
            "a stopped watch answered with the previous session's reading"
        )
    }

    /// A sweep held open across the stop. When it finishes there is no live
    /// session, so it publishes nothing and announces nothing.
    @Test("A sweep that finishes after a stop publishes nothing")
    func sweepAfterStopIsDiscarded() async {
        let gate = SweepGate(RecordingState(camera: true))
        let callbacks = ChangeCount()
        let source = watcher(sweep: { gate.read() })

        source.startWatching { callbacks.bump() }
        // Asserted, not assumed: a wait that timed out silently would let this
        // test pass without the race ever happening.
        #expect(await gate.waitUntilEntered(1), "the initial sweep never started")

        source.stopWatching()
        gate.releaseOne()
        // Wait for that exact sweep to return, so the assertions below are
        // made after it had its chance to publish.
        #expect(await gate.waitUntilReturned(1), "the released sweep never returned")

        #expect(
            source.current() == RecordingState(),
            "a sweep from a stopped session repopulated the cache"
        )
        #expect(callbacks.value == 0, "and it announced itself to a stopped watch")
    }

    /// Session A held open, stopped, and B started in the meantime: A's
    /// reading belongs to nobody and must not overwrite B's.
    @Test("An old session's sweep cannot overwrite a new one")
    func oldSweepCannotOverwriteNewSession() async {
        let gate = SweepGate(RecordingState(camera: true, microphone: true))
        let source = watcher(sweep: { gate.read() })

        source.startWatching {}
        #expect(await gate.waitUntilEntered(1), "session A's sweep never started")
        let sessionA = source.activeCacheSessionForTesting

        source.stopWatching()
        // B starts while A's sweep is still inside the gate. B's own sweep
        // queues behind it and is never released, so B's cache stays empty —
        // which is what makes a leak from A visible.
        source.startWatching {}
        let sessionB = source.activeCacheSessionForTesting
        #expect(sessionA != sessionB, "the restart reused the old session token")

        gate.releaseOne()
        #expect(await gate.waitUntilReturned(1), "session A's sweep never returned")
        #expect(await gate.waitUntilEntered(2), "session B's sweep never started")
        #expect(
            source.current() == RecordingState(),
            "session A's reading landed in session B's cache"
        )
        source.stopWatching()
        gate.releaseOne()
    }

    /// And the ordinary case still works: a reading from the live session
    /// publishes and announces.
    @Test("A current session's reading publishes")
    func currentSessionPublishes() async {
        let callbacks = ChangeCount()
        let source = watcher(sweep: { RecordingState(microphone: true) })
        source.startWatching { callbacks.bump() }

        for _ in 0..<400 where callbacks.value == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(callbacks.value >= 1, "the reading was never announced")
        #expect(source.current().microphone, "and never reached the cache")
        source.stopWatching()
    }

    /// `current()` is a lock and a copy: no hardware enumeration on the main
    /// actor, not even for the first answer.
    @Test("current() does not sweep the hardware")
    func currentIsCheap() {
        let source = watcher(sweep: { RecordingState() })
        let started = Date()
        _ = source.current()
        #expect(Date().timeIntervalSince(started) < 0.005)
    }
}

/// A sweep the test can hold open, call by call.
///
/// Per call, because one gate shared by two sessions cannot show whose reading
/// landed: the second session's own sweep would publish the same value and the
/// test would pass either way. Call one is released on demand; every later
/// call blocks until the test releases it too, so a session whose sweep is
/// still inside the gate has published nothing.
///
/// Both *entered* and *returned* are tracked, and the waits report whether
/// they got there. A wait that silently timed out let a test pass without ever
/// exercising the race it was written for.
private final class SweepGate: @unchecked Sendable {
    private struct State {
        var entered = 0
        var returned = 0
        var released = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let value: RecordingState

    init(_ value: RecordingState) { self.value = value }

    /// Called on the watcher's queue, standing in for the HAL sweep.
    func read() -> RecordingState {
        let call = state.withLock { s -> Int in
            s.entered += 1
            return s.entered
        }
        while state.withLock({ $0.released < call }) {
            // Blocking the watcher's own queue is what a real sweep does.
            usleep(1_000)
        }
        state.withLock { $0.returned += 1 }
        return value
    }

    /// Lets one more sweep finish.
    func releaseOne() { state.withLock { $0.released += 1 } }

    var entered: Int { state.withLock { $0.entered } }
    var returned: Int { state.withLock { $0.returned } }

    /// - Returns: whether that many sweeps entered before the deadline.
    func waitUntilEntered(_ count: Int) async -> Bool {
        await wait { self.entered >= count }
    }

    /// - Returns: whether that many sweeps returned before the deadline.
    func waitUntilReturned(_ count: Int) async -> Bool {
        await wait { self.returned >= count }
    }

    private func wait(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}

/// Counts callbacks from whatever context delivers them.
private final class ChangeCount: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    func bump() { state.withLock { $0 += 1 } }
    var value: Int { state.withLock { $0 } }
}

/// How often the hardware may be swept.
///
/// Each sweep walks every audio process object and makes two round trips to
/// coreaudiod for each — measured at 6.3ms with 32 objects live and 19.5ms with
/// 57, so the cost grows faster than the count. A browser with several tabs
/// making noise churns those objects a few times a second, and each of those
/// events used to buy its own sweep, because the only thing holding them back
/// was a 50ms wait that had always elapsed by the time the next one arrived.
/// That is a steady five percent of a core with nobody touching the machine.
///
/// Asserted as the *gap between sweeps* rather than a count in a period. A
/// count is a statement about the machine's speed as much as the code's
/// behaviour — under a loaded test run the events spread out, each one lands in
/// its own window, and the test fails for being right. The minimum gap only
/// ever grows on a slow machine, so it says the same thing everywhere.
@Suite("How often the hardware is swept", .serialized)
@MainActor
struct SweepRateTests {

    /// Records when each sweep ran.
    private final class SweepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var times: [Date] = []
        func sweep() -> RecordingState {
            lock.lock(); times.append(Date()); lock.unlock()
            return RecordingState()
        }
        func reset() { lock.lock(); times = []; lock.unlock() }
        var stamps: [Date] { lock.lock(); defer { lock.unlock() }; return times }
        /// The closest two consecutive sweeps came, or nil for fewer than two.
        var shortestGap: TimeInterval? {
            let t = stamps
            guard t.count >= 2 else { return nil }
            return zip(t.dropFirst(), t).map { $0.timeIntervalSince($1) }.min()
        }
    }

    /// `pollInterval` 1.0 puts the coalescing window at half a second.
    private func watcher(_ log: SweepLog) -> SystemRecordingSource {
        SystemRecordingSource(pollInterval: 1.0, sweep: { log.sweep() })
    }

    @Test("Two sweeps are never closer together than the window")
    func sweepsAreRateLimited() async throws {
        let log = SweepLog()
        let source = watcher(log)
        source.startWatching {}
        defer { source.stopWatching() }

        // Let the opening sweep land, then start counting from clean.
        try await Task.sleep(for: .milliseconds(250))
        log.reset()

        // Events at 60ms apart: slower than the old 50ms wait, so each one
        // would have bought its own sweep, and faster than the half-second
        // window that now governs them.
        for _ in 0..<25 {
            source.notifyChangedForTesting()
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(700))

        let gap = try #require(log.shortestGap, "fewer than two sweeps ran — nothing was measured")
        // The window is 0.5s; allow for the timer's own slack. Without the
        // rate limit these land ~60ms apart.
        #expect(gap > 0.3, "two sweeps ran \(Int(gap * 1000))ms apart — the rate limit is not holding")
    }
}
