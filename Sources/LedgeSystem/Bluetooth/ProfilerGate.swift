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
    /// `at` is when the run finished, for the freshness window; `sampledAt`
    /// is when it *began*, which is the oldest the data can be. They are
    /// different questions and the second one is the one callers need: an
    /// answer handed to a caller who asked after the run started describes
    /// the world as it was before they asked.
    private var cached: (value: Value, at: TimeInterval, sampledAt: TimeInterval)?

    /// When the run now in flight began.
    private var inFlightSince: TimeInterval = 0

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

    /// The answer, and when the work that produced it began.
    ///
    /// The second half matters wherever the answer is compared against
    /// something else that happened: a shared or reused result describes the
    /// world at the moment it was sampled, not at the moment it was handed
    /// over. Stamping it with the latter made a two-second-old reading look
    /// newer than an event that happened in between — which is how a paired
    /// list sampled before a connect undid that connect.
    func reading() async -> (value: Value, sampledAt: TimeInterval) {
        if let cached, now() - cached.at < freshness {
            return (cached.value, cached.sampledAt)
        }
        if let inFlight {
            // Someone else is already asking. Wait for their answer rather than
            // starting a second process to compute the same thing.
            let since = inFlightSince
            return (await inFlight.value, since)
        }

        let startedAt = now()
        let task = Task { [run] in await run() }
        inFlight = task
        inFlightSince = startedAt
        let value = await task.value
        inFlight = nil
        cached = (value, now(), startedAt)
        return (value, startedAt)
    }

    func value() async -> Value { await reading().value }

    /// Tests: how many times the underlying work actually ran is counted by the
    /// caller's own closure; this only reports whether one is in flight.
    var isRunning: Bool { inFlight != nil }
}
