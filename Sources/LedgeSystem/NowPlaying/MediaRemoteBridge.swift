import Foundation
import os

/// Access to `MediaRemote.framework`, which is private and partly gated.
///
/// Reads and writes are gated differently, and that asymmetry is the useful
/// part:
///
/// - **Reads** (`MRMediaRemoteGetNowPlayingInfo`) return a NULL dictionary
///   unless the calling process is signed with a `com.apple.*` identifier.
///   Verified on macOS 26.4 against this project's own Apple Development
///   identity: symbols present, dictionary NULL. So reads are unusable, and
///   `NowPlayingSourceSelector` falls back to AppleScript.
/// - **Commands** (`MRMediaRemoteSendCommand`) are a separate, un-gated code
///   path, so transport control works even though reading does not.
///
/// Every symbol is looked up defensively. A missing one costs one feature, not
/// the app.
public enum MediaRemoteBridge {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "mediaremote")

    private typealias GetNowPlayingInfo =
        @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
    private typealias SendCommand = @convention(c) (Int, [String: Any]?) -> Bool
    private typealias SetElapsedTime = @convention(c) (Double) -> Void

    /// `MRMediaRemoteCommand` values. Only the ones actually used are listed.
    private enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    /// Whether reads actually return anything for *this* process.
    ///
    /// The symbol being present proves nothing — the gate shows up as a
    /// callback that fires with a NULL dictionary, not as a missing symbol or a
    /// crash. So the only honest test is to call it and look.
    ///
    /// Note the deliberate ambiguity: nothing playing also yields no
    /// dictionary. This returns `true` only on a definite non-nil answer, so a
    /// false negative just means falling back to AppleScript, which is the
    /// safe direction to be wrong in.
    public static func probeReadAccess(timeout: TimeInterval = 2) async -> Bool {
        guard let pointer = PrivateSymbol.lookup(
            "MRMediaRemoteGetNowPlayingInfo",
            in: .mediaRemote,
            as: GetNowPlayingInfo.self
        ) else {
            log.notice("read probe: symbol missing")
            return false
        }

        let result: Bool = await withCheckedContinuation { continuation in
            let hasResumed = OSAllocatedUnfairLock(initialState: false)

            // Resumes exactly once, whichever of the callback or the timeout
            // arrives first. A continuation resumed twice is a crash.
            // `@Sendable`: reached from the MediaRemote callback queue and from
            // the timeout. It touches only the lock and the continuation.
            @Sendable func finish(_ value: Bool) {
                let shouldResume = hasResumed.withLock { resumed -> Bool in
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(returning: value)
            }

            pointer(DispatchQueue.global()) { info in
                finish(info != nil)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }

        log.notice("read probe: \(result ? "readable" : "gated or idle", privacy: .public)")
        return result
    }

    /// Sends a transport command, best-effort.
    ///
    /// Returns `Void`, not `Bool`, deliberately. `MRMediaRemoteSendCommand`
    /// returns an unconditional `true` — the implementation on macOS 26.4 tail-
    /// calls into `MRMediaRemoteSendCommandToApp` and then moves `#1` into the
    /// return register regardless of outcome. Treating that as "it worked" made
    /// the scripting fallback unreachable and let the app report success for a
    /// command that went nowhere.
    ///
    /// It is also not addressed: MediaRemote routes to whatever the *system*
    /// considers now-playing, which is not necessarily the player on the card.
    /// So this is the opportunistic path, and the caller still targets the app
    /// directly.
    public static func send(_ command: NowPlayingCommand) {
        // Seek is a separate symbol with its own signature, so it is handled
        // before the command table. This is what makes the scrub bar work for a
        // player AppleScript cannot reach — a YouTube tab, say.
        if case .seek(let position) = command {
            guard let setElapsed = PrivateSymbol.lookup(
                "MRMediaRemoteSetElapsedTime",
                in: .mediaRemote,
                as: SetElapsedTime.self
            ) else {
                log.debug("seek: MRMediaRemoteSetElapsedTime missing")
                return
            }
            setElapsed(position)
            return
        }

        guard let send = PrivateSymbol.lookup(
            "MRMediaRemoteSendCommand",
            in: .mediaRemote,
            as: SendCommand.self
        ) else {
            log.error("send: MRMediaRemoteSendCommand missing")
            return
        }

        switch command {
        case .playPause: _ = send(Command.togglePlayPause.rawValue, nil)
        case .next: _ = send(Command.nextTrack.rawValue, nil)
        case .previous: _ = send(Command.previousTrack.rawValue, nil)
        case .seek:
            // Handled above, by the elapsed-time setter rather than a command.
            break
        }
    }
}
