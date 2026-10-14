import Foundation

/// The fail-safe behind the lease, and — stated plainly, because the first
/// version of this comment was not — **not a guaranteed completed restore at
/// any fixed instant.**
///
/// What it actually promises: once the persisted lease has lapsed and a grace
/// has passed, a restore is *attempted* without waiting for the control queue,
/// and it goes on being attempted until a readback says SleepDisabled is 0.
/// The first attempt begins within roughly `grace` plus one timer period plus
/// its leeway of the lease lapsing. How long it then takes is `pmset`'s
/// business, and a refused one is retried. There is no instant at which the
/// Mac is guaranteed to be sleeping again, and calling one out would be
/// inventing a number nothing enforces.
///
/// ## Why it cannot live on the control queue
///
/// `HelperCore` is one serial queue by design, and that is right: "no two
/// things happen between this decision and that write" is the property the
/// lease rests on. But it means every event — a lease expiry, a release, a
/// SIGTERM — waits behind whatever is already running on it, and a claim-store
/// save is synchronous file I/O with an `F_FULLFSYNC` at the end of it. A save
/// that does not come back takes the expiry with it. A probe did exactly that:
/// blocked one renewal's save, advanced the monotonic clock ninety-one seconds,
/// and the queued expiry could not run. Sleep stayed disabled. The bound was
/// not a bound.
///
/// Moving the I/O to a worker does not fix it either, if the restore still has
/// to wait for that worker. The only thing that establishes a bound is
/// something that can act **without** the thing that might be stuck.
///
/// ## What it does, and what it deliberately does not do
///
/// It holds one small fact — the last *persisted* lease expiry, and whether
/// Ledge believes it set `disablesleep` — published by the core under a lock
/// that is never held across anything. On its own queue it asks one question:
/// is this Mac past the instant it was promised it could sleep? If it is, it
/// writes `disablesleep 0` and says so loudly.
///
/// It does not take the claim-store lock, does not clear the claim, and does
/// not pretend to have finished anything. That is safe, and for one specific
/// reason: a claim has only ever meant *"Ledge may have changed this"*, never
/// "this is in place". Leaving it standing is what makes the core — or the
/// next start, or the other build's daemon — read the setting back and sort it
/// out properly. Every write this makes is in the same direction, towards the
/// Mac being allowed to sleep, so repeating one costs nothing and racing one
/// changes nothing.
///
/// The stale bound is a feature. If a renewal's save never lands, the
/// extension it carried was never persisted, and the expiry this still holds
/// is the last one that *was* — which is exactly the instant the daemon is
/// allowed to be judged against.
public final class LeaseWatchdog: @unchecked Sendable {

    /// How long past the lease the orderly path is given before this steps in.
    ///
    /// The ordinary restore is the one that should happen: it reads the
    /// setting, writes it, reads it back and clears the record. A fail-safe
    /// that beat it to the punch every time would turn the exception into the
    /// rule and nothing would ever reconcile the claim.
    public static let grace: TimeInterval = 10

    /// How long before an *unconfirmed* attempt is made again.
    ///
    /// Short, because an attempt nobody has read back is not a restore and the
    /// Mac is still held awake while it is outstanding.
    public static let retryInterval: TimeInterval = 15

    /// How long before a confirmed-but-still-claimed state is acted on again.
    ///
    /// Long, because the setting has been read back as 0: something else has
    /// to have put it back for there to be anything to do, and that something
    /// is a live hold which this must not be racing.
    public static let repeatInterval: TimeInterval = 60

    /// Operation ids start here so one of these can never be mistaken for the
    /// core's, whichever runner they share.
    public static let opIDBase = 1_000_000

    /// What the core last managed to persist.
    public struct Bound: Equatable, Sendable {
        /// Continuous time past which this Mac must be allowed to sleep. Nil
        /// when nothing of Ledge's is outstanding.
        public var expiryContinuousNs: UInt64?
        /// Ledge wrote, or was about to write, `disablesleep 1`.
        public var claimed: Bool

        public init(expiryContinuousNs: UInt64?, claimed: Bool) {
            self.expiryContinuousNs = expiryContinuousNs
            self.claimed = claimed
        }

        public static let nothing = Bound(expiryContinuousNs: nil, claimed: false)
    }

    /// How long a reservation may stand with nothing coming back.
    ///
    /// A write that never answers would otherwise hold the reservation for
    /// ever and the fail-safe would stop being one. Retiring it does **not**
    /// mean the write cannot still land: the activity counter was bumped when
    /// it started, and the core goes on distrusting its cached state until it
    /// has read the setting again.
    public static let reservationTimeout: TimeInterval = 120

