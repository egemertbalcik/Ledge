import Foundation
import Testing

@testable import LedgeHelperKit
@testable import LedgeKeepAwakeHelper

/// The store on disk, in a temporary directory that is nobody's but this test's.
///
/// The real one lives under /Library and belongs to root. Everything checked
/// here is the same code with its directory and its expected owner pointed
/// somewhere a test may write.
@Suite("The claim store on disk")
struct FileClaimStoreTests {

    private func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-claims-\(UUID().uuidString)", isDirectory: true)
    }

    private func ledger(_ expiry: UInt64 = 500, deadline: Date? = nil) -> ClaimLedger {
        ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": HelperClaim(
                holderLabel: "com.egemert.ledge.keepawake", boot: "boot-1",
                sessionID: "6E2C5E2A-0000-4000-8000-00000000000A", generation: 3,
                deadline: deadline, leaseExpiryContinuousNs: expiry, sleepDisabledClaimed: true)
        ])
    }

    private func clean(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    @Test("What is written is what comes back")
    func roundTrip() throws {
        let url = directory()
        defer { clean(url) }
        let store = FileClaimStore(directory: url, owner: getuid())
        #expect(store.tryLock())
        defer { store.unlock() }

        let written = ledger(deadline: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(written)
        #expect(try store.load() == written)
    }

    @Test("A store that was never written is an empty one, not a broken one")
    func missingFile() throws {
        let url = directory()
        defer { clean(url) }
        let store = FileClaimStore(directory: url, owner: getuid())
        #expect(store.tryLock())
        defer { store.unlock() }
        #expect(try store.load() == .empty)
    }

    @Test("Only one daemon holds the lock at a time")
    func lockIsExclusive() throws {
        let url = directory()
        defer { clean(url) }
        let first = FileClaimStore(directory: url, owner: getuid())
        let second = FileClaimStore(directory: url, owner: getuid())

        #expect(first.tryLock())
        // The other daemon finds it busy and is told so at once. Waiting here
        // would be a root process blocked on a lock another process holds
        // across a child it cannot see.
        #expect(!second.tryLock())

        first.unlock()
        #expect(second.tryLock())
        second.unlock()
    }

    @Test("Taking a lock already held by this daemon is not taking it twice")
    func lockIsReentrant() {
        let url = directory()
        defer { clean(url) }
        let store = FileClaimStore(directory: url, owner: getuid())
        #expect(store.tryLock())
        #expect(store.tryLock())
        store.unlock()

        let other = FileClaimStore(directory: url, owner: getuid())
        #expect(other.tryLock(), "one unlock is enough, because one lock was taken")
        other.unlock()
    }

    @Test("A store that cannot be understood is kept, not guessed at")
    func malformedIsSetAside() throws {
        let url = directory()
        defer { clean(url) }
        let store = FileClaimStore(directory: url, owner: getuid())
        #expect(store.tryLock())
        defer { store.unlock() }
        try store.save(ledger())

        let file = url.appendingPathComponent("claims.json")
        try Data("{ not json".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.load() }

        try store.moveAside()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: url.path)
            .filter { $0.hasPrefix("claims.json.unreadable-") }
        #expect(kept.count == 1, "somebody may want to know what it said")
        let text = try String(contentsOf: url.appendingPathComponent(kept[0]), encoding: .utf8)
        #expect(text == "{ not json")
    }

    @Test("A store from a later version is not guessed at either")
    func futureVersion() throws {
        let url = directory()
        defer { clean(url) }
        let store = FileClaimStore(directory: url, owner: getuid())
        #expect(store.tryLock())
        defer { store.unlock() }
        try store.save(ClaimLedger(v: ClaimLedger.currentVersion + 1, claims: [:]))

        // It may describe a claim this build does not know how to put back.
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test("Nobody but the owner may read or write any of it")
    func permissions() throws {
        let url = directory()
        defer { clean(url) }
        let store = FileClaimStore(directory: url, owner: getuid())
        #expect(store.tryLock())
        try store.save(ledger())
        store.unlock()

        func mode(_ path: String) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        }
        #expect(try mode(url.path) == 0o700)
        #expect(try mode(url.appendingPathComponent("claims.json").path) == 0o600)
        #expect(try mode(url.appendingPathComponent("claims.lock").path) == 0o600)
    }

    @Test("A store anybody can write to is not used")
    func worldWritableIsRefused() throws {
        let url = directory()
        defer { clean(url) }
        let store = FileClaimStore(directory: url, owner: getuid())
        #expect(store.tryLock())
        defer { store.unlock() }
        try store.save(ledger())

        // A claim file a lesser process can edit is a claim file that can be
        // made to say Ledge changed something it did not, or that it changed
        // nothing when it did.
        let file = url.appendingPathComponent("claims.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        #expect(throws: FileClaimStore.Trouble.notOurs(file.path)) { try store.load() }
    }

    @Test("A lock file anybody can write to is not locked")
    func worldWritableLockIsRefused() throws {
        let url = directory()
        defer { clean(url) }
        let store = FileClaimStore(directory: url, owner: getuid())
        #expect(store.tryLock())
        store.unlock()

        let lock = url.appendingPathComponent("claims.lock")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: lock.path)
        #expect(!store.tryLock(), "a lock everyone can take is not a lock")
    }

    @Test("Nothing half-written is left lying about")
    func noLeftovers() throws {
        let url = directory()
        defer { clean(url) }
        let store = FileClaimStore(directory: url, owner: getuid())
        #expect(store.tryLock())
        defer { store.unlock() }
        try store.save(ledger())
        try store.save(ledger(900))

        let files = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        #expect(files == ["claims.json", "claims.lock"])
    }

    @Test("A write that fails leaves the claim that was already there")
    func failedWriteKeepsTheOldRecord() throws {
        let url = directory()
        defer { clean(url) }
        let store = FileClaimStore(directory: url, owner: getuid())
        #expect(store.tryLock())
        defer { store.unlock() }
        let first = ledger(500)
        try store.save(first)

        // The disk says no. The record of what Ledge has already done must
        // survive that, or a restore nobody knows is owed goes undone.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try store.save(ledger(900)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)

        #expect(try store.load() == first)
    }
}
