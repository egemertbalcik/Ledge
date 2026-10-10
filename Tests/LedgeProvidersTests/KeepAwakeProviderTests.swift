import Foundation
import Testing
@testable import LedgeCore
@testable import LedgeProviders
@testable import LedgeSystem

/// Serialised, because several of these hold a journal write open to model a
/// slow disk, and a held write blocks the thread its actor is running on. Run
/// in parallel, enough of them at once take every thread the concurrency pool
/// has and nothing is left to release them.
@MainActor
@Suite("Keep Awake provider", .serialized)
struct KeepAwakeProviderTests {

    private let boot = "boot-A"

    private struct Rig {
        let provider: KeepAwakeProvider
        let log: KeepAwakeLog
        let assertion: FakeSleepAssertion
        let journal: MemoryKeepAwakeJournal
        let writer: KeepAwakeJournalWorker
        let admissions: AdmissionCounter
        let tombstone: MemoryTombstone
        let clock: TestClock
        let power: StubPowerSource
        let thermal: StubThermalSource
    }

    private func rig(
        stored: KeepAwakeRecord? = nil,
        tombstone id: String? = nil,
        bootID: String? = "boot-A",
        hasNotchPanel: Bool = true,
        ids: [String] = ["A", "B", "C", "D"]
    ) -> Rig {
        let log = KeepAwakeLog()
        let clock = TestClock()
        let assertion = FakeSleepAssertion(log: log)
        let journal = MemoryKeepAwakeJournal(log: log, stored: stored)
        let admissions = AdmissionCounter()
        let stone = MemoryTombstone(log: log, value: id)
        let power = StubPowerSource(
            value: PowerSnapshot(percentage: 0.80, isCharging: false, isPluggedIn: false,
                                 isLowPower: false, timeRemaining: nil)
        )
        let thermal = StubThermalSource()
        var queue = ids
        let writer = KeepAwakeJournalWorker(journal, observeAdmissions: { admissions.note($0) })
        let provider = KeepAwakeProvider(
            now: { clock.now },
            assertion: assertion,
            power: power,
            thermal: thermal,
            journal: writer,
            tombstone: stone,
            bootID: bootID,
            hasNotchPanel: { hasNotchPanel },
            makeID: { queue.isEmpty ? UUID().uuidString : queue.removeFirst() },
            formatTime: { _ in "17:40" }
        )
        return Rig(provider: provider, log: log, assertion: assertion, journal: journal,
                   writer: writer, admissions: admissions, tombstone: stone, clock: clock,
                   power: power, thermal: thermal)
    }

    /// The provider the registry builds when Keep Awake is switched back on:
    /// a new one, over the same journal and the same writer.
    private func replacement(for rig: Rig, ids: [String],
                             assertion: FakeSleepAssertion) -> KeepAwakeProvider {
        var queue = ids
        return KeepAwakeProvider(
            now: { rig.clock.now },
            assertion: assertion,
            power: rig.power,
            thermal: rig.thermal,
            journal: rig.writer,
            tombstone: rig.tombstone,
            bootID: boot,
            makeID: { queue.isEmpty ? UUID().uuidString : queue.removeFirst() },
            formatTime: { _ in "17:40" }
        )
    }