    /// What the fail-safe is doing. One operation at a time, reserved from the
    /// moment a write is started and held through its readback.
    ///
    /// `verifying` alone was not a reservation: it was set when a write
    /// *answered*, so a write with no answer left the fail-safe idle and every
    /// interval enqueued another. The runner serialises execution; its queue
    /// is unbounded, and a backlog of old zero writes arriving after a newer
    /// hold turns the accepted early-sleep hazard into a repeated one.
    private enum Stage: Equatable {
        case idle
        case writing(Int)
        case reading(Int)
    }

    private let clock: any HelperClock
    private let pmset: any PmsetRunner
    private let log: any HelperLog

    private let lock = NSLock()
    private var bound: Bound = .nothing
    private var firedAtNs: UInt64?
    /// The instant another attempt becomes eligible. Always a time, never an
    /// absence standing in for "now".
    private var nextAttemptNs: UInt64?
    private var stage: Stage = .idle
    private var stageSinceNs: UInt64 = 0
    /// Bumped by every publication from the core. A seed read that started
    /// before one of these is answering about a Mac the core has since spoken
    /// authoritatively about.
    private var publications = 0
    /// Writers that were admitted and have not yet proved they cannot run.
    ///
    /// This is admission control, not a memory of replies. Nothing here is
    /// ever *evicted*: an evicted id is a privileged write that can still
    /// reach the hardware with nothing left to notice when it does, which is
    /// the stale-cache bug all over again. When the set is full the fail-safe
    /// stops admitting work instead — refusing to start another write is the
    /// only honest answer when the ones already out cannot be accounted for.
    private var unresolvedWriters: Set<Int> = []

    /// How many unresolved writers may exist at once.
    public static let writerLimit = 8
    /// The boot the claim file has to belong to for its expiry to mean
    /// anything.
    private let boot: String?
    private var nextOpID = LeaseWatchdog.opIDBase
    private var firings = 0
    /// Bumped when a write is started **and** again when it finishes.
    ///
    /// Two events, because the core has to distrust its cached state at both:
    /// at the start, because a write is now in flight and may land at any
    /// moment; and at the finish, because that is when it landed and the
    /// hardware moved. A counter that only counted starts missed the case
    /// this whole hazard is about — the child delayed past a new hold.
    private var activity = 0
    /// A write of ours has been read back as 0. Until then every attempt is
    /// just an attempt.
    private var confirmed = false

    /// - Parameter boot: `kern.bootsessionuuid`, so a claim written in an
    ///   earlier boot is never waited out against its old continuous-time
    ///   number. Continuous time restarts at boot, and a Mac that had been up
    ///   for days leaves expiries days above the new clock.
    public init(clock: any HelperClock,
                pmset: any PmsetRunner,
                boot: String? = nil,
                log: any HelperLog = SilentHelperLog()) {
        self.clock = clock
        self.pmset = pmset
        self.boot = boot
        self.log = log
    }

    /// Told by the core whenever what it has persisted changes.
    ///
    /// One struct under one lock, and nothing else — so it is safe to call
    /// from the control queue without becoming another way for that queue to
    /// be the problem.
    public func publish(_ bound: Bound) {
        lock.withLock {
            publications += 1
            if self.bound.expiryContinuousNs != bound.expiryContinuousNs {
                firedAtNs = nil
                // A new lease is a deliberate reset of eligibility.
                nextAttemptNs = nil
                confirmed = false
            }
            if !bound.claimed { confirmed = false }
            self.bound = bound
        }
    }

    /// Seeds the bound from the claim file, without the control queue and
    /// without the store lock.
    ///
    /// Until the core has run far enough to publish, this has nothing to
    /// enforce — and "far enough" includes the one `load()` that may be the
    /// very thing that is stuck. A daemon starting with an existing claim and
    /// a disk that will not answer had no bound at all. The read is lockless
    /// on purpose: the store replaces its file with `rename`, so a reader sees
    /// one whole version or the other, and a seed that waited for the lock
    /// would be waiting on exactly what it exists to survive.
    ///
    /// Only ever widens: a seed never overwrites something the core has said.
    public func seed(_ read: () -> HelperClaim?) {
        // Captured across the read. The checks used to be on the bound's
        // *value*, and `.nothing` is both the starting value and what the core
        // publishes when it has authoritatively discharged everything — so a
        // seed held open across that publication passed its own second check
        // and reinstalled a claim the core had just cleared.
        let before = lock.withLock { publications }
        guard lock.withLock({ bound.expiryContinuousNs == nil && !bound.claimed }) else { return }
        guard let claim = read(), claim.sleepDisabledClaimed else { return }

        // A claim from another boot has no live lease in this one, and its
        // continuous-time expiry is a number from a clock that no longer
        // exists. Zero makes it overdue immediately, which is correct: nothing
        // in this boot is relying on it.
        let expiry: UInt64 = (boot != nil && claim.boot == boot) ? claim.leaseExpiryContinuousNs : 0
        if expiry == 0 {
            log.note("lease watchdog: seeding a claim from an earlier boot as already overdue")
        }
        lock.withLock {
            guard publications == before else {
                log.note("lease watchdog: the control queue spoke first; the seed is stale")
                return
            }
            guard bound.expiryContinuousNs == nil && !bound.claimed else { return }
            bound = Bound(expiryContinuousNs: expiry, claimed: true)
        }
        log.note("lease watchdog: seeded from a claim the control queue has not read yet")
    }

