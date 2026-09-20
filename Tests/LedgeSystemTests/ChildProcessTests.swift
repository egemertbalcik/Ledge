import Foundation
import Testing
import os

@testable import LedgeSystem

/// A child must end, even when it does not want to.
@Suite("Child process", .serialized)
struct ChildProcessTests {

    /// Traps SIGTERM and keeps going. This is the case a single `terminate()`
    /// cannot handle, and the one that could wedge the single-flight gate.
    private static let ignoresSigterm = "trap '' TERM; sleep 60"

    /// A child that traps SIGTERM and then *says so* by creating a file.
    ///
    /// Waiting for that marker is what makes the escalation test deterministic:
    /// signalling before the shell has installed its trap kills it with plain
    /// SIGTERM, which proves nothing about escalation. Under a parallel suite
    /// that is exactly what happened — status 15 instead of 9 — because `sh`
    /// took longer to start than the deadline allowed.
    private static func trapScript(marker: String) -> String {
        "trap '' TERM; : > '\(marker)'; sleep 60"
    }

    private static func waitForMarker(_ path: String) async -> Bool {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// A short grace, so the suite does not spend real seconds holding threads
    /// while every other test runs alongside it. The production value is a
    /// second; what is under test is that the escalation happens at all.
    private static let quickGrace: TimeInterval = 0.05

    /// The assertion is the *signal*, not the clock.
    ///
    /// The child traps SIGTERM, so it can only end early by being killed, and a
    /// process killed that way reports `SIGKILL` as its status. If the
    /// escalation were missing it would instead run its `sleep` to completion
    /// and exit 0. That distinction holds however loaded the machine is, which
    /// a wall-clock threshold does not: measured at 5-8 seconds under a
    /// parallel suite against 1.5 on an idle one.
    /// The timeout path: a child that outlives its deadline is signalled and
    /// the run completes rather than hanging. Which signal finished it depends
    /// on how far into its own startup the child had got, so the escalation
    /// itself is asserted by `cancellingStubbornChildEscalates`, which waits
    /// until the trap is demonstrably installed.
    @Test("A child that outlives its deadline is ended and reaped")
    func stubbornChildIsKilled() async {
        let outcome = await ChildProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", Self.ignoresSigterm],
            timeout: 0.2,
            killGrace: Self.quickGrace
        )

        #expect(outcome.timedOut, "the deadline never fired")
        #expect(!outcome.succeeded)
        #expect(outcome.status != 0, "the child exited normally, so nothing ended it")
    }

    @Test("A well-behaved child returns its output")
    func normalChildSucceeds() async {
        let outcome = await ChildProcess.run(
            executable: "/bin/echo", arguments: ["hello"], timeout: 5
        )
        #expect(outcome.succeeded)
        #expect(outcome.outputText == "hello")
    }

    @Test("A failing child reports its status and stderr")
    func failingChildReportsStatus() async {
        let outcome = await ChildProcess.run(
            executable: "/bin/sh", arguments: ["-c", "echo boom >&2; exit 3"], timeout: 5
        )
        #expect(outcome.status == 3)
        #expect(!outcome.succeeded)
        #expect(outcome.errorText.contains("boom"))
    }

