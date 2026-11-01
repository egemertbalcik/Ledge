import Foundation
import Security
import Testing

@testable import LedgeHelperKit
@testable import LedgeKeepAwakeHelper

/// The whole daemon, deciding to leave once its bundle is replaced.
///
/// `IdleExit` and `RunningCopy` are tested on their own; these are about the
/// places the daemon asks — a client going, a release landing, a restore
/// finishing — which only exist inside a running daemon. Nothing privileged
/// is touched: the listener is anonymous rather than launchd's, the claim
/// store is a folder of the test's own, `pmset` is a script that keeps its
/// "setting" in a file beside it, the bundle is a file the test replaces,
/// and leaving is recorded rather than done.
@Suite("The daemon leaving a replaced bundle", .serialized, .timeLimit(.minutes(10)))
struct DaemonExitTests {

    // MARK: - The rig

    private final class Rig {
        let folder: URL
        let executable: URL
        let state: URL
        let listener = NSXPCListener.anonymous()
        let exits = Exits()
        let daemon: KeepAwakeDaemon
        /// The same note the daemon was given, so a test can see the
        /// replacement the way the daemon will.
        let copy: RunningCopy

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("ledge-daemon-exit-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            executable = folder.appendingPathComponent("LedgeKeepAwakeHelper")
            try Data("helper".utf8).write(to: executable)
            state = folder.appendingPathComponent("sleepdisabled")
            try "0".write(to: state, atomically: true, encoding: .utf8)

            // `pmset` as far as the daemon can tell: reads print the file,
            // writes to disablesleep change it, everything else succeeds.
            let tool = folder.appendingPathComponent("pmset")
            try """
                #!/bin/sh
                STATE='\(state.path)'
                case "$1" in
                  -g)
                    if [ "$2" = "custom" ]; then
                      printf 'Battery Power:\\n lowpowermode         0\\nAC Power:\\n lowpowermode         0\\n'
                    else
                      printf 'System-wide power settings:\\n SleepDisabled\\t\\t%s\\n' "$(cat "$STATE")"
                    fi ;;
                  -a)
                    if [ "$2" = "disablesleep" ]; then printf '%s' "$3" > "$STATE"; fi ;;
                esac
                exit 0
                """.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: tool.path)

