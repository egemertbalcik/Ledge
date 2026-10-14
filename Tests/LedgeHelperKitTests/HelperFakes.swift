import Foundation
import Testing

@testable import LedgeHelperKit

// Everything the daemon talks to, faked, so that every rule in the lease can
// be exercised without a Mac that has to be put to sleep, a root process, or a
// single real second passing.

/// Two clocks the test moves by hand, and separately.
///
/// Separately is the point: the rules that matter most are the ones that say
/// the lease ignores the wall clock, and a test that moved both together could
/// not tell a correct implementation from one that measured the lease in
/// `Date`s.
final class TestClock: HelperClock, @unchecked Sendable {

    private let box = NSLock()
    private var wall: Date
    private var continuous: UInt64

    init(wall: Date = Date(timeIntervalSince1970: 1_700_000_000),
         continuousNanoseconds: UInt64 = 60_000_000_000) {
        self.wall = wall
        self.continuous = continuousNanoseconds
    }

    var now: Date { box.withLock { wall } }
    var continuousNanoseconds: UInt64 { box.withLock { continuous } }

    /// Time passing, as a person would mean it.
    func advance(_ seconds: TimeInterval) {
        box.withLock {
            wall = wall.addingTimeInterval(seconds)
            continuous += UInt64(seconds * 1_000_000_000)
        }
    }

    /// The Mac slept: continuous time counts it, the wall clock agrees, and
    /// nothing else ran in between.
    func sleep(_ seconds: TimeInterval) { advance(seconds) }

    /// Somebody moved the wall clock. Continuous time does not notice.
    func stepWallClock(by seconds: TimeInterval) {
        box.withLock { wall = wall.addingTimeInterval(seconds) }
    }
}

/// The one SleepDisabled setting on the one Mac, shared by every daemon in the
/// test, exactly as it is shared on a real Mac.
final class FakeMac: @unchecked Sendable {
    var sleepDisabled = 0
    /// Low Power Mode, per power source, exactly as `pmset` keeps it. Nil is
    /// a source this Mac does not have — a desktop has no battery — and is a
    /// different answer from off.
    var lowPower = LowPowerSetting(battery: false, charger: false)
    /// `pmset` refuses this many of the next Low Power Mode writes.
    var refuseLowPowerWrites = 0
    /// `pmset` refuses this many of the next Low Power Mode reads.
    var refuseLowPowerReads = 0
    /// Low Power Mode writes exit cleanly and change nothing.
    var ignoreLowPowerWrites = false
    /// A runner that answers a Low Power Mode read with a SleepDisabled
    /// number. Not something `pmset` does — something a future parser bug
    /// would do, and the reason the core checks which setting an answer is
    /// about before it believes it.
    var answersLowPowerReadsWithANumber = false
    /// `pmset` refuses this many of the next writes.
    var refuseWrites = 0
    /// `pmset` refuses this many of the next reads.
    var refuseReads = 0
    /// Writes exit cleanly and change nothing — the case a readback exists to
    /// catch.
    var ignoreWrites = false
    /// Children started and not yet reaped. The test answers them by hand.
    var hangs = false
}

/// The claim file and its lock, shared between daemons the way the real one is.
final class ClaimFile: @unchecked Sendable {
    var ledger: ClaimLedger?
    /// The file exists and cannot be understood.
    var corrupt = false
    var lockedBy: String?
    /// Refuse this many of the next saves.
    var saveFailures = 0
    var saves = 0
    /// What was moved aside, never thrown away.
    var setAside: [ClaimLedger?] = []
}

struct ClaimStoreRefusal: Error {}

final class TestStore: ClaimStore {

    let file: ClaimFile
    let owner: String
    private(set) var lockAttempts = 0

    init(file: ClaimFile, owner: String) {
        self.file = file
        self.owner = owner
    }

    func tryLock() -> Bool {
        lockAttempts += 1
        guard file.lockedBy == nil else { return false }
        file.lockedBy = owner
        return true
    }

