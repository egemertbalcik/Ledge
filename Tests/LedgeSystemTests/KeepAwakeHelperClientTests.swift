import Foundation
import LedgeCore
import LedgeHelperKit
import Testing

@testable import LedgeSystem

/// A daemon the test answers by hand.
///
/// Scripted rather than stateful: what matters here is not what a real daemon
/// would say but what this client does with each thing it could say, including
/// saying nothing at all.
private final class FakeLink: @unchecked Sendable, KeepAwakeHelperLink {

    private let lock = NSLock()

    struct Hold: Equatable {
        let session: String
        let generation: Int
        let deadline: Date?
        let lease: Double
    }

    private var holds: [Hold] = []
    private var releases: [(session: String, generation: Int)] = []
    private var lowPowerCalls: [(on: Bool, session: String, generation: Int)] = []
    private var answers: [KeepAwakeHelperCode] = []
    private var fallback: KeepAwakeHelperCode = .ok
    private var silent = false
    /// Calls that will never be answered. Held so the continuations are not
    /// leaked when the suite finishes.
    private var stranded: [CheckedContinuation<Void, Never>] = []
    /// Whether the privileged write behind an accepted hold actually lands.
    ///
    /// A real daemon answers `ok` once the lease is on disk and *then* runs
    /// `pmset` and reads it back. A fake that reported `ours: false,
    /// sleepDisabled: 0` forever was a daemon whose apply never succeeded —
    /// and every test that asserted `holding` against it was asserting that an
    /// acceptance is a hold, which is the thing that was wrong.
    private var applySucceeds = true
    private var applied = false
    private var reported: KeepAwakeHelperStatus?

    /// The apply fails, as a refused `pmset` does. The hold is still accepted.
    func refusesTheApply() { lock.withLock { applySucceeds = false } }

    /// Every call, in the order it arrived, whatever came of it.
    private var log: [String] = []
    var callLog: [String] { lock.withLock { log } }

    /// The daemon is the copy from before an update.
    ///
    /// Every message still lands and is acted on — a hold applies, a release
    /// puts the setting back — and every answer is refused on the way back,
    /// which is what the app's code signing check does to a daemon whose
    /// bundle has been deleted.
    private var outOfDate = false
    func goesOutOfDate() { lock.withLock { outOfDate = true } }
    /// The old copy has exited and launchd started the new one.
    func comesBackUpToDate() { lock.withLock { outOfDate = false } }
    private func refuseIfOutOfDate() throws {
        if lock.withLock({ outOfDate }) { throw KeepAwakeHelperOutOfDate() }
    }

    var recordedHolds: [Hold] { lock.withLock { holds } }
    var recordedLowPower: [(on: Bool, session: String, generation: Int)] {
        lock.withLock { lowPowerCalls }
    }
    var recordedReleases: [(session: String, generation: Int)] { lock.withLock { releases } }

    /// Never answers. Models a daemon that is wedged behind a `pmset`
    /// transaction, or gone.
    func goSilent() { lock.withLock { silent = true } }
    func speakAgain() { lock.withLock { silent = false } }

    /// Lets every abandoned call finish, so nothing is left parked.
    func releaseStranded() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            let held = stranded
            stranded = []
            return held
        }
        waiting.forEach { $0.resume() }
    }

    /// Refuses every generation below this one, as a daemon still holding a
    /// recovered session's generation does.
    private var staleBelow = 0
    func refusesBelow(generation: Int) { lock.withLock { staleBelow = generation } }

    /// The next answers, in order. Once they run out, `fallback` is used.
    func willAnswer(_ codes: [KeepAwakeHelperCode], thereafter: KeepAwakeHelperCode = .ok) {
        lock.withLock {
            answers = codes
            fallback = thereafter
        }
    }

    func reports(_ status: KeepAwakeHelperStatus) { lock.withLock { reported = status } }

    /// Holds the next status call open until it is let go.
    ///
    /// Not the same as `goSilent`, which never answers at all: this one
    /// answers, late. A status still in flight while its session ends is the
    /// only way to reproduce an observation filing itself against a session
    /// it was never about.
    private var statusGate: DispatchSemaphore?
    func holdNextStatus() { lock.withLock { statusGate = DispatchSemaphore(value: 0) } }
    func releaseHeldStatus() {
        let gate = lock.withLock { statusGate }
        statusGate = nil
        gate?.signal()
    }

    func status() async throws -> KeepAwakeHelperStatus {
        lock.withLock { log.append("status") }
        if lock.withLock({ silent }) { try await Task.sleep(for: .seconds(3600)) }
        if let gate = lock.withLock({ statusGate }) {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { gate.wait(); k.resume() }
            }
        }
        try refuseIfOutOfDate()
        return lock.withLock {
            if let reported { return reported }
            return KeepAwakeHelperStatus(
                build: "test", sleepDisabled: applied ? 1 : 0, ours: applied,
                clean: !applied, cleanupPending: false,
                otherLedgeHolds: false, lowPowerClaimed: false
            )
        }
    }

    private var lowPowerGate: DispatchSemaphore?
    private var lowPowerReached = 0

    /// Holds the next Low Power Mode call open, which is where the catch-up's
    /// last await lives.
    func holdNextLowPower() { lock.withLock { lowPowerGate = DispatchSemaphore(value: 0) } }
    func letLowPowerFinish() {
        let gate: DispatchSemaphore? = lock.withLock {
            let held = lowPowerGate
            lowPowerGate = nil
            return held
        }
        gate?.signal()
    }
    var lowPowerInFlight: Int { lock.withLock { lowPowerReached } }

    func setLowPowerMode(_ on: Bool, session: String,
                         generation: Int) async throws -> KeepAwakeHelperCode {
        let gate: DispatchSemaphore? = lock.withLock {
            lowPowerReached += 1
            return lowPowerGate
        }
        if let gate {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    gate.wait()
                    continuation.resume()
                }
            }
        }
        let silent: Bool = lock.withLock {
            lowPowerCalls.append((on, session, generation))
            log.append("low-power")
            return self.silent
        }
        if silent {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        try refuseIfOutOfDate()
        return .ok
    }

    func hold(session: String, generation: Int, until deadline: Date?,
              leaseSeconds: Double) async throws -> KeepAwakeHelperCode {
        let answer: KeepAwakeHelperCode? = lock.withLock {
            holds.append(Hold(session: session, generation: generation,
                              deadline: deadline, lease: leaseSeconds))
            log.append("hold")
            if silent { return nil }
            if generation < staleBelow { return KeepAwakeHelperCode.stale }
            let answer = answers.isEmpty ? fallback : answers.removeFirst()
            // The apply happens after the reply, as it does on a real daemon.
            if answer == .ok, applySucceeds { applied = true }
            return answer
        }
        // Applied above, refused here: the old copy takes the hold and the
        // app never hears that it did.
        try refuseIfOutOfDate()
        // A hold held open: sent, not yet answered.
        if let gate = lock.withLock({ holdGate }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    gate.wait()
                    continuation.resume()
                }
            }
            return lock.withLock {
                if gatedAnswer == .ok, applySucceeds { applied = true }
                return gatedAnswer
            }
        }

        guard let answer else {
            // Never answers, and does not cooperate with cancellation —
            // which is the point. A real XPC call is parked in a continuation
            // that only the daemon can resume, so a fake built on a
            // cancellable sleep would let a broken timeout pass.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { stranded.append(continuation) }
            }
            throw CancellationError()
        }
        return answer
    }

    private var holdGate: DispatchSemaphore?

    /// Holds the next hold open, so a test can get between a hold being sent
    /// and it being answered — which is where the first pending hold lives,
    /// and where an `end` arriving used to lose the session.
    func holdNextHold() { lock.withLock { holdGate = DispatchSemaphore(value: 0) } }
    func letHoldFinish(answering code: KeepAwakeHelperCode = .ok) {
        let gate: DispatchSemaphore? = lock.withLock {
            gatedAnswer = code
            let held = holdGate
            holdGate = nil
            return held
        }
        gate?.signal()
    }
    private var gatedAnswer: KeepAwakeHelperCode = .ok

    private var releaseGate: DispatchSemaphore?
    private var releasesReached = 0

    /// Holds the next release open, so a test can get between the release
    /// being asked for and it being answered.
    func holdNextRelease() { lock.withLock { releaseGate = DispatchSemaphore(value: 0) } }
    func letReleaseFinish() {
        let gate: DispatchSemaphore? = lock.withLock {
            let held = releaseGate
            releaseGate = nil
            return held
        }
        gate?.signal()
    }
    var releasesInFlight: Int { lock.withLock { releasesReached } }

    func release(session: String, generation: Int) async throws -> KeepAwakeHelperCode {
        let gate: DispatchSemaphore? = lock.withLock {
            releases.append((session, generation))
            log.append("release")
            releasesReached += 1
            applied = false
            return releaseGate
        }
        if let gate {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    gate.wait()
                    continuation.resume()
                }
            }
        }
        try refuseIfOutOfDate()
        return .ok
    }
}

/// A sleeper the test drives.
///
/// The client sleeps for two quite different reasons — waiting out the
/// heartbeat interval and waiting out a call's timeout — and a test that
/// cannot tell them apart can only ever test one of them. They are told apart
/// by their duration, which is why the two constants are different numbers.
private final class Sleeper: @unchecked Sendable {

    private let lock = NSLock()
    private var beatGate: [CheckedContinuation<Void, Error>] = []
    private var timeoutFires = false

    /// Lets exactly one heartbeat through.
    func beat() {
        let waiting: CheckedContinuation<Void, Error>? = lock.withLock {
            beatGate.isEmpty ? nil : beatGate.removeFirst()
        }
        waiting?.resume()
    }

    var beatsWaiting: Int { lock.withLock { beatGate.count } }

