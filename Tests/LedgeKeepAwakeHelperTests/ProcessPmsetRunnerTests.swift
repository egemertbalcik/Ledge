import Foundation
import Testing

@testable import LedgeHelperKit
@testable import LedgeKeepAwakeHelper

/// The one privileged act, run against tools that are not `pmset`.
///
/// Nothing in this file may change this Mac's power settings, so the tool is a
/// required argument with no default and every test points it at a script it
/// wrote itself a moment earlier. What is being checked is the handling —
/// timeouts, signals, reaping, draining, what the child inherits — which is
/// the same whatever the tool at the end of it happens to be.
@Suite("Running pmset", .serialized)
struct ProcessPmsetRunnerTests {

    // MARK: Tools that are not pmset

    private func tool(_ body: String, shebang: String = "#!/bin/sh") throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-fake-tool-\(UUID().uuidString)")
        try "\(shebang)\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url.path
    }

    /// Runs one command and waits for the answer.
    ///
    /// Awaited rather than blocked on: a test that held its thread while the
    /// child ran would be competing with the very queues it is waiting for.
    private func answer(_ runner: ProcessPmsetRunner, _ command: PmsetCommand,
                        opID: Int = 7) async -> (id: Int, outcome: PmsetOutcome) {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            runner.report { identifier, outcome in once.resume(identifier, outcome) }
            runner.start(command, opID: opID)
        }
    }

    /// A continuation may be resumed exactly once, and a runner that answered
    /// twice would be a bug worth a crash rather than a hang.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(id: Int, outcome: PmsetOutcome), Never>?
        init(_ continuation: CheckedContinuation<(id: Int, outcome: PmsetOutcome), Never>) {
            self.continuation = continuation
        }
        func resume(_ identifier: Int, _ outcome: PmsetOutcome) {
            let waiting = lock.withLock { () -> CheckedContinuation<(id: Int, outcome: PmsetOutcome), Never>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: (identifier, outcome))
        }
    }

    private static let dump = """
        System-wide power settings:
        SleepDisabled\t\t1
        Currently in use:
         standby              1
         hibernatemode        3
        """

    // MARK: Reading the answer

    @Test("What pmset says about SleepDisabled")
    func parsing() {
        #expect(ProcessPmsetRunner.readSleepDisabled(from: Self.dump) == .read(1))
        #expect(ProcessPmsetRunner.readSleepDisabled(
            from: Self.dump.replacingOccurrences(of: "SleepDisabled\t\t1",
                                                 with: "SleepDisabled\t\t0")) == .read(0))
        // The line is absent until the setting has been turned on, and absent
        // is not unknown: a Mac nobody has ever disabled sleep on has sleep
        // enabled. Calling it unknown would leave the feature unavailable on
        // every Mac until the first time Ledge set it.
        #expect(ProcessPmsetRunner.readSleepDisabled(
            from: " standby 1\n hibernatemode 3\n") == .read(0))
        // Saying nothing at all is a different thing, and is not an answer.
        #expect(ProcessPmsetRunner.readSleepDisabled(from: "") == .failed("pmset said nothing"))
        #expect(ProcessPmsetRunner.readSleepDisabled(from: "   \n  ") == .failed("pmset said nothing"))
        if case .failed = ProcessPmsetRunner.readSleepDisabled(from: "SleepDisabled maybe") {} else {
            Issue.record("a value that is not a number is not a reading")
            return
        }
    }

    @Test("What pmset is asked")
    func arguments() {
        #expect(ProcessPmsetRunner.arguments(for: .readSleepDisabled) == ["-g"])
        #expect(ProcessPmsetRunner.arguments(for: .writeSleepDisabled(true))
                == ["-a", "disablesleep", "1"])
        #expect(ProcessPmsetRunner.arguments(for: .writeSleepDisabled(false))
                == ["-a", "disablesleep", "0"])
    }

    // MARK: Children

    @Test("A reading comes back under the operation it was asked for")
    func reads() async throws {
        let runner = ProcessPmsetRunner(tool: try tool("cat <<'END'\n\(Self.dump)\nEND"))
        let result = await answer(runner, .readSleepDisabled, opID: 41)
        #expect(result.id == 41)
        #expect(result.outcome == .read(1))
    }

    @Test("A write that the tool accepts is a write, and nothing more")
    func writes() async throws {
        let runner = ProcessPmsetRunner(tool: try tool("exit 0"))
        // `.wrote` says the command ran, not that the setting changed. The
        // core reads it back before it believes anything.
        #expect(await answer(runner, .writeSleepDisabled(true)).outcome == .wrote)
    }

    @Test("A tool that refuses says why")
    func refused() async throws {
        let runner = ProcessPmsetRunner(tool: try tool("echo 'not permitted' >&2\nexit 3"))
        guard case .failed(let message) = await answer(runner, .writeSleepDisabled(true)).outcome else {
            Issue.record("a non-zero exit is a failure")
            return
        }
        #expect(message.contains("3"))
        #expect(message.contains("not permitted"))
    }

    @Test("A tool that never finishes is ended and reported")
    func timesOut() async throws {
        // A long grace on purpose: if the gentle signal is what ends it, this
        // comes back at the limit. If only the kill works, it comes back two
        // seconds later and the measurement below says so.
        // `exec` so that the process we signal is the one that is sleeping:
        // a shell with a child would hand us a pid whose death tells us
        // nothing about the tool's.
        let runner = ProcessPmsetRunner(tool: try tool("exec sleep 30"),
                                        readLimit: 0.2, writeLimit: 0.2, killGrace: 2)
        let started = Date()
        guard case .failed(let message) = await answer(runner, .readSleepDisabled).outcome else {
            Issue.record("a tool that hangs is a failure, not an answer")
            return
        }
        #expect(message.contains("did not finish"))
        #expect(Date().timeIntervalSince(started) < 1, "it waited for the limit, not for the tool")
    }

    @Test("A child that will not finish is asked to stop, and then made to")
    func escalates() async {
        // Checked here rather than against a tool that ignores SIGTERM,
        // because nothing available to a test ignores it reliably: a shell
        // trap and a perl handler both die to it on this system, and a test
        // that cannot tell the two signals apart would pass with the second
        // one deleted. What matters is the policy — ask, wait, insist — and
        // that is what this is.
        let seen = Signals()
        _ = Escalation(limit: 0.05, grace: 0.1)
            .schedule(on: DispatchQueue(label: "escalation-test")) { seen.add($0) }

        try? await Task.sleep(for: .milliseconds(400))
        #expect(seen.all == [SIGTERM, SIGKILL])
    }

    @Test("A child that is reaped in time is not signalled at all")
    func escalationIsCancelled() async {
        let seen = Signals()
        let steps = Escalation(limit: 0.05, grace: 0.1)
            .schedule(on: DispatchQueue(label: "escalation-test")) { seen.add($0) }
        for step in steps { step.cancel() }

        try? await Task.sleep(for: .milliseconds(400))
        #expect(seen.all.isEmpty, "the child had already exited")
    }

    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var numbers: [Int32] = []
        func add(_ number: Int32) { lock.withLock { numbers.append(number) } }
        var all: [Int32] { lock.withLock { numbers } }
    }

    @Test("A tool that says far too much does not wedge the daemon")
    func floodOfOutput() async throws {
        // Both pipes are drained while the child runs. A child that filled one
        // and blocked writing to it would never exit, and the kill would be the
        // only thing that ever ended it. Reading has to continue past what is
        // kept, too: a reader that closed the pipe would send the child SIGPIPE
        // and turn "said too much" into "died of a signal".
        let runner = ProcessPmsetRunner(
            tool: try tool("echo 'SleepDisabled 1'\nhead -c 2000000 /dev/zero | tr '\\0' 'x'"),
            readLimit: 10, writeLimit: 10)
        #expect(await answer(runner, .readSleepDisabled).outcome == .read(1))
    }

    /// Comfortably above the handful a shell and `ls` open for themselves,
    /// and far below what a leak of the parent's descriptors would show.
    private let threshold = 10

    @Test("The child inherits nothing but the three descriptors it was given")
    func noDescriptorsLeak() async throws {
        // The one that matters is the claim store's lock. A copy of it in a
        // process the daemon is about to lose track of is a lock it can no
        // longer account for — and on macOS a flock lives as long as any
        // descriptor on that open file, so an orphan holding one would keep
        // the other daemon out for as long as it lived.
        var spare: [Int32] = []
        for _ in 0..<40 {
            let descriptor = open("/dev/null", O_RDONLY)
            if descriptor >= 0 { spare.append(descriptor) }
        }
        defer { for descriptor in spare { close(descriptor) } }
        // As many as this process can spare, not a round number of them.
        // Under the full suite the runner already holds a great many files
        // open, and demanding exactly forty made the test fail at its own
        // setup — reporting a descriptor leak that had not happened, for a
        // reason that had nothing to do with the child.
        try #require(spare.count > threshold,
                     "this process could not open enough descriptors for a leak to show")

        let runner = ProcessPmsetRunner(tool: try tool("""
            n=$(ls /dev/fd | wc -l)
            if [ "$n" -gt \(threshold) ]; then echo "SleepDisabled 1"; else echo "SleepDisabled 0"; fi
            """))
        #expect(await answer(runner, .readSleepDisabled).outcome == .read(0),
                "the child counted more open descriptors than it was handed")
    }

    @Test("The child is given an environment of our choosing, not ours")
    func environmentIsNotInherited() async throws {
        // A root daemon that passed its own environment on would be passing on
        // whatever was set for it, `DYLD_*` included, to a program it runs as
        // root.
        setenv("LEDGE_TEST_LEAKED", "1", 1)
        defer { unsetenv("LEDGE_TEST_LEAKED") }

        let runner = ProcessPmsetRunner(tool: try tool("""
            if [ -n "$LEDGE_TEST_LEAKED" ] || [ -z "$PATH" ]; then
                echo "SleepDisabled 1"
            else
                echo "SleepDisabled 0"
            fi
            """))
        #expect(await answer(runner, .readSleepDisabled).outcome == .read(0),
                "the child saw something it was not given")
    }

    @Test("A tool that cannot be run at all is a failure, not a crash")
    func missingTool() async {
        let runner = ProcessPmsetRunner(tool: "/nowhere/at/all/pmset")
        guard case .failed = await answer(runner, .readSleepDisabled).outcome else {
            Issue.record("there was nothing to run")
            return
        }
    }

    @Test("No test ever points the runner at the real tool")
    func testsNeverRunPmset() throws {
        // The reason `tool` is a required argument with no default. This Mac
        // belongs to somebody, and a test that disabled sleep on it would be
        // a test that changed the machine it was run on.
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)

        // Spelled in pieces so that this file does not trip its own check.
        let realTool = "/usr/bin/" + "pmset"
        let constant = "ProcessPmsetRunner" + ".pmset"
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains(realTool), "\(file.lastPathComponent)")
            #expect(!text.contains(constant), "\(file.lastPathComponent)")
        }
    }

    @Test("Operations run one after another, each answered under its own id")
    func severalInARow() async throws {
        let runner = ProcessPmsetRunner(tool: try tool("echo 'SleepDisabled 0'"))
        for identifier in [1, 2, 3] {
            #expect(await answer(runner, .readSleepDisabled, opID: identifier).id == identifier)
        }
    }
}

