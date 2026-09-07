import Foundation
import os

/// Decides, once at startup, whether the bundled MediaRemote adapter actually
/// works on this machine.
///
/// The probe is a *mechanism* check, not a semantic one: it proves that perl
/// loads the dylib, that the symbol resolves, and that a MediaRemote callback
/// fires. It deliberately does **not** require the callback to contain a track,
/// because "nothing is playing" and "Apple closed the gate again" look
/// identical from here. Catching the latter is
/// `CompositeNowPlayingSource`'s runtime demotion, not this.
@MainActor
public enum NowPlayingProbe {

    // `nonisolated` because the probe's background queues log too, and a
    // main-actor-isolated `Logger` cannot be read from a `@Sendable` closure.
    // `Logger` is itself `Sendable`, so this removes an isolation claim that was
    // never true rather than loosening a real one.
    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "nowplaying")

    /// How long the one-shot helper gets before it is killed.
    private static let timeout: TimeInterval = 4

    /// The adapter's location and the host that will drive it, or nil when no
    /// host on this Mac can.
    ///
    /// Each candidate is tried in turn, because the interpreter this rests on
    /// is deprecated by Apple and one day will not be there. Trying the second
    /// costs a few hundred milliseconds on exactly the Macs where the first is
    /// already gone, and nothing at all anywhere else.
    public static func workingAdapter() async -> (dylib: URL, host: AdapterHost)? {
        guard ProcessInfo.processInfo.environment["LEDGE_NO_ADAPTER"] != "1" else {
            log.notice("adapter: disabled by LEDGE_NO_ADAPTER")
            return nil
        }
        // Absent in a bare `swift build` run, which is exactly when the adapter
        // should not be used.
        guard let dylib = MediaRemoteAdapterSource.bundledDylibURL() else {
            log.notice("adapter: not bundled (running outside the .app?)")
            return nil
        }
        let candidates = AdapterHost.candidates()
        guard !candidates.isEmpty else {
            log.notice("adapter: no permitted host on this Mac")
            return nil
        }
        for host in candidates {
            if await run(dylib, host: host) {
                log.notice("adapter: \(host.name, privacy: .public) works")
                return (dylib, host)
            }
            log.notice("adapter: \(host.name, privacy: .public) did not answer")
        }
        return nil
    }

    /// Runs the helper once in `get` mode and checks that it both greets us and
    /// answers.
    private static func run(_ dylib: URL, host: AdapterHost) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: host.executable)
            process.arguments = host.arguments
            process.environment = [
                "LEDGE_ADAPTER_DYLIB": dylib.path,
                "LEDGE_ADAPTER_MODE": "get",
                // The probe never needs the picture, and skipping it avoids
                // several hundred kilobytes of base64 through a pipe.
                "LEDGE_ADAPTER_ARTWORK": "0",
                "PATH": "/usr/bin:/bin",
            ]

            let out = Pipe()
            process.standardOutput = out
            // Discarded, not piped: an undrained pipe blocks the child once
            // its buffer fills, turning a chatty helper into a probe timeout.
            process.standardError = FileHandle.nullDevice

            let finished = OSAllocatedUnfairLock(initialState: false)
            // `@Sendable`: called from the timeout work item and from the
            // reader queue. It only touches the lock and the continuation, both
            // of which are `Sendable`.
            @Sendable func complete(_ value: Bool) {
                let alreadyDone = finished.withLock { done -> Bool in
                    if done { return true }
                    done = true
                    return false
                }
                guard !alreadyDone else { return }
                continuation.resume(returning: value)
            }

            do {
                try process.run()
            } catch {
                log.notice("adapter probe: launch failed — \(error.localizedDescription, privacy: .public)")
                complete(false)
                return
            }

            // A helper that never answers must not hold startup open.
            // `nonisolated(unsafe)` only to carry the work item into the reader
            // queue so it can be cancelled. `DispatchWorkItem.cancel()` is
            // documented as safe to call from any thread; the type simply is not
            // marked `Sendable`.
            nonisolated(unsafe) let deadline = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                log.notice("adapter probe: timed out")
                complete(false)
            }
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + timeout, execute: deadline)

            DispatchQueue.global(qos: .userInitiated).async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()

                var sawHello = false
                var sawAnswer = false
                var buffer = LineBuffer()
                for line in buffer.append(data) {
                    guard let payload = try? JSONDecoder().decode(AdapterPayload.self, from: line)
                    else { continue }
                    if payload.ok == false { break }
                    if payload.kind == .hello { sawHello = true }
                    if payload.kind == .now { sawAnswer = true }
                }

                let works = sawHello && sawAnswer && process.terminationStatus == 0
                log.notice("""
                    adapter probe: hello=\(sawHello, privacy: .public) \
                    answer=\(sawAnswer, privacy: .public) \
                    status=\(process.terminationStatus, privacy: .public)
                    """)
                complete(works)
            }
        }
    }
}
