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
