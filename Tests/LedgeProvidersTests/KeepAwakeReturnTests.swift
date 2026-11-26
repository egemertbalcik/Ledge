import Foundation
import Testing

@testable import LedgeCore
@testable import LedgeProviders
@testable import LedgeSystem

/// Espresso picked while Coffee was on used to end in the Mac being free to
/// sleep: the Coffee it replaced was forgotten the moment it was replaced.
/// Its time running out now goes back to Coffee. Picked from Off, it still
/// ends in Off.
@Suite("A timed hold goes back to what was on before it", .serialized, .timeLimit(.minutes(10)))
@MainActor
struct KeepAwakeReturnTests {

    private struct Rig {
        let provider: KeepAwakeProvider
        let assertion: FakeSleepAssertion
        let journal: MemoryKeepAwakeJournal
        let clock: TestClock
    }

    private func wait(for condition: @MainActor () -> Bool,
                      _ what: Comment, sourceLocation: SourceLocation = #_sourceLocation) async {
        // By the wall clock and not by a count of sleeps, which runs out
        // early when the main thread is held.
        let limit = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < limit, (try? await Task.sleep(for: .milliseconds(1))) != nil else {
                Issue.record("gave up waiting for \(what)", sourceLocation: sourceLocation)
                return
            }
        }
    }

    private func rig() -> Rig {
        let log = KeepAwakeLog()
        let clock = TestClock()
        let assertion = FakeSleepAssertion(log: log)
        let journal = MemoryKeepAwakeJournal(log: log, stored: nil)
        let admissions = AdmissionCounter()
        let power = StubPowerSource(
            value: PowerSnapshot(percentage: 0.80, isCharging: false, isPluggedIn: false,
                                 isLowPower: false, timeRemaining: nil)
        )
        let provider = KeepAwakeProvider(
            now: { clock.now },
            assertion: assertion,
            power: power,
            thermal: StubThermalSource(),
            journal: KeepAwakeJournalWorker(journal, observeAdmissions: { admissions.note($0) }),
            tombstone: MemoryTombstone(log: log, value: nil),
            bootID: "boot-A",
            hasNotchPanel: { true },
            makeID: { UUID().uuidString },
            formatTime: { _ in "17:40" }
        )
        return Rig(provider: provider, assertion: assertion, journal: journal, clock: clock)
    }

    // MARK: - Coffee, then Espresso

    @Test("Espresso over Coffee runs out into Coffee, and the Mac is never let go of")
    func backToCoffee() async {
        let r = rig()
        #expect(await r.provider.begin())
        let started = r.provider.state.session?.startedAt
        #expect(await r.provider.changeMode(toLidClosed: 45) == .changed)
        let espresso = r.provider.state.session
        #expect(espresso?.returnsToHold == true)
        #expect(r.provider.payload.returnsToHold == true, "the card can say what happens at the end")
        #expect(r.provider.payload.returned != true)
        let releasesBefore = r.assertion.releaseCount

        r.clock.advance(45 * 60 + 1)
        r.provider.deadlineTick()
        await wait(for: { r.provider.state.session?.id != espresso?.id }, "the hand-back")

        let now = r.provider.state.session
        #expect(r.provider.state.isRunning, "it ended in nothing, which is the bug")
        #expect(now?.lidHoldRequested == false)
        #expect(now?.deadline == nil, "Coffee has no end")
        #expect(now?.returnsToHold != true)
        #expect(now?.startedAt == started, "the same hold, so it keeps the moment it started")
        #expect(r.assertion.isHeld)
        #expect(r.assertion.releaseCount == releasesBefore, "the Mac was let go of on the way back")
        #expect(r.provider.payload.returned == true, "nobody pressed anything, so the notch has to say it")
        #expect(r.provider.payload.isIndefinite)
        #expect(r.journal.stored?.id == now?.id)
        #expect(r.journal.stored?.state == .running)
    }

    @Test("Espresso from Off still runs out into Off")
    func fromOffEndsInOff() async {
        let r = rig()
        #expect(await r.provider.begin(minutes: 45, lidClosed: true))
        #expect(r.provider.state.session?.returnsToHold != true)
        #expect(r.provider.payload.returnsToHold != true)

        r.clock.advance(45 * 60 + 1)
        r.provider.deadlineTick()
        await wait(for: { !r.provider.state.isRunning }, "the end")
        #expect(!r.assertion.isHeld)
        guard case .finished(let finish) = r.provider.state else {
            Issue.record("not finished")
            return
        }
        #expect(finish.reason == .timeUp)
    }

    @Test("Changing the length of an Espresso picked from Off does not invent a Coffee to go back to")
    func lengthChangeFromOffStillEndsInOff() async {
        let r = rig()
        #expect(await r.provider.begin(minutes: 45, lidClosed: true))
        #expect(await r.provider.changeMode(toLidClosed: 90) == .changed)
        #expect(r.provider.state.session?.returnsToHold != true)

        r.clock.advance(90 * 60 + 1)
        r.provider.deadlineTick()
        await wait(for: { !r.provider.state.isRunning }, "the end")
        #expect(!r.assertion.isHeld)
    }

    /// Ledge quit and opened again in the middle of the Espresso.
    @Test("What is written down carries the way back, and reads back with it")
    func writtenDown() async {
        let r = rig()
        #expect(await r.provider.begin())
        #expect(await r.provider.changeMode(toLidClosed: 45) == .changed)
        #expect(r.journal.stored?.returnsToHold == true)
        #expect(r.journal.stored?.session.returnsToHold == true)
        #expect(r.journal.stored?.session == r.provider.state.session)
    }

    @Test("Changing only the length of Espresso keeps the way back to Coffee")
    func lengthChangeKeepsTheWayBack() async {
        let r = rig()
        #expect(await r.provider.begin())
        #expect(await r.provider.changeMode(toLidClosed: 45) == .changed)
        #expect(await r.provider.changeMode(toLidClosed: 90) == .changed)
        let espresso = r.provider.state.session
        #expect(espresso?.returnsToHold == true)

        r.clock.advance(90 * 60 + 1)
        r.provider.deadlineTick()
        await wait(for: { r.provider.state.session?.id != espresso?.id }, "the hand-back")
        #expect(r.provider.state.isRunning)
        #expect(r.provider.state.session?.lidHoldRequested == false)
    }

    @Test("Off pressed during Espresso over Coffee is Off")
    func offIsOff() async {
        let r = rig()
        #expect(await r.provider.begin())
        #expect(await r.provider.changeMode(toLidClosed: 45) == .changed)
        await r.provider.end(reason: .endedByYou)
        #expect(!r.provider.state.isRunning)
        #expect(!r.assertion.isHeld)
    }

    @Test("Coffee pressed during Espresso is plain Coffee, with nothing to say about it")
    func coffeePressedByHand() async {
        let r = rig()
        #expect(await r.provider.begin())
        #expect(await r.provider.changeMode(toLidClosed: 45) == .changed)
        #expect(await r.provider.changeMode(toLidClosed: nil) == .changed)
        #expect(r.provider.payload.returned != true, "a press is not news to the person who made it")
        #expect(r.provider.state.session?.returnsToHold != true)
    }

    /// Wake and a clock change both run the deadline check again.
    @Test("The check running again while the hand-back is written down hands back once")
    func oneHandBack() async {
        let r = rig()
        #expect(await r.provider.begin())
        #expect(await r.provider.changeMode(toLidClosed: 45) == .changed)
        let espresso = r.provider.state.session

        r.clock.advance(45 * 60 + 1)
        r.provider.deadlineTick()
        r.provider.deadlineTick()
        r.provider.systemDidWake()
        await wait(for: { r.provider.state.session?.id != espresso?.id }, "the hand-back")
        let coffee = r.provider.state.session?.id
        // Long enough for the second and third checks to have looked again.
        try? await Task.sleep(for: .milliseconds(800))
        #expect(r.provider.state.isRunning, "a check that lost the race ended the hold")
        #expect(r.provider.state.session?.id == coffee, "and only one Coffee was started")
        #expect(r.assertion.isHeld)
    }

    /// A lid-shut hold must never outlive the time it was given.
    @Test("If Coffee cannot be written down, Espresso ends as it always did")
    func refusedHandBackEnds() async {
        let r = rig()
        #expect(await r.provider.begin())
        #expect(await r.provider.changeMode(toLidClosed: 45) == .changed)

        r.journal.failWrites = 1
        r.clock.advance(45 * 60 + 1)
        r.provider.deadlineTick()
        await wait(for: { !r.provider.state.isRunning }, "the end")
        #expect(!r.assertion.isHeld)
    }

    /// The flag stayed on the card for as long as the Coffee ran. A card
    /// swiped away and shown again later announced a return from long ago.
    @Test("Back to Coffee is news for a few seconds and then it is just Coffee")
    func newsForAMoment() async {
        let r = rig()
        #expect(await r.provider.begin())
        #expect(await r.provider.changeMode(toLidClosed: 45) == .changed)
        let espresso = r.provider.state.session
        r.clock.advance(45 * 60 + 1)
        r.provider.deadlineTick()
        await wait(for: { r.provider.state.session?.id != espresso?.id }, "the hand-back")
        #expect(r.provider.payload.returned == true)

        r.clock.advance(KeepAwakeProvider.returnNewsLife - 1)
        #expect(r.provider.payload.returned == true)
        r.clock.advance(2)
        #expect(r.provider.payload.returned != true, "an old return is not news")
        #expect(r.provider.state.isRunning)
    }

    /// Ledge quit and opened again in the middle of the Espresso.
    @Test("An Espresso over Coffee picked up after a relaunch still goes back to Coffee")
    func afterARelaunch() async {
        let first = rig()
        #expect(await first.provider.begin())
        #expect(await first.provider.changeMode(toLidClosed: 45) == .changed)
        let record = first.journal.stored

        let log = KeepAwakeLog()
        let clock = TestClock()
        let assertion = FakeSleepAssertion(log: log)
        let journal = MemoryKeepAwakeJournal(log: log, stored: record)
        let admissions = AdmissionCounter()
        let again = KeepAwakeProvider(
            now: { clock.now },
            assertion: assertion,
            power: StubPowerSource(
                value: PowerSnapshot(percentage: 0.80, isCharging: false, isPluggedIn: false,
                                     isLowPower: false, timeRemaining: nil)),
            thermal: StubThermalSource(),
            journal: KeepAwakeJournalWorker(journal, observeAdmissions: { admissions.note($0) }),
            tombstone: MemoryTombstone(log: log, value: nil),
            bootID: "boot-A",
            hasNotchPanel: { true },
            makeID: { UUID().uuidString },
            formatTime: { _ in "17:40" }
        )
        let stream = again.start()
        _ = stream
        await wait(for: { again.state.isRunning }, "the resume")
        let espresso = again.state.session
        #expect(espresso?.lidHoldRequested == true)
        #expect(espresso?.returnsToHold == true, "the relaunch forgot the Coffee underneath")

        clock.advance(45 * 60 + 1)
        again.deadlineTick()
        await wait(for: { again.state.session?.id != espresso?.id }, "the hand-back")
        #expect(again.state.isRunning)
        #expect(again.state.session?.lidHoldRequested == false)
        #expect(assertion.isHeld)
        again.stop()
    }

    @Test("After going back to Coffee, Off and a new Coffee say nothing about a return")
    func returnIsSaidOnce() async {
        let r = rig()
        #expect(await r.provider.begin())
        #expect(await r.provider.changeMode(toLidClosed: 45) == .changed)
        let espresso = r.provider.state.session
        r.clock.advance(45 * 60 + 1)
        r.provider.deadlineTick()
        await wait(for: { r.provider.state.session?.id != espresso?.id }, "the hand-back")
        #expect(r.provider.payload.returned == true)

        await r.provider.end(reason: .endedByYou)
        await wait(for: { !r.provider.state.isRunning }, "the end")
        r.provider.dismiss()
        #expect(await r.provider.begin())
        #expect(r.provider.payload.returned != true)
    }
}