    /// Somebody else taking the lock the instant this store lets go of it.
    ///
    /// The only seam a cross-process window has in a unit test. Another
    /// helper is a separate process with its own schedule: it does not wait
    /// for this core's next pump, it waits for the file lock, and the moment
    /// that is free it is entitled to act.
    ///
    /// It is used with `holdWithoutDraining`, which is the half that is easy
    /// to miss — a peer whose request is queued but not driven is armed and
    /// waiting, which is what a separate process actually looks like. A peer
    /// that is drained early does its own recovery first and never reaches
    /// the branch under test.
    var onUnlocked: (() -> Void)?

    func unlock() {
        #expect(file.lockedBy == owner, "a daemon released a lock it did not hold")
        file.lockedBy = nil
        let waiting = onUnlocked
        onUnlocked = nil
        waiting?()
    }

    func load() throws -> ClaimLedger {
        #expect(file.lockedBy == owner, "the store was read outside the transaction lock")
        if file.corrupt { throw ClaimStoreRefusal() }
        return file.ledger ?? .empty
    }

    func save(_ ledger: ClaimLedger) throws {
        #expect(file.lockedBy == owner, "the store was written outside the transaction lock")
        if file.saveFailures > 0 {
            file.saveFailures -= 1
            throw ClaimStoreRefusal()
        }
        file.ledger = ledger
        file.saves += 1
    }

    func moveAside() throws {
        file.setAside.append(file.ledger)
        file.ledger = nil
        file.corrupt = false
    }
}

/// Starts `pmset` children and never answers them on its own.
///
/// `@unchecked Sendable` because a reply block hands it across a closure
/// boundary to ask one question — how many children had been started when the
/// reply went out — and everything in this file runs on the test's own thread.
final class TestPmset: PmsetRunner, @unchecked Sendable {
    private(set) var started: [(command: PmsetCommand, opID: Int)] = []
    var answered = 0
    var outstanding: (command: PmsetCommand, opID: Int)? {
        answered < started.count ? started[answered] : nil
    }
    var commands: [PmsetCommand] { started.map(\.command) }
    /// Run the instant a child is admitted, before anything else can react.
    ///
    /// The point where a privileged write becomes possible is the point where
    /// everything it depends on has to already be on disk — and the next pump
    /// is not a durability barrier: a process can stop between the two.
    var onStart: (() -> Void)?

    func start(_ command: PmsetCommand, opID: Int) {
        started.append((command, opID))
        onStart?()
    }

    /// Where this runner's results go, if anybody has asked.
    ///
    /// The core is driven by hand in these tests, but the fail-safe is wired
    /// to its own runner and reads its own children back — so a fake runner
    /// that could not report was a fail-safe that could never confirm
    /// anything.
    private(set) var receiver: (@Sendable (Int, PmsetOutcome) -> Void)?
    func report(to receiver: @escaping @Sendable (Int, PmsetOutcome) -> Void) {
        self.receiver = receiver
    }

    /// Where the news goes that a write already answered for has finished.
    private(set) var settledReceiver: (@Sendable (Int, PmsetCommand) -> Void)?
    func reportSettled(to receiver: @escaping @Sendable (Int, PmsetCommand) -> Void) {
        self.settledReceiver = receiver
    }

    /// Answers the next outstanding child with `outcome`, through whoever is
    /// listening.
    @discardableResult
    func answerNext(_ outcome: PmsetOutcome) -> PmsetCommand? {
        guard let next = outstanding else { return nil }
        answered += 1
        receiver?(next.opID, outcome)
        return next.command
    }

    /// Where the news goes that a writer can still act.
    private(set) var unsettledReceiver: (@Sendable (Int, PmsetCommand) -> Void)?
    func reportUnsettled(to receiver: @escaping @Sendable (Int, PmsetCommand) -> Void) {
        self.unsettledReceiver = receiver
    }

    /// A child about to be answered for while it can still act — the shape
    /// the real runner produces when it abandons a child's pipes, or gives up
    /// collecting one. The reply follows; the child has not stopped.
    func markLive(opID: Int, command: PmsetCommand) {
        guard command.isWrite else { return }
        unsettledReceiver?(opID, command)
    }

