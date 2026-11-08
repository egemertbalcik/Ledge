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
        source.startWatching { _ in }
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

    @Test("Watching hands over what is already there, then a feed renamed into the folder")
    func hearsARename() async throws {
        let scratch = FeedsScratch()
        scratch.write("first.json", #"{"version": 1}"#)
        let source = FeedFolderSource(directory: scratch.root)
        var deliveries: [[FeedFile]] = []
        source.startWatching { deliveries.append($0) }
        defer { source.stopWatching() }

        try await waitUntil { !deliveries.isEmpty }
        #expect(deliveries.first?.map(\.name) == ["first"], "the folder's contents never arrived")

        scratch.replace("limits.json", with: #"{"version": 1, "title": "One"}"#)
        try await waitUntil { deliveries.last?.map(\.name) == ["first", "limits"] }
        #expect(deliveries.last?.map(\.name) == ["first", "limits"], "the rename was never heard")

        // And again over a file that is already there, which is what a
        // producer does every minute.
        scratch.replace("limits.json", with: #"{"version": 1, "title": "Two"}"#)
        try await waitUntil { text(of: "limits", in: deliveries.last)?.contains("Two") == true }
        #expect(text(of: "limits", in: deliveries.last)?.contains("Two") == true,
                "a file replaced over another was not heard")
    }

    @Test("Stopping is the end of the callbacks, including a read already under way")
    func stopIsFinal() async throws {
        let scratch = FeedsScratch()
        scratch.write("early.json", #"{"version": 1}"#)
        let source = FeedFolderSource(directory: scratch.root)
        var heard = 0
        source.startWatching { _ in heard += 1 }
        source.stopWatching()
        scratch.replace("late.json", with: #"{"version": 1}"#)
        try await Task.sleep(for: .milliseconds(500))
        #expect(heard == 0)
    }

    @Test("A producer writing faster than the burst delay is still heard while it writes")
    func aBusyProducerIsHeard() async throws {
        let scratch = FeedsScratch()
        let source = FeedFolderSource(directory: scratch.root)
        var deliveries: [[FeedFile]] = []
        source.startWatching { deliveries.append($0) }
        defer { source.stopWatching() }
        try await waitUntil { !deliveries.isEmpty }
        #expect(deliveries.count == 1, "the first, empty reading never arrived")

        // Three seconds of a write every 50 ms, well inside the 150 ms delay,
        // so a delay that only restarts would hear nothing until it stopped.
        var round = 0
        let end = ContinuousClock.now + .seconds(3)
        var heardDuringBurst = false
        while ContinuousClock.now < end {
            round += 1
            scratch.replace("busy.json", with: #"{"version": 1, "round": \#(round)}"#)
            try await Task.sleep(for: .milliseconds(50))
            if deliveries.count > 1 { heardDuringBurst = true }
        }
        #expect(heardDuringBurst, "nothing was read while the producer kept writing")
    }

    // MARK: - Untrusted files

    @Test("A link is never followed, wherever it points")
    func linksAreRefused() throws {
        let scratch = FeedsScratch()
        let outside = FeedsScratch()
        let target = outside.write("secret.json", #"{"version": 1, "title": "outside"}"#)
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root.appendingPathComponent("link.json").path,
            withDestinationPath: target.path
        )
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root.appendingPathComponent("zero.json").path,
            withDestinationPath: "/dev/zero"
        )
        try FileManager.default.createDirectory(
            at: scratch.root.appendingPathComponent("folder.json"), withIntermediateDirectories: false
        )
        scratch.write("real.json", #"{"version": 1}"#)
        let reading = FeedFolderSource.read(scratch.root)
        #expect(reading.files.map(\.name) == ["real"])
        // And each says why, so a feed linked in from a dotfiles folder is
        // not simply missing with nothing in the log.
        #expect(reading.refused["link.json"]?.contains("link") == true)
        #expect(reading.refused["zero.json"]?.contains("link") == true)
        #expect(reading.refused["folder.json"] == "it is not a plain file")
        #expect(reading.refused["real.json"] == nil)
    }

    /// A reader stuck opening a pipe waits for a writer that never comes, and
    /// a blocked open cannot be cancelled, so a time limit alone would leave
    /// the run hanging. A few seconds in, this opens the pipe's other end,
    /// which frees a stuck read so the timing check can fail it. With no
    /// reader waiting, that open finds nobody and does nothing.
    @Test("A pipe is skipped at once, not waited on", .timeLimit(.minutes(1)))
    func pipesAreRefused() async throws {
        let scratch = FeedsScratch()
        let path = scratch.root.appendingPathComponent("pipe.json").path
        #expect(mkfifo(path, 0o600) == 0, "the fixture never made its pipe")
        scratch.write("real.json", #"{"version": 1}"#)

        let rescue = Task.detached {
            try await Task.sleep(for: .seconds(3))
            while true {
                let fd = open(path, O_WRONLY | O_NONBLOCK)
                if fd >= 0 { close(fd) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { rescue.cancel() }

        let root = scratch.root
        let started = ContinuousClock.now
        let files = await Task.detached { FeedFolderSource.read(root).files }.value
        #expect(ContinuousClock.now - started < .seconds(2), "the read waited on the pipe")
        #expect(files.map(\.name) == ["real"])
        #expect(FeedFolderSource.refusal(atPath: path) == "it is not a plain file")
    }

    @Test("A file read straight is held to the limit too")
    func directReadIsCapped() {
        let scratch = FeedsScratch()
        let url = scratch.write("huge.json", String(repeating: "x", count: FeedParser.maxBytes * 3))
        let file = FeedFolderSource.readFile(atPath: url.path, name: "huge")
        #expect(file != nil)
        #expect(file?.data == nil)
        // Turned away on its size alone: the whole size is reported, which
        // reading up to the limit and stopping could not know.
        #expect(file?.byteCount == FeedParser.maxBytes * 3)
    }

    @Test("Only the first sixteen files by name are read")
    func capped() throws {
        let scratch = FeedsScratch()
        for index in 0..<30 {
            scratch.write(String(format: "feed-%02d.json", index), #"{"version": 1}"#)
        }
        // Past the cap, names that could never be read. Counted by name, they
        // are overflow; opened to be counted, they would not be.
        for index in 0..<10 {
            try FileManager.default.createDirectory(
                at: scratch.root.appendingPathComponent(String(format: "zz-%02d.json", index)),
                withIntermediateDirectories: false
            )
        }
        let reading = FeedFolderSource.read(scratch.root)
        #expect(reading.files.count == FeedFolderSource.maxFiles)
        #expect(reading.files.first?.name == "feed-00")
        #expect(reading.files.last?.name == String(format: "feed-%02d", FeedFolderSource.maxFiles - 1))
        #expect(reading.overflow == 40 - FeedFolderSource.maxFiles)
        // Nothing past the cap was opened, so nothing past it was judged.
        #expect(reading.refused.isEmpty)
    }

    @Test("Feeds live in a folder of their own inside Ledge's")
    func defaultFolder() {
        let url = FeedFolderSource.defaultDirectory()
        #expect(url.lastPathComponent == "Feeds")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Ledge")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    private func text(of name: String, in files: [FeedFile]?) -> String? {
        files?.first { $0.name == name }?.data.map { String(decoding: $0, as: UTF8.self) }
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
