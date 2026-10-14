import Foundation
import Testing

@testable import LedgeCore
@testable import LedgeProviders
@testable import LedgeSystem

/// A lid-closed hold the test answers for.
///
/// No daemon, no XPC, nothing privileged: the point of the seam is that every
/// answer a root process could give can be produced here instead, including
/// the one where it gives none.
private final class FakeLid: @unchecked Sendable, KeepAwakeLidHolding {

    /// Which session each release named, or nil for "whatever is held".
    /// A provider on its way out must name its own, or its delayed release
    /// ends the hold its replacement has taken.
    private(set) var disarmedSessions: [String?] = []


    private let lock = NSLock()
    private var answer: KeepAwakeLidState
    private var resting: KeepAwakeLidState
    private var armed: [(session: String, deadline: Date)] = []
    private var disarms = 0

    init(arming: KeepAwakeLidState = .holding, resting: KeepAwakeLidState = .off) {
        answer = arming
        self.resting = resting
    }

    var arms: [(session: String, deadline: Date)] { lock.withLock { armed } }
    var disarmCount: Int { lock.withLock { disarms } }

    func answers(_ state: KeepAwakeLidState) { lock.withLock { answer = state } }
    func rests(_ state: KeepAwakeLidState) { lock.withLock { resting = state } }

    func state() async -> KeepAwakeLidState { lock.withLock { resting } }

    func arm(session: String, until deadline: Date) async -> KeepAwakeLidState {
        lock.withLock {
            armed.append((session, deadline))
            resting = answer
            return answer
        }
    }

    func disarm(session: String?) async {
        lock.withLock { disarmedSessions.append(session) }
        lock.withLock {
            disarms += 1
            resting = .off
        }
    }
}

/// The lid-closed mode, from the provider's side.
///
/// Everything here is about the seam rather than the daemon: that the mode is
/// only ever asked for when it was asked for, that a refusal costs the user
/// nothing they already had, and that letting go is unconditional.
@MainActor
@Suite("Keep Awake, the lid-closed seam", .serialized)
struct KeepAwakeLidProviderTests {

    private struct Rig {
        let provider: KeepAwakeProvider
        let lid: FakeLid
        let clock: TestClock
        let assertion: FakeSleepAssertion
        let power: StubPowerSource
        let thermal: StubThermalSource
    }

    private func rig(_ lid: FakeLid, stored: KeepAwakeRecord? = nil) -> Rig {
        let log = KeepAwakeLog()
        let clock = TestClock()
        let assertion = FakeSleepAssertion(log: log)
        let power = StubPowerSource(
            value: PowerSnapshot(percentage: 0.80, isCharging: false, isPluggedIn: false,
                                 isLowPower: false, timeRemaining: nil)
        )
        let thermal = StubThermalSource()
        var ids = ["A", "B", "C"]
        let provider = KeepAwakeProvider(
            now: { clock.now },
            assertion: assertion,
            power: power,
            thermal: thermal,
            journal: MemoryKeepAwakeJournal(log: log, stored: stored),
            tombstone: MemoryTombstone(log: log),
            bootID: "boot-A",
            lid: lid,
            makeID: { ids.isEmpty ? UUID().uuidString : ids.removeFirst() },
            formatTime: { _ in "17:40" }
        )
        return Rig(provider: provider, lid: lid, clock: clock, assertion: assertion,
                   power: power, thermal: thermal)
    }

    private func wait(for condition: @MainActor () -> Bool, _ what: Comment,
                      sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0 ..< 2_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    // MARK: - Asked for, or not

    /// The plain switch is the lid-open mode. It must not quietly take a
    /// privileged hold on a Mac whose owner only pressed Start.
    @Test("The ordinary switch never asks for the lid")
    func switchDoesNotAskForTheLid() async {
        let r = rig(FakeLid())
        #expect(await r.provider.begin())
        await settledWithoutArming(r, "the plain switch took a privileged hold")
    }

    @Test("A timed hold with the lid open never asks for it either")
    func timedOpenDoesNotAskForTheLid() async {
        let r = rig(FakeLid())
        #expect(await r.provider.begin(minutes: 30))
        await settledWithoutArming(r, "a lid-open session took a privileged hold")
    }

    /// Waiting for something *not* to happen proves nothing on its own, so
    /// this waits for every side effect the start and the end set in motion.
    /// An arm, had there been one, would be among them.
    ///
    /// It used to wait for a release instead, which a lid-open session no
    /// longer sends: a provider that armed nothing releases nothing, because
    /// a nameless release ends whatever a replacement happens to be holding.
    private func settledWithoutArming(_ r: Rig, _ what: Comment,
                                      sourceLocation: SourceLocation = #_sourceLocation) async {
        await r.provider.end(reason: .endedByYou)
        await r.provider.joinSideEffects()
        #expect(r.lid.arms.isEmpty, what, sourceLocation: sourceLocation)
        #expect(r.lid.disarmedSessions.isEmpty,
                "a session that armed nothing sent a release anyway",
                sourceLocation: sourceLocation)
    }

