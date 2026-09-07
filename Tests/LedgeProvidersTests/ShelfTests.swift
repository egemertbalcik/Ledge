import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

/// A scratch directory of real files, so the store's existence checks are
/// exercised rather than stubbed.
@MainActor
private final class Scratch {
    let root: URL
    private(set) var stored = ""

    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-shelf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ name: String) -> URL {
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeStore() -> ShelfStore {
        ShelfStore(load: { [self] in stored }, save: { [self] in stored = $0 })
    }
}

@Suite("Shelf store")
@MainActor
struct ShelfStoreTests {

    @Test("Dropped files are added, with a name and an icon")
    func addsFiles() {
        let scratch = Scratch()
        let store = scratch.makeStore()
        let added = store.add([scratch.file("one.txt"), scratch.file("two.txt")])

        #expect(added == 2)
        #expect(store.items.map(\.name) == ["one.txt", "two.txt"])
        #expect(store.items.allSatisfy { $0.iconData != nil }, "the Finder icon should be rendered")
    }

    @Test("The same file cannot be shelved twice")
    func rejectsDuplicates() {
        let scratch = Scratch()
        let store = scratch.makeStore()
        let file = scratch.file("one.txt")

        #expect(store.add([file]) == 1)
        #expect(store.add([file]) == 0)
        #expect(store.items.count == 1)
    }

    @Test("A path that does not exist is ignored")
    func ignoresMissingPaths() {
        let scratch = Scratch()
        let store = scratch.makeStore()
        let ghost = scratch.root.appendingPathComponent("never-existed.txt")

        #expect(store.add([ghost]) == 0)
        #expect(store.isEmpty)
    }

    @Test("Folders are shelved and flagged as such")
    func acceptsFolders() {
        let scratch = Scratch()
        let store = scratch.makeStore()
        store.add([scratch.folder("Docs")])

        #expect(store.items.first?.isDirectory == true)
    }

    @Test("Beyond capacity the oldest entries fall off")
    func enforcesCapacity() {
        let scratch = Scratch()
        let store = scratch.makeStore()
        let files = (0..<(ShelfStore.capacity + 3)).map { scratch.file("f\($0).txt") }
        store.add(files)

        #expect(store.items.count == ShelfStore.capacity)
        #expect(store.items.first?.name == "f3.txt", "the three oldest were dropped")
        #expect(store.items.last?.name == "f\(ShelfStore.capacity + 2).txt")
    }

    @Test("Removing and clearing work, and notify")
    func removeAndClear() {
        let scratch = Scratch()
        let store = scratch.makeStore()
        var notifications = 0
        store.onChange = { notifications += 1 }

        let a = scratch.file("a.txt")
        store.add([a, scratch.file("b.txt")])
        store.remove(path: a.path)
        #expect(store.items.map(\.name) == ["b.txt"])

        store.clear()
        #expect(store.isEmpty)
        #expect(notifications == 3, "add, remove, clear")
    }

    @Test("Removing something that is not there changes nothing")
    func removeUnknownIsNoop() {
        let scratch = Scratch()
        let store = scratch.makeStore()
        var notifications = 0
        store.add([scratch.file("a.txt")])
        store.onChange = { notifications += 1 }

        store.remove(path: "/nowhere/at/all.txt")
        #expect(store.items.count == 1)
        #expect(notifications == 0)
    }

    @Test("Paths survive a relaunch; files deleted meanwhile do not")
    func persistsAcrossRelaunch() {
        let scratch = Scratch()
        let keep = scratch.file("keep.txt")
        let doomed = scratch.file("doomed.txt")

        let first = scratch.makeStore()
        first.add([keep, doomed])
        #expect(first.items.count == 2)

        try? FileManager.default.removeItem(at: doomed)

        // A second store over the same backing store is exactly what a relaunch
        // looks like.
        let second = scratch.makeStore()
        #expect(second.items.map(\.name) == ["keep.txt"])
    }

    @Test("Pruning drops files deleted while Ledge was running")
    func prunesMissing() {
        let scratch = Scratch()
        let store = scratch.makeStore()
        let doomed = scratch.file("doomed.txt")
        store.add([scratch.file("keep.txt"), doomed])

        try? FileManager.default.removeItem(at: doomed)
        store.pruneMissing()
        #expect(store.items.map(\.name) == ["keep.txt"])
    }
}

@Suite("Shelf provider")
@MainActor
struct ShelfProviderTests {

    private func collect(
        _ provider: ShelfProvider,
        while body: () -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("An empty shelf publishes nothing at all")
    func emptyShelfIsSilent() async {
        let scratch = Scratch()
        let provider = ShelfProvider(store: scratch.makeStore(), now: { 100 })
        let events = await collect(provider) {}
        #expect(events.isEmpty)
    }

    @Test("Dropping a file publishes a standing card with no expiry")
    func publishesOnDrop() async {
        let scratch = Scratch()
        let store = scratch.makeStore()
        let provider = ShelfProvider(store: store, now: { 100 })

        let events = await collect(provider) {
            store.add([scratch.file("a.txt")])
        }

        guard case .publish(let activity)? = events.last else {
            Issue.record("expected a publish")
            return
        }
        #expect(activity.id == ActivityID(kind: .shelf, source: "user"))
        #expect(activity.expiresAfter == nil, "parked files must not time out")
        guard case .shelf(let payload) = activity.payload else {
            Issue.record("expected a shelf payload")
            return
        }
        #expect(payload.items.map(\.name) == ["a.txt"])
    }

    @Test("Emptying the shelf retracts the card")
    func retractsWhenEmptied() async {
        let scratch = Scratch()
        let store = scratch.makeStore()
        store.add([scratch.file("a.txt")])
        let provider = ShelfProvider(store: store, now: { 100 })

        let events = await collect(provider) { store.clear() }
        #expect(events.contains(.retract(ActivityID(kind: .shelf, source: "user"))))
    }
}
