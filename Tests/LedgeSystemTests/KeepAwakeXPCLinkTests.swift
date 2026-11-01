import Foundation
import LedgeHelperKit
import Security
import Testing

@testable import LedgeSystem

/// The link against real XPC, with the daemon's half in this process.
///
/// The failure these are about cannot be faked one layer up. A daemon still
/// running from a bundle an update deleted sends answers the app's code signing
/// check refuses, and XPC then does something its own header says it does not:
/// it leaves the connection up. The daemon goes on counting a client, never
/// idle-exits, and never makes way for the new copy. An anonymous listener and
/// a requirement nothing satisfies produce exactly that refusal — the same
/// error, the same open connection — with no root daemon anywhere.
@Suite("The link, over real XPC", .serialized, .timeLimit(.minutes(10)))
struct KeepAwakeXPCLinkTests {

    /// For as long as it takes. The suite's time limit catches a condition
    /// that never comes.
    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        while !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A requirement that compiles and that nothing on this Mac satisfies.
    private static let nobody = #"identifier "invalid.ledge.never-signed""#

    @Test("A refused answer drops the connection at once and says why")
    func refusedAnswerDropsTheConnection() async throws {
        let daemon = InProcessDaemon()
        defer { daemon.stop() }
        let link = KeepAwakeXPCLink(endpoint: daemon.endpoint, requirement: Self.nobody)

        await #expect(throws: KeepAwakeHelperOutOfDate.self) { try await link.status() }

        // Arrived: the message reached the daemon and was acted on. Without
        // this the error could be a connection that never formed, which is a
        // different failure with a different cure.
        try await waitUntil { daemon.calls == ["status"] }
        #expect(daemon.accepted == 1)

        // The fix. Nothing in XPC closed this; the link had to.
        #expect(!link.isConnected, "the link kept a connection whose answers it cannot hear")
        // And the daemon's side sees it go, which is what lets a real daemon's
        // count of clients reach zero.
        try await waitUntil { daemon.open == 0 }
        #expect(link.callsInFlight == 0)
    }

    /// The handover depends on this: the release it sends must still land,
    /// on a connection of its own, and must not leave that one open either.
    @Test("The next call still lands, on a fresh connection that is dropped too")
    func nextCallStillLands() async throws {
        let daemon = InProcessDaemon()
        defer { daemon.stop() }
        let link = KeepAwakeXPCLink(endpoint: daemon.endpoint, requirement: Self.nobody)

        await #expect(throws: KeepAwakeHelperOutOfDate.self) { try await link.status() }
        try await waitUntil { daemon.open == 0 }

        await #expect(throws: KeepAwakeHelperOutOfDate.self) {
            try await link.release(session: "s1", generation: 3)
        }
        try await waitUntil { daemon.calls == ["status", "release"] }
        #expect(daemon.accepted == 2, "the release went out on the connection that was dropped")
        #expect(!link.isConnected)
        try await waitUntil { daemon.open == 0 }
    }

    /// The control. Without it the refusal above could be the fixture's
    /// fault rather than the requirement's, and the connection being dropped
    /// could be the link dropping every connection.
    @Test("An answer the requirement accepts is heard, and the connection is kept")
    func acceptedAnswerKeepsTheConnection() async throws {
        let mine = try #require(Self.ownRequirement(),
                                "this process has no designated requirement to check against")
        let daemon = InProcessDaemon()
        defer { daemon.stop() }
        let link = KeepAwakeXPCLink(endpoint: daemon.endpoint, requirement: mine)

        let status = try await link.status()
        #expect(status.build == InProcessDaemon.build)
        #expect(link.isConnected)

        _ = try await link.release(session: "s1", generation: 1)
        #expect(daemon.accepted == 1, "a connection that was answered was not reused")
        #expect(daemon.open == 1)
        #expect(daemon.calls == ["status", "release"])
    }

    @Test("Only the code signing refusal is read as an out-of-date helper")
    func onlyTheRefusalCounts() {
        let refused = NSError(domain: NSCocoaErrorDomain,
                              code: NSXPCConnectionCodeSigningRequirementFailure)
        #expect(KeepAwakeXPCLink.isRefusedAnswer(refused))
        // The two everyday failures. Reading either as an update would put
        // a two-minute silence on top of a daemon that merely restarted.
        for code in [NSXPCConnectionInterrupted, NSXPCConnectionInvalid] {
            #expect(!KeepAwakeXPCLink.isRefusedAnswer(
                NSError(domain: NSCocoaErrorDomain, code: code)))
        }
        #expect(!KeepAwakeXPCLink.isRefusedAnswer(
            NSError(domain: NSPOSIXErrorDomain, code: NSXPCConnectionCodeSigningRequirementFailure)))
        #expect(!KeepAwakeXPCLink.isRefusedAnswer(KeepAwakeXPCUnavailable()))
    }

    /// What this very process satisfies, so the control can pass for the
    /// same reason the refusal fails.
    private static func ownRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }
}