    /// What it is currently promising, for a status line or a test.
    public var currentBound: Bound { lock.withLock { bound } }
    public var firingCount: Int { lock.withLock { firings } }

    /// How many times a fail-safe write has been started or has finished.
    ///
    /// What the core watches. Any change means the setting may have moved
    /// underneath it, and whatever it believed about SleepDisabled is an
    /// opinion about a Mac that has since been written to by something the
    /// claim store cannot reconcile.
    public var writeActivity: Int { lock.withLock { activity } }

    /// Whether this Mac is past the instant it was promised it could sleep.
    ///
    /// Pure, given the clock: the whole decision is one comparison, and a
    /// decision nobody can check by hand is a decision nobody has checked.
    public func isOverdue(at now: UInt64) -> Bool {
        lock.withLock { Self.isOverdue(bound, at: now) }
    }

    static func isOverdue(_ bound: Bound, at now: UInt64) -> Bool {
        guard bound.claimed, let expiry = bound.expiryContinuousNs else { return false }
        let (deadline, overflowed) = expiry.addingReportingOverflow(
            UInt64(grace * 1_000_000_000)
        )
        guard !overflowed else { return false }
        return now >= deadline
    }

    /// Runs on the watchdog's own queue. Never touches the core.
    ///
    /// - Returns: whether it acted, which is the only thing a test can see
    ///   and the only thing a log line needs.
    @discardableResult
    public func check() -> Bool {
        let now = clock.continuousNanoseconds
        let act: Int? = lock.withLock {
            guard Self.isOverdue(bound, at: now) else { return nil }

            // One operation at a time, reserved here — at admission — and
            // held until its readback answers. Anything less is an unbounded
            // queue of zero writes, each of which can land after a newer hold.
            if stage != .idle {
                guard now >= stageSinceNs &+ UInt64(Self.reservationTimeout * 1_000_000_000)
                else { return nil }
                // Retired, not forgiven: the activity counter was bumped when
                // that write started, and the core goes on distrusting its
                // cached state until it has read the setting again. Giving up
                // on the *reply* is not proof the writer cannot still run, so
                // the id stays in the unresolved set and counts against
                // admission until something terminal arrives for it.
                log.note("lease watchdog: an operation never answered; retiring the reservation")
                if case .writing(let id) = stage { unresolvedWriters.insert(id) }
                stage = .idle
            }

            // Nothing new while the writes already out cannot be accounted
            // for. Admitting another would be adding a privileged write to a
            // pile nobody can bound, and every one of them can still land
            // after a newer hold.
            guard unresolvedWriters.count < Self.writerLimit else {
                log.note("lease watchdog: too many writes are unaccounted for to start another")
                return nil
            }

            // The interval is enforced against a real timestamp. Deleting the
            // timestamp to mean "eligible now" meant a persistent failure was
            // retried on every five-second check rather than at the interval
            // this type advertises.
            if let nextAttemptNs, now < nextAttemptNs { return nil }
            firedAtNs = now
            nextAttemptNs = now &+ UInt64((confirmed ? Self.repeatInterval
                                                     : Self.retryInterval) * 1_000_000_000)
            firings += 1
            activity += 1
            let id = nextOpID
            nextOpID += 1
            stage = .writing(id)
            stageSinceNs = now
            return id
        }
        guard let id = act else { return false }

        log.note("lease watchdog: the lease lapsed and SleepDisabled is still set. Attempting a restore without waiting for the control queue.")
        pmset.start(.writeSleepDisabled(false), opID: id)
        return true
    }

