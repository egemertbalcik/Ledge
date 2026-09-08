import AppKit
import Foundation
import LedgeCore
import os

/// Reads now-playing state from the players that expose an AppleScript
/// dictionary — currently Music and Spotify.
///
/// This is the working source, because MediaRemote reads are gated (see
/// `MediaRemoteBridge`). It covers less ground than the system-wide API would:
/// audio playing in a browser is invisible to it.
///
/// `osascript` is spawned as a subprocess rather than using `NSAppleScript`
/// in-process. It costs a few tens of milliseconds per poll, and buys process
/// isolation: a hung or crashed script cannot take the app's main thread with
/// it, and a timeout is a `terminate()` rather than a wedged run loop.
@MainActor
public final class ScriptingNowPlayingSource: NowPlayingSource {

    // Nonisolated: read from closures running on a background queue.
    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "nowplaying")

    /// How long a query may take before the subprocess is killed.
    ///
    /// This is load-bearing. An `osascript` awaiting a TCC decision — the user
    /// has not answered the Automation prompt, or dismissed it — blocks
    /// indefinitely, and AppleScript's own Apple-event timeout is 120 seconds.
    /// Without a deadline the poll loop suspends forever and now-playing stays
    /// dead for the rest of the process lifetime.
    private nonisolated static let queryTimeout: TimeInterval = 3

    /// Separates fields in the script's output. A unit separator cannot occur
    /// in a track title, unlike a newline or a comma.
    ///
    /// Note it is never written *into* the script source — AppleScript's parser
    /// rejects a raw control character inside a string literal, which silently
    /// broke the whole expression. The script builds it with `character id 31`
    /// instead; this constant is only used to split the result.
    private static let separator = "\u{1F}"

    /// How AppleScript spells an absent property once coerced to text.
    private static let missingValue = "missing value"

    public let identifier = "applescript"

    /// One supported player.
    struct Player: Sendable {
        let bundleID: String
        let displayName: String
        /// AppleScript application name, which is not always the bundle name.
        let scriptName: String
        /// Spotify reports milliseconds; Music reports seconds.
        let durationIsMilliseconds: Bool
        let hasArtworkURL: Bool
    }

    static let players: [Player] = [
        Player(
            bundleID: "com.spotify.client",
            displayName: "Spotify",
            scriptName: "Spotify",
            durationIsMilliseconds: true,
            hasArtworkURL: true
        ),
        Player(
            bundleID: "com.apple.Music",
            displayName: "Music",
            scriptName: "Music",
            durationIsMilliseconds: false,
            hasArtworkURL: false
        ),
    ]

    public init() {}

    /// True when at least one supported player is already running.
    ///
    /// Checked through `NSRunningApplication` rather than by asking the script:
    /// telling a non-running app anything would launch it, and an overlay that
    /// opens Spotify on its own would be indefensible.
    public var isAvailable: Bool {
        !Self.runningPlayers().isEmpty
    }

    static func runningPlayers() -> [Player] {
        players.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
    }

    /// Asks one specific player, for the composite source: when MediaRemote
    /// says Spotify or Music owns playback, the answer should still come from
    /// the scripting path that already works for them.
    public func snapshot(forBundleID bundleID: String) async -> NowPlayingSnapshot? {
        guard let player = Self.players.first(where: { $0.bundleID == bundleID }),
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        else { return nil }
        return await Self.query(player)
    }

    /// Whether this source knows how to script the given app at all.
    public static func handles(_ bundleID: String) -> Bool {
        players.contains { $0.bundleID == bundleID }
    }

    public func snapshot() async -> NowPlayingSnapshot? {
        var firstPaused: NowPlayingSnapshot?

        let running = Self.runningPlayers()
        if DebugSwitches.tracing("media") {
            let names = running.map(\.displayName).joined(separator: ",")
            Self.log.notice("media/scripting: running players = [\(names, privacy: .public)]")
        }
        for player in running {
            guard let snapshot = await Self.query(player) else {
                if DebugSwitches.tracing("media") {
                    Self.log.notice("media/scripting: \(player.displayName, privacy: .public) answered nothing")
                }
                continue
            }
            // Something actively playing always wins over something paused, so
            // two open players cannot fight over the card.
            if snapshot.isPlaying { return snapshot }
            if firstPaused == nil { firstPaused = snapshot }
        }
        return firstPaused
    }

    // MARK: - Scripting

    private static func script(for player: Player) -> String {
        // `if it is running` guards against the app quitting between the
        // NSRunningApplication check and the script executing.
        let artwork = player.hasArtworkURL
            ? "set artworkLink to (artwork url of current track)"
            : "set artworkLink to \"\""

        // Variable names are spelled out deliberately. Short ones collide with
        // AppleScript's own vocabulary — `st` is an ordinal suffix, as in "1st",
        // so `set st to ...` is a syntax error that kills the whole script and
        // says only "expected expression".
        //
        // Built on one line with no `¬` continuations too: a stray character
        // after a continuation marker is another silent syntax error.
        return """
        tell application "\(player.scriptName)"
            if it is not running then return ""
            if player state is stopped then return ""
            set sep to (character id 31)
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackLength to duration of current track
            set trackPosition to player position
            set stateText to (player state as text)
            set trackKey to (id of current track) as text
            \(artwork)
            return trackName & sep & trackArtist & sep & trackAlbum & sep & trackLength & sep & trackPosition & sep & stateText & sep & trackKey & sep & artworkLink
        end tell
        """
    }

    /// Players the user has refused Automation for, and until when to believe
    /// it. Static because `query` is: the latch has to outlive any one source.
    private static var denials = AutomationDenialLatch()

    /// The user granted Automation: any believed refusal is stale now, and
    /// waiting out its cooldown would keep Music/Spotify details absent for
    /// up to ten minutes after the grant.
    public static func forgetDenials() {
        denials = AutomationDenialLatch()
    }

    static func query(_ player: Player) async -> NowPlayingSnapshot? {
        let now = Date().timeIntervalSinceReferenceDate
        // A refused Automation prompt is not going to change its mind in the
        // next second. Before the latch, every poll re-spawned osascript just
        // to be refused again and logged an error each time, forever.
        guard !denials.isDenied(player.bundleID, now: now) else { return nil }

        switch await runOsascript(script(for: player)) {
        case .output(let output):
            return parse(output, player: player)
        case .denied(let detail):
            denials.recordDenial(player.bundleID, now: now)
            log.notice("""
                osascript: Automation for \(player.displayName, privacy: .public) is denied \
                (\(detail, privacy: .public)) — not asking again for \
                \(Int(AutomationDenialLatch.cooldown), privacy: .public)s
                """)
            return nil
        case .failed:
            return nil
        }
    }

    /// What one `osascript` run came to.
    enum ScriptResult: Sendable {
        case output(String)
        /// The user has refused this app Automation access to the player
        /// (`-1743`, "Not authorized to send Apple events"). Distinct from
        /// other failures so the caller can stop asking for a while.
        case denied(String)
        case failed
    }

    /// Whether a non-zero exit was TCC refusing us, rather than the script or
    /// the player misbehaving. AppleScript reports it as `errAEEventNotPermitted`
    /// (-1743) with "Not authorized to send Apple events" in the message.
    nonisolated static func indicatesAutomationDenial(_ stderr: String) -> Bool {
        stderr.contains("-1743") || stderr.localizedCaseInsensitiveContains("not authorized")
    }

    /// Runs a script and returns stdout, or why it could not.
    ///
    /// Failures are expected and normal here: the user may have declined
    /// Automation permission, or the player may have quit mid-query. Neither is
    /// worth more than a debug line.
    private static func runOsascript(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                // Drained continuously rather than read at the end. An undrained
                // pipe deadlocks the child once it fills — but discarding stderr
                // entirely costs the only diagnostic there is when a script
                // fails, which has already hidden one silent syntax error.
                let errorBuffer = ErrorBuffer()
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty { errorBuffer.append(chunk) }
                }

                do {
                    try process.run()
                } catch {
                    log.debug("osascript failed to launch: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: .failed)
                    return
                }

                // Kill it if it overruns. Cancelled on normal exit below, so the
                // timer never fires for a healthy query.
                let deadline = DispatchWorkItem {
                    guard process.isRunning else { return }
                    log.notice("osascript timed out after \(queryTimeout, privacy: .public)s — terminating")
                    process.terminate()
                }
                DispatchQueue.global(qos: .utility)
                    .asyncAfter(deadline: .now() + queryTimeout, execute: deadline)

                // Read to EOF first: a script producing more than the pipe
                // buffer would otherwise deadlock against waitUntilExit. On a
                // timeout, terminate() closes the pipe and this returns.
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                stderr.fileHandleForReading.readabilityHandler = nil

                guard process.terminationStatus == 0 else {
                    let detail = errorBuffer.text
                    // A denial is the caller's to log — once, when it latches
                    // — not an error to repeat on every poll.
                    if indicatesAutomationDenial(detail) {
                        continuation.resume(returning: .denied(detail))
                        return
                    }
                    log.error("""
                        osascript exited \(process.terminationStatus, privacy: .public): \
                        \(detail, privacy: .public)
                        """)
                    continuation.resume(returning: .failed)
                    return
                }

                continuation.resume(
                    returning: .output(
                        String(decoding: data, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }
        }
    }

    static func parse(_ output: String, player: Player) -> NowPlayingSnapshot? {
        guard !output.isEmpty else { return nil }

        // AppleScript hands back the literal `missing value` for a property the
        // player has no answer to — a stream with no album, a track with no id.
        // Concatenated into the line it arrives as text, and taken at face
        // value it became an artist called "missing value" and a duration of
        // 0. Treat it as absent in every slot.
        let fields = output.components(separatedBy: separator)
            .map { $0 == Self.missingValue ? "" : $0 }
        // Exactly the scripted shape, not "at least": a track title containing
        // U+001F would shift every later field, landing an attacker-chosen
        // string in the artwork-URL slot. Extra fields mean the sample is
        // corrupt — drop it rather than guess.
        guard fields.count == 7 || fields.count == 8 else {
            log.debug("unexpected field count \(fields.count) from \(player.displayName, privacy: .public)")
            return nil
        }

        // AppleScript formats reals using the *user's* locale, so a machine in
        // a comma-decimal locale yields "214,5". Both separators are accepted.
        func number(_ text: String) -> Double {
            Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
        }

        let rawDuration = number(fields[3])
        let duration = player.durationIsMilliseconds ? rawDuration / 1000 : rawDuration
        let elapsed = number(fields[4])
        // Only web artwork: the URL rides in band with track metadata, and a
        // file: or other scheme here would make the app fetch whatever a
        // crafted tag pointed at.
        let artworkURL = fields.count > 7
            ? URL(string: fields[7]).flatMap { url in
                url.scheme == "https" || url.scheme == "http" ? url : nil
            }
            : nil

        return NowPlayingSnapshot(
            title: fields[0],
            artist: fields[1],
            album: fields[2],
            isPlaying: fields[5].lowercased().contains("playing"),
            elapsed: elapsed,
            // A player briefly reports a position past the end while switching
            // tracks; clamping keeps the scrub bar from overshooting. An
            // unknown duration stays 0, which the card reads as "no progress"
            // — clamping it up to the position would show a full bar instead.
            duration: duration > 0 ? max(duration, elapsed) : 0,
            appName: player.displayName,
            appBundleID: player.bundleID,
            trackKey: fields[6].isEmpty ? nil : "\(player.bundleID)|\(fields[6])",
            artworkURL: artworkURL
        )
    }
}

