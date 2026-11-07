import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

/// A scratch folder standing in for `~/Library/Application Support/Ledge/Feeds`.
private final class FeedsScratch {
    let root: URL

    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-feeds-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ name: String, _ contents: String) -> URL {
        let url = root.appendingPathComponent(name)
        try? Data(contents.utf8).write(to: url)
        return url
    }

    /// The way a producer is meant to update a file: a temporary file beside
    /// it, renamed over it.
    func replace(_ name: String, with contents: String) {
        let temporary = root.appendingPathComponent(".\(name).tmp")
        try? Data(contents.utf8).write(to: temporary)
        // rename(2) replaces the destination atomically, which is the whole
        // reason producers write this way.
        _ = rename(temporary.path, root.appendingPathComponent(name).path)
    }
}

@Suite("Feed folder")
@MainActor
struct FeedFolderSourceTests {

    @Test("Every .json file is a feed, named without its extension, in name order")
    func listsJSON() {
        let scratch = FeedsScratch()
        scratch.write("zeta.json", #"{"version": 1}"#)
        scratch.write("alpha.json", #"{"version": 1}"#)
        let files = FeedFolderSource(directory: scratch.root).files()
        #expect(files.map { $0.name } == ["alpha", "zeta"])
        #expect(files.allSatisfy { $0.data != nil })
        #expect(files.first?.data == Data(#"{"version": 1}"#.utf8))
    }

    @Test("Anything else in the folder is left alone")
    func ignoresTheRest() throws {
        let scratch = FeedsScratch()
        scratch.write("real.json", #"{"version": 1}"#)
        scratch.write("notes.txt", "hello")
        scratch.write("real.json.tmp", "half")
        scratch.write(".hidden.json", #"{"version": 1}"#)
        try FileManager.default.createDirectory(
            at: scratch.root.appendingPathComponent("folder.json"), withIntermediateDirectories: true
        )
        let files = FeedFolderSource(directory: scratch.root).files()
        #expect(files.map { $0.name } == ["real"])
    }

    @Test("A file over the limit is reported, and never read")
    func oversizeIsNotRead() {
        let scratch = FeedsScratch()
        let big = String(repeating: " ", count: FeedParser.maxBytes + 1)
        scratch.write("huge.json", #"{"version": 1}"# + big)
        let files = FeedFolderSource(directory: scratch.root).files()
        #expect(files.count == 1)
        #expect(files.first?.data == nil)
        #expect((files.first?.byteCount ?? 0) > FeedParser.maxBytes)
    }

    @Test("A folder that is not there holds no feeds, and is not made by looking")
    func missingFolder() {
        let scratch = FeedsScratch()
        let missing = scratch.root.appendingPathComponent("not-yet", isDirectory: true)
        let source = FeedFolderSource(directory: missing)
        #expect(source.files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("Watching makes the folder, so there is somewhere to put a feed")
    func watchingMakesTheFolder() {
        let scratch = FeedsScratch()
        let folder = scratch.root.appendingPathComponent("Feeds", isDirectory: true)
        let source = FeedFolderSource(directory: folder)
        source.startWatching {}
        defer { source.stopWatching() }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("The file's own date comes with it")
    func modificationDate() throws {
        let scratch = FeedsScratch()
        let url = scratch.write("dated.json", #"{"version": 1}"#)
        let when = Date(timeIntervalSince1970: 1_794_000_000)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        let files = FeedFolderSource(directory: scratch.root).files()
        #expect(abs((files.first?.modifiedAt ?? 0) - 1_794_000_000) < 1)
    }

    @Test("A feed renamed into the folder is heard")
    func hearsARename() async throws {
        let scratch = FeedsScratch()
        let source = FeedFolderSource(directory: scratch.root)
        var heard = 0
        source.startWatching { heard += 1 }
        defer { source.stopWatching() }

        scratch.replace("limits.json", with: #"{"version": 1, "title": "One"}"#)
        try await waitUntil { heard > 0 }
        #expect(heard > 0, "the folder never said anything changed")
        #expect(source.files().map { $0.name } == ["limits"])

        // And again over a file that is already there, which is what a
        // producer does every minute.
        let before = heard
        scratch.replace("limits.json", with: #"{"version": 1, "title": "Two"}"#)
        try await waitUntil { heard > before }
        #expect(heard > before, "a file replaced over another was not heard")
        let text = source.files().first.flatMap { $0.data }.map { String(decoding: $0, as: UTF8.self) }
        #expect(text?.contains("Two") == true)
    }

    @Test("Stopping is the end of the callbacks")
    func stopIsFinal() async throws {
        let scratch = FeedsScratch()
        let source = FeedFolderSource(directory: scratch.root)
        var heard = 0
        source.startWatching { heard += 1 }
        source.stopWatching()
        scratch.replace("late.json", with: #"{"version": 1}"#)
        try await Task.sleep(for: .milliseconds(500))
        #expect(heard == 0)
    }

    /// The folder's events arrive on the main queue, after a short delay that
    /// gathers a burst into one; a loaded runner can be slow to deliver them.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
