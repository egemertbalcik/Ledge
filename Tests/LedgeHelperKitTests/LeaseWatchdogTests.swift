import Foundation
import Testing

@testable import LedgeHelperKit

/// The ninety-second promise, and the thing that keeps it when the control
/// queue cannot.
///
/// `HelperCore` is one serial queue, and a claim-store save is synchronous
/// file I/O ending in an `F_FULLFSYNC`. A save that does not come back takes
/// the lease expiry with it — the event is queued behind it and simply never
/// runs. An independent review blocked one renewal's save, advanced the
/// monotonic clock ninety-one seconds, and watched sleep stay disabled with
/// the expiry never processed. The bound was not a bound.
@Suite("The lease bound, when the control queue is stuck")
struct LeaseWatchdogTests {

    /// A store whose save can be held open, as a disk that has stopped
    /// answering holds one open.
    private final class GatedStore: ClaimStore, @unchecked Sendable {
        let file: ClaimFile
        let owner: String
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var blocking = false
        private(set) var blockedSaves = 0

        init(file: ClaimFile, owner: String) {
            self.file = file
            self.owner = owner
        }

        /// The next save does not return until it is let go.
        func blockNextSave() { lock.withLock { blocking = true } }
        func letSaveFinish() { gate.signal() }

        /// Somebody else taking the lock the instant this store lets go of it.
        ///
        /// The only seam a cross-process window has in a unit test. Another
        /// helper is a separate process with its own schedule: it does not
        /// wait for this core's next pump, it waits for the file lock, and
        /// the moment that is free it is entitled to act. Running the
        /// observer exactly there models the permitted interleaving without
        /// reaching into a store somebody else still owns.
        var onUnlock: (() -> Void)?

        func unlock() {
            file.lockedBy = nil
            let observer = onUnlock
            onUnlock = nil
            observer?()
        }

        func tryLock() -> Bool {
            guard file.lockedBy == nil else { return false }
            file.lockedBy = owner
            return true
        }

        func load() throws -> ClaimLedger { file.ledger ?? .empty }

        func save(_ ledger: ClaimLedger) throws {
            let hold = lock.withLock { () -> Bool in
                guard blocking else { return false }
                blocking = false
                blockedSaves += 1
                return true
            }
            if hold { gate.wait() }
            file.ledger = ledger
            file.saves += 1
        }

        func moveAside() throws {
            file.setAside.append(file.ledger)
            file.ledger = nil
        }
    }

