import Foundation
import Testing

/// An update marked for the wrong Macs installs on an Intel Mac and leaves an
/// app that won't open, so the release has to stop before the feed goes up.
@Suite("Checking the feed before it goes up")
struct CheckAppcastTests {

    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Scripts/check-appcast.sh")

    private func item(_ build: Int, arm64: Bool) -> String {
        """
        <item>
            <title>Ledge</title>
            <sparkle:version>\(build)</sparkle:version>
            \(arm64 ? "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>" : "")
            <enclosure url="https://example.invalid/Ledge.dmg" />
        </item>
        """
    }

    private func passes(_ feed: String) throws -> Bool {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "appcast-\(UUID().uuidString).xml")
        try feed.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script.path, file.path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func feed(_ items: String...) -> String {
        "<rss><channel>\(items.joined())</channel></rss>"
    }

    @Test("A marked update passes, with older unmarked ones beside it")
    func marked() throws {
        #expect(try passes(feed(item(427, arm64: true))))
        #expect(try passes(feed(item(414, arm64: false), item(427, arm64: true))))
        #expect(try passes(feed(item(427, arm64: true), item(414, arm64: false))))
    }

    @Test("An unmarked newest update is refused, even with a marked older one")
    func unmarked() throws {
        #expect(try !passes(feed(item(427, arm64: false))))
        #expect(try !passes(feed(item(427, arm64: true), item(428, arm64: false))))
    }

    @Test("A feed with nothing to check is refused")
    func empty() throws {
        #expect(try !passes(feed()))
    }
}
