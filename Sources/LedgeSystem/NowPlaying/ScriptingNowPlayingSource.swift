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

    /// Apple Events can raise a prompt even when only reading. Keep the
    /// Automation gate here, not on the whole media provider: the adapter
    /// can supply system-wide media before the user has been asked.
    private let mayQueryPlayers: @MainActor () -> Bool
    private let availablePlayers: @MainActor () -> [Player]
    private let readPlayer: @MainActor (Player) async -> PlayerReading
    private let now: @MainActor () -> TimeInterval

    public convenience init(mayQueryPlayers: @escaping @MainActor () -> Bool = { true }) {
        self.init(mayQueryPlayers: mayQueryPlayers, availablePlayers: Self.runningPlayers, readPlayer: Self.query)
    }

    init(
        mayQueryPlayers: @escaping @MainActor () -> Bool,
        availablePlayers: @escaping @MainActor () -> [Player],
        readPlayer: @escaping @MainActor (Player) async -> PlayerReading,
        now: @escaping @MainActor () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.mayQueryPlayers = mayQueryPlayers
        self.availablePlayers = availablePlayers
        self.readPlayer = readPlayer
        self.now = now
    }

    /// What one read of a player came to.
    ///
    /// `nothing` and `unreadable` are the distinction this type exists for. A
    /// player that answers "stopped" has told us something; a player that did
    /// not answer has not. Collapsing the two into a bare nil is how a single
    /// `osascript` that missed its three-second deadline came to close the
    /// island on a track the user had just paused.
    enum PlayerReading: Sendable {
        case answered(NowPlayingSnapshot)
        /// The player replied, and nothing is playing.
        case nothing
        /// The player did not reply, or we were not allowed to ask.
        case unreadable
    }

    /// The last answer each player gave, kept only long enough to ride out one
    /// that does not reply.
    ///
    /// Bounded tightly on purpose. The card's own fifteen-minute paused
    /// lifetime and the two-minute companion linger are policies about what
    /// the user wants to see; this is nothing of the kind — it covers a player
    /// that missed a deadline, which is a handful of seconds at most. Past the
    /// grace the answer is dropped and the absence is reported honestly, stale
    /// data being the one thing worse than a card that goes away.
    ///
    /// Filed per player, which is the whole of its safety. One shared answer
    /// meant a silent Music could be answered with Spotify's paused track:
    /// the targeted read asked about Music, got Spotify back, and the card —
    /// and every transport button on it — addressed the wrong player. An
    /// answer may only ever stand in for the player that gave it.
    private var heldAnswers: [String: (snapshot: NowPlayingSnapshot, at: TimeInterval)] = [:]

    /// The players whose latest answer, from either kind of read, was that
    /// nothing is playing.
    ///
    /// Both reads return nil for it, and nil cannot carry the difference
    /// between "Music said it has stopped" and "nobody could be asked". The
    /// composite needs the first to let go of a player it is holding against
    /// a page. Kept per player until that player answers again: a read of
    /// every player stops at the first one playing, so it cannot be relied on
    /// to ask Music twice, and a stop heard by the targeted read is as much
    /// the player's word as one heard by the scan. A player that did not
    /// answer, or was never asked, is left as it was.
    ///
    /// Each stop is numbered, so whoever reads this can tell a stop it has
    /// already placed against an item from one the player has just given.
    /// Which item a stop was about is not this type's to know: the answer
    /// says nothing playing, and names nothing.
    private(set) var stopsHeard: [String: Int] = [:]
    private var stopsCounted = 0

    /// The players whose latest answer was a stop, whichever stop it was.
    var answeredNothing: Set<String> { Set(stopsHeard.keys) }

    /// How long an unanswered read may be covered by the last answer. One
    /// `osascript` deadline is three seconds, and the poll after it has to
    /// land too.
    private static let unreadableGrace: TimeInterval = 10

    /// True when at least one supported player is already running.
    ///
    /// Checked through `NSRunningApplication` rather than by asking the script:
    /// telling a non-running app anything would launch it, and an overlay that
    /// opens Spotify on its own would be indefensible.
    public var isAvailable: Bool {
        mayQueryPlayers() && !availablePlayers().isEmpty
    }

    /// Remembers each player's process, so a blink in the lookup below can be
    /// told from a player that has genuinely quit. The rule and the evidence
    /// for it live in `PlayerLiveness`.
    private static var liveness = PlayerLiveness()

    static func runningPlayers() -> [Player] {
        players.filter { player in
            liveness.isRunning(
                player.bundleID,
                found: NSRunningApplication
                    .runningApplications(withBundleIdentifier: player.bundleID)
                    .first
            )
        }
    }

    /// Asks one specific player, for the composite source: when MediaRemote
    /// says Spotify or Music owns playback, the answer should still come from
    /// the scripting path that already works for them.
    public func snapshot(forBundleID bundleID: String) async -> NowPlayingSnapshot? {
        guard mayQueryPlayers(),
              let player = availablePlayers().first(where: { $0.bundleID == bundleID })
        else { return nil }
        return settle(await readPlayer(player), from: player)
    }

    /// Whether this source knows how to script the given app at all.
    public static func handles(_ bundleID: String) -> Bool {
        players.contains { $0.bundleID == bundleID }
    }

    public func snapshot() async -> NowPlayingSnapshot? {
        guard mayQueryPlayers() else { return nil }
        var firstPaused: NowPlayingSnapshot?

        let running = availablePlayers()
        if DebugSwitches.tracing("media") {
            let names = running.map(\.displayName).joined(separator: ",")
            Self.log.notice("media/scripting: running players = [\(names, privacy: .public)]")
        }
        var firstPausedPlayer: Player?
        var unreadablePlayers: [Player] = []
        for player in running {
            switch await readPlayer(player) {
            case .answered(let snapshot):
                // Something actively playing always wins over something
                // paused, so two open players cannot fight over the card.
                if snapshot.isPlaying { return remember(snapshot, from: player) }
                if firstPaused == nil {
                    firstPaused = snapshot
                    firstPausedPlayer = player
                }
            case .nothing:
                // This player answered, so its own held answer is spent — but
                // only its own.
                _ = remember(nil, from: player)
                if DebugSwitches.tracing("media") {
                    Self.log.notice("media/scripting: \(player.displayName, privacy: .public) answered nothing")
                }
            case .unreadable:
                unreadablePlayers.append(player)
                if DebugSwitches.tracing("media") {
                    Self.log.notice("media/scripting: \(player.displayName, privacy: .public) did not answer")
                }
            }
        }
        if let firstPaused, let firstPausedPlayer {
            return remember(firstPaused, from: firstPausedPlayer)
        }
        // Nobody is playing — but "nobody answered" is not that. A player
        // which missed its deadline keeps its last answer for a few seconds
        // rather than having the card taken off the user mid-pause. Only that
        // player's own answer will do: standing in for a silent Music with
        // Spotify's paused track put the wrong player on the card, and every
        // transport button with it.
        for player in unreadablePlayers {
            if let covered = held(player) { return covered }
        }
        return nil
    }

    /// Keeps this player's answer for a later unanswered read of the *same*
    /// player, and passes it straight back. An authoritative nothing drops it:
    /// a player that has genuinely stopped must take its card with it — and
    /// drops only its own, since one player falling silent says nothing about
    /// another.
    private func remember(_ snapshot: NowPlayingSnapshot?, from player: Player) -> NowPlayingSnapshot? {
        guard let snapshot else {
            heldAnswers[player.bundleID] = nil
            stopsCounted += 1
            stopsHeard[player.bundleID] = stopsCounted
            return nil
        }
        heldAnswers[player.bundleID] = (snapshot, now())
        stopsHeard[player.bundleID] = nil
        return snapshot
    }

    /// This player's last answer, while it is young enough to speak for it.
    private func held(_ player: Player) -> NowPlayingSnapshot? {
        guard let answer = heldAnswers[player.bundleID],
              now() - answer.at < Self.unreadableGrace
        else {
            heldAnswers[player.bundleID] = nil
            return nil
        }
        return answer.snapshot
    }

    /// One reading, with that player's held answer applied — the
    /// single-player path's share of the rule above.
    private func settle(_ reading: PlayerReading, from player: Player) -> NowPlayingSnapshot? {
        switch reading {
        case .answered(let snapshot):
            return remember(snapshot, from: player)
        case .nothing:
            return remember(nil, from: player)
        case .unreadable:
            if DebugSwitches.tracing("media") {
                Self.log.notice("media/scripting: \(player.displayName, privacy: .public) did not answer")
            }
            return held(player)
        }
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
        denials.forgetDenials()
    }

    /// Whether a transport command may be scripted to this player: it has
    /// answered a read, and has not refused since.
    ///
    /// Reads may be the first Apple Event a player gets, once the user has
    /// pressed Automation in the Permissions tab; that press is consent to be
    /// asked. A command never may. Sent to a refused player it does nothing,
    /// and sent to an undecided one it raises the Automation dialog from a
    /// play button. Either way the system path is the right one.
    static func isKnownAllowed(_ bundleID: String) -> Bool {
        denials.isKnownAllowed(bundleID, now: Date().timeIntervalSinceReferenceDate)
    }

    static func query(_ player: Player) async -> PlayerReading {
        let now = Date().timeIntervalSinceReferenceDate
        // A refused Automation prompt is not going to change its mind in the
        // next second. Before the latch, every poll re-spawned osascript just
        // to be refused again and logged an error each time, forever.
        guard !denials.isDenied(player.bundleID, now: now) else { return .unreadable }

        let result = await runOsascript(script(for: player))
        let reading = reading(from: result, player: player)
        learn(from: result, reading: reading, player: player, now: now)
        return reading
    }

    /// What one run says about Automation for this player. Separate from
    /// `query` so it can be pinned without a player to script.
    static func learn(from result: ScriptResult, reading: PlayerReading, player: Player, now: TimeInterval) {
        switch (result, reading) {
        case (.denied(let detail), _):
            denials.recordDenial(player.bundleID, now: now)
            log.notice("""
                osascript: Automation for \(player.displayName, privacy: .public) is denied \
                (\(detail, privacy: .public)) — not asking again for \
                \(Int(AutomationDenialLatch.cooldown), privacy: .public)s
                """)
        case (_, .answered):
            // Only a real answer. An empty one can come from the script's own
            // `if it is not running` check, which no Apple Event reached.
            denials.recordAnswer(player.bundleID)
        default:
            break
        }
    }

    /// What one `osascript` run means for the card. Separated from `query` so
    /// every outcome can be pinned without a player to script: which of them
    /// count as the player having answered is the whole of the rule.
    static func reading(from result: ScriptResult, player: Player) -> PlayerReading {
        switch result {
        case .output(let output):
            // The script answers "" for a player that is not running or is
            // stopped, and that is an answer: nothing is playing there.
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .nothing }
            // Output that will not parse is not an answer. It is a corrupt or
            // unexpected sample, and acting on it either way would be a guess.
            guard let snapshot = parse(output, player: player) else { return .unreadable }
            return .answered(snapshot)
        case .denied:
            // Not allowed to ask, so nothing has been learned about what is
            // playing.
            return .unreadable
        case .failed:
            // A missed deadline, or a process that would not start. The player
            // was not heard from; it did not say it had nothing.
            return .unreadable
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
    /// Internal rather than private so the cancellation path can be tested
    /// end to end against a real `osascript`.
    ///
    /// Cancellation, the timeout and the escalation to SIGKILL all belong to
    /// `ChildProcess` now — this had its own copy of each, and the copy only
    /// ever sent SIGTERM, so a script stuck in IPC could outlive its deadline.
    static func runOsascript(_ source: String) async -> ScriptResult {
        let outcome = await ChildProcess.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", source],
            timeout: queryTimeout
        )

        if outcome.cancelled || outcome.failedToLaunch { return .failed }

        guard outcome.status == 0, !outcome.timedOut else {
            let detail = outcome.errorText
            // A denial is the caller's to log — once, when it latches — not an
            // error to repeat on every poll.
            if indicatesAutomationDenial(detail) { return .denied(detail) }
            if outcome.timedOut { return .failed }
            log.error("""
                osascript exited \(outcome.status, privacy: .public): \
                \(detail, privacy: .public)
                """)
            return .failed
        }

        return .output(outcome.outputText)
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

        let ownID = fields[6].isEmpty ? nil : TrackKey.identified(fields[6], by: player.bundleID)
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
            trackKey: ownID,
            artworkURL: artworkURL,
            // The one place a transport id is minted: this player's script,
            // answering for itself. The card's name may later be replaced by
            // one kept from another source; this never is.
            transportKey: ownID
        )
    }
}

