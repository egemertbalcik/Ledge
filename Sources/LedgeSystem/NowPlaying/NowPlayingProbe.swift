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
    ///
    /// The lifetime belongs to `ChildProcess`: a helper that ignores SIGTERM
    /// gets SIGKILL after a grace, and the output is drained continuously
    /// rather than through a `readDataToEndOfFile` that a stuck child would
    /// leave blocked on a background queue for as long as it lived.
    private static func run(_ dylib: URL, host: AdapterHost) async -> Bool {
        let outcome = await ChildProcess.run(
            executable: host.executable,
            arguments: host.arguments,
            timeout: timeout,
            environment: [
                "LEDGE_ADAPTER_DYLIB": dylib.path,
                "LEDGE_ADAPTER_MODE": "get",
                // The probe never needs the picture, and skipping it avoids
                // several hundred kilobytes of base64 through a pipe.
                "LEDGE_ADAPTER_ARTWORK": "0",
                "PATH": "/usr/bin:/bin",
            ]
        )

        guard !outcome.failedToLaunch else {
            log.notice("adapter probe: launch failed")
            return false
        }
        guard !outcome.timedOut else {
            log.notice("adapter probe: timed out")
            return false
        }

        var sawHello = false
        var sawAnswer = false
        var buffer = LineBuffer()
        for line in buffer.append(outcome.standardOutput) {
            guard let payload = try? JSONDecoder().decode(AdapterPayload.self, from: line)
            else { continue }
            if payload.ok == false { break }
            if payload.kind == .hello { sawHello = true }
            if payload.kind == .now { sawAnswer = true }
        }

        let works = sawHello && sawAnswer && outcome.status == 0
        log.notice("""
            adapter probe: hello=\(sawHello, privacy: .public) \
            answer=\(sawAnswer, privacy: .public) \
            status=\(outcome.status, privacy: .public)
            """)
        return works
    }
}
