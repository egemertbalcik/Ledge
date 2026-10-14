import Foundation

/// The numbers the daemon will not negotiate about.
public enum HelperLimits {

    /// What a client may ask the lease to be. Below 30 s a hiccup in the app
    /// would drop the hold; above 120 s a Mac whose Ledge has died stays awake
    /// for longer than anybody would wait for it.
    public static let leaseSeconds: ClosedRange<TimeInterval> = 30...120

    /// The furthest ahead a deadline may be fixed.
    ///
    /// Seven days, because that is what the app offers — `KeepAwakeReducer`
    /// allows a session of up to seven days and a user can pick one. A horizon
    /// below it is not a safety margin, it is a disagreement: the daemon fixed
    /// the first hold at its own lower number, then refused the renewal
    /// carrying the *same unchanged* deadline the app had always been sending,
    /// and the hold died at ninety-one seconds with the card still saying it
    /// was on.
    ///
    /// The rule this encodes is the one that matters whatever the number is:
    /// **an acknowledged hold must never reject its own unchanged renewal.**
    /// `SessionNote.asked` holds the other half of it.
    public static let deadlineHorizon: TimeInterval = 7 * 24 * 60 * 60

    /// How many client holds may be waiting for the store at once.
    ///
    /// Only holds queue. A release, an expiry, a reaped child and a SIGTERM
    /// all move this Mac towards being allowed to sleep, so none of them is
    /// ever refused for want of room.
    public static let queuedHolds = 8

    /// Another daemon has the lock: 250 ms, doubling to 2 s.
    public static let lockBackoffNs: [UInt64] = [250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000]

    /// `pmset` refused, or the readback disagreed: 5 s, 15 s, 60 s, then every
    /// 5 minutes for as long as the daemon runs. It does not idle-exit while
    /// anything is outstanding, so "for as long as the daemon runs" means
    /// until it is clean.
    public static let retryBackoffNs: [UInt64] = [5_000_000_000, 15_000_000_000, 60_000_000_000, 300_000_000_000]
}

/// What the daemon says about itself.
public struct HelperStatus: Equatable, Sendable {
    public var build: String
    /// The last reading of SleepDisabled, or -1 if the daemon has not managed
    /// to read one.
    public var sleepDisabled: Int
    /// A reading of 1 is explained by a claim of ours.
    public var ours: Bool
    /// No claim of this daemon's label, and nothing in flight. Says nothing
    /// about `sleepDisabled`: somebody else's 1 is still clean.
    public var clean: Bool
    /// A claim of ours is outstanding with nobody holding it — the restore has
    /// not been confirmed yet.
    public var cleanupPending: Bool
    public var otherLedgeHolds: Bool
    public var lowPowerClaimed: Bool
}

/// Everything the root daemon thinks, with nothing privileged in it.
///
/// The daemon's job is one sentence long: keep `pmset disablesleep` at 1 while
/// Ledge keeps saying so, and put it back the moment Ledge stops. The danger is
/// the second half. A Mac whose daemon lost contact with its app and kept
/// holding is a Mac that cannot sleep in a bag, so the hold is leased: Ledge
/// renews every 30 s, the lease lapses 90 s after the last renewal on a clock
/// no wall-clock change can touch, and the restore starts then.
///
/// Everything here is event-driven on one serial queue, and nothing in it
/// blocks. `pmset` runs as a child elsewhere and reports back as an event, so
/// a lease expiry arriving while a write hangs is still seen the moment it
/// happens — the restore simply starts once the child has been reaped.
///
/// It is a plain class, not an actor, deliberately: an actor re-enters at every
/// `await`, and "no two things happen between this decision and that write" is
/// the only property this file exists to provide.
public final class HelperCore {

    // MARK: - Collaborators

    private let label: String
    private let bootID: String
    private let clock: any HelperClock
    private let store: any ClaimStore
    private let pmset: any PmsetRunner
    private let timer: any HelperTimer
    private let log: any HelperLog
    /// The ninety-second bound, enforced by something that is not this queue.
    ///
    /// Everything here runs on one serial queue, and a claim-store save is
    /// synchronous file I/O. A save that does not come back takes the lease
    /// expiry with it, and the promise this daemon makes is a promise about
    /// *time*, not about the control queue being healthy. So the bound is
    /// published outwards and enforced from outside. See `LeaseWatchdog`.
    private let watchdog: LeaseWatchdog?

    public init(
        label: String,
        bootID: String,
        clock: any HelperClock,
        store: any ClaimStore,
        pmset: any PmsetRunner,
        timer: any HelperTimer,
        log: any HelperLog = SilentHelperLog(),
        watchdog: LeaseWatchdog? = nil
    ) {
        self.label = label
        self.bootID = bootID
        self.clock = clock
        self.store = store
        self.pmset = pmset
        self.timer = timer
        self.log = log
        self.watchdog = watchdog
    }

    // MARK: - State

    /// The session the hold is for, and the two bounds on it.
    private struct Holder {
        let sessionID: String
        var generation: Int
        /// Wall clock, fixed at the session's first hold. Nil runs until the
        /// app says otherwise.
        var deadline: Date?
        /// Monotonic, and the bound that holds when the app is gone.
        var leaseExpiryNs: UInt64
    }

    /// What the daemon remembers about a session id it has been told about.
    ///
    /// Kept after the session ends, because the point of remembering is to
    /// refuse a command that arrives late. The daemon exits when it is idle,
    /// so this cannot grow for longer than a Mac stays awake with Ledge
    /// starting and ending sessions.
    private struct SessionNote {
        /// Fixed at the first hold; nil is an indefinite hold, not an unknown
        /// one.
        var deadline: Date?
        /// What the client actually sent at the first hold, before any
        /// clamping.
        ///
        /// The acceptance test compares against this, not against the fixed
        /// deadline, so a hold that was clamped can never reject the renewal
        /// of itself. The *effective* deadline is still `deadline` and still
        /// never moves — this only decides what counts as "the same request
        /// again".
        var asked: Date?
        var highestGeneration: Int
        /// Released, lapsed, or past its deadline. A command naming it needs a
        /// generation above `highestGeneration` to be taken seriously again.
        var retired: Bool
    }

    private struct HoldRequest {
        let sessionID: String
        let generation: Int
        let leaseSeconds: TimeInterval
        let reply: @Sendable (KeepAwakeHelperCode) -> Void
    }

    /// What this Mac actually looks like, as opposed to what is wanted.
    private enum Actual: Equatable {
        /// Nothing has been read yet. Only true before the first start.
        case unknown
        case notClaimed
        case claimed
        /// A restore `pmset` refused or a readback contradicted. The claim
        /// stays, the daemon is not clean, and it keeps trying.
        case restoreFailed(attempt: Int)
    }

    /// One privileged operation, from taking the lock to releasing it.
    private struct Transaction {
        enum Kind: Equatable {
            case startup, apply, restore
            /// Low Power Mode on for the length of the hold, and back to
            /// whatever it was afterwards. A separate transaction from the
            /// sleep setting, never a step inside one: they are two settings,
            /// each written and read back on its own, and a daemon that bound
            /// them together would have no way to be half right about them —
            /// which is the state it is in whenever one write lands and the
            /// other does not.
            case applyLowPower, restoreLowPower

            var isLowPower: Bool {
                self == .applyLowPower || self == .restoreLowPower
            }

            /// Whether this transaction *creates* an obligation rather than
            /// discharging one.
            ///
            /// The difference decides what a refused journal means. An apply
            /// that cannot be written down must not happen: it would leave a
            /// changed Mac with nothing saying who changed it. A restore that
            /// cannot be written down must happen anyway: it is undoing
            /// something already recorded, its late child writes a setting
            /// back rather than taking one, and refusing it leaves a Mac that
            /// cannot sleep.
            var takesSomething: Bool {
                self == .apply || self == .applyLowPower
            }

            /// What this transaction reads, both before it decides and after
            /// it writes.
            var readCommand: PmsetCommand {
                isLowPower ? .readLowPowerMode : .readSleepDisabled
            }
        }
        /// Every operation reads before it decides and reads after it writes.
        /// `pmset` exiting 0 is not evidence that the setting changed.
        enum Step: Equatable { case reading, writing, verifying }

        let id: Int
        /// An apply becomes a restore when it finds a lapsed claim standing
        /// where it wanted to put its own.
        var kind: Kind
        var step: Step
        /// Loaded once, under the lock, at the start. Nothing else can change
        /// it while the transaction runs, which is the reason the lock is held
        /// across the child and not only across the writes.
        var ledger: ClaimLedger
        /// Labels whose claims come out of the ledger once the restore reads
        /// back as 0.
        var restoring: [String]
        /// Writes still to go, in order.
        ///
        /// A list rather than one command because Low Power Mode is stored
        /// per power source, and putting back "on for battery only" takes a
        /// `-b` and a `-c`. The sleep setting always has exactly one.
        var writes: [PmsetCommand] = []
        /// What the readback has to say for a Low Power Mode transaction.
        var wantedLowPower: LowPowerSetting?
        /// How much fail-safe writing had happened when this transaction
        /// started.
        ///
        /// Invalidating the cache was not enough on its own: a transaction
        /// whose readback was taken *before* a fail-safe write landed could
        /// still answer afterwards, and `afterVerify` would write `.claimed`
        /// back over the invalidation. Consuming a counter must not make an
        /// older read trustworthy.
        var failSafeActivityAtStart = 0
        /// How many of this process's *own* writes had settled late when this
        /// transaction started.
        ///
        /// The fail-safe counter cannot carry these. An operation's reply is
        /// not proof that the child behind it has stopped: `run` answers
        /// `.failed` when a child's pipes time out, or when collection gives
        /// up on a child that is still alive, and the write can be ahead of
        /// it. So a write reported as failed could land after a *newer*
        /// transaction had already read the setting — and that newer reading
        /// then passed every fence there was.
        var lateWritesAtStart = 0
    }

    private var started = false
    private var startupDone = false
    private var terminating = false

    private var holder: Holder?
    private var sessions: [String: SessionNote] = [:]
    /// Whether the holder has asked for Low Power Mode.
    ///
    /// Tied to the holder and nothing else: it goes the moment the hold goes,
    /// by release, by lease, by deadline or by SIGTERM. A Low Power Mode left
    /// on past the session that wanted it is a Mac quietly running slower
    /// than its owner asked it to, for no reason anybody could find.
    private var lowPowerWanted = false
    /// A Low Power Mode apply of ours has been written and read back.
    ///
    /// False at startup, always: no hold survives a daemon restart, so
    /// nothing this daemon has not itself confirmed may be believed.
    private var lowPowerApplied = false
    /// Some claim in the store records a Low Power Mode that is this daemon's
    /// to put back. Refreshed from the ledger on every read, never remembered
    /// across one.
    private var lowPowerOutstanding = false
    /// Our entry in the store, as last read or written.
    private var claim: HelperClaim?
    private var actual: Actual = .unknown
    private var sleepDisabledReading = -1
    private var otherLedgeHolds = false
    /// SleepDisabled reads 1 and no Ledge claim explains it. Ledge leaves it
    /// exactly as it is, in every state, forever.
    private var foreign = false