    /// One of its own children has finished.
    ///
    /// A write that exits cleanly is not a restore; only the readback is. An
    /// attempt is therefore two children, and the second one is what turns
    /// `firings` into something that has actually happened.
    public func childFinished(opID: Int, outcome: PmsetOutcome) {
        let next: PmsetCommand? = lock.withLock {
            switch stage {
            case .reading(let id) where id == opID:
                stage = .idle
                stageSinceNs = clock.continuousNanoseconds
                if case .read(let value) = outcome, value == 0 {
                    confirmed = true
                    // Confirmed, so the long cadence applies from here. The
                    // eligibility fixed at fire time assumed this would not be
                    // confirmed, and leaving it there would look again in
                    // fifteen seconds over a restore that has been read back.
                    nextAttemptNs = clock.continuousNanoseconds
                        &+ UInt64(Self.repeatInterval * 1_000_000_000)
                    return nil
                }
                log.note("lease watchdog: the restore did not read back as 0; it will be tried again")
                nextAttemptNs = clock.continuousNanoseconds
                    &+ UInt64(Self.retryInterval * 1_000_000_000)
                return nil

            case .writing(let id) where id == opID:
                // The write has finished, whichever way. This is the moment
                // the hardware may have moved, and the moment the core has to
                // stop believing whatever it believed.
                activity += 1
                guard outcome == .wrote else {
                    log.note("lease watchdog: pmset refused the fail-safe restore")
                    stage = .idle
                    stageSinceNs = clock.continuousNanoseconds
                    nextAttemptNs = clock.continuousNanoseconds
                        &+ UInt64(Self.retryInterval * 1_000_000_000)
                    return nil
                }
                stage = .reading(id)
                stageSinceNs = clock.continuousNanoseconds
                return .readSleepDisabled

            default:
                // An answer for an operation this is no longer waiting on —
                // a retired reservation finally replying, or a duplicate.
                // Letting it overwrite the current one would misread a write
                // as a readback.
                if unresolvedWriters.remove(opID) != nil {
                    // Terminal, and that is all that is known. `.failed`
                    // covers a timeout and a kill as well as a refusal, and a
                    // write can have applied 0 before any of those — so only
                    // an outcome that *is* a reading can promise nothing was
                    // written. Everything else invalidates.
                    if !outcome.isReading {
                        activity += 1
                        confirmed = false
                        log.note("lease watchdog: a writer nobody was waiting for finished")
                    }
                    return nil
                }
                log.note("lease watchdog: an answer arrived for an operation nobody is waiting on")
                return nil
            }
        }
        guard let next else { return }
        pmset.start(next, opID: opID)
    }

    /// A write of this watchdog's is about to be answered for while its
    /// child can still act.
    ///
    /// It counts against admission from here, exactly as a reservation that
    /// never answered does — the reply told us nothing about the writer, so
    /// the writer is still one of the unaccounted-for ones. `writerSettled`
    /// is what lets it go.
    public func noticeLiveWriter(opID: Int) {
        lock.withLock {
            guard unresolvedWriters.insert(opID).inserted else { return }
            log.note("lease watchdog: a write was answered for while its writer can still act")
        }
    }

    /// A write of this watchdog's that it had already answered for has
    /// finally finished.
    ///
    /// `childFinished` is the *reply*, and a reply is not the end of a
    /// writer: `run` answers `.failed` when a child's pipes time out or when
    /// the bounded collection poll gives up, and the child can still be alive
    /// with the write ahead of it. The reply retires the stage and bumps the
    /// activity counter once — and then a newer hold's readback, taken after
    /// that bump, passes the fence with a reading this writer is about to
    /// invalidate.
    ///
    /// So the finish gets its own bump. Nothing is recalled: the write was
    /// sent and cannot be unsent. What changes is that a reading taken in the
    /// gap stops being believed, and `confirmed` goes with it — a restore
    /// read back as 0 before this landed is not a restore any more.
    public func writerSettled(opID: Int) {
        lock.withLock {
            activity += 1
            confirmed = false
            // Resolved at last, whatever it did. It stops counting against
            // admission, which is the half the registry already handled.
            unresolvedWriters.remove(opID)
            // And looked at again soon rather than at the confirmed cadence.
            nextAttemptNs = clock.continuousNanoseconds
                &+ UInt64(Self.retryInterval * 1_000_000_000)
            log.note("lease watchdog: a write it had given up on finished; nothing cached stands")
        }
    }

    /// Whether a write of this watchdog's has been read back as 0.
    public var hasConfirmedRestore: Bool { lock.withLock { confirmed } }

    /// Whether an operation is reserved. For a test, and for a log line.
    public var isBusy: Bool { lock.withLock { stage != .idle } }

    /// How many admitted writes have not yet proved they cannot run.
    public var unresolvedWriterCount: Int { lock.withLock { unresolvedWriters.count } }
}