    /// Waits for something to actually have happened, rather than for a number
    /// of turns to have passed.
    ///
    /// `settle()` says "let the main actor catch up"; this says "let it catch
    /// up *until this is true*", which is what a test needs before it can act
    /// on a write or a read being in flight.
    private func wait(for condition: @MainActor () -> Bool,
                      _ what: Comment, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0 ..< 2_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// Lets work the provider posted to the main actor run.
    ///
    /// Journal reads and writes moved off this actor so a stalled disk cannot
    /// freeze the app, which means recovery finishes a turn or two after
    /// `start()` returns rather than inside it.
    private func settle() async {
        for _ in 0 ..< 8 { await Task.yield() }
    }

    private func record(id: String, state: KeepAwakeRecord.State,
                        start: Date, minutes: Int, boot: String) -> KeepAwakeRecord {
        KeepAwakeRecord(id: id, state: state, startedAt: start,
                        deadline: start.addingTimeInterval(TimeInterval(minutes * 60)),
                        total: TimeInterval(minutes * 60), boot: boot)
    }

    // MARK: - Ordering

    @Test("Nothing is held until the disk has agreed to remember it")
    func journalBeforeAcquire() async {
        // A hold nobody wrote down is a hold nobody can release after a crash.
        // A record of a hold that was never taken is merely wrong, and the next
        // launch corrects it — so the write goes first.
        let r = rig()
        let outcome1 = await r.provider.begin(minutes: 60)
        #expect(outcome1)
        let write = r.log.firstIndex(of: .journalWrite(.running, id: "A"))
        let acquire = r.log.firstIndex(of: .acquire(timeout: 3_600 + 120))
        #expect(write != nil && acquire != nil)
        #expect(write! < acquire!)
    }

    @Test("The assertion carries a powerd backstop two minutes past the deadline")
    func backstop() async {
        // So a hung or killed Ledge can hold the Mac at most that long.
        let r = rig()
        _ = await r.provider.begin(minutes: 30)
        #expect(r.assertion.lastTimeout == 30 * 60 + KeepAwakeProvider.powerdMargin)
    }

    @Test("Ending releases the assertion and records the end")
    func endReleases() async {
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        await r.provider.end(reason: .endedByYou)
        #expect(!r.assertion.isHeld)
        #expect(r.journal.stored?.state == .ended)
        #expect(r.journal.stored?.endReason == .endedByYou)
        if case .finished(let finish) = r.provider.state {
            #expect(finish.reason == .endedByYou)
        } else {
            #expect(Bool(false), "it should be finished")
        }
    }

    @Test("stop() lets go of everything and writes nothing")
    func stopWritesNothing() async {
        // stop() is reached both when the card is switched off and when the app
        // is exiting, so it cannot tell them apart — and a function that cannot
        // tell them apart must not be the one that decides a session is over.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        let before = r.log.writes.count
        r.provider.stop()
        #expect(!r.assertion.isHeld)
        #expect(r.log.writes.count == before)
        #expect(r.journal.stored?.state == .running)
    }

    // MARK: - Journal failures (§6.1.1)

    @Test("A start the disk refuses acquires nothing and changes nothing")
    func startWriteFails() async {
        let r = rig()
        r.journal.failWrites = 1
        let refused11 = await r.provider.begin(minutes: 60)
        #expect(!refused11)
        #expect(!r.assertion.isHeld)
        #expect(r.provider.state == .ready)
        #expect(r.provider.payload.problem == .startNotSaved)
    }

    @Test("An end the disk refuses still releases, and leaves a tombstone")
    func endWriteFails() async {
        // Releasing is never conditional on the disk: holding a Mac awake until
        // a disk recovers is the one outcome nobody would choose.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.journal.failWrites = -1
        await r.provider.end(reason: .endedByYou)
        #expect(!r.assertion.isHeld)
        #expect(r.tombstone.value == "A")
        #expect(r.journal.stored?.state == .running, "the disk never took the end")
    }

    @Test("When the journal and the tombstone both refuse, the card says so")
    func bothFail() async {
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.journal.failWrites = -1
        r.tombstone.fails = true
        await r.provider.end(reason: .endedByYou)
        #expect(!r.assertion.isHeld)
        guard case .finished(let finish) = r.provider.state else {
            return #expect(Bool(false), "it should be finished")
        }
        // The user is told before a relaunch surprises them with it.
        #expect(finish.endUnrecorded)
        #expect(r.provider.payload.endUnrecorded)
    }

    @Test("An acquire the system refuses leaves Ready, with its own sentence")
    func acquireRefused() async {
        let r = rig()
        r.assertion.refuses = true
        let refused12 = await r.provider.begin(minutes: 60)
        #expect(!refused12)
        #expect(r.provider.state == .ready)
        #expect(r.provider.payload.problem == .assertionRefused)
        // The record must not be left claiming a hold that was never taken.
        #expect(r.journal.stored?.state == .ended)
    }

    // MARK: - The retry guard

    @Test("A superseded retry never puts an old session back")
    func supersededRetry() async {
        // End A fails, Start B succeeds, A's retry fires. The retry writes
        // whatever the disk is *currently* meant to hold, which is B.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.journal.failWrites = 1
        await r.provider.end(reason: .endedByYou)
        #expect(r.journal.stored?.id == "A")

        r.provider.dismiss()
        let outcome2 = await r.provider.begin(minutes: 30)
        #expect(outcome2)
        #expect(r.journal.stored?.id == "B")
        #expect(r.journal.stored?.state == .running)

        // Observed as a write, not only as an outcome: re-writing the record
        // that is already on disk would reach the same final state while
        // hammering the disk on every retry, so the guard is that the retry
        // does nothing at all.
        let writesBefore = r.log.writes.count
        await r.provider.retryTick()
        #expect(r.log.writes.count == writesBefore, "a persisted record is not written again")
        #expect(r.journal.stored?.id == "B")
        #expect(r.journal.stored?.state == .running, "A's retry must not undo B")
    }

    @Test("End A fails, Start B fails too, and A's retry records A — never B")
    func retryAfterBothFail() async {
        // The case the owner asked for. B never started: nothing was acquired
        // and the card stayed in Ready. If the failed start had become what the
        // retries were trying to write, A's retry would persist running(B) —
        // and a later launch would resume a session that never existed.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)

        r.journal.failWrites = 1
        await r.provider.end(reason: .endedByYou)
        #expect(!r.assertion.isHeld)

        r.provider.dismiss()
        r.journal.failWrites = 1
        let refused13 = await r.provider.begin(minutes: 30)
        #expect(!refused13, "B must not start")
        #expect(!r.assertion.isHeld, "nothing may be held for a session that did not start")
        #expect(r.provider.state == .ready)

        await r.provider.retryTick()

        let stored = r.journal.stored
        #expect(stored?.id == "A", "the retry must flush A's end, not B")
        #expect(stored?.state == .ended)
        #expect(stored?.endReason == .endedByYou)
        #expect(r.journal.stored?.id != "B")

        // And nothing resumes: a fresh provider over the same disk sees A's
        // end, not a running B.
        let again = rig(stored: r.journal.stored, tombstone: r.tombstone.value)
        let stream = again.provider.start()
        await settle()
        #expect(!again.provider.state.isRunning)
        #expect(!again.assertion.isHeld)
        // The stream has to outlive the assertions: an unconsumed one that
        // goes out of scope terminates, and termination stops the provider.
        withExtendedLifetime(stream) {}

    }

    // MARK: - Continuity

    @Test("A session from this boot with time left comes back, and is announced")
    func resumesSameBoot() async {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let r = rig(stored: record(id: "A", state: .running, start: start,
                                   minutes: 60, boot: boot))
        let stream = r.provider.start()
        await settle()
        #expect(r.provider.state.isRunning)
        #expect(r.assertion.isHeld)
        // A resume nobody asked for has to be visible, with End one tap away.
        #expect(r.provider.announcesResumeOnce)
        #expect(!r.provider.announcesResumeOnce, "announced once, not every publish")
        // The stream has to outlive the assertions: an unconsumed one that
        // goes out of scope terminates, and termination stops the provider.
        withExtendedLifetime(stream) {}

    }

    @Test("A deadline that passed while Ledge was away is dated to the deadline")
    func missedDeadline() async {
        let start = Date(timeIntervalSince1970: 1_000_000).addingTimeInterval(-7_200)
        let r = rig(stored: record(id: "A", state: .running, start: start,
                                   minutes: 60, boot: boot))
        let stream = r.provider.start()
        await settle()
        guard case .finished(let finish) = r.provider.state else {
            return #expect(Bool(false), "it should be finished")
        }
        #expect(finish.reason == .ledgeNotRunning)
        #expect(finish.endedAt == start.addingTimeInterval(3_600))
        #expect(!r.assertion.isHeld)
        // The stream has to outlive the assertions: an unconsumed one that
        // goes out of scope terminates, and termination stops the provider.
        withExtendedLifetime(stream) {}

    }

    @Test("A session from another boot ended when the Mac restarted")
    func otherBoot() async {
        let r = rig(stored: record(id: "A", state: .running,
                                   start: Date(timeIntervalSince1970: 1_000_000),
                                   minutes: 60, boot: "boot-OLD"))
        let stream = r.provider.start()
        await settle()
        guard case .finished(let finish) = r.provider.state else {
            return #expect(Bool(false), "it should be finished")
        }
        #expect(finish.reason == .macRestarted)
        #expect(!r.assertion.isHeld)
        // The stream has to outlive the assertions: an unconsumed one that
        // goes out of scope terminates, and termination stops the provider.
        withExtendedLifetime(stream) {}

    }

    @Test("A tombstone stops a relaunch from resurrecting an ended session")
    func tombstoneWins() async {
        let r = rig(stored: record(id: "A", state: .running,
                                   start: Date(timeIntervalSince1970: 1_000_000),
                                   minutes: 60, boot: boot),
                    tombstone: "A")
        let stream = r.provider.start()
        await settle()
        #expect(!r.provider.state.isRunning)
        #expect(!r.assertion.isHeld)
        // The stream has to outlive the assertions: an unconsumed one that
        // goes out of scope terminates, and termination stops the provider.
        withExtendedLifetime(stream) {}

    }

    @Test("An unreadable journal is set aside, never deleted, and resumes nothing")
    func unreadableJournal() async {
        let r = rig()
        r.journal.isUnreadable = true
        let stream = r.provider.start()
        await settle()
        #expect(r.journal.movedAside)
        #expect(!r.provider.state.isRunning)
        #expect(r.provider.payload.problem == .journalUnreadable)
        // The stream has to outlive the assertions: an unconsumed one that
        // goes out of scope terminates, and termination stops the provider.
        withExtendedLifetime(stream) {}

    }

    // MARK: - Clock and wake

    @Test("Waking after the deadline ends the session")
    func wakePastDeadline() async {
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.clock.advance(7_200)
        r.provider.systemDidWake()
        await settle()
        #expect(!r.provider.state.isRunning)
        #expect(!r.assertion.isHeld)
    }

    @Test("Waking before the deadline re-arms the backstop for what is left")
    func wakeBeforeDeadline() async {
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.clock.advance(600)
        r.provider.systemDidWake()
        #expect(r.assertion.isHeld)
        #expect(r.assertion.lastTimeout == 3_000 + KeepAwakeProvider.powerdMargin)
    }

    @Test("A clock stepped backwards leaves the session running, not dropped")
    func clockBackwards() async {
        // Insomnia's bug: a timer that fires early and silently returns never
        // re-arms, and the session simply never ends. The deadline is absolute,
        // so the answer is to re-check and re-arm, never to assume the firing
        // meant anything.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.clock.advance(-3_600)
        r.provider.clockDidChange()
        await settle()
        #expect(r.provider.state.isRunning)
        #expect(r.assertion.isHeld)

        r.clock.advance(7_200 + 3_600)
        r.provider.clockDidChange()
        await settle()
        #expect(!r.provider.state.isRunning, "it must still end once the time really passes")
    }

    // MARK: - Floors

    @Test("The battery floor ends a session on battery, not on power")
    func batteryFloor() async {
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.power.set(PowerSnapshot(percentage: 0.10, isCharging: false, isPluggedIn: false,
                                  isLowPower: false, timeRemaining: nil))
        await settle()
        #expect(!r.provider.state.isRunning)
        #expect(!r.assertion.isHeld)
    }

    @Test("Critical heat ends a session")
    func thermalFloor() async {
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.thermal.set(.critical)
        await settle()
        #expect(!r.provider.state.isRunning)
    }

    @Test("Nothing is watched while Ready or Finished")
    func noWatchersAtRest() async {
        // The feature is an extra: while it is not running it must cost
        // nothing, so the watchers belong to Running and to nothing else.
        let r = rig()
        #expect(!r.thermal.isWatching)
        _ = await r.provider.begin(minutes: 60)
        #expect(r.thermal.isWatching)
        await r.provider.end(reason: .endedByYou)
        #expect(!r.thermal.isWatching)
    }

    // MARK: - Regressions found in review

    @Test("A normal battery reading does not end the session")
    func batteryUnits() async {
        // `PowerSnapshot.percentage` is 0...1. Rounding it straight to an Int
        // made 80% into 1, under every floor worth having, so the first
        // unplugged reading ended the session. The old tests passed 80 and 10
        // and never saw it.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        for level in [1.0, 0.95, 0.80, 0.50, 0.16] {
            r.power.set(PowerSnapshot(percentage: level, isCharging: false,
                                      isPluggedIn: false, isLowPower: false,
                                      timeRemaining: nil))
            await settle()
            #expect(r.provider.state.isRunning, "\(level) should keep going")
        }
    }