    /// Makes every call time out rather than wait for an answer.
    ///
    /// Goes with `FakeLink.goSilent`, and comes off with `speakAgain`: a
    /// daemon that is answering again must not still be timing out. The
    /// earlier version left this on and relied on the real answer winning a
    /// race against an instant timeout, which is not a race any production
    /// code should be able to lose and not a property worth testing.
    func timeOutCalls() { lock.withLock { timeoutFires = true } }
    func answerCallsAgain() { lock.withLock { timeoutFires = false } }

    /// The handover's silences, through their own door — the client's
    /// `silence`, not its `sleep` — so a test can let one go without the
    /// other, and can see that it began at all.
    private var silenceGate: [CheckedContinuation<Void, Error>] = []
    private var lengths: [TimeInterval] = []
    var silencesWaiting: Int { lock.withLock { silenceGate.count } }
    /// How many silences have started, ended or not. Two waiting one after
    /// the other look the same to `silencesWaiting`.
    var silencesBegun: Int { lock.withLock { lengths.count } }
    /// How long each silence asked for, in order.
    var silenceLengths: [TimeInterval] { lock.withLock { lengths } }
    func endSilence() {
        let waiting: CheckedContinuation<Void, Error>? = lock.withLock {
            silenceGate.isEmpty ? nil : silenceGate.removeFirst()
        }
        waiting?.resume()
    }

    func silence(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                lengths.append(seconds)
                silenceGate.append(continuation)
            }
        }
    }

    func sleep(_ seconds: TimeInterval) async throws {
        if seconds == KeepAwakeHelperClient.callTimeout {
            guard lock.withLock({ timeoutFires }) else {
                // The call's own answer should win; never fire.
                try await Task.sleep(for: .seconds(3600))
                return
            }
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { beatGate.append(continuation) }
        }
    }
}

@Suite("Keep Awake helper client", .timeLimit(.minutes(10)))
struct KeepAwakeHelperClientTests {

    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    private static func client(_ link: FakeLink, _ sleeper: Sleeper) -> KeepAwakeHelperClient {
        KeepAwakeHelperClient(link: link, now: { t0 }, sleep: sleeper.sleep)
    }

