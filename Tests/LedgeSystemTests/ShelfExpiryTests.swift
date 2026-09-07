import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

@Suite("Screenshots leave the shelf on their own")
@MainActor
struct ShelfExpiryTests {

    /// A real directory, because the store checks that a path exists before it
    /// will keep it.
    private func makeFiles(_ count: Int) throws -> (dir: URL, urls: [URL]) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-shelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = (0..<count).map { dir.appendingPathComponent("shot-\($0).png") }
        for url in urls { try Data("x".utf8).write(to: url) }
        return (dir, urls)
    }

    private func store(_ storage: Storage) -> ShelfStore {
        ShelfStore(load: { storage.value }, save: { storage.value = $0 })
    }

    private final class Storage: @unchecked Sendable {
        var value = ""
    }

    @Test("A dropped file has no clock on it")
    func droppedFilesStay() throws {
        let files = try makeFiles(1)
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let shelf = store(Storage())
        #expect(shelf.add(files.urls) == 1)
        #expect(shelf.items.first?.expiresAt == nil)
        #expect(shelf.pruneExpired(now: .greatestFiniteMagnitude) == 0)
    }

    @Test("A screenshot goes when its day is up, and not before")
    func screenshotsExpire() throws {
        let files = try makeFiles(1)
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let shelf = store(Storage())
        let now = Date().timeIntervalSinceReferenceDate
        #expect(shelf.add(files.urls, expiresAfter: ShelfStore.screenshotLifetime) == 1)

        // Most of a day later it is still there — the point of keeping it.
        #expect(shelf.pruneExpired(now: now + ShelfStore.screenshotLifetime - 60) == 0)
        #expect(shelf.items.count == 1)

        #expect(shelf.pruneExpired(now: now + ShelfStore.screenshotLifetime + 1) == 1)
        #expect(shelf.items.isEmpty)
    }

    @Test("Only the entries on a clock are dropped")
    func mixedShelfKeepsTheRest() throws {
        let files = try makeFiles(2)
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let shelf = store(Storage())
        _ = shelf.add([files.urls[0]])
        _ = shelf.add([files.urls[1]], expiresAfter: 60)
        #expect(shelf.pruneExpired(now: Date().timeIntervalSinceReferenceDate + 120) == 1)
        #expect(shelf.items.map(\.path) == [files.urls[0].path])
    }

    /// The clock has to survive a relaunch, or a screenshot taken before bed
    /// would come back permanent.
    @Test("The expiry is remembered across a restart")
    func expiryPersists() throws {
        let files = try makeFiles(2)
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let storage = Storage()
        let first = store(storage)
        _ = first.add([files.urls[0]])
        _ = first.add([files.urls[1]], expiresAfter: ShelfStore.screenshotLifetime)

        let restored = store(storage)
        #expect(restored.items.count == 2)
        #expect(restored.items.first { $0.path == files.urls[0].path }?.expiresAt == nil)
        #expect(restored.items.first { $0.path == files.urls[1].path }?.expiresAt != nil)
    }

    /// Everything stored before this existed is a file the user put there.
    @Test("Entries written by older builds stay")
    func legacyEntriesArePermanent() throws {
        let files = try makeFiles(1)
        defer { try? FileManager.default.removeItem(at: files.dir) }
        let storage = Storage()
        storage.value = files.urls[0].path + "\u{1F}"
        let shelf = store(storage)
        #expect(shelf.items.count == 1)
        #expect(shelf.items.first?.expiresAt == nil)
    }
}