    /// The length is what bounds a privileged hold, so the deadline the daemon
    /// is given is the session's own — never a fresh one, and never none.
    @Test("The lid-closed mode asks for the session's own deadline")
    func lidClosedArmsToTheDeadline() async {
        let r = rig(FakeLid())
        #expect(await r.provider.begin(minutes: 90, lidClosed: true))
        await wait(for: { !r.lid.arms.isEmpty }, "the hold to be asked for")
        #expect(r.lid.arms.first?.session == "A")
        #expect(r.lid.arms.first?.deadline == r.clock.now.addingTimeInterval(90 * 60))
    }

    @Test("The card is told the hold took")
    func holdingReachesTheCard() async {
        let r = rig(FakeLid())
        #expect(await r.provider.begin(minutes: 90, lidClosed: true))
        await wait(for: { r.provider.lidReading == .holding }, "the reading to land")
        #expect(r.provider.payload.lid == .holding)
        #expect(r.provider.payload.lidHeld, "the flag and the reading disagree")
        #expect(r.provider.payload.lidClosed)
    }

    // MARK: - A refusal costs nothing already had

    /// The ordinary hold is taken before the lid is ever asked about, so a
    /// refusal leaves the user with the session they started. Failing the
    /// whole start over it would throw away the half that worked.
    @Test("A refused lid leaves the session running, and says why")
    func refusalKeepsTheSession() async {
        let lid = FakeLid(arming: .refused(.foreign))
        let r = rig(lid)
        #expect(await r.provider.begin(minutes: 90, lidClosed: true))
        await wait(for: { r.provider.lidReading == .refused(.foreign) }, "the refusal")
        #expect(r.provider.state.isRunning, "a refused lid ended a session that was fine")
        #expect(r.provider.payload.lid == .refused(.foreign))
        #expect(!r.provider.payload.lidHeld)
        #expect(KeepAwakeCopy.lid(r.provider.payload.lid)?.isEmpty == false)
    }

    /// Silence is not death. The daemon drops a hold on its own lease, not on
    /// our inability to reach it, so the card must go on reporting a hold.
    @Test("A silent daemon leaves the card saying the hold stands")
    func silenceStillReadsAsHeld() async {
        let lid = FakeLid(arming: .unconfirmed)
        let r = rig(lid)
        #expect(await r.provider.begin(minutes: 90, lidClosed: true))
        await wait(for: { r.provider.lidReading == .unconfirmed }, "the unconfirmed reading")
        #expect(r.provider.payload.lidHeld, "an unconfirmed hold is still a hold")
    }

    // MARK: - Letting go

    @Test("Ending the session gives the hold back")
    func endDisarms() async {
        let r = rig(FakeLid())
        #expect(await r.provider.begin(minutes: 90, lidClosed: true))
        await wait(for: { !r.lid.arms.isEmpty }, "the hold")
        await r.provider.end(reason: .endedByYou)
        await wait(for: { r.lid.disarmCount >= 1 }, "the hold to be given back")
    }