    /// For as long as it takes. A five-second deadline turned a held main
    /// thread into a failure with nothing wrong; the suite's time limit
    /// catches a condition that never comes.
    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        while !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits on the client itself rather than on the fake.
    ///
    /// The fake records a hold as the call arrives, not as it is answered, so a
    /// test that waits for the call count and then reads the state is reading
    /// it one step early — the client has not seen the answer yet. Under the
    /// full suite that is the difference between passing and not.
    ///
    /// For as long as it takes, like `waitUntil`.
    private func waitForState(_ client: KeepAwakeHelperClient,
                              _ wanted: KeepAwakeHelperState) async throws {
        while await client.currentState != wanted {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// These three numbers only mean anything in relation to each other, and
    /// the relations are the contract rather than the values. A timeout at or
    /// below the heartbeat reports a daemon that is merely slow — a renewal is
    /// answered only once it is on disk, which can honestly take ~20 s behind a
    /// `pmset` transaction — as a daemon that is gone. A timeout at or above
    /// the lease learns of real trouble too late to do anything about it.
    @Test("The timeout sits between the heartbeat and the lease")
    func timingsAreOrdered() {
        #expect(KeepAwakeHelperClient.callTimeout > KeepAwakeHelperClient.heartbeat,
                "a slow but healthy daemon would be reported as gone")
        #expect(KeepAwakeHelperClient.callTimeout < KeepAwakeHelperClient.lease,
                "trouble would not be noticed until the hold had already lapsed")
        #expect(KeepAwakeHelperClient.heartbeat * 2 < KeepAwakeHelperClient.lease,
                "two lost heartbeats would be enough to lose the hold")
    }

    // MARK: - Low Power Mode

    /// Ledge throttles the Mac on purpose, because the agents this is for wait
    /// on sockets rather than on clocks. It is still a system-wide setting
    /// hung on a lease, and everything below is about the lease.

    @Test("Low Power Mode goes to the daemon under the hold's own generation")
    func lowPowerCarriesTheHoldsGeneration() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        #expect(await client.begin(session: "s1") == .holding)

        _ = await client.setLowPowerMode(true)
        let asked = link.recordedLowPower
        #expect(asked.count == 1)
        #expect(asked.last?.on == true)
        #expect(asked.last?.session == "s1")
        #expect(asked.last?.generation == 1,
                "the request carried a generation the daemon has not agreed to")
        await client.end()
    }

    /// Nothing to hang it on. The daemon refuses a Low Power Mode request from
    /// a session that is not the one holding this Mac, so asking before there
    /// is a hold is asking to be refused.
    @Test("Nothing is asked for before there is a hold")
    func noHoldNoRequest() async {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        #expect(await client.setLowPowerMode(true) == nil)
        #expect(link.recordedLowPower.isEmpty)
    }

    /// The request is re-sent with every heartbeat for two reasons, and each
    /// one alone would be enough: the daemon may have restarted and remembers
    /// nothing anybody asked it, and every renewal retires the generation
    /// before it, so a want stated once is answered `stale` within thirty
    /// seconds of being stated.
    @Test("The standing want goes again with every heartbeat")
    func wantIsRestated() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)
        _ = await client.setLowPowerMode(true)
        #expect(link.recordedLowPower.count == 1)

        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitUntil { link.recordedHolds.count >= 2 }
        try await waitUntil { link.recordedLowPower.count >= 2 }

        let latest = link.recordedLowPower.last
        #expect(latest?.on == true)
        #expect(latest?.generation == link.recordedHolds.last?.generation,
                "the restated want carried a generation the daemon had retired")
        await client.end()
    }

    @Test("A want nobody ever stated is never sent")
    func silenceIsNotAWant() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)

        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitUntil { link.recordedHolds.count >= 2 }

        #expect(link.recordedLowPower.isEmpty,
                "Low Power Mode was asked for by a session that never wanted it")
        await client.end()
    }

    /// Giving it back is a request like any other, and the daemon turns it
    /// into "put the setting back to what I journalled" rather than "off".
    @Test("Giving it back is sent, and then stops being restated")
    func givingItBack() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)
        _ = await client.setLowPowerMode(true)
        _ = await client.setLowPowerMode(false)

        #expect(link.recordedLowPower.map(\.on) == [true, false])

        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitUntil { link.recordedHolds.count >= 2 }
        try await waitUntil { link.recordedLowPower.count >= 3 }
        #expect(link.recordedLowPower.last?.on == false)
        await client.end()
    }

    /// A release ends the session, and the want belonged to it. Carrying one
    /// into the next session would ask for Low Power Mode on behalf of a user
    /// who had not switched it on this time.
    @Test("The want does not survive the session it belonged to")
    func wantEndsWithTheSession() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)
        _ = await client.setLowPowerMode(true)
        await client.end()

        let asked = link.recordedLowPower.count
        #expect(await client.begin(session: "s2") == .holding)
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitUntil { link.recordedHolds.contains { $0.session == "s2" } }

        #expect(link.recordedLowPower.count == asked,
                "a new session inherited the last one's Low Power Mode")
        #expect(!link.recordedLowPower.contains { $0.session == "s2" })
        await client.end()
    }

    /// Silence is not failure. The want is remembered and goes again with the
    /// next heartbeat, and the daemon's own lease puts the setting back if
    /// this app never manages to say another word.
    @Test("A daemon that does not answer does not lose the want")
    func silentDaemonKeepsTheWant() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)

        link.goSilent()
        sleeper.timeOutCalls()
        #expect(await client.setLowPowerMode(true) == nil)

        link.speakAgain()
        sleeper.answerCallsAgain()
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitUntil { link.recordedLowPower.count >= 2 }
        #expect(link.recordedLowPower.last?.on == true)
        await client.end()
    }

    /// A timeout has to be a bound, not a preference.
    ///
    /// The first version raced the call against a sleep in a task group — and
    /// a group waits for its cancelled children before it returns. The losing
    /// child is an XPC call parked in a continuation that cancellation cannot
    /// resume; only the daemon answering can, and a daemon that has stopped
    /// answering is the case the timeout exists for. So the call stayed
    /// suspended for as long as the daemon stayed silent, which is forever.
    ///
    /// This fake does not cooperate with cancellation either, for exactly
    /// that reason: a fake that does cannot catch the bug.
    @Test("A call the daemon never answers still returns at the timeout")
    func timeoutIsActuallyABound() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)

        link.goSilent()
        sleeper.timeOutCalls()
        let began = Task { await client.begin(session: "s1") }

        // Bounded by the suite's time limit, and without a task group.
        //
        // A regression here does not make this assertion false — it makes it
        // never arrive, and a wait that ignored cancellation would turn a
        // failing test into a hung test run, which is worse than no test. So
        // the wait gives up when the time limit cancels it. A count of short
        // sleeps bounded it before, and a held main thread outlasted that with
        // nothing wrong. A task group is no good for the bound either, for
        // exactly the reason this test exists: a group waits for its children,
        // including the one that never finishes.
        let answer = Answer()
        Task { answer.set(await began.value) }
        while answer.value == nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        // Not `temporarilyUnavailable`, which would say the hold almost
        // certainly stands — nothing was ever confirmed, so there is no
        // confirmation to stand on. And not `unreachable` either: the request
        // *left*, and a daemon that took the lease and lost the reply looks
        // exactly like this. What is true is that the outcome is unknown.
        #expect(answer.value == .unknownWhetherHeld,
                "the call never came back: the timeout is not a bound")
        link.releaseStranded()
        await client.end()
    }

    /// Each request used to start its own detached task, so two hundred rapid
    /// on/off pairs could finish with the daemon holding *on* — a Mac left
    /// throttled by a request the user had already taken back.
    ///
    /// A queue fixed the order and left a second problem behind it: every
    /// queued request acted on whatever session was current when it finally
    /// ran. There is no queue now, because `setLowPowerMode` states a standing
    /// want and only the latest one means anything — so what is tested is not
    /// that every request arrives, but that the one the user asked for last is
    /// the one the daemon is left holding.
    @Test("Rapid changes leave the daemon holding the last one asked for")
    func lowPowerCoalescesToTheLatest() async throws {
        for wanted in [true, false] {
            let link = FakeLink()
            let client = Self.client(link, Sleeper())
            #expect(await client.begin(session: "s1") == .holding)

            let control = HelperLowPowerMode(client: client)
            for _ in 0..<200 {
                _ = control.set(true)
                _ = control.set(false)
            }
            _ = control.set(wanted)
            await control.settle()

            #expect(link.recordedLowPower.last?.on == wanted,
                    "the last thing the user asked for is not the last thing the daemon heard")
            #expect(!link.recordedLowPower.isEmpty, "nothing reached the daemon at all")
            #expect(link.recordedLowPower.count <= 401,
                    "requests the user had already replaced were still sent")
            await client.end()
        }
    }

    /// And the point of coalescing rather than queuing: nothing can be waiting
    /// its turn to act on a session that has since been replaced.
    @Test("No Low Power Mode request outlives the session that made it")
    func noRequestOutlivesItsSession() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        #expect(await client.begin(session: "A") == .holding)

        let control = HelperLowPowerMode(client: client)
        _ = control.set(true)
        await control.settle()
        await client.end()

        let askedUnderA = link.recordedLowPower.count
        #expect(await client.begin(session: "B") == .holding)
        await control.settle()

        #expect(link.recordedLowPower.count == askedUnderA,
                "a request made under one session was delivered to the next")
        #expect(!link.recordedLowPower.contains { $0.session == "B" })
        await client.end()
    }

    // MARK: - An acceptance is not a hold

    /// The daemon answers a hold once the lease is on disk and *then* runs
    /// the privileged write. A refused `pmset` leaves an `ok` behind it, and
    /// reading that as held told the user their Mac was being kept awake
    /// while the setting read 0 and the daemon was still retrying.
    @Test("An accepted hold whose apply was refused does not read as held")
    func acceptedButNotApplied() async {
        let link = FakeLink()
        link.refusesTheApply()
        let client = Self.client(link, Sleeper())

        let state = await client.begin(session: "s1")

        #expect(state == .pending, "a lease the daemon took was reported as a hold")
        await client.end()
    }

    @Test("An accepted hold whose apply landed reads as held")
    func acceptedAndApplied() async {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        #expect(await client.begin(session: "s1") == .holding)
        await client.end()
    }

    /// A claim is journalled before the privileged write, so `ours` is true
    /// from the moment the record exists — including when the write that
    /// followed it failed.
    @Test("Armed means the setting is in force, not that a claim exists")
    func armedIsNotJustOurs() {
        let claimed = KeepAwakeHelperStatus(
            build: "t", sleepDisabled: 0, ours: true, clean: false,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false)
        #expect(!claimed.isArmed, "a claim with no setting behind it read as armed")

        let held = KeepAwakeHelperStatus(
            build: "t", sleepDisabled: 1, ours: true, clean: false,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false)
        #expect(held.isArmed)

        let somebodyElse = KeepAwakeHelperStatus(
            build: "t", sleepDisabled: 1, ours: false, clean: true,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false)
        #expect(!somebodyElse.isArmed)
    }

    // MARK: - Ends and begins that overtake each other

    /// A hold sent and not yet answered, with an `end` arriving in it. The old
    /// code saw generation 0, sent no release and forgot — and then the hold's
    /// own late reply set `holding` and started the heartbeat again, for a
    /// session nobody was running and nobody would ever release.
    @Test("An end during the first pending hold still releases, and does not revive")
    func endDuringTheFirstHold() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        link.holdNextHold()

        let starting = Task { await client.begin(session: "s1") }
        try await waitUntil { !link.recordedHolds.isEmpty }

        await client.end()
        link.letHoldFinish()
        _ = await starting.value

        #expect(await client.currentState == .idle,
                "a session that was ended came back as held")
        #expect(link.recordedReleases.count == 1,
                "the hold already sent to the daemon was never released")
        #expect(link.recordedReleases.first?.generation == 1,
                "the release named a generation the daemon had never been told")
    }

    /// Every branch out of a renewal writes state, and most never go near the
    /// confirmation that has its own fence.
    @Test("A refusal that arrives after the session ended is not shown")
    func lateRefusalIsIgnored() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        link.holdNextHold()

        let starting = Task { await client.begin(session: "s1") }
        try await waitUntil { !link.recordedHolds.isEmpty }

        await client.end()
        link.letHoldFinish(answering: .busy)
        _ = await starting.value

        #expect(await client.currentState == .idle,
                "a session that was over was given a refusal to show")
    }

    /// The catch-up has awaits of its own, and the Low Power Mode push after
    /// it is one more. An end during that push left a perfectly good answer
    /// about a session that had already gone, and assigning it brought the
    /// session back as `holding`.
    @Test("A catch-up finishing after the session ended does not revive it")
    func catchUpCompletionAfterEnd() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)
        _ = await client.setLowPowerMode(true)
        let before = link.lowPowerInFlight

        // The daemon has moved far ahead — a restart, holding the generation
        // the last run reached — so the next heartbeat is stale and has to
        // catch up. The catch-up's last await is the Low Power Mode push.
        link.refusesBelow(generation: 10_000)
        link.holdNextLowPower()
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitUntil { link.lowPowerInFlight > before }

        // And the user switches it off while that push is still out.
        await client.end()
        #expect(await client.currentState == .idle)
        link.letLowPowerFinish()
        try await waitUntil { link.lowPowerInFlight > before }

        #expect(await client.currentState == .idle,
                "a session that was ended came back as held")
    }

    /// A release has to name the session it means. A provider on its way out
    /// can be delayed past the point where its replacement has taken a hold,
    /// and an unnamed release would end that one instead.
    @Test("A release naming another session leaves the live one alone")
    func namedEndOnlyEndsItsOwn() async {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        #expect(await client.begin(session: "live") == .holding)

        await client.end(session: "the-one-before")

        #expect(await client.currentState == .holding,
                "a stale release ended the session that replaced it")
        #expect(link.recordedReleases.isEmpty, "a release went out for a session that was over")

        await client.end(session: "live")
        #expect(link.recordedReleases.map(\.session) == ["live"])
    }

    @Test("An unnamed release still ends whatever is held")
    func unnamedEndStillEnds() async {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        #expect(await client.begin(session: "live") == .holding)
        await client.end(session: nil)
        #expect(await client.currentState == .idle)
        #expect(link.recordedReleases.map(\.session) == ["live"])
    }

    @Test("A hold the daemon accepts leaves the lid-closed mode on")
    func acceptedHold() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        let state = await client.begin(session: "s1")
        #expect(state == .holding)
        #expect(link.recordedHolds.count == 1)
        #expect(link.recordedHolds.first?.generation == 1)
        await client.end()
    }

    /// The lease, not our certainty, is what ends a hold. A daemon that has
    /// stopped answering has almost certainly not dropped anything yet, and
    /// reporting the hold as lost would have the card tell the user their Mac
    /// is about to sleep when it is not.
    @Test("A daemon that stops answering does not end the hold")
    func silenceIsNotDeath() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)

        link.goSilent()
        sleeper.timeOutCalls()
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()

        try await waitForState(client, .temporarilyUnavailable)
        await client.end()
    }

    /// A call that timed out may still be sitting in the daemon's queue. The
    /// daemon replaces a waiting heartbeat with a repeat of itself, so sending
    /// the same generation again collapses the two into one; sending a higher
    /// one would leave the first queued and add a second, and the queue only
    /// holds eight before it starts answering `busy`.
    @Test("A call that timed out is retried under the same generation")
    func timeoutRetriesTheSameRequest() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)
        #expect(link.recordedHolds.last?.generation == 1)

        link.goSilent()
        sleeper.timeOutCalls()
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitUntil { link.recordedHolds.count >= 2 }
        #expect(link.recordedHolds[1].generation == 2)

        // Still silent: the retry after a timeout must not claim a new number.
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitUntil { link.recordedHolds.count >= 3 }
        #expect(link.recordedHolds[2].generation == 2,
                "a timed-out heartbeat was retried under a new generation, leaving the first queued instead of replaced")
        await client.end()
    }

    /// A lapse nobody watched happen. The daemon retires the generation, and a
    /// heartbeat still carrying it is answered `stale` on purpose — repeating
    /// it would ask a question the daemon has already decided.
    @Test("A stale answer is caught up from at once, not over the next hour")
    func staleIsResynchronised() async throws {
        let link = FakeLink()
        link.willAnswer([.stale], thereafter: .ok)
        let client = Self.client(link, Sleeper())

        // One `stale`, then the catch-up finds a generation the daemon takes
        // without waiting for a heartbeat.
        #expect(await client.begin(session: "s1") == .holding)
        #expect(link.recordedHolds.first?.generation == 1)
        #expect(link.recordedHolds.count == 2)
        #expect(link.recordedHolds[1].generation > 1, "the catch-up repeated a decided request")
        await client.end()
    }

    /// The case the catch-up exists for. A relaunched app starts counting at
    /// one while the daemon still holds the generation the last run reached,
    /// and stepping by one takes a heartbeat per generation — fifty minutes
    /// of being refused for a session recovered at a hundred, with every
    /// reconnection keeping the daemon alive to go on refusing.
    @Test("A daemon far ahead of a restarted app is caught up within one beat")
    func restartCatchesUpImmediately() async throws {
        let link = FakeLink()
        link.refusesBelow(generation: 100)
        let client = Self.client(link, Sleeper())

        let outcome = await client.begin(session: "recovered")

        #expect(outcome == .holding, "a restarted app could not retake its own session")
        #expect(link.recordedHolds.count <= KeepAwakeHelperClient.staleCatchUpAttempts + 1)
        #expect((link.recordedHolds.last?.generation ?? 0) >= 100)
        await client.end()
    }

    @Test("A catch-up that gets nowhere leaves the refusal standing")
    func catchUpCanGiveUp() async throws {
        let link = FakeLink()
        link.willAnswer([], thereafter: .stale)
        let client = Self.client(link, Sleeper())

        #expect(await client.begin(session: "s1") == .refused(.stale))
        #expect(link.recordedHolds.count == KeepAwakeHelperClient.staleCatchUpAttempts + 1,
                "the catch-up did not stop where it said it would")
        await client.end()
    }

    @Test("Generations only ever go up")
    func generationsNeverGoBackwards() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)

        for expected in 2...4 {
            try await waitUntil { sleeper.beatsWaiting > 0 }
            sleeper.beat()
            try await waitUntil { link.recordedHolds.count >= expected }
        }

        let generations = link.recordedHolds.map(\.generation)
        #expect(generations == Array(1...generations.count))
        await client.end()
    }

    /// The daemon refuses a deadline later than the one a session already
    /// fixed, so sending one would be asking to be told no.
    @Test("The deadline is fixed by the first hold, not by the heartbeat")
    func deadlineIsFixedOnce() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        let wanted = Self.t0.addingTimeInterval(3600)
        _ = await client.begin(session: "s1", until: wanted)

        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitUntil { link.recordedHolds.count >= 2 }

        #expect(link.recordedHolds.allSatisfy { $0.deadline == wanted })
        await client.end()
    }

    /// The daemon refuses a deadline later than the one a session already
    /// fixed. Re-arming the same session — a resume, a coordinator that calls
    /// begin again — must therefore not carry a new one, or the hold the user
    /// can see would be refused for asking.
    @Test("Beginning the same session again does not move its deadline")
    func reBeginningKeepsTheFirstDeadline() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        let first = Self.t0.addingTimeInterval(3600)
        _ = await client.begin(session: "s1", until: first)
        _ = await client.begin(session: "s1", until: Self.t0.addingTimeInterval(86400))

        #expect(link.recordedHolds.count == 2)
        #expect(link.recordedHolds.allSatisfy { $0.deadline == first },
                "a second begin pushed the deadline out, which the daemon refuses")
        await client.end()
    }

    /// A different session is a different hold, and fixes its own deadline.
    @Test("A new session fixes its own deadline")
    func newSessionFixesItsOwn() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        _ = await client.begin(session: "s1", until: Self.t0.addingTimeInterval(3600))
        await client.end()
        let second = Self.t0.addingTimeInterval(7200)
        _ = await client.begin(session: "s2", until: second)
        #expect(link.recordedHolds.last?.deadline == second)
        #expect(link.recordedHolds.last?.generation == 1, "a new session starts its generations again")
        await client.end()
    }

    /// Switching sessions without ending the old one — a resume path, a
    /// coordinator handing over — still starts the new session's generations
    /// at the beginning. Carrying the old session's number over would work by
    /// accident (the daemon only forbids going backwards) but leaves the
    /// numbers meaning two different things at once.
    @Test("A session taking over from another starts its generations again")
    func takingOverStartsFresh() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        _ = await client.begin(session: "s1")

        for expected in 2...3 {
            try await waitUntil { sleeper.beatsWaiting > 0 }
            sleeper.beat()
            try await waitUntil { link.recordedHolds.count >= expected }
        }
        #expect(link.recordedHolds.last?.generation == 3)

        _ = await client.begin(session: "s2")
        #expect(link.recordedHolds.last?.session == "s2")
        #expect(link.recordedHolds.last?.generation == 1,
                "the new session carried the previous one's generation over")
        await client.end()
    }

    /// The switch asks for no deadline at all: it ends when the user ends it,
    /// and if Ledge dies the lease ends it instead.
    @Test("The switch holds with no deadline")
    func switchHoldsIndefinitely() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        _ = await client.begin(session: "s1")
        #expect(link.recordedHolds.first?.deadline == nil)
        await client.end()
    }

    @Test("The lease asked for is the one the daemon clamps around")
    func leaseIsInRange() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        _ = await client.begin(session: "s1")
        let lease = try #require(link.recordedHolds.first?.lease)
        #expect(lease == KeepAwakeHelperClient.lease)
        #expect(lease >= 30 && lease <= 120, "outside the range the daemon accepts unclamped")
    }

    /// Stopping the heartbeat first is the whole of it: a renewal landing
    /// after the release would take the hold straight back, and the user who
    /// switched it off would find it on.
    @Test("Ending stops the heartbeat before it gives the hold back")
    func endStopsTheHeartbeatFirst() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        _ = await client.begin(session: "s1")
        try await waitUntil { sleeper.beatsWaiting > 0 }

        await client.end()
        let afterEnd = link.recordedHolds.count

        // Whatever was waiting on the heartbeat gate is cancelled, so letting
        // it go must not produce another hold.
        sleeper.beat()
        try await Task.sleep(for: .milliseconds(50))

        #expect(link.recordedHolds.count == afterEnd)
        #expect(link.recordedReleases.count == 1)
        #expect(await client.currentState == .idle)
    }

    /// The window that matters is the one *inside* `end()`: a release can take
    /// seconds to answer, and a heartbeat landing in that gap would take the
    /// hold straight back — the user switches it off and finds it on.
    @Test("No heartbeat slips in while the release is still being answered")
    func noHoldDuringTheRelease() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        _ = await client.begin(session: "s1")
        try await waitUntil { sleeper.beatsWaiting > 0 }

        link.holdNextRelease()
        let ending = Task { await client.end() }
        try await waitUntil { link.releasesInFlight == 1 }

        let before = link.recordedHolds.count
        sleeper.beat()
        try await Task.sleep(for: .milliseconds(50))
        #expect(link.recordedHolds.count == before,
                "a heartbeat renewed the hold while it was being given back")

        link.letReleaseFinish()
        await ending.value
        #expect(await client.currentState == .idle)
    }

    @Test("A release names the generation the hold was taken under")
    func releaseNamesTheGeneration() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        _ = await client.begin(session: "s1")
        await client.end()
        #expect(link.recordedReleases.first?.session == "s1")
        #expect(link.recordedReleases.first?.generation == 1)
    }

    @Test("Ending a session that never took a hold asks the daemon for nothing")
    func endingNothingIsQuiet() async throws {
        let link = FakeLink()
        let client = Self.client(link, Sleeper())
        await client.end()
        #expect(link.recordedReleases.isEmpty)
        #expect(await client.currentState == .idle)
    }

    @Test("A refusal is reported as the daemon's own code")
    func refusalKeepsItsReason() async throws {
        let link = FakeLink()
        link.willAnswer([.inUseByOtherLedge], thereafter: .inUseByOtherLedge)
        let client = Self.client(link, Sleeper())
        #expect(await client.begin(session: "s1") == .refused(.inUseByOtherLedge))
        await client.end()
    }

    // MARK: - What the status means

    @Test("Sleep disabled by somebody who is not Ledge reads as foreign")
    func foreignIsDerived() {
        let foreign = KeepAwakeHelperStatus(
            build: "b", sleepDisabled: 1, ours: false, clean: true,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false)
        #expect(foreign.isForeign)
        #expect(!foreign.isArmed)
    }

    @Test("The other build holding it is not foreign")
    func otherLedgeIsNotForeign() {
        let other = KeepAwakeHelperStatus(
            build: "b", sleepDisabled: 1, ours: false, clean: true,
            cleanupPending: false, otherLedgeHolds: true, lowPowerClaimed: false)
        #expect(!other.isForeign)
    }

    @Test("Our own hold is not foreign")
    func ourHoldIsNotForeign() {
        let ours = KeepAwakeHelperStatus(
            build: "b", sleepDisabled: 1, ours: true, clean: false,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false)
        #expect(!ours.isForeign)
        #expect(ours.isArmed)
    }

    /// A claim still waiting to be put back needs the daemon alive to put it
    /// back, so a pending cleanup is not a state to unregister from however
    /// clean the rest of it looks.
    @Test("A pending cleanup keeps the daemon registered")
    func cleanupPendingBlocksUnregister() {
        let pending = KeepAwakeHelperStatus(
            build: "b", sleepDisabled: 0, ours: false, clean: true,
            cleanupPending: true, otherLedgeHolds: false, lowPowerClaimed: false)
        #expect(!pending.mayUnregister)

        let settled = KeepAwakeHelperStatus(
            build: "b", sleepDisabled: 0, ours: false, clean: true,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false)
        #expect(settled.mayUnregister)
    }

    /// Sleep disabled by somebody else is still clean: it is not Ledge's to
    /// undo, so it is no reason to keep a daemon around.
    @Test("Somebody else's setting does not keep the daemon registered")
    func foreignDoesNotBlockUnregister() {
        let foreign = KeepAwakeHelperStatus(
            build: "b", sleepDisabled: 1, ours: false, clean: true,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false)
        #expect(foreign.mayUnregister)
    }

    @Test("A status call that times out leaves the last known status alone")
    func statusTimeoutKeepsWhatWeKnew() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        link.reports(KeepAwakeHelperStatus(
            build: "b", sleepDisabled: 1, ours: true, clean: false,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false))
        let first = await client.refreshStatus()
        #expect(first?.ours == true)

        link.goSilent()
        sleeper.timeOutCalls()
        let second = await client.refreshStatus()
        #expect(second == nil, "a timeout must not be reported as an answer")
        #expect(await client.status?.ours == true, "the last real answer was thrown away")
    }
}


