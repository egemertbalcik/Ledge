import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

/// A journal that remembers what it was last told, and counts how often.
private final class SpyJournal: @unchecked Sendable, KeepAwakeJournal {
    private let lock = NSLock()
    private var record: KeepAwakeRecord?
    private(set) var writeCount = 0

    var stored: KeepAwakeRecord? { lock.withLock { record } }

    func read() throws -> KeepAwakeRecord? { stored }

    /// How many of the next writes to refuse.
    var failWrites = 0

    func write(_ newRecord: KeepAwakeRecord) throws {
        let refuse: Bool = lock.withLock {
            guard failWrites > 0 else { return false }
            failWrites -= 1
            return true
        }
        if refuse { throw CocoaError(.fileWriteNoPermission) }
        lock.withLock {
            record = newRecord
            writeCount += 1
        }
    }

    func clear() throws { lock.withLock { record = nil } }
    func moveAside() throws { lock.withLock { record = nil } }
}

private func record(_ id: String, _ state: KeepAwakeRecord.State) -> KeepAwakeRecord {
    let start = Date(timeIntervalSince1970: 1_000_000)
    return KeepAwakeRecord(
        id: id,
        state: state,
        startedAt: start,
        deadline: start.addingTimeInterval(3_600),
        total: 3_600,
        boot: "boot"
    )
}

@Suite("The Keep Awake journal's write order")
struct KeepAwakeJournalWorkerTests {

    // Writers take an owner number from the journal, and the ordering rules
    // below are the ones that apply within one of them.

    // The provider also declines to send a write it knows is superseded, but
    // that decision is a read, an await and then a write, and the order writes
    // arrive in cannot be assumed. These are about the one place the check and
    // the write cannot come apart.

    @Test("A write older than the last one does not reach the disk")
    func olderWriteIsRefused() async throws {
        let journal = SpyJournal()
        let worker = KeepAwakeJournalWorker(journal)
        let owner = worker.claim()

        let newer = try await worker.write(record("B", .running), revision: 3, owner: owner)
        let older = try await worker.write(record("A", .ended), revision: 2, owner: owner)

        #expect(newer)
        #expect(!older, "being superseded is not a failure, but it is not a write either")
        #expect(journal.stored?.id == "B")
        #expect(journal.stored?.state == .running)
        #expect(journal.writeCount == 1, "the older record must not have touched the disk at all")
    }

    @Test("A write at the revision already written is refused too")
    func sameRevisionIsRefused() async throws {
        let journal = SpyJournal()
        let worker = KeepAwakeJournalWorker(journal)
        let owner = worker.claim()

        _ = try await worker.write(record("A", .running), revision: 1, owner: owner)
        let again = try await worker.write(record("A", .ended), revision: 1, owner: owner)

        #expect(!again)
        #expect(journal.stored?.state == .running)
        #expect(journal.writeCount == 1)
    }

    @Test("Newer writes keep landing after one has been refused")
    func newerWritesStillLand() async throws {
        let journal = SpyJournal()
        let worker = KeepAwakeJournalWorker(journal)
        let owner = worker.claim()

        _ = try await worker.write(record("B", .running), revision: 3, owner: owner)
        _ = try await worker.write(record("A", .ended), revision: 2, owner: owner)
        let latest = try await worker.write(record("B", .ended), revision: 4, owner: owner)

        #expect(latest, "a refusal must not leave the worker closed to what comes next")
        #expect(journal.stored?.id == "B")
        #expect(journal.stored?.state == .ended)
        #expect(journal.writeCount == 2)
    }
}

@Suite("Who the Keep Awake journal belongs to")
struct KeepAwakeJournalOwnerTests {

    // A provider is built per switch-on, so its revisions start again at one.
    // Ownership is what the journal keeps instead, because the question —
    // which of these providers is the live one — outlives all of them.

    @Test("A provider the journal has moved past cannot write")
    func olderOwnerIsRefused() async throws {
        let journal = SpyJournal()
        let worker = KeepAwakeJournalWorker(journal)
        let old = worker.claim()
        let new = worker.claim()

        let newer = try await worker.write(record("B", .running), revision: 1, owner: new)
        // The old provider's revision is higher, and counts for nothing.
        let older = try await worker.write(record("A", .ended), revision: 9, owner: old)

        #expect(newer)
        #expect(!older, "an owner that has been replaced writes nothing")
        #expect(journal.stored?.id == "B")
        #expect(journal.stored?.state == .running)
        #expect(journal.writeCount == 1)
    }

    @Test("A replaced provider may still tidy up until its replacement writes")
    func olderOwnerMayStillTidyUp() async throws {
        // Claiming is not taking over. A provider on its way out has a record
        // of its own to take back, and nothing is served by refusing it while
        // its replacement has written nothing.
        let journal = SpyJournal()
        let worker = KeepAwakeJournalWorker(journal)
        let old = worker.claim()
        _ = worker.claim()

        _ = try await worker.write(record("A", .running), revision: 1, owner: old)
        let tidied = try await worker.write(record("A", .ended), revision: 2, owner: old)

        #expect(tidied)
        #expect(journal.stored?.state == .ended)
    }