    /// Unconditional on purpose. Everything about a release moves the Mac
    /// towards being allowed to sleep, so "we think nothing is held" is never
    /// The belief is still the thing most likely to be wrong — but a release
    /// has to *name* what it is ending, and a lid-open session has no name to
    /// give. A nameless one means "whatever is held", which is how a delayed
    /// teardown ended the session that had replaced it. The daemon's own
    /// lease is what covers a hold this provider has forgotten about.
    @Test("A session that never armed sends no release")
    func lidOpenSessionSendsNoRelease() async {
        let r = rig(FakeLid())
        #expect(await r.provider.begin(minutes: 30))
        await r.provider.end(reason: .endedByYou)
        await r.provider.joinSideEffects()
        #expect(r.lid.disarmCount == 0,
                "a provider that armed nothing released something")
    }

    @Test("Tearing the provider down gives the hold back")
    func stopDisarms() async {
        let r = rig(FakeLid())
        #expect(await r.provider.begin(minutes: 90, lidClosed: true))
        await wait(for: { !r.lid.arms.isEmpty }, "the hold")
        r.provider.stop()
        await wait(for: { r.lid.disarmCount >= 1 }, "the hold to be given back")
        #expect(!r.lid.disarmedSessions.contains(nil),
                "a teardown released without naming what it was ending")
    }

    // MARK: - The floors a shut lid changes

    /// A shut Mac cannot shed heat and nobody can see it get hot, so the
    /// thermal floor comes down from critical to serious. With the lid open
    /// the user is looking at the thing and can act for themselves.
    @Test("A shut lid ends the session one step earlier on heat")
    func heatEndsALidClosedSessionSooner() async {
        let open = rig(FakeLid())
        #expect(await open.provider.begin(minutes: 90))
        open.thermal.set(.serious)
        await Task.yield()
        #expect(open.provider.state.isRunning, "a visible Mac was cut short over warmth")

        let shut = rig(FakeLid())
        #expect(await shut.provider.begin(minutes: 90, lidClosed: true))
        shut.thermal.set(.serious)
        await wait(for: { !shut.provider.state.isRunning }, "the hot shut Mac to be let go")
    }

    /// Holding a Mac awake on a battery level nobody can read is how a laptop
    /// in a bag runs flat. With the lid open that number is on screen, and
    /// ending a session over a failed read would be Ledge being jumpy about
    /// something it did not need.
    @Test("A battery nobody can read ends a shut session, not an open one")
    func unreadableBatteryEndsOnlyTheShutOne() async {
        let open = rig(FakeLid())
        #expect(await open.provider.begin(minutes: 90))
        open.power.set(nil)
        for _ in 0 ..< 3 { open.thermal.set(.nominal) }
        await Task.yield()
        #expect(open.provider.state.isRunning, "an open session ended over a number it did not need")

        let shut = rig(FakeLid())
        #expect(await shut.provider.begin(minutes: 90, lidClosed: true))
        shut.power.set(nil)
        for _ in 0 ..< 3 { shut.thermal.set(.nominal) }
        await wait(for: { !shut.provider.state.isRunning },
                   "a shut Mac held awake on a battery level nobody can read")
    }

    // MARK: - The resting reading

    /// Sleep disabled by somebody else is a standing fact about the Mac, and
    /// the Ready card has to carry it before anything is pressed.
    @Test("A refusal that was never asked for still reaches the Ready card")
    func restingReadingReachesReady() async {
        let lid = FakeLid(resting: .refused(.foreign))
        let r = rig(lid)
        await r.provider.refreshLid()
        #expect(r.provider.payload.lid == .refused(.foreign))
        #expect(!r.provider.payload.lid.mayArm)
    }
}

// MARK: - Coming back to a session already running

/// A relaunch mid-session, which is what a Sparkle update or a crash looks
/// like from here.
@MainActor
@Suite("Keep Awake, resuming a lid-closed session", .serialized)
struct KeepAwakeLidResumeTests {

    private static let start = Date(timeIntervalSince1970: 1_000_000)

    private func provider(_ lid: FakeLid, lidRequested: Bool) -> KeepAwakeProvider {
        let log = KeepAwakeLog()
        let record = KeepAwakeRecord(
            id: "A", state: .running, startedAt: Self.start,
            deadline: Self.start.addingTimeInterval(3600),
            total: 3600, boot: "boot-A", lidHoldRequested: lidRequested
        )
        return KeepAwakeProvider(
            now: { Self.start.addingTimeInterval(60) },
            assertion: FakeSleepAssertion(log: log),
            power: StubPowerSource(value: PowerSnapshot(
                percentage: 0.80, isCharging: false, isPluggedIn: false,
                isLowPower: false, timeRemaining: nil)),
            thermal: StubThermalSource(),
            journal: MemoryKeepAwakeJournal(log: log, stored: record),
            tombstone: MemoryTombstone(log: log),
            bootID: "boot-A",
            lid: lid,
            makeID: { "B" },
            formatTime: { _ in "17:40" }
        )
    }