/// Somewhere a Task can put an answer that the test polls for, so a wait can
/// be bounded without a task group.
private final class Answer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: KeepAwakeHelperState?
    func set(_ state: KeepAwakeHelperState) { lock.withLock { stored = state } }
    var value: KeepAwakeHelperState? { lock.withLock { stored } }
}


/// The same silence, opposite facts.
///
/// A daemon that goes quiet on a hold it already accepted has very probably
/// still got it — it drops a hold on its own lease, not on Ledge's inability
/// to reach it. A daemon that has never answered at all is holding nothing.
/// These were one state, and the card said "it almost certainly still stands"
/// to somebody whose Mac nothing was holding, who then shut the lid on it.
@Suite("Silence before a hold, and silence after one", .timeLimit(.minutes(10)))
struct KeepAwakeSilenceTests {

    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("A hold that was never accepted reads as unreachable")
    func neverAcceptedIsUnreachable() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = KeepAwakeHelperClient(link: link, now: { Self.t0 }, sleep: sleeper.sleep)

        link.goSilent()
        sleeper.timeOutCalls()
        let state = await client.begin(session: "s1")

        // The bug this was written for was the opposite claim — a hold
        // nobody ever took reported as very probably standing. That claim is
        // still refused. What has changed is the other end: a request that
        // went out and was never answered is not proof that nothing is held.
        #expect(state != .temporarilyUnavailable,
                "a hold nobody ever took was reported as very probably standing")
        #expect(state == .unknownWhetherHeld,
                "and a request that got no answer is not proof of absence")
        link.releaseStranded()
        await client.end()
    }

    /// And the other half, which must keep working: once a hold has been
    /// accepted, silence is a warning rather than a death.
    @Test("A hold that was accepted and then went quiet stays a warning")
    func acceptedThenQuietIsAWarning() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = KeepAwakeHelperClient(link: link, now: { Self.t0 }, sleep: sleeper.sleep)

        #expect(await client.begin(session: "s1") == .holding)

        link.goSilent()
        sleeper.timeOutCalls()
        while sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()

        var seen = await client.currentState
        while seen != .temporarilyUnavailable {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }
        #expect(seen == .temporarilyUnavailable,
                "a hold that was taken and went quiet was reported as never taken")
        link.releaseStranded()
        await client.end()
    }

    @Test("A hold that was accepted and never applied is never reassured about")
    func acceptanceIsNotApplication() async throws {
        // The daemon answers a `begin` once its lease is on disk and before
        // it runs the privileged write, so an acceptance says a request got
        // through and nothing about the Mac. Recording it as evidence meant
        // a hold that was accepted, reported SleepDisabled=0, and then failed
        // to renew read as "almost certainly still standing" over a Mac that
        // nothing was holding.
        let link = FakeLink()
        let sleeper = Sleeper()
        let clock = MovableClock(Self.t0)
        let client = KeepAwakeHelperClient(link: link, now: { clock.now }, sleep: sleeper.sleep)

        // The daemon takes the lease and the privileged write does not land,
        // which is exactly what `ok` promises and does not deliver.
        link.refusesTheApply()
        _ = await client.begin(session: "s1")
        link.goSilent()
        sleeper.timeOutCalls()
        while sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()

        var seen = await client.currentState
        while seen == .pending || seen == .holding {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }
        #expect(seen != .temporarilyUnavailable,
                "acceptance was standing in for confirmation, which it is not")
        #expect(seen == .unknownWhetherHeld, "and what is true is that nothing can vouch for it")
        link.releaseStranded()
        await client.end()
    }

    @Test("A fresh reading changes what the card says, now")
    func freshStatusReconcilesTheState() async throws {
        // Evidence was being filed and nothing else. It changed what a
        // *later* silence would conclude, which is not what somebody asking
        // for a fresh reading wants: the card could be told the setting was
        // off and go on saying held, or be told it was on and go on saying
        // Checking. Both directions, both reproduced.
        let link = FakeLink()
        let sleeper = Sleeper()
        let clock = MovableClock(Self.t0)
        let client = KeepAwakeHelperClient(link: link, now: { clock.now }, sleep: sleeper.sleep)

        #expect(await client.begin(session: "s1") == .holding)

        // The daemon lets go behind our back.
        link.reports(KeepAwakeHelperStatus(
            build: "test", sleepDisabled: 0, ours: false, clean: true,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false
        ))
        clock.advance(1)
        _ = await client.refreshStatus()
        #expect(await client.currentState != .holding,
                "a reading that says the setting is off must take the card off held")

        // And back again: the setting is on, and the card must stop hedging.
        link.reports(KeepAwakeHelperStatus(
            build: "test", sleepDisabled: 1, ours: true, clean: false,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false
        ))
        clock.advance(1)
        _ = await client.refreshStatus()
        #expect(await client.currentState == .holding,
                "a reading that says the setting is on must say so")
        await client.end()
    }

    /// **This test does not currently discriminate.** Removing the fence it
    /// is written for — the era and session captured before the status call —
    /// leaves it green. The reviewer reproduced the bug with a harness that
    /// can gate the client's own continuations; this fake can gate the link's
    /// answer and not the client's resumption, and the straggler lands in an
    /// order that does not corrupt what is then asked. Kept because the
    /// scenario is worth writing down and the fix is worth keeping, but it
    /// should not be read as a guard until it can be made to fail.
    @Test("An observation belongs to the session it was taken for")
    func observationsDoNotCrossSessions() async throws {
        // A status held in flight while its session ended and another began
        // came back and filed itself as the *new* session's evidence, so B
        // read as "almost certainly still stands" on the strength of
        // something only ever true of A.
        let link = FakeLink()
        let sleeper = Sleeper()
        let clock = MovableClock(Self.t0)
        let client = KeepAwakeHelperClient(link: link, now: { clock.now }, sleep: sleeper.sleep)

        #expect(await client.begin(session: "A") == .holding)

        // A's status is in the air when A ends and B begins. Released after,
        // it must not become B's evidence — and it has to be a *positive*
        // reading, or there is no false confirmation for the fence to stop
        // and the test passes whatever the code does.
        link.reports(KeepAwakeHelperStatus(
            build: "test", sleepDisabled: 1, ours: true, clean: false,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false
        ))
        link.holdNextStatus()
        let straggler = Task { await client.refreshStatus() }
        try await Task.sleep(for: .milliseconds(20))
        await client.end()

        // B never gets an answer to anything.
        link.goSilent()
        sleeper.timeOutCalls()
        let b = await client.begin(session: "B")
        #expect(b == .unknownWhetherHeld, "the premise: B has had no answer to anything")

        // Only now does A's reading come back. Measured after it lands —
        // asserting before it did was asking the question before the thing
        // under test had happened.
        link.releaseHeldStatus()
        _ = await straggler.value

        // A beat, so B asks again and gets nothing again.
        while sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()
        var seen = await client.currentState
        // Bounded on purpose: the right answer is that nothing changes, so
        // this is a chance for the wrong one to show, and a slow run can only
        // make it miss.
        for _ in 0 ..< 200 where seen == .unknownWhetherHeld {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }
        #expect(seen != .temporarilyUnavailable,
                "B inherited A's confirmation and claimed the hold almost certainly stands")
        link.releaseStranded()
        await client.end()
    }

    @Test("A newer reading that says off ends an older confirmation")
    func negativeEvidenceWins() async throws {
        // A status reporting the setting off is a fact about a later moment
        // than the confirmation before it. It was recorded nowhere, so a
        // renewal that then went unanswered produced "almost certainly still
        // stands" out of evidence a newer reading had already refuted.
        let link = FakeLink()
        let sleeper = Sleeper()
        let clock = MovableClock(Self.t0)
        let client = KeepAwakeHelperClient(link: link, now: { clock.now }, sleep: sleeper.sleep)

        #expect(await client.begin(session: "s1") == .holding, "confirmed once")

        // The daemon lets go behind our back, and the next status says so.
        link.reports(KeepAwakeHelperStatus(
            build: "test", sleepDisabled: 0, ours: false, clean: true,
            cleanupPending: false, otherLedgeHolds: false, lowPowerClaimed: false
        ))
        clock.advance(1)
        _ = await client.refreshStatus()

        // Then it stops answering altogether.
        link.goSilent()
        sleeper.timeOutCalls()
        while sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()

        var seen = await client.currentState
        // Bounded on purpose: what is asserted is only what the state must not
        // become, so this is a chance for the wrong answer to show, and a slow
        // run can only make it miss.
        for _ in 0 ..< 400 where seen == .holding {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }
        #expect(seen != .temporarilyUnavailable,
                "an older confirmation outlived the reading that contradicted it")
        link.releaseStranded()
        await client.end()
    }

    @Test("Confidence expires on the clock, not on the next request")
    func confidenceExpiresWithoutAnotherCall() async throws {
        // It was only ever recomputed when a call came back, so a client
        // whose daemon had gone away kept answering "almost certainly still
        // stands" for as long as nothing else happened — and nothing else
        // happening is exactly the case this covers.
        let link = FakeLink()
        let sleeper = Sleeper()
        let clock = MovableClock(Self.t0)
        let client = KeepAwakeHelperClient(link: link, now: { clock.now }, sleep: sleeper.sleep)

        #expect(await client.begin(session: "s1") == .holding)
        link.goSilent()
        sleeper.timeOutCalls()
        while sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()
        var seen = await client.currentState
        while seen != .temporarilyUnavailable {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }

        // No further heartbeat, no further call. Only time passes.
        clock.advance(KeepAwakeHelperClient.confidenceWindow + 1)
        #expect(await client.currentState == .unknownWhetherHeld,
                "the reassurance outlived the lease because nothing asked it to stop")
        link.releaseStranded()
        await client.end()
    }

    @Test("Confidence in a silent hold does not outlast the lease it stood on")
    func silenceExpiresWithTheLease() async throws {
        // The warning above is right for a daemon that answered a moment ago
        // and is right for nobody an hour later. The hold stands on a lease
        // the daemon itself renews; once a whole lease has passed with
        // nothing accepted, the daemon has either let go or is not there, and
        // "it almost certainly still stands" is no longer a reading of any
        // evidence. It was said for ever, because the flag behind it recorded
        // *that* a hold was accepted and never *when*.
        let link = FakeLink()
        let sleeper = Sleeper()
        // A clock the test moves, rather than a fixed instant.
        let clock = MovableClock(Self.t0)
        let client = KeepAwakeHelperClient(link: link, now: { clock.now }, sleep: sleeper.sleep)

        #expect(await client.begin(session: "s1") == .holding)

        link.goSilent()
        sleeper.timeOutCalls()

        // Inside the lease: still a warning.
        clock.advance(KeepAwakeHelperClient.confidenceWindow - 1)
        while sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()
        var seen = await client.currentState
        while seen != .temporarilyUnavailable {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }
        #expect(seen == .temporarilyUnavailable, "inside the lease, silence is still a warning")

        // Past it: the lease the hold stood on has run out.
        clock.advance(2)
        while sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()
        while seen != .unknownWhetherHeld {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }
        // Not a refusal. A renewal the daemon took whose reply was lost looks
        // exactly like this, and the hold is then standing — so saying it
        // lapsed is inventing an answer nobody gave. What is true is that
        // nothing can vouch for it.
        #expect(seen == .unknownWhetherHeld,
                "past the lease, the card must stop claiming the hold stands")
        link.releaseStranded()
        await client.end()
    }

    /// A new session does not inherit the last one's acceptance.
    @Test("Ending forgets that a hold was ever accepted")
    func endingForgets() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = KeepAwakeHelperClient(link: link, now: { Self.t0 }, sleep: sleeper.sleep)

        #expect(await client.begin(session: "s1") == .holding)
        await client.end()

        link.goSilent()
        sleeper.timeOutCalls()
        let fresh = await client.begin(session: "s2")
        #expect(fresh != .temporarilyUnavailable,
                "a new session inherited the last one's hold")
        #expect(fresh == .unknownWhetherHeld,
                "its own unanswered request is unknown, not absent")
        link.releaseStranded()
        await client.end()
    }
}