/// Reading Low Power Mode off `pmset -g custom`, which is two sections and a
/// Mac that may have only one of them.
///
/// Every sample here is real output from `pmset -g custom` on macOS 26.4,
/// trimmed or amended to produce the cases a single Mac cannot. Nothing in
/// this file runs `pmset`.
@Suite("Reading Low Power Mode")
struct LowPowerParsingTests {

    private let laptop = """
        Battery Power:
         Sleep On Power Button 1
         lowpowermode         0
         standby              1
         displaysleep         15
        AC Power:
         Sleep On Power Button 1
         lowpowermode         0
         standby              1
         displaysleep         20
        """

    private func read(_ output: String) -> PmsetOutcome {
        ProcessPmsetRunner.readLowPowerMode(from: output)
    }

    @Test("Both sources off is both sources off")
    func bothOff() {
        #expect(read(laptop) == .lowPower(LowPowerSetting(battery: false, charger: false)))
    }

    /// The case the whole per-source design exists for. System Settings calls
    /// it "Only on Battery" and people pick it.
    @Test("Only on Battery is read as what it is")
    func batteryOnly() {
        let output = laptop.replacingOccurrences(
            of: "Battery Power:\n Sleep On Power Button 1\n lowpowermode         0",
            with: "Battery Power:\n Sleep On Power Button 1\n lowpowermode         1"
        )
        #expect(read(output) == .lowPower(LowPowerSetting(battery: true, charger: false)))
    }

    @Test("Only on Power Adapter is read as what it is")
    func chargerOnly() {
        let output = laptop.replacingOccurrences(
            of: "AC Power:\n Sleep On Power Button 1\n lowpowermode         0",
            with: "AC Power:\n Sleep On Power Button 1\n lowpowermode         1"
        )
        #expect(read(output) == .lowPower(LowPowerSetting(battery: false, charger: true)))
    }

    /// A desktop prints one section. Absent is not off: off is something to
    /// put back, and absent is something that was never there and must never
    /// have `pmset -b` run at it.
    @Test("A Mac with no battery reports no battery, not a battery that is off")
    func desktop() {
        let output = """
            AC Power:
             Sleep On Power Button 1
             lowpowermode         0
             womp                 1
            """
        #expect(read(output) == .lowPower(LowPowerSetting(battery: nil, charger: false)))
    }

    /// `pmset` prints the settings that are in force, so a Mac where nobody
    /// has ever set this has no line for it. Calling that unknown would leave
    /// the daemon unable to act on any Mac until somebody set it by hand.
    @Test("A section with no lowpowermode line is off, not unknown")
    func missingLineIsOff() {
        let output = """
            Battery Power:
             displaysleep         15
            AC Power:
             lowpowermode         1
            """
        #expect(read(output) == .lowPower(LowPowerSetting(battery: false, charger: true)))
    }

    @Test("Nothing at all is a failure, never a reading")
    func silence() {
        guard case .failed = read("") else {
            Issue.record("silence was read as a value")
            return
        }
        guard case .failed = read("   \n  \n") else {
            Issue.record("whitespace was read as a value")
            return
        }
    }

    @Test("Output with no power source in it is a failure")
    func noSections() {
        guard case .failed = read("System-wide power settings:\n SleepDisabled 0") else {
            Issue.record("output naming no power source was read as a value")
            return
        }
    }

    /// Filing a value under a guess is how a laptop's battery setting gets
    /// written to its charger.
    @Test("A value before any section is a failure, not a guess")
    func valueWithNoSection() {
        guard case .failed = read(" lowpowermode         1\nAC Power:\n") else {
            Issue.record("a homeless value was filed under something")
            return
        }
    }

    @Test("A value that is not a number is a failure")
    func unreadableValue() {
        let output = "AC Power:\n lowpowermode         yes"
        guard case .failed = read(output) else {
            Issue.record("a non-numeric value was read as a reading")
            return
        }
    }

    /// Anything but 0 is on, the same rule `SleepDisabled` follows.
    @Test("Any non-zero value is on")
    func nonZeroIsOn() {
        #expect(read("AC Power:\n lowpowermode 2")
                == .lowPower(LowPowerSetting(battery: nil, charger: true)))
    }
}

@Suite("What each command runs")
struct PmsetArgumentTests {

    private func arguments(_ command: PmsetCommand) -> [String] {
        ProcessPmsetRunner.arguments(for: command)
    }

    @Test("Reading Low Power Mode asks for both sources, not the one in force")
    func readAsksForCustom() {
        #expect(arguments(.readLowPowerMode) == ["-g", "custom"])
    }

    @Test("Each power source has its own flag")
    func writeNamesItsSource() {
        #expect(arguments(.writeLowPowerMode(on: true, source: .all))
                == ["-a", "lowpowermode", "1"])
        #expect(arguments(.writeLowPowerMode(on: false, source: .battery))
                == ["-b", "lowpowermode", "0"])
        #expect(arguments(.writeLowPowerMode(on: true, source: .charger))
                == ["-c", "lowpowermode", "1"])
    }

    @Test("The sleep setting is untouched by any of it")
    func sleepIsUnchanged() {
        #expect(arguments(.readSleepDisabled) == ["-g"])
        #expect(arguments(.writeSleepDisabled(true)) == ["-a", "disablesleep", "1"])
        #expect(arguments(.writeSleepDisabled(false)) == ["-a", "disablesleep", "0"])
    }

    /// A read must never be given the write timeout, and a write must never be
    /// treated as a read of a setting it did not look at.
    @Test("Reads and writes are told apart, and so are the two settings")
    func classification() {
        #expect(!PmsetCommand.readLowPowerMode.isWrite)
        #expect(PmsetCommand.readLowPowerMode.isLowPower)
        #expect(PmsetCommand.writeLowPowerMode(on: true, source: .all).isWrite)
        #expect(PmsetCommand.writeLowPowerMode(on: true, source: .all).isLowPower)
        #expect(!PmsetCommand.readSleepDisabled.isWrite)
        #expect(!PmsetCommand.readSleepDisabled.isLowPower)
        #expect(PmsetCommand.writeSleepDisabled(true).isWrite)
        #expect(!PmsetCommand.writeSleepDisabled(true).isLowPower)
    }
}

