import Foundation
import LedgeCore
import LedgeSystem

/// One ordered log shared by the fakes.
///
/// The rules worth testing here are about *order* — nothing is acquired before
/// the journal agrees, everything is released whether it agrees or not — and
/// order cannot be checked by asking each fake separately what it saw.
/// Not main-actor isolated, because the journal and tombstone protocols are
/// not: a fake that can only be written from the main actor cannot stand in for
/// something the provider may call from anywhere. A lock is enough — this
/// records a handful of events in a test.
final class KeepAwakeLog: @unchecked Sendable {

    private let lock = NSLock()

    enum Event: Equatable {
        case journalWrite(KeepAwakeRecord.State, id: String)
        case journalWriteRefused(KeepAwakeRecord.State, id: String)
        case journalClear
        case journalMovedAside
        case acquire(timeout: TimeInterval)
        case acquireRefused
        case rearm(timeout: TimeInterval)
        case release
        case tombstoneSet(String?)
        case tombstoneRefused
    }

    private var storage: [Event] = []

    var events: [Event] { lock.withLock { storage } }

    func record(_ event: Event) { lock.withLock { storage.append(event) } }

    func firstIndex(of event: Event) -> Int? { events.firstIndex(of: event) }

    var writes: [Event] {
        events.filter {
            if case .journalWrite = $0 { return true }
            return false
        }
    }
}

@MainActor
final class FakeSleepAssertion: SleepAssertion {
    private let log: KeepAwakeLog
    var refuses = false
    private(set) var isHeld = false
    private(set) var lastTimeout: TimeInterval?
    /// How many times an assertion has been taken, so a test can tell one
    /// session from two.
    private(set) var acquireCount = 0

    init(log: KeepAwakeLog) { self.log = log }

    func acquire(name: String, details: String, timeout: TimeInterval) -> Bool {
        guard !refuses else {
            log.record(.acquireRefused)
            return false
        }
        isHeld = true
        acquireCount += 1
        lastTimeout = timeout
        log.record(.acquire(timeout: timeout))
        return true
    }

    func rearm(timeout: TimeInterval) -> Bool {
        guard isHeld else { return false }
        lastTimeout = timeout
        log.record(.rearm(timeout: timeout))
        return true
    }

    func release() {
        guard isHeld else { return }
        isHeld = false
        log.record(.release)
    }
}

/// A journal that can be told to refuse.
///
/// `failWrites` is a count rather than a flag so a test can make exactly the
/// write it cares about fail and let the retries through, which is how the
/// interesting interleavings are reached.
final class MemoryKeepAwakeJournal: @unchecked Sendable, KeepAwakeJournal {

    private let lock = NSLock()
    private let log: KeepAwakeLog
    private var record: KeepAwakeRecord?
    private var unreadable = false
    private var refusals = 0
    private var refusedState: KeepAwakeRecord.State?
    private var aside = false

    /// Holds the next write until the test lets it go.
    ///
    /// The point of the whole feature's trouble is what else can happen while a
    /// write is in the air, and that is unreachable against a disk that always
    /// answers at once. `write` is synchronous by protocol, so this blocks the
    /// worker actor's thread — which is exactly the shape of a slow disk, and
    /// leaves the main actor free to do the thing being tested.
    private var gate: DispatchSemaphore?
    private var gateOpenings = 0
    /// A queue, so more than one read can be held at a time and let go in
    /// the order they arrived — which is what it takes to model a provider
    /// being restarted while its first recovery is still waiting.
    private var readGates: [DispatchSemaphore] = []
    private var readGateOpenings = 0
    /// Gates for named sessions, so a test can hold one write while letting
    /// another through — which is the only way to model a queue.
    private var beforeStore: [String: DispatchSemaphore] = [:]
    private var afterStore: [String: DispatchSemaphore] = [:]
    private var reached: [String: Int] = [:]
    private var committed: Set<String> = []

    init(log: KeepAwakeLog, stored: KeepAwakeRecord? = nil) {
        self.log = log
        self.record = stored
    }

    var stored: KeepAwakeRecord? {
        get { lock.withLock { record } }
        set { lock.withLock { record = newValue } }
    }

    var isUnreadable: Bool {
        get { lock.withLock { unreadable } }
        set { lock.withLock { unreadable = newValue } }
    }

    /// How many of the next writes to refuse. -1 refuses all of them, which is
    /// how the "the disk never takes it" cases are reached.
    var failWrites: Int {
        get { lock.withLock { refusals } }
        set { lock.withLock { refusals = newValue } }
    }

    /// Refuses every write recording a particular state, however many there
    /// are. `failWrites` says *how many* writes fail; this says *which* — the
    /// cases where a start lands and only taking it back is refused.
    var failWritesRecording: KeepAwakeRecord.State? {
        get { lock.withLock { refusedState } }
        set { lock.withLock { refusedState = newValue } }
    }

    var movedAside: Bool { lock.withLock { aside } }

    func read() throws -> KeepAwakeRecord? {
        let held: DispatchSemaphore? = lock.withLock {
            guard !readGates.isEmpty else { return nil }
            readGateOpenings += 1
            let gate = readGates.removeFirst()
            heldReads.append(gate)
            return gate
        }
        held?.wait()
        if isUnreadable { throw CocoaError(.fileReadCorruptFile) }
        return stored
    }

