import Foundation
import os

/// Runs a child process and guarantees it ends.
///
/// Every subprocess in this app had its own version of this, and each version
/// was missing a different piece: one drained its pipes but had no timeout,
/// one had a timeout but only ever sent SIGTERM, one could not be cancelled at
/// all. A child that ignores SIGTERM or is stuck in IPC then lives on — and
/// where a single-flight gate is waiting on it, it wedges that too.
///
/// What this guarantees, in order of the ways it has gone wrong before:
///
/// - **Cancellation works before, during and after launch.** Cancelled before
///   adoption, the process is never started; between adoption and `run()`,
///   whichever of `cancel` and `started` happens second sends the signal, so
///   the launch cannot slip through the gap; after that it is terminated.
/// - **One terminal completion.** The continuation is resumed exactly once,
///   whichever of exit, timeout and cancellation gets there first.
/// - **Pipes are drained continuously**, not read at the end. An undrained
///   pipe deadlocks the child once it fills.
/// - **SIGTERM, then SIGKILL.** A child that ignores the first gets the
///   second after a short grace, which nothing can ignore.
/// - **Always reaped.** `waitUntilExit` runs on a background queue, so no
///   zombie and no blocked caller.
enum ChildProcess {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "process")

    struct Outcome: Sendable {
        var status: Int32
        var standardOutput: Data
        var standardError: Data
        /// True if the deadline fired and the child had to be signalled.
        var timedOut: Bool
        /// True if the surrounding task was cancelled.
        var cancelled: Bool
        /// True if the process could not be launched at all.
        var failedToLaunch: Bool

        var succeeded: Bool { status == 0 && !timedOut && !cancelled && !failedToLaunch }
        var outputText: String {
            String(decoding: standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var errorText: String { String(decoding: standardError, as: UTF8.self) }
    }

    /// How long after SIGTERM before SIGKILL. Short: by this point the child
    /// has already missed its deadline and been asked politely once.
    static let killGrace: TimeInterval = 1.0

    /// How long to wait after exit for the last of the output to arrive.
    static let tailGrace: TimeInterval = 0.25

    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        captureOutput: Bool = true,
        killGrace: TimeInterval = killGrace
    ) async -> Outcome {
        let handle = Handle(killGrace: killGrace)
        return await withTaskCancellationHandler {
            await execute(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                environment: environment,
                captureOutput: captureOutput,
                handle: handle
            )
        } onCancel: {
            handle.cancel()
        }
    }

    // MARK: - The shared lifetime box

    /// Holds the process and the one-shot completion, reachable from the
    /// cancellation handler, the deadline and the exit — any of which may be
    /// first, and on any thread.
    final class Handle: @unchecked Sendable {

        /// How long after SIGTERM before SIGKILL, for this run.
        let killGrace: TimeInterval

        init(killGrace: TimeInterval = ChildProcess.killGrace) {
            self.killGrace = killGrace
        }

        private struct State {
            var process: Process?
            var pid: pid_t?
            var started = false
            var cancelled = false
            var finished = false
            /// Set once an escalation chain is under way, so the several
            /// things that can ask for one — cancellation, a cancellation that
            /// arrived mid-launch, the deadline — produce a single
            /// SIGTERM-then-SIGKILL rather than several overlapping ones.
            var escalating = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        /// - Returns: false if cancellation already happened, in which case the
        ///   caller must not start the process at all.
        func adopt(_ process: Process) -> Bool {
            state.withLock { s in
                guard !s.cancelled else { return false }
                s.process = process
                return true
            }
        }

        /// Called immediately after `run()`, to close the window in which the
        /// process exists but is not yet running and so cannot be signalled.
        func started(pid: pid_t) {
            let wasCancelled = state.withLock { s -> Bool in
                s.started = true
                s.pid = pid
                return s.cancelled
            }
            // Cancelled while it was being launched: it is running now, so it
            // can finally be signalled — and it gets the full escalation, not
            // a lone SIGTERM.
            if wasCancelled { terminateThenKill(grace: killGrace) }
        }

        func cancel() {
            let started = state.withLock { s -> Bool in
                s.cancelled = true
                // `terminate()` on a Process that was never launched raises.
                return s.started
            }
            guard started else { return }
            // The same escalation the deadline uses. Terminating once and
            // leaving it at that meant a cancelled child that ignores SIGTERM
            // lived on until the original timeout — the cancellation bought
            // nothing.
            terminateThenKill(grace: killGrace)
        }

        var isCancelled: Bool { state.withLock { $0.cancelled } }

        /// Sends SIGTERM, then SIGKILL if the child is still there after the
        /// grace. Returns without waiting; the exit path does the reaping.
        func terminateThenKill(grace: TimeInterval) {
            let (process, pid, already) = state.withLock { s -> (Process?, pid_t?, Bool) in
                defer { s.escalating = true }
                return (s.process, s.pid, s.escalating)
            }
            // Idempotent: several callers may want the child gone at once.
            guard !already, let process, process.isRunning else { return }
            process.terminate()
            guard let pid else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
                // Signal the pid rather than the Process: by now the object may
                // have been released, and a child that ignored SIGTERM is
                // exactly the one that must not be left running.
                guard process.isRunning else { return }
                log.notice("child \(pid, privacy: .public) ignored SIGTERM — killing")
                kill(pid, SIGKILL)
            }
        }

        /// - Returns: true the first time only. Everything that can finish the
        ///   run asks this, so the continuation is resumed exactly once.
        func claimCompletion() -> Bool {
            state.withLock { s in
                guard !s.finished else { return false }
                s.finished = true
                return true
            }
        }

        func clearProcess() { state.withLock { $0.process = nil } }
    }

    // MARK: - Running

    private static func execute(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        captureOutput: Bool,
        handle: Handle
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                func finish(_ outcome: Outcome) {
                    guard handle.claimCompletion() else { return }
                    handle.clearProcess()
                    continuation.resume(returning: outcome)
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }

                let outBuffer = ByteBuffer()
                let errBuffer = ByteBuffer()
                // Signalled when the pipe reports end-of-file, which is how the
                // tail of the output is collected without reading to EOF —
                // see the bounded wait below.
                let outEOF = DispatchSemaphore(value: 0)
                let errEOF = DispatchSemaphore(value: 0)
                let outPipe: Pipe? = captureOutput ? Pipe() : nil
                let errPipe: Pipe? = captureOutput ? Pipe() : nil

                if let outPipe {
                    process.standardOutput = outPipe
                    // Drained continuously: reading only at the end deadlocks
                    // the child as soon as it fills the pipe.
                    outPipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { outEOF.signal(); return }
                        outBuffer.append(chunk)
                    }
                } else {
                    process.standardOutput = FileHandle.nullDevice
                }

                if let errPipe {
                    process.standardError = errPipe
                    errPipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { errEOF.signal(); return }
                        errBuffer.append(chunk)
                    }
                } else {
                    process.standardError = FileHandle.nullDevice
                }

                guard handle.adopt(process) else {
                    finish(Outcome(
                        status: -1, standardOutput: Data(), standardError: Data(),
                        timedOut: false, cancelled: true, failedToLaunch: false
                    ))
                    return
                }

                do {
                    try process.run()
                } catch {
                    log.debug("\(executable, privacy: .public) failed to launch: \(error.localizedDescription, privacy: .public)")
                    outPipe?.fileHandleForReading.readabilityHandler = nil
                    errPipe?.fileHandleForReading.readabilityHandler = nil
                    finish(Outcome(
                        status: -1, standardOutput: Data(), standardError: Data(),
                        timedOut: false, cancelled: false, failedToLaunch: true
                    ))
                    return
                }
                handle.started(pid: process.processIdentifier)

                let timedOut = OSAllocatedUnfairLock(initialState: false)
                let deadline = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.withLock { $0 = true }
                    log.notice("\(executable, privacy: .public) timed out after \(timeout, privacy: .public)s")
                    handle.terminateThenKill(grace: handle.killGrace)
                }
                DispatchQueue.global(qos: .utility)
                    .asyncAfter(deadline: .now() + timeout, execute: deadline)

                // Reaps the child, whether it exited, was terminated or killed.
                process.waitUntilExit()
                deadline.cancel()

                // Whatever the child wrote just before exiting may not have
                // reached the handler yet, and dropping it loses the most
                // useful line there is — the one a program prints on its way
                // out. For `osascript` that is the text the Automation-denial
                // check reads, so losing it would silently break the latch.
                //
                // Waiting for end-of-file rather than reading to it: a killed
                // shell can leave a grandchild holding the write end, and
                // `readDataToEndOfFile` then blocks until *that* exits — which
                // turned a 1.5-second kill into a 60-second one. This waits
                // briefly for the tail and gives up rather than hanging on a
                // pipe nobody is going to close.
                if outPipe != nil { _ = outEOF.wait(timeout: .now() + Self.tailGrace) }
                if errPipe != nil { _ = errEOF.wait(timeout: .now() + Self.tailGrace) }

                outPipe?.fileHandleForReading.readabilityHandler = nil
                errPipe?.fileHandleForReading.readabilityHandler = nil

                finish(Outcome(
                    status: process.terminationStatus,
                    standardOutput: outBuffer.data,
                    standardError: errBuffer.data,
                    timedOut: timedOut.withLock { $0 },
                    cancelled: handle.isCancelled,
                    failedToLaunch: false
                ))
            }
        }
    }
}

/// Accumulates pipe output from the readability handler's thread.
private final class ByteBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Data())
    func append(_ chunk: Data) { lock.withLock { $0.append(chunk) } }
    var data: Data { lock.withLock { $0 } }
}