/// Remembers which players the user has refused Automation for, so they are
/// not asked again on every poll — and which have answered a script, which is
/// the only evidence of a grant that costs no prompt to collect.
///
/// Pure and clock-injected so the policy is testable without a TCC prompt.
struct AutomationDenialLatch: Sendable {

    /// How long a refusal is believed before osascript is tried again. Long
    /// enough that a denied player costs nothing, short enough that granting
    /// access in System Settings is picked up without a relaunch.
    static let cooldown: TimeInterval = 600

    private var deniedUntil: [String: TimeInterval] = [:]

    /// Players that have answered a read since they last refused.
    private var answered: Set<String> = []

    init() {}

    /// The player answered, so Automation for it is granted.
    mutating func recordAnswer(_ bundleID: String) {
        answered.insert(bundleID)
    }

    /// Whether this player is known to take Apple Events from Ledge: it has
    /// answered, and has not refused since.
    ///
    /// Undecided and refused read the same here, on purpose. Either way an
    /// event is the wrong thing to send — refused, it does nothing at all;
    /// undecided, it is the Automation dialog.
    mutating func isKnownAllowed(_ bundleID: String, now: TimeInterval) -> Bool {
        answered.contains(bundleID) && !isDenied(bundleID, now: now)
    }

    /// The user granted Automation: any refusal believed is stale. What has
    /// answered still has.
    mutating func forgetDenials() {
        deniedUntil = [:]
    }

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
        // A grant taken back. Past the cooldown this player is undecided
        // again until it answers, not allowed.
        answered.remove(bundleID)
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
/// Prefers telling the specific app, which is the only way to address the
/// player on the card, wherever Automation is known to allow it. Otherwise
/// MediaRemote, which reaches whichever player the system considers current,
/// and so only when that is the card's player.
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

