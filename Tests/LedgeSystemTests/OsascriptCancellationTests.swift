import Foundation
import Testing
import os

@testable import LedgeSystem

/// The launch window, which is the part that is easy to get wrong.
///
/// Cancellation can arrive at any moment relative to the launch, and the
/// ordering that bites is the middle one: the process object exists but has not
/// been started, so `isRunning` is false and a naive handler concludes there is
/// nothing to kill — then `run()` starts it and nothing ever terminates it.
/// That defect was introduced and caught here during this work.
@Suite("Child process launch window", .serialized)
struct ChildProcessLaunchWindowTests {

    @Test("Cancelled before adoption, the process is never started")
    func cancelledBeforeAdoption() {
        let handle = ChildProcess.Handle()
        handle.cancel()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]

        #expect(handle.adopt(process) == false, "a cancelled run would still have launched")
        #expect(!process.isRunning)
    }

    @Test("Cancelled between adoption and launch, the child is still terminated")
    func cancelledDuringLaunch() async throws {
        let handle = ChildProcess.Handle()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        #expect(handle.adopt(process))
        // The window: adopted, cancelled, and only then launched.
        handle.cancel()
        try process.run()
        handle.started(pid: process.processIdentifier)

        // `started` is what sends the signal in this ordering.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!process.isRunning, "a child cancelled mid-launch was left running")
        process.waitUntilExit()
    }

    @Test("Completion is claimed exactly once")
    func completionIsClaimedOnce() {
        let handle = ChildProcess.Handle()
        #expect(handle.claimCompletion())
        #expect(handle.claimCompletion() == false)
        #expect(handle.claimCompletion() == false)
    }
}

/// The same property through the real entry point.
@Suite("Media query cancellation, end to end", .serialized)
struct OsascriptIntegrationCancellationTests {

    /// Off by default: `elapsed` includes how long the detached task takes to be
    /// *scheduled*, which under a parallel suite is seconds — it measured 4 to 7
    /// seconds with the fix in place and 3 seconds without, so there it reports
    /// the machine rather than the code. The mechanism is covered
    /// deterministically above and in `ChildProcessTests`.
    ///
    ///     LEDGE_TIMING_TESTS=1 swift test --filter cancellingAQueryReturnsAtOnce
    @Test(
        "Cancelling a query returns at once rather than waiting out the script",
        .enabled(if: ProcessInfo.processInfo.environment["LEDGE_TIMING_TESTS"] == "1")
    )
    func cancellingAQueryReturnsAtOnce() async throws {
        let task = Task.detached {
            _ = await ScriptingNowPlayingSource.runOsascript("delay 30")
        }
        try await Task.sleep(for: .milliseconds(400))

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            task.cancel()
            await task.value
        }
        // Below the runner's own timeout, or the timeout would mask the result.
        #expect(
            elapsed < .milliseconds(1500),
            "the query took \(elapsed) — the child ran on until its timeout"
        )
    }
}
