import Foundation
import os

/// Carries the latest value to the main actor, one delivery at a time.
///
/// The naive version clears its "a delivery is on the way" flag on the
/// producer's queue, as soon as the hop is enqueued. That is too early: while
/// the main actor is busy, every further value enqueues another hop, and forty
/// refreshes against a held main thread arrive as forty-one deliveries. The
/// flag has to stay set until main has actually taken the value.
///
/// So the pending value, the flag and the session all live behind one lock that
/// both sides take. The producer posts and, only if no delivery is outstanding,
/// schedules one. Main takes whatever is in the box at the moment it runs —
/// which is the newest — and clears the flag; if more arrived meanwhile it
/// schedules itself again. A stalled main actor therefore accumulates exactly
/// one pending delivery carrying the newest value.
///
/// The session is checked twice: when posting, and again on main immediately
/// before handing the value over. Cancellation cannot reach a hop already
/// enqueued on the main queue, so the gate at the far end is the one that
/// actually stops a readout arriving after a stop.
final class MainMailbox<Value: Sendable>: @unchecked Sendable {

    private struct State {
        var pending: Value?
        var inFlight = false
        var generation = 0
        var deliver: (@Sendable (Value) -> Void)?
        /// The last value main accepted, so an unchanged one is dropped —
        /// recorded on acceptance, never on posting.
        var lastDelivered: Value?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let isEqual: @Sendable (Value, Value) -> Bool
    /// Where deliveries land. The main queue in the app; in tests, a queue the
    /// test owns — blocking the real main queue to prove the bound would starve
    /// every other test running alongside.
    private let deliveryQueue: DispatchQueue

    /// - Parameters:
    ///   - isEqual: used to drop a value identical to the last one actually
    ///     delivered.
    ///   - deliveryQueue: where the delivery closure is run.
    init(
        isEqual: @escaping @Sendable (Value, Value) -> Bool,
        deliveryQueue: DispatchQueue = .main
    ) {
        self.isEqual = isEqual
        self.deliveryQueue = deliveryQueue
    }

    /// Opens a session. Returns the generation the caller should quote.
    @discardableResult
    func open(deliver: @escaping @Sendable (Value) -> Void) -> Int {
        state.withLock { s in
            s.generation &+= 1
            s.deliver = deliver
            s.pending = nil
            s.lastDelivered = nil
            return s.generation
        }
    }

    /// Ends the session. Anything already enqueued for main is disqualified by
    /// the generation bump, without waiting on the producer's queue.
    func close() {
        state.withLock { s in
            s.generation &+= 1
            s.deliver = nil
            s.pending = nil
            s.lastDelivered = nil
        }
    }

    /// Replaces the delivery closure without starting a new session, for a
    /// caller that is already running. Opening a new generation here would
    /// orphan every listener holding the old one — their updates would be
    /// dropped as stale and the readout would go quiet.
    func setDeliver(_ deliver: @escaping @Sendable (Value) -> Void) {
        state.withLock { $0.deliver = deliver }
    }

    var currentGeneration: Int { state.withLock { $0.generation } }

    /// Offers a value. Drops it if the session has moved on, or if it matches
    /// what main last accepted.
    func post(_ value: Value, generation: Int) {
        let schedule = state.withLock { s -> Bool in
            guard generation == s.generation, s.deliver != nil else { return false }
            if let last = s.lastDelivered, isEqual(last, value) {
                // The state has come back to what main is already showing. Any
                // value still waiting is an intermediate one the user would
                // now see *after* the value it was on the way to — A, B, A
                // delivering B last. Drop it with this one.
                s.pending = nil
                return false
            }
            s.pending = value
            guard !s.inFlight else { return false }
            s.inFlight = true
            return true
        }
        guard schedule else { return }
        deliveryQueue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        let taken = state.withLock { s -> (Value, @Sendable (Value) -> Void)? in
            s.inFlight = false
            guard let value = s.pending, let deliver = s.deliver else { return nil }
            s.pending = nil
            s.lastDelivered = value
            return (value, deliver)
        }
        guard let (value, deliver) = taken else { return }
        deliver(value)
    }
}