    @Test("Output larger than a pipe buffer does not deadlock")
    func largeOutputIsDrained() async {
        // An undrained pipe wedges the child once it fills; 512KB is well past
        // the 64KB buffer.
        let outcome = await ChildProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes ledge | head -c 524288"],
            timeout: 20
        )
        #expect(outcome.succeeded, "the child deadlocked on a full pipe")
        #expect(outcome.standardOutput.count == 524_288)
    }

    @Test("An executable that does not exist fails rather than hanging")
    func missingExecutable() async {
        let outcome = await ChildProcess.run(
            executable: "/usr/bin/ledge-does-not-exist", arguments: [], timeout: 5
        )
        #expect(outcome.failedToLaunch)
        #expect(!outcome.succeeded)
    }

    /// Cancellation used to send SIGTERM and stop there, so a child that
    /// ignores it lived on until the *original* deadline — cancelling bought
    /// nothing. Measured before the fix: 2.86s against a 3s timeout.
    /// Escalation, with the race removed: the child is not signalled until it
    /// has told us its SIGTERM trap is in place, so the only thing that can end
    /// it is SIGKILL. The deadline is long enough that it cannot be what
    /// finished the child, and the assertion is the signal rather than a clock.
    @Test("Cancelling a stubborn child escalates to SIGKILL rather than waiting out the timeout")
    func cancellingStubbornChildEscalates() async {
        let marker = NSTemporaryDirectory() + "ledge-trap-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: marker) }

        let finished = OSAllocatedUnfairLock(initialState: false)
        let status = OSAllocatedUnfairLock(initialState: Int32(0))

        let task = Task.detached {
            let outcome = await ChildProcess.run(
                executable: "/bin/sh",
                arguments: ["-c", Self.trapScript(marker: marker)],
                // Long: if cancellation does not escalate, only the deadline
                // could end this, and the test would take that long.
                timeout: 120,
                killGrace: Self.quickGrace
            )
            status.withLock { $0 = outcome.status }
            finished.withLock { $0 = true }
        }

        let ready = await Self.waitForMarker(marker)
        #expect(ready, "the child never installed its trap")

        task.cancel()
        await task.value

        #expect(finished.withLock { $0 })
        #expect(
            status.withLock { $0 } == SIGKILL,
            """
            status was \(status.withLock { $0 }), not SIGKILL — cancellation sent \
            SIGTERM to a child that ignores it and stopped there
            """
        )
    }

    @Test("Cancelling returns promptly and takes the child with it")
    func cancellationEndsTheChild() async throws {
        let done = OSAllocatedUnfairLock(initialState: false)
        let task = Task.detached {
            _ = await ChildProcess.run(
                executable: "/bin/sleep", arguments: ["60"], timeout: 60
            )
            done.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await task.value
        #expect(done.withLock { $0 }, "the run never completed")
    }
}

/// Transport commands: one at a time, in order, bounded.
@Suite("Serial command runner", .serialized)
struct SerialCommandRunnerTests {

    @Test("Fifty rapid commands run one at a time, in submission order")
    func fiftyCommandsStaySerial() async {
        let runner = SerialCommandRunner(capacity: 64)
        let order = OSAllocatedUnfairLock(initialState: [Int]())

        // Submitted synchronously and back to back, as a user mashing a button
        // produces them.
        for i in 0..<50 {
            let accepted = runner.submit {
                try? await Task.sleep(for: .milliseconds(2))
                order.withLock { $0.append(i) }
            }
            #expect(accepted)
        }
        await runner.drain()

        #expect(runner.peakConcurrency == 1, "\(runner.peakConcurrency) commands ran at once")
        #expect(runner.completed == 50)
        #expect(
            order.withLock { $0 } == Array(0..<50),
            "commands ran out of submission order"
        )
        #expect(runner.startedOrder == Array(0..<50))
    }

    /// The bound has to be enforced where the decision is made. An earlier
    /// version spawned a task first and returned true regardless — so a
    /// capacity-zero runner recorded a refusal and still answered yes, and
    /// every press created a task outside the bound the queue existed for.
    @Test("A capacity-zero runner refuses everything, and says so")
    func zeroCapacityRefuses() async {
        let runner = SerialCommandRunner(capacity: 0)
        let ran = OSAllocatedUnfairLock(initialState: 0)

        for _ in 0..<10 {
            let accepted = runner.submit { ran.withLock { $0 += 1 } }
            #expect(accepted == false, "a full runner claimed to have queued the command")
        }
        await runner.drain()

        #expect(runner.refusals == 10)
        #expect(ran.withLock { $0 } == 0, "refused work ran anyway")
        #expect(runner.completed == 0)
    }

    @Test("Pending work never exceeds capacity")
    func pendingStaysBounded() async {
        let runner = SerialCommandRunner(capacity: 4)
        let release = OSAllocatedUnfairLock(initialState: false)
        var accepted = 0

        for _ in 0..<200 {
            if runner.submit({
                while !release.withLock({ $0 }) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }) {
                accepted += 1
            }
            #expect(runner.pendingCount <= 4, "pending grew to \(runner.pendingCount)")
        }

        #expect(accepted <= 5, "\(accepted) accepted against a capacity of 4")
        #expect(runner.refusals > 0)

        release.withLock { $0 = true }
        await runner.drain()
    }

    @Test("Submission order survives back-to-back calls from one thread")
    func submissionOrderIsPreserved() async {
        let runner = SerialCommandRunner(capacity: 128)
        for _ in 0..<100 { runner.submit {} }
        await runner.drain()
        #expect(runner.startedOrder == Array(0..<100), "order was scheduling order, not submission order")
    }
}
