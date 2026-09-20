import Foundation
import os

/// Runs submitted work one at a time, in submission order, with a bounded queue.
///
/// Transport commands were fire-and-forget: every play/pause, seek, next and
/// previous launched its own `osascript` with no timeout, no cancellation and
/// no bound. Mashing next-track against a player that has stopped answering
/// accumulates one child per press.
///
/// Order matters — pause-then-next is not next-then-pause — so this is a queue
/// rather than a "latest wins" gate, and the bound is backpressure: past
/// capacity, submission is refused and the caller is told.
///
/// **Admission is synchronous**, under a lock, at the moment `submit` is
/// called. An earlier version was an actor whose synchronous entry point
/// spawned a task and optimistically returned true: the answer was a lie, the
/// order became task-scheduling order rather than submission order, and each
/// press created a task *outside* the very bound the queue existed to enforce.
/// The place that decides is now the place that is called.
final class SerialCommandRunner: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "process")

    typealias Work = @Sendable () async -> Void

    /// Beyond this many waiting, the player is not answering and further
    /// presses are noise.
    let capacity: Int

    private struct State {
        var pending: [(sequence: Int, work: Work)] = []
        /// Whether a consumer is already draining the queue. Exactly one runs.
        var consuming = false
        var nextSequence = 0
        var running = 0
        var peakConcurrency = 0
        var refusals = 0
        var completed = 0
        /// The order work actually started in, for tests.
        var startedOrder: [Int] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    /// Queues `work` behind whatever is already waiting.
    ///
    /// Synchronous, and the returned value is the truth: false means nothing
    /// was queued and nothing will run.
    @discardableResult
    func submit(_ work: @escaping Work) -> Bool {
        enum Admission { case refused, queued, queuedAndStart }

        let admission = state.withLock { s -> Admission in
            guard s.pending.count < capacity else {
                s.refusals += 1
                return .refused
            }
            s.pending.append((s.nextSequence, work))
            s.nextSequence += 1
            guard !s.consuming else { return .queued }
            s.consuming = true
            return .queuedAndStart
        }

        switch admission {
        case .refused:
            Self.log.notice("dropping a command: \(self.capacity, privacy: .public) already queued")
            return false
        case .queued:
            return true
        case .queuedAndStart:
            Task { await self.consume() }
            return true
        }
    }

    /// The single consumer. Takes one item at a time and stops when the queue
    /// is empty, handing the flag back so the next `submit` starts a new one.
    private func consume() async {
        while true {
            let next = state.withLock { s -> (Int, Work)? in
                guard !s.pending.isEmpty else {
                    s.consuming = false
                    return nil
                }
                let item = s.pending.removeFirst()
                s.running += 1
                s.peakConcurrency = max(s.peakConcurrency, s.running)
                s.startedOrder.append(item.sequence)
                return (item.sequence, item.work)
            }
            guard let (_, work) = next else { return }

            await work()

            state.withLock { s in
                s.running -= 1
                s.completed += 1
            }
        }
    }

    // MARK: - Diagnostics and tests

    var pendingCount: Int { state.withLock { $0.pending.count } }
    var running: Int { state.withLock { $0.running } }
    var peakConcurrency: Int { state.withLock { $0.peakConcurrency } }
    var refusals: Int { state.withLock { $0.refusals } }
    var completed: Int { state.withLock { $0.completed } }
    var startedOrder: [Int] { state.withLock { $0.startedOrder } }

    /// Waits for everything queued so far to finish.
    func drain() async {
        while state.withLock({ !$0.pending.isEmpty || $0.running > 0 }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