    private var transaction: Transaction?
    private var pending: [HoldRequest] = []
    private var nextOpID = 1
    private var lockBackoffStep = 0
    private var lockRetryAtNs: UInt64?
    private var retryStep = 0
    private var retryAtNs: UInt64?
    /// How many times the fail-safe had written the setting when this core
    /// last took account of it.
    private var seenFailSafeFirings = 0
    /// How many writes this process had given up on and then learned had
    /// finished after all. See `noticeLateWrite`.
    private var lateWrites = 0
    /// Writes this process has answered for whose writer can still act.
    ///
    /// Bounded by construction: a live writer holds one of the runner's
    /// permits until it settles, so there can never be more of these than the
    /// runner will admit children. Entries are added by identity and removed
    /// by identity, and nothing else removes them — a set that forgot an
    /// obligation to stay small would be the bug it exists to prevent.
    private var liveWriters: Set<Int> = []
    /// Records this run has marked and has not yet managed to unmark.
    ///
    /// A retirement is complete when the disk says so. A save that fails
    /// leaves this run named on a record — often somebody else's, where there
    /// is no claim of our own to notice it by — and the work is still owed
    /// until it lands. Counted in `isClean`, so the helper cannot be
    /// unregistered while it still owes one.
    private var pendingRetirements: Set<String> = []
    /// Whether this run has a privileged write it has not yet accounted for.
    ///
    /// Raised with the baseline claim, in the same save, before the child can
    /// exist — which is what makes the uncertainty durable rather than
    /// best-effort. Lowered when the write's outcome is known *and* no writer
    /// of it is still able to act.
    private var writeOutstanding = false
    /// When Low Power Mode was last read back and found to be as asked.
    private var lastLowPowerVerifiedNs: UInt64 = 0
    /// When the sleep setting was last read back and found to be ours.
    private var lastVerifiedNs: UInt64 = 0

    // MARK: - Client events

    /// Reconciles whatever the last daemon left behind. Nothing is answered
    /// before this has run, because nothing is known before it.
    public func start() {
        guard !started else { return }
        started = true
        pump()
    }

    /// What the daemon believes, answered from memory.
    ///
    /// Not an event, and not queued: a status call spawns nothing and waits
    /// for nothing, so there is no interleaving for it to be part of.
    public var status: HelperStatus {
        HelperStatus(
            build: label,
            sleepDisabled: sleepDisabledReading,
            ours: claim?.sleepDisabledClaimed == true,
            clean: isClean,
            cleanupPending: claim != nil && holder == nil,
            otherLedgeHolds: otherLedgeHolds,
            lowPowerClaimed: claim?.lowPowerPrior != nil
        )
    }

    /// No claim of our label is outstanding and nothing is in flight.
    ///
    /// This is what `SMAppService.unregister` is gated on. It is deliberately
    /// not "SleepDisabled reads 0": a 1 that somebody else set is not Ledge's
    /// to undo, and refusing to unregister until a Terminal command is
    /// reversed would strand the daemon on the user's Mac forever.
    public var isClean: Bool {
        startupDone && claim == nil && transaction == nil && pending.isEmpty
            // And nothing of ours can still change a setting. Quitting here
            // leaves a privileged write in flight with nobody left to notice
            // where it lands — and no claim on disk saying who to blame.
            && liveWriters.isEmpty
            // And nothing this run has written its name onto that it has not
            // managed to take off again. A foreign record naming us is work
            // we still owe, and `claim == nil` cannot see it.
            && pendingRetirements.isEmpty
    }

    /// Takes or renews the hold.
    ///
    /// The reply waits until the renewal is on disk, because the in-memory
    /// lease must never be later than the persisted one: the other daemon
    /// judges our liveness from the file, and a lease we believe in but never
    /// wrote down is a hold nobody else can see the end of.
    public func hold(
        session: String,
        generation: Int,
        deadline: Date?,
        leaseSeconds: TimeInterval,
        reply: @escaping @Sendable (KeepAwakeHelperCode) -> Void
    ) {
        guard UUID(uuidString: session) != nil, generation >= 1,
              leaseSeconds.isFinite, leaseSeconds > 0 else {
            reply(.invalidArgument)
            return
        }
        // launchd is taking this daemon down and everything it holds is being
        // put back. Taking a new hold now would be taking one nothing is going
        // to renew; the client holds again against the daemon that replaces it.
        guard !terminating else { return reply(.stale) }
        let now = clock.now

        if var note = sessions[session] {
            // A generation only ever goes forwards, and a session the daemon
            // has retired needs a new one before it is listened to again.
            guard generation >= note.highestGeneration else { return reply(.stale) }
            guard !note.retired || generation > note.highestGeneration else { return reply(.stale) }

            switch (note.deadline, deadline) {
            case (nil, nil):
                break
            case (.some(let recorded), .some(let wanted)):
                // Shortening is the app changing its mind; lengthening is the
                // one thing a heartbeat bug could do that the lease cannot
                // catch, so it is the one thing refused outright.
                //
                // Compared against what was *asked* for, never against what
                // this daemon clamped it to. A renewal repeating the original
                // request unchanged is the same request, and refusing it would
                // be refusing a hold that had already been acknowledged.
                let ceiling = note.asked ?? recorded
                guard wanted <= ceiling else { return reply(.invalidArgument) }
                note.asked = min(note.asked ?? wanted, wanted)
                note.deadline = min(recorded, wanted)
            case (nil, .some(let wanted)):
                note.asked = wanted
                note.deadline = min(wanted, now.addingTimeInterval(HelperLimits.deadlineHorizon))
            case (.some, nil):
                // An indefinite hold is later than any deadline this session
                // already fixed.
                return reply(.invalidArgument)
            }

            if let fixed = note.deadline, fixed <= now {
                note.retired = true
                sessions[session] = note
                return reply(.stale)
            }
            note.highestGeneration = generation
            note.retired = false
            sessions[session] = note
        } else {
            var fixed = deadline
            if let wanted = deadline {
                guard wanted > now else { return reply(.invalidArgument) }
                fixed = min(wanted, now.addingTimeInterval(HelperLimits.deadlineHorizon))
            }
            sessions[session] = SessionNote(deadline: fixed, asked: deadline,
                                            highestGeneration: generation, retired: false)
        }

        let lease = min(max(leaseSeconds, HelperLimits.leaseSeconds.lowerBound),
                        HelperLimits.leaseSeconds.upperBound)
        let request = HoldRequest(sessionID: session, generation: generation,
                                  leaseSeconds: lease, reply: reply)

        // A client that heartbeats again before its last one was answered is
        // asking the same question twice; the later one is the one served.
        if let index = pending.firstIndex(where: {
            $0.sessionID == session && $0.generation == generation
        }) {
            pending.remove(at: index).reply(.busy)
        }
        guard pending.count < HelperLimits.queuedHolds else { return reply(.busy) }
        pending.append(request)
        pump()
    }

    /// Turns Low Power Mode on for the length of the hold, or gives it back.
    ///
    /// The agents this exists for are network-bound — they sit on a socket,
    /// not on a clock — so the throttle costs them next to nothing while the
    /// battery saving is real. That is the whole argument for doing something
    /// to a Mac that nobody is watching, and it is why this is the one piece
    /// of Insomnia's conserve that needs root.
    ///
    /// Answered as soon as it is accepted, like `release`: the write goes
    /// behind the same one-at-a-time lock the sleep setting uses, and a client
    /// made to wait for it would be waiting on a `pmset` child for a decision
    /// it does not get to make. `status`'s `lowPowerClaimed` is what says
    /// whether it landed.
    public func setLowPowerMode(
        _ on: Bool,
        session: String,
        generation: Int,
        reply: @escaping @Sendable (KeepAwakeHelperCode) -> Void
    ) {
        guard UUID(uuidString: session) != nil, generation >= 1 else {
            reply(.invalidArgument)
            return
        }
        // Being taken down. Everything held is being put back, and this is
        // one of the things being put back.
        guard !terminating else { return reply(.stale) }

        // Only the session actually holding this Mac may change a system-wide
        // setting on the strength of it. Asked first, because it is the more
        // precise answer: a session that was never the holder is not stale,
        // it is somebody else's.
        guard holder?.sessionID == session else { return reply(.notHolder) }

        // Same generation rule as `hold`, for the same reason: a request
        // carrying a generation the daemon has already retired is a message
        // from before a lapse nobody saw at the time. A session that is the
        // holder always has a note, so this reads only the generation.
        guard let note = sessions[session], !note.retired,
              generation >= note.highestGeneration
        else { return reply(.stale) }

        lowPowerWanted = on
        reply(.ok)
        pump()
    }

    /// Ends the hold. Answered immediately, and never refused.
    ///
    /// The restore it sets in motion is not waited for: the app has its own
    /// bound on how long it will wait, and the daemon's cleanup carries on
    /// whether or not anybody is still listening.
    public func release(
        session: String,
        generation: Int,
        reply: @escaping @Sendable (KeepAwakeHelperCode) -> Void
    ) {
        var note = sessions[session] ?? SessionNote(deadline: nil, highestGeneration: generation,
                                                    retired: true)
        note.retired = true
        note.highestGeneration = max(note.highestGeneration, generation)
        sessions[session] = note

        // Anything queued for a session that is over is over too.
        for index in pending.indices.reversed() where pending[index].sessionID == session {
            pending.remove(at: index).reply(.stale)
        }

        let wasHolder = holder?.sessionID == session
        if wasHolder {
            holder = nil
            // The want goes with the holder, always. What was *done* about it
            // is in the claim, and that is what the restore reads.
            lowPowerWanted = false
            wantedStateChanged()
        }
        reply(wasHolder ? .ok : .notHolder)
        pump()
    }

    // MARK: - Internal events

    /// launchd is taking the daemon down. Treated as a release by every holder
    /// of this label; the host then waits for `isClean`.
    public func sigterm() {
        terminating = true
        if holder != nil {
            holder = nil
            lowPowerWanted = false
            wantedStateChanged()
        }
        for id in sessions.keys { sessions[id]?.retired = true }
        for index in pending.indices.reversed() { pending.remove(at: index).reply(.stale) }
        log.note("sigterm: releasing every hold of \(label)")
        pump()
    }