/// Signalling a child that has already been collected.
///
/// A pid is the kernel's to reuse the instant `waitpid` takes it. This daemon
/// runs as root, so a `kill` aimed at a pid that has been reused is a SIGKILL
/// delivered to whatever the system started next, with root authority. The
/// window is two instructions wide and cannot be hit by chance, so the
/// syscalls are injected and a test holds one open at exactly the moment the
/// other would be unsafe.
@Suite("Reaping a child without killing its replacement")
struct ChildReapingTests {

    private typealias Child = ProcessPmsetRunner.Child

    /// Every `kill` that reached the "kernel", with whether the pid had been
    /// collected by then.
    private final class Kernel: @unchecked Sendable {
        private let lock = NSLock()
        private var collected = false
        private(set) var killsAfterCollection: [Int32] = []
        private(set) var kills: [Int32] = []
        /// Runs inside `waitpid`, at the instant the pid is handed back.
        var onCollect: (@Sendable () -> Void)?

        /// - Parameter exitsOnlyWhenSignalled: the child ignores end of file
        ///   and keeps running until something kills it, which is the case
        ///   the escalation exists for and the case a lock held across the
        ///   wait would deadlock.
        func syscalls(pid wanted: pid_t, exitsAfter attempts: Int = 0,
                      exitsOnlyWhenSignalled: Bool = false) -> Child.Syscalls {
            let counter = Counter()
            return Child.Syscalls(
                wait: { [self] pid, status, _ in
                    if exitsOnlyWhenSignalled, lock.withLock({ kills.isEmpty }) { return 0 }
                    guard pid == wanted, counter.next() >= attempts else { return 0 }
                    status.pointee = 0
                    // The pid goes back to the kernel here, and anything the
                    // test wants to happen at that instant happens here.
                    lock.withLock { collected = true }
                    onCollect?()
                    return wanted
                },
                kill: { [self] _, number in
                    lock.withLock {
                        kills.append(number)
                        if collected { killsAfterCollection.append(number) }
                    }
                    return 0
                },
                pause: { _ in }
            )
        }

        var killCount: Int { lock.withLock { kills.count } }
        var unsafeKills: [Int32] { lock.withLock { killsAfterCollection } }

        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int { lock.withLock { let n = count; count += 1; return n } }
        }
    }

    /// The interleaving itself: the escalation fires on another thread at the
    /// exact moment `waitpid` hands the pid back. The signal path and the
    /// collection share one lock, so the signal must find the child retired.
    @Test("A signal racing the collection never reaches the kernel")
    func signalRacingTheReapIsRefused() {
        let kernel = Kernel()
        // Held in a box rather than a captured `var`: the escalation really
        // does run on another thread, and a mutable capture crossing one is
        // the warning as well as the race.
        let held = Held()
        let signalled = Signal()
        kernel.onCollect = {
            // Another thread, as the escalation really is, started at the
            // instant the kernel takes the pid back so the race is run
            // rather than described.
            let thread = Thread {
                held.child?.signal(SIGKILL, timedOut: true)
                signalled.fire()
            }
            thread.start()
            // Long enough for it to reach the lock it must block on.
            Thread.sleep(forTimeInterval: 0.05)
        }
        let child = Child(pid: 4242, syscalls: kernel.syscalls(pid: 4242))
        held.child = child

        let outcome = child.reap()
        signalled.wait()

        #expect(outcome.status == 0)
        #expect(kernel.unsafeKills.isEmpty,
                "a pid the kernel had taken back was signalled with root authority")
        #expect(child.signalsSentAfterReaping == 1, "the race did not actually run")
    }

    @Test("A signal after the child is reaped is refused")
    func signalAfterReapIsRefused() {
        let kernel = Kernel()
        let child = Child(pid: 99, syscalls: kernel.syscalls(pid: 99))
        _ = child.reap()
        child.signal(SIGTERM, timedOut: true)
        child.signal(SIGKILL, timedOut: true)

        #expect(kernel.killCount == 0)
        #expect(child.signalsSentAfterReaping == 2)
    }

    /// The other half of the rule. A child that has stopped writing but has
    /// not exited is exactly when the escalation is needed, so the wait may
    /// not hold the lock the escalation takes.
    @Test("A child that has not exited can still be signalled")
    func escalationWorksWhileWaiting() {
        let kernel = Kernel()
        let held = Held()
        let signalled = Signal()
        // The child ignores end of file and runs until something kills it.
        // A reap that held its lock across the wait would never let that
        // something through, and this would hang rather than fail.
        let child = Child(pid: 7, syscalls: kernel.syscalls(pid: 7, exitsOnlyWhenSignalled: true))
        held.child = child

        let thread = Thread {
            Thread.sleep(forTimeInterval: 0.02)
            held.child?.signal(SIGTERM, timedOut: true)
            signalled.fire()
        }
        thread.start()
        let outcome = child.reap()
        signalled.wait()

        #expect(outcome.timedOut, "the signal that ended it was not recorded as a timeout")
        #expect(kernel.kills.contains(SIGTERM), "the escalation could not reach a live child")
        #expect(kernel.unsafeKills.isEmpty)
    }

    @Test("A child that was never there is retired rather than signalled")
    func noSuchChild() {
        let kernel = Kernel()
        let syscalls = Child.Syscalls(
            wait: { _, _, _ in errno = ECHILD; return -1 },
            kill: { _, number in _ = number; return 0 },
            pause: { _ in }
        )
        let child = Child(pid: 1234, syscalls: syscalls)
        _ = child.reap()
        child.signal(SIGKILL, timedOut: true)
        #expect(child.signalsSentAfterReaping == 1)
        #expect(kernel.killCount == 0)
    }

    /// Collected is not answered.
    ///
    /// If anything outside the runner takes the child — a process-wide
    /// reaper somewhere else in the same process is the realistic one —
    /// `waitpid` answers `ECHILD` and never touches the status buffer. The
    /// zero left in it is an absence, and reading it as an exit of zero
    /// reports a `pmset` write that failed as one that worked. The daemon
    /// then believes a setting it never set, which is the whole of what it
    /// is for.
    @Test("A child somebody else collected has no status to report")
    func collectedElsewhereHasNoStatus() {
        let syscalls = Child.Syscalls(
            wait: { _, status, _ in
                // Exactly what the kernel does: the buffer is left alone.
                _ = status
                errno = ECHILD
                return -1
            },
            kill: { _, _ in 0 },
            pause: { _ in }
        )
        let outcome = Child(pid: 1234, syscalls: syscalls).reap()
        #expect(outcome.collected, "a child nobody can wait for is not still ours")
        #expect(!outcome.known, "an untouched status buffer was read as an exit status")
    }

    @Test("A child this runner collected does report its status")
    func collectedHereHasAStatus() {
        let syscalls = Child.Syscalls(
            wait: { pid, status, _ in
                status.pointee = 17 << 8
                return pid
            },
            kill: { _, _ in 0 },
            pause: { _ in }
        )
        let outcome = Child(pid: 1234, syscalls: syscalls).reap()
        #expect(outcome.collected)
        #expect(outcome.known)
        #expect(outcome.status == 17)
    }

    @Test("The poll backs off rather than spinning")
    func backoffRises() {
        #expect(Child.pollBackoff == Child.pollBackoff.sorted())
        #expect(Child.pollBackoff.first ?? 0 > 0)
        #expect(Child.pollBackoff.last ?? 0 <= 20_000, "a slow poll delays the restore it owes")
    }

    /// Somewhere a child can live that another thread may read.
    private final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Child?
        var child: Child? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private final class Signal: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        func fire() { gate.signal() }
        func wait() { _ = gate.wait(timeout: .now() + 5) }
    }
}

/// A child that never exits, and never dies to its escalation either.
///
/// Found by mutation: making `signal` a no-op turned the reap into a loop with
/// no end, spinning the queue for the life of the daemon — and the queue has a
/// restore to get back to. The guard that makes it impossible in production is
/// real, but "impossible" is not a bound.
@Suite("A child that will not go")
struct ChildGivingUpTests {

    private typealias Child = ProcessPmsetRunner.Child