    @Test("A session started below the floor ends at once, without waiting for a change")
    func floorsAtStart() async {
        // Waiting for a notification means a Mac already at 9% unplugged keeps
        // itself awake until something happens to move.
        let r = rig()
        r.power.set(PowerSnapshot(percentage: 0.09, isCharging: false, isPluggedIn: false,
                                  isLowPower: false, timeRemaining: nil))
        _ = await r.provider.begin(minutes: 60)
        await settle()
        #expect(!r.provider.state.isRunning)
        #expect(!r.assertion.isHeld)
    }

    @Test("A session started on an overheating Mac ends at once")
    func thermalAtStart() async {
        let r = rig()
        r.thermal.set(.critical)
        _ = await r.provider.begin(minutes: 60)
        await settle()
        #expect(!r.provider.state.isRunning)
    }

    @Test("Only a Finished card expires; Ready stays until the user leaves it")
    func onlyFinishedExpires() async {
        // Ready is a control somebody came looking for. Expiring it took the
        // card off screen twelve seconds after it appeared.
        let r = rig()
        #expect(r.provider.activityForTesting.expiresAfter == nil)
        _ = await r.provider.begin(minutes: 60)
        #expect(r.provider.activityForTesting.expiresAfter == nil)
        await r.provider.end(reason: .endedByYou)
        #expect(r.provider.activityForTesting.expiresAfter != nil)
    }