/// A clock a test can move, for the rules that are about elapsed time rather
/// than about order.
final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}


/// A daemon from before the update, and the way out of it.
///
/// After an update the helper still running is the old copy, out of a bundle
/// that has been deleted. Everything the app sends it lands and is acted on;
/// every answer it sends is refused by the app's code signing check. The app
/// cannot tell it to leave, so it gives the hold back, says nothing at all
/// long enough for the old copy's own idle rule to fire, and asks again —
/// which starts the new copy. These pin each part of that, and that the card
/// is never told the lid is covered while it happens.
@Suite("Handing over from a helper an update left behind", .timeLimit(.minutes(10)))
struct KeepAwakeHandoverTests {

    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    private static func client(
        _ link: FakeLink, _ sleeper: Sleeper,
        installed: @escaping @Sendable () -> KeepAwakeInstalledHelper = { .passes }
    ) -> KeepAwakeHelperClient {
        KeepAwakeHelperClient(link: link, now: { t0 }, sleep: sleeper.sleep,
                              silence: sleeper.silence, installedHelper: installed)
    }

    /// For as long as it takes; the suite's time limit catches a condition
    /// that never comes.
    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        while !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForState(_ client: KeepAwakeHelperClient,
                              _ wanted: KeepAwakeHelperState) async throws {
        while await client.currentState != wanted {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// What the card would be told right now.
    private func reading(_ client: KeepAwakeHelperClient) async -> KeepAwakeLidState {
        KeepAwakeLidState.reading(installation: .installed,
                                  client: await client.currentState,
                                  status: await client.status)
    }

    // MARK: - The window

    /// Three numbers that only mean anything together. The silence has to
    /// outlast the old copy's own exit rule at its worst, and the old copy
    /// was built before this one — so its numbers are pinned, not merely
    /// read. The test sleeper also tells the client's sleeps apart by their
    /// length, so the three must differ.
    @Test("The silence outlasts the old helper's own idle rule, and no more than it must")
    func silenceIsTheHelpersOwnRule() {
        #expect(HelperLimits.idleExitAfter == 60,
                "every helper already installed exits after sixty idle seconds")
        #expect(HelperLimits.idleCheckEvery == 60,
                "and asks whether to every sixty")
        let worst = HelperLimits.idleExitAfter + HelperLimits.idleCheckEvery
        #expect(KeepAwakeHelperClient.handoverSilence > worst,
                "the old helper could still be there when the silence ends")
        #expect(KeepAwakeHelperClient.handoverSilence <= worst + 30,
                "a silence this long is time nobody can use the lid for nothing")
        #expect(KeepAwakeHelperClient.handoverSilence != KeepAwakeHelperClient.heartbeat)
        #expect(KeepAwakeHelperClient.handoverSilence != KeepAwakeHelperClient.callTimeout)
    }

    // MARK: - With a hold standing

    @Test("A refused answer gives the hold back once, says nothing, then holds again higher")
    func handoverFromAStandingHold() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)
        _ = await client.setLowPowerMode(true)

        // The update. The next heartbeat lands on the old copy and its answer
        // is refused.
        link.goesOutOfDate()
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()

        // Arrived: the silence has begun, which is the only point the
        // silence can be measured from.
        try await waitUntil { sleeper.silencesWaiting == 1 }
        #expect(await client.currentState == .handingOver)
        #expect(link.recordedHolds.last?.generation == 2, "the premise: the heartbeat went out")
        // One release, naming the heartbeat the old copy took without saying so.
        #expect(link.recordedReleases.map(\.session) == ["s1"])
        #expect(link.recordedReleases.first?.generation == 2,
                "the release named a generation older than the one the old helper is holding")

        // Everything that would normally talk to the daemon, asked at once.
        let quietFrom = link.callLog.count
        #expect(await client.refreshStatus() == nil)
        #expect(await client.setLowPowerMode(true) == nil)
        #expect(await client.begin(session: "s1") == .handingOver)
        sleeper.beat()
        try await Task.sleep(for: .milliseconds(50))
        #expect(link.callLog.count == quietFrom,
                "the old helper was spoken to during the silence: \(link.callLog.dropFirst(quietFrom))")

        // The old copy has gone. The next call reaches the new one.
        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .holding)
        let rehold = try #require(link.recordedHolds.last)
        #expect(rehold.session == "s1")
        #expect(rehold.generation > 2,
                "the hold after the handover reused a generation that was already given back")
        // Low Power Mode goes again behind the new hold, as it does behind
        // every renewal.
        try await waitUntil { link.recordedLowPower.last?.generation == rehold.generation }
        // And the heartbeat is back.
        try await waitUntil { sleeper.beatsWaiting > 0 }
        await client.end()
    }

    /// The headline rule of the card: nothing may say the lid is covered when
    /// nothing can confirm it. The last status the old copy managed to send
    /// before the update said it was holding, and that must not count.
    @Test("A handover never reads as a hold, whatever the last status said")
    func handoverIsNeverAHold() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)
        #expect(await client.status?.isArmed == true, "the premise: the last word was a hold")

        link.goesOutOfDate()
        #expect(await client.refreshStatus() == nil)
        try await waitUntil { sleeper.silencesWaiting == 1 }

        let seen = await reading(client)
        #expect(seen == .handover(.underWay))
        #expect(!seen.isConfirmed)
        #expect(!seen.isLive, "the hold was given back; nothing is covering the lid")
        #expect(!seen.mayArm)
        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .holding)
        await client.end()
    }

    @Test("A session that ends during the silence is not held again, or released twice")
    func endingDuringTheSilence() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)

        link.goesOutOfDate()
        _ = await client.refreshStatus()
        try await waitUntil { sleeper.silencesWaiting == 1 }
        #expect(link.recordedReleases.count == 1, "the premise: the handover gave the hold back")

        await client.end(session: "s1")
        #expect(link.recordedReleases.count == 1,
                "a second release went to the old helper and reset its idle clock")
        #expect(await client.currentState == .handingOver,
                "a session ending is not the handover ending")

        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .idle)
        #expect(link.recordedHolds.count == 1, "a session that had ended was held again")
    }

    @Test("A session that begins during the silence waits for the new helper")
    func beginningDuringTheSilence() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        let deadline = Self.t0.addingTimeInterval(3600)

        link.goesOutOfDate()
        _ = await client.refreshStatus()
        try await waitUntil { sleeper.silencesWaiting == 1 }

        #expect(await client.begin(session: "s2", until: deadline) == .handingOver)
        #expect(link.recordedHolds.isEmpty, "a hold went to the old helper during the silence")

        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .holding)
        #expect(link.recordedHolds.map(\.session) == ["s2"])
        #expect(link.recordedHolds.first?.deadline == deadline,
                "the deadline the session fixed did not survive the wait")
        await client.end()
    }

    /// `end` sends its own release, and that release is the first to hear
    /// the old copy refuse. It has already landed, so the handover owes
    /// nothing more — but with no session left, the next reading would
    /// otherwise have been "off".
    @Test("A release that comes back refused starts the handover and is not sent again")
    func refusedRelease() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)

        link.goesOutOfDate()
        await client.end()
        try await waitUntil { sleeper.silencesWaiting == 1 }
        #expect(await client.currentState == .handingOver)
        #expect(link.recordedReleases.count == 1)
        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .idle)
    }

    // MARK: - With nothing running

    /// The second half of the bug. With no session the failed status became
    /// `.off`, and the card offered the mode as ready over a helper nothing
    /// could hear.
    @Test("With nothing running, the old helper reads as a handover rather than off")
    func nothingRunningIsNotOff() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)

        link.goesOutOfDate()
        #expect(await client.refreshStatus() == nil, "a refused answer was reported as one")
        #expect(link.callLog == ["status"], "the premise: the old helper was asked, and refused")
        let seen = await reading(client)
        #expect(seen == .handover(.underWay))
        #expect(seen != .off)
        #expect(!seen.mayArm, "the mode was offered over a helper nothing can hear")

        try await waitUntil { sleeper.silencesWaiting == 1 }
        #expect(link.recordedReleases.isEmpty, "nothing was held, so nothing is given back")

        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .idle)
        #expect(link.callLog == ["status", "status"])
        #expect(await client.status != nil, "the new helper's answer was not kept")
        #expect(await reading(client) == .off, "once the new helper answers, the mode is offered")
    }

    // MARK: - Giving up, and not for good

    @Test("Still the old helper after two silences: restart needed, and quiet between slow questions")
    func twoRoundsThenRestart() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)

        link.goesOutOfDate()
        #expect(await client.begin(session: "s1") == .handingOver)
        try await waitUntil { sleeper.silencesWaiting == 1 }
        #expect(link.recordedReleases.map(\.generation) == [1],
                "the hold the old helper took without answering was not given back")

        // The first silence ends on the old copy.
        sleeper.endSilence()
        try await waitUntil { sleeper.silencesBegun == 2 && sleeper.silencesWaiting == 1 }
        #expect(await client.currentState == .handingOver, "one refusal after a silence is not the end")
        #expect(link.callLog == ["hold", "release", "status"])

        // And so does the second.
        sleeper.endSilence()
        try await waitForState(client, .restartNeeded)
        #expect(link.callLog == ["hold", "release", "status", "status"])
        #expect(await reading(client) == .handover(.restartNeeded))

        // Arrived at the slow questions: a third wait has begun, and it is
        // longer than the old helper's whole exit rule, so that rule can
        // still fire between two of them.
        try await waitUntil { sleeper.silencesBegun == 3 && sleeper.silencesWaiting == 1 }
        let lengths = sleeper.silenceLengths
        #expect(lengths.prefix(2).allSatisfy { $0 == KeepAwakeHelperClient.handoverSilence })
        #expect(lengths.last == KeepAwakeHelperClient.restartProbeEvery)
        #expect(KeepAwakeHelperClient.restartProbeEvery >= KeepAwakeHelperClient.handoverSilence,
                "a question sooner than the exit rule resets the old helper's clock every time")

        // Between questions nothing reaches anybody.
        let quietFrom = link.callLog.count
        #expect(await client.refreshStatus() == nil)
        #expect(await client.begin(session: "s1") == .restartNeeded)
        #expect(await client.setLowPowerMode(true) == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(link.callLog.count == quietFrom,
                "the old helper was spoken to between the slow questions")

        // A slow question the old copy still refuses changes nothing.
        sleeper.endSilence()
        try await waitUntil { sleeper.silencesBegun == 4 && sleeper.silencesWaiting == 1 }
        #expect(link.callLog.count == quietFrom + 1, "exactly one question per wait")
        #expect(link.callLog.last == "status")
        #expect(await client.currentState == .restartNeeded)
        await client.end()
    }

    /// "Restart needed" was final for the life of the app. The old copy can
    /// still get clean and leave — a restore that took its time, a Mac that
    /// slept through more than any margin — and then nothing ever asked
    /// again, so the card went on saying restart over a helper that had gone.
    @Test("A slow question that gets through ends restart needed and holds again")
    func restartNeededIsNotFinal() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)

        link.goesOutOfDate()
        #expect(await client.begin(session: "s1") == .handingOver)
        try await waitUntil { sleeper.silencesWaiting == 1 }
        sleeper.endSilence()
        try await waitUntil { sleeper.silencesBegun == 2 && sleeper.silencesWaiting == 1 }
        sleeper.endSilence()
        try await waitForState(client, .restartNeeded)
        try await waitUntil { sleeper.silencesBegun == 3 && sleeper.silencesWaiting == 1 }
        let heldBefore = link.recordedHolds.count

        // The old copy has gone after all.
        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .holding)
        let rehold = try #require(link.recordedHolds.last)
        #expect(link.recordedHolds.count == heldBefore + 1)
        #expect(rehold.session == "s1")
        #expect(rehold.generation > 1, "the hold reused the generation that was given back")
        try await waitUntil { sleeper.beatsWaiting > 0 }
        await client.end()
    }

    // MARK: - After the silence, ordinary trouble

    /// A question after the silence that is not refused ends the handover,
    /// whatever else is wrong. A daemon that is merely slow is the ordinary
    /// rules' business, and the session's hold has to be taken again under
    /// them rather than left waiting on a handover that is over.
    @Test("A timeout after the silence ends the handover and the hold is asked for again")
    func timeoutAfterTheSilence() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper)
        #expect(await client.begin(session: "s1") == .holding)

        link.goesOutOfDate()
        _ = await client.refreshStatus()
        try await waitUntil { sleeper.silencesWaiting == 1 }
        let heldBefore = link.recordedHolds.count

        // The new daemon is not answering yet: neither refused nor heard.
        link.comesBackUpToDate()
        link.goSilent()
        sleeper.timeOutCalls()
        sleeper.endSilence()
        try await waitUntil { link.recordedHolds.count > heldBefore }
        var seen = await client.currentState
        while seen == .handingOver {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }
        // The re-hold went out and was not heard, which the ordinary rules
        // read as an unknown outcome — not as the handover, and not as held.
        #expect(seen == .unknownWhetherHeld)
        #expect(sleeper.silencesBegun == 1, "a timeout started another silence")
        try await waitUntil { sleeper.beatsWaiting > 0 }

        // And the ordinary rules carry it from there. Beaten until a hold
        // goes out: the heartbeat from before the handover was cancelled
        // with its wait still parked in the sleeper, and the first beat can
        // land on that one and wake nothing.
        link.speakAgain()
        sleeper.answerCallsAgain()
        let holdsBefore = link.recordedHolds.count
        while link.recordedHolds.count == holdsBefore {
            sleeper.beat()
            try await Task.sleep(for: .milliseconds(5))
        }
        try await waitForState(client, .holding)
        link.releaseStranded()
        await client.end()
    }

    // MARK: - A refusal that is not a leftover process

    /// The helper on disk would be refused too, so this is the installation
    /// rather than an update's leftover. A restart starts the same helper
    /// again, and the handover's release would only take away a hold that
    /// is very probably standing — everything sent still lands.
    @Test("With the installed helper failing the check: no release, no silence, the hold kept going")
    func mismatchedHelperKeepsTheHold() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let asked = CallCounter()
        let client = Self.client(link, sleeper, installed: { asked.bump(); return .fails })
        #expect(await client.begin(session: "s1") == .holding)
        #expect(asked.value == 0, "the helper on disk was checked with nothing refused")

        link.goesOutOfDate()
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitForState(client, .helperMismatch)
        #expect(asked.value == 1)
        #expect(link.recordedReleases.isEmpty, "a hold the user still wants was given back")
        #expect(sleeper.silencesBegun == 0, "a silence was kept for a helper no wait will replace")
        let seen = await reading(client)
        #expect(seen == .helperMismatch)
        #expect(!seen.isConfirmed && !seen.isLive && !seen.mayArm)

        // The heartbeat goes on landing, under the generation nobody has
        // answered, and the check is not asked again.
        let holds = link.recordedHolds.count
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitUntil { link.recordedHolds.count > holds }
        #expect(link.recordedHolds.last?.generation == link.recordedHolds[holds - 1].generation)
        #expect(await client.refreshStatus() == nil)
        #expect(await client.currentState == .helperMismatch)
        #expect(asked.value == 1, "the helper on disk was checked more than once")

        // Ending it still gives the hold back, and the reading stays.
        await client.end()
        #expect(link.recordedReleases.map(\.session) == ["s1"])
        #expect(await client.currentState == .helperMismatch,
                "a session ending does not fix the installation")
    }

    @Test("With the installed helper passing the check, a refusal is a handover")
    func passingHelperIsAHandover() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let asked = CallCounter()
        let client = Self.client(link, sleeper, installed: { asked.bump(); return .passes })

        link.goesOutOfDate()
        _ = await client.refreshStatus()
        #expect(asked.value == 1, "the helper on disk was never asked about")
        #expect(await client.currentState == .handingOver)
        try await waitUntil { sleeper.silencesWaiting == 1 }
        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .idle)
    }

    /// A check that could not be made is no evidence against the rescue.
    @Test("An installed helper that could not be checked is treated as passing")
    func uncheckedIsAHandover() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper, installed: { .unchecked })
        link.goesOutOfDate()
        _ = await client.refreshStatus()
        #expect(await client.currentState == .handingOver)
        try await waitUntil { sleeper.silencesWaiting == 1 }
        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .idle)
    }

    @Test("An answer that is heard takes the mismatch off")
    func heardAnswerEndsTheMismatch() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let client = Self.client(link, sleeper, installed: { .fails })
        link.goesOutOfDate()
        _ = await client.refreshStatus()
        #expect(await client.currentState == .helperMismatch)

        link.comesBackUpToDate()
        #expect(await client.refreshStatus() != nil)
        #expect(await client.currentState == .idle)
        #expect(await reading(client) == .off)
    }

    // MARK: - A fail read while the bundle was being written

    /// Finder's Replace, `ditto`, an installer copying over the app in
    /// place: the helper reads as failing while it is half written, and the
    /// copy finishing leaves the stale process a handover exists for. A fail
    /// kept for good said "reinstall" until a relaunch, through the reinstall
    /// itself, while the heartbeat kept the stale helper alive.
    @Test("A fail read mid-copy is asked again, and the pass that follows hands over")
    func halfWrittenThenFixed() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let clock = MovableClock(Self.t0)
        let disk = Verdicts([.fails, .passes])
        let client = KeepAwakeHelperClient(link: link, now: { clock.now }, sleep: sleeper.sleep,
                                           silence: sleeper.silence,
                                           installedHelper: { disk.next() })
        #expect(await client.begin(session: "s1") == .holding)

        // The update, read while the new helper was still being written.
        link.goesOutOfDate()
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitForState(client, .helperMismatch)
        #expect(disk.asked == 1)
        #expect(link.recordedReleases.isEmpty)

        // Moments later: the fail is too fresh to ask about again.
        clock.advance(5)
        #expect(await client.refreshStatus() == nil)
        #expect(disk.asked == 1, "the disk was asked again on every refusal")
        #expect(await client.currentState == .helperMismatch)

        // The copy has finished. The next renewal is refused, the fail is
        // old, and the disk says pass.
        clock.advance(KeepAwakeHelperClient.installedRecheckAfter)
        try await waitUntil { sleeper.beatsWaiting > 0 }
        sleeper.beat()
        try await waitForState(client, .handingOver)
        #expect(disk.asked == 2, "a fail was believed for good")

        // From there it is the ordinary handover: one release naming the
        // highest generation sent, the silence, and a new hold above it.
        try await waitUntil { sleeper.silencesWaiting == 1 }
        let released = try #require(link.recordedReleases.first)
        #expect(link.recordedReleases.count == 1)
        #expect(released.generation == link.recordedHolds.map(\.generation).max())
        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .holding)
        #expect((link.recordedHolds.last?.generation ?? 0) > released.generation)
        await client.end()
    }

    /// And the other half: an installation that really is wrong goes on
    /// saying so, however often it is asked again, and never gives up a hold.
    @Test("A fail that keeps failing stays a mismatch and gives nothing back")
    func brokenStaysBroken() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let clock = MovableClock(Self.t0)
        let disk = Verdicts([.fails])
        let client = KeepAwakeHelperClient(link: link, now: { clock.now }, sleep: sleeper.sleep,
                                           silence: sleeper.silence,
                                           installedHelper: { disk.next() })
        #expect(await client.begin(session: "s1") == .holding)
        link.goesOutOfDate()

        for round in 1 ... 3 {
            try await waitUntil { sleeper.beatsWaiting > 0 }
            sleeper.beat()
            try await waitUntil { disk.asked == round }
            #expect(await client.currentState == .helperMismatch, "round \(round)")
            clock.advance(KeepAwakeHelperClient.installedRecheckAfter)
        }
        #expect(link.recordedReleases.isEmpty, "a hold the user still wants was given back")
        #expect(sleeper.silencesBegun == 0)
        await client.end()
    }

    /// The pass ends the mismatch by itself, not only once the new helper is
    /// heard. A new helper that is slow to answer ends the handover under
    /// the ordinary rules, and those must not find a reinstall still laid
    /// over them from a read that turned out wrong.
    @Test("A pass after a fail leaves no mismatch behind, even if the new helper is slow")
    func passClearsTheMismatch() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let clock = MovableClock(Self.t0)
        let disk = Verdicts([.fails, .passes])
        let client = KeepAwakeHelperClient(link: link, now: { clock.now }, sleep: sleeper.sleep,
                                           silence: sleeper.silence,
                                           installedHelper: { disk.next() })
        link.goesOutOfDate()
        _ = await client.refreshStatus()
        #expect(await client.currentState == .helperMismatch, "the premise: the first read failed")

        clock.advance(KeepAwakeHelperClient.installedRecheckAfter)
        _ = await client.refreshStatus()
        #expect(await client.currentState == .handingOver)
        try await waitUntil { sleeper.silencesWaiting == 1 }

        // Neither refused nor heard: the new helper is slow.
        link.comesBackUpToDate()
        link.goSilent()
        sleeper.timeOutCalls()
        sleeper.endSilence()
        var seen = await client.currentState
        while seen == .handingOver {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }
        #expect(seen == .idle, "a mismatch from a read that was wrong outlived the handover")
    }

    @Test("A clock that went backwards does not keep a fail alive")
    func backwardsClockAsksAgain() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let clock = MovableClock(Self.t0)
        let disk = Verdicts([.fails, .passes])
        let client = KeepAwakeHelperClient(link: link, now: { clock.now }, sleep: sleeper.sleep,
                                           silence: sleeper.silence,
                                           installedHelper: { disk.next() })
        link.goesOutOfDate()
        _ = await client.refreshStatus()
        #expect(disk.asked == 1)

        clock.advance(-600)
        _ = await client.refreshStatus()
        #expect(disk.asked == 2, "an age that cannot be trusted kept a fail alive")
        #expect(await client.currentState == .handingOver)
        try await waitUntil { sleeper.silencesWaiting == 1 }
        link.comesBackUpToDate()
        sleeper.endSilence()
        try await waitForState(client, .idle)
    }

    @Test("The disk is asked again within one heartbeat, and not on every refusal")
    func recheckSitsUnderTheHeartbeat() {
        #expect(KeepAwakeHelperClient.installedRecheckAfter < KeepAwakeHelperClient.heartbeat,
                "a finished copy would wait more than one renewal to be noticed")
        #expect(KeepAwakeHelperClient.installedRecheckAfter >= 5,
                "a burst of refusals would hash the helper once each")
    }

    // MARK: - Cancellation

    /// Nothing cancels the handover today. If something did, every sleep in
    /// it would throw at once, and a loop that read that as "cut short" would
    /// ask as fast as the old copy could refuse — keeping it alive.
    @Test("A cancelled handover stops, rather than asking as fast as it is refused")
    func cancelledHandoverStops() async throws {
        let link = FakeLink()
        let sleeper = Sleeper()
        let silences = CallCounter()
        let client = KeepAwakeHelperClient(
            link: link, now: { Self.t0 }, sleep: sleeper.sleep,
            // The silence cancels the very task it is waiting in, then throws
            // as a cancelled sleep does.
            silence: { _ in
                silences.bump()
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
        )

        link.goesOutOfDate()
        #expect(await client.refreshStatus() == nil)
        try await waitUntil { silences.value >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(silences.value == 1, "the cancelled handover went round again")
        #expect(link.callLog == ["status"], "a cancelled handover went on asking")
    }
}

/// Counts from any thread.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func bump() { lock.withLock { stored += 1 } }
    var value: Int { lock.withLock { stored } }
}

