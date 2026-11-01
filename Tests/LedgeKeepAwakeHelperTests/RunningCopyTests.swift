import Darwin
import Foundation
import Testing

@testable import LedgeKeepAwakeHelper

/// Whether the helper can tell that an update has replaced it.
///
/// Plain files in a folder of the test's own, standing in for the bundle. The
/// shapes are the ones the reviewer tried against a running process: a
/// rename-over with an identical copy, a bundle moved aside, and the one an
/// update actually does — the folder deleted and a new one written in its
/// place. Each test first checks that the file system really is in the shape
/// it is named for, because an assertion about a reading is only worth
/// something once the change it reads has happened.
@Suite("The helper noticing its own bundle replaced", .serialized)
struct RunningCopyTests {

    /// A bundle-shaped folder with one executable in it.
    private struct FakeBundle {
        let root: URL
        var folder: URL { root.appendingPathComponent("Ledge.app/Contents/MacOS") }
        var executable: URL { folder.appendingPathComponent("LedgeKeepAwakeHelper") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("running-copy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Ledge.app/Contents/MacOS"),
                                                    withIntermediateDirectories: true)
            try Data("helper".utf8).write(to: root.appendingPathComponent(
                "Ledge.app/Contents/MacOS/LedgeKeepAwakeHelper"))
        }

        func remove() {
            // Put permissions back first, or a test that took them away
            // leaves a folder nobody can delete.
            chmod(folder.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func inode(_ url: URL) -> UInt64? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    @Test("Nothing changed reads as the same copy")
    func untouchedIsTheSame() throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let copy = RunningCopy(path: bundle.executable.path)
        #expect(copy.launched != nil, "the premise: the file was noted at launch")
        #expect(copy.reading() == .same)
    }

    /// What an update does, and the only shape in which the code signing
    /// lookup itself fails: the folder deleted and an identical one written
    /// where it was.
    @Test("The folder deleted and written again reads as replaced, even with the same bytes")
    func deletedAndRecreatedIsReplaced() throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let copy = RunningCopy(path: bundle.executable.path)
        let before = try #require(Self.inode(bundle.executable))

        try FileManager.default.removeItem(at: bundle.root.appendingPathComponent("Ledge.app"))
        try FileManager.default.createDirectory(at: bundle.folder, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: bundle.executable)
        let after = try #require(Self.inode(bundle.executable))
        #expect(before != after, "the premise: a new file is at the path")
        #expect(try Data(contentsOf: bundle.executable) == Data("helper".utf8),
                "the premise: with identical bytes")

        #expect(copy.reading() == .replaced)
    }

    /// The lookup still passes here, and this check says replaced anyway.
    /// The next launch runs whatever is at the path now, so a clean helper
    /// leaving costs one relaunch and nothing else.
    @Test("A binary renamed over with a copy reads as replaced")
    func renamedOverIsReplaced() throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let copy = RunningCopy(path: bundle.executable.path)
        let before = try #require(Self.inode(bundle.executable))

        let staged = bundle.folder.appendingPathComponent(".staged")
        try Data("helper".utf8).write(to: staged)
        #expect(rename(staged.path, bundle.executable.path) == 0)
        #expect(Self.inode(bundle.executable) != before, "the premise: the rename landed")

        #expect(copy.reading() == .replaced)
    }

    @Test("A bundle moved aside reads as replaced, here or not")
    func movedAsideIsReplaced() throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let copy = RunningCopy(path: bundle.executable.path)

        let app = bundle.root.appendingPathComponent("Ledge.app")
        try FileManager.default.moveItem(at: app, to: bundle.root.appendingPathComponent("Old.app"))
        #expect(!FileManager.default.fileExists(atPath: bundle.executable.path),
                "the premise: nothing is at the path")
        #expect(copy.reading() == .replaced, "a path with nothing at it")

        // And then a new bundle where the old one was.
        try FileManager.default.createDirectory(at: bundle.folder, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: bundle.executable)
        #expect(copy.reading() == .replaced, "a path with something else at it")
    }

    /// The reading that must never make a helper leave. A permission error
    /// says nothing about which copy is installed, and a helper that guessed
    /// could exit from under a client.
    @Test("A path that cannot be read is not a replaced bundle")
    func unreadableIsUnknown() throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let copy = RunningCopy(path: bundle.executable.path)

        #expect(chmod(bundle.folder.path, 0) == 0)
        var info = stat()
        let refused = stat(bundle.executable.path, &info) != 0 && errno == EACCES
        try #require(refused, "the premise: the path can no longer be read (as root it still can)")

        #expect(copy.reading() == .unknown)
    }

    @Test("A copy that noted nothing at launch never reads as replaced")
    func nothingNotedIsUnknown() throws {
        #expect(RunningCopy(path: nil).reading() == .unknown)
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let missing = bundle.folder.appendingPathComponent("not-there").path
        let copy = RunningCopy(path: missing)
        #expect(copy.launched == nil, "the premise: there was nothing to note")
        #expect(copy.reading() == .unknown)
    }

    /// This process is a test runner rather than the helper, but it finds
    /// itself the way the helper does — and nobody is replacing it.
    @Test("A running process finds its own executable and reads as the same copy")
    func findsItself() {
        let copy = RunningCopy.atLaunch()
        #expect(copy.path?.hasPrefix("/") == true, "not an absolute path: \(copy.path ?? "nil")")
        #expect(copy.launched != nil)
        #expect(copy.reading() == .same)
    }

    /// The two halves together, as the daemon asks them on its tick.
    @Test("Replaced and clean leaves; replaced with a claim outstanding stays")
    func readingDrivesTheRule() throws {
        let bundle = try FakeBundle()
        defer { bundle.remove() }
        let copy = RunningCopy(path: bundle.executable.path)
        #expect(!IdleExit.shouldExit(clean: true, connections: 1, idleFor: 0,
                                     replaced: copy.reading() == .replaced),
                "a copy nobody replaced left from under its client")

        try FileManager.default.removeItem(at: bundle.executable)
        try Data("helper".utf8).write(to: bundle.executable)
        try #require(copy.reading() == .replaced, "the premise: the copy was replaced")

        #expect(IdleExit.shouldExit(clean: true, connections: 1, idleFor: 0,
                                    replaced: copy.reading() == .replaced))
        #expect(!IdleExit.shouldExit(clean: false, connections: 1, idleFor: 0,
                                     replaced: copy.reading() == .replaced))
    }
}