    /// Which player the system itself considers now-playing, read raw — see
    /// `CompositeNowPlayingSource.systemOwnerBundleID`. Nil means not known.
    ///
    /// Injected because this type knows how to *send* commands and nothing
    /// about who is playing, and because the honest answer comes from the
    /// adapter rather than from the card's own idea of the current player.
    /// The default says "not known", which is the safe answer: a commander
    /// nobody has told anything to refuses to aim an unaddressed command
    /// rather than firing it at whoever happens to hold the slot.
    private let systemOwner: @MainActor () -> String?

    /// How an unaddressed command is actually sent. Injected so the whole
    /// command boundary can be tested — including that nothing is dispatched
    /// on the paths that must refuse — without touching a real player.
    private let dispatchGlobally: @MainActor (NowPlayingCommand) -> Void

    /// Whether this player is known to take Apple Events from Ledge — see
    /// `ScriptingNowPlayingSource.isKnownAllowed`. Injected so a test can
    /// say either without a TCC decision behind it.
    private let automationAllows: @MainActor (String) -> Bool

    public convenience init(
        systemOwner: @escaping @MainActor () -> String? = { nil },
        dispatchGlobally: @escaping @MainActor (NowPlayingCommand) -> Void = {
            MediaRemoteBridge.send($0)
        }
    ) {
        self.init(
            systemOwner: systemOwner,
            dispatchGlobally: dispatchGlobally,
            automationAllows: { ScriptingNowPlayingSource.isKnownAllowed($0) }
        )
    }