    /// A `pmset` child has exited and been reaped.
    public func childExited(opID: Int, outcome: PmsetOutcome) {
        guard var current = transaction, current.id == opID else {
            // Its transaction is long over; the child it belonged to has been
            // reaped, so there is nothing to clean up and nothing to decide.
            log.note("ignored a completion for operation \(opID)")
            return
        }
        // A Low Power Mode read answers with its own case, but a `.read`
        // arriving inside a low-power transaction would still be a number
        // about some other setting. `sleepDisabledReading` is what `status`
        // publishes, so letting one through would have the daemon report a
        // SleepDisabled it never read.
        if case .read(let value) = outcome, !current.kind.isLowPower {
            sleepDisabledReading = value
        }

        switch current.step {
        case .reading:
            afterRead(&current, outcome)
        case .writing:
            afterWrite(&current, outcome)
        case .verifying:
            afterVerify(&current, outcome)
        }
        pump()
    }

    /// The timer the core asked for has fired: a lease, a deadline, a retry or
    /// another try at the lock. One entry point for all four, because the core
    /// works out what is due by looking, not by remembering which timer it was.
    public func tick() {
        dropLapsedHolder()
        pump()
    }

    // MARK: - The pump

    private func pump() {
        guard started else { return }
        stampWriterState()
        noticeFailSafeWrites()
        dropLapsedHolder()
        defer { arm() }

        while transaction == nil {
            if !startupDone {
                // The same gate everything else passes. A startup whose
                // publication was refused schedules a retry and then used to
                // start again on the very next pass, which is a root daemon
                // reading the setting as fast as `pmset` can answer.
                if let due = retryAtNs, clock.continuousNanoseconds < due { return }
                beginStartup()
                return
            }
            if let request = pending.first {
                guard settle(request) else { return }
                pending.removeFirst()
                continue
            }
            beginResourceWork()
            return
        }
    }

    /// Drops the hold once either of its bounds has passed.
    ///
    /// Both are checked on every pass rather than armed once, so a wall clock
    /// that moves cannot leave a deadline behind, and a lease cannot be
    /// stretched by moving one either — it is measured on a different clock
    /// entirely.
    /// Forgets what this core believed about SleepDisabled whenever the
    /// fail-safe has written it.
    ///
    /// The watchdog is a second writer, and a second writer that does not go
    /// through the claim store cannot be reconciled by the claim store. Its
    /// write can also land *late* — after the ordinary restore finished and
    /// after a new hold applied 1 — so the Mac can end up at 0 while this core
    /// still believes `.claimed` and skips the read-and-apply path entirely.
    /// Every heartbeat after that confirmed a hold that was not in force.
    ///
    /// So a firing retires the belief, not the hold: the next pass reads
    /// SleepDisabled again and re-applies it if a session still wants it. That
    /// is the only honest repair available to something that cannot cancel a
    /// child it did not start.
    private func noticeFailSafeWrites() {
        guard let watchdog else { return }
        // Both the start of a write and its finish. The start, because one
        // is now in flight and may land at any moment; the finish, because
        // that is when the hardware moved — and a child delayed past a new
        // hold is the whole hazard here.
        let activity = watchdog.writeActivity
        guard activity != seenFailSafeFirings else { return }
        seenFailSafeFirings = activity
        log.note("the fail-safe wrote SleepDisabled; re-reading before believing anything")
        if actual == .claimed { actual = .unknown }
        // Formed from a reading that is now out of date, like the rest of it.
        foreign = false
        // And promptly: a hold the user is relying on has just been written
        // out from under it, and a backoff here is a Mac that sleeps.
        retryStep = 0
        retryAtNs = nil
    }

    /// Whether any power setting was written while this transaction was out.
    ///
    /// Two counters, because there are two kinds of writer this process
    /// cannot otherwise account for: the fail-safe, which runs on its own
    /// queue and its own runner, and its own children that answered `.failed`
    /// and then carried on living. Either one makes a readback taken earlier
    /// a statement about a Mac that has since moved.
    private func wasWrittenUnder(_ current: Transaction) -> Bool {
        (watchdog?.writeActivity ?? 0) != current.failSafeActivityAtStart
            || lateWrites != current.lateWritesAtStart
    }

    /// A write this process had already answered for has finally finished.
    ///
    /// An operation's failed reply is not proof that its writer stopped. A
    /// child whose pipes time out is abandoned and answered for; a child the
    /// bounded poll cannot collect is answered for too. Both can still be
    /// alive with a privileged write ahead of them, and when that write lands
    /// the setting has moved under whatever this core believes.
    ///
    /// Nothing here recalls the write — it was sent, and it cannot be
    /// unsent. What it does is stop the belief: a cached `.claimed` becomes
    /// unknown, an in-flight transaction's readback is fenced by the counter,
    /// and the next pass reads the setting rather than waiting out the
    /// thirty-second re-verify. That last part is the point: the poll was the
    /// only repair, and a poll is not a reaction.
    /// A write is about to be answered for while its writer can still act.
    ///
    /// The counters already here fence a *cache*: they stop a readback taken
    /// in the wrong moment being believed. This is the stronger case, and the
    /// one they cannot cover — a reading can be perfectly fresh and still not
    /// prove that a writer which has not stopped will leave the setting
    /// alone. Everything that destroys evidence on the strength of a reading
    /// — clearing a claim, dropping a Low Power prior, going clean enough to
    /// quit — has to wait for this to empty.
    ///
    /// Waiting is the whole of it. Nothing here writes anything, and nothing
    /// tries to undo a write already sent. Recreating the record afterwards
    /// would not do: the helper can exit or crash between discharging the
    /// obligation and hearing that the writer landed, and then the record is
    /// gone with nothing to rebuild it from.
    public func noticeLiveWriter(opID: Int) {
        // Terminal already. A settlement that overtook its own registration —
        // the salvage queue is independent of the one that answers — must not
        // re-register a writer that has finished, or the obligation it stands
        // for is held for ever by nothing.
        guard !settledWriters.contains(opID) else {
            log.note("a settlement arrived before its registration (op \(opID)); already finished")
            return
        }
        guard liveWriters.insert(opID).inserted else { return }
        log.note("a pmset write was answered for while its writer can still act (op \(opID))")
        stampWriterState()
    }

    /// Writers that have settled, kept only long enough to recognise a
    /// registration that arrives after its own settlement.
    ///
    /// Bounded, and deliberately small: this is a reordering window measured
    /// in queue hops, not a history. An unbounded set of finished ids would
    /// be a memory leak standing in for a race that has already been fixed at
    /// its source.
    private var settledWriters: [Int] = []
    private static let settledMemory = 16

    /// Records on disk whether this helper has a write it cannot account for.
    ///
    /// The flag is the whole of the cross-helper story. Another build's
    /// helper reads this file and sees a lapsed claim; nothing else on the
    /// Mac can tell it that one of ours has a child still holding a
    /// privileged write. Keeping it in memory kept it exactly where the other
    /// helper could not look.
    ///
    /// Saved outside a transaction, because inside one the lock is already
    /// held and the transaction's own `finish` will write it. A save that
    /// cannot take the lock is retried on the next pass rather than skipped.
    /// This run of this helper, as distinct from the label it answers to.
    ///
    /// A label identifies a service; this identifies one lifetime of it. The
    /// durable uncertainty flag belongs to a run, because the only process
    /// entitled to say a writer has finished is the one that started it.
    private let run = UUID().uuidString

    /// Whether this core is entitled to lower the flag on the record it finds.
    ///
    /// Raising it is always ours to do. Lowering it is a statement that the
    /// writers it stands for have been accounted for, and a process that
    /// never knew them cannot make that statement — its empty set is
    /// ignorance, not settlement. A record from an earlier boot is the one
    /// case where starting empty *is* proof: nothing from a previous boot is
    /// still running.
    private func mayLower(_ mark: WriterMark) -> Bool {
        // Ours to retire, or born in a boot that is over. Nothing from a
        // previous boot can still be running, whoever wrote it; everything
        // from this one belongs to the run that raised it.
        mark.run == run || mark.boot != bootID
    }

    /// This run's own mark.
    private var ourMark: WriterMark { WriterMark(run: run, boot: bootID) }

    private func stampWriterState() {
        guard started else { return }
        let wanted = !liveWriters.isEmpty || writeOutstanding
        // Judged against the claim as last written, never against a separate
        // memory of what was stamped. A transaction saves a ledger it loaded
        // earlier, which can put the flag back to what it was before a writer
        // was registered — and a cache that believed its own last word would
        // then skip the repair and leave the uncertainty off the disk, which
        // is the one place it has to be.
        // Judged against what this run owes, not against a separate memory of
        // what was stamped: a transaction saves a ledger it loaded earlier,
        // which can put a record back to what it was before a writer was
        // registered.
        //
        // And not gated on having a claim of our own. A retirement this run
        // owes on somebody *else's* record is still owed — returning early
        // without one is how a failed retirement was forgotten and the helper
        // reported itself finished while a foreign record still named it.
        let ourMarkOnOurClaim = (claim?.writers ?? []).contains(ourMark)
        guard ourMarkOnOurClaim != wanted || !pendingRetirements.isEmpty else { return }
        if transaction != nil {
            // The lock is already this core's, taken when the transaction
            // began. Write through it rather than waiting: a registration
            // arrives *during* the operation it belongs to, and the lock goes
            // the moment that operation fails — straight to whichever process
            // is waiting for it, which would then find a record that says
            // nothing about the writer still out there.
            stampThroughTheHeldLock(wanted)
            return
        }
        guard var ledger = lockAndLoad() else { return }
        defer { store.unlock() }
        guard lowerOurUncertainty(in: &ledger, while: wanted) else { return }
        do {
            try store.save(ledger)
            claim = ledger.claims[label]
            noteRetirements(in: ledger)
        } catch {
            log.note("could not record that a writer is unresolved: \(error)")
        }
    }

    /// Publishes the uncertainty on the lock the current transaction holds.
    ///
    /// The transaction's own copy of the ledger is corrected too, so the
    /// `finish` that follows cannot write an older picture back over this.
    private func stampThroughTheHeldLock(_ wanted: Bool) {
        // Best effort, and deliberately only a top-up. The uncertainty this
        // run owes for its *own* writes is already durable: it went down with
        // the baseline claim before the child existed. What reaches here is
        // the fail-safe's writer, which runs on another queue and has no
        // baseline of its own — and a refusal there is a gap this cannot
        // close, so it is logged rather than pretended away.
        guard var ledger = try? store.load() else {
            log.note("could not read the claim store to record an unresolved writer")
            return
        }
        guard lowerOurUncertainty(in: &ledger, while: wanted) else { return }
        do {
            try store.save(ledger)
            claim = ledger.claims[label]
            transaction?.ledger = ledger
            noteRetirements(in: ledger)
        } catch {
            log.note("could not record that a writer is unresolved: \(error)")
        }
    }

