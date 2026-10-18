import AppKit
import Foundation

/// The one fact this policy needs about a player's process.
///
/// A protocol rather than `NSRunningApplication` directly so the rule below
/// can be tested: a real running application cannot be conjured up in a test,
/// and the one thing worth asserting here is what happens when the lookup
/// disagrees with the process.
public protocol PlayerProcess: AnyObject {
    var isTerminated: Bool { get }
}

extension NSRunningApplication: PlayerProcess {}

/// Whether a supported player is running, given a lookup that lies.
///
/// `NSRunningApplication.runningApplications(withBundleIdentifier:)` comes back
/// empty for a single poll every so often while the process is plainly still
/// there. Measured on macOS 26 against Spotify: 553 polls at 50ms, two empty
/// answers, the same pid before and after each. Every one of those answers
/// used to read as "the player has quit" — the card was retracted, the island
/// closed, and a paused track's whole two-minute courtesy was spent on a gap
/// nobody saw.
///
/// So the process is asked instead of the list. `isTerminated` belongs to the
/// application object the lookup handed over when it last worked, and across
/// those same 553 polls it was never wrong. Consulting it launches nothing,
/// which is the reason the running check exists in the first place: telling a
/// stopped app anything would open it, and an overlay that opens Spotify on
/// its own would be indefensible.
///
/// The memory is per player and holds exactly one object each — the process,
/// not a timestamp, because a deadline would have to guess how long a blink
/// lasts and the process already knows.
public struct PlayerLiveness {

    private var seen: [String: any PlayerProcess] = [:]

    public init() {}

    /// Whether this player counts as running.
    ///
    /// - Parameters:
    ///   - bundleID: the player.
    ///   - found: what the running-application lookup returned, or nil when it
    ///     returned nothing — which may mean the player has quit, or may be
    ///     the lookup blinking.
    public mutating func isRunning(_ bundleID: String, found: (any PlayerProcess)?) -> Bool {
        if let found {
            seen[bundleID] = found
            return true
        }
        // Never seen running, so there is nothing to disbelieve the lookup
        // with, and nothing to launch by trying.
        guard let known = seen[bundleID] else { return false }
        guard !known.isTerminated else {
            // Gone for real. Releasing it changes no answer — a dead process
            // keeps saying so, and a new one arrives through the branch above
            // and overwrites this — so this line is housekeeping rather than
            // policy: nothing holds a terminated application for the rest of
            // the session.
            seen[bundleID] = nil
            return false
        }
        return true
    }
}