/// The helper on disk, held to the same requirement the link holds answers to.
///
/// Real signatures, read-only. `/bin/ls` is signed by Apple and nobody else,
/// which makes it a binary whose answer to each requirement is known without
/// building a fixture of our own.
@Suite("Checking the helper on disk")
struct KeepAwakeInstalledHelperTests {

    private static let appleSigned = URL(fileURLWithPath: "/bin/ls")

    @Test("A binary the requirement accepts passes")
    func passes() {
        #expect(KeepAwakeXPCLink.check(executable: Self.appleSigned,
                                       against: "anchor apple") == .passes)
    }

    /// The case the check exists for: a signed binary that is not the one the
    /// app will talk to. A refusal from that is the installation, not a
    /// process an update left behind.
    @Test("A binary the requirement refuses fails")
    func fails() {
        #expect(KeepAwakeXPCLink.check(executable: Self.appleSigned,
                                       against: #"identifier "invalid.ledge.never-signed""#)
            == .fails)
    }

    @Test("A file with no signature at all fails")
    func unsignedFails() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-unsigned-\(UUID().uuidString)")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(KeepAwakeXPCLink.check(executable: url, against: "anchor apple") == .fails)
    }

    /// The read the client must not believe for long. A copy caught half
    /// written fails exactly as a wrong one does, and the same file a moment
    /// later passes — which is why a fail is asked about again.
    @Test("A binary caught half written fails, and the finished copy passes")
    func halfWrittenThenFinished() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-half-written-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let whole = try Data(contentsOf: Self.appleSigned)
        try whole.prefix(whole.count / 2).write(to: url)
        #expect(KeepAwakeXPCLink.check(executable: url, against: "anchor apple") == .fails,
                "a half-written binary did not read the way a wrong one does")

        try whole.write(to: url)
        #expect(KeepAwakeXPCLink.check(executable: url, against: "anchor apple") == .passes,
                "the premise: the finished copy is a good one")
    }

    /// Neither of these says anything about which helper is installed, and
    /// the rescue must not be held back for them.
    @Test("A check that could not be made is unchecked, not failed")
    func uncheckable() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-not-there-\(UUID().uuidString)")
        #expect(KeepAwakeXPCLink.check(executable: missing, against: "anchor apple") == .unchecked)
        #expect(KeepAwakeXPCLink.check(executable: Self.appleSigned,
                                       against: "this is not a requirement") == .unchecked)
    }

    /// The path the check looks at is the path launchd starts the helper
    /// from. They are written in two places — here and the script that
    /// writes the job's plist — and a check pointed at the wrong file would
    /// call every update a broken installation.
    @Test("The helper the check reads is the one the job runs")
    func samePathAsTheJob() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/helper-plist.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("<key>BundleProgram</key>\n    <string>\(KeepAwakeXPCLink.helperProgram)</string>"),
                "helper-plist.sh names a different BundleProgram")
    }
}

/// The daemon's half of the protocol, answering from this process.
///
/// It records what reached it and counts its connections by identity, the way
/// the real daemon's tally does, because "the daemon saw the client go" is the
/// thing the fix is for.
private final class InProcessDaemon: NSObject, NSXPCListenerDelegate, KeepAwakeHelperProtocol,
                                     @unchecked Sendable {

    static let build = "test.in-process.keepawake"

    private let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var opened: Set<Int> = []
    private var acceptedCount = 0
    private var received: [String] = []
    private var connections: [NSXPCConnection] = []

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    var accepted: Int { lock.withLock { acceptedCount } }
    var open: Int { lock.withLock { opened.count } }
    var calls: [String] { lock.withLock { received } }

    func stop() {
        listener.invalidate()
        let held = lock.withLock { connections }
        held.forEach { $0.invalidate() }
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: KeepAwakeHelperProtocol.self)
        connection.exportedObject = self
        let identity: Int = lock.withLock {
            acceptedCount += 1
            opened.insert(acceptedCount)
            connections.append(connection)
            return acceptedCount
        }
        connection.invalidationHandler = { [weak self] in self?.closed(identity) }
        connection.interruptionHandler = { [weak self] in self?.closed(identity) }
        connection.resume()
        return true
    }

    private func closed(_ identity: Int) {
        lock.withLock { _ = opened.remove(identity) }
    }

    private func note(_ call: String) {
        lock.withLock { received.append(call) }
    }

    func status(reply: @escaping (String, Int, Bool, Bool, Bool, Bool, Bool) -> Void) {
        note("status")
        reply(Self.build, 0, false, true, false, false, false)
    }

    func hold(session: String, generation: Int, until deadline: Date?, leaseSeconds: Double,
              reply: @escaping (Int) -> Void) {
        note("hold")
        reply(KeepAwakeHelperCode.ok.rawValue)
    }

    func release(session: String, generation: Int, reply: @escaping (Int) -> Void) {
        note("release")
        reply(KeepAwakeHelperCode.ok.rawValue)
    }

    func setLowPowerMode(_ on: Bool, session: String, generation: Int,
                         reply: @escaping (Int) -> Void) {
        note("low-power")
        reply(KeepAwakeHelperCode.ok.rawValue)
    }
}