    /// The labels of `labels` whose records may actually be taken away.
    ///
    /// A claim that says its helper has an unaccounted-for write is nobody's
    /// to delete — not the other build's, and not ours. The setting still
    /// gets written back; it is the evidence that has to outlive the
    /// uncertainty.
    private func removable(_ labels: [String], in ledger: ClaimLedger?,
                           of resource: Retained.Resource) -> [String] {
        labels.filter { name in
            guard let record = ledger?.claims[name] else { return true }
            if record.mayBeRemoved { return true }
            log.note("keeping \(name)'s record: it has a write it cannot account for")
            // Our part is done and the record is staying. Remembering that
            // stops the next pass restoring it all over again: a record that
            // can never be removed would otherwise be restored for ever, which
            // is a root daemon running `pmset` in a loop.
            restoredAndRetained.insert(Retained(label: name, resource: resource))
            return false
        }
    }

    /// Records this core has restored and may not remove.
    ///
    /// In-process, because it is about what this run has already done, not
    /// about the obligation — which stays on disk for whoever owns it. A
    /// record that becomes removable drops out of here and is treated
    /// normally again.
    private var restoredAndRetained: Set<Retained> = []

    /// One resource of one helper's record.
    ///
    /// A label names a service, not an obligation, and this cache describes an
    /// obligation: "this run has already put that back and may not remove
    /// it". Keyed by label alone it answered for resources it had never
    /// touched — a retained Low Power prior suppressed a live sleep hold's
    /// End, and a retained sleep claim sent every completed read into another
    /// Low Power restore. Two settings, two obligations, two entries.
    struct Retained: Hashable {
        enum Resource: Hashable { case sleep, lowPower }
        let label: String
        let resource: Resource
    }

    /// Whether the evidence of what Ledge changed may be destroyed.
    ///
    /// Two different ways a reading can fail to justify it, and both have to
    /// hold. The reading may have been taken *before* a writer landed, which
    /// is what the counters catch. Or it may be perfectly fresh and still not
    /// speak for the next moment, because a writer we answered for has not
    /// stopped — which no counter can catch, since nothing has happened yet.
    ///
    /// Caching a stale reading costs one pointless re-read. Destroying the
    /// claim or the prior on one costs the only record of what Ledge changed,
    /// so this is the stricter test and it guards the destructive branches.
    /// Both stay on disk while it is false, which is what makes the
    /// obligation survive a crash in the gap.
    private func mayDischarge(under current: Transaction) -> Bool {
        liveWriters.isEmpty && !wasWrittenUnder(current)
    }

    /// Keeps the obligation and stops: nothing is written, nothing is
    /// cleared, and the backoff holds the queue off until the settlement
    /// wakes it.
    private func deferDischarge(_ why: String) {
        log.note("\(why) — a writer can still act, so the record is kept")
        abandon()
    }

    /// A write this process had already answered for has finally finished.
    ///
    /// The disk is brought up to date by the `pump` below, which is the one
    /// place that stamps outside a transaction — there is no second path here
    /// that could disagree with it.
    public func noticeLateWrite(opID: Int) {
        liveWriters.remove(opID)
        if !settledWriters.contains(opID) {
            settledWriters.append(opID)
            if settledWriters.count > Self.settledMemory { settledWriters.removeFirst() }
        }
        lateWrites &+= 1
        log.note("a pmset write this helper had given up on finished (op \(opID)); re-reading")
        if actual == .claimed { actual = .unknown }
        lowPowerApplied = false
        // Formed from a reading that is now out of date, like the rest of it.
        foreign = false
        // And promptly. A hold the user is relying on may have just been
        // written out from under it, and a backoff here is a Mac that sleeps.
        retryStep = 0
        retryAtNs = nil
        pump()
    }

    private func dropLapsedHolder() {
        guard let current = holder else { return }
        if clock.continuousNanoseconds >= current.leaseExpiryNs {
            log.note("lease lapsed for session \(current.sessionID)")
        } else if let deadline = current.deadline, clock.now >= deadline {
            log.note("deadline reached for session \(current.sessionID)")
        } else {
            return
        }
        holder = nil
        lowPowerWanted = false
        sessions[current.sessionID]?.retired = true
        wantedStateChanged()
    }

    private var desiredIsClaimed: Bool { holder != nil }

    /// Believes the setting is ours, and records when that was last looked
    /// at.
    ///
    /// Always together. A `.claimed` set without stamping the time is a hold
    /// that re-verifies on every single pass, which is a daemon spawning
    /// `pmset` without end.
    /// Believes Low Power Mode is as asked, and records when that was last
    /// looked at.
    ///
    /// Always together, exactly as `markClaimed` pairs them for the sleep
    /// setting. A belief without a timestamp is a hold that never looks
    /// again, which is how another helper's late writer, the other build or a
    /// Terminal window could turn the setting off and leave this one
    /// reporting it on for the rest of the session.
    private func markLowPowerApplied() {
        lowPowerApplied = true
        lastLowPowerVerifiedNs = clock.continuousNanoseconds
    }

    private func markClaimed() {
        actual = .claimed
        lastVerifiedNs = clock.continuousNanoseconds
        // "Already put back" was true until this run applied the setting
        // again. Keeping the belief past a new hold made End skip its restore
        // entirely — a cache meant to stop a spin became the thing that
        // suppressed the undo it was protecting. The *uncertainty* is
        // untouched; only the belief about having finished with the record
        // goes, and only when there is demonstrably something new to undo.
        restoredAndRetained.remove(Retained(label: label, resource: .sleep))
    }

    /// How long a hold may go without looking at the setting it believes it
    /// has.
    ///
    /// One heartbeat. The read is unprivileged and cheap, and it is the only
    /// thing that can catch a writer this process has no counter for — the
    /// other build's fail-safe, or somebody's Terminal window.
    static let verifyIntervalNs: UInt64 = 30_000_000_000

    /// The hold was taken or given up, so a backoff left over from the other
    /// direction is in the way.
    ///
    /// A failed apply must not delay the restore that follows a release by its
    /// own retry schedule: the user let go of the switch, and the Mac being
    /// allowed to sleep again is the thing that has to happen promptly. The
    /// backoff exists to stop a *repeated* attempt at the same thing, and this
    /// is not that.
    private func wantedStateChanged() {
        retryStep = 0
        retryAtNs = nil
    }

    // MARK: - Store transactions

    /// Writes a renewal, and answers the client that is waiting for it.
    ///
    /// - Returns: false when the lock could not be taken, or our own privileged
    ///   operation has it. The request stays queued and is tried again.
    private func settle(_ request: HoldRequest) -> Bool {
        guard store.tryLock() else {
            noteLockBusy()
            return false
        }
        lockBackoffStep = 0
        lockRetryAtNs = nil
        defer { store.unlock() }

        var ledger = loadLedger()
        claim = ledger.claims[label]

        if let live = liveOtherClaim(in: ledger) {
            // It was here first, and SleepDisabled is one setting. Ledge runs
            // as a phase 1 session here and says so.
            otherLedgeHolds = true
            log.note("\(live.holderLabel) holds this Mac; not taking it")
            request.reply(.inUseByOtherLedge)
            return true
        }
        otherLedgeHolds = false

        // Re-checked here and not only on arrival: a request can wait behind a
        // hung `pmset` for longer than the lease it was renewing.
        guard let note = sessions[request.sessionID], !note.retired else {
            request.reply(.stale)
            return true
        }

        // Computed where it is written, not where it was asked for: a renewal
        // that waited 20 s for the lock would otherwise persist an expiry 20 s
        // in the past.
        let expiry = clock.continuousNanoseconds + HelperCore.nanoseconds(request.leaseSeconds)
        var updated = ledger.claims[label] ?? HelperClaim(
            holderLabel: label, boot: bootID, sessionID: request.sessionID,
            generation: request.generation, deadline: note.deadline,
            leaseExpiryContinuousNs: expiry, sleepDisabledClaimed: false
        )
        updated.boot = bootID
        updated.sessionID = request.sessionID
        updated.generation = request.generation
        updated.deadline = note.deadline
        updated.leaseExpiryContinuousNs = expiry
        ledger.claims[label] = updated

        do {
            try store.save(ledger)
        } catch {
            // The in-memory lease stays at the last persisted value. Both
            // daemons judge liveness from the file, so believing in a lease
            // the file does not have is the one thing that must never happen.
            log.note("could not persist a renewal: \(error)")
            request.reply(.persistFailed)
            return true
        }

        claim = updated
        let isNewHold = holder == nil
        holder = Holder(sessionID: request.sessionID, generation: request.generation,
                        deadline: note.deadline, leaseExpiryNs: expiry)
        if isNewHold { wantedStateChanged() }
        request.reply(foreign ? .foreign : .ok)
        return true
    }

    /// Takes the ledger, or sets aside one that cannot be read.
    ///
    /// An unreadable store means ownership of whatever it described is
    /// unknown. The daemon carries on with an empty ledger, which makes any
    /// SleepDisabled it then reads foreign — nobody's to undo, least of all
    /// Ledge's.
    private func loadLedger() -> ClaimLedger {
        do {
            return try store.load()
        } catch {
            log.note("the claim store could not be read; setting it aside")
            try? store.moveAside()
            return .empty
        }
    }

    private func liveOtherClaim(in ledger: ClaimLedger) -> HelperClaim? {
        let now = clock.continuousNanoseconds
        return ledger.claims.values.first {
            $0.holderLabel != label && $0.isLive(inBoot: bootID, atContinuousNanoseconds: now)
        }
    }

    // MARK: - Privileged operations

    private func beginStartup() {
        guard let ledger = lockAndLoad() else { return }
        begin(.startup, ledger: ledger)
    }