    /// A child this runner already answered for, finishing at last.
    ///
    /// The shape the real runner produces when a child's pipes time out, or
    /// when the bounded collection poll gives up on a child that is still
    /// alive: the operation was answered `.failed` long ago, and the write it
    /// carried lands now. Reads are filtered out by the real runner, so this
    /// does the same.
    func settle(opID: Int, command: PmsetCommand) {
        guard command.isWrite else { return }
        settledReceiver?(opID, command)
    }
}

final class TestTimer: HelperTimer {
    private(set) var requested: [UInt64?] = []
    var last: UInt64?? { requested.last }
    func wake(after nanoseconds: UInt64?) { requested.append(nanoseconds) }
    /// Starts counting again, for a test that cares about what happens from
    /// here rather than about everything since the daemon started.
    func forgetRequests() { requested.removeAll() }
}

final class TestLog: HelperLog, @unchecked Sendable {
    private let box = NSLock()
    private var lines: [String] = []
    func note(_ message: String) { box.withLock { lines.append(message) } }
    var all: [String] { box.withLock { lines } }
    func contains(_ fragment: String) -> Bool { all.contains { $0.contains(fragment) } }
}

/// Somewhere for an XPC reply to land, and *when* it landed.
///
/// The timing matters and used to be invisible: `Daemon.hold` answered every
/// `pmset` child before it returned, so a test could not tell a reply sent
/// after the privileged write had been verified from one sent before the
/// write had even started. They are not the same reply. The daemon answers a
/// hold once the lease is on disk and only then applies the setting, which is
/// why `ok` is an acceptance and not a confirmation — and a fake that hid the
/// difference is a fake that let that be forgotten.
final class Replies: @unchecked Sendable {
    private let box = NSLock()
    private var codes: [KeepAwakeHelperCode] = []
    private var childrenAtReply: [Int] = []

    func add(_ code: KeepAwakeHelperCode, childrenStarted: Int = -1) {
        box.withLock {
            codes.append(code)
            childrenAtReply.append(childrenStarted)
        }
    }

    var all: [KeepAwakeHelperCode] { box.withLock { codes } }
    var last: KeepAwakeHelperCode? { all.last }
    var count: Int { all.count }

    /// How many `pmset` children had been started when each reply was sent.
    var childrenStartedAtEachReply: [Int] { box.withLock { childrenAtReply } }
}

/// One daemon, with the Mac and the claim file it shares with any other.
final class Daemon {

    let label: String
    let clock: TestClock
    let mac: FakeMac
    let store: TestStore
    let pmset = TestPmset()
    let timer = TestTimer()
    let log = TestLog()
    let replies = Replies()
    let core: HelperCore

    init(label: String = "com.egemert.ledge.keepawake",
         boot: String = "boot-1",
         clock: TestClock,
         file: ClaimFile,
         mac: FakeMac) {
        self.label = label
        self.clock = clock
        self.mac = mac
        self.store = TestStore(file: file, owner: label)
        self.core = HelperCore(label: label, bootID: boot, clock: clock, store: store,
                               pmset: pmset, timer: timer, log: log)
    }

    convenience init(label: String = "com.egemert.ledge.keepawake", boot: String = "boot-1") {
        self.init(label: label, boot: boot, clock: TestClock(), file: ClaimFile(), mac: FakeMac())
    }

    // MARK: Driving it

    /// Answers every outstanding `pmset` child, and every one that answering
    /// starts, until the daemon is waiting for something other than a child.
    func drain() {
        var guardRail = 0
        while let next = pmset.outstanding, !mac.hangs {
            guardRail += 1
            #expect(guardRail < 50, "the daemon is spawning pmset without end")
            if guardRail >= 50 { return }
            pmset.answered += 1
            core.childExited(opID: next.opID, outcome: outcome(for: next.command))
        }
    }

    /// Answers exactly one outstanding child, whatever `hangs` says.
    func answerOne() {
        guard let next = pmset.outstanding else {
            Issue.record("there is no pmset child to answer")
            return
        }
        pmset.answered += 1
        core.childExited(opID: next.opID, outcome: outcome(for: next.command))
    }

