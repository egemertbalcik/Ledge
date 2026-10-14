import Foundation
import LedgeCore
import os

/// Feeds the lid sensor and a clock into `LidConserver`, one event at a time.
///
/// Two sources, one consumer. The hinge produces events whenever it likes —
/// and the registry notification behind it fires for every power event, not
/// only for the lid — while the brightness sample has to come round every
/// thirty seconds whether anything moved or not. Both end up in the same
/// method, and the order they reach it in is the order they arrived.
///
/// ## Three rules, each of them learned from a counterexample
///
/// **Events are fenced at consumption, not only at delivery.** `LidConserver`
/// is an actor, so two `Task`s would each run to completion, but nothing says
/// which goes first: a close and an open a few hundred milliseconds apart could
/// land as open-then-close and leave the Mac conserving with its lid up. Each
/// event therefore waits on the one before it *and* checks, at the moment it
/// runs, that the session it belongs to is still the current one. `stop()`
/// unregisters a sensor; it does not reach into a callback already on its way,
/// and such a callback carrying a hard-coded `sessionRunning: true` re-darkened
/// a panel after its session had ended.
///
/// **The watch outlives the session when the session leaves work behind.** A
/// restore that failed while the lid was shut can only be repaired by another
/// pass, and the events that would cause one are exactly what cancelling the
/// sensor and the timer takes away. So monitoring stops when the conserver says
/// nothing is outstanding, not when the session ends.
///
/// **A quit waits for the restore.** Enqueuing it and exiting leaves the panel
/// at zero until the next launch, with the user holding a dark laptop.
public final class LidConserveDriver: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "lid")

    private let sensor: any LidSensing
    private let conserver: LidConserver

    private let lock = NSLock()
    /// The tail of the chain. Each new event awaits it before doing its own
    /// work, which is what keeps arrival order.
    private var pump: Task<Void, Never>?
    private var ticker: DispatchSourceTimer?
    /// Which registration of the sensor an event belongs to.
    ///
    /// Bumped whenever the watch is started or stopped, and captured when the
    /// callback is *registered* rather than when an event arrives — which is
    /// the whole of the fix. A callback captured before `stop` and delivered
    /// afterwards still carries the number of the watch that handed it out,
    /// and that number is no longer current. Fencing on the session instead
    /// would have let it through, because by the time the event ran the
    /// session had already been incremented past it.
    ///
    /// Deliberately not the session: the watch outlives the session whenever
    /// a restore is still owed, and events arriving in that window are exactly
    /// the ones that repair it.
    private var watchEra = 0
    private var sessionID: String?
    /// A session is live. Not the same as "the sensor is watching".
    private var running = false
    /// The sensor is registered. Outlives `running` while entries remain.
    private var watching = false

    public init(sensor: any LidSensing, conserver: LidConserver) {
        self.sensor = sensor
        self.conserver = conserver
    }

    deinit {
        ticker?.cancel()
        sensor.stop()
    }

    /// Puts back anything a previous run left behind. Before any session.
    ///
    /// If something cannot be put back, the watch starts anyway: a record left
    /// by a dead process is owed to the user whether or not they ever switch
    /// Keep Awake on again.
    public func recover() {
        enqueue { conserver in await conserver.recover() }
    }

    /// A lid-closed session started.
    ///
    /// The sensor calls back once with the reading as it stands, so a session
    /// begun on a Mac that is *already* shut — the one the user most wants to
    /// work, because they closed the lid and then reached for their phone —
    /// conserves without waiting for a hinge that is not going to move.
    public func begin(sessionID id: String) {
        // The guard returns from the *function*. A `return` inside
        // `lock.withLock` returns only from the closure and carries straight
        // on into the body below it, which is how this was an idempotence
        // guard in name only: a second `begin` registered a second sensor
        // callback and a second timer on top of the first.
        let start: Bool = lock.withLock {
            // One session at a time. A second `begin` while one is running is
            // not a fresh start, and quietly re-pointing the driver at another
            // session id would have its events journalled under a name that
            // was never conserved for.
            guard !running else { return false }
            running = true
            sessionID = id
            return true
        }
        guard start else { return }

        enqueue { conserver in
            await conserver.sessionBegan()
            return nil
        }
        startWatching()
    }

    /// The session ended, by any route. Everything goes back.
    ///
    /// The sensor and the timer are deliberately *not* cancelled here. They
    /// stop when the conserver reports nothing outstanding, because a restore
    /// that could not land while the lid was shut needs the lid opening to try
    /// again — and that is an event only a live watch can hear.
    public func end() {
        let wasRunning: Bool = lock.withLock {
            let was = running
            running = false
            sessionID = nil
            return was
        }
        guard wasRunning else { return }
        enqueue { conserver in await conserver.sessionEnded() }
    }

    /// Waits for everything queued, and for whatever it starts.
    ///
    /// A quit awaits this. Enqueuing a restore and exiting leaves the panel at
    /// zero with the record on disk — recoverable at the next launch, but only
    /// at the next launch.
    public func settle() async {
        // Twice, because settling the tail can itself enqueue: a restore that
        // lands clears the record, and the pass that clears it is behind the
        // one that was waited for.
        for _ in 0..<3 {
            // The sensor queue first: registration and unregistration happen
            // there, and a reading delivered by a registration that has not
            // run yet is a reading nobody is waiting for.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Self.queue.async { continuation.resume() }
            }
            let tail = lock.withLock { pump }
            await tail?.value
        }
    }

    /// Whether the sensor is still registered — which is to say, whether
    /// anything is still owed. For a test, and for a quit that wants to know.
    public var isWatching: Bool { lock.withLock { watching } }

    /// The session whose events the driver is currently serving, if any.
    public var currentSessionID: String? { lock.withLock { sessionID } }

    // MARK: - The watch

    private static let queue = DispatchQueue(label: "com.egemert.ledge.lid", qos: .utility)

    private func startWatching() {
        let era: Int? = lock.withLock {
            guard !watching else { return nil }
            watching = true
            watchEra += 1
            return watchEra
        }
        guard let era else { return }

        // Registration and unregistration both happen here, on one queue, in
        // order. The state lock cannot carry that: it is released before the
        // sensor call, so an old `stop()` resuming after a new `observe()` had
        // already run would unregister the watch that replaced it — and
        // `observe` calls back synchronously, so holding the lock across it
        // would re-enter the driver.
        Self.queue.async { [weak self] in
            guard let self else { return }
            guard self.lock.withLock({ self.watchEra == era && self.watching }) else { return }
            self.sensor.observe { [weak self] reading in
                self?.observed(reading, watch: era)
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now() + LidBrightnessSampler.cadence,
                       repeating: LidBrightnessSampler.cadence,
                       leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.observed(self.sensor.read(), watch: era)
        }
        timer.resume()
        lock.withLock { ticker = timer }
    }

    /// Stops the watch, but only if it is still the watch the caller meant.
    ///
    /// - Parameter expecting: the registration the decision to stop was made
    ///   against. A completion belonging to a session that has ended used to
    ///   decide "nothing is running" under the lock, drop the lock, and then
    ///   unregister whatever watch it found — which by then could be the one a
    ///   *replacement* session had just started on top of. That session then
    ///   ran with neither the hinge nor the clock feeding it.
    private func stopWatching(expecting era: Int? = nil) {
        let stale: DispatchSourceTimer?? = lock.withLock {
            guard watching else { return .none }
            // Both halves checked here, together, against the state as it is
            // now — not as it was when the caller decided.
            if let era, era != watchEra { return .none }
            guard !running else { return .none }
            watching = false
            // Anything already dispatched under this registration is now from
            // a watch that no longer exists.
            watchEra += 1
            let held = ticker
            ticker = nil
            // Enqueued inside the lock, so the order these run in is the
            // order the state changed. Enqueuing after the lock was released
            // left a window where a replacement session could register its
            // watch between this decision and the `sensor.stop()` below —
            // and this stop would then unregister that session's only source
            // of hinge events. The identity check inside stays as well.
            Self.queue.async { [weak self] in
                guard let self else { return }
                guard self.lock.withLock({ !self.watching }) else { return }
                self.sensor.stop()
            }
            return .some(held)
        }
        guard let held = stale else { return }
        held?.cancel()
    }

    /// One reading, from the hinge or from the clock.
    ///
    /// `watch` is the registration this reading came from, stamped when the
    /// callback was handed out. The session is read live at consumption, so a
    /// reading that arrives after the session ended still runs — as a restore,
    /// which is exactly what should happen to it.
    private func observed(_ reading: LidReading, watch: Int) {
        enqueue { [weak self] conserver in
            guard let self else { return nil }
            let now: (live: Bool, running: Bool, session: String?) = self.lock.withLock {
                (self.watchEra == watch, self.running, self.sessionID)
            }
            guard now.live else {
                // A callback captured before `stop` and delivered after it.
                // Acting on it would conserve for a session that is over.
                return nil
            }
            return await conserver.update(reading: reading,
                                          sessionRunning: now.running,
                                          sessionID: now.session)
        }
    }

    /// Adds one piece of work to the chain, and acts on what it reported.
    ///
    /// The outcome decides whether the watch goes on. Nothing else can decide
    /// it: the conserver owns the record, and "is anything still owed" is a
    /// question only it can answer.
    private func enqueue(
        _ work: @escaping @Sendable (LidConserver) async -> LidConserver.Outcome?
    ) {
        lock.withLock {
            let previous = pump
            let conserver = self.conserver
            pump = Task { [weak self] in
                await previous?.value
                let outcome = await work(conserver)
                self?.settleWatch(outcome)
            }
        }
    }

    /// Starts or stops the watch according to what is still owed.
    ///
    /// Deliberately not keyed on the session ending. A failed restore keeps
    /// its record, and a record nothing is watching for is a record nothing
    /// will ever clear.
    private func settleWatch(_ outcome: LidConserver.Outcome?) {
        guard let outcome else { return }
        // The era this completion belongs to, and nothing else decided here.
        // Whether to stop is one decision and it is made inside
        // `stopWatching`, under the lock, against the state as it is then —
        // because a session beginning between a check out here and the action
        // in there reuses the watch that is already registered, and this
        // completion would unregister it out from under them.
        let era = lock.withLock { watchEra }

        guard !outcome.owesSomething else {
            Self.log.notice("lid: nothing is running and something is still owed — still watching")
            // Recovery at launch reaches here with no session and either a
            // record it could not put back or a journal it could not read.
            // Both are owed; the difference is only whether we know what.
            // Retiring the watch on an unresolved journal left nothing to
            // notice the disk coming back, so "retried on every pass"
            // described passes that never happened.
            // Only on behalf of a session that is over. A live one is
            // already watching.
            if lock.withLock({ !running }) { startWatching() }
            return
        }
        stopWatching(expecting: era)
    }
}