    private func beginResourceWork() {
        guard !terminatingAndFinished else { return }
        if let due = retryAtNs, clock.continuousNanoseconds < due { return }

        if desiredIsClaimed {
            // A counter in this process cannot see the other build's daemon,
            // or a `pmset` run by hand, or anything else that writes a
            // machine-wide setting. Nothing can, short of looking. So a hold
            // that believes itself re-reads on a cadence, and a reading of 0
            // sends it back through the apply path.
            if actual == .claimed,
               clock.continuousNanoseconds >= lastVerifiedNs &+ Self.verifyIntervalNs {
                log.note("re-reading SleepDisabled: a hold is only as good as its last look")
                actual = .unknown
            }
            if actual != .claimed {
                // `foreign` and `otherLedgeHolds` are deliberately not
                // consulted here. They are opinions formed by an earlier read,
                // and the only thing that can correct them is another read —
                // which is the first step of the operation they would be
                // blocking. The backoff, not the opinion, is what keeps this
                // from spinning.
                guard let ledger = lockAndLoad() else { return }
                begin(.apply, ledger: ledger)
                return
            }
            // The sleep setting is where it should be, so Low Power Mode is
            // next. After it and never instead of it: the hold is the feature
            // and the saving is what the hold costs, so a Mac that can only
            // manage one of them should be the one that stays awake.
            beginLowPowerWork()
            return
        }

        // A record this run has already put back and may not remove is
        // finished with, as far as this run is concerned. It stays on disk as
        // evidence for whoever owns its uncertainty, and touching it again
        // would write a setting that is already where it belongs — on every
        // pass, for ever, which is a root daemon running `pmset` in a loop.
        // The *sleep* half only, and it skips the sleep restore rather than the
        // whole pass. A record whose sleep obligation this run has already
        // discharged — and may not remove, because its uncertainty belongs to
        // somebody else — can still owe a Low Power restore, and returning
        // here skipped it. That is the same resource-blindness one level up.
        let sleepHandled = restoredAndRetained
            .contains(Retained(label: label, resource: .sleep)) && claim?.mayBeRemoved == false

        switch actual {
        case .claimed, .unknown, .restoreFailed:
            if sleepHandled { break }
            guard let ledger = lockAndLoad() else { return }
            begin(.restore, ledger: ledger)
            return
        case .notClaimed:
            if claim?.sleepDisabledClaimed == true, !sleepHandled {
                // Nothing in memory says the setting is ours, but the record
                // on disk says it might be — and a claim is only ever cleared
                // by a restore that was read back, never by an opinion.
                guard let ledger = lockAndLoad() else { return }
                begin(.restore, ledger: ledger)
                return
            }
            if lowPowerOutstanding || claim?.lowPowerPrior != nil {
                beginLowPowerWork()
                return
            }
            guard claim != nil, !sleepHandled else { return }
            // A hold that never got as far as changing anything. The record of
            // it is all there is to tidy away.
            clearClaimRecord()
            return
        }

        // The sleep half is done with and kept. Whatever Low Power Mode still
        // owes is a separate obligation and still owed.
        if lowPowerOutstanding || claim?.lowPowerPrior != nil { beginLowPowerWork() }
    }

    /// Whether the hold wants Low Power Mode right now.
    private var desiredLowPower: Bool { holder != nil && lowPowerWanted }

    /// Starts whichever Low Power Mode transaction is owed, if either is.
    private func beginLowPowerWork() {
        if desiredLowPower {
            // The same cadence the sleep setting keeps, in the path it had
            // not been carried to.
            //
            // A hold that believes Low Power Mode is applied never looked at
            // it again — not after another helper's late writer turned it
            // off, not after a Terminal window, not after the other build's
            // own session. The sleep setting re-reads every heartbeat on
            // exactly that reasoning: a counter in this process cannot see
            // anybody else's writes, and nothing can, short of looking.
            if lowPowerApplied,
               clock.continuousNanoseconds >= lastLowPowerVerifiedNs &+ Self.verifyIntervalNs {
                log.note("re-reading Low Power Mode: a hold is only as good as its last look")
                lowPowerApplied = false
            }
            guard !lowPowerApplied else { return }
            guard let ledger = lockAndLoad() else { return }
            begin(.applyLowPower, ledger: ledger)
            return
        }
        guard lowPowerOutstanding || claim?.lowPowerPrior != nil else { return }
        // And not again once this run has put it back and may not remove the
        // record. Without this every completed read admitted another Low
        // Power read, for ever, because the prior it is looking at can never
        // go away.
        if restoredAndRetained.contains(Retained(label: label, resource: .lowPower)) { return }
        guard let ledger = lockAndLoad() else { return }
        begin(.restoreLowPower, ledger: ledger)
    }

    private var terminatingAndFinished: Bool { terminating && isClean }

    private func lockAndLoad() -> ClaimLedger? {
        guard store.tryLock() else {
            noteLockBusy()
            return nil
        }
        lockBackoffStep = 0
        lockRetryAtNs = nil
        return loadLedger()
    }

    private func begin(_ kind: Transaction.Kind, ledger: ClaimLedger) {
        let id = nextOpID
        nextOpID += 1
        // What the disk says is what we believe about our own claim, from the
        // moment we have read it. An operation that then fails leaves the
        // claim standing, and `status` has to say so.
        claim = ledger.claims[label]
        transaction = Transaction(id: id, kind: kind, step: .reading, ledger: ledger,
                                  restoring: [],
                                  failSafeActivityAtStart: watchdog?.writeActivity ?? 0,
                                  lateWritesAtStart: lateWrites)
        // Every operation reads first. For an apply it is the evidence that
        // the setting is ours to take; for a restore it is the evidence there
        // is anything to put back.
        pmset.start(kind.readCommand, opID: id)
    }

    /// Starts the next write, or moves on to the readback when none is left.
    ///
    /// The one place a write is issued, so the rule that every write is
    /// followed by a read of the same setting cannot be forgotten at one of
    /// the several sites that start one.
    private func advanceWrites(_ current: inout Transaction) {
        if !current.writes.isEmpty {
            // One admission rule, for every privileged write there is.
            //
            // It used to live in the sleep apply alone, so a Low Power child
            // could exist over a record that said nothing about it — the same
            // window, in the path the rule had not been carried to. Two
            // privileged writes, one rule; and the rule belongs where writes
            // are issued rather than in each caller that issues one.
            guard admitPrivilegedWrite(&current) else { return }
            let next = current.writes.removeFirst()
            current.step = .writing
            transaction = current
            pmset.start(next, opID: current.id)
            return
        }
        current.step = .verifying
        transaction = current
        pmset.start(current.kind.readCommand, opID: current.id)
    }

    /// Publishes, durably, that this run is about to have a privileged write
    /// outstanding — and refuses the write if that cannot be published.
    ///
    /// The claim is already journalled before anything changes; this goes into
    /// the same record, on the lock the transaction holds, before the child
    /// exists. Stamping afterwards could only ever be best effort: the
    /// registration arrives with the failed answer, the save can be refused,
    /// and the lock is released either way — so an unprotected claim reaches
    /// the next helper.
    ///
    /// - Returns: false when nothing may be written, having already ended the
    ///   transaction.
    /// Raises the uncertainty on a record that is about to be journalled
    /// ahead of a privileged write.
    ///
    /// Folded into the save that is already happening, so the rule costs no
    /// extra journal write on either apply path — and so that a disk which
    /// refuses the claim refuses the uncertainty with it, which is the same
    /// answer: a write that cannot be journalled is a write that is not made.
    /// Updates what this run still owes the disk, from a ledger just written.
    private func noteRetirements(in ledger: ClaimLedger) {
        pendingRetirements = Set(
            ledger.claims.filter { $0.value.writers?.contains(ourMark) == true }.keys
        )
    }

    /// This run lowers exactly what it raised, wherever it raised it.
    ///
    /// The raising side marks every record a write acts on, which includes a
    /// lapsed claim of somebody else's that this run is putting back. The
    /// lowering side has to reach the same set, or a foreign record keeps a
    /// flag nobody will ever clear and the cleanup it is protecting never
    /// happens. Ownership is what makes that safe: only the run named in the
    /// record may lower it.
    ///
    /// - Returns: whether anything changed.
    @discardableResult
    private func lowerOurUncertainty(in ledger: inout ClaimLedger, while outstanding: Bool) -> Bool {
        var changed = false
        for (name, var record) in ledger.claims {
            let before = record.writers ?? []
            if outstanding {
                // Only our own record is raised here; the rest are raised at
                // admission, where the write says which ones it acts on.
                guard name == label else { continue }
                markWriterOutstanding(on: &record)
            } else {
                // Exactly what this run may retire, and nothing else. Another
                // run's contribution stays until that run accounts for it.
                record.writers = before.filter { !mayLower($0) }
                if record.writers?.isEmpty == true { record.writers = nil }
            }
            guard (record.writers ?? []) != before else { continue }
            ledger.claims[name] = record
            changed = true
        }
        return changed
    }

    private func markWriterOutstanding(on record: inout HelperClaim) {
        var marks = record.writers ?? []
        guard !marks.contains(ourMark) else { return }
        // Added, never substituted. Somebody else's outstanding write is not
        // replaced by ours: two runs can have children in flight against one
        // obligation, and whichever finishes first must retire only its own
        // contribution.
        marks.append(ourMark)
        record.writers = marks
    }

    private func admitPrivilegedWrite(_ current: inout Transaction) -> Bool {
        // Every record this write acts on, not just our own.
        //
        // The rule is one sentence and it took four rounds to say it in one
        // place: *a privileged write may be issued only when every obligation
        // it acts on is durably marked as having a writer this run cannot yet
        // account for.* Applying it per-site produced a fix for the path each
        // finding named and a hole in the one beside it — our own claim but
        // not a peer's, an apply but not a restore, a restore of ours but not
        // one made on somebody else's behalf. The write knows which records
        // it is undoing; it should be the thing that says so.
        let governed = obligationsGoverned(by: current)
        guard !governed.isEmpty else {
            // Nothing recorded anywhere that this write could invalidate.
            writeOutstanding = true
            return true
        }

        var ledger = current.ledger
        var changed = false
        for name in governed {
            guard var record = ledger.claims[name] else { continue }
            let before = record.writers ?? []
            markWriterOutstanding(on: &record)
            guard (record.writers ?? []) != before else { continue }
            ledger.claims[name] = record
            changed = true
        }
        guard changed else {
            writeOutstanding = true
            return true
        }

        do {
            try store.save(ledger)
            claim = ledger.claims[label]
            current.ledger = ledger
        } catch {
            // A sleep *restore* is the one write that goes out anyway, and
            // the asymmetry is deliberate rather than an oversight.
            //
            // Every other write is refused here, because an unpublished
            // writer is one a peer cannot know to wait for — the peer reads
            // an ordinary removable record, deletes it, and the only account
            // of what the user had is gone while a writer that can still move
            // the setting is in flight.
            //
            // What differs is the cost of waiting. A sleep restore is a Mac
            // asking to be allowed to sleep, and nothing may stand in front of
            // that; it also cannot create an obligation, since it ends one.
            // Low Power Mode is a saving, and a saving delayed by a retry
            // interval costs a little battery, while a lost prior costs the
            // user the setting they chose with no way left to find out what it
            // was. The smaller loss is the one to take.
            //
            // So: sleep goes, Low Power Mode waits for a disk that will take
            // its record.
            guard isUrgentSleepRelease(current) else {
                log.note("refusing a privileged write: its obligations cannot be journalled")
                abandon()
                return false
            }
            log.note("could not journal that a sleep restore is outstanding; restoring anyway")
        }
        writeOutstanding = true
        return true
    }

    /// Whether the write about to go out is the one that lets a Mac sleep.
    ///
    /// Asked of the *command*, not of the transaction's name. Startup's
    /// recovery of somebody's lapsed claim writes exactly the same
    /// `disablesleep 0`, and keying the exception on one spelling of the kind
    /// refused the one write nothing may stand in front of — and then looped,
    /// because startup does not pass the backoff gate the other work does.
    private func isUrgentSleepRelease(_ current: Transaction) -> Bool {
        current.writes.first == .writeSleepDisabled(false)
    }