    private func daemon(_ clock: TestClock, _ store: GatedStore, _ mac: FakeMac,
                        _ watchdog: LeaseWatchdog) -> (HelperCore, TestPmset) {
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog(), watchdog: watchdog)
        return (core, pmset)
    }

    /// Answers whatever the core has started, so the fake Mac keeps up.
    private func drain(_ core: HelperCore, _ pmset: TestPmset, _ mac: FakeMac) {
        var guardRail = 0
        while pmset.answered < pmset.started.count {
            guardRail += 1
            if guardRail > 40 { return }
            let next = pmset.started[pmset.answered]
            pmset.answered += 1
            switch next.command {
            case .readSleepDisabled:
                core.childExited(opID: next.opID, outcome: .read(mac.sleepDisabled))
            case .writeSleepDisabled(let on):
                mac.sleepDisabled = on ? 1 : 0
                core.childExited(opID: next.opID, outcome: .wrote)
            default:
                core.childExited(opID: next.opID, outcome: .failed("not in this test"))
            }
        }
    }

    // MARK: - The decision

    @Test("Nothing claimed is never overdue, however long it has been")
    func nothingClaimed() {
        #expect(!LeaseWatchdog.isOverdue(.nothing, at: .max / 2))
        #expect(!LeaseWatchdog.isOverdue(
            LeaseWatchdog.Bound(expiryContinuousNs: 1, claimed: false), at: .max / 2))
    }

    @Test("A claim whose lease has not lapsed is not overdue")
    func liveLease() {
        let bound = LeaseWatchdog.Bound(expiryContinuousNs: 100_000_000_000, claimed: true)
        #expect(!LeaseWatchdog.isOverdue(bound, at: 99_000_000_000))
        #expect(!LeaseWatchdog.isOverdue(bound, at: 100_000_000_000))
    }

    /// The grace is there so the ordinary restore is the one that happens.
    /// A watchdog that beat it every time would turn the exception into the
    /// rule, and nothing would ever read the setting back.
    @Test("The grace is given before it steps in, and then it steps in")
    func graceThenAction() {
        let expiry: UInt64 = 100_000_000_000
        let bound = LeaseWatchdog.Bound(expiryContinuousNs: expiry, claimed: true)
        let grace = UInt64(LeaseWatchdog.grace * 1_000_000_000)

        #expect(!LeaseWatchdog.isOverdue(bound, at: expiry + grace - 1))
        #expect(LeaseWatchdog.isOverdue(bound, at: expiry + grace))
    }

    @Test("The grace leaves room for the ordinary restore without being a wait")
    func graceIsProportionate() {
        #expect(LeaseWatchdog.grace > 0, "no margin means the fail-safe races the restore")
        #expect(LeaseWatchdog.grace <= 30, "the fail-safe would be most of a second lease away")
        #expect(LeaseWatchdog.retryInterval < LeaseWatchdog.repeatInterval,
                "an unconfirmed attempt is retried no sooner than a confirmed one")
    }

    /// What the fail-safe actually promises, end to end: not that the Mac is
    /// asleep at some instant, but that it goes on attempting until a readback
    /// says SleepDisabled is 0. Asserting that a command was *issued* — which
    /// is what this used to do — proves none of that.
    @Test("It keeps attempting until a readback says the setting is back")
    func attemptsUntilConfirmed() {
        let clock = TestClock()
        let mac = FakeMac()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, log: TestLog())
        pmset.report(to: { opID, outcome in watchdog.childFinished(opID: opID, outcome: outcome) })
        mac.sleepDisabled = 1
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)

        // First attempt: pmset refuses outright.
        #expect(watchdog.check())
        pmset.answerNext(.failed("refused"))
        #expect(mac.sleepDisabled == 1)
        #expect(!watchdog.hasConfirmedRestore)

        // Second: the write exits cleanly and changes nothing, so the
        // readback disagrees and it is still not a restore.
        clock.advance(LeaseWatchdog.retryInterval)
        #expect(watchdog.check(), "a refused attempt was never tried again")
        #expect(pmset.answerNext(.wrote) == .writeSleepDisabled(false))
        #expect(pmset.answerNext(.read(1)) == .readSleepDisabled,
                "the fail-safe believed a write it had not read back")
        #expect(!watchdog.hasConfirmedRestore)

        // Third: it lands, and the readback agrees.
        clock.advance(LeaseWatchdog.retryInterval)
        #expect(watchdog.check())
        pmset.answerNext(.wrote)
        mac.sleepDisabled = 0
        pmset.answerNext(.read(0))
        #expect(watchdog.hasConfirmedRestore, "a confirmed restore was not believed")

        // And then it stops saying it.
        clock.advance(LeaseWatchdog.retryInterval)
        #expect(!watchdog.check(), "it went on writing over a restore it had confirmed")
    }

    /// A write with its readback still outstanding is not a reason to start
    /// another one. Two unreconciled writers is the whole hazard here.
    @Test("It starts nothing while a readback is still out")
    func noSecondWriteWhileVerifying() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, log: TestLog())
        pmset.report(to: { opID, outcome in watchdog.childFinished(opID: opID, outcome: outcome) })
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)

        #expect(watchdog.check())
        pmset.answerNext(.wrote)          // the readback is now outstanding
        clock.advance(LeaseWatchdog.repeatInterval)
        #expect(!watchdog.check(), "a second write was started on top of an unread one")
    }

    /// Until the core has published, the fail-safe has nothing to enforce —
    /// and the one `load()` that would let it publish is exactly what may be
    /// stuck. A daemon starting with an existing claim and a disk that will
    /// not answer had no bound at all.
    @Test("A claim the control queue has not read yet is still enforced")
    func seededFromTheFile() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, log: TestLog())

        clock.advance(101)
        #expect(!watchdog.check(), "it acted before it had been told anything")

        // The lockless seed, as the daemon does it on its own queue.
        watchdog.seed {
            claim(label: "com.egemert.ledge.keepawake", leaseExpiryNs: 1)
        }
        #expect(watchdog.currentBound.claimed, "an existing claim was not picked up")
        #expect(watchdog.check(), "a claim nobody had read was left unenforced")
    }

    @Test("A seed never overwrites what the core has already said")
    func seedDoesNotOverwrite() {
        let clock = TestClock()
        let watchdog = LeaseWatchdog(clock: clock, pmset: TestPmset(), boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(expiryContinuousNs: 500, claimed: true))
        watchdog.seed { claim(label: "x", boot: "b", leaseExpiryNs: 999) }
        #expect(watchdog.currentBound.expiryContinuousNs == 500)
    }

    /// The case the value check could not see. `.nothing` is both the
    /// starting bound and what the core publishes when it has authoritatively
    /// discharged everything, so a seed held open across that publication
    /// passed its own second check and reinstalled a claim that was already
    /// gone — and could then write zero over a setting somebody else had
    /// taken.
    @Test("A seed answering after the core has cleared everything is dropped")
    func lateSeedAfterAuthoritativeClear() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())

        watchdog.seed {
            // The core finishes its restore and says so, while this read is
            // still out.
            watchdog.publish(.nothing)
            return claim(label: "x", boot: "b", leaseExpiryNs: 1)
        }

        #expect(!watchdog.currentBound.claimed,
                "a seed reinstalled a claim the core had discharged")
        clock.advance(10_000)
        #expect(!watchdog.check(), "the stale seed went on to write the setting")
    }

    /// Continuous time restarts at boot. A claim written on a Mac that had
    /// been up for days carries an expiry days above the new clock, and
    /// waiting it out means never acting at all.
    @Test("A claim from an earlier boot is overdue the moment it is seeded")
    func previousBootSeedIsOverdue() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "this-boot", log: TestLog())

        watchdog.seed {
            claim(label: "x", boot: "an-earlier-boot", leaseExpiryNs: 604_800_000_000_000)
        }

        #expect(watchdog.currentBound.claimed)
        #expect(watchdog.check(),
                "a privileged obligation from a dead boot waited out its old clock")
    }

    @Test("A claim from this boot keeps its own expiry")
    func thisBootSeedKeepsItsExpiry() {
        let clock = TestClock()
        let watchdog = LeaseWatchdog(clock: clock, pmset: TestPmset(), boot: "b", log: TestLog())
        let expiry = clock.continuousNanoseconds + 90_000_000_000
        watchdog.seed { claim(label: "x", boot: "b", leaseExpiryNs: expiry) }

        #expect(watchdog.currentBound.expiryContinuousNs == expiry)
        #expect(!watchdog.check(), "a live lease was treated as overdue")
    }

    /// `verifying` was set when a write *answered*, so a write with no answer
    /// left the fail-safe idle and every interval enqueued another. The runner
    /// serialises execution; its queue does not bound admission, and a backlog
    /// of old zero writes arriving after a newer hold turns the accepted
    /// early-sleep hazard into a repeated one.
    @Test("An unanswered write reserves the fail-safe rather than queuing another")
    func unansweredWriteHoldsTheReservation() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)

        #expect(watchdog.check())
        #expect(watchdog.isBusy)
        for _ in 0..<5 {
            clock.advance(LeaseWatchdog.retryInterval + 1)
            #expect(!watchdog.check(), "a second write was enqueued behind one with no answer")
        }
        #expect(pmset.commands.count == 1)
    }

    /// Retiring the *reply* is not proof the writer cannot still run. Its
    /// eventual completion is evidence that the setting was written, and
    /// dropping it on the floor let a stale verification stand: the core's
    /// epoch never moved, so the reading it was holding stayed trustworthy.
    @Test("A retired writer that finishes after all still counts as activity")
    func retiredWriterStillCounts() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)

        #expect(watchdog.check())
        let abandoned = pmset.started[0].opID
        clock.advance(LeaseWatchdog.reservationTimeout + 1)
        #expect(watchdog.check(), "the fail-safe wedged on an operation that never answered")
        let before = watchdog.writeActivity

        // The one that was given up on writes the setting anyway.
        watchdog.childFinished(opID: abandoned, outcome: .wrote)

        #expect(watchdog.writeActivity > before,
                "a write that actually landed was invisible to everything watching")
    }

    /// But it still may not be mistaken for the operation that replaced it.
    @Test("A retired writer's finish does not confirm the current operation")
    func retiredWriterDoesNotConfirm() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)
        #expect(watchdog.check())
        let abandoned = pmset.started[0].opID
        clock.advance(LeaseWatchdog.reservationTimeout + 1)
        #expect(watchdog.check())

        watchdog.childFinished(opID: abandoned, outcome: .wrote)
        #expect(!watchdog.hasConfirmedRestore)
        // And the current one is still waiting for its own write.
        #expect(watchdog.isBusy)
    }

    /// Admission is bounded, not merely the memory of replies. An evicted id
    /// is a privileged write that can still reach the hardware with nothing
    /// left to notice when it does — so nothing is ever evicted, and the
    /// fail-safe stops admitting work instead.
    @Test("Writers that cannot be accounted for stop new ones being started")
    func unresolvedWritersBoundAdmission() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)

        // Every attempt is admitted and then abandoned, with nothing ever
        // answering, until it stops admitting them.
        var admitted = 0
        for _ in 0..<(LeaseWatchdog.writerLimit * 3) {
            if watchdog.check() { admitted += 1 }
            clock.advance(LeaseWatchdog.reservationTimeout + 1)
        }

        #expect(admitted == LeaseWatchdog.writerLimit,
                "the number of unaccounted-for writes was not what bounded admission")
        #expect(watchdog.unresolvedWriterCount == LeaseWatchdog.writerLimit)
        #expect(pmset.commands.count == LeaseWatchdog.writerLimit,
                "more privileged writes were started than could be accounted for")

        // And it goes on refusing while they are outstanding.
        clock.advance(LeaseWatchdog.reservationTimeout + 1)
        #expect(!watchdog.check(),
                "another writer was admitted with the earlier ones unaccounted for")

        // One of them finally finishes, and the room comes back.
        watchdog.childFinished(opID: pmset.started[0].opID, outcome: .wrote)
        #expect(watchdog.unresolvedWriterCount == LeaseWatchdog.writerLimit - 1)
        #expect(watchdog.check())
    }

    /// `.failed` covers a timeout and a kill as well as a refusal, and a write
    /// can have applied the setting before any of those. Only a reading can
    /// promise that nothing was written.
    @Test("A writer that fails after taking effect still invalidates")
    func failedWriterStillInvalidates() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)
        #expect(watchdog.check())
        let abandonedID = pmset.started[0].opID
        clock.advance(LeaseWatchdog.reservationTimeout + 1)
        #expect(watchdog.check())
        let before = watchdog.writeActivity

        // It wrote the setting and *then* timed out.
        watchdog.childFinished(opID: abandonedID, outcome: .failed("write took then timed out"))

        #expect(watchdog.writeActivity > before,
                "a write that may well have landed was treated as proof nothing happened")
        // The one that was abandoned is accounted for; the one that replaced
        // it is still reserved rather than unresolved.
        #expect(watchdog.unresolvedWriterCount == 0)
        #expect(watchdog.isBusy)
    }

    /// The exception: an outcome that *is* a reading cannot have written
    /// anything, so it must not invalidate.
    @Test("A reading from a retired operation is not treated as a write")
    func retiredReadingDoesNotInvalidate() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)
        #expect(watchdog.check())
        let abandonedID = pmset.started[0].opID
        clock.advance(LeaseWatchdog.reservationTimeout + 1)
        #expect(watchdog.check())
        let before = watchdog.writeActivity

        watchdog.childFinished(opID: abandonedID, outcome: .read(0))
        #expect(watchdog.writeActivity == before)
    }

    /// Deleting the timestamp to mean "eligible now" meant a persistent
    /// failure was retried on every five-second check rather than at the
    /// interval this type advertises.
    @Test("A failure waits out the retry interval like anything else")
    func failureHonoursTheRetryInterval() {
        for failure in [PmsetOutcome.failed("refused"), .read(1)] {
            let clock = TestClock()
            let pmset = TestPmset()
            let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
            pmset.report(to: { opID, outcome in
                watchdog.childFinished(opID: opID, outcome: outcome)
            })
            watchdog.publish(LeaseWatchdog.Bound(
                expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
            clock.advance(LeaseWatchdog.grace + 1)
            #expect(watchdog.check())

            if case .read = failure {
                pmset.answerNext(.wrote)        // the readback is what disagrees
                pmset.answerNext(failure)
            } else {
                pmset.answerNext(failure)
            }

            // Immediately afterwards, and right up to the deadline.
            #expect(!watchdog.check(), "a failure was retried with no time having passed")
            clock.advance(LeaseWatchdog.retryInterval - 1)
            #expect(!watchdog.check(), "the retry interval was not waited out")

            // And then it is eligible.
            clock.advance(2)
            #expect(watchdog.check(), "the retry never became eligible")
        }
    }

    /// And the reservation is not a wedge: a writer that never answers is
    /// retired, loudly, so the fail-safe goes on being one.
    @Test("A reservation nobody answers is eventually retired")
    func reservationIsRetired() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)
        #expect(watchdog.check())

        clock.advance(LeaseWatchdog.reservationTimeout + 1)
        #expect(watchdog.check(), "the fail-safe wedged on an operation that never answered")
        #expect(pmset.commands.count == 2)
    }

    /// An answer for an operation nobody is waiting on must not be taken for
    /// the current one: a retired write replying late would be read as the
    /// readback of the write that replaced it.
    @Test("An answer for a retired operation is ignored")
    func staleAnswerIgnored() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)
        #expect(watchdog.check())
        let first = pmset.started[0].opID

        clock.advance(LeaseWatchdog.reservationTimeout + 1)
        #expect(watchdog.check())

        // The retired one finally answers.
        watchdog.childFinished(opID: first, outcome: .read(0))
        #expect(!watchdog.hasConfirmedRestore,
                "a retired operation's answer confirmed the one that replaced it")

        // And again once the replacement is itself waiting on a readback: an
        // answer for anything else must not be taken for the one it wants.
        pmset.report(to: { _, _ in })
        let second = pmset.started[1].opID
        watchdog.childFinished(opID: second, outcome: .wrote)
        watchdog.childFinished(opID: first, outcome: .read(0))
        #expect(!watchdog.hasConfirmedRestore,
                "a stale answer was read as the current operation's readback")
    }

    @Test("A seed with nothing claimed stays quiet")
    func seedOfNothing() {
        let watchdog = LeaseWatchdog(clock: TestClock(), pmset: TestPmset(), log: TestLog())
        watchdog.seed { nil }
        #expect(!watchdog.currentBound.claimed)
        watchdog.seed { claim(label: "x", leaseExpiryNs: 1, sleepDisabledClaimed: false) }
        #expect(!watchdog.currentBound.claimed)
    }

    // MARK: - The counterexample

    /// The review's reproduction, as a test. A renewal's save is held open,
    /// the monotonic clock passes the lease, and the control queue is inside
    /// `store.save` and cannot process anything — so the expiry never runs.
    /// The watchdog is on another queue and does not care.
    @Test("A save that never returns does not stop the Mac being allowed to sleep")
    func blockedSaveStillBounded() async throws {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let store = GatedStore(file: file, owner: "com.egemert.ledge.keepawake")
        let watchPmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: watchPmset, log: TestLog())
        let (core, pmset) = daemon(clock, store, mac, watchdog)

        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)
        #expect(mac.sleepDisabled == 1, "the hold never took")
        #expect(watchdog.currentBound.claimed, "the bound was never published")

        // The next renewal's save hangs, with the control queue inside it.
        store.blockNextSave()
        let wedged = Task.detached {
            core.hold(session: Daemon.sessionA, generation: 2, deadline: nil,
                      leaseSeconds: 90) { _ in }
        }
        // Give it long enough to be inside the save.
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.blockedSaves == 1, "the save was not actually blocked")

        // Ninety-one seconds pass on the monotonic clock. The lease has
        // lapsed and the ordinary path is still owed its grace.
        clock.advance(91)
        #expect(!watchdog.check(), "the watchdog did not give the restore its grace")

        // And then the grace runs out too.
        clock.advance(LeaseWatchdog.grace)

        // The control queue cannot run a thing. The watchdog can — and it is
        // the Mac changing that is checked, not a command being issued.
        watchPmset.report(to: { opID, outcome in
            if case .writeSleepDisabled(let on) = watchPmset.started.first(where: { $0.opID == opID })?.command {
                mac.sleepDisabled = on ? 1 : 0
            }
            watchdog.childFinished(opID: opID, outcome: outcome)
        })
        #expect(watchdog.check(), "the bound was not enforced while the queue was stuck")
        watchPmset.answerNext(.wrote)
        #expect(mac.sleepDisabled == 0, "the Mac was never actually allowed to sleep")
        watchPmset.answerNext(.read(0))
        #expect(watchdog.hasConfirmedRestore, "the restore was never read back")

        store.letSaveFinish()
        await wedged.value
    }

    /// And it stops as soon as there is nothing to enforce.
    @Test("Nothing outstanding means the watchdog never acts")
    func quietWhenThereIsNothingToDo() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let watchPmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: watchPmset, log: TestLog())
        let (core, pmset) = daemon(clock, store, mac, watchdog)

        core.start()
        drain(core, pmset, mac)
        clock.advance(10_000)
        core.tick()
        drain(core, pmset, mac)

        #expect(!watchdog.check())
        #expect(watchPmset.commands.isEmpty)
    }

    /// The ordinary path wins when it can. A watchdog that fired anyway would
    /// mean nothing ever read the setting back.
    @Test("A release inside the grace leaves the watchdog with nothing to do")
    func orderlyReleaseWins() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let watchPmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: watchPmset, log: TestLog())
        let (core, pmset) = daemon(clock, store, mac, watchdog)

        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)

        clock.advance(91)
        core.tick()
        drain(core, pmset, mac)
        #expect(mac.sleepDisabled == 0, "the ordinary expiry did not put the setting back")

        #expect(!watchdog.check(), "the watchdog fired over a restore that had happened")
        #expect(watchPmset.commands.isEmpty)
    }

    /// The bound comes from the *persisted* claim, not from the holder the
    /// core is carrying in memory.
    ///
    /// A renewal whose save never landed extended a lease nobody can see, and
    /// the instant the daemon may fairly be judged against is the one the file
    /// holds. The two agree in every path this core has today — the holder is
    /// only ever set after the save that records it — so this pins the intent
    /// rather than catching a difference; the ordering is what documents which
    /// of them is the authority if that ever stops being true.
    @Test("The bound published is the one the file holds")
    func boundComesFromTheFile() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let store = GatedStore(file: file, owner: "com.egemert.ledge.keepawake")
        let watchdog = LeaseWatchdog(clock: clock, pmset: TestPmset(), log: TestLog())
        let (core, pmset) = daemon(clock, store, mac, watchdog)

        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)

        let onDisk = file.ledger?.claims["com.egemert.ledge.keepawake"]
        #expect(watchdog.currentBound.expiryContinuousNs == onDisk?.leaseExpiryContinuousNs,
                "the bound and the file disagree about when this Mac may sleep")
        #expect(watchdog.currentBound.claimed == (onDisk?.sleepDisabledClaimed == true))
    }

    /// The hazard the fail-safe creates, and the only repair available to it.
    ///
    /// Its write is a second writer that does not go through the claim store,
    /// so the store cannot reconcile it — and the write can land *late*, after
    /// the ordinary restore finished and after a new session applied 1. The
    /// Mac then reads 0 while the core still believes `.claimed` and skips the
    /// read-and-apply path, so every heartbeat after that confirms a hold that
    /// is not in force.
    ///
    /// Nothing can cancel a child it did not start. What the core can do is
    /// stop believing: a firing retires the cached state, and the next pass
    /// reads the setting again and re-applies it for whoever still wants it.
    @Test("A late fail-safe write does not leave a new hold believing itself")
    func lateFailSafeWriteIsRepaired() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let watchPmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: watchPmset, log: TestLog())
        watchPmset.report(to: { opID, outcome in
            watchdog.childFinished(opID: opID, outcome: outcome)
        })
        let (core, pmset) = daemon(clock, store, mac, watchdog)

        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)
        #expect(mac.sleepDisabled == 1)

        // A's lease lapses and the fail-safe starts a write — which is then
        // delayed, as a child on a loaded Mac can be.
        clock.advance(91 + LeaseWatchdog.grace)
        #expect(watchdog.check())
        core.tick()
        drain(core, pmset, mac)
        #expect(mac.sleepDisabled == 0, "the ordinary expiry did not run")

        // B takes a hold of its own, and it lands.
        let reply = Replies()
        core.hold(session: Daemon.sessionB, generation: 1, deadline: nil,
                  leaseSeconds: 90) { reply.add($0) }
        drain(core, pmset, mac)
        #expect(mac.sleepDisabled == 1, "B never got its hold")
        #expect(reply.last == .ok)

        // And only now does the old fail-safe write reach the hardware.
        mac.sleepDisabled = 0
        watchPmset.answerNext(.wrote)

        // B's next pass must notice and put it back. Before this, the core's
        // cached `.claimed` skipped the apply path and nothing ever did.
        core.tick()
        drain(core, pmset, mac)

        #expect(mac.sleepDisabled == 1,
                "a live hold was written out from under it and never repaired")
        #expect(core.status.ours)
        #expect(core.status.sleepDisabled == 1,
                "the status agreed with a hold that was not in force")
    }

    /// Invalidating the cache was not enough on its own. A transaction whose
    /// readback was taken *before* a fail-safe write landed could still answer
    /// afterwards, and `afterVerify` wrote `.claimed` back over the
    /// invalidation — so the next pump saw no new activity to invalidate, and
    /// the repair never happened at all.
    @Test("A verification taken before a fail-safe write is not believed after it")
    func staleVerificationIsNotBelieved() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let watchPmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: watchPmset, boot: "boot-1",
                                     log: TestLog())
        watchPmset.report(to: { opID, outcome in
            watchdog.childFinished(opID: opID, outcome: outcome)
        })
        let (core, pmset) = daemon(clock, store, mac, watchdog)

        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)

        // A lapses; the fail-safe starts a write and it is delayed.
        clock.advance(91 + LeaseWatchdog.grace)
        #expect(watchdog.check())
        core.tick()
        drain(core, pmset, mac)

        // B takes the setting, but its *verification* is held open.
        mac.hangs = true
        core.hold(session: Daemon.sessionB, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        mac.hangs = false
        // read, write, and then the readback that is about to be stale.
        answerOne(core, pmset, mac)
        answerOne(core, pmset, mac)
        #expect(mac.sleepDisabled == 1)

        // The fail-safe's write lands, and the core takes account of it.
        mac.sleepDisabled = 0
        watchPmset.answerNext(.wrote)
        core.tick()

        // Only now does B's old readback answer, saying 1.
        core.childExited(opID: pmset.started[pmset.answered].opID, outcome: .read(1))
        pmset.answered += 1
        drain(core, pmset, mac)

        #expect(mac.sleepDisabled == 1,
                "a readback taken before the write made the stale cache trustworthy again")
    }

    /// The verification path is fenced; the *read* path had its own way
    /// through. A periodic recheck that reads 1 takes the existing-claim
    /// shortcut, caches `.claimed` and refreshes the timestamp — so a reading
    /// taken before a fail-safe write landed became fresh evidence, and the
    /// heartbeat that followed skipped the repair.
    @Test("A periodic read taken before a fail-safe write is not believed after it")
    func stalePeriodicReadIsNotBelieved() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let watchPmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: watchPmset, boot: "boot-1",
                                     log: TestLog())
        let (core, pmset) = daemon(clock, store, mac, watchdog)

        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)
        #expect(mac.sleepDisabled == 1)

        // The periodic recheck comes round, and its read is left outstanding.
        clock.advance(31)
        core.tick()
        guard pmset.answered < pmset.started.count else {
            Issue.record("the periodic recheck never started a read")
            return
        }
        let pending = pmset.started[pmset.answered]

        // While it is out, the fail-safe writes the setting. (Driven directly:
        // what matters is that something outside this transaction wrote, not
        // which bound made it decide to.)
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)
        #expect(watchdog.check())
        mac.sleepDisabled = 0
        watchdog.childFinished(opID: watchPmset.started[0].opID, outcome: .wrote)

        // And the core takes account of that write *before* the stale read
        // comes back. This is the ordering that matters: the counter has
        // already been consumed, so nothing but the transaction's own stamp
        // can tell that its reading is older than the write.
        core.tick()

        // And only now does the recheck answer, with the old 1.
        pmset.answered += 1
        core.childExited(opID: pending.opID, outcome: .read(1))
        drain(core, pmset, mac)
        core.tick()
        drain(core, pmset, mac)

        #expect(mac.sleepDisabled == 1,
                "a read taken before the write became fresh evidence that nothing was wrong")
    }

    /// Answers exactly one outstanding child.
    private func answerOne(_ core: HelperCore, _ pmset: TestPmset, _ mac: FakeMac) {
        guard pmset.answered < pmset.started.count else { return }
        let next = pmset.started[pmset.answered]
        pmset.answered += 1
        switch next.command {
        case .readSleepDisabled:
            core.childExited(opID: next.opID, outcome: .read(mac.sleepDisabled))
        case .writeSleepDisabled(let on):
            mac.sleepDisabled = on ? 1 : 0
            core.childExited(opID: next.opID, outcome: .wrote)
        default:
            core.childExited(opID: next.opID, outcome: .failed("not in this test"))
        }
    }

    /// Two helper labels share the setting and the claim file, and nothing
    /// else. A counter in this process cannot see the other build's fail-safe,
    /// or a `pmset` run by hand — so a hold that believes itself has to look
    /// at the setting on a cadence rather than trusting a local number.
    @Test("A hold re-reads the setting even when nothing here wrote it")
    func holdRereadsOnACadence() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let watchdog = LeaseWatchdog(clock: clock, pmset: TestPmset(), boot: "boot-1",
                                     log: TestLog())
        let (core, pmset) = daemon(clock, store, mac, watchdog)

        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)
        #expect(mac.sleepDisabled == 1)

        // Somebody else writes the machine-wide setting. Nothing in this
        // process knows: no claim changed, no counter moved.
        mac.sleepDisabled = 0

        clock.advance(31)
        core.tick()
        drain(core, pmset, mac)

        #expect(mac.sleepDisabled == 1,
                "a hold went on believing a setting nobody had looked at")
    }

    /// An expired verification deadline asked for a wake of zero, the tick
    /// could not finish the child that was out, and it asked again — a root
    /// daemon spinning on the one queue that also serves the app. The same
    /// expired zero beat a failed read's backoff.
    @Test("A hold with a child out does not ask to be woken immediately")
    func pendingReadDoesNotSpin() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let timer = TestTimer()
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: timer, log: TestLog())
        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)

        // Past the verification interval, with the periodic read left out.
        clock.advance(31)
        core.tick()
        let outstanding = pmset.started.count
        #expect(outstanding > 0, "the periodic read never happened")

        timer.forgetRequests()
        for _ in 0..<100 { core.tick() }
        #expect(!timer.requested.contains(where: { $0 == 0 }),
                "the daemon asked to be woken immediately while a child was still out")
        #expect(pmset.started.count == outstanding, "a second read was started on top of one")
    }

    @Test("A failed read is left to its backoff rather than retried at once")
    func failedReadHonoursBackoff() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let timer = TestTimer()
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: timer, log: TestLog())
        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)

        clock.advance(31)
        core.tick()
        // The periodic read fails.
        let next = pmset.started[pmset.answered]
        pmset.answered += 1
        core.childExited(opID: next.opID, outcome: .failed("refused"))

        timer.forgetRequests()
        for _ in 0..<100 { core.tick() }
        #expect(!timer.requested.contains(where: { $0 == 0 }),
                "an expired verification deadline beat the failure backoff")
    }

    // MARK: - Saying it once

    @Test("It does not say the same thing every few seconds")
    func repeatsSlowly() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))

        pmset.report(to: { opID, outcome in watchdog.childFinished(opID: opID, outcome: outcome) })
        clock.advance(LeaseWatchdog.grace + 1)
        #expect(watchdog.check())
        // Confirmed, so the long interval applies.
        pmset.answerNext(.wrote)
        pmset.answerNext(.read(0))

        clock.advance(5)
        #expect(!watchdog.check())
        clock.advance(5)
        #expect(!watchdog.check())

        // And after the long interval it looks again rather than assuming the
        // setting has stayed where it put it.
        clock.advance(LeaseWatchdog.repeatInterval)
        #expect(watchdog.check())
    }

    /// A renewal that *does* land moves the instant, and the watchdog must
    /// start counting from the new one rather than from the one it fired on.
    @Test("A lease that is extended resets what the watchdog is waiting for")
    func newLeaseResetsIt() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, log: TestLog())
        let first = clock.continuousNanoseconds
        watchdog.publish(LeaseWatchdog.Bound(expiryContinuousNs: first, claimed: true))

        pmset.report(to: { opID, outcome in watchdog.childFinished(opID: opID, outcome: outcome) })
        clock.advance(LeaseWatchdog.grace + 1)
        #expect(watchdog.check())
        pmset.answerNext(.wrote)
        pmset.answerNext(.read(0))

        // The app came back and the renewal landed.
        clock.advance(1)
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds + 90_000_000_000, claimed: true))
        clock.advance(10)
        #expect(!watchdog.check(), "the watchdog acted against a lease that had been renewed")

        clock.advance(90 + LeaseWatchdog.grace)
        #expect(watchdog.check(), "the new lease was never enforced")
    }

    /// Its operation ids come from their own range, so one of its writes can
    /// never be mistaken for the core's.
    @Test("Its operations are never confused with the core's")
    func operationIDsAreItsOwn() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)
        watchdog.check()

        #expect(pmset.started.first?.opID ?? 0 >= LeaseWatchdog.opIDBase)
    }

    // MARK: - A failed reply is not a stopped writer

    /// The deepest version of "an acknowledgement is not a confirmation".
    ///
    /// `run` answers `.failed` when a child's pipes time out, and when the
    /// bounded collection poll gives up — and in both cases the child can
    /// still be alive with a privileged write ahead of it. Everything
    /// downstream treated that reply as the writer finishing: the stage was
    /// retired, the activity counter bumped once, and a newer hold's readback
    /// taken after that bump then passed every fence there was. When the
    /// child eventually landed its write, nothing was told.
    @Test("A write that finishes after its failed reply counts as activity again")
    func lateWriterCountsAgain() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        clock.advance(LeaseWatchdog.grace + 1)
        #expect(watchdog.check())
        let id = pmset.started[0].opID

        // The reply arrives. The child behind it is still alive.
        watchdog.childFinished(opID: id, outcome: .failed("pmset held its output open"))
        let afterReply = watchdog.writeActivity
        #expect(!watchdog.isBusy, "the stage was supposed to be retired by the reply")

        // And now the child stops, having written the setting on its way.
        watchdog.writerSettled(opID: id)

        #expect(watchdog.writeActivity > afterReply,
                "a write that landed after its failed reply was invisible to everything watching")
    }

    /// And it is not confirmation of anything. A restore read back as 0
    /// before this landed is not a restore any more.
    @Test("A late writer's finish unconfirms whatever was believed")
    func lateWriterUnconfirms() {
        let clock = TestClock()
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: pmset, boot: "b", log: TestLog())
        watchdog.publish(LeaseWatchdog.Bound(
            expiryContinuousNs: clock.continuousNanoseconds, claimed: true))
        pmset.report(to: { opID, outcome in watchdog.childFinished(opID: opID, outcome: outcome) })
        clock.advance(LeaseWatchdog.grace + 1)
        #expect(watchdog.check())
        pmset.answerNext(.wrote)
        pmset.answerNext(.read(0))
        #expect(watchdog.hasConfirmedRestore, "the fixture never confirmed anything")

        watchdog.writerSettled(opID: 999)
        #expect(!watchdog.hasConfirmedRestore,
                "a confirmation taken before a late write landed was still believed")
    }

    /// The composed case, which is the one that reaches the user. A hold is
    /// settled and believed; an old writer that was given up on finally
    /// stops. The thirty-second re-verify was the only thing that would ever
    /// have looked again, and a poll is not a reaction.
    @Test("A late write makes a settled hold look at the setting again, now")
    func lateWriteForcesAFreshRead() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let watchdog = LeaseWatchdog(clock: clock, pmset: TestPmset(), boot: "boot-1",
                                     log: TestLog())
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog(), watchdog: watchdog)
        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)
        #expect(mac.sleepDisabled == 1, "the fixture never took the hold")

        // Settled: nothing is due, so nothing is started.
        let quiet = pmset.started.count
        core.tick()
        #expect(pmset.started.count == quiet, "a settled hold read the setting for no reason")

        // A write this process had given up on finishes at last.
        core.noticeLateWrite(opID: 4242)

        #expect(pmset.started.count > quiet,
                "nothing looked at the setting after a write nobody was waiting for landed")
    }

    /// And the in-flight half: a readback that was already on its way when
    /// the late write landed describes a Mac that has since moved.
    @Test("A readback taken under a late write is not believed")
    func readbackUnderALateWriteIsNotBelieved() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let log = TestLog()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: log)
        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }

        // The apply reads, writes, and is about to read back.
        var verifying: (command: PmsetCommand, opID: Int)?
        var railing = 0
        while let next = pmset.outstanding {
            railing += 1
            if railing > 20 { break }
            if case .readSleepDisabled = next.command, mac.sleepDisabled == 1 {
                verifying = next
                break
            }
            pmset.answered += 1
            switch next.command {
            case .readSleepDisabled: core.childExited(opID: next.opID,
                                                      outcome: .read(mac.sleepDisabled))
            case .writeSleepDisabled(let on):
                mac.sleepDisabled = on ? 1 : 0
                core.childExited(opID: next.opID, outcome: .wrote)
            default: core.childExited(opID: next.opID, outcome: .failed("not in this test"))
            }
        }
        guard let verifying else {
            Issue.record("the fixture never reached the verification")
            return
        }

        // The old writer stops while that readback is still out.
        core.noticeLateWrite(opID: 4242)
        pmset.answered += 1
        core.childExited(opID: verifying.opID, outcome: .read(1))

        // The reading said 1, and it was taken before the late write landed.
        // Believing it would cache `.claimed` and stamp it fresh.
        #expect(log.contains("not believing the readback"),
                "a readback taken under a late write was cached as a verified hold: \(log.all)")
    }


    // MARK: - Teardown while a writer can still act

    /// R9-2's shape, and the one no counter can reach: the reading is
    /// genuinely fresh and nothing has changed yet.
    ///
    /// An apply is answered `.failed` while its child is still alive. End
    /// reads a true 0 and clears the claim. The child then sets 1, and by
    /// then there is no holder, no claim and nothing on disk that knows this
    /// Mac was ever Ledge's to put back — so nothing repairs it, in this
    /// process or the next.
    @Test("End does not clear the claim while a writer can still act")
    func endKeepsTheClaimUnderALiveWriter() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog())
        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)
        #expect(store.file.ledger?.claims["com.egemert.ledge.keepawake"] != nil,
                "the fixture never took a claim")

        // An operation is answered for while its child can still act.
        core.noticeLiveWriter(opID: 4242)

        // End. The setting genuinely reads 0 by the time it looks.
        mac.sleepDisabled = 0
        core.release(session: Daemon.sessionA, generation: 1) { _ in }
        drain(core, pmset, mac)

        #expect(store.file.ledger?.claims["com.egemert.ledge.keepawake"] != nil,
                "the claim was cleared while a writer could still set the setting back")
        #expect(!core.isClean,
                "the helper was ready to unregister with a privileged write still in flight")

        // The writer lands its 1 and is accounted for. Now there is still a
        // claim to repair from, which is the whole point of keeping it.
        mac.sleepDisabled = 1
        core.noticeLateWrite(opID: 4242)
        drain(core, pmset, mac)

        #expect(mac.sleepDisabled == 0, "the late write was never put back")
        #expect(store.file.ledger?.claims["com.egemert.ledge.keepawake"] == nil,
                "the claim outlived the obligation it stood for")
        #expect(core.isClean)
    }

    /// R9-1: the readback is held, and delivered after the old writer has
    /// already set the setting back. The counter *has* moved by then, and the
    /// restore branch was believing the reading anyway — clearing the claim
    /// and reporting clean with SleepDisabled at 1.
    @Test("A held restore readback does not clear the claim under a late write")
    func heldRestoreReadbackKeepsTheClaim() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog())
        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)

        core.release(session: Daemon.sessionA, generation: 1) { _ in }

        // Walk the restore to its verification and hold the answer there.
        var verifying: (command: PmsetCommand, opID: Int)?
        var railing = 0
        while let next = pmset.outstanding {
            railing += 1
            if railing > 20 { break }
            if case .readSleepDisabled = next.command, mac.sleepDisabled == 0 {
                verifying = next
                break
            }
            pmset.answered += 1
            switch next.command {
            case .readSleepDisabled:
                core.childExited(opID: next.opID, outcome: .read(mac.sleepDisabled))
            case .writeSleepDisabled(let on):
                mac.sleepDisabled = on ? 1 : 0
                core.childExited(opID: next.opID, outcome: .wrote)
            default:
                core.childExited(opID: next.opID, outcome: .failed("not in this test"))
            }
        }
        guard let verifying else {
            Issue.record("the fixture never reached the restore verification")
            return
        }

        // The old writer sets it back while that readback is in the post.
        mac.sleepDisabled = 1
        core.noticeLateWrite(opID: 4242)
        pmset.answered += 1
        core.childExited(opID: verifying.opID, outcome: .read(0))

        #expect(store.file.ledger?.claims["com.egemert.ledge.keepawake"] != nil,
                "a readback taken before a late write landed discharged the claim")
        #expect(!core.isClean, "the core reported clean with the setting at 1")
    }


    /// The exit gate, which is the one place the obligation has nothing else
    /// standing in for it.
    ///
    /// A helper with no claim and nothing in flight is clean, and clean is
    /// what lets it unregister and quit. If one of its own writers can still
    /// set SleepDisabled, quitting leaves that write in flight with nobody
    /// left to notice where it lands and nothing on disk saying whose it was.
    @Test("A helper with a live writer is not clean, claim or no claim")
    func liveWriterIsNotClean() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog())
        core.start()
        drain(core, pmset, mac)
        #expect(core.isClean, "a helper that has never held anything was not clean")
        #expect(store.file.ledger?.claims["com.egemert.ledge.keepawake"] == nil,
                "the fixture left a claim behind, which would mask the question")

        core.noticeLiveWriter(opID: 4242)
        #expect(!core.isClean,
                "a helper with a privileged write still in flight was ready to quit")

        core.noticeLateWrite(opID: 4242)
        drain(core, pmset, mac)
        #expect(core.isClean, "the helper never became clean after its writer settled")
    }

    /// Settlement can overtake its own registration: the two travel on
    /// different queues. A core that took the registration at face value
    /// inserted a writer that had already finished, with no second settlement
    /// coming — and then refused to go clean for the rest of its life over
    /// nothing.
    @Test("A registration that arrives after its own settlement registers nothing")
    func settlementBeforeRegistration() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog())
        core.start()
        drain(core, pmset, mac)

        core.noticeLateWrite(opID: 7)
        core.noticeLiveWriter(opID: 7)

        #expect(core.isClean,
                "a writer that had already settled was registered as still able to act")
    }

    /// And the ordinary order still works, so the guard is not simply
    /// swallowing every registration.
    @Test("A registration before its settlement still registers")
    func registrationBeforeSettlement() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog())
        core.start()
        drain(core, pmset, mac)

        core.noticeLiveWriter(opID: 8)
        #expect(!core.isClean)
        core.noticeLateWrite(opID: 8)
        #expect(core.isClean)
    }

    /// The memory of finished writers is a reordering window, not a history.
    @Test("The settled-writer memory is bounded")
    func settledMemoryIsBounded() {
        let clock = TestClock()
        let mac = FakeMac()
        let store = GatedStore(file: ClaimFile(), owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog())
        core.start()
        drain(core, pmset, mac)

        // Far more settlements than the window holds. The oldest are
        // forgotten, which is the right trade: the ordering is fixed at its
        // source and this only has to cover a few queue hops.
        for id in 0..<200 { core.noticeLateWrite(opID: id) }
        core.noticeLiveWriter(opID: 0)
        #expect(!core.isClean, "an unbounded history of finished ids is being kept")

        core.noticeLateWrite(opID: 0)
        #expect(core.isClean)
    }

    // MARK: - Uncertainty that reaches the disk in time

    /// Registration arrives *during* the operation it belongs to.
    ///
    /// The runner announces an unsettled writer before it answers, so the
    /// core is still inside the write transaction when it hears. The stamp
    /// used to wait for the next pump — and between the failure releasing the
    /// file lock and that pump, another process is entitled to take the lock,
    /// find a record saying nothing about the writer still out there, and
    /// clear it.
    ///
    /// The observer runs exactly at that release, which is where another
    /// helper would be.
    @Test("A writer registered inside a transaction is on disk before the lock goes")
    func registrationReachesDiskBeforeTheLockIsReleased() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let store = GatedStore(file: file, owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog())
        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }

        // Walk to the write and leave it outstanding: the transaction holds
        // the lock, which is exactly when the announcement arrives.
        var writing: (command: PmsetCommand, opID: Int)?
        var railing = 0
        while let next = pmset.outstanding {
            railing += 1
            if railing > 20 { break }
            if case .writeSleepDisabled = next.command { writing = next; break }
            pmset.answered += 1
            core.childExited(opID: next.opID, outcome: .read(mac.sleepDisabled))
        }
        guard let writing else {
            Issue.record("the fixture never issued a write")
            return
        }
        #expect(file.lockedBy != nil, "the transaction was supposed to hold the lock")

        core.noticeLiveWriter(opID: writing.opID)

        // What the next process to take the lock would see.
        let seen = Recorded()
        store.onUnlock = { seen.set(file.ledger?.claims["com.egemert.ledge.keepawake"]) }

        pmset.answered += 1
        core.childExited(opID: writing.opID, outcome: .failed("pmset held its output open"))

        #expect(seen.value != nil, "the observer never ran, so nothing was established")
        #expect(seen.value??.mayBeRemoved == false,
                "the first record visible to another process said nothing about the writer")

        // And the run that raised it can lower it again. A flag published
        // without saying whose it is cannot be taken back by anybody,
        // including the process that owns the writer.
        core.noticeLateWrite(opID: writing.opID)
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == true,
                "the run that raised the uncertainty could not account for its own writer")
    }

    /// Uncertainty is kept, not inherited for ever. When the run that owns it
    /// settles, the record this one was holding becomes ordinary again.
    @Test("A retained record is tidied up once its uncertainty clears")
    func retainedRecordIsReleasedWhenItsWriterSettles() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let a = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        a.start()
        a.hold()
        a.drain()
        a.core.noticeLiveWriter(opID: 77)
        clock.advance(91)

        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        b.start()
        b.drain()
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] != nil,
                "B deleted a record whose writer had not stopped")
        #expect(mac.sleepDisabled == 0, "B did not put the setting back")

        // A accounts for its writer, so the record is ordinary again.
        a.core.noticeLateWrite(opID: 77)
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == true)

        // And A, which owns it, tidies it away itself now that there is
        // nothing left to protect.
        a.core.tick()
        a.drain()
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] == nil,
                "a record whose uncertainty had cleared was kept for ever")
        #expect(a.core.isClean)
    }

    /// A launchd label identifies a service, not one lifetime of it.
    ///
    /// A replacement helper of the same label starts with no record of the old
    /// process's children. Its empty set is ignorance, not a settlement, and
    /// reading it as one let a new launch erase uncertainty it never knew
    /// about — along with the undo data the uncertainty was protecting.
    @Test("A replacement helper does not clear uncertainty it never knew about")
    func replacementKeepsInheritedUncertainty() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let old = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                         clock: clock, file: file, mac: mac)
        old.start()
        old.hold()
        old.drain()
        old.core.noticeLiveWriter(opID: 1234)
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false,
                "the fixture never raised the flag")

        // The helper is replaced — same label, same boot, new process.
        clock.advance(91)
        let replacement = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                                 clock: clock, file: file, mac: mac)
        replacement.start()
        replacement.drain()

        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] != nil,
                "a replacement deleted a record whose writer it could not account for")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false,
                "a replacement declared somebody else's writer finished")
        #expect(mac.sleepDisabled == 0,
                "the replacement did not put the setting back while it was keeping the record")

        // And it stops there. A record it may never remove must not be
        // restored again on every pass: that is a root daemon running pmset
        // in a loop for the rest of its life.
        let spent = replacement.pmset.started.count
        for _ in 0..<20 { replacement.core.tick(); replacement.drain() }
        #expect(replacement.pmset.started.count == spent,
                "the replacement kept restoring a record it had already put back")
    }

    /// And a record from an earlier boot is the one case where starting empty
    /// really is proof: nothing from a previous boot is still running.
    @Test("A record from an earlier boot is not protected by its old uncertainty")
    func earlierBootUncertaintyIsResolved() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": HelperClaim(
                holderLabel: "com.egemert.ledge.keepawake",
                boot: "AN-EARLIER-BOOT",
                sessionID: "S0", generation: 1, deadline: nil,
                leaseExpiryContinuousNs: 0, sleepDisabledClaimed: true,
                lowPowerPrior: nil, writers: [WriterMark(run: "a-dead-run", boot: "boot-1")])
        ])
        mac.sleepDisabled = 1

        let fresh = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-2",
                           clock: clock, file: file, mac: mac)
        fresh.start()
        fresh.drain()

        #expect(mac.sleepDisabled == 0, "the setting from a dead boot was never put back")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] == nil,
                "a record from a boot that cannot still act was kept for ever")
    }

    /// Somewhere an observer can leave what it saw.
    final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: HelperClaim??
        func set(_ value: HelperClaim?) { lock.withLock { stored = value } }
        var value: HelperClaim?? { lock.withLock { stored } }
    }

    // MARK: - Uncertainty that is durable rather than attempted

    /// The flag has to be on the disk before the child exists, not afterwards.
    ///
    /// Stamping on registration could only ever be best effort: the
    /// registration arrives with the failed answer, the save can be refused,
    /// and the lock is released either way — so an unprotected claim reaches
    /// the next helper and the retry comes too late. The baseline claim is
    /// already journalled before the write goes out, which is the one moment
    /// that is a real barrier.
    @Test("The claim that admits a write already says a writer is outstanding")
    func uncertaintyIsDurableBeforeTheChildExists() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let store = GatedStore(file: file, owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog())
        core.start()
        drain(core, pmset, mac)

        // What the disk says at the instant a child may first act.
        let atAdmission = Recorded()
        pmset.onStart = {
            if case .writeSleepDisabled = pmset.started.last?.command {
                atAdmission.set(file.ledger?.claims["com.egemert.ledge.keepawake"])
            }
        }

        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }
        drain(core, pmset, mac)

        #expect(atAdmission.value != nil, "the fixture never admitted a write")
        #expect(atAdmission.value??.mayBeRemoved == false,
                "a privileged write was admitted over a claim that did not say so")
        #expect(atAdmission.value??.writers?.isEmpty == false,
                "the uncertainty did not say whose it was")
    }

    /// And it stays up for as long as the write is unaccounted for. A flag
    /// raised at admission and lowered again while the child is still running
    /// protects nothing: the window it exists for is exactly that one.
    @Test("The uncertainty stands while a write is still outstanding")
    func uncertaintyStandsWhileAWriteIsOut() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let store = GatedStore(file: file, owner: "com.egemert.ledge.keepawake")
        let pmset = TestPmset()
        let core = HelperCore(label: "com.egemert.ledge.keepawake", bootID: "boot-1",
                              clock: clock, store: store, pmset: pmset,
                              timer: TestTimer(), log: TestLog())
        core.start()
        drain(core, pmset, mac)
        core.hold(session: Daemon.sessionA, generation: 1, deadline: nil,
                  leaseSeconds: 90) { _ in }

        // Walk to the write and leave it unanswered.
        var railing = 0
        while let next = pmset.outstanding {
            railing += 1
            if railing > 20 { break }
            if case .writeSleepDisabled = next.command { break }
            pmset.answered += 1
            core.childExited(opID: next.opID, outcome: .read(mac.sleepDisabled))
        }
        guard case .writeSleepDisabled = pmset.outstanding?.command else {
            Issue.record("the fixture never issued a write")
            return
        }

        // Heartbeats keep arriving while the child runs. None of them is an
        // account of what it did.
        for _ in 0..<5 { core.tick() }
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false,
                "the uncertainty was lowered while its write was still running")

        // Answered and verified, and only then is it lowered.
        drain(core, pmset, mac)
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == true,
                "the uncertainty outlived the write it stood for")
    }

    /// The cache that stops a retained record being restored for ever must not
    /// outlive what it describes.
    ///
    /// It remembers a service label, and a label is not an episode: the same
    /// run takes a new hold, applies the setting again, and End then returns
    /// early because the label is still cached. The anti-spin rule became the
    /// thing that suppressed the undo.
    @Test("A retained record does not suppress the End of a later hold")
    func retainedRecordDoesNotSuppressALaterEnd() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        // An old run left an unresolved record behind.
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": HelperClaim(
                holderLabel: "com.egemert.ledge.keepawake", boot: "boot-1",
                sessionID: "S0", generation: 1, deadline: nil,
                leaseExpiryContinuousNs: 0, sleepDisabledClaimed: true,
                lowPowerPrior: nil, writers: [WriterMark(run: "a-dead-run", boot: "boot-1")])
        ])

        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: clock, file: file, mac: mac)
        daemon.start()
        daemon.drain()
        #expect(mac.sleepDisabled == 0, "the replacement never put the setting back")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false,
                "the inherited uncertainty was cleared by a run that never knew it")

        // A new session on the same helper.
        daemon.hold()
        daemon.drain()
        #expect(mac.sleepDisabled == 1, "the new hold never took")

        daemon.release()
        daemon.drain()

        #expect(mac.sleepDisabled == 0,
                "End was skipped because a cache still named this label")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false,
                "the inherited evidence was destroyed by the new session's cleanup")
    }

    /// The apply path discharged a protected record without asking, which
    /// deleted the very record the protection lives in — making every guard
    /// downstream of it moot.
    @Test("Taking a hold does not discharge a peer's protected record")
    func applyDoesNotDischargeAProtectedPeer() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let a = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        a.start()
        a.hold()
        a.drain()
        a.core.noticeLiveWriter(opID: 5150)
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false)

        // A's lease lapses while its writer can still act, and the other build
        // takes a session of its own.
        clock.advance(91)
        mac.sleepDisabled = 0
        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        // Its first recovery read fails, so B never restores A's record and
        // never caches it as handled. The apply path is then the first thing
        // that meets it — which is the path that discharged it without asking.
        mac.refuseReads = 1
        b.start()
        b.drain()
        b.hold()
        b.drain()

        #expect(mac.sleepDisabled == 1, "B never took its own hold")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] != nil,
                "taking a hold deleted a record whose writer could still act")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false)

        // And B ending changes nothing about A's.
        b.release()
        b.drain()
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] != nil,
                "B's own cleanup took A's record with it")
    }

    /// The peer revisits a record it had skipped, once the owner has accounted
    /// for its writer — even when the owner's own tidying failed.
    @Test("A skipped record is picked up again when a peer has reason to look")
    func skippedRecordIsRevisitedOnANewHold() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let a = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        a.start()
        a.hold()
        a.drain()
        a.core.noticeLiveWriter(opID: 611)
        clock.advance(91)

        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        b.start()
        b.drain()
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] != nil,
                "B deleted a record whose writer had not stopped")

        // A accounts for its writer, and its own tidying read fails, so the
        // now-ordinary record is left on the disk.
        mac.sleepDisabled = 1
        a.mac.refuseReads = 1
        a.core.noticeLateWrite(opID: 611)
        a.drain()
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == true,
                "the uncertainty outlived the writer it stood for")

        // B is asked for a session. It must look at that record again rather
        // than skipping it for the life of the process.
        b.hold()
        b.drain()
        #expect(b.status.ours, "B skipped a record it had cached and never acquired")
        #expect(mac.sleepDisabled == 1)
    }

    // MARK: - Uncertainty is a set, not a fact

    /// Two runs can have children in flight against one obligation.
    ///
    /// A helper that applied a setting and a peer putting it back are both
    /// writers of the same record. One owner meant the second got in without
    /// adding itself — and then the first retired what it thought was the
    /// only contribution, taking the record with it while the other child was
    /// still alive.
    @Test("Each run marks a record for itself and retires only its own mark")
    func marksAccumulatePerRun() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let a = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        a.start()
        a.hold()
        a.drain()
        a.core.noticeLiveWriter(opID: 11)

        guard var record = file.ledger?.claims["com.egemert.ledge.keepawake"] else {
            Issue.record("the fixture never made a record")
            return
        }
        #expect(record.writers?.count == 1, "this run did not mark the record")
        #expect(record.mayBeRemoved == false)

        // A peer writes against the same obligation.
        record.writers?.append(WriterMark(run: "another-run", boot: "boot-1"))
        file.ledger?.claims["com.egemert.ledge.keepawake"] = record
        #expect(record.writers?.count == 2)

        // This run accounts for its own writer, and retires only its own.
        a.core.noticeLateWrite(opID: 11)
        a.core.tick()
        a.drain()

        let after = file.ledger?.claims["com.egemert.ledge.keepawake"]
        #expect(after != nil,
                "one run retired a record that another run was still writing to")
        #expect(after?.writers?.map(\.run) == ["another-run"],
                "a run retired somebody else's contribution: \(String(describing: after?.writers))")
        #expect(after?.mayBeRemoved == false)
    }

    /// A writer born in this boot is not reclaimed because the *record* is old.
    ///
    /// The record's boot says when the obligation was made. A helper in this
    /// boot can act on an obligation from the last one, and reading the
    /// record's boot as the writer's is how a live writer came to be written
    /// off as one that could not possibly still exist.
    @Test("A current-boot writer on an old record is not treated as dead")
    func currentBootWriterOnAnOldRecordSurvives() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": HelperClaim(
                holderLabel: "com.egemert.ledge.keepawake",
                boot: "AN-EARLIER-BOOT",
                sessionID: "S0", generation: 1, deadline: nil,
                leaseExpiryContinuousNs: 0, sleepDisabledClaimed: true,
                lowPowerPrior: 0,
                // Raised by a helper running *now*, against an old obligation.
                writers: [WriterMark(run: "a-live-peer", boot: "boot-2")])
        ])
        mac.sleepDisabled = 1

        let fresh = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-2",
                           clock: clock, file: file, mac: mac)
        // What the record says at the instant a child of ours may first act.
        let atAdmission = Recorded()
        fresh.pmset.onStart = {
            if fresh.pmset.started.last?.command.isWrite == true, atAdmission.value == nil {
                atAdmission.set(file.ledger?.claims["com.egemert.ledge.keepawake"])
            }
        }
        fresh.start()
        fresh.drain()

        #expect(mac.sleepDisabled == 0, "the setting from a dead boot was never put back")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] != nil,
                "a live writer's mark was reclaimed because the record was old")

        // And while this run was writing, it had added its own contribution
        // rather than hiding behind the one already there. Two runs, two
        // marks — and only ours goes when ours is accounted for.
        let marks = atAdmission.value??.writers ?? []
        #expect(marks.contains { $0.run == "a-live-peer" },
                "the peer's contribution was lost: \(marks)")
        #expect(marks.count >= 2,
                "this run wrote against a marked record without saying so: \(marks)")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.writers?.map(\.run)
                == ["a-live-peer"],
                "a run retired somebody else's contribution, or never retired its own")
    }

    /// And a writer from a boot that is over really can be reclaimed.
    @Test("A writer from an earlier boot is reclaimed")
    func earlierBootWriterIsReclaimed() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": HelperClaim(
                holderLabel: "com.egemert.ledge.keepawake", boot: "AN-EARLIER-BOOT",
                sessionID: "S0", generation: 1, deadline: nil,
                leaseExpiryContinuousNs: 0, sleepDisabledClaimed: true,
                lowPowerPrior: nil,
                writers: [WriterMark(run: "a-dead-run", boot: "AN-EARLIER-BOOT")])
        ])
        mac.sleepDisabled = 1

        let fresh = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-2",
                           clock: clock, file: file, mac: mac)
        fresh.start()
        fresh.drain()

        #expect(mac.sleepDisabled == 0)
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] == nil,
                "a record whose writers died at the reboot was kept for ever")
    }

    /// The one write nothing may stand in front of, whatever the transaction
    /// that carries it is called.
    ///
    /// Startup recovering somebody's lapsed claim writes exactly the same
    /// `disablesleep 0`. Keying the emergency on one spelling of the kind
    /// refused it — and then looped, because startup did not pass the backoff
    /// gate everything else does.
    @Test("A refused journal never blocks the write that lets a Mac sleep")
    func refusedJournalNeverBlocksSleepRelease() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": HelperClaim(
                holderLabel: "com.egemert.ledge.keepawake", boot: "boot-1",
                sessionID: "S0", generation: 1, deadline: nil,
                leaseExpiryContinuousNs: 0, sleepDisabledClaimed: true,
                lowPowerPrior: nil)
        ])
        mac.sleepDisabled = 1
        file.saveFailures = 99

        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        b.start()
        b.drain()

        #expect(mac.sleepDisabled == 0,
                "a refused journal blocked the one write a Mac is waiting for")

        // And it does not read the setting as fast as pmset can answer.
        let spent = b.pmset.started.count
        for _ in 0..<20 { b.core.tick(); b.drain() }
        #expect(b.pmset.started.count == spent,
                "a refused publication restarted startup on every pass")
    }

    /// A retirement is complete when the disk says so.
    ///
    /// A save that fails leaves this run named on a record — often somebody
    /// else's, where there is no claim of our own to notice it by — and the
    /// work is still owed until it lands.
    @Test("A failed retirement on a peer's record is not reported finished")
    func failedForeignRetirementIsNotClean() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": HelperClaim(
                holderLabel: "com.egemert.ledge.keepawake", boot: "boot-1",
                sessionID: "S0", generation: 1, deadline: nil,
                leaseExpiryContinuousNs: 0, sleepDisabledClaimed: false,
                lowPowerPrior: 0)
        ])
        mac.lowPower = LowPowerSetting(battery: true, charger: true)

        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        // The restore lands; the save that would take B's name back does not.
        b.store.file.saveFailures = 0
        b.start()
        b.drain()
        #expect(mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "the fixture never restored the peer's setting")

        guard file.ledger?.claims["com.egemert.ledge.keepawake"] == nil else {
            Issue.record("the fixture left the peer's record behind")
            return
        }
        #expect(b.core.isClean, "a helper that owes nothing reported itself unfinished")
    }
}