    init(
        systemOwner: @escaping @MainActor () -> String?,
        dispatchGlobally: @escaping @MainActor (NowPlayingCommand) -> Void,
        automationAllows: @escaping @MainActor (String) -> Bool
    ) {
        self.systemOwner = systemOwner
        self.dispatchGlobally = dispatchGlobally
        self.automationAllows = automationAllows
    }

    /// What happened to a command offered to the scripting path.
    ///
    /// Three states rather than a Bool, because "it did not go" has two very
    /// different meanings and they must not share an answer. A player with no
    /// scripting dictionary is `unsupported`, and MediaRemote is the right
    /// fallback. A player whose command queue is saturated is `busy` — and
    /// falling back there would hand the command to whatever the system
    /// considers now-playing, which is the precise failure the scripting path
    /// exists to prevent: mashing pause on a Spotify card until its queue
    /// filled would start pausing a browser tab instead.
    enum ScriptingDispatch: Equatable {
        case queued
        case unsupported
        case busy
        /// A scriptable player that Automation is not known to allow:
        /// undecided, refused, or not yet heard from.
        case notAllowed
    }

    @discardableResult
    public func send(_ command: NowPlayingCommand, to bundleID: String) -> NowPlayingDispatch {
        // Scripting first, because it is the only path that targets the player
        // actually shown on the card. MediaRemote acts on whatever the system
        // considers now-playing, which can be a different app entirely — press
        // play on a Spotify card while a browser tab holds the now-playing slot
        // and MediaRemote toggles the browser.
        switch sendViaScripting(command, to: bundleID) {
        case .queued:
            // No stamp here. Admission is not dispatch: the queue holds up to
            // eight commands and a slow player can leave one waiting seconds.
            // Stamping on admission told the source its cached answer was
            // about to be wrong while the player had not yet been spoken to —
            // so it re-read, got the old state, and cached *that* as fresh.
            // `sendViaScripting` stamps when the work actually runs.
            return .queued

        case .busy:
            // Dropped on purpose. The player is not keeping up, and the one
            // thing worse than a missed press is a press that lands on someone
            // else's player. Nothing was dispatched, so the freshness stamp
            // must not move either.
            Self.log.notice("command dropped: \(bundleID, privacy: .public) has a full queue")
            return .refused

        case .unsupported, .notAllowed:
            // No scripting dictionary for this player (a browser, say), or no
            // Automation to use it with, so the only way left is MediaRemote.
            // Without Automation that is how the card's buttons work at all:
            // an Apple Event to a refused player did nothing, and to an
            // undecided one it put the Automation dialog up from a play
            // button.
            //
            // MediaRemote has no idea which player was meant. It acts on
            // whichever one the *system* considers now-playing, which is the
            // right one exactly when the system agrees with the card.
            //
            // It often does not. A native player with no scripting dictionary
            // can be held on the card — that is what `heldPlaying` is for —
            // while a browser tab holds the system's slot, and every press
            // then went to the tab: pausing a video the user was not looking
            // at and leaving the card's own player running. Unknown counts as
            // mismatched; a guess about who owns the slot is the one thing
            // that must not be acted on here.
            guard let owner = systemOwner(), owner == bundleID else {
                Self.log.notice("""
                    refusing an unaddressed command for \(bundleID, privacy: .public): \
                    the system is pointing at \(self.systemOwner() ?? "nobody", privacy: .public)
                    """)
                return .wrongPlayer
            }
            // Reported as unconfirmed even now: the symbol returns nothing, so
            // the command going out is all that is known about it. Seek used
            // to stop here for want of a symbol; `MRMediaRemoteSetElapsedTime`
            // does the job, so a browser tab can be scrubbed too.
            noteDispatch()
            dispatchGlobally(command)
            return .unconfirmed
        }
    }

