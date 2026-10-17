import Foundation
import Testing

@testable import LedgeCore
@testable import LedgeProviders
@testable import LedgeSystem

/// Swapping one kind of hold for the other, without letting go of the Mac.
///
/// The shell used to do this with `end` then `begin`. Both halves were broken
/// and the reviewer's probe printed each one: `begin` refuses outright while a
/// session runs, so switching the lid mode *on* over a plain hold silently did
/// nothing; and `end` releases the assertion before it waits on the disk, so
/// switching it *off* left the Mac unprotected for as long as the disk took —
/// and, if the replacement was then refused, left both modes off while the
/// card said "nothing changed".
@Suite("Changing between the two kinds of hold", .serialized)
@MainActor
struct KeepAwakeModeChangeTests {

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

    /// Spins until a condition holds, for the work the provider posts to the
    /// main actor rather than awaits.
    private func wait(for condition: @MainActor () -> Bool,
                      _ what: Comment, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0 ..< 2_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func rig(ids: [String] = ["A", "B", "C"]) -> Rig {
        let log = KeepAwakeLog()
        let clock = TestClock()
        let assertion = FakeSleepAssertion(log: log)
        let journal = MemoryKeepAwakeJournal(log: log, stored: nil)
        let admissions = AdmissionCounter()
        let stone = MemoryTombstone(log: log, value: nil)
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
            bootID: "boot-A",
            hasNotchPanel: { true },
            makeID: { queue.isEmpty ? UUID().uuidString : queue.removeFirst() },
            formatTime: { _ in "17:40" }
        )
        return Rig(provider: provider, log: log, assertion: assertion, journal: journal,
                   writer: writer, admissions: admissions, tombstone: stone, clock: clock,
                   power: power, thermal: thermal)
    }

    // MARK: - On, over a hold that is already running