/// What the helper on disk says, in order, then the last answer for good.
private final class Verdicts: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [KeepAwakeInstalledHelper]
    private var count = 0
    init(_ answers: [KeepAwakeInstalledHelper]) { queue = answers }
    var asked: Int { lock.withLock { count } }
    func next() -> KeepAwakeInstalledHelper {
        lock.withLock {
            count += 1
            return queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }
}

/// A Mac with two clocks: the wall clock, which goes on while it sleeps, and
/// uptime, which does not.
///
/// The old helper's idle tick runs on uptime. The point of this is a client
/// whose silence is counted on the wrong one — the continuous clock, which
/// is what `Task.sleep(for:)` uses — and so runs down while the lid is shut.
private final class TwoClockMac: @unchecked Sendable {
    private let lock = NSLock()
    private var wall: TimeInterval = 0
    private var awake: TimeInterval = 0
    private var wallSleepers: [(until: TimeInterval, k: CheckedContinuation<Void, Error>)] = []
    private var awakeSleepers: [(until: TimeInterval, k: CheckedContinuation<Void, Error>)] = []

    var now: Date { lock.withLock { Date(timeIntervalSince1970: 1_000_000 + wall) } }
    var awakeWaiting: Int { lock.withLock { awakeSleepers.count } }

    /// A sleep on the wall clock, as `Task.sleep(for:)` is.
    func wallSleep(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { k in
            lock.withLock { wallSleepers.append((wall + seconds, k)) }
        }
    }