    /// The records a write is about to act on.
    ///
    /// An apply takes something and the obligation it creates is this run's
    /// own. A restore ends somebody's — sometimes ours, sometimes a lapsed
    /// claim we are putting back on their behalf, and that foreign record is
    /// exactly the one at stake: it is the only account of what the user had,
    /// and a peer reading it while this writer is still able to act sees an
    /// ordinary removable prior.
    private func obligationsGoverned(by current: Transaction) -> [String] {
        switch current.kind {
        case .apply, .applyLowPower:
            return current.ledger.claims[label] == nil ? [] : [label]
        case .restore, .startup:
            var names = current.restoring
            if current.ledger.claims[label] != nil, !names.contains(label) { names.append(label) }
            return names.filter { current.ledger.claims[$0] != nil }
        case .restoreLowPower:
            var names = lowPowerClaims(in: current.ledger).labels
            if current.ledger.claims[label] != nil, !names.contains(label) { names.append(label) }
            return names.filter { current.ledger.claims[$0] != nil }
        }
    }

    private func afterRead(_ current: inout Transaction, _ outcome: PmsetOutcome) {
        if current.kind.isLowPower {
            guard case .lowPower(let reading) = outcome else {
                log.note("could not read Low Power Mode: \(outcome)")
                fail(current)
                return
            }
            switch current.kind {
            case .applyLowPower: applyLowPowerRead(&current, reading)
            default: restoreLowPowerRead(&current, reading)
            }
            return
        }

        guard case .read(let value) = outcome, value >= 0 else {
            log.note("could not read SleepDisabled: \(outcome)")
            fail(current)
            return
        }

        switch current.kind {
        case .startup:
            startupRead(&current, sleepDisabled: value)
        case .apply:
            applyRead(&current, sleepDisabled: value)
        default:
            restoreRead(&current, sleepDisabled: value)
        }
    }

    /// Which claims are this daemon's to undo, and which are to be left alone.
    ///
    /// The rules, in the order they matter: a claim from an earlier boot is
    /// nobody's — continuous time restarted, so nothing in this boot is
    /// relying on it. A claim of our own label is ours whatever it says,
    /// because no hold survives a daemon restart. A claim of the other build
    /// whose lease is still live in this boot is *theirs*, and the single most
    /// important thing this function does is leave it alone. The same claim
    /// with a lapsed lease is undone on their behalf, because the app behind
    /// it has stopped speaking and somebody has to put the setting back.
    ///
    /// Claims with nothing privileged behind them are dropped from the ledger
    /// on the spot; the rest are returned, and leave the ledger only once a
    /// restore has been read back.
    private func classify(_ ledger: inout ClaimLedger) -> [String] {
        var restoring: [String] = []
        otherLedgeHolds = false
        // A fresh fact on every read, never a memory. The ledger is the only
        // thing that knows, and it is read at the start of every transaction.
        lowPowerOutstanding = false
        let now = clock.continuousNanoseconds

        for (holderLabel, record) in ledger.claims {
            let ours = holderLabel == label
            if !ours && record.isLive(inBoot: bootID, atContinuousNanoseconds: now) {
                otherLedgeHolds = true
                continue
            }
            if record.mayBeRemoved {
                restoredAndRetained.remove(Retained(label: holderLabel, resource: .sleep))
                restoredAndRetained.remove(Retained(label: holderLabel, resource: .lowPower))
            }
            // Asked per resource, never per record. A record whose sleep half
            // this run has already put back — and may not remove, because its
            // uncertainty belongs to somebody else — can still owe a Low Power
            // restore, and one answer for both is how a prior came to be
            // restored on every completed read without end.
            //
            // Only the sleep half is filtered here. The Low Power half is
            // stopped at `beginLowPowerWork`, which is the single place that
            // starts that work; filtering it twice would mean two conditions
            // that have to agree, and one of them never read.
            let sleepHandled = restoredAndRetained
                .contains(Retained(label: holderLabel, resource: .sleep))
            if record.needsRestore {
                if record.lowPowerPrior != nil { lowPowerOutstanding = true }
                // Only a sleep claim belongs in this list. A claim that says
                // nothing but "Low Power Mode was off" would otherwise send
                // the sleep restore to write `disablesleep 0` over a 1 that
                // somebody else — Amphetamine, a Terminal window — had set.
                if record.sleepDisabledClaimed && !sleepHandled {
                    if !ours { log.note("restoring a lapsed claim on behalf of \(holderLabel)") }
                    restoring.append(holderLabel)
                }
            } else {
                // Nothing claimed and no prior: there is nothing here for an
                // unresolved writer to protect. What `writerUnresolved`
                // guards is evidence, and this record has none.
                ledger.claims[holderLabel] = nil
            }
        }
        return restoring
    }

    /// Sorts out what the last daemon, the last boot or the other build left
    /// behind.
    private func startupRead(_ current: inout Transaction, sleepDisabled: Int) {
        var ledger = current.ledger
        let restoring = classify(&ledger)
        current.ledger = ledger
        current.restoring = restoring

        // No hold survives a daemon restart. The app's next heartbeat takes a
        // new one, with a new generation, and until it does this Mac is free
        // to sleep.
        holder = nil
        actual = .notClaimed

        guard !restoring.isEmpty else {
            foreign = sleepDisabled == 1 && !otherLedgeHolds
            if foreign { log.note("SleepDisabled is 1 and no Ledge claim explains it; leaving it") }
            startupDone = true
            finish(current, saving: ledger, removing: [])
            return
        }

        // A live claim by the other build is the one thing that outranks a
        // restore: the 1 on this Mac is theirs now, and writing 0 would end
        // their session from inside ours. Their claim stays; the lapsed ones
        // are simply dropped, since nothing is relying on them.
        if sleepDisabled == 1 && !otherLedgeHolds {
            current.writes = [.writeSleepDisabled(false)]
            advanceWrites(&current)
            return
        }
        // Nothing to put back, by this reading. The same caveat as everywhere
        // else: a reading cannot speak for the next moment while a writer of
        // ours is still able to act. Vanishingly unlikely this early — the
        // process has only just started — but the rule is the rule, and the
        // fail-safe runs on its own queue from the moment it is seeded.
        startupDone = true
        guard mayDischarge(under: current) else {
            deferDischarge("startup found nothing to put back")
            return
        }
        finish(current, saving: ledger, removing: restoring)
    }

    private func applyRead(_ current: inout Transaction, sleepDisabled: Int) {
        var ledger = current.ledger
        let restorable = classify(&ledger)
        current.ledger = ledger

        if otherLedgeHolds {
            log.note("the other Ledge build holds this Mac; not taking it")
            abandon()
            return
        }

        if sleepDisabled == 1 {
            if ledger.claims[label]?.sleepDisabledClaimed == true {
                // A previous attempt of ours landed after all; its readback
                // was what failed.
                claim = ledger.claims[label]
                // Fenced here as well as at the verification. This is a read
                // result like any other, and a reading of 1 taken before a
                // fail-safe write landed says nothing about the Mac
                // afterwards — caching it here, with a fresh timestamp,
                // bypassed the repair entirely.
                if wasWrittenUnder(current) {
                    log.note("the setting was written while this read was out; reading again")
                    // Not `abandon()`: that schedules a backoff, and this is
                    // not a failure to be backed off from. It is a reading
                    // that arrived too late to mean anything, and the right
                    // answer is another reading, now.
                    actual = .unknown
                    retryStep = 0
                    retryAtNs = nil
                    finish(current, saving: nil, removing: [])
                    return
                }
                markClaimed()
                foreign = false
                finish(current, saving: ledger, removing: [])
                return
            }
            if !restorable.isEmpty {
                // Somebody's lapsed claim is sitting where ours is going. Undo
                // it first and on its own terms — a claim is cleared by a
                // restore that was read back, never by being written over —
                // and the next pass applies ours from a known 0.
                log.note("undoing a lapsed claim before taking the setting")
                current.kind = .restore
                current.restoring = restorable
                current.writes = [.writeSleepDisabled(false)]
                advanceWrites(&current)
                return
            }
            foreign = true
            log.note("SleepDisabled is already 1 and not ours; leaving it")
            abandon()
            return
        }

        foreign = false
        // The reading is 0, so nothing any of these claims says about the
        // *sleep setting* is still in place. Only that half is discharged: a
        // claim also carrying a Low Power Mode prior is still owed, and
        // deleting it here left a Mac throttled with nothing on disk saying
        // who did it — and `status.clean` reporting that all was well.
        // Through the same gate as every other discharge. A current 0 cannot
        // speak for a claim whose writer can still apply 1 — and this path was
        // the one place that deleted the record *containing* that protection,
        // which made every guard downstream of it moot.
        lowerOurUncertainty(in: &ledger, while: !liveWriters.isEmpty || writeOutstanding)
        dischargeSleepClaims(&ledger, from: removable(restorable, in: ledger, of: .sleep))

        guard let holding = holder else {
            // The hold went away while the read was out. Nothing was changed
            // and there is nothing to try again, so this must not go on the
            // retry schedule: the next pass clears our record straight away,
            // and a Mac whose user has let go waits for nothing.
            let changed = ledger != current.ledger
            current.ledger = ledger
            finish(current, saving: changed ? ledger : nil, removing: [])
            return
        }

        // Journalled before the change, never after. A crash here leaves a
        // claim for something that did not happen, and the next start reads
        // SleepDisabled, finds 0, and drops the claim. The other order leaves
        // a Mac that cannot sleep with nothing on disk saying who did it.
        var record = ledger.claims[label] ?? HelperClaim(
            holderLabel: label, boot: bootID, sessionID: holding.sessionID,
            generation: holding.generation, deadline: holding.deadline,
            leaseExpiryContinuousNs: holding.leaseExpiryNs, sleepDisabledClaimed: false
        )
        record.sleepDisabledClaimed = true
        // Down with the baseline, in the same save, before the child exists.
        markWriterOutstanding(on: &record)
        ledger.claims[label] = record
        do {
            try store.save(ledger)
        } catch {
            log.note("could not journal the claim; changing nothing: \(error)")
            abandon()
            return
        }
        claim = record
        current.ledger = ledger
        current.writes = [.writeSleepDisabled(true)]
        advanceWrites(&current)
    }