    /// Somewhere for a closure running on another thread to count.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var total: UInt64 = 0
        private var signals: [Int32] = []
        func add(_ amount: UInt64) { lock.withLock { total += amount } }
        func note(_ number: Int32) { lock.withLock { signals.append(number) } }
        var waited: UInt64 { lock.withLock { total } }
        var sent: [Int32] { lock.withLock { signals } }
    }

    @Test("The poll gives up rather than spinning for the life of the daemon")
    func givesUp() {
        let tally = Tally()
        let syscalls = Child.Syscalls(
            // Never exits, whatever is sent to it.
            wait: { _, _, _ in 0 },
            kill: { _, _ in 0 },
            pause: { tally.add(UInt64($0)) }
        )
        let child = Child(pid: 55, syscalls: syscalls)
        let outcome = child.reap()

        #expect(outcome.timedOut)
        #expect(outcome.status != 0, "giving up was reported as a clean exit")
        #expect(tally.waited >= Child.maximumWaitMicroseconds)
        #expect(tally.waited < Child.maximumWaitMicroseconds * 2,
                "it waited well past its own bound")
    }

    /// Nothing collected the pid, so the pid is still the child's and the
    /// escalation may still have it. Marking it reaped here would be the
    /// opposite mistake to the one this class was built to avoid.
    /// Giving up on the poll is not collection. Freeing the slot that stands
    /// for an uncollected child is how stuck children stopped being bounded:
    /// the pid is still ours, another operation is admitted, and repeating it
    /// bounds nothing.
    @Test("A child it gave up on is reported as not collected")
    func givingUpIsNotCollection() {
        let tally = Tally()
        let syscalls = Child.Syscalls(
            wait: { _, _, _ in 0 },          // never exits
            kill: { _, _ in 0 },
            pause: { tally.add(UInt64($0)) }
        )
        let outcome = Child(pid: 57, syscalls: syscalls).reap()
        #expect(!outcome.collected, "a child nobody collected was reported as collected")
        #expect(outcome.timedOut)
    }

    @Test("A child that is collected says so")
    func collectionSaysSo() {
        let syscalls = Child.Syscalls(
            wait: { pid, status, _ in status.pointee = 0; return pid },
            kill: { _, _ in 0 },
            pause: { _ in }
        )
        let outcome = Child(pid: 58, syscalls: syscalls).reap()
        #expect(outcome.collected)
        #expect(outcome.status == 0)
    }

    @Test("A child it gave up on is not marked reaped")
    func givingUpDoesNotRetireThePid() {
        let tally = Tally()
        let syscalls = Child.Syscalls(
            wait: { _, _, _ in 0 },
            kill: { _, number in tally.note(number); return 0 },
            pause: { _ in }
        )
        let child = Child(pid: 56, syscalls: syscalls)
        _ = child.reap()
        child.signal(SIGKILL, timedOut: true)

        #expect(tally.sent == [SIGKILL], "a pid nobody had collected was left unsignallable")
        #expect(child.signalsSentAfterReaping == 0)
    }
}

/// Counting clients by identity, not by callbacks.
///
/// An `NSXPCConnection` reports its end twice — interruption *and*
/// invalidation — and an interruption is not even necessarily its last word.
/// Counting each callback as a disconnection took two off the count for one
/// connection, so with two clients attached the daemon believed nobody was
/// there and could idle-exit out from under the one that was.
@Suite("How many clients are actually connected")
struct ConnectionTallyTests {

    @Test("Two terminal callbacks for one connection close it once")
    func closedOnlyOnce() {
        var tally = ConnectionTally()
        tally.opened(1)
        tally.opened(2)
        #expect(tally.live == 2)

        // Interruption, then invalidation, both for connection 1.
        let first = tally.closed(1)
        let second = tally.closed(1)
        #expect(first)
        #expect(!second, "the same connection closed twice")

        #expect(tally.live == 1, "a daemon with a client still attached believed it had none")
    }

    @Test("Each connection is closed by its own callback")
    func eachClosesItself() {
        var tally = ConnectionTally()
        tally.opened(1)
        tally.opened(2)
        tally.closed(2)
        #expect(tally.live == 1)
        tally.closed(1)
        #expect(tally.live == 0)
    }

    @Test("A callback for something that was never opened changes nothing")
    func unknownIdentity() {
        var tally = ConnectionTally()
        tally.opened(1)
        let answered = tally.closed(99)
        #expect(!answered)
        #expect(tally.live == 1)
    }
}

/// The one that cannot be proved from the budget alone: a child whose output
/// outlives it.
///
/// The runner waits for both drains to reach end of file, and end of file
/// arrives when the *last writer* closes — which is the child, or anything the
/// child handed the descriptor to. The tool below exits at once and leaves a
/// grandchild holding its stdout open, which is a shape a real `pmset` has no
/// business producing and a shape this runner must survive anyway: an
/// unbounded wait there held the queue that owes the restore for as long as
/// the grandchild lived.
@Suite("A child whose pipes outlive it", .serialized)
struct OrphanedPipeTests {

