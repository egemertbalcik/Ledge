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

    /// How long a command may wait before it stops meaning what it meant.
    ///
    /// Each command is a subprocess with a five-second deadline, and eight may
    /// be waiting, so against a player that has stopped answering the last one
    /// admitted could run the best part of a minute after the button was
    /// pressed. A play/pause landing then toggles whatever state the player
    /// has reached since, which is as likely to be wrong as right; a next-track
    /// skips a song nobody asked to skip. Four seconds is about the longest a
    /// press can wait and still be the press the user made.
    let maxWait: TimeInterval

    /// The clock. Injected so expiry can be tested at its boundary rather than
    /// by waiting out real seconds.
    private let now: @Sendable () -> TimeInterval

    /// How many started commands the diagnostic history keeps. Comfortably
    /// more than any burst of presses a person can produce, and a fixed cost
    /// rather than a growing one.
    static let rememberedStarts = 256

    private struct State {
        var pending: [(sequence: Int, queuedAt: TimeInterval, work: Work)] = []
        /// Whether a consumer is already draining the queue. Exactly one runs.
        var consuming = false
        var nextSequence = 0
        var running = 0
        var peakConcurrency = 0
        var refusals = 0
        var completed = 0
        /// Commands dropped for having waited too long to still mean anything.
        var expired = 0
        /// The order work actually started in, for tests.
        ///
        /// Bounded, oldest dropped first. The queue itself has a bound and the
        /// transport is not hot, but this grew by one entry per press for the
        /// life of the process — a diagnostic that nothing read in production
        /// quietly keeping every command number since launch.
        var startedOrder: [Int] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        capacity: Int = 8,
        maxWait: TimeInterval = 4,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.capacity = capacity
        self.maxWait = maxWait
        self.now = now
    }

    /// Queues `work` behind whatever is already waiting.
    ///
    /// Synchronous, and the returned value is the truth: false means nothing
    /// was queued and nothing will run.
    @discardableResult
    func submit(_ work: @escaping Work) -> Bool {
        enum Admission { case refused, queued, queuedAndStart }

        let queuedAt = now()
        let admission = state.withLock { s -> Admission in
            guard s.pending.count < capacity else {
                s.refusals += 1
                return .refused
            }
            s.pending.append((s.nextSequence, queuedAt, work))
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
            let startedAt = now()
            let (next, dropped) = state.withLock { s -> ((Int, Work)?, Int) in
                // Anything that has waited past `maxWait` is thrown away
                // rather than run. Order survives: the queue is only ever
                // drained from the front, so dropping a stale head cannot
                // reorder what is behind it.
                var dropped = 0
                while let head = s.pending.first, startedAt - head.queuedAt > maxWait {
                    s.pending.removeFirst()
                    s.expired += 1
                    dropped += 1
                }
                guard !s.pending.isEmpty else {
                    s.consuming = false
                    return (nil, dropped)
                }
                let item = s.pending.removeFirst()
                s.running += 1
                s.peakConcurrency = max(s.peakConcurrency, s.running)
                s.startedOrder.append(item.sequence)
                if s.startedOrder.count > Self.rememberedStarts {
                    s.startedOrder.removeFirst(s.startedOrder.count - Self.rememberedStarts)
                }
                return ((item.sequence, item.work), dropped)
            }
            if dropped > 0 {
                Self.log.notice("""
                    dropping \(dropped, privacy: .public) command(s) that waited \
                    more than \(Int(self.maxWait), privacy: .public)s
                    """)
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
    var expired: Int { state.withLock { $0.expired } }
    var startedOrder: [Int] { state.withLock { $0.startedOrder } }

    /// Waits for everything queued so far to finish.
    func drain() async {
        while state.withLock({ !$0.pending.isEmpty || $0.running > 0 }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