/// Remembers which players the user has refused Automation for, so they are
/// not asked again on every poll.
///
/// Pure and clock-injected so the policy is testable without a TCC prompt.
struct AutomationDenialLatch: Sendable {

    /// How long a refusal is believed before osascript is tried again. Long
    /// enough that a denied player costs nothing, short enough that granting
    /// access in System Settings is picked up without a relaunch.
    static let cooldown: TimeInterval = 600

    private var deniedUntil: [String: TimeInterval] = [:]

    init() {}

    /// True while a refusal is still believed. A latch whose cooldown has
    /// passed is cleared here, so the very next attempt goes through.
    mutating func isDenied(_ bundleID: String, now: TimeInterval) -> Bool {
        guard let until = deniedUntil[bundleID] else { return false }
        if now < until { return true }
        deniedUntil[bundleID] = nil
        return false
    }

    mutating func recordDenial(_ bundleID: String, now: TimeInterval) {
        deniedUntil[bundleID] = now + Self.cooldown
    }
}

/// Collects a subprocess's error output from the read handler's thread.
private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        // Bounded: a runaway script must not be able to grow this without limit.
        guard data.count < 4096 else { return }
        data.append(chunk)
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Transport control.
///
/// Prefers MediaRemote, whose commands are un-gated and reach whichever player
/// the system considers current. Falls back to telling the specific app, which
/// also covers seeking — MediaRemote's seek takes a different signature.
@MainActor
public final class NowPlayingCommander: NowPlayingCommanding {

