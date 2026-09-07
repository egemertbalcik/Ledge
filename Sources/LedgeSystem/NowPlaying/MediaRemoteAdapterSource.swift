import AppKit
import Foundation
import os

/// How long to wait before restarting a helper that died, and when to give up.
///
/// Pure and separate so the policy can be tested without spawning anything: a
/// dylib that crashes on load would otherwise become a fork bomb at whatever
/// the floor delay happens to be.
public struct AdapterRestartPolicy: Sendable {

    /// Restarts allowed inside `window` before the adapter is abandoned.
    public static let maximumRestarts = 5
    public static let window: TimeInterval = 300

    private var failures = 0
    /// Start times of recent restarts, trimmed to `window`.
    private var recent: [TimeInterval] = []

    public init() {}

    /// The delay before the next attempt, or nil to stop trying for good.
    public mutating func nextDelay(now: TimeInterval, lastRunDuration: TimeInterval) -> TimeInterval? {
        // A helper that ran for a while and then died is a transient failure,
        // not a broken build — start the backoff over, and keep such deaths
        // out of the give-up window too: the window exists to catch a dylib
        // that crashes on load, not a helper that works for minutes at a time.
        if lastRunDuration > 30 {
            failures = 0
            recent.removeAll()
        }

        recent = recent.filter { now - $0 < Self.window }
        recent.append(now)
        guard recent.count <= Self.maximumRestarts else { return nil }

        let delay = min(60, pow(2, Double(failures)))
        failures += 1
        return delay
    }
}

/// Reads system-wide now-playing state by running `LedgeMediaAdapter` inside
/// `/usr/bin/perl`, which is entitled to talk to MediaRemote.
///
/// The helper pushes; this type caches the newest line and answers `snapshot()`
/// from that cache, projecting the elapsed time forward. So the existing
/// pull-based `NowPlayingSource` protocol fits without modification, and the
/// 1s poll costs nothing — there is no subprocess in the hot path.
@MainActor
public final class MediaRemoteAdapterSource: NowPlayingSource, NowPlayingChangePublishing {

    /// Told the moment a line changes the answer — see
    /// `NowPlayingChangePublishing`.
    public var onChange: (() -> Void)?

    nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "adapter")

    public let identifier = "mediaremote-adapter"

    /// Beyond this with no line at all — not even a heartbeat, which arrives
    /// every 30s — the helper is assumed wedged.
    private static let staleAfter: TimeInterval = 90

    private let dylibURL: URL
    /// Which system binary loads the helper. Chosen by the probe, so a Mac
    /// without perl still gets system-wide media rather than nothing.
    public let host: AdapterHost
    private let now: () -> TimeInterval

    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer = LineBuffer()
    private var policy = AdapterRestartPolicy()
    private var startedAt: TimeInterval = 0
    private var restartTask: Task<Void, Never>?
    private var abandoned = false

    /// Bumped per spawn so a stale `terminationHandler` cannot restart the
    /// process that replaced it.
    private var generation = 0

    private var latest: AdapterPayload?
    private var latestAt: TimeInterval = 0

    public init(
        dylibURL: URL,
        host: AdapterHost = .perl,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.dylibURL = dylibURL
        self.host = host
        self.now = now
    }

    /// Where the adapter lives inside the app bundle. Nil in a bare
    /// `swift build` run, which is exactly when it should not be used.
    public static func bundledDylibURL() -> URL? {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let url = frameworks.appendingPathComponent("libLedgeMediaAdapter.dylib")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public var isAvailable: Bool {
        guard !abandoned, process?.isRunning == true else { return false }
        return now() - latestAt < Self.staleAfter
    }

    /// How long since the helper last said anything at all — a change, or the
    /// heartbeat it sends every thirty seconds when nothing is happening.
    /// A long gap means it has stopped watching, whatever its process says.
    public var secondsSinceLastLine: TimeInterval { now() - latestAt }

    public func snapshot() async -> NowPlayingSnapshot? {
        guard let latest, isAvailable else { return nil }
        return latest.snapshot(at: now(), resolveApp: Self.resolveApp)
    }

    /// Whether two lines describe the same track.
    ///
    /// The player's own identifier when there is one; otherwise what is on
    /// screen, which is all a browser gives for anything else.
    nonisolated static func isSameTrack(_ line: AdapterPayload, _ previous: AdapterPayload) -> Bool {
        if let a = line.trackID, let b = previous.trackID { return a == b }
        return line.title == previous.title
            && line.artist == previous.artist
            && line.bundleID == previous.bundleID
    }

    /// Whether a new line is worth waking the reader for.
    ///
    /// The position moves on almost every line and is extrapolated between
    /// them anyway, so it is not news. What is: something started, stopped,
    /// changed track, changed player, or jumped somewhere else in the track.
    nonisolated static func isNews(_ line: AdapterPayload, since previous: AdapterPayload?) -> Bool {
        guard let previous else { return true }
        if line.playing != previous.playing { return true }
        if line.trackID != previous.trackID { return true }
        if line.title != previous.title { return true }
        if line.bundleID != previous.bundleID { return true }
        // A seek: the position is somewhere the last line could not have led
        // to. Anything smaller is ordinary playback and the projection covers
        // it without a redraw.
        let elapsed = line.elapsed ?? 0
        let before = previous.elapsed ?? 0
        let expected = (line.t ?? 0) - (previous.t ?? 0)
        return abs(elapsed - before) > max(expected, 0) + 2
    }

    /// Names an app from its pid when the helper could not. Lives here rather
    /// than in `AdapterPayload` so that stays free of AppKit and testable.
    private nonisolated static func resolveApp(_ pid: Int) -> (name: String, bundleID: String)? {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              let bundleID = app.bundleIdentifier
        else { return nil }
        return (app.localizedName ?? bundleID, bundleID)
    }

    // MARK: - Process

    public func start() {
        guard process == nil, !abandoned else { return }
        generation += 1
        let spawned = generation

        let task = Process()
        task.executableURL = URL(fileURLWithPath: host.executable)
        task.arguments = host.arguments
        // A minimal environment: the child has no business inheriting the app's.
        task.environment = [
            "LEDGE_ADAPTER_DYLIB": dylibURL.path,
            "LEDGE_ADAPTER_MODE": "stream",
            "LEDGE_ADAPTER_ARTWORK": "1",
            "PATH": "/usr/bin:/bin",
        ]

        let out = Pipe()
        let err = Pipe()
        // Held open deliberately: the helper watches its stdin for EOF and exits
        // when it closes, which is what stops orphans surviving a SIGKILL of
        // this process.
        let input = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = input

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // Generation-tagged: a chunk Task already queued when stop() runs
            // would otherwise land after the reset and resurrect the dead
            // session's track as a fresh-looking snapshot.
            Task { @MainActor [weak self] in self?.consume(chunk, from: spawned) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let text = String(decoding: chunk, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                Self.log.error("adapter stderr: \(text, privacy: .public)")
            }
        }

        task.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.processEnded(generation: spawned, status: finished.terminationStatus)
            }
        }

        // Stamped before the launch attempt: a `run()` failure must read as an
        // instant death (backoff grows), not as a marathon run (backoff reset).
        startedAt = now()
        do {
            try task.run()
            process = task
            stdinPipe = input
            Self.log.notice("adapter started (pid \(task.processIdentifier, privacy: .public))")
        } catch {
            Self.log.error("adapter failed to launch: \(error.localizedDescription, privacy: .public)")
            scheduleRestart()
        }
    }

    public func stop() {
        restartTask?.cancel()
        restartTask = nil
        generation += 1  // orphan any in-flight termination handler

        if let process {
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            // Closing stdin is what the helper actually watches for.
            try? stdinPipe?.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // Hold the Process itself: `self.process` is nil'd right below, so
            // checking it here made the SIGKILL branch unreachable and a helper
            // that shrugged off SIGTERM survived stop() forever.
            let doomed = process
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if doomed.isRunning { kill(doomed.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        stdinPipe = nil
        latest = nil
        latestAt = 0
        buffer = LineBuffer()
    }

    private func processEnded(generation ended: Int, status: Int32) {
        guard ended == generation else { return }  // a stale handler
        Self.log.notice("adapter exited (status \(status, privacy: .public))")
        // The crash path has to clear the pipe handlers just like stop() does:
        // a handler left installed strands the FileHandle and its dispatch
        // source, one pair per helper death, forever.
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !abandoned else { return }
        let ranFor = now() - startedAt
        guard let delay = policy.nextDelay(now: now(), lastRunDuration: ranFor) else {
            abandoned = true
            Self.log.error("adapter restarted too often — giving up, falling back to AppleScript")
            return
        }
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.start()
        }
    }

    // MARK: - Reading

    private func consume(_ chunk: Data, from spawned: Int) {
        guard spawned == generation else { return }  // straggler from a stopped session
        for line in buffer.append(chunk) {
            guard let payload = try? JSONDecoder().decode(AdapterPayload.self, from: line) else {
                continue
            }
            latestAt = now()
            switch payload.kind {
            case .hello, .heartbeat:
                break  // liveness only
            case .now, .none:
                // Artwork rides only on the line where its id changes; later
                // status lines for the same track carry none. Replacing
                // `latest` wholesale therefore dropped the bytes one second
                // after they arrived — carry them forward while the id holds.
                if payload.describesTrack {
                    var merged = payload
                    // Artwork rides only on the line that introduces it, so
                    // every later line for the same track carries none and the
                    // bytes have to be carried forward by hand.
                    //
                    // Carried by *track*, not by artwork id. Keyed on the id,
                    // a line that simply stopped mentioning artwork — which
                    // Safari does, mid-video, for no reason it explains —
                    // failed the comparison and the cover vanished from under
                    // a video that was still playing. The id travels with the
                    // bytes so the pair can never disagree.
                    if merged.artwork == nil,
                       let held = latest,
                       held.artwork != nil,
                       Self.isSameTrack(merged, held) {
                        merged.artwork = held.artwork
                        merged.artworkID = held.artworkID
                        merged.artworkMIME = held.artworkMIME
                    }
                    let changed = Self.isNews(merged, since: latest)
                    latest = merged
                    if changed { onChange?() }
                } else {
                    let changed = latest != nil
                    latest = nil
                    if changed { onChange?() }
                }
            }
        }
    }
}
