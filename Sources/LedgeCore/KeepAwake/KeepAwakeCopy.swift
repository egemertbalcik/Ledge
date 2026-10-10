import Foundation

/// Every sentence Keep Awake says, in one place.
///
/// Gathered here for two reasons. The recipe asks each unavailable or finished
/// state to be a distinct sentence that says what happens next, and a test can
/// only hold that line if the sentences are reachable without building a view.
/// And a power feature that ends on its own has to explain itself in the words
/// of the person it happened to: what Ledge did, what their Mac will do now,
/// and what they can do about it.
public enum KeepAwakeCopy {

    // MARK: - Ready

    public static let readyLidOpen = "Closing the lid will still put your Mac to sleep."
    public static func readyLidHeld(floor: Int) -> String {
        "Stays awake with the lid closed, until the battery reaches \(floor)%."
    }

    /// The assertion was refused, so nothing changed. Phrased as something to
    /// try again rather than as a fault, because there is nothing to fix.
    public static let assertionRefused =
        "macOS didn't accept the request to stay awake, so nothing changed. Try Start again."

    /// The journal refused the start write. Nothing was acquired.
    public static let startNotSaved =
        "Ledge couldn't save the session, so nothing changed. Try Start again."

    /// Enough sessions are waiting to be written down that starting another
    /// would risk losing the record of one. Says what has to happen rather
    /// than asking for a retry that cannot work yet.
    public static let tooManyUnsaved =
        "Ledge still can't write to the disk, so it won't start another session until it can."

    // MARK: - Running

    public static func runningUntil(_ time: String) -> String { "Until \(time)" }

    public static func resumed(remaining: String, until time: String) -> String {
        "Keep Awake resumed. \(remaining) left, until \(time)."
    }

    // MARK: - Finished

    /// One sentence per reason. Each says what happened and what the Mac will
    /// do now, because "ended" alone leaves the user guessing whether their
    /// machine is about to sleep.
    public static func finished(_ reason: KeepAwakeEndReason,
                                at time: String,
                                floor: Int,
                                lidClosed: Bool) -> String {
        switch reason {
        case .timeUp:
            "Finished at \(time). Your Mac can sleep again."
        case .endedByYou:
            "Ended. Your Mac can sleep again."
        case .batteryFloor:
            "Ended at \(floor)% battery so your Mac can sleep before it runs out."
        case .batteryUnreadable:
            "Ended because the battery level couldn't be read twice in a row. "
                + "Your Mac can sleep again."
        case .thermal:
            lidClosed
                ? "Ended because your Mac got too hot. Open the lid and give it air."
                : "Ended because your Mac is very hot."
        case .macRestarted:
            "Ended when your Mac restarted."
        case .ledgeNotRunning:
            "Ended at \(time) while Ledge wasn't running. Your Mac was free to sleep from then."
        case .sleepChangedElsewhere:
            "Ended because another app or a Terminal command changed the sleep setting. "
                + "Ledge didn't change it back."
        case .quit, .turnedOff:
            // No card is shown for these; the surface is gone. The sentence
            // exists so the summary line in Settings has something to say.
            "Ended."
        }
    }

    /// Added to the Finished card when the end could not be written down.
    ///
    /// It promises nothing it cannot keep: a relaunch *may* bring the session
    /// back, and the user is told before it happens rather than surprised by
    /// it afterwards.
    public static func endNotSaved(until time: String) -> String {
        "Ledge couldn't save that this session ended. "
            + "If Ledge restarts before it can, Keep Awake may start again until \(time)."
    }

    public static func resumeButton(remaining: String) -> String { "Resume (\(remaining) left)" }

    /// Shown once when the journal could not be read at all.
    public static let journalUnreadable =
        "Ledge couldn't read the last Keep Awake session, so it didn't resume it."

    // MARK: - Settings

    /// The continuity policy, stated where the user can find it rather than
    /// left to be discovered by losing a session.
    public static let continuityPolicy =
        "Keep Awake continues if Ledge restarts. "
            + "It ends when you press End, quit Ledge, or restart your Mac."

    public static let settingsSummary = "Keeps your Mac awake for as long as you choose."

    // MARK: - Actions

    public static let start = "Start"
    public static let end = "End"
    public static let done = "Done"
    public static let title = "Keep Awake"
}