    // Nonisolated: read from a process termination handler off the main actor.
    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "nowplaying")

    /// When a transport command was last dispatched, in
    /// `timeIntervalSinceReferenceDate`. Zero until one has been.
    ///
    /// Static, because the commander and the now-playing source are built in
    /// different places and neither holds the other. `CompositeNowPlayingSource`
    /// reads it to know that its cached AppleScript answer — position, play
    /// state — is about to be wrong and must be re-read rather than projected.
    public private(set) static var lastCommandAt: TimeInterval = 0

    public init() {}

    @discardableResult
    public func send(_ command: NowPlayingCommand, to bundleID: String) -> Bool {
        Self.lastCommandAt = Date().timeIntervalSinceReferenceDate

        // Scripting first, because it is the only path that targets the player
        // actually shown on the card. MediaRemote acts on whatever the system
        // considers now-playing, which can be a different app entirely — press
        // play on a Spotify card while a browser tab holds the now-playing slot
        // and MediaRemote toggles the browser.
        if sendViaScripting(command, to: bundleID) {
            return true
        }

        // No scripting dictionary for this player (a browser, say). Fall back to
        // MediaRemote and report honestly that we cannot confirm it landed.
        // Seek used to stop here, because MediaRemote had no usable symbol for
        // it. `MRMediaRemoteSetElapsedTime` does the job, so a browser tab can
        // now be scrubbed too — reported as unconfirmed, since the symbol
        // returns nothing.
        MediaRemoteBridge.send(command)
        return false
    }

    private func sendViaScripting(_ command: NowPlayingCommand, to bundleID: String) -> Bool {
        guard let player = ScriptingNowPlayingSource.players.first(where: { $0.bundleID == bundleID })
        else {
            Self.log.debug("no scripting fallback for \(bundleID, privacy: .public)")
            return false
        }

        let body: String
        switch command {
        case .playPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        // Formatted explicitly: `Double.description` switches to scientific
        // notation for small values ("1e-05"), which AppleScript cannot parse.
        case .seek(let position): body = String(format: "set player position to %.3f", position)
        }

        let source = """
        tell application "\(player.scriptName)"
            if it is not running then return
            \(body)
        end tell
        """

        // Fire and forget: the poll will pick up the result, and blocking the
        // main actor on a subprocess to confirm a button press would be worse
        // than assuming it worked.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        // Discarded, not piped. An undrained pipe deadlocks the child once it
        // fills, and nothing here reads the output.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // `terminationHandler` rather than `waitUntilExit`: mashing next-track
        // would otherwise park one blocked global-queue thread per press.
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else { return }
            Self.log.debug("transport command exited \(finished.terminationStatus, privacy: .public)")
        }

        do {
            try process.run()
        } catch {
            Self.log.debug("transport command failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }
}