    private func wait(for condition: @MainActor () -> Bool, _ what: Comment,
                      sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0 ..< 2_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// The daemon never inherits a hold across a restart — not its own, and
    /// not one taken by an app that has since been replaced. So a resumed
    /// session has to ask again.
    ///
    /// Darkening without re-arming is the worst of both: the panel is black,
    /// the card says the mode is on, and the Mac sleeps the moment the lid
    /// comes down. The user finds their agent dead and their screen was off
    /// the whole time for nothing.
    @Test("A resumed lid-closed session asks the daemon for the hold again")
    func resumeArmsTheDaemon() async {
        let lid = FakeLid()
        let p = provider(lid, lidRequested: true)
        // The stream has to be held: an unconsumed one going out of scope
        // terminates, and termination stops the provider before it resumes.
        let stream = p.start()
        defer { p.stop() }
        await wait(for: { !lid.arms.isEmpty }, "the resumed session to arm the lid")
        #expect(lid.arms.first?.session == "A", "a different session took the hold")
        #expect(lid.arms.first?.deadline == Self.start.addingTimeInterval(3600),
                "the resumed hold moved the deadline the first one fixed")
        withExtendedLifetime(stream) {}
    }

    /// An ordinary session sleeps when the lid comes down. Resuming one must
    /// not quietly take a privileged hold its owner never asked for.
    @Test("A resumed ordinary session never asks for the lid")
    func resumeOfOrdinaryDoesNotArm() async {
        let lid = FakeLid()
        let p = provider(lid, lidRequested: false)
        let stream = p.start()
        defer { p.stop() }
        // Waited out rather than yielded once: proving an absence needs the
        // window in which it could have happened to have actually passed.
        await wait(for: { p.state.isRunning }, "the plain session to resume")
        for _ in 0 ..< 60 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(lid.arms.isEmpty, "a plain session took a privileged hold on resume")
        withExtendedLifetime(stream) {}
    }
}

/// What `end(reason:)` returning has never meant.
///
/// It means the session is written down. It has never meant the hold was given
/// back, the savings put away, or another application's preference restored —
/// those were tasks nobody was holding on to, so a quit could return from the
/// end and exit with all three still outstanding.
@MainActor
@Suite("Side effects a quit has to wait for", .serialized)
struct KeepAwakeSideEffectTests {

    private func built(_ lid: FakeLid,
                       appNap: (any AppNapSuspending)? = nil) -> KeepAwakeProvider {
        let ids = SessionIDs()
        let log = KeepAwakeLog()
        let clock = TestClock()
        return KeepAwakeProvider(
            now: { clock.now },
            assertion: FakeSleepAssertion(log: log),
            power: StubPowerSource(
                value: PowerSnapshot(percentage: 0.80, isCharging: false, isPluggedIn: false,
                                     isLowPower: false, timeRemaining: nil)
            ),
            thermal: StubThermalSource(),
            journal: MemoryKeepAwakeJournal(log: log),
            tombstone: MemoryTombstone(log: log),
            bootID: "boot-A",
            lid: lid,
            appNap: appNap,
            makeID: { ids.next() },
            formatTime: { _ in "17:40" }
        )
    }