    @Test("A resume whose assertion is refused leaves no running record behind")
    func resumeRollback() async {
        // The write lands before the acquire is attempted. Leaving it there
        // would have the next launch resume a session that never started.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.clock.advance(600)
        await r.provider.end(reason: .endedByYou)

        r.assertion.refuses = true
        let resumed = await r.provider.resume()
        #expect(!resumed)
        #expect(!r.assertion.isHeld)
        #expect(r.journal.stored?.state == .ended, "no running record may be left")
        #expect(r.provider.payload.problem == .assertionRefused,
                "a refused assertion is not a failed save")
    }

    @Test("A clock change re-arms powerd's backstop, not only the app's timer")
    func clockRearmsBackstop() async {
        // powerd counts from when the assertion was taken. Moving the wall
        // clock moves the deadline relative to it, so a clock pushed forward
        // leaves powerd holding for hours past the end.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        #expect(r.assertion.lastTimeout == 3_600 + KeepAwakeProvider.powerdMargin)
        r.clock.advance(1_800)
        r.provider.clockDidChange()
        await settle()
        #expect(r.assertion.lastTimeout == 1_800 + KeepAwakeProvider.powerdMargin)
    }

    @Test("A deadline callback that fires early re-arms instead of giving up")
    func earlyCallbackRearms() async {
        // Returning without re-arming is how a session silently never ends.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.provider.deadlineTick()
        await settle()
        #expect(r.provider.state.isRunning)
        #expect(r.assertion.isHeld)

        r.clock.advance(3_601)
        r.provider.deadlineTick()
        await settle()
        #expect(!r.provider.state.isRunning, "it must still end when the time really passes")
    }

    @Test("An old stream's teardown cannot stop a newer session")
    func staleStreamTeardown() async {
        let r = rig()
        let first = r.provider.start()
        let consumer = Task { for await _ in first {} }
        await settle()
        _ = await r.provider.begin(minutes: 60)

        // The second start supersedes the first; tearing the first down must
        // not take the live session with it.
        let stream = r.provider.start()
        await settle()
        consumer.cancel()
        await settle()
        #expect(r.provider.state.isRunning)
        #expect(r.assertion.isHeld)
        // The stream has to outlive the assertions: an unconsumed one that
        // goes out of scope terminates, and termination stops the provider.
        withExtendedLifetime(stream) {}

    }

    // MARK: - What happens while a write is in the air

    // Every one of these is the same shape: the disk is slow, and something
    // else happens before it answers. An actor's `await` is a place another
    // operation can run, so anything decided before one has to be checked
    // again after it.

    @Test("A Start caught by Stop does not go on to acquire")
    func startCaughtByStop() async {
        let r = rig()
        r.journal.holdNextWrite()
        let starting = Task { await r.provider.begin(minutes: 60) }
        await settle()

        r.provider.stop()
        r.journal.releaseHeldWrite()
        let started = await starting.value

        #expect(!started)
        #expect(!r.assertion.isHeld, "a stopped provider must hold nothing")
        #expect(!r.provider.state.isRunning)
        // And the record it wrote must not outlive it as something to resume.
        #expect(r.journal.stored?.state != .running)
    }

    @Test("Two Starts in quick succession produce one session")
    func twoStarts() async {
        // Both passed a `state == .ready` check, because neither had changed
        // the state yet — the first was still waiting on the disk.
        let r = rig()
        r.journal.holdNextWrite()
        let first = Task { await r.provider.begin(minutes: 60) }
        await settle()

        // Asked for in a task and read through a box, because a refusal is
        // decided before any disk work: it must already have an answer by
        // here. A second Start that went to the journal instead would still
        // be in flight behind the held write, and the box would be empty —
        // asking for it directly would simply hang.
        let outcome = Answer()
        let secondTask = Task { await outcome.put(await r.provider.begin(minutes: 30)) }
        await settle()
        let second = await outcome.value
        #expect(second == false, "the second Start must be refused while the first is in flight")

        r.journal.releaseHeldWrite()
        let started = await first.value
        _ = await secondTask.value
        #expect(started)
        #expect(r.assertion.acquireCount == 1, "one session, one assertion")
        #expect(r.provider.state.session?.total == 3_600, "the first Start is the one that stands")
    }

    @Test("A retry queued behind a newer Start does not overwrite it")
    func retryBehindNewerStart() async {
        // Serialising the writes is not enough on its own: the retry's turn
        // comes *after* the newer one, so it has to be refused at the point of
        // writing rather than waved through in order.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.journal.failWrites = 1
        await r.provider.end(reason: .endedByYou)
        r.provider.dismiss()

        r.journal.holdNextWrite()
        let starting = Task { await r.provider.begin(minutes: 30) }
        await settle()
        let retrying = Task { await r.provider.retryTick() }
        await settle()

        r.journal.releaseHeldWrite()
        _ = await starting.value
        await retrying.value
        await settle()

        #expect(r.provider.state.isRunning)
        #expect(r.journal.stored?.id == "B")
        #expect(r.journal.stored?.state == .running,
                "the disk must agree with the session that is actually running")
        let writesForB = r.log.writes.filter { $0 == .journalWrite(.running, id: "B") }
        #expect(writesForB.count == 1,
                "the retry's turn came after the newer start — it must write nothing")
    }

    @Test("Done is not undone by the End that was still being written")
    func dismissDuringEnd() async {
        let r = rig()
        _ = await r.provider.begin(minutes: 60)

        r.journal.holdNextWrite()
        let ending = Task { await r.provider.end(reason: .endedByYou) }
        await settle()

        r.provider.dismiss()
        #expect(r.provider.state == .ready)

        r.journal.releaseHeldWrite()
        await ending.value
        await settle()

        #expect(r.provider.state == .ready, "the card must not come back after Done")
    }

    @Test("A cancelled Start the disk will not take back is tombstoned instead")
    func abandonedStartRefused() async {
        // The one combination that outlives the process: the file says a
        // session is running, this process let go of everything, and nothing
        // anywhere says the session is over. Without a tombstone the next
        // launch reads that record and resumes a session that never started.
        let r = rig()
        r.journal.holdNextWrite()
        r.journal.failWritesRecording = .ended
        let starting = Task { await r.provider.begin(minutes: 60) }
        await wait(for: { r.journal.writesWaiting == 1 }, "the start to reach the disk")

        r.provider.stop()
        r.journal.releaseHeldWrite()
        let started = await starting.value
        await settle()

        #expect(!started)
        #expect(!r.assertion.isHeld)
        #expect(r.journal.stored?.state == .running, "the start did land, and will not come off")
        #expect(r.tombstone.value == "A", "so the session has to be named as one not to resume")
    }

    @Test("A recovered End the disk refuses keeps the tombstone that stands in for it")
    func recoveryKeepsRefusedEndTombstone() async {
        // The tombstone is what made this record recoverable-as-ended in the
        // first place. Clearing it on the way out, while the write meant to
        // replace the record was refused, hands the next launch a running
        // record with nothing to contradict it.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let r = rig(stored: record(id: "A", state: .running, start: start,
                                   minutes: 60, boot: boot),
                    tombstone: "A")
        r.journal.failWrites = -1
        let stream = r.provider.start()
        await settle()

        #expect(!r.assertion.isHeld, "a tombstoned session is not resumed")
        #expect(r.journal.stored?.state == .running, "the disk refused the replacement")
        #expect(r.tombstone.value == "A", "the note saying not to resume it has to stay")
        withExtendedLifetime(stream) {}
    }

    @Test("A summary is not published into a provider that has stopped")
    func summaryAfterStopIsDropped() async {
        // Recovery checks who owns it after the read, and the check has to
        // cover every answer the read can give — not only the running one.
        let start = Date(timeIntervalSince1970: 1_000_000)
        var stored = record(id: "A", state: .running, start: start, minutes: 60, boot: boot)
        stored = stored.ended(.timeUp, at: start.addingTimeInterval(3_600), summaryPending: true)
        let r = rig(stored: stored)
        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "recovery to be reading the journal")

        r.provider.stop()
        r.journal.releaseHeldRead()
        await settle()

        #expect(r.provider.state == .ready, "a stopped provider has no card to show")
        #expect(r.log.writes.isEmpty, "and nothing to write about one")
        withExtendedLifetime(stream) {}
    }

    @Test("An End while a Start is still being written cancels it")
    func endCancelsPendingStart() async {
        // The state is still Ready while the start is on the disk, so an End
        // that only looks at the running session walks straight past it — and
        // the start it ignored goes on to take an assertion afterwards, for a
        // provider the user has just switched off, or an app that is quitting.
        let r = rig()
        r.journal.holdNextWrite()
        let starting = Task { await r.provider.begin(minutes: 60) }
        await wait(for: { r.journal.writesWaiting == 1 }, "the start to reach the disk")

        await r.provider.end(reason: .quit)
        r.journal.releaseHeldWrite()
        let started = await starting.value
        await settle()

        #expect(!started)
        #expect(!r.assertion.isHeld, "a cancelled start must not acquire anything")
        #expect(!r.provider.state.isRunning)
        #expect(r.journal.stored?.state != .running,
                "and must not leave the disk claiming a session is running")
    }

    @Test("An End while a Resume is still being written cancels it too")
    func endCancelsPendingResume() async {
        // Resume takes the same road as Start, so it has the same hole.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        await r.provider.end(reason: .endedByYou)

        r.journal.holdNextWrite()
        let resuming = Task { await r.provider.resume() }
        await wait(for: { r.journal.writesWaiting == 1 }, "the resume to reach the disk")

        await r.provider.end(reason: .quit)
        r.journal.releaseHeldWrite()
        let resumed = await resuming.value
        await settle()

        #expect(!resumed)
        #expect(!r.assertion.isHeld)
        #expect(r.journal.stored?.state != .running)
    }

    @Test("A quit cannot be undone by a start the disk was still holding")
    func cancelledPendingStartIsNamedForTheNextLaunch() async {
        // The record may already be on the disk when the End arrives, and a
        // quit is one of the reasons to be here — so the work that would take
        // it back may never run. The tombstone is the part that survives that.
        let r = rig()
        r.journal.holdNextWrite()
        let starting = Task { await r.provider.begin(minutes: 60) }
        await wait(for: { r.journal.writesWaiting == 1 }, "the start to reach the disk")

        await r.provider.end(reason: .quit)
        #expect(r.tombstone.value == "A",
                "named before the disk answers, because the answer may never come")
        r.journal.releaseHeldWrite()
        _ = await starting.value
    }

    @Test("A provider on its way out cannot overwrite its replacement's record")
    func oldProviderCannotOverwriteNew() async {
        // Switching Keep Awake off and on again builds a new provider while the
        // old one may still be waiting on the disk. Revisions counted per
        // provider start again at one, so the old provider's last write
        // outranked nothing, and replaced a running session with the end of one
        // nobody was running.
        let r = rig()
        r.journal.holdNextWrite()
        let old = Task { await r.provider.begin(minutes: 60) }
        await wait(for: { r.journal.writesWaiting == 1 }, "the old start to reach the disk")

        await r.provider.end(reason: .turnedOff)
        r.provider.stop()

        let assertionB = FakeSleepAssertion(log: r.log)
        let b = replacement(for: r, ids: ["B"], assertion: assertionB)
        // In a task, because the replacement's write queues behind the one
        // being held: one journal has one writer, which is the point.
        let submitted = Flag()
        let starting = Task {
            submitted.raise()
            return await b.begin(minutes: 60)
        }
        await wait(for: { submitted.isRaised }, "the replacement to have asked")

        r.journal.releaseHeldWrite()
        let startedA = await old.value
        let startedB = await starting.value
        await settle()

        #expect(startedB)
        #expect(!startedA)
        #expect(!r.assertion.isHeld, "the old provider holds nothing")
        #expect(assertionB.isHeld, "and the new one still does")
        #expect(r.journal.stored?.id == "B")
        #expect(r.journal.stored?.state == .running,
                "the disk must still describe the session that is running")
        b.stop()
    }

    @Test("Cancelling a Start that has already landed protects that start")
    func cancellingAfterTheWriteLandsProtectsIt() async {
        // The other side of the same uncertainty. Here B's write does reach the
        // disk, so the journal ends up holding B — and B is the session the
        // next launch must be told not to resume. Keeping only the older name
        // would lose exactly this case.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.journal.failWritesRecording = .ended
        await r.provider.end(reason: .endedByYou)
        r.provider.dismiss()

        r.journal.holdNextWrite()
        let starting = Task { await r.provider.begin(minutes: 60) }
        await wait(for: { r.journal.writesWaiting == 1 }, "B's start to reach the disk")
        await r.provider.end(reason: .quit)
        // Let it land after the cancellation, which is the ordering the
        // cancellation cannot see coming.
        r.journal.releaseHeldWrite()
        _ = await starting.value
        await settle()

        #expect(r.journal.stored?.id == "B", "the disk took B after all")
        #expect(r.tombstone.values.contains("B"),
                "so B is the one the next launch must not resume")
    }

    @Test("An end that finally lands spends the name standing in for it")
    func landedEndClearsTheNameItStoodIn() async {
        // The name exists because the journal would not take the end. Once it
        // does, the journal itself says the session is over and the name is
        // protecting a record that is no longer on the disk.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.journal.failWrites = 1
        await r.provider.end(reason: .endedByYou)
        #expect(r.journal.stored?.state == .running, "the end was refused")
        #expect(r.tombstone.values == ["A"], "so the name is standing in for it")

        await r.provider.retryTick()
        await settle()

        #expect(r.journal.stored?.state == .ended, "the retry landed")
        #expect(r.tombstone.values == [], "and the stand-in has nothing left to say")
    }

    @Test("Cancellations at capacity do not forget the session the disk is holding")
    func capacityNeverEvictsTheRecordedSession() async {
        // The list is bounded, and the bound used to be kept by dropping the
        // oldest name. Age says nothing about which name matters: the oldest
        // is as likely as any to be the one session the journal is still
        // holding, and dropping that one brings an ended session back.
        let r = rig(ids: (1 ... 20).map(String.init))
        _ = await r.provider.begin(minutes: 60)
        r.journal.failWritesRecording = .ended
        await r.provider.end(reason: .endedByYou)
        #expect(r.journal.stored?.id == "1", "the disk is holding session 1")
        #expect(r.tombstone.values == ["1"], "and only the name says it is over")
        r.provider.dismiss()

        // Nothing can reach the disk from here, and every start is cancelled
        // while its write is still waiting.
        r.journal.failWritesRecording = .running
        r.journal.holdNextWrite()
        var pending: [Task<Bool, Never>] = []
        for index in 0 ..< 10 {
            let asked = Flag()
            let start = Task {
                asked.raise()
                return await r.provider.begin(minutes: 60)
            }
            pending.append(start)
            await wait(for: { asked.isRaised }, "start \(index) to have asked")
            if index == 0 {
                await wait(for: { r.journal.writesWaiting == 1 }, "the first write to reach the disk")
            }
            await r.provider.end(reason: .quit)
        }

        let onDisk = r.journal.stored
        #expect(onDisk?.id == "1", "the disk never took anything else")
        #expect(r.tombstone.values.contains("1"),
                "so the name saying session 1 is over has to still be there")
        #expect(r.tombstone.values.count <= 8, "and the list is still bounded")

        r.journal.releaseHeldWrite()
        for start in pending { #expect(!(await start.value)) }
    }

    @Test("A start with nowhere to leave its name does not start")
    func startIsRefusedWhenThereIsNoRoom() async {
        // The alternative to forgetting a name is not starting the session
        // that would need one. Refusing is recoverable: one write landing
        // clears the list back to at most one name.
        let r = rig(tombstone: nil)
        r.tombstone.values = (1 ... 8).map(String.init)

        let started = await r.provider.begin(minutes: 60)

        #expect(!started)
        #expect(!r.assertion.isHeld, "and nothing is held for a session that did not start")
        #expect(r.journal.stored == nil, "nor written down")
        #expect(r.tombstone.values.count == 8, "and no name was spent to make room")
        if case .keepAwake(let payload) = r.provider.activityForTesting.payload {
            #expect(payload.problem == .tooManyUnsaved, "the card says why")
        } else {
            #expect(Bool(false), "the card should be saying something")
        }
    }

    @Test("An older write that lands does not drop a newer one still queued")
    func landedWriteKeepsQueuedNames() async {
        // Two cancelled starts, A ahead of B on the one writer. A's write
        // finishes first and used to say what the disk held — but B's write
        // was already admitted, and is the one that ends up on the disk. A
        // Mac that stops in that gap reads running(B) with nothing saying B
        // was cancelled.
        let r = rig()
        r.journal.holdWrites(for: "A")
        let first = Task { await r.provider.begin(minutes: 60) }
        await wait(for: { r.journal.writeReached("A") }, "A's write to reach the disk")
        await r.provider.end(reason: .quit)

        let asked = Flag()
        let second = Task {
            asked.raise()
            return await r.provider.begin(minutes: 60)
        }
        await wait(for: { asked.isRaised }, "B to have asked")
        await r.provider.end(reason: .quit)
        #expect(r.tombstone.values.contains("A") && r.tombstone.values.contains("B"))

        // B's record settles on the disk, and is held there unanswered.
        r.journal.holdAfterStoring("B")
        r.journal.releaseWrites(for: "A")
        await wait(for: { r.journal.isStored("B") }, "B's record to be on the disk")
        let startedA = await first.value

        #expect(!startedA)
        #expect(r.journal.stored?.id == "B")
        #expect(r.journal.stored?.state == .running)
        #expect(r.tombstone.values.contains("B"),
                "B is what the disk holds, so what says B is over has to still be there")
        #expect(!r.assertion.isHeld)

        r.journal.releaseAfterStoring("B")
        _ = await second.value
    }

    @Test("A landing end does not clear the names of writes still queued")
    func landedEndKeepsQueuedNames() async {
        // Same shape, with the older write recording an end. An ended record
        // cannot be resumed, so its own name goes — but that says nothing
        // about the cancelled start queued behind it.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.journal.failWrites = 1
        await r.provider.end(reason: .endedByYou)
        #expect(r.tombstone.values == ["A"], "A's end only exists as a name")
        r.provider.dismiss()

        // A's retry goes first and is held; B's start queues behind it on the
        // one writer, and is held in its turn so nothing moves while this is
        // being looked at.
        r.journal.holdWrites(for: "A")
        r.journal.holdWrites(for: "B")
        let retrying = Task { await r.provider.retryTick() }
        await wait(for: { r.journal.writeReached("A") }, "A's end to reach the disk")

        let asked = Flag()
        let second = Task {
            asked.raise()
            return await r.provider.begin(minutes: 60)
        }
        await wait(for: { asked.isRaised }, "B to have asked")
        await r.provider.end(reason: .quit)
        #expect(r.tombstone.values.contains("B"))

        // A's end lands. B has not been answered, and may still be the record.
        r.journal.releaseWrites(for: "A")
        await retrying.value
        await settle()

        #expect(r.journal.stored?.state == .ended, "A's end did land")
        #expect(r.tombstone.values.contains("B"),
                "the end that landed says nothing about the start behind it")

        r.journal.releaseWrites(for: "B")
        _ = await second.value
    }

    @Test("A replacement's queued write is not dropped by the provider it replaced")
    func replacementQueuedWriteKeepsItsName() async {
        // The two providers share one writer, which is the only thing that
        // knows about both of their writes.
        let r = rig()
        r.journal.holdWrites(for: "A")
        let first = Task { await r.provider.begin(minutes: 60) }
        await wait(for: { r.journal.writeReached("A") }, "A's write to reach the disk")
        await r.provider.end(reason: .quit)
        r.provider.stop()

        let assertionB = FakeSleepAssertion(log: r.log)
        let b = replacement(for: r, ids: ["B"], assertion: assertionB)
        let asked = Flag()
        let second = Task {
            asked.raise()
            return await b.begin(minutes: 60)
        }
        await wait(for: { asked.isRaised }, "the replacement to have asked")
        await b.end(reason: .quit)
        #expect(r.tombstone.values.contains("B"))

        r.journal.holdAfterStoring("B")
        r.journal.releaseWrites(for: "A")
        await wait(for: { r.journal.isStored("B") }, "B's record to be on the disk")
        // A positive barrier, not a number of turns: taking its own record
        // back is the first thing A does after pruning, so A asking the writer
        // a second time proves the pruning has already happened.
        await wait(for: { r.admissions.count(of: "A") == 2 },
                   "A to be taking its own record back")

        // Read while B's write is unanswered — the state a Mac stopping here
        // would be left in. A's task is deliberately not awaited yet: that
        // second write queues behind the one being held.
        let whileUnanswered = r.tombstone.values
        #expect(whileUnanswered.contains("B"),
                "the provider on its way out knows nothing about its replacement's queue")

        r.journal.releaseAfterStoring("B")
        _ = await first.value
        _ = await second.value
        b.stop()
    }

    @Test("A Start that failed is not left as the thing the retries will write")
    func failedStartIsNotRestoredAsSomethingToWrite() async {
        // Two starts fail in turn. The second captured the first's record on
        // the way past, and putting it back made a session that was cancelled
        // before it ever held anything into the thing the retries would write
        // — with nothing left naming it, because it never reached the disk.
        let r = rig()
        r.journal.failWritesRecording = .running
        r.journal.holdWrites(for: "A")
        let first = Task { await r.provider.begin(minutes: 60) }
        await wait(for: { r.journal.writeReached("A") }, "A's write to reach the disk")
        await r.provider.end(reason: .quit)

        let asked = Flag()
        let second = Task {
            asked.raise()
            return await r.provider.begin(minutes: 60)
        }
        await wait(for: { asked.isRaised }, "B to have asked")
        await r.provider.end(reason: .quit)

        r.journal.releaseWrites(for: "A")
        #expect(!(await first.value))
        #expect(!(await second.value))
        await settle()

        // Nothing landed, so nothing should be waiting to be written either.
        r.journal.failWritesRecording = nil
        await r.provider.retryTick()
        await settle()

        #expect(r.journal.stored?.state != .running,
                "a session nobody started must not be written down as running")
        #expect(!r.assertion.isHeld)
    }

    @Test("An unreadable journal does not take a record written while it was being read")
    func quarantineDoesNotTakeTheNewRecord() async {
        // Putting the file aside used to be a second trip to the disk, and it
        // waited its turn like anything else. A start queued behind the failed
        // read had its perfectly good record moved aside instead — and was
        // left holding an assertion nothing would ever find.
        let r = rig()
        r.journal.isUnreadable = true
        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "recovery to be reading")

        // Queued behind the read, so it reaches the disk between the read
        // failing and anything that might follow it.
        let asked = Flag()
        let starting = Task {
            asked.raise()
            return await r.provider.begin(minutes: 60)
        }
        await wait(for: { asked.isRaised }, "the start to have asked")
        // The read stays unreadable: the quarantine has to actually happen,
        // or this proves nothing about what it takes with it.
        r.journal.releaseHeldRead()
        let started = await starting.value
        await settle()

        #expect(r.journal.movedAside, "the file that could not be read was put aside")
        #expect(started)
        #expect(r.journal.stored?.state == .running,
                "and the record the start wrote afterwards is still there")
        #expect(r.assertion.isHeld, "with the session it belongs to running")
        withExtendedLifetime(stream) {}
    }

    @Test("An End names its session before it waits on the disk")
    func endNamesItsSessionBeforeWriting() async {
        // The assertion is released first and the record still says running,
        // so the window between the two is one a Mac can stop in.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.journal.holdWrites(for: "A")
        let ending = Task { await r.provider.end(reason: .endedByYou) }
        // The second write for this session: the first was the start.
        await wait(for: { r.journal.writeAttempts(for: "A") == 2 }, "the end to reach the disk")

        #expect(!r.assertion.isHeld, "nothing is held any more")
        #expect(r.journal.stored?.state == .running, "but the disk still says running")
        #expect(r.tombstone.values.contains("A"),
                "so something has to be saying the session is over")

        r.journal.releaseWrites(for: "A")
        await ending.value
        await settle()
        #expect(r.journal.stored?.state == .ended)
        #expect(r.tombstone.values == [], "and the name goes once the disk agrees")
    }

    @Test("Two providers cannot both take the last place on the list")
    func twoProvidersCannotShareTheLastPlace() async {
        // The names are shared, so the room for them has to be counted the
        // same way — including the starts that have not been answered yet.
        let r = rig(ids: ["A"])
        r.tombstone.values = (1 ... 7).map(String.init)
        r.journal.holdWrites(for: "A")
        let asked = Flag()
        let first = Task {
            asked.raise()
            return await r.provider.begin(minutes: 60)
        }
        await wait(for: { r.journal.writeReached("A") }, "A's write to reach the disk")

        let assertionB = FakeSleepAssertion(log: r.log)
        let b = replacement(for: r, ids: ["B"], assertion: assertionB)
        // Asked in a task and read through a box: a refusal is decided before
        // any disk work, so it must already have an answer here. A start that
        // was let through instead would be queued behind the held write, and
        // asking for it directly would simply hang.
        let outcome = Answer()
        let startingB = Task { await outcome.put(await b.begin(minutes: 60)) }
        await settle()
        let startedB = await outcome.value

        #expect(asked.isRaised)
        #expect(startedB == false, "A has not been answered, and may still need the last place")
        #expect(!assertionB.isHeld)

        r.journal.releaseWrites(for: "A")
        _ = await first.value
        _ = await startingB.value
        b.stop()
    }

    @Test("Recovery stands down when an End cancels the Start it was racing")
    func recoveryYieldsToAnEndOfAPendingStart() async {
        // An End that cancels a Start still being written changes no state —
        // Ready before, Ready after — so nothing recovery looks at would move.
        // It went on to acquire the old session, and the cancelled Start's
        // cleanup then wrote an end over it: an assertion held for a session
        // the journal says is over.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let r = rig(stored: record(id: "old", state: .running, start: start,
                                   minutes: 60, boot: boot),
                    ids: ["A"])
        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "recovery to be reading")

        let asked = Flag()
        let starting = Task {
            asked.raise()
            return await r.provider.begin(minutes: 30)
        }
        await wait(for: { asked.isRaised }, "the start to have asked")
        // In a task: an End arriving before recovery has spoken now waits for
        // it, because the session recovery is about to find is one the End is
        // meant to cover.
        let ending = Task { await r.provider.end(reason: .quit) }
        await settle()

        r.journal.releaseHeldRead()
        await ending.value
        _ = await starting.value
        await settle()

        #expect(!r.assertion.isHeld, "nothing may be held after an explicit End")
        #expect(!r.provider.state.isRunning)
        withExtendedLifetime(stream) {}
    }

    @Test("Recovery stands down when the session it was reading about has ended")
    func recoveryYieldsToAnEndDuringItsRead() async {
        // The slow read's answer is about a world that has moved on.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let r = rig(stored: record(id: "old", state: .running, start: start,
                                   minutes: 60, boot: boot),
                    ids: ["A"])
        _ = await r.provider.begin(minutes: 30)
        #expect(r.assertion.isHeld)

        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "recovery to be reading")

        let ending = Task { await r.provider.end(reason: .endedByYou) }
        await wait(for: { !r.provider.state.isRunning }, "the session to have ended")
        r.journal.releaseHeldRead()
        await ending.value
        await settle()

        #expect(!r.assertion.isHeld, "recovery must not take back what End let go")
        withExtendedLifetime(stream) {}
    }

    @Test("Names left over from a crash are reclaimed on the next launch")
    func recoveryReclaimsNamesProtectingNothing() async {
        // Stopping between an end landing and its name being taken away left
        // a list that protected nothing and refused every new session — on a
        // disk that was working perfectly.
        let start = Date(timeIntervalSince1970: 1_000_000)
        var ended = record(id: "old", state: .running, start: start, minutes: 60, boot: boot)
        ended = ended.ended(.timeUp, at: start.addingTimeInterval(3_600), summaryPending: false)
        let r = rig(stored: ended, ids: ["A"])
        r.tombstone.values = (1 ... 8).map(String.init)

        let stream = r.provider.start()
        await settle()

        #expect(r.tombstone.values == [],
                "nothing on that list can be the record the disk is holding")
        let started = await r.provider.begin(minutes: 60)
        #expect(started, "so a new session is free to start again")
        withExtendedLifetime(stream) {}
    }

    @Test("Switching off before recovery has spoken ends what it was about to find")
    func endBeforeRecoveryEndsTheRecoveredSession() async {
        // Nothing is running yet, so there was nothing for End to end — and it
        // returned, leaving the record on the disk for this recovery, or the
        // next launch, to pick up again. The user had switched it off.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let r = rig(stored: record(id: "old", state: .running, start: start,
                                   minutes: 60, boot: boot))
        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "recovery to be reading")

        let ending = Task { await r.provider.end(reason: .turnedOff) }
        await settle()
        r.journal.releaseHeldRead()
        await ending.value
        await settle()

        #expect(!r.assertion.isHeld, "nothing may be acquired for a session switched off")
        #expect(!r.provider.state.isRunning)
        #expect(r.journal.stored?.state == .ended,
                "and the disk has to say so, for the launch after this one")
        withExtendedLifetime(stream) {}
    }

    @Test("A Start refused for want of room does not stop recovery tidying up")
    func refusedStartDoesNotSuppressRecovery() async {
        // The refusal and the tidying are about the same thing — the list
        // being full — and the tidying is what empties it. Counting a refused
        // Start as a command told recovery to stand down, so the list stayed
        // full and every later Start was refused too.
        let start = Date(timeIntervalSince1970: 1_000_000)
        var ended = record(id: "old", state: .running, start: start, minutes: 60, boot: boot)
        ended = ended.ended(.timeUp, at: start.addingTimeInterval(3_600), summaryPending: false)
        let r = rig(stored: ended, ids: ["A", "B"])
        r.tombstone.values = (1 ... 8).map(String.init)

        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "recovery to be reading")

        let refused = await r.provider.begin(minutes: 60)
        #expect(!refused, "there is nowhere to leave this session's name")

        r.journal.releaseHeldRead()
        await settle()

        #expect(r.tombstone.values == [], "recovery still had its tidying to do")
        let started = await r.provider.begin(minutes: 60)
        #expect(started, "and afterwards there is room again")
        withExtendedLifetime(stream) {}
    }

    @Test("An End that was asked for is honoured even if recovery stands down")
    func endIsHonouredWhenRecoveryStandsDown() async {
        // The guards decide whether this provider still gets to act. They do
        // not decide whether the session is still meant to end — and when
        // recovery returned early the record stayed on the disk, unnamed, for
        // a replacement provider to pick up and resume.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let r = rig(stored: record(id: "old", state: .running, start: start,
                                   minutes: 60, boot: boot))
        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "recovery to be reading")

        let ending = Task { await r.provider.end(reason: .turnedOff) }
        await settle()
        r.provider.stop()
        r.journal.releaseHeldRead()
        await ending.value
        await settle()

        #expect(r.tombstone.values.contains("old"),
                "the session the End was for has to be named, whatever recovery did")

        // What a replacement makes of what is left.
        let assertionB = FakeSleepAssertion(log: r.log)
        let b = replacement(for: r, ids: ["B"], assertion: assertionB)
        let next = b.start()
        await settle()
        #expect(!assertionB.isHeld, "and nothing may pick it up again")
        b.stop()
        withExtendedLifetime((stream, next)) {}
    }

    @Test("A full list does not stop an End protecting what it was for")
    func endProtectsEvenWhenTheListLooksFull()  async {
        // The names and the room for them are the same shared thing, so the
        // tidying has to come first. Adding before reclaiming meant a list
        // full of names protecting nothing refused the one name that was
        // actually needed — and the End completed anyway, leaving the record
        // on the disk for a replacement to pick up.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let r = rig(stored: record(id: "old", state: .running, start: start,
                                   minutes: 60, boot: boot))
        r.tombstone.values = (1 ... 8).map(String.init)

        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "recovery to be reading")
        let ending = Task { await r.provider.end(reason: .turnedOff) }
        await settle()
        r.provider.stop()
        r.journal.releaseHeldRead()
        await ending.value
        await settle()

        #expect(r.tombstone.values == ["old"],
                "the names protecting nothing make room for the one that does")
        withExtendedLifetime(stream) {}
    }

    @Test("An older provider's End does not touch a record its replacement wrote")
    func olderEndLeavesANewerOwnersSessionAlone() async {
        // The provider on its way out is reading about a session its
        // replacement started. Naming it, or ending it, ends a session nobody
        // asked to end — and the next provider along reads the name and
        // finishes it off.
        let r = rig(ids: ["A"])
        let assertionB = FakeSleepAssertion(log: r.log)
        let b = replacement(for: r, ids: ["B"], assertion: assertionB)
        #expect(await b.begin(minutes: 60))
        #expect(r.journal.stored?.id == "B")

        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "the older recovery to be reading")
        let ending = Task { await r.provider.end(reason: .turnedOff) }
        await settle()
        r.journal.releaseHeldRead()
        await ending.value
        await settle()

        #expect(assertionB.isHeld, "the replacement's session is still running")
        #expect(r.tombstone.values == [], "and nothing says it is over")
        #expect(r.journal.stored?.id == "B")
        #expect(r.journal.stored?.state == .running)
        b.stop()
        withExtendedLifetime(stream) {}
    }

    @Test("A Start that failed does not cost an End the protection it was owed")
    func failedStartDoesNotDiscardEndProtection() async {
        // What matters is whether anything actually reached the disk since the
        // End was asked for. A Start that was attempted and refused changes
        // nothing — treating it as a newer command left the old record
        // unnamed, and the next provider along resumed it.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let r = rig(stored: record(id: "old", state: .running, start: start,
                                   minutes: 60, boot: boot),
                    ids: ["A"])
        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "recovery to be reading")
        let ending = Task { await r.provider.end(reason: .turnedOff) }
        await settle()

        // A Start the disk will refuse, submitted behind the held read.
        r.journal.failWritesRecording = .running
        let asked = Flag()
        let starting = Task {
            asked.raise()
            return await r.provider.begin(minutes: 30)
        }
        await wait(for: { asked.isRaised }, "the start to have asked")

        r.journal.releaseHeldRead()
        #expect(!(await starting.value), "the disk refused it")
        await ending.value
        await settle()

        #expect(r.tombstone.values.contains("old"),
                "nothing landed, so the End is still owed its protection")

        let assertionB = FakeSleepAssertion(log: r.log)
        let b = replacement(for: r, ids: ["B"], assertion: assertionB)
        let next = b.start()
        await settle()
        #expect(!assertionB.isHeld, "and nothing picks the old session up again")
        b.stop()
        withExtendedLifetime((stream, next)) {}
    }

    @Test("Recovery does not acquire a record a newer provider has replaced")
    func recoveryStandsDownWhenTheDiskMovedUnderIt() async {
        // The read says who owned the file when it ran. By the time this
        // continuation gets its turn on the main actor, a newer provider's
        // write can have landed — and acquiring on the strength of the older
        // answer leaves two assertions held for one Mac, with the journal
        // describing only one of them.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let r = rig(stored: record(id: "old", state: .running, start: start,
                                   minutes: 60, boot: boot),
                    ids: ["A"])
        r.journal.holdNextRead()
        let stream = r.provider.start()
        await wait(for: { r.journal.readsWaiting == 1 }, "the older recovery to be reading")

        let assertionB = FakeSleepAssertion(log: r.log)
        let b = replacement(for: r, ids: ["B"], assertion: assertionB)
        let asked = Flag()
        let startingB = Task {
            asked.raise()
            return await b.begin(minutes: 60)
        }
        await wait(for: { asked.isRaised }, "the newer start to have asked")
        await wait(for: { r.writer.admittedSessionIDs().contains("B") },
                   "the newer start's write to be with the writer")

        r.journal.releaseHeldRead()
        #expect(await startingB.value)
        await settle()

        #expect(!r.assertion.isHeld, "the older recovery holds nothing")
        #expect(assertionB.isHeld, "the newer session holds its own")
        #expect(r.journal.stored?.id == "B")

        await b.end(reason: .endedByYou)
        await settle()
        #expect(!assertionB.isHeld)
        #expect(!r.assertion.isHeld, "and ending it leaves nothing behind")
        b.stop()
        withExtendedLifetime(stream) {}
    }

    @Test("A write that lands leaves only the name still protecting something")
    func landedWritePrunesTheNames() async {
        // A name protects one record: it tells the next launch not to resume
        // the session the journal is holding. Once a write has landed, the
        // journal holds that session and nothing else, so every other name on
        // the list is protecting a record that is no longer there.
        let r = rig(tombstone: "stale")
        _ = await r.provider.begin(minutes: 60)
        await settle()

        #expect(r.journal.stored?.id == "A")
        #expect(r.tombstone.values == [],
                "a name for a record the disk no longer holds protects nothing")

        await r.provider.end(reason: .endedByYou)
        await settle()
        #expect(r.tombstone.values == [], "and an ended record cannot be resumed by anybody")
    }

    @Test("Cancelling a Start does not unseat the name an earlier End is relying on")
    func cancellingKeepsAnEarlierEndsName() async {
        // End A is refused by the journal and falls back to the name. B then
        // starts, and is cancelled while its write is in the air — so from
        // here there is no telling whether the disk holds A or B. Naming only
        // B hands a Mac that stops here a journal saying A is running with
        // nothing to contradict it, and A was explicitly ended.
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        r.journal.failWritesRecording = .ended
        await r.provider.end(reason: .endedByYou)
        #expect(r.journal.stored?.state == .running, "the end did not reach the disk")
        #expect(r.tombstone.values == ["A"], "so the name is standing in for it")
        r.provider.dismiss()

        r.journal.holdNextWrite()
        let starting = Task { await r.provider.begin(minutes: 60) }
        await wait(for: { r.journal.writesWaiting == 1 }, "B's start to reach the disk")
        await r.provider.end(reason: .quit)

        // Exactly what a Mac that stopped here would read back.
        let onDisk = r.journal.stored
        #expect(onDisk?.id == "A")
        let names = r.tombstone.values
        #expect(names.contains("A"), "A is still named")
        #expect(names.contains("B"), "and so is the session that never started")

        r.journal.releaseHeldWrite()
        let started = await starting.value
        #expect(!started)
    }

    @Test("A session recovered from the journal arrives, and is worth announcing")
    func recoveredSessionAnnounces() async {
        // Publishing Ready first and correcting it to Running made the resumed
        // session an update to a card that already existed, and only arrivals
        // are announced — so it came back in silence.
        let start = Date(timeIntervalSince1970: 1_000_000)
        let r = rig(stored: record(id: "A", state: .running, start: start,
                                   minutes: 60, boot: boot))
        let seen = Published()
        let stream = r.provider.start()
        let consumer = Task {
            for await event in stream {
                if case .publish(let activity) = event { await seen.add(activity) }
            }
        }
        await settle()

        let first = await seen.first
        #expect(first != nil, "something must be published")
        if case .keepAwake(let payload)? = first?.payload {
            #expect(payload.phase == .running, "the first card the notch sees is the running one")
            #expect(payload.resumed)
        } else {
            #expect(Bool(false), "the first publish should be a Keep Awake card")
        }
        #expect(first?.isWorthAnnouncing == true)
        consumer.cancel()
        // The stream has to outlive the assertions: an unconsumed one that
        // goes out of scope terminates, and termination stops the provider.
        withExtendedLifetime(stream) {}

    }

    // MARK: - Resume

    @Test("Resume keeps the original deadline and takes the assertion again")
    func resume() async {
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        let deadline = r.provider.state.session?.deadline
        r.clock.advance(600)
        await r.provider.end(reason: .endedByYou)
        #expect(r.provider.payload.resumable == 3_000)

        let outcome3 = await r.provider.resume()
        #expect(outcome3)
        #expect(r.assertion.isHeld)
        #expect(r.provider.state.session?.deadline == deadline)
        #expect(r.provider.state.session?.id == "B", "a new record, so A's end stands")
    }

    @Test("Resume is not offered for an end the user did not choose")
    func noResumeAfterFloor() async {
        let r = rig()
        _ = await r.provider.begin(minutes: 60)
        await r.provider.end(reason: .batteryFloor)
        #expect(r.provider.payload.resumable == nil)
        let outcome4 = await r.provider.resume()
        #expect(!outcome4)
    }

    // MARK: - Summaries

    @Test("A session that ends with no notch panel keeps its summary for later")
    func summaryPending() async {
        let r = rig(hasNotchPanel: false)
        _ = await r.provider.begin(minutes: 60)
        await r.provider.end(reason: .timeUp)
        #expect(r.journal.stored?.summaryPending == true)

        // The next launch shows it once, then clears the flag.
        let again = rig(stored: r.journal.stored)
        let stream = again.provider.start()
        await settle()
        guard case .finished(let finish) = again.provider.state else {
            return #expect(Bool(false), "the summary should be shown")
        }
        #expect(finish.reason == .timeUp)
        #expect(again.journal.stored?.summaryPending == false)
        // The stream has to outlive the assertions: an unconsumed one that
        // goes out of scope terminates, and termination stops the provider.
        withExtendedLifetime(stream) {}

    }
}


/// Collects what a provider published, from whichever task is consuming it.
/// Counts what the writer has been asked to write, per session.
///
/// Lives here rather than in the writer: only a test needs to know that a
/// session has asked a second time, and the app has no business remembering
/// every session it ever had in order to tell one.
final class AdmissionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func note(_ id: String) { lock.withLock { counts[id, default: 0] += 1 } }
    func count(of id: String) -> Int { lock.withLock { counts[id] ?? 0 } }
}

/// A one-way switch, for waiting on a task having got as far as asking.
@MainActor
private final class Flag {
    private(set) var isRaised = false
    func raise() { isRaised = true }
}

/// Somewhere to leave an answer that may never arrive, so a test can ask
/// whether it has without waiting for it.
private actor Answer {
    private var answer: Bool?
    func put(_ value: Bool) { answer = value }
    var value: Bool? { answer }
}

private actor Published {
    private var activities: [Activity] = []
    func add(_ activity: Activity) { activities.append(activity) }
    var first: Activity? { activities.first }
    var count: Int { activities.count }
}