    private func restoreRead(_ current: inout Transaction, sleepDisabled: Int) {
        var ledger = current.ledger
        let restoring = classify(&ledger)
        current.ledger = ledger
        current.restoring = restoring

        // The other build took this Mac over while we were not holding it. The
        // 1 is theirs; all we do is stop claiming it.
        if otherLedgeHolds {
            guard mayDischarge(under: current) else {
                deferDischarge("the other build holds the setting")
                return
            }
            actual = .notClaimed
            finish(current, saving: ledger, removing: restoring)
            return
        }

        if sleepDisabled == 1 && !restoring.isEmpty {
            current.writes = [.writeSleepDisabled(false)]
            advanceWrites(&current)
            return
        }
        // Nothing to undo. The claim goes whether or not we were the ones who
        // undid it: it only ever said "Ledge may have changed this".
        //
        // Except while one of our own writers can still act. The 0 just read
        // is genuinely current and still proves nothing: a child that was
        // answered for and never stopped can set 1 a moment from now, and by
        // then the claim would be gone, the holder gone, and nothing left
        // that knows the Mac was ever Ledge's to put back.
        guard mayDischarge(under: current) else {
            deferDischarge("the sleep claim reads as nothing to undo")
            return
        }
        actual = .notClaimed
        finish(current, saving: ledger, removing: restoring)
    }

    // MARK: - Low Power Mode

    /// Records what Low Power Mode was before Ledge touched it, then turns it
    /// on.
    ///
    /// The prior is the whole of the safety story here, and it is written
    /// down before anything changes. Without it a restore cannot tell "Ledge
    /// turned this on" from "the user had it on already", and the two want
    /// opposite endings: one is switched off, the other is left exactly where
    /// it was found.
    private func applyLowPowerRead(_ current: inout Transaction, _ reading: LowPowerSetting) {
        var ledger = current.ledger
        _ = classify(&ledger)
        current.ledger = ledger

        if otherLedgeHolds {
            log.note("the other Ledge build holds this Mac; not touching Low Power Mode")
            abandon()
            return
        }
        guard let holding = holder, lowPowerWanted else {
            // The hold went away while the read was out. Nothing was changed,
            // so there is nothing to try again and nothing to wait for.
            finish(current, saving: nil, removing: [])
            return
        }

        // Somebody else's prior is still outstanding, which means the reading
        // just taken is not a baseline at all — it is *their* applied state.
        // Recording it as this user's original choice is how a replacement
        // daemon came to believe the user had asked for Low Power Mode on both
        // sources: it read the Mac the dead daemon had changed, journalled 3,
        // and the merge then ORed that with the real prior of 1 and left Low
        // Power Mode on for good, reporting clean.
        //
        // So that one is put back first, on its own terms, and the next pass
        // takes a baseline from a Mac nobody is holding. The same shape as the
        // sleep setting undoing a lapsed claim before taking the setting.
        let foreignPriors = lowPowerClaims(in: ledger).labels.filter { $0 != label }
        if !foreignPriors.isEmpty {
            // Unless this run has already put them back and may not remove
            // them. Redirecting into a restore that has nothing left to write
            // finishes immediately, and the next pass makes the same decision
            // about the same record — a `pmset` read on every pump, for ever,
            // while the setting the user asked for is never applied.
            //
            // The prior stays, because it is somebody else's evidence. What
            // stops is asking again without anything having changed: the
            // backoff holds this off until the owner accounts for its writer,
            // and `classify` lets the record go the moment it becomes
            // ordinary again.
            let stuck = foreignPriors.allSatisfy {
                restoredAndRetained.contains(Retained(label: $0, resource: .lowPower))
            }
            if stuck {
                log.note("waiting on another helper's Low Power Mode record before taking one")
                abandon()
                return
            }
            log.note("undoing an outstanding Low Power Mode claim before taking a baseline")
            current.kind = .restoreLowPower
            restoreLowPowerRead(&current, reading)
            return
        }

        var record = ledger.claims[label] ?? HelperClaim(
            holderLabel: label, boot: bootID, sessionID: holding.sessionID,
            generation: holding.generation, deadline: holding.deadline,
            leaseExpiryContinuousNs: holding.leaseExpiryNs, sleepDisabledClaimed: false
        )
        if record.lowPowerPrior == nil {
            // Written once and never written over. A second attempt reads a
            // Mac the first attempt may already have changed, so recording it
            // again would journal Ledge's own change as the user's choice —
            // and the restore would then put Low Power Mode back *on*.
            record.lowPowerPrior = reading.packed
        }
        // The same rule as the sleep baseline, in the save that is already
        // happening. Two privileged writes, one admission.
        markWriterOutstanding(on: &record)
        ledger.claims[label] = record

        do {
            try store.save(ledger)
        } catch {
            log.note("could not journal the Low Power Mode prior; changing nothing: \(error)")
            abandon()
            return
        }
        claim = record
        current.ledger = ledger

        let wanted = reading.turnedOn
        current.wantedLowPower = wanted
        current.writes = reading.writes(to: wanted)
        guard !current.writes.isEmpty else {
            // Already on everywhere. The prior is recorded, which is what
            // makes the end of the session put it back the way it was; there
            // is simply nothing to write.
            //
            // Fenced like every other readback. This one stamps a *fresh*
            // verification time onto the reading, so believing one taken
            // before a late writer landed does not merely cache a stale
            // answer — it undoes the invalidation this core had already made
            // for itself and then stops looking for another half minute.
            guard !wasWrittenUnder(current) else {
                log.note("Low Power Mode was written while this read was out; reading again")
                lowPowerApplied = false
                retryStep = 0
                retryAtNs = nil
                finish(current, saving: nil, removing: [])
                return
            }
            markLowPowerApplied()
            finish(current, saving: nil, removing: [])
            return
        }
        advanceWrites(&current)
    }

    /// The other build's label, when it is the one holding this Mac.
    private func liveOtherLedgeLabel(in ledger: ClaimLedger) -> String? {
        let now = clock.continuousNanoseconds
        return ledger.claims.first { name, record in
            name != label && record.isLive(inBoot: bootID, atContinuousNanoseconds: now)
        }?.key
    }

    /// Puts Low Power Mode back the way the claim says it was found.
    private func restoreLowPowerRead(_ current: inout Transaction, _ reading: LowPowerSetting) {
        var ledger = current.ledger
        _ = classify(&ledger)
        current.ledger = ledger

        // The other build took this Mac over while we were not holding it.
        // Writing our prior over theirs would end their conserve from inside
        // ours, which is the same mistake the sleep setting refuses to make a
        // few lines up. So this does not write — but what it does with the
        // record is the whole question.
        if otherLedgeHolds {
            // Through the same gate as every other discharge, first: nothing
            // goes while a writer of ours can still move the setting.
            guard mayDischarge(under: current) else {
                deferDischarge("the other build holds the Mac while Low Power Mode is owed")
                return
            }
            // And then handed over, never deleted.
            //
            // Their holding the *sleep* setting says they hold the Mac. It
            // does not say they have taken on this Low Power undo, and if
            // they have no baseline of their own then deleting ours is the
            // only record of what the user had going out of existence — after
            // which they sample Ledge's own applied state as the thing to put
            // back, and Low Power Mode never goes off again.
            //
            // So the baseline moves to whoever holds the Mac. One record
            // carries it at a time; it is only ever dropped by somebody who
            // has a baseline of their own, which is the case the whole branch
            // was written for.
            var ours = ledger
            if let mine = ours.claims[label], let prior = mine.lowPowerPrior,
               let heir = liveOtherLedgeLabel(in: ours) {
                if ours.claims[heir]?.lowPowerPrior == nil {
                    ours.claims[heir]?.lowPowerPrior = prior
                    log.note("handing the Low Power Mode baseline to \(heir)")
                }
            }
            lowerOurUncertainty(in: &ours, while: !liveWriters.isEmpty || writeOutstanding)
            clearLowPowerPriors(&ours, from: removable([label], in: ours, of: .lowPower))
            lowPowerApplied = false
            lowPowerOutstanding = false
            current.ledger = ours
            finish(current, saving: ours, removing: [])
            return
        }

        let owed = lowPowerClaims(in: ledger)
        guard let wanted = owed.prior else {
            // Nothing recorded is ours. Whatever Low Power Mode reads as now
            // is somebody's own setting, and not this daemon's to move.
            lowPowerApplied = false
            lowPowerOutstanding = false
            finish(current, saving: ledger, removing: [])
            return
        }

        current.wantedLowPower = wanted
        current.writes = reading.writes(to: wanted)
        guard !current.writes.isEmpty else {
            // The Mac is already as the claim remembers it — somebody put it
            // back, or it never moved. The record goes, because it only ever
            // said "Ledge may have changed this".
            //
            // Unless one of ours can still move it. Then this reading is a
            // description of a Mac that is about to change, and the prior is
            // the only thing that would know how to put it back.
            guard mayDischarge(under: current) else {
                deferDischarge("Low Power Mode reads as the prior already restored")
                return
            }
            lowerOurUncertainty(in: &ledger, while: !liveWriters.isEmpty || writeOutstanding)
            clearLowPowerPriors(&ledger,
                                from: removable(owed.labels, in: ledger, of: .lowPower))
            lowPowerApplied = false
            lowPowerOutstanding = false
            current.ledger = ledger
            finish(current, saving: ledger, removing: [])
            return
        }
        advanceWrites(&current)
    }

    /// Which claims record a Low Power Mode this daemon may put back, and what
    /// to put it back to.
    ///
    /// Ours whatever it says, and a lapsed one of the other build, because the
    /// app behind that one has stopped speaking and somebody has to put the
    /// setting back.
    ///
    /// A *live* claim of the other build is not filtered here, because it
    /// cannot reach here: `restoreLowPowerRead` turns back the moment
    /// `classify` reports one, and that is the single place the rule lives. A
    /// second copy of it in this function would be a second place to get it
    /// wrong and no test could tell which copy was doing the work.
    private func lowPowerClaims(in ledger: ClaimLedger) -> (labels: [String], prior: LowPowerSetting?) {
        var labels: [String] = []
        var prior: LowPowerSetting?
        for (holderLabel, record) in ledger.claims.sorted(by: { $0.key < $1.key }) {
            guard let packed = record.lowPowerPrior else { continue }
            labels.append(holderLabel)
            let recorded = LowPowerSetting.unpacked(packed)
            prior = prior.map { $0.merged(with: recorded) } ?? recorded
        }
        return (labels, prior)
    }

    /// Takes the sleep half out of a claim, and the claim too when that was
    /// all it said.
    ///
    /// A claim makes up to two promises. Discharging one of them is not
    /// discharging the claim, and the one line that forgot this — a
    /// `claims[name] = nil` on the apply path — lost an outstanding Low Power
    /// Mode prior and then reported the daemon clean. There is one of these
    /// per setting, and no path may delete a record any other way.
    private func dischargeSleepClaims(_ ledger: inout ClaimLedger, from labels: [String]) {
        for name in labels {
            guard var record = ledger.claims[name] else { continue }
            record.sleepDisabledClaimed = false
            ledger.claims[name] = record.needsRestore ? record : nil
        }
    }