    /// Distinct session names, because the provider refuses to start a session
    /// whose name is already spoken for.
    private final class SessionIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> String {
            lock.withLock {
                count += 1
                return count == 1 ? "S1" : "S\(count)"
            }
        }
    }

    @Test("Joining the side effects waits for the hold to be given back")
    func joinWaitsForTheRelease() async {
        let lid = FakeLid()
        let provider = built(lid)
        #expect(await provider.begin(minutes: 30, lidClosed: true))

        await provider.joinSideEffects()
        #expect(lid.arms.count == 1, "the hold was never taken")

        await provider.end(reason: .turnedOff)
        await provider.joinSideEffects()

        #expect(lid.disarmedSessions.count == 1,
                "a quit could have exited before the hold was given back")
    }

    /// The first End reads `state.session?.id` while the state is still
    /// running and gets the right answer. The `stop()` that follows reads it
    /// after the state has become Finished and gets nil — which means
    /// "whatever is held", and ended the session that had replaced it.
    @Test("A stop after an end does not release a second time")
    func stopAfterEndReleasesNothing() async {
        let lid = FakeLid()
        let provider = built(lid)
        #expect(await provider.begin(minutes: 30, lidClosed: true))
        await provider.joinSideEffects()

        await provider.end(reason: .turnedOff)
        await provider.joinSideEffects()
        #expect(lid.disarmedSessions == ["S1"])

        // The card is switched off, or the app is quitting.
        provider.stop()
        await provider.joinSideEffects()

        #expect(lid.disarmedSessions == ["S1"],
                "a second, nameless release went out after the session had ended")
        #expect(!lid.disarmedSessions.contains(nil),
                "a wildcard release could end whatever a replacement is holding")
    }

    /// An App Nap boundary a test can park inside.
    private final class GatedNap: AppNapSuspending, @unchecked Sendable {
        private let lock = NSLock()
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private var gate = false
        private(set) var begins = 0

        func gateBegin() { lock.withLock { gate = true } }
        func waitUntilInsideBegin() { _ = entered.wait(timeout: .now() + 5) }
        func letBeginFinish() { release.signal() }

        func beginIfWanted() async {
            lock.withLock { begins += 1 }
            guard lock.withLock({ gate }) else { return }
            entered.signal()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.release.wait()
                    continuation.resume()
                }
            }
        }

        func end() async {}
        func restoreOutstanding() async {}
        var beginCount: Int { lock.withLock { begins } }
    }

    /// Disabling another application's App Nap is work a quit has to wait
    /// for, and an untracked Task is work the barrier cannot see: the join
    /// returned while a Begin was still parked, with nothing tracked at all.
    @Test("A join waits for App Nap to finish starting")
    func joinWaitsForAppNapBegin() async {
        let lid = FakeLid()
        let nap = GatedNap()
        nap.gateBegin()
        let provider = built(lid, appNap: nap)

        #expect(await provider.begin(minutes: 30, lidClosed: true))
        nap.waitUntilInsideBegin()
        #expect(provider.liveSideEffectCount > 0,
                "a producer that is still running is not being tracked")

        let finished = Flag()
        let joined = Task {
            await provider.joinSideEffects()
            finished.raise()
        }
        try? await Task.sleep(for: .milliseconds(120))
        #expect(!finished.isRaised,
                "the barrier returned with another application's App Nap still being changed")

        nap.letBeginFinish()
        await joined.value
        #expect(finished.isRaised)
        #expect(provider.liveSideEffectCount == 0)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func raise() { lock.withLock { value = true } }
        var isRaised: Bool { lock.withLock { value } }
    }

    /// Handles for work that has finished are not work. Removing only
    /// cancelled ones kept every completed task for the provider's lifetime.
    @Test("Finished side effects do not accumulate")
    func finishedWorkIsNotRetained() async {
        let lid = FakeLid()
        let provider = built(lid)

        #expect(await provider.begin(minutes: 30, lidClosed: true))
        await provider.end(reason: .turnedOff)

        // No join: the registry has to empty itself as the work finishes.
        // Removing only *cancelled* handles kept every completed one for the
        // provider's lifetime, and normal completion does not cancel.
        for _ in 0..<400 where provider.liveSideEffectCount > 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(provider.liveSideEffectCount == 0,
                "completed work was kept for the provider's lifetime")
    }

    /// A provider on its way out can be delayed past the point where its
    /// replacement has taken a hold of its own. An unnamed release would end
    /// that one instead, and the publication guard afterwards cannot undo a
    /// release that has already gone out.
    @Test("The release names the session it is giving back")
    func releaseNamesItsSession() async {
        let lid = FakeLid()
        let provider = built(lid)
        #expect(await provider.begin(minutes: 30, lidClosed: true))
        await provider.joinSideEffects()
        let started = lid.arms.first?.session
        #expect(started == "S1", "the hold was never taken")

        await provider.end(reason: .turnedOff)
        await provider.joinSideEffects()

        #expect(lid.disarmedSessions == [started],
                "the release did not name the session it belonged to")
    }
}