    @Test("A takeover the disk refuses leaves the old owner able to tidy up")
    func refusedTakeoverKeepsTheOldOwner() async throws {
        // Taking over on being *asked* rather than on having written left the
        // worst of both: the old owner's record still on the disk, and the old
        // owner no longer allowed to replace it.
        let journal = SpyJournal()
        let worker = KeepAwakeJournalWorker(journal)
        let old = worker.claim()
        let new = worker.claim()

        _ = try await worker.write(record("A", .running), revision: 1, owner: old)
        journal.failWrites = 1
        await #expect(throws: (any Error).self) {
            try await worker.write(record("B", .running), revision: 1, owner: new)
        }
        #expect(journal.stored?.id == "A", "the disk never took B")

        let tidied = try await worker.write(record("A", .ended), revision: 2, owner: old)
        #expect(tidied, "so A is still the owner, and still has a record to take back")
        #expect(journal.stored?.state == .ended)
    }

    @Test("Once a takeover lands, the old owner is refused")
    func landedTakeoverRetiresTheOldOwner() async throws {
        let journal = SpyJournal()
        let worker = KeepAwakeJournalWorker(journal)
        let old = worker.claim()
        let new = worker.claim()

        _ = try await worker.write(record("A", .running), revision: 1, owner: old)
        journal.failWrites = 1
        await #expect(throws: (any Error).self) {
            try await worker.write(record("B", .running), revision: 1, owner: new)
        }
        let retried = try await worker.write(record("B", .running), revision: 2, owner: new)
        let late = try await worker.write(record("A", .ended), revision: 3, owner: old)

        #expect(retried)
        #expect(!late, "the retry succeeded, so A's turn is over")
        #expect(journal.stored?.id == "B")
        #expect(journal.stored?.state == .running)
    }

    @Test("A read says who last wrote the file")
    func readReportsItsWriter() async throws {
        // What an older provider needs in order to know a record is not its
        // to speak for. Serial is not first-come: an owner on its way out can
        // be reading long after its replacement has written.
        let journal = SpyJournal()
        let worker = KeepAwakeJournalWorker(journal)
        let old = worker.claim()
        let new = worker.claim()

        let before = try await worker.readOrQuarantine()
        #expect(before.record == nil)
        #expect(before.writtenBy == 0, "nobody has written in this process")

        _ = try await worker.write(record("A", .running), revision: 1, owner: old)
        let afterOld = try await worker.readOrQuarantine()
        #expect(afterOld.writtenBy == old)

        _ = try await worker.write(record("B", .running), revision: 1, owner: new)
        let afterNew = try await worker.readOrQuarantine()
        #expect(afterNew.record?.id == "B")
        #expect(afterNew.writtenBy == new, "and the older owner can tell it is not theirs")
    }

    @Test("A new owner's revisions are not outranked by the last owner's")
    func revisionsRestartWithTheOwner() async throws {
        let journal = SpyJournal()
        let worker = KeepAwakeJournalWorker(journal)
        let old = worker.claim()
        let new = worker.claim()

        _ = try await worker.write(record("A", .running), revision: 7, owner: old)
        let first = try await worker.write(record("B", .running), revision: 1, owner: new)
        let second = try await worker.write(record("B", .ended), revision: 2, owner: new)

        #expect(first, "the new provider starts counting at one, and must still be heard")
        #expect(second)
        #expect(journal.stored?.id == "B")
        #expect(journal.stored?.state == .ended)
    }
}

/// A tombstone that only ever lives in memory.
private final class MemoryStone: @unchecked Sendable, KeepAwakeTombstone {
    private let lock = NSLock()
    private var ids: [String] = []
    func endedSessionIDs() -> [String] { lock.withLock { ids } }
    func set(_ newIDs: [String]) throws { lock.withLock { ids = newIDs } }
}

@Suite("The list of sessions known to be over")
struct KeepAwakeTombstoneTests {

    @Test("A full list refuses rather than forgetting what is on it")
    func fullListRefuses() throws {
        // Which name matters has nothing to do with how old it is: the oldest
        // is as likely as any to be the one session the journal still holds.
        let stone = MemoryStone()
        for id in 1 ... 8 { try stone.add(String(id)) }

        #expect(throws: KeepAwakeTombstoneFull.self) { try stone.add("9") }
        #expect(stone.endedSessionIDs() == (1 ... 8).map(String.init),
                "and nothing on the list was spent to make room")
    }

    @Test("A name already on the list costs nothing to add again")
    func addingTwiceIsFree() throws {
        let stone = MemoryStone()
        for id in 1 ... 8 { try stone.add(String(id)) }
        try stone.add("3")
        #expect(stone.endedSessionIDs().count == 8)
    }

    @Test("Room is claimed before the session that may need it")
    func roomIsCheckedBeforeStarting() throws {
        let stone = MemoryStone()
        for id in 1 ... 7 { try stone.add(String(id)) }
        #expect(stone.hasRoomForAnotherSession)

        try stone.add("8")
        #expect(!stone.hasRoomForAnotherSession, "the last place is taken")
    }

    @Test("One write landing gives the room back")
    func pruningRestoresRoom() throws {
        let stone = MemoryStone()
        for id in 1 ... 8 { try stone.add(String(id)) }
        #expect(!stone.hasRoomForAnotherSession)

        // What the journal is found holding is the only name still needed.
        try stone.keepOnly(["5"])

        #expect(stone.endedSessionIDs() == ["5"])
        #expect(stone.hasRoomForAnotherSession, "so refusing to start is recoverable")
    }
}