    @Test("Switching the lid mode on over a plain hold actually starts it")
    func plainToLid() async {
        // The ordinary sequence the two-switch card invites, and the one
        // `begin` refused: its guard wants Ready, and a running session is not.
        let r = rig()
        #expect(await r.provider.begin())
        #expect(r.provider.state.session?.lidHoldRequested == false)

        let outcome = await r.provider.changeMode(toLidClosed: 45)
        #expect(outcome == .changed)
        #expect(r.provider.state.session?.lidHoldRequested == true,
                "the lid mode was asked for and the session is still plain")
        #expect(r.provider.state.session?.deadline != nil, "a lid-closed hold always has an end")
    }

    @Test("The Mac is never let go of while the mode changes")
    func theHoldIsContinuous() async {
        // The assertion is the Mac staying awake. `end`-then-`begin` released
        // it and then went to the disk; this must never drop it at all.
        let r = rig()
        #expect(await r.provider.begin())
        #expect(r.assertion.isHeld)
        // Every release the fake has ever seen, so a release-and-retake cannot
        // hide inside a final `isHeld == true`.
        let releasesBefore = r.assertion.releaseCount

        _ = await r.provider.changeMode(toLidClosed: 45)
        #expect(r.assertion.isHeld, "the Mac was let go of during the change")
        #expect(r.assertion.releaseCount == releasesBefore,
                "the assertion was released and retaken — that gap is the bug")

        _ = await r.provider.changeMode(toLidClosed: nil)
        #expect(r.assertion.isHeld)
        #expect(r.assertion.releaseCount == releasesBefore)
    }

    @Test("The hold keeps the moment it started")
    func elapsedTimeSurvives() async {
        // Three hours awake must not become none because the lid switch moved.
        let r = rig()
        #expect(await r.provider.begin())
        let started = r.provider.state.session?.startedAt
        r.clock.advance(3 * 3600)

        _ = await r.provider.changeMode(toLidClosed: 60)
        #expect(r.provider.state.session?.startedAt == started,
                "the replacement restarted the clock on a hold that never stopped")
    }

    // MARK: - Off, back to a plain hold

    @Test("Switching the lid mode off keeps the Mac awake")
    func lidToPlain() async {
        let r = rig()
        #expect(await r.provider.begin(minutes: 60, lidClosed: true))
        #expect(r.assertion.isHeld)

        let outcome = await r.provider.changeMode(toLidClosed: nil)
        #expect(outcome == .changed)
        #expect(r.provider.state.isRunning, "turning the smaller setting off must not sleep the Mac")
        #expect(r.provider.state.session?.lidHoldRequested == false)
        #expect(r.provider.state.session?.deadline == nil,
                "a plain hold runs until it is switched off")
        #expect(r.assertion.isHeld)
    }

    // MARK: - Refusals

    @Test("A disk that refuses the replacement leaves the hold that was running")
    func refusedWriteKeepsTheHold() async {
        // The failure the old sequence handled worst: it had already ended the
        // session before finding out, so a refusal left both modes off while
        // the card said nothing had changed.
        let r = rig()
        #expect(await r.provider.begin())
        let before = r.provider.state.session?.id

        r.journal.failWrites = 1
        let outcome = await r.provider.changeMode(toLidClosed: 45)
        #expect(outcome == .refused)
        #expect(r.provider.state.isRunning, "a refused change must not end the hold")
        #expect(r.provider.state.session?.id == before, "the session that was running is still it")
        #expect(r.provider.state.session?.lidHoldRequested == false)
        #expect(r.assertion.isHeld, "and the Mac is still being kept awake")
        #expect(r.provider.payload.problem == .startNotSaved, "and the user is told why")
    }

    @Test("Nothing running is reported as such rather than quietly starting one")
    func nothingToChange() async {
        // The shell starts a session on this answer. Doing it here instead
        // would make a mode change into a way of switching Keep Awake on.
        let r = rig()
        #expect(await r.provider.changeMode(toLidClosed: 45) == .nothingRunning)
        #expect(!r.provider.state.isRunning)
        #expect(!r.assertion.isHeld)
    }

    @Test("Asking for the mode it is already in changes nothing")
    func alreadyThere() async {
        let r = rig()
        #expect(await r.provider.begin())
        let before = r.provider.state.session?.id
        #expect(await r.provider.changeMode(toLidClosed: nil) == .alreadyThere)
        #expect(r.provider.state.session?.id == before, "the session was replaced for no reason")

        _ = await r.provider.changeMode(toLidClosed: 30)
        let lidSession = r.provider.state.session?.id
        #expect(await r.provider.changeMode(toLidClosed: 90) == .changed,
                "a different length is a change, even in the same mode")
        #expect(r.provider.state.session?.id != lidSession)
    }

    // MARK: - Things arriving at once

    @Test("Off during a mode change stays off")
    func endBeatsAChangeInFlight() async {
        // The reviewer's sequence. A runs; the replacement's record reaches
        // the disk; the user presses Off, which releases A; then the write
        // returns. `end` used to cancel a start in flight only when nothing
        // was running, on the reasoning that nothing can be waiting on the
        // disk while a session runs — true until a mode change, which writes
        // a replacement while the old session is still running. Keep Awake
        // switched itself back on over a card reading Finished.
        let r = rig()
        #expect(await r.provider.begin())

        r.journal.holdWrites(for: "B")
        let changing = Task { await r.provider.changeMode(toLidClosed: 45) }
        await wait(for: { r.admissions.count(of: "B") >= 1 }, "the replacement to reach the disk")

        // Started rather than awaited, and the disk let go from here: `end`
        // releases the Mac synchronously and *then* goes to the disk, which
        // is blocked by the same held write. Awaiting it first would deadlock
        // the test rather than test anything.
        let ending = Task { await r.provider.end(reason: .endedByYou) }
        await wait(for: { !r.assertion.isHeld }, "Off to release the Mac")

        r.journal.releaseWrites(for: "B")
        await ending.value
        #expect(await changing.value == .refused)

        #expect(!r.provider.state.isRunning, "Off must stay off")
        #expect(!r.assertion.isHeld, "and nothing may take the Mac back")
        #expect(r.journal.stored?.state == .ended,
                "the disk must not be left holding a session nobody is running")

        // And the provider is usable afterwards. The guard that refuses the
        // replacement does not clear `pendingStart` — only the End does — so
        // without that clearing, the token stays set for ever and every later
        // start and change is refused. Keep Awake could never be switched on
        // again for the life of the app, and nothing above would have noticed.
        r.provider.dismiss()
        #expect(await r.provider.begin(), "the card must still be able to start a session")
        #expect(r.assertion.isHeld)
    }

    @Test("A second change while one is in flight is refused, not queued")
    func noOverlappingChanges() async {
        // Two overlapping changes both wrote, both returned refused, and left
        // the journal holding a lid session the provider was not running —
        // which the next launch would resume. A second press is a press at a
        // card that has not finished answering the first.
        let r = rig()
        #expect(await r.provider.begin())

        r.journal.holdWrites(for: "B")
        let first = Task { await r.provider.changeMode(toLidClosed: 45) }
        await wait(for: { r.admissions.count(of: "B") >= 1 }, "the first replacement")

        #expect(await r.provider.changeMode(toLidClosed: 90) == .refused,
                "a change must not start while one is still in the air")
        // Refused before the disk, not after it. A second change that writes
        // and is then discarded is the case that left the journal holding a
        // session the provider was not running.
        #expect(r.admissions.count(of: "C") == 0,
                "a refused change must not reach the disk at all")
        #expect(r.provider.state.session?.id == "A",
                "and must not disturb the session that is running")

        r.journal.releaseWrites(for: "B")
        #expect(await first.value == .changed)
        #expect(r.provider.state.session?.lidHoldRequested == true)
        #expect(r.journal.stored?.id == r.provider.state.session?.id,
                "the disk names the session that is actually running")
    }

    @Test("A refused assertion fails the change rather than claiming it worked")
    func refusedAssertionFailsSafely() async {
        // `acquire` on a held assertion re-arms, so a refusal here means the
        // Mac was not being held before the call either. Committing anyway
        // published a card reading On over a Mac free to sleep, with the old
        // session's backstop still in force.
        let r = rig()
        #expect(await r.provider.begin())
        // Refused with the old assertion still held, which is the case the
        // first version of this test assumed away by releasing it by hand.
        // The two are separate calls to IOKit and only the second can fail,
        // so this is the shape production actually produces — and the shape
        // that left a Mac awake with a card reading Off.
        r.assertion.refuses = true
        #expect(r.assertion.isHeld, "the premise: the Mac is still held when the re-arm fails")

        #expect(await r.provider.changeMode(toLidClosed: 45) == .refused)
        #expect(!r.assertion.isHeld,
                "a card in Ready over a held assertion is a Mac nothing can let go of")
        #expect(!r.provider.state.isRunning, "a Mac that is not held must not read as running")
        #expect(r.provider.payload.problem == .assertionRefused, "and the user is told why")
        #expect(r.journal.stored?.state != .running || r.journal.stored?.id == nil,
                "nothing may be left on the disk to resume")
    }

    // MARK: - What the card is then told

    @Test("The card is told the new mode, and the old session is not on the disk")
    func whatLands() async {
        let r = rig()
        #expect(await r.provider.begin())
        _ = await r.provider.changeMode(toLidClosed: 45)

        #expect(r.provider.payload.lidClosed, "the card must show which mode is running")
        #expect(!r.provider.payload.isIndefinite)
        #expect(r.journal.stored?.state == .running)
        #expect(r.journal.stored?.id == r.provider.state.session?.id,
                "the disk still names the session that was replaced")
    }
}