    /// Resumes exactly once, whatever the runner does.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PmsetOutcome, Never>?
        init(_ continuation: CheckedContinuation<PmsetOutcome, Never>) {
            self.continuation = continuation
        }
        func resume(_ outcome: PmsetOutcome) {
            let waiting: CheckedContinuation<PmsetOutcome, Never>? = lock.withLock {
                let held = continuation
                continuation = nil
                return held
            }
            waiting?.resume(returning: outcome)
        }
    }

    /// Every pid this suite's own runner was asked to collect.
    ///
    /// Cleanup takes exactly these and nothing else. A process-wide
    /// `waitpid(-1, …, WNOHANG)` drains any exited direct child of the whole
    /// test process, and other process-owning suites run alongside this one:
    /// taking another runner's child means that runner's own `waitpid` sees
    /// `ECHILD`, counts the pid collected with a raw status of zero, and
    /// reports a write that actually failed as `.wrote`. Cross-test ownership
    /// interference, and it makes a defective exit-status path look correct.
    final class WatchedPIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [pid_t] = []
        func note(_ pid: pid_t) {
            lock.withLock { if !seen.contains(pid) { seen.append(pid) } }
        }
        var all: [pid_t] { lock.withLock { seen } }

        /// Collects exactly the children this fixture made, waiting for each
        /// rather than taking one nonblocking look — a child that has not
        /// quite exited is left behind by a single attempt, and left behind
        /// is a zombie for the rest of the run.
        func collectAll(upTo seconds: TimeInterval = 10) {
            for pid in all {
                let deadline = Date().addingTimeInterval(seconds)
                var status: Int32 = 0
                while Date() < deadline {
                    let answer = waitpid(pid, &status, WNOHANG)
                    if answer == pid { break }
                    // No such child: somebody else has it, or it never
                    // existed. Either way there is nothing here to take.
                    if answer < 0 && errno != EINTR { break }
                    usleep(20_000)
                }
            }
        }
    }

    /// A collector that can be made to work partway through a test.
    ///
    /// Failed collection has to be injected — there is no benign way to wedge
    /// a process in the kernel — but the *recovery* is the thing under test,
    /// so the injection has to be able to stop. Once it does, the real
    /// `waitpid` runs against the real child.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var working = false
        let watched = WatchedPIDs()

        func startWorking() { lock.withLock { working = true } }
        private var isWorking: Bool { lock.withLock { working } }

        var syscalls: ProcessPmsetRunner.Child.Syscalls {
            ProcessPmsetRunner.Child.Syscalls(
                wait: { [self] pid, status, options in
                    watched.note(pid)
                    // Zero is "nothing to collect yet", which is what the
                    // bounded poll eventually gives up on.
                    guard isWorking else { return 0 }
                    return waitpid(pid, status, options)
                },
                kill: { _, _ in 0 },
                pause: { _ in }
            )
        }
    }

    private func tool(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-orphan-tool-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url.path
    }

    @Test("A grandchild holding the pipe open does not hold the queue for ever")
    func orphanedPipeIsBounded() async throws {
        // Exits immediately; the backgrounded subshell inherits stdout and
        // keeps it open far longer than any budget here.
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-orphan-\(UUID().uuidString)").path
        // Records its own pid *before* forking, so a run that never started
        // the fixture cannot be mistaken for a run that proved something.
        // The orphan holds the pipe for a minute. That number is the one the
        // assertion below is measured against: anything well short of it is
        // proof the runner stopped waiting on its own, and a generous gap is
        // what keeps this from failing on a loaded machine rather than on a
        // bug.
        let orphanHolds: TimeInterval = 60
        let path = try tool("echo $$ > \(marker)\n( sleep \(Int(orphanHolds)); echo late ) &\necho started\nexit 0")
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: marker)
        }

        // Room for the fixture to actually start under load: the escalation
        // sends SIGTERM at `readLimit`, and a shell killed before it has run
        // its first line leaves no orphan to test against.
        let runner = ProcessPmsetRunner(tool: path, readLimit: Self.fixtureLimit,
                                        writeLimit: Self.fixtureLimit, killGrace: 1)
        let started = Date()
        let outcome: PmsetOutcome = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            runner.report { _, outcome in once.resume(outcome) }
            runner.start(.readSleepDisabled, opID: 1)
        }
        let elapsed = Date().timeIntervalSince(started)

        // The fixture really started: it wrote its marker before forking. A
        // run where it never started proves nothing about pipes, and must not
        // be allowed to pass quietly.
        try await untilTrue(upTo: 20) { FileManager.default.fileExists(atPath: marker) }
        // Measured against what the orphan actually does, not a round number.
        // The budget here is about five seconds; twelve was meant as headroom
        // and turned out to be none under a full parallel suite, where this
        // failed at 12.9 s and reported a pipe bug that had not happened.
        #expect(elapsed < orphanHolds / 2,
                "the runner waited on a pipe nobody was going to close (\(elapsed)s)")
        guard case .failed(let reason) = outcome else {
            Issue.record("a child whose output never ended was reported as a reading")
            return
        }
        #expect(reason.contains("held its output open"),
                "the failure was something other than the pipe timeout: \(reason)")

        // And the child is still collected, on its own queue. An abandoned
        // exited child is a zombie, and one per failure accumulates.
        try await collected(marker: marker, upTo: 10)
    }

    /// What `ps` says about a pid.
    ///
    /// Three answers, not two. A marker that could not be read, or a `ps`
    /// that would not run, must never come back as the same answer as
    /// "collected" — a diagnostic that never worked would then look like
    /// proof the child had been reaped.
    enum ChildState: Equatable {
        case zombie
        case absent
        case alive(String)
        case unknown(String)
    }

    static func childState(marker: String) -> ChildState {
        guard let text = try? String(contentsOfFile: marker, encoding: .utf8) else {
            return .unknown("the fixture's marker could not be read")
        }
        return state(ofPID: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Read-only: it asks `ps` about one pid and nothing else.
    static func state(ofPID text: String) -> ChildState {
        guard let pid = Int32(text) else { return .unknown("not a pid: \(text)") }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "state=", "-p", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return .unknown("ps would not run") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let state = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if state.isEmpty { return .absent }
        return state.hasPrefix("Z") ? .zombie : .alive(state)
    }

    /// Waits for something to become true, and fails if it never does.
    private func untilTrue(upTo seconds: TimeInterval,
                           _ condition: @Sendable () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition())
    }

    /// Waits for `ps` to positively say the pid is gone.
    ///
    /// `.unknown` is not success and never passes: a diagnostic that could
    /// not establish anything must not read as proof.
    private func collected(marker: String, upTo seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        var last = Self.childState(marker: marker)
        while Date() < deadline, last != .absent {
            try await Task.sleep(for: .milliseconds(50))
            last = Self.childState(marker: marker)
        }
        #expect(last == .absent, "the child was never collected: \(last)")
    }

    /// Everything a stuck operation costs — a child, two blocking reads, two
    /// descriptors — is created *before* anything could have been refused. So
    /// the budget is taken before the spawn, and saturation refuses the work
    /// rather than abandoning something already made.
    @Test("Past its limit the runner creates nothing at all")
    func saturationRefusesBeforeSpawning() async throws {
        let fixture = try orphanFixture()
        defer { fixture.clean() }

        // Room for exactly one operation, and the first one keeps it: its
        // descendant holds the pipes long after the child is collected.
        let runner = ProcessPmsetRunner(tool: fixture.path, readLimit: Self.fixtureLimit,
                                        writeLimit: Self.fixtureLimit,
                                        killGrace: 1, outstandingLimit: 1)
        let held = await answerOnce(runner)
        guard case .failed(let reason) = held, reason.contains("held its output open") else {
            Issue.record("the fixture did not reach the pipe timeout: \(held)")
            return
        }
        try await untilTrue(upTo: 5) { fixture.recordedPIDs.count == 1 }

        // A second operation on the same runner, while that budget is still
        // out. It must not start a child at all.
        let refused = await answerOnce(runner)
        guard case .failed(let why) = refused else {
            Issue.record("a saturated runner started work anyway: \(refused)")
            return
        }
        #expect(why.contains("already outstanding"),
                "the refusal came from the pipe timeout, so a child was spawned: \(why)")
        #expect(fixture.recordedPIDs.count == 1,
                "a saturated runner spawned a second child anyway")

        // And the first one is still collected, as it always was.
        for pid in fixture.recordedPIDs {
            try await untilTrue(upTo: 10) { Self.state(ofPID: pid) == .absent }
        }
    }

    /// One runner, two stuck operations, and **neither descendant released**
    /// until both children have been collected.
    ///
    /// A fixed sleep could not establish this: the first descendant can exit
    /// on its own before the second collector is needed, so a collector
    /// blocked on the first one's end of file looks exactly like a working
    /// one. Holding both pipes open across both collections is the condition.
    @Test("Both children are collected while both pipes are still held open")
    func bothChildrenCollectedWithPipesHeld() async throws {
        let fixture = try orphanFixture()
        defer { fixture.clean() }

        let runner = ProcessPmsetRunner(tool: fixture.path, readLimit: Self.fixtureLimit,
                                        writeLimit: Self.fixtureLimit,
                                        killGrace: 1, outstandingLimit: 8)
        for _ in 0..<2 {
            let outcome = await answerOnce(runner)
            guard case .failed(let reason) = outcome, reason.contains("held its output open") else {
                Issue.record("the fixture did not reach the pipe timeout: \(outcome)")
                return
            }
        }

        try await untilTrue(upTo: 5) { fixture.recordedPIDs.count == 2 }
        let pids = fixture.recordedPIDs
        #expect(pids.count == 2, "two operations did not produce two children: \(pids)")

        // Both collected — and neither holder has been let go, so a collector
        // that waited for end of file could not have reached the second.
        for pid in pids {
            try await untilTrue(upTo: 10) { Self.state(ofPID: pid) == .absent }
            #expect(Self.state(ofPID: pid) == .absent,
                    "a child was not collected while its pipe was still held")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.release),
                "the test released a holder before proving anything")
    }

    /// A child that exits, closes its pipes, and still cannot be collected.
    ///
    /// Giving up on the poll is not collection: the pid is still this child's.
    /// Freeing the slot that stands for it is how stuck children stopped being
    /// bounded — another operation is admitted, and repeating it bounds
    /// nothing. There is no benign way to produce an uncollectable process, so
    /// the collection syscall is injected and the real child is reaped by the
    /// test afterwards.
    @Test("A child that could not be collected keeps its slot")
    func uncollectableChildKeepsItsSlot() async throws {
        let path = try tool("echo started\nexit 0")
        let collector = Collector()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            // Exactly the children this fixture made. See `WatchedPIDs`.
            collector.watched.collectAll()
        }

        let runner = ProcessPmsetRunner(tool: path, readLimit: 2, writeLimit: 2,
                                        killGrace: 1, outstandingLimit: 1,
                                        salvageInterval: 3600,
                                        syscalls: collector.syscalls)

        let first = await answerOnce(runner)
        guard case .failed = first else {
            Issue.record("a child that could not be collected was reported as a reading: \(first)")
            return
        }
        #expect(runner.unsalvagedCount == 1,
                "nothing owns the child the collector could not take")

        // The slot is still taken, so the runner starts nothing else.
        let second = await answerOnce(runner)
        guard case .failed(let why) = second else {
            Issue.record("a runner holding an uncollected child started more work: \(second)")
            return
        }
        #expect(why.contains("already outstanding"),
                "the slot of a child nobody collected was handed back: \(why)")
    }

    /// And the half that was missing: the obstruction clears.
    ///
    /// Retaining the slot while a child cannot be collected is right. Keeping
    /// it for ever is not, and that is what the decremented counter alone
    /// did: the `Child` was dropped, so nothing ever asked again. Eight
    /// transient failures and the runner was empty for the life of the
    /// helper — a root daemon owing a sleep or Low Power Mode restore, unable
    /// to start the work that would discharge it, long after every child had
    /// exited and could have been collected. A bounded refusal turned into a
    /// stuck Mac.
    @Test("A slot comes back once the child can be collected")
    func collectableAgainReturnsTheSlot() async throws {
        let path = try tool("echo started\nexit 0")
        let collector = Collector()
        defer {
            collector.watched.collectAll()
            try? FileManager.default.removeItem(atPath: path)
        }

        // The timer is pushed out of the way: every sweep in this test is one
        // the test asked for, so what is being shown is the sweep's decision
        // and not a race with a background one.
        let runner = ProcessPmsetRunner(tool: path, readLimit: 2, writeLimit: 2,
                                        killGrace: 1, outstandingLimit: 1,
                                        salvageInterval: 3600,
                                        syscalls: collector.syscalls)

        guard case .failed = await answerOnce(runner) else {
            Issue.record("a child that could not be collected was reported as a reading")
            return
        }
        #expect(runner.unsalvagedCount == 1)
        let pids = collector.watched.all
        #expect(pids.count == 1, "the fixture did not make exactly one child: \(pids)")

        // Nothing has changed yet, so a sweep must find nothing and the slot
        // must stay out. Collection being *possible* is the only thing that
        // may return it.
        #expect(runner.salvageNow() == 0, "a slot came back for a child still uncollectable")
        guard case .failed(let why) = await answerOnce(runner), why.contains("already outstanding")
        else {
            Issue.record("a runner holding an uncollected child started more work")
            return
        }

        // The obstruction clears.
        collector.startWorking()
        #expect(runner.salvageNow() == 1, "collection became possible and nothing noticed")
        #expect(runner.unsalvagedCount == 0, "a collected child was still held outstanding")

        // And the capacity is genuinely back: the next operation runs.
        let after = await answerOnce(runner)
        if case .failed(let reason) = after, reason.contains("already outstanding") {
            Issue.record("the slot never came back after the child was collected")
        }
        // The child really was collected by the runner, not left for cleanup.
        for pid in pids {
            #expect(Self.state(ofPID: "\(pid)") == .absent,
                    "the salvaged child is still a zombie")
        }
    }

    /// The same rule on the other path: a child whose pipes outlived it and
    /// which then could not be collected either. The slot is handed to the
    /// collector, and the collector must not give it back for a child it did
    /// not take.
    @Test("An abandoned child that could not be collected keeps its slot")
    func uncollectableAbandonedChildKeepsItsSlot() async throws {
        let fixture = try orphanFixture()
        let collector = Collector()
        defer {
            fixture.clean()
            collector.watched.collectAll()
        }

        let runner = ProcessPmsetRunner(tool: fixture.path, readLimit: Self.fixtureLimit,
                                        writeLimit: Self.fixtureLimit,
                                        killGrace: 1, outstandingLimit: 1,
                                        salvageInterval: 3600,
                                        syscalls: collector.syscalls)

        let first = await answerOnce(runner)
        guard case .failed(let reason) = first, reason.contains("held its output open") else {
            Issue.record("the fixture did not reach the pipe timeout: \(first)")
            return
        }
        try await untilTrue(upTo: 5) { fixture.recordedPIDs.count == 1 }

        // Let the descendant go, so the drains finish and the collector
        // reaches its decision. Without this the unbounded wait on end of
        // file would be what held the slot, and the decision itself would
        // never be the thing under test.
        fixture.releaseHolder()
        // A positive barrier on that decision, not an interval: the slot is
        // only on the registry once the collector has actually failed to take
        // the child, and a loaded machine can take as long as it likes to get
        // there. A fixed sleep turns "the collector has not run yet" into
        // "retention works".
        try await untilTrue(upTo: 20) { runner.unsalvagedCount == 1 }

        // The collector could not take the child, so the slot is still out.
        let second = await answerOnce(runner)
        guard case .failed(let why) = second else {
            Issue.record("a runner holding an uncollected child started more work: \(second)")
            return
        }
        #expect(why.contains("already outstanding"),
                "an abandoned child nobody collected had its slot handed back: \(why)")
        #expect(fixture.recordedPIDs.count == 1, "a second child was spawned anyway")
    }

    /// The abandoned path's recovery, where the permit stands for two things
    /// at once: the child *and* the descriptors something else still holds.
    /// It comes back only when both are done — collection established, drains
    /// finished — and it does come back.
    @Test("An abandoned child's slot comes back once it can be collected")
    func abandonedSlotComesBack() async throws {
        let fixture = try orphanFixture()
        let collector = Collector()
        defer {
            fixture.clean()
            collector.watched.collectAll()
        }

        let runner = ProcessPmsetRunner(tool: fixture.path, readLimit: Self.fixtureLimit,
                                        writeLimit: Self.fixtureLimit,
                                        killGrace: 1, outstandingLimit: 1,
                                        salvageInterval: 3600,
                                        syscalls: collector.syscalls)

        guard case .failed(let reason) = await answerOnce(runner),
              reason.contains("held its output open")
        else {
            Issue.record("the fixture did not reach the pipe timeout")
            return
        }
        try await untilTrue(upTo: 5) { fixture.recordedPIDs.count == 1 }
        try await untilTrue(upTo: 20) { runner.unsalvagedCount == 1 }

        // Still stuck: a sweep now must change nothing.
        #expect(runner.salvageNow() == 0, "a slot came back for a child still uncollectable")

        // The obstruction clears — but the pipe is still held, so the
        // descriptors the permit also stands for are still out.
        collector.startWorking()
        #expect(runner.salvageNow() == 1, "collection became possible and nothing noticed")
        #expect(runner.unsalvagedCount == 0)
        #expect(runner.availableSlots == 0,
                "the slot came back while a reader still held its descriptors")

        // And now the pipe goes too. The permit stands for the child *and*
        // the drains, and comes back when both are finished — which is why
        // the budget is held past collection and not merely until it.
        fixture.releaseHolder()
        try await untilTrue(upTo: 20) { runner.availableSlots == 1 }

        // And the capacity is real: the next operation starts a child.
        let before = fixture.recordedPIDs.count
        let after = await answerOnce(runner)
        if case .failed(let why) = after, why.contains("already outstanding") {
            Issue.record("the slot never came back after the child was collected")
        }
        #expect(fixture.recordedPIDs.count > before,
                "the runner reported capacity it would not actually use")
    }

    /// `collect()` is the registry's question, and it has to answer the same
    /// ownership rule `reap` does: `ECHILD` means somebody else has the
    /// child, so it is no longer ours and the slot it stands for is free.
    /// Treating that as "still outstanding" keeps a permit for a child that
    /// no longer exists, which is the finding in a different disguise.
    @Test("A child nothing can wait for is not still outstanding")
    func collectTreatsNoSuchChildAsDone() {
        let gone = ProcessPmsetRunner.Child.Syscalls(
            wait: { _, _, _ in errno = ECHILD; return -1 },
            kill: { _, _ in 0 },
            pause: { _ in }
        )
        #expect(ProcessPmsetRunner.Child(pid: 999_999, syscalls: gone).collect(),
                "a pid nothing can wait for was counted as still ours")

        let waiting = ProcessPmsetRunner.Child.Syscalls(
            wait: { _, _, _ in 0 },
            kill: { _, _ in 0 },
            pause: { _ in }
        )
        #expect(!ProcessPmsetRunner.Child(pid: 999_999, syscalls: waiting).collect(),
                "a child that has not exited was written off as collected")
    }

    /// The write path's half of the same distinction. Something outside the
    /// runner takes the child; `waitpid` answers `ECHILD` and leaves the
    /// status buffer alone. Reporting that zero as an exit of zero tells the
    /// daemon a `pmset` write succeeded when nothing is known about it — and
    /// the daemon's whole job is knowing whether the setting is in force.
    @Test("A write whose child was collected elsewhere is not a successful write")
    func writeWithNoStatusIsNotSuccess() async throws {
        let path = try tool("exit 17")
        let watched = WatchedPIDs()
        defer {
            watched.collectAll()
            try? FileManager.default.removeItem(atPath: path)
        }

        let syscalls = ProcessPmsetRunner.Child.Syscalls(
            wait: { pid, _, _ in
                watched.note(pid)
                // Exactly the kernel's behaviour: the buffer is untouched.
                errno = ECHILD
                return -1
            },
            kill: { _, _ in 0 },
            pause: { _ in }
        )
        let runner = ProcessPmsetRunner(tool: path, readLimit: 2, writeLimit: 2,
                                        killGrace: 1, outstandingLimit: 2,
                                        salvageInterval: 3600, syscalls: syscalls)

        let outcome: PmsetOutcome = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            runner.report { _, outcome in once.resume(outcome) }
            runner.start(.writeSleepDisabled(true), opID: 1)
        }
        guard case .failed(let why) = outcome else {
            Issue.record("a write with no status to read was reported as done: \(outcome)")
            return
        }
        #expect(why.contains("exit status could not be established"),
                "the failure was something other than the missing status: \(why)")
    }

    /// Nothing in the other tests runs the registry's own timer — they ask
    /// for a sweep so the decision can be pinned to a moment. So one test
    /// asks for nothing at all, and waits for capacity to come back on its
    /// own, because a registry nobody ever polls reclaims nothing.
    @Test("The registry retries on its own, without being asked")
    func salvageRunsOnItsOwnTimer() async throws {
        let path = try tool("echo started\nexit 0")
        let collector = Collector()
        defer {
            collector.watched.collectAll()
            try? FileManager.default.removeItem(atPath: path)
        }

        let runner = ProcessPmsetRunner(tool: path, readLimit: 2, writeLimit: 2,
                                        killGrace: 1, outstandingLimit: 1,
                                        salvageInterval: 0.2,
                                        syscalls: collector.syscalls)

        guard case .failed = await answerOnce(runner) else {
            Issue.record("a child that could not be collected was reported as a reading")
            return
        }
        try await untilTrue(upTo: 10) { runner.unsalvagedCount == 1 }
        #expect(runner.availableSlots == 0)

        collector.startWorking()
        try await untilTrue(upTo: 20) { runner.availableSlots == 1 }
        #expect(runner.unsalvagedCount == 0, "the timer freed a slot it had not collected")
    }

    /// A fixture whose descendants hold their pipes until the *test* lets go,
    /// and which records one marker per invocation so one script can serve one
    /// runner across several operations.
    private struct Fixture {
        let path: String
        let markers: String
        let holders: String
        let release: String

        var recordedPIDs: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: markers)) ?? []).sorted()
        }

        /// The descendants that hold the pipes open. Not our children — they
        /// belong to the shells that forked them — so they are watched, never
        /// collected.
        var holderPIDs: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: holders)) ?? []).sorted()
        }

        func releaseHolder() { FileManager.default.createFile(atPath: release, contents: nil) }

        func clean() {
            releaseHolder()
            // The signal stays until the holders have acknowledged it by
            // leaving. Created and deleted in the same breath, it could fall
            // between two of a descendant's polls, and the descendant then
            // lingered to its own safety timeout with the descriptors still
            // open — which is a fixture quietly holding resources for the
            // tests that run after it.
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let left = holderPIDs.filter {
                    OrphanedPipeTests.state(ofPID: $0) != .absent
                }
                if left.isEmpty { break }
                usleep(50_000)
            }
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: markers)
            try? FileManager.default.removeItem(atPath: holders)
            try? FileManager.default.removeItem(atPath: release)
        }
    }

    /// Room for the fixture to actually start under load.
    ///
    /// The escalation sends SIGTERM at the limit, and a shell killed before
    /// it has run its first line leaves no orphan at all — so the operation
    /// fails with a plain timeout rather than the pipe timeout, and a test
    /// that needed an orphan has nothing to say. Two seconds was enough in
    /// isolation and not beside a full parallel suite; three was not enough
    /// either once this suite grew. The number is headroom for process
    /// startup, not a property anything here is measuring.
    private static let fixtureLimit: TimeInterval = 5

    private func orphanFixture() throws -> Fixture {
        let token = UUID().uuidString
        let markers = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-orphans-\(token)").path
        try FileManager.default.createDirectory(atPath: markers,
                                                withIntermediateDirectories: true)
        let holders = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-holders-\(token)").path
        try FileManager.default.createDirectory(atPath: holders,
                                                withIntermediateDirectories: true)
        let release = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-release-\(token)").path
        // Bounded at thirty seconds so a test that dies cannot leave it.
        let holder = "( i=0; while [ ! -f \(release) ] && [ $i -lt 150 ]; "
            + "do sleep 0.2; i=$((i+1)); done; echo late ) &"
        // The holder's own pid, recorded by its parent, so cleanup can watch
        // for it actually going rather than assume it did.
        let path = try tool(": > \(markers)/$$\n\(holder)\n: > \(holders)/$!"
                            + "\necho started\nexit 0")
        return Fixture(path: path, markers: markers, holders: holders, release: release)
    }

    // MARK: - A failed reply is not a stopped writer

    /// Capacity was only ever half of what the registry owed.
    ///
    /// The other half is identity. Somebody asked for this write, was told it
    /// failed while the child was still alive, and acted on that answer — the
    /// watchdog retired its stage, the core finished its transaction. When
    /// the child finally stops, having landed a privileged write, the thing
    /// that asked has to be told which of its writes it was. Returning the
    /// slot and saying nothing left a newer hold believing a reading this
    /// writer had just invalidated.
    @Test("A salvaged write says which operation it was")
    func salvagedWriteNamesItsOperation() async throws {
        let path = try tool("echo started\nexit 0")
        let collector = Collector()
        let settled = Settlements()
        defer {
            collector.watched.collectAll()
            try? FileManager.default.removeItem(atPath: path)
        }

        let runner = ProcessPmsetRunner(tool: path, readLimit: 2, writeLimit: 2,
                                        killGrace: 1, outstandingLimit: 2,
                                        salvageInterval: 3600,
                                        syscalls: collector.syscalls)
        runner.reportSettled { opID, command in settled.add(opID, command) }

        let outcome: PmsetOutcome = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            runner.report { _, outcome in once.resume(outcome) }
            runner.start(.writeSleepDisabled(false), opID: 77)
        }
        guard case .failed = outcome else {
            Issue.record("a child that could not be collected was reported as done: \(outcome)")
            return
        }
        #expect(settled.all.isEmpty, "a writer still alive was reported as finished")

        collector.startWorking()
        #expect(runner.salvageNow() == 1)
        #expect(settled.all.map(\.opID) == [77],
                "the finish was reported without the identity of what finished: \(settled.all)")
        #expect(settled.all.first?.command.isWrite == true)
    }

    /// A read changes nothing, however late it is. Telling the core to throw
    /// away its cached state over one would be a `pmset` spawned for nothing
    /// on every stuck child.
    @Test("A salvaged read reports nothing")
    func salvagedReadIsNotNews() async throws {
        let path = try tool("echo started\nexit 0")
        let collector = Collector()
        let settled = Settlements()
        defer {
            collector.watched.collectAll()
            try? FileManager.default.removeItem(atPath: path)
        }

        let runner = ProcessPmsetRunner(tool: path, readLimit: 2, writeLimit: 2,
                                        killGrace: 1, outstandingLimit: 2,
                                        salvageInterval: 3600,
                                        syscalls: collector.syscalls)
        runner.reportSettled { opID, command in settled.add(opID, command) }
        _ = await answerOnce(runner)

        collector.startWorking()
        #expect(runner.salvageNow() == 1, "the fixture never registered a stuck child")
        #expect(settled.all.isEmpty, "a read was reported as a write that had landed")
    }

    /// The branch that never reaches the registry: a child whose pipes
    /// outlived its operation and which the collector then *does* take. The
    /// operation was answered the moment the pipes timed out, with the child
    /// still running, and its write has only now finished.
    @Test("An abandoned child that is collected later still reports its write")
    func abandonedCollectionReportsTheWrite() async throws {
        let fixture = try orphanFixture()
        let settled = Settlements()
        defer { fixture.clean() }

        let runner = ProcessPmsetRunner(tool: fixture.path, readLimit: Self.fixtureLimit,
                                        writeLimit: Self.fixtureLimit,
                                        killGrace: 1, outstandingLimit: 2,
                                        salvageInterval: 3600)
        runner.reportSettled { opID, command in settled.add(opID, command) }

        let outcome: PmsetOutcome = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            runner.report { _, outcome in once.resume(outcome) }
            runner.start(.writeSleepDisabled(false), opID: 31)
        }
        guard case .failed(let reason) = outcome, reason.contains("held its output open") else {
            Issue.record("the fixture did not reach the pipe timeout: \(outcome)")
            return
        }

        try await untilTrue(upTo: 20) { settled.all.map(\.opID) == [31] }
        #expect(settled.all.map(\.opID) == [31],
                "a child collected after its operation was answered reported nothing")
    }

    /// The window has to open *before* the failure that opens it.
    ///
    /// Everything downstream decides on the reply: the watchdog retires its
    /// stage, the core finishes its transaction and may go on to read the
    /// setting and throw away the claim. If the warning arrives after the
    /// answer, there is a moment where a perfectly fresh reading looks like
    /// permission to destroy the only record of what Ledge changed.
    @Test("A writer that can still act is announced before its failure is")
    func liveWriterIsAnnouncedBeforeTheReply() async throws {
        let path = try tool("echo started\nexit 0")
        let collector = Collector()
        let order = Ordering()
        defer {
            collector.watched.collectAll()
            try? FileManager.default.removeItem(atPath: path)
        }

        let runner = ProcessPmsetRunner(tool: path, readLimit: 2, writeLimit: 2,
                                        killGrace: 1, outstandingLimit: 2,
                                        salvageInterval: 3600,
                                        syscalls: collector.syscalls)
        runner.reportUnsettled { opID, _ in order.add("live \(opID)") }

        let outcome: PmsetOutcome = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            runner.report { opID, outcome in
                order.add("reply \(opID)")
                once.resume(outcome)
            }
            runner.start(.writeSleepDisabled(false), opID: 77)
        }
        guard case .failed = outcome else {
            Issue.record("the fixture did not reach the uncollectable branch: \(outcome)")
            return
        }
        #expect(order.all == ["live 77", "reply 77"],
                "the warning did not come before the answer: \(order.all)")
    }

    /// And the other path, where the child's pipes outlive its operation.
    @Test("An abandoned child's writer is announced before its failure is")
    func abandonedWriterIsAnnouncedBeforeTheReply() async throws {
        let fixture = try orphanFixture()
        let order = Ordering()
        defer { fixture.clean() }

        let runner = ProcessPmsetRunner(tool: fixture.path, readLimit: Self.fixtureLimit,
                                        writeLimit: Self.fixtureLimit,
                                        killGrace: 1, outstandingLimit: 2,
                                        salvageInterval: 3600)
        runner.reportUnsettled { opID, _ in order.add("live \(opID)") }

        let outcome: PmsetOutcome = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            runner.report { opID, outcome in
                order.add("reply \(opID)")
                once.resume(outcome)
            }
            runner.start(.writeSleepDisabled(false), opID: 31)
        }
        guard case .failed(let reason) = outcome, reason.contains("held its output open") else {
            Issue.record("the fixture did not reach the pipe timeout: \(outcome)")
            return
        }
        #expect(order.all == ["live 31", "reply 31"],
                "the warning did not come before the answer: \(order.all)")
    }

    /// A read can be as late as it likes; it changes nothing.
    @Test("A read is never announced as a writer that can still act")
    func readsAreNotLiveWriters() async throws {
        let path = try tool("echo started\nexit 0")
        let collector = Collector()
        let order = Ordering()
        defer {
            collector.watched.collectAll()
            try? FileManager.default.removeItem(atPath: path)
        }

        let runner = ProcessPmsetRunner(tool: path, readLimit: 2, writeLimit: 2,
                                        killGrace: 1, outstandingLimit: 2,
                                        salvageInterval: 3600,
                                        syscalls: collector.syscalls)
        runner.reportUnsettled { opID, _ in order.add("live \(opID)") }
        _ = await answerOnce(runner)

        #expect(order.all.isEmpty, "a read was announced as a writer: \(order.all)")
    }

    /// Registration and settlement travel on different queues, so the order
    /// has to be established at the source rather than hoped for.
    ///
    /// The child used to become visible to salvage *before* the runner
    /// announced it, so a sweep could collect it and report settlement in
    /// between — the core heard that a writer had finished and then that it
    /// had started, and held an obligation for ever over nothing.
    ///
    /// Held inside the announcement, with a sweep running against it from
    /// another thread: if the child were visible to salvage first, that sweep
    /// would collect it and settle it before this returns.
    @Test("Salvage cannot see a child before its writer has been announced")
    func salvageCannotOvertakeTheAnnouncement() async throws {
        let path = try tool("echo started\nexit 0")
        let collector = Collector()
        let order = Ordering()
        let inside = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer {
            collector.watched.collectAll()
            try? FileManager.default.removeItem(atPath: path)
        }

        let runner = ProcessPmsetRunner(tool: path, readLimit: 2, writeLimit: 2,
                                        killGrace: 1, outstandingLimit: 2,
                                        salvageInterval: 3600,
                                        syscalls: collector.syscalls)
        let swept = Counted()
        runner.reportUnsettled { opID, _ in
            order.add("live \(opID)")
            // Collection becomes possible while this is still in flight, and
            // a sweep runs. It must find nothing to take.
            collector.startWorking()
            inside.signal()
            release.wait()
        }
        runner.reportSettled { opID, _ in order.add("settled \(opID)") }

        let sweeper = Thread {
            inside.wait()
            swept.set(runner.salvageNow())
            release.signal()
        }
        sweeper.start()

        let outcome: PmsetOutcome = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            runner.report { opID, outcome in
                order.add("reply \(opID)")
                once.resume(outcome)
            }
            runner.start(.writeSleepDisabled(false), opID: 55)
        }
        guard case .failed = outcome else {
            Issue.record("the fixture did not reach the uncollectable branch: \(outcome)")
            return
        }

        #expect(swept.value == 0,
                "salvage collected a child whose writer had not been announced yet")
        #expect(order.all.first == "live 55",
                "something reached the core before the announcement: \(order.all)")
        #expect(!order.all.contains("settled 55") || order.all.firstIndex(of: "settled 55")!
                > order.all.firstIndex(of: "live 55")!,
                "settlement was reported before registration: \(order.all)")

        // And the child is still salvageable afterwards, so nothing was lost
        // by making it wait.
        #expect(runner.salvageNow() == 1, "the child never became collectable")
        #expect(order.all.contains("settled 55"))
    }

    /// One number, written by one thread and read by another.
    final class Counted: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = -1
        func set(_ value: Int) { lock.withLock { stored = value } }
        var value: Int { lock.withLock { stored } }
    }

    /// What happened, in the order it happened.
    final class Ordering: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ what: String) { lock.withLock { seen.append(what) } }
        var all: [String] { lock.withLock { seen } }
    }

    /// Everything the settlement channel was told, for a test that has to
    /// show both that it fired and what it carried.
    final class Settlements: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(opID: Int, command: PmsetCommand)] = []
        func add(_ opID: Int, _ command: PmsetCommand) {
            lock.withLock { seen.append((opID, command)) }
        }
        var all: [(opID: Int, command: PmsetCommand)] { lock.withLock { seen } }
    }

    private func answerOnce(_ runner: ProcessPmsetRunner) async -> PmsetOutcome {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            runner.report { _, outcome in once.resume(outcome) }
            runner.start(.readSleepDisabled, opID: 1)
        }
    }
}