    /// A sleep on uptime, as the daemon's tick and the client's silence are.
    func awakeSleep(_ seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { k in
            lock.withLock { awakeSleepers.append((awake + seconds, k)) }
        }
    }

    /// The Mac sleeps: the wall clock moves and uptime does not.
    func sleeps(for seconds: TimeInterval) { advance(wall: seconds, awake: 0) }
    /// The Mac is awake: both move.
    func isAwake(for seconds: TimeInterval) { advance(wall: seconds, awake: seconds) }

    private func advance(wall dw: TimeInterval, awake da: TimeInterval) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            wall += dw
            awake += da
            let w = wallSleepers.filter { $0.until <= wall }.map(\.k)
            wallSleepers.removeAll { $0.until <= wall }
            let a = awakeSleepers.filter { $0.until <= awake }.map(\.k)
            awakeSleepers.removeAll { $0.until <= awake }
            return w + a
        }
        due.forEach { $0.resume() }
    }
}

@Suite("A handover the Mac sleeps through", .timeLimit(.minutes(10)))
struct KeepAwakeHandoverSleepTests {

    /// The scenario that made "restart needed" a likely outcome rather than a
    /// corner case. The handover begins by giving the lid hold back, so the
    /// natural next thing — shutting the lid — sleeps the Mac. Counted on a
    /// clock that keeps going in sleep, the silence is over on waking, and
    /// the first question reaches an old helper that has not ticked since
    /// before the lid shut.
    @Test("Time asleep does not count towards the silence")
    func sleepDoesNotCount() async throws {
        let link = FakeLink()
        let mac = TwoClockMac()
        let client = KeepAwakeHelperClient(link: link, now: { mac.now },
                                           sleep: mac.wallSleep, silence: mac.awakeSleep)

        link.goesOutOfDate()
        #expect(await client.refreshStatus() == nil)
        try await waitUntil { mac.awakeWaiting == 1 }
        #expect(link.callLog == ["status"], "the premise: one refused question, then silence")

        // Ten minutes asleep, far past the silence on any wall clock.
        mac.sleeps(for: 600)
        try await Task.sleep(for: .milliseconds(50))
        #expect(link.callLog == ["status"], "a Mac asleep counted towards the silence")
        #expect(await client.currentState == .handingOver)

        // Awake for all but the last second of it: still nothing.
        mac.isAwake(for: KeepAwakeHelperClient.handoverSilence - 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(link.callLog == ["status"], "the silence ended before the old helper could tick")

        // And the last second.
        link.comesBackUpToDate()
        mac.isAwake(for: 1)
        try await waitForState(client, .idle)
        #expect(link.callLog == ["status", "status"])
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        while !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForState(_ client: KeepAwakeHelperClient,
                              _ wanted: KeepAwakeHelperState) async throws {
        while await client.currentState != wanted {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