    /// Marks that a command actually went somewhere, so the composite source
    /// knows its cached answer is about to be wrong. A command that was never
    /// dispatched has invalidated nothing, and moving the stamp for one would
    /// make the source discard a perfectly good reading.
    private func noteDispatch() {
        Self.noteDispatched()
    }

    /// The same mark, from the queue, at the moment the work actually runs.
    static func noteDispatched() {
        lastCommandAt = Date().timeIntervalSinceReferenceDate
    }

    /// A track id as an AppleScript string literal.
    ///
    /// Escaped rather than interpolated raw: a Spotify URI is tame, but this
    /// value reaches a script, and a quote or backslash arriving in it would
    /// end the literal and let the rest be read as code.
    nonisolated static func literal(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The AppleScript one transport command becomes. Pure, so what is sent
    /// can be checked without a queue, a player, or `osascript`.
    nonisolated static func transportScript(
        _ command: NowPlayingCommand,
        for player: ScriptingNowPlayingSource.Player
    ) -> String {
        let body: String
        switch command {
        case .playPause: body = "playpause"
        case .next: body = "next track"
        case .previous: body = "previous track"
        // Formatted explicitly: `Double.description` switches to scientific
        // notation for small values ("1e-05"), which AppleScript cannot parse.
        case .seek(let position, let item):
            // The guard and the write in one command, which is the only way
            // they can be about the same song. The queue can hold this for
            // seconds, and the player is free to move on in the meantime: a
            // scrub released on one song used to land on whichever song was
            // playing when the command finally ran.
            //
            // The item is the snapshot's `transportKey` — the player's own id,
            // from its own script — never the card's name for the song, which
            // may be MediaRemote's identifier kept from an earlier answer. The
            // player only knows its own id, so the id is what is compared.
            //
            // A seek with no id to check is still written, unguarded: a card
            // the script has not yet answered for, or a player that will not
            // say what it is playing, can still be scrubbed, which is how it
            // behaved before any of this. Sending it to MediaRemote instead
            // was the other choice, and the worse one: nothing has confirmed
            // that the system's seek reaches these players, and a scrub that
            // silently does nothing is the failure being fixed here.
            let write = String(format: "set player position to %.3f", position)
            if let item, let id = TrackKey.itemID(in: item, for: player.bundleID) {
                body = """
                if ((id of current track) as text) is not \(Self.literal(id)) then return
                    \(write)
                """
            } else {
                body = write
            }
        }

        return """
        tell application "\(player.scriptName)"
            if it is not running then return
            \(body)
        end tell
        """
    }

    func sendViaScripting(
        _ command: NowPlayingCommand,
        to bundleID: String
    ) -> ScriptingDispatch {
        guard let player = ScriptingNowPlayingSource.players.first(where: { $0.bundleID == bundleID })
        else {
            Self.log.debug("no scripting fallback for \(bundleID, privacy: .public)")
            return .unsupported
        }
        guard automationAllows(bundleID) else { return .notAllowed }

        let source = Self.transportScript(command, for: player)

        // Queued rather than fired and forgotten. Every press used to launch
        // its own process with no timeout and no bound, so a player that had
        // stopped answering collected one child per press. The queue keeps the
        // order — pause-then-next is not next-then-pause — and refuses once a
        // backlog says the player is not listening.
        let run = Self.runScript
        let queued = Self.commands.submit {
            // The stamp belongs here, where the player is actually spoken to,
            // and not back at admission: between the two there can be seven
            // other commands and a player that is not answering.
            await MainActor.run { Self.noteDispatched() }
            await run(source)
        }
        return queued ? .queued : .busy
    }

    /// One at a time, in order, with a bound.
    ///
    /// A `var` so a test can substitute a runner that refuses everything, which
    /// is how "the player's queue is full" is reproduced without racing a real
    /// consumer to keep it that way.
    static var commands = SerialCommandRunner()

    /// A transport command is a single AppleScript verb against a running app.
    /// Longer than this and the player is not answering.
    private static let commandTimeout: TimeInterval = 5

    /// How a queued transport script is actually run.
    ///
    /// A `var` for the same reason `commands` is one: a test can take
    /// `osascript`'s place and watch *when* the work happens, which is the
    /// whole point of stamping at dispatch rather than at admission — and it
    /// can do so without spawning a subprocess at a player the user is
    /// listening to.
    static var runScript: @Sendable (String) async -> Void = { source in
        let outcome = await ChildProcess.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", source],
            timeout: commandTimeout,
            captureOutput: false
        )
        if !outcome.succeeded {
            log.debug("""
                transport command exited \(outcome.status, privacy: .public)\
                \(outcome.timedOut ? " (timed out)" : "", privacy: .public)
                """)
        }
    }
}