    /// Takes the Low Power Mode half out of a claim, and the claim too when
    /// that was all it said.
    private func clearLowPowerPriors(_ ledger: inout ClaimLedger, from labels: [String]) {
        for name in labels {
            guard var record = ledger.claims[name] else { continue }
            record.lowPowerPrior = nil
            ledger.claims[name] = record.needsRestore ? record : nil
        }
    }

    private func afterWrite(_ current: inout Transaction, _ outcome: PmsetOutcome) {
        // The write's outcome is known here, which is where "outstanding"
        // ends. Whether its *writer* can still act is a different question
        // and `liveWriters` answers it. Leaving this up past the answer makes
        // a restore refuse to discharge the very record it has just put back.
        writeOutstanding = false
        guard outcome == .wrote else {
            log.note("pmset refused a write: \(outcome)")
            fail(current)
            return
        }
        // `pmset` exiting cleanly is not evidence. The readback is — and it
        // comes after the *last* write, not after each one, because the two
        // halves of a per-source Low Power Mode are one change.
        advanceWrites(&current)
    }

    private func afterVerify(_ current: inout Transaction, _ outcome: PmsetOutcome) {
        if current.kind.isLowPower {
            verifyLowPower(&current, outcome)
            return
        }
        guard case .read(let value) = outcome, value >= 0 else {
            log.note("could not read back SleepDisabled: \(outcome)")
            fail(current)
            return
        }
        let wanted = current.kind == .apply ? 1 : 0
        guard value == wanted else {
            log.note("SleepDisabled read back as \(value), wanted \(wanted)")
            fail(current)
            return
        }

        retryStep = 0
        retryAtNs = nil
        switch current.kind {
        case .apply:
            // Only if nothing wrote the setting while this transaction was
            // out. A readback taken before a fail-safe write landed says
            // nothing about the Mac afterwards, and caching it as `.claimed`
            // is how the repair stopped happening at all.
            if wasWrittenUnder(current) {
                log.note("the setting was written while this apply was out; not believing the readback")
                actual = .unknown
            } else {
                markClaimed()
            }
            finish(current, saving: nil, removing: [])
        default:
            // The readback said 0, and a readback is not a promise about the
            // next moment. Discharging here is the destructive half — the
            // claim goes — so it waits on every writer of ours having
            // actually stopped. Startup is finished either way: it has done
            // its looking, and refusing to finish it would wedge the daemon
            // before it ever served anybody.
            guard mayDischarge(under: current) else {
                if current.kind == .startup { startupDone = true }
                deferDischarge("the sleep setting read back as restored")
                return
            }
            actual = .notClaimed
            finish(current, saving: current.ledger, removing: current.restoring)
            if current.kind == .startup { startupDone = true }
        }
    }

    /// The Low Power Mode readback, which is the only evidence a write landed.
    private func verifyLowPower(_ current: inout Transaction, _ outcome: PmsetOutcome) {
        guard case .lowPower(let reading) = outcome else {
            log.note("could not read back Low Power Mode: \(outcome)")
            fail(current)
            return
        }
        guard let wanted = current.wantedLowPower, reading.matches(wanted) else {
            log.note("Low Power Mode read back as \(reading), wanted \(current.wantedLowPower as Any)")
            fail(current)
            return
        }

        retryStep = 0
        retryAtNs = nil
        switch current.kind {
        case .applyLowPower:
            // The prior is already on disk — it was written before the change
            // — so there is nothing to save here, only something to believe.
            //
            // Fenced like the sleep setting, and for the same reason: a
            // readback taken before some other writer of ours landed says
            // nothing about the Mac afterwards, and believing it here is a
            // Low Power Mode state nothing will look at again.
            if wasWrittenUnder(current) {
                log.note("a power setting was written while this apply was out; not believing it")
                lowPowerApplied = false
                retryStep = 0
                retryAtNs = nil
            } else {
                markLowPowerApplied()
                // Something new to undo, so "already put back" stops being
                // true — the same invalidation `markClaimed` does for the
                // sleep setting, in the path it had not been carried to.
                restoredAndRetained.remove(Retained(label: label, resource: .lowPower))
            }
            finish(current, saving: nil, removing: [])
        default:
            guard mayDischarge(under: current) else {
                deferDischarge("Low Power Mode read back as restored")
                return
            }
            var ledger = current.ledger
            lowerOurUncertainty(in: &ledger, while: !liveWriters.isEmpty || writeOutstanding)
            clearLowPowerPriors(&ledger,
                                from: removable(lowPowerClaims(in: ledger).labels,
                                                in: ledger, of: .lowPower))
            lowPowerApplied = false
            lowPowerOutstanding = false
            current.ledger = ledger
            finish(current, saving: ledger, removing: [])
        }
    }

    /// Ends a transaction, writes the ledger if it changed, and gives up the
    /// lock.
    private func finish(_ current: Transaction, saving ledger: ClaimLedger?, removing labels: [String]) {
        writeOutstanding = false
        var written = ledger
        // Whatever this helper knows about its own writers goes down with
        // whatever else is being written, so the other build never sees a
        // claim without the uncertainty attached to it.
        let unresolved = !liveWriters.isEmpty || writeOutstanding
        if var updated = written, lowerOurUncertainty(in: &updated, while: unresolved) {
            written = updated
        }
        let removing = removable(labels, in: written ?? current.ledger, of: .sleep)
        if !removing.isEmpty {
            var updated = written ?? current.ledger
            dischargeSleepClaims(&updated, from: removing)
            written = updated
        }
        if let written {
            do {
                try store.save(written)
                claim = written.claims[label]
                noteRetirements(in: written)
            } catch {
                // The change itself is done and confirmed. The record of it is
                // what failed, so the claim stays and the next pass clears it.
                log.note("could not write the claim store: \(error)")
                scheduleRetry()
            }
        }
        transaction = nil
        store.unlock()
    }

    /// Ends a transaction that decided not to act. Nothing is written, and the
    /// next attempt waits for the backoff.
    private func abandon() {
        writeOutstanding = false
        transaction = nil
        store.unlock()
        scheduleRetry()
    }

    /// Ends a transaction that `pmset` or a readback defeated.
    private func fail(_ current: Transaction) {
        // The write's outcome is known, whichever way it went. Whether its
        // *writer* can still act is a separate question, and `liveWriters`
        // answers it — a failed reply over a child that is still alive keeps
        // the uncertainty up through that set, not through this one.
        writeOutstanding = false
        switch current.kind {
        case .apply:
            // The write may or may not have landed. The claim was journalled
            // before it, and says it might have, which is what makes it safe
            // not to know.
            actual = .unknown
        case .applyLowPower, .restoreLowPower:
            // Same rule, one setting along. The prior was journalled before
            // the write, so the claim already says Low Power Mode may have
            // moved — and it stays saying so until a readback agrees it is
            // back. `lowPowerApplied` is deliberately left alone: a failed
            // apply has not been confirmed and must be tried again, and a
            // failed restore has not undone anything.
            if current.kind == .applyLowPower { lowPowerApplied = false }
        case .startup, .restore:
            actual = .restoreFailed(attempt: retryStep + 1)
            // The claims stay in the store, so the daemon is not clean and
            // will not be unregistered. It keeps trying for as long as it runs,
            // and it does not idle-exit while anything is outstanding.
            if current.kind == .startup { startupDone = true }
        }
        transaction = nil
        store.unlock()
        scheduleRetry()
    }

    /// Takes a claim of ours out of the store when there is nothing privileged
    /// behind it.
    private func clearClaimRecord() {
        guard store.tryLock() else {
            noteLockBusy()
            return
        }
        defer { store.unlock() }
        var ledger = loadLedger()
        ledger.claims[label] = nil
        do {
            try store.save(ledger)
            claim = nil
            lockBackoffStep = 0
            lockRetryAtNs = nil
        } catch {
            log.note("could not clear the claim: \(error)")
            scheduleRetry()
        }
    }

    // MARK: - Backoff and timing

    private func noteLockBusy() {
        let step = min(lockBackoffStep, HelperLimits.lockBackoffNs.count - 1)
        lockRetryAtNs = clock.continuousNanoseconds + HelperLimits.lockBackoffNs[step]
        lockBackoffStep = min(lockBackoffStep + 1, HelperLimits.lockBackoffNs.count - 1)
    }

    private func scheduleRetry() {
        let step = min(retryStep, HelperLimits.retryBackoffNs.count - 1)
        retryAtNs = clock.continuousNanoseconds + HelperLimits.retryBackoffNs[step]
        retryStep = min(retryStep + 1, HelperLimits.retryBackoffNs.count - 1)
    }

    /// Works out the one instant the core next has anything to do at.
    private func arm() {
        publishBound()
        let now = clock.continuousNanoseconds
        var delays: [UInt64] = []

        if let current = holder {
            delays.append(current.leaseExpiryNs > now ? current.leaseExpiryNs - now : 0)
            // A wake for the next look at the setting — but only when there
            // is a future appointment to keep and nothing else already owns
            // the progress. A deadline that is already past asked for a wake
            // of zero, the tick could not finish the child that was out, and
            // it asked again: a root daemon spinning on its own control
            // queue. A failed read's backoff lost to the same expired zero.
            if transaction == nil, retryAtNs == nil, actual == .claimed {
                let due = lastVerifiedNs &+ Self.verifyIntervalNs
                if due > now { delays.append(due - now) }
            }
            if transaction == nil, retryAtNs == nil, lowPowerApplied {
                let due = lastLowPowerVerifiedNs &+ Self.verifyIntervalNs
                if due > now { delays.append(due - now) }
            }
            if let deadline = current.deadline {
                delays.append(HelperCore.nanoseconds(max(0, deadline.timeIntervalSince(clock.now))))
            }
        }
        // A retry or another try at the lock means nothing while a child is
        // out: the next thing to happen is its completion, which is an event
        // of its own. And with nothing wanted, nothing claimed and nobody
        // waiting, there is nothing to come back for at all.
        let unfinished = !pending.isEmpty || desiredIsClaimed || claim != nil
            || !startupDone || lowPowerOutstanding || desiredLowPower
        if transaction == nil && unfinished {
            if let due = lockRetryAtNs { delays.append(due > now ? due - now : 0) }
            if let due = retryAtNs { delays.append(due > now ? due - now : 0) }
        }
        timer.wake(after: delays.min())
    }

    /// Tells the watchdog the instant this Mac was promised it could sleep.
    ///
    /// Taken from the *persisted* claim before the in-memory holder, and that
    /// order is the whole point: a renewal whose save never landed extended a
    /// lease nobody can see, so the expiry the file holds is the one the
    /// daemon may fairly be judged against. A stale bound here is a correct
    /// bound.
    private func publishBound() {
        guard let watchdog else { return }
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: claim?.leaseExpiryContinuousNs ?? holder?.leaseExpiryNs,
            claimed: claim?.sleepDisabledClaimed == true
        ))
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64((seconds * 1_000_000_000).rounded())
    }
}