/// The reap budget only bounds the child if everything upstream of it does.
///
/// The runner waits for both output drains to reach end of file before it
/// reaps, and end of file arrives when the last writer closes — which is the
/// child, *or* anything the child handed the descriptor to. An unbounded wait
/// there meant the bounded reap below it was never reached, and the queue that
/// owes the restore was held for ever.
@Suite("Bounding the whole child, not just the reap")
struct DrainBudgetTests {

    @Test("The drains are given until after the escalation has finished")
    func budgetOutlastsTheEscalation() {
        let limit: TimeInterval = 10
        let grace: TimeInterval = 2
        let budget = ProcessPmsetRunner.drainBudget(after: limit, grace: grace)

        // SIGTERM lands at `limit`, SIGKILL at `limit + grace`. A budget that
        // expired before then would give up on a child the escalation was
        // about to end anyway.
        #expect(budget > limit + grace, "the drains gave up before the kill had landed")
        // And not so far past it that the queue is held for minutes.
        #expect(budget <= limit + grace + 5)
    }

    @Test("A read is given the same shape of budget as a write")
    func bothKindsBounded() {
        #expect(ProcessPmsetRunner.drainBudget(after: 5, grace: 2) > 7)
        #expect(ProcessPmsetRunner.drainBudget(after: 10, grace: 2) >
                ProcessPmsetRunner.drainBudget(after: 5, grace: 2))
    }
}
/// How many abandoned children may be outstanding at once.
///
/// Each one costs a collector and two descriptors nobody can close, so the
/// number has to be a number rather than "as many as happen".
@Suite("Permits for work nobody can finish")
struct PermitsTests {

    @Test("Permits run out, and come back")
    func permitsAreFinite() {
        let permits = ProcessPmsetRunner.Permits(2)
        #expect(permits.take())
        #expect(permits.take())
        #expect(!permits.take(), "an unbounded number of abandoned children was allowed")
        permits.give()
        #expect(permits.take())
    }

    @Test("A permit count of nothing allows nothing")
    func zeroPermits() {
        #expect(!ProcessPmsetRunner.Permits(0).take())
    }
}