    /// How many reads have reached the gate, so a test can wait for one to be
    /// genuinely in flight rather than for a few turns to have passed.
    var readsWaiting: Int { lock.withLock { readGateOpenings } }

    /// Makes the next read wait, so a test can get between the journal being
    /// asked what it holds and the answer being acted on.
    func holdNextRead() {
        lock.withLock { readGates.append(DispatchSemaphore(value: 0)) }
    }

    /// Lets a held read finish. Released before the read arrives is fine — the
    /// permit is waiting for it.
    func releaseHeldRead() {
        let held: DispatchSemaphore? = lock.withLock {
            heldReads.isEmpty ? nil : heldReads.removeFirst()
        }
        held?.signal()
    }

    /// Gates a read has actually taken, oldest first.
    private var heldReads: [DispatchSemaphore] = []

    /// Holds every write recording this session, before the record is stored.
    func holdWrites(for id: String) {
        lock.withLock { beforeStore[id] = DispatchSemaphore(value: 0) }
    }

    /// Holds this session's write *after* the record is stored — the gap
    /// between the disk taking a record and the caller hearing that it did.
    func holdAfterStoring(_ id: String) {
        lock.withLock { afterStore[id] = DispatchSemaphore(value: 0) }
    }

    func releaseWrites(for id: String) {
        let gate: DispatchSemaphore? = lock.withLock {
            let held = beforeStore[id]
            beforeStore[id] = nil
            return held
        }
        gate?.signal()
    }

    func releaseAfterStoring(_ id: String) {
        let gate: DispatchSemaphore? = lock.withLock {
            let held = afterStore[id]
            afterStore[id] = nil
            return held
        }
        gate?.signal()
    }

    /// How many of this session's writes have reached the disk. A count, not a
    /// flag: a session is written more than once, and a test that cannot tell
    /// the start from the end waits for something that has already happened.
    func writeAttempts(for id: String) -> Int { lock.withLock { reached[id] ?? 0 } }

    /// Whether this session has been written at all.
    func writeReached(_ id: String) -> Bool { writeAttempts(for: id) > 0 }

    /// Whether this session's record is on the disk, answered or not.
    func isStored(_ id: String) -> Bool { lock.withLock { committed.contains(id) } }

    /// Makes the next write wait. Returns once it is actually waiting.
    func holdNextWrite() {
        lock.withLock { gate = DispatchSemaphore(value: 0) }
    }

    /// Lets a held write finish.
    func releaseHeldWrite() {
        let semaphore: DispatchSemaphore? = lock.withLock {
            let held = gate
            gate = nil
            return held
        }
        semaphore?.signal()
    }

    /// How many writes have been let through the gate, so a test can wait for
    /// one to have actually reached it.
    var writesWaiting: Int { lock.withLock { gateOpenings } }

    func write(_ newRecord: KeepAwakeRecord) throws {
        let held: DispatchSemaphore? = lock.withLock {
            guard let gate else { return nil }
            gateOpenings += 1
            return gate
        }
        held?.wait()

        let named: DispatchSemaphore? = lock.withLock {
            reached[newRecord.id, default: 0] += 1
            return beforeStore[newRecord.id]
        }
        named?.wait()

        let refuse: Bool = lock.withLock {
            if refusedState == newRecord.state { return true }
            guard refusals != 0 else { return false }
            if refusals > 0 { refusals -= 1 }
            return true
        }
        if refuse {
            log.record(.journalWriteRefused(newRecord.state, id: newRecord.id))
            throw CocoaError(.fileWriteNoPermission)
        }
        stored = newRecord
        log.record(.journalWrite(newRecord.state, id: newRecord.id))

        let settling: DispatchSemaphore? = lock.withLock {
            committed.insert(newRecord.id)
            return afterStore[newRecord.id]
        }
        settling?.wait()
    }

    func clear() throws {
        stored = nil
        log.record(.journalClear)
    }

    func moveAside() throws {
        lock.withLock { aside = true; record = nil }
        log.record(.journalMovedAside)
    }
}

final class MemoryTombstone: @unchecked Sendable, KeepAwakeTombstone {

    private let lock = NSLock()
    private let log: KeepAwakeLog
    private var stored: [String]
    private var refuses = false

    init(log: KeepAwakeLog, value: String? = nil) {
        self.log = log
        self.stored = value.map { [$0] } ?? []
    }

    var values: [String] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// The one name, for the many tests that only ever expect one.
    var value: String? {
        get { values.last }
        set { values = newValue.map { [$0] } ?? [] }
    }

    var fails: Bool {
        get { lock.withLock { refuses } }
        set { lock.withLock { refuses = newValue } }
    }

    func endedSessionIDs() -> [String] { values }

    func set(_ ids: [String]) throws {
        if fails {
            log.record(.tombstoneRefused)
            throw CocoaError(.fileWriteNoPermission)
        }
        values = ids
        log.record(.tombstoneSet(ids.last))
    }
}

/// A clock the test moves by hand.
@MainActor
final class TestClock {
    private(set) var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    func set(_ date: Date) { now = date }
}
