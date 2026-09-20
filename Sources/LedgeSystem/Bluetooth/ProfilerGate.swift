import Foundation
import os

/// Runs one `system_profiler` at a time, and lets simultaneous callers share
/// the result.
///
/// `system_profiler SPBluetoothDataType` takes a second or more and is the only
/// source of battery levels, so it is asked for from two places: the periodic
/// read, and every Bluetooth connect notification. Those notifications arrive
/// in bursts — waking a Mac reconnects every paired device at once — and each
/// used to spawn its own process. Several copies of a slow system tool running
/// concurrently, all computing the same answer, is the shape of the problem
/// this app has already had once.
///
/// So a run in flight is joined rather than duplicated, and an answer a moment
/// old is reused rather than recomputed. Both are safe here: the data is a
/// snapshot of the same hardware either way.
actor ProfilerGate<Value: Sendable> {

    private let run: @Sendable () async -> Value
    private let freshness: TimeInterval
    private let now: @Sendable () -> TimeInterval

    private var inFlight: Task<Value, Never>?
    private var cached: (value: Value, at: TimeInterval)?

    /// - Parameters:
    ///   - freshness: how long an answer may be reused. Short — this is for
    ///     collapsing a burst, not for caching.
    init(
        freshness: TimeInterval = 2,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        run: @escaping @Sendable () async -> Value
    ) {
        self.freshness = freshness
        self.now = now
        self.run = run
    }

    func value() async -> Value {
        if let cached, now() - cached.at < freshness {
            return cached.value
        }
        if let inFlight {
            // Someone else is already asking. Wait for their answer rather than
            // starting a second process to compute the same thing.
            return await inFlight.value
        }

        let task = Task { [run] in await run() }
        inFlight = task
        let value = await task.value
        inFlight = nil
        cached = (value, now())
        return value
    }

    /// Tests: how many times the underlying work actually ran is counted by the
    /// caller's own closure; this only reports whether one is in flight.
    var isRunning: Bool { inFlight != nil }
}
