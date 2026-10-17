import Foundation
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
        if lock.withLock({ silent }) { try await Task.sleep(for: .seconds(3600)) }
        if let gate = lock.withLock({ statusGate }) {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { gate.wait(); k.resume() }
            }
        }
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
            return self.silent
        }
        if silent {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        return .ok
    }

    func hold(session: String, generation: Int, until deadline: Date?,
              leaseSeconds: Double) async throws -> KeepAwakeHelperCode {
        let answer: KeepAwakeHelperCode? = lock.withLock {
            holds.append(Hold(session: session, generation: generation,
                              deadline: deadline, lease: leaseSeconds))
            if silent { return nil }
            if generation < staleBelow { return KeepAwakeHelperCode.stale }
            let answer = answers.isEmpty ? fallback : answers.removeFirst()
            // The apply happens after the reply, as it does on a real daemon.
            if answer == .ok, applySucceeds { applied = true }
            return answer
        }
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

@Suite("Keep Awake helper client")
struct KeepAwakeHelperClientTests {

    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    private static func client(_ link: FakeLink, _ sleeper: Sleeper) -> KeepAwakeHelperClient {
        KeepAwakeHelperClient(link: link, now: { t0 }, sleep: sleeper.sleep)
    }

    private func waitUntil(upTo seconds: TimeInterval = 5,
                           _ condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "waited \(seconds)s and it never came true")
    }

    /// Waits on the client itself rather than on the fake.
    ///
    /// The fake records a hold as the call arrives, not as it is answered, so a
    /// test that waits for the call count and then reads the state is reading
    /// it one step early — the client has not seen the answer yet. Under the
    /// full suite that is the difference between passing and not.
    private func waitForState(_ client: KeepAwakeHelperClient,
                              _ wanted: KeepAwakeHelperState,
                              upTo seconds: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        var seen = await client.currentState
        while Date() < deadline, seen != wanted {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }
        try #require(seen == wanted, "state settled at \(seen), not \(wanted)")
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

        // Bounded on purpose, and bounded without a task group.
        //
        // A regression here does not make this assertion false — it makes it
        // never arrive, and an unbounded wait turns a failing test into a hung
        // test run, which is worse than no test. A task group is no good for
        // the bound either, for exactly the reason this test exists: a group
        // waits for its children, including the one that never finishes.
        let answer = Answer()
        Task { answer.set(await began.value) }
        for _ in 0 ..< 1_000 where answer.value == nil {
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
@Suite("Silence before a hold, and silence after one")
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
        for _ in 0 ..< 400 where sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()

        var seen = await client.currentState
        for _ in 0 ..< 400 where seen != .temporarilyUnavailable {
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
        for _ in 0 ..< 400 where sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()

        var seen = await client.currentState
        for _ in 0 ..< 400 where seen == .pending || seen == .holding {
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
        for _ in 0 ..< 400 where sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()
        var seen = await client.currentState
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
        for _ in 0 ..< 400 where sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()

        var seen = await client.currentState
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
        for _ in 0 ..< 400 where sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()
        var seen = await client.currentState
        for _ in 0 ..< 400 where seen != .temporarilyUnavailable {
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
        for _ in 0 ..< 400 where sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()
        var seen = await client.currentState
        for _ in 0 ..< 400 where seen != .temporarilyUnavailable {
            try await Task.sleep(for: .milliseconds(5))
            seen = await client.currentState
        }
        #expect(seen == .temporarilyUnavailable, "inside the lease, silence is still a warning")

        // Past it: the lease the hold stood on has run out.
        clock.advance(2)
        for _ in 0 ..< 400 where sleeper.beatsWaiting == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        sleeper.beat()
        for _ in 0 ..< 400 where seen != .unknownWhetherHeld {
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