    private func outcome(for command: PmsetCommand) -> PmsetOutcome {
        switch command {
        case .readSleepDisabled:
            if mac.refuseReads > 0 {
                mac.refuseReads -= 1
                return .failed("read refused")
            }
            return .read(mac.sleepDisabled)
        case .writeSleepDisabled(let on):
            if mac.refuseWrites > 0 {
                mac.refuseWrites -= 1
                return .failed("write refused")
            }
            if !mac.ignoreWrites { mac.sleepDisabled = on ? 1 : 0 }
            return .wrote
        case .readLowPowerMode:
            if mac.refuseLowPowerReads > 0 {
                mac.refuseLowPowerReads -= 1
                return .failed("read refused")
            }
            if mac.answersLowPowerReadsWithANumber { return .read(0) }
            return .lowPower(mac.lowPower)
        case .writeLowPowerMode(let on, let source):
            if mac.refuseLowPowerWrites > 0 {
                mac.refuseLowPowerWrites -= 1
                return .failed("write refused")
            }
            if !mac.ignoreLowPowerWrites {
                // A source this Mac does not have stays absent whatever is
                // written at it, which is how a test notices a `-b` aimed at
                // a desktop: the readback never agrees and the restore never
                // finishes.
                if source != .charger, mac.lowPower.battery != nil { mac.lowPower.battery = on }
                if source != .battery, mac.lowPower.charger != nil { mac.lowPower.charger = on }
            }
            return .wrote
        }
    }

    func start() {
        core.start()
        drain()
    }

    /// Time passes with nobody talking to the daemon.
    func advance(_ seconds: TimeInterval) {
        clock.advance(seconds)
        core.tick()
        drain()
    }

    @discardableResult
    func hold(session: String = Daemon.sessionA, generation: Int = 1,
              deadline: Date? = nil, lease: TimeInterval = 90) -> Replies {
        let answer = holdWithoutDraining(session: session, generation: generation,
                                         deadline: deadline, lease: lease)
        drain()
        return answer
    }

    /// A hold whose `pmset` children are left outstanding.
    ///
    /// The ordinary `hold` answers every child before it returns, which is
    /// convenient and hides the one thing worth seeing: the reply goes out
    /// once the lease is on disk, *before* the privileged write has been run
    /// or read back. A test that wants to know what `ok` actually means has to
    /// look at that moment, not after it.
    @discardableResult
    func holdWithoutDraining(session: String = Daemon.sessionA, generation: Int = 1,
                             deadline: Date? = nil, lease: TimeInterval = 90) -> Replies {
        let answer = Replies()
        core.hold(session: session, generation: generation, deadline: deadline,
                  leaseSeconds: lease) { [replies, pmset] code in
            answer.add(code, childrenStarted: pmset.started.count)
            replies.add(code, childrenStarted: pmset.started.count)
        }
        return answer
    }

    @discardableResult
    func lowPower(_ on: Bool, session: String = Daemon.sessionA, generation: Int = 1) -> Replies {
        let answer = Replies()
        core.setLowPowerMode(on, session: session, generation: generation) { [replies] code in
            answer.add(code)
            replies.add(code)
        }
        drain()
        return answer
    }

    @discardableResult
    func release(session: String = Daemon.sessionA, generation: Int = 1) -> Replies {
        let answer = Replies()
        core.release(session: session, generation: generation) { [replies] code in
            answer.add(code)
            replies.add(code)
        }
        drain()
        return answer
    }

    // MARK: Looking at it

    var claim: HelperClaim? { store.file.ledger?.claims[label] }
    var status: HelperStatus { core.status }

    static let sessionA = "6E2C5E2A-0000-4000-8000-00000000000A"
    static let sessionB = "6E2C5E2A-0000-4000-8000-00000000000B"
}

/// A ledger as some earlier daemon would have left it.
func claim(label: String, boot: String = "boot-1", session: String = Daemon.sessionA,
           generation: Int = 1, deadline: Date? = nil, leaseExpiryNs: UInt64,
           sleepDisabledClaimed: Bool = true) -> HelperClaim {
    HelperClaim(holderLabel: label, boot: boot, sessionID: session, generation: generation,
                deadline: deadline, leaseExpiryContinuousNs: leaseExpiryNs,
                sleepDisabledClaimed: sleepDisabledClaimed)
}