            let requirement = try #require(Self.ownRequirement(),
                                           "this process has no designated requirement")
            let state = state
            let exits = exits
            copy = RunningCopy(path: executable.path)
            daemon = KeepAwakeDaemon(
                arguments: HelperArguments(clientIdentifier: "test.ledge.exit-\(UUID().uuidString.prefix(8))",
                                           requirement: requirement),
                store: FileClaimStore(directory: folder.appendingPathComponent("store"),
                                      owner: getuid()),
                pmset: ProcessPmsetRunner(tool: tool.path),
                watchdogPmset: ProcessPmsetRunner(tool: tool.path),
                bootID: "boot-test",
                runningCopy: copy,
                listener: listener,
                handlesTermination: false,
                // What the setting was at the moment of leaving, so a test
                // can say the restore landed first.
                exitProcess: { code in
                    exits.record(code, setting: (try? String(contentsOf: state, encoding: .utf8)) ?? "?")
                }
            )
            daemon.start()
        }

        /// What an update does: the folder's file deleted and written again.
        func replaceBundle() throws {
            try FileManager.default.removeItem(at: executable)
            try Data("helper".utf8).write(to: executable)
        }

        var setting: String { (try? String(contentsOf: state, encoding: .utf8)) ?? "?" }

        func connect() -> Client { Client(listener.endpoint) }

        /// The daemon's timers and listener stopped, then its folder gone.
        /// Without the first, every daemon a test started went on ticking in
        /// this process for the rest of the run.
        func tearDown() {
            daemon.stop()
            try? FileManager.default.removeItem(at: folder)
        }

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

    /// Every exit the daemon asked for, and the setting at that moment.
    final class Exits: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(code: Int32, setting: String)] = []
        func record(_ code: Int32, setting: String) { lock.withLock { stored.append((code, setting)) } }
        var all: [(code: Int32, setting: String)] { lock.withLock { stored } }
    }

    /// The app's side of one connection.
    final class Client: @unchecked Sendable {
        private let connection: NSXPCConnection

        init(_ endpoint: NSXPCListenerEndpoint) {
            connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: KeepAwakeHelperProtocol.self)
            connection.resume()
        }

        struct Status { let sleepDisabled: Int; let ours: Bool; let clean: Bool }

        func status() async throws -> Status {
            try await call { proxy, done in
                proxy.status { _, sleepDisabled, ours, clean, _, _, _ in
                    done(Status(sleepDisabled: sleepDisabled, ours: ours, clean: clean))
                }
            }
        }

        func hold(_ session: String) async throws -> Int {
            try await call { proxy, done in
                proxy.hold(session: session, generation: 1, until: nil, leaseSeconds: 90) { done($0) }
            }
        }

        /// Sent and not waited for. The daemon may leave before its answer
        /// goes out, which is the point of one of these tests.
        func sendRelease(_ session: String) {
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as? KeepAwakeHelperProtocol
            proxy?.release(session: session, generation: 1) { _ in }
        }

        func close() { connection.invalidate() }

        private func call<T: Sendable>(
            _ body: @escaping (KeepAwakeHelperProtocol, @escaping @Sendable (T) -> Void) -> Void
        ) async throws -> T {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<T, Error>) in
                let once = Once(k)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ once.resume(.failure($0)) })
                        as? KeepAwakeHelperProtocol else {
                    once.resume(.failure(CocoaError(.featureUnsupported)))
                    return
                }
                body(proxy) { once.resume(.success($0)) }
            }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var k: CheckedContinuation<T, Error>?
        init(_ k: CheckedContinuation<T, Error>) { self.k = k }
        func resume(_ result: Result<T, Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<T, Error>? in
                defer { k = nil }
                return k
            }
            waiting?.resume(with: result)
        }
    }

    /// Ten seconds, then a failure that says what never came.
    ///
    /// Everything here is one process talking to itself through a shell
    /// script, and each condition arrives in well under a second. An exit
    /// path that broke used to show up as a hang until the suite's
    /// ten-minute limit; this turns it into a named failure instead.
    private func waitUntil(_ what: Comment,
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("gave up after ten seconds waiting for \(what)",
                             sourceLocation: sourceLocation)
                throw GaveUp()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct GaveUp: Error {}

    // MARK: - The tests

    @Test("A replaced copy with nothing held leaves as soon as its client goes")
    func replacedAndCleanLeavesOnClose() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let client = rig.connect()
        // Arrived: started up, clean, and counting this client.
        try await waitUntil("a clean start") { try await client.status().clean }
        try await waitUntil("one client counted") { rig.daemon.liveConnections == 1 }

        try rig.replaceBundle()
        try #require(rig.copy.reading() == .replaced, "the premise: the bundle was replaced")
        #expect(rig.exits.all.isEmpty, "it left before anybody went")

        client.close()
        try await waitUntil("the exit") { !rig.exits.all.isEmpty }
        #expect(rig.exits.all.first?.code == 0)
    }

    /// The ordinary rule is untouched: a client going is not a reason to
    /// leave a bundle nobody replaced. That waits for the idle tick.
    @Test("A copy nobody replaced stays when its client goes")
    func notReplacedStays() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let client = rig.connect()
        try await waitUntil("a clean start") { try await client.status().clean }
        try await waitUntil("one client counted") { rig.daemon.liveConnections == 1 }

        client.close()
        // Arrived: the close has been counted, so whatever it was going to
        // do, it has done.
        try await waitUntil("the close counted") { rig.daemon.liveConnections == 0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.exits.all.isEmpty, "a copy nobody replaced left when its client went")
    }

    /// The rule that must not move. A replaced copy holding a claim stays
    /// through a client going, and leaves only once the release's restore
    /// has put the setting back.
    @Test("A replaced copy holding a claim stays until the release has put it back")
    func replacedWithAClaimWaitsForTheRestore() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let holder = rig.connect()
        try await waitUntil("a clean start") { try await holder.status().clean }

        let session = UUID().uuidString
        #expect(try await holder.hold(session) == KeepAwakeHelperCode.ok.rawValue)
        // Arrived: the fake setting is on, the claim is ours, and the core is
        // not clean.
        try await waitUntil("the hold applied") {
            let now = try await holder.status()
            return now.ours && now.sleepDisabled == 1 && !now.clean
        }
        #expect(rig.setting == "1")

        try rig.replaceBundle()
        try #require(rig.copy.reading() == .replaced, "the premise: the bundle was replaced")

        // A second client comes and goes. Replaced, but not clean: stays.
        let passer = rig.connect()
        _ = try await passer.status()
        try await waitUntil("two clients counted") { rig.daemon.liveConnections == 2 }
        passer.close()
        try await waitUntil("one client counted") { rig.daemon.liveConnections == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.exits.all.isEmpty, "a replaced copy left with a claim outstanding")

        // The release lands, the restore runs, and only then does it go.
        holder.sendRelease(session)
        try await waitUntil("the exit") { !rig.exits.all.isEmpty }
        #expect(rig.exits.all.first?.code == 0)
        #expect(rig.exits.all.first?.setting == "0",
                "it left before the setting was put back")
    }
}
