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

    /// What the card says under the title for a hold with no end. The card is
    /// a switch, and this is the honest answer to "until when".
    public static let runningUntilSwitchedOff = "Until you switch it off"

    /// How long an open-ended hold has been running. "Awake for 2h 14m" reads
    /// as a fact about the Mac; the same number without it reads as a
    /// countdown, which is the one thing it is not.
    public static func heldFor(_ label: String) -> String { "Awake for \(label)" }

    /// What is left, in the units it was set in.
    ///
    /// A two-day session counted in hours reads "51h 15m", which is true and
    /// useless: nobody holds fifty-one hours in their head. The days come
    /// back out, and a field is left off once it has nothing to say.
    public static func remainingLabel(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded()))
        let minutes = total / 60
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let mins = minutes % 60
        if days > 0 { return "\(days)d \(pad(hours))h \(pad(mins))m" }
        if hours > 0 { return "\(hours)h \(pad(mins))m" }
        // The last minute counts down in seconds. Rounding it to "0m" told
        // the user it was over while the Mac was still being held awake.
        if minutes == 0 { return "0:\(pad(total % 60))" }
        return "\(mins)m"
    }

    /// The same span with no room to say it in: the ear beside the island, and
    /// the compact face.
    ///
    /// Short by design — one unit, two at most. The timer's own label stops at
    /// 99h 59m, which turned a seven-day session into "99h 59m" rather than
    /// "7d".
    public static func compactRemainingLabel(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded()))
        let minutes = total / 60
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        // A whole hour says so in one unit: the ear is a few characters wide
        // and "1h 00m" spends two of them on a zero.
        if hours > 0 {
            let mins = minutes % 60
            return mins > 0 ? "\(hours)h \(pad(mins))m" : "\(hours)h"
        }
        if minutes == 0 { return "0:\(pad(total % 60))" }
        return "\(minutes)m"
    }

    private static func pad(_ value: Int) -> String { String(format: "%02d", value) }

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

    // MARK: - Lid closed

    /// The subordinate mode's name, on the card and in Settings. Two words,
    /// because it has to sit beside Start without competing with it.
    public static let lidClosed = "Lid closed"

    /// What the card asks once the lid-closed mode has been chosen.
    ///
    /// Naming the mode in the question is the whole reason the length picker
    /// needs no label of its own: the boxes belong to this mode and to nothing
    /// else, and the line above them says which mode that is.
    public static let howLongLidClosed = "How long, with the lid shut?"

    /// Backing out of the question without starting anything.
    public static let cancel = "Cancel"

    /// Under the length boxes, once there is a length to say it about. Short
    /// by necessity — it shares a 275-point card with three numbers.
    public static func lidEndsAt(floor: Int) -> String { "Ends at \(floor)% battery" }

    /// Why a lid-closed hold always has a length.
    ///
    /// Said in Settings rather than on the card, where there is room for the
    /// reason as well as the rule.
    public static let lidNeedsALength =
        "A lid-closed hold always has an end time. An indefinite one on battery is how a "
            + "Mac cooks in a bag, so Ledge asks how long instead of assuming."

    /// Every lid-closed state as a sentence, or nil when the state has nothing
    /// of its own to say and the standing line should stand.
    ///
    /// One sentence per answer the daemon can give, which is the whole reason
    /// there are nine answers: "it didn't work" names nothing to do next.
    /// Every sentence here says what happened and what would change it.
    public static func lid(_ state: KeepAwakeLidState) -> String? {
        switch state {
        case .off: nil
        case .unsignedBuild: lidUnsignedBuild
        case .notInstalled: lidNotInstalled
        case .holding: lidHolding
        case .unconfirmed: lidUnconfirmed
        case .refused(let code): lidRefused(code)
        }
    }

    /// `SMAppService` will not register a daemon out of an ad-hoc signed
    /// bundle, so this is a fact about the build rather than a failure to fix.
    /// It names the one thing that changes it.
    public static let lidUnsignedBuild =
        "This build of Ledge isn't signed, and macOS only installs the lid-closed helper "
            + "from a signed one. A release build can do it."

    /// A one-time setup, named and placed. Nothing about it happens on the
    /// card, so the card says where it does happen.
    public static let lidNotInstalled =
        "Holding your Mac awake with the lid shut needs a one-time setup. "
            + "Settings › Keep Awake has it."

    /// The mode is on and the daemon says so.
    public static let lidHolding = "Staying awake with the lid shut."

    /// The honest sentence for silence.
    ///
    /// The hold is almost certainly standing: the daemon lets go on its own
    /// lease, not on Ledge's inability to reach it. So this says what is true
    /// — the hold stands, we cannot confirm it — and does not say the Mac is
    /// about to sleep, which would be alarming, actionable in exactly the
    /// wrong direction, and wrong.
    public static let lidUnconfirmed =
        "Ledge can't reach the helper to check on the hold. It almost certainly still "
            + "stands, and Ledge is still trying."

    /// Each refusal, as something to do next.
    public static func lidRefused(_ code: KeepAwakeLidCode) -> String {
        switch code {
        case .foreign:
            // No blame and no undoing. Sleep is disabled, nothing of Ledge's
            // explains it, and taking it back would be Ledge reversing a
            // choice it did not make. The sentence names the places that
            // choice is usually made, so there is somewhere to go and look.
            "Something else is already keeping this Mac awake — another app, or pmset in "
                + "Terminal. Ledge didn't set that and won't change it."
        case .inUseByOtherLedge:
            "The other build of Ledge is holding this Mac awake. End it there, or quit it, "
                + "and try again."
        case .stale:
            "The hold lapsed while Ledge wasn't able to renew it. Switch Lid closed on "
                + "again to take it back."
        case .busy:
            "The helper has more to answer than it can keep up with. Give it a moment and "
                + "try again."
        case .persistFailed:
            "The helper couldn't write the hold down, so it didn't take it — nothing on "
                + "your Mac changed. Try again."
        case .pmsetFailed:
            "macOS wouldn't change the sleep setting, so nothing changed. Try again."
        case .notHolder:
            "The helper is holding a different session, so this one has nothing to renew. "
                + "Switch Lid closed on again."
        case .invalidArgument:
            // A bug on Ledge's side. Saying so is more use than a vague
            // apology: it tells the user the fault is not theirs, and that
            // trying again costs nothing.
            "Ledge asked for a hold the helper wouldn't accept, so nothing changed. "
                + "That's a bug in Ledge. Trying again is safe."
        }
    }

    // MARK: - The lid-closed menu-bar item

    /// The menu's first line while the hold is live.
    public static func lidMenuHeadline(remaining: String) -> String {
        "Awake with the lid shut — \(remaining) left"
    }

    /// The same, for a hold with nothing counting down. The lid-closed mode
    /// always sets a length, so this is the belt to that brace.
    public static let lidMenuHeadlineOpenEnded = "Awake with the lid shut"

    /// The one thing the menu does. Named for the whole act rather than for
    /// the helper: from the menu bar there is no card nearby to make "End"
    /// mean anything in particular.
    public static let lidMenuEnd = "Let this Mac sleep"

    /// What the Keep Awake pane says about the helper's state.
    public static func lidInstallation(_ state: KeepAwakeHelperInstallation) -> String {
        switch state {
        case .unsignedBuild: lidUnsignedBuild
        case .notInstalled: lidNotInstalled
        case .installed: "Set up. Keep Awake can hold your Mac awake with the lid shut."
        }
    }

    /// The continuity policy, stated where the user can find it rather than
    /// left to be discovered by losing a session.
    public static let continuityPolicy =
        "Keep Awake continues if Ledge restarts. "
            + "It ends when you press End, quit Ledge, or restart your Mac."

    public static let settingsSummary = "Keeps your Mac awake for as long as you choose."

    // MARK: - Actions

    public static let start = "Start"
    public static let end = "End"

    /// Asked once Start has been pressed and before anything is held: the card
    /// is now a question, and the line under the title says which one.
    public static let howLong = "How long?"

    /// The button that actually begins it. Named for what it does rather than
    /// repeating "Start", so the second press is plainly a different act from
    /// the first.
    public static let keepAwake = "Keep awake"

    /// Said under the boxes, and as each box's accessibility hint. A control
    /// that is only a number explains nothing about how to change it.
    public static let boxHint = "Drag a number up or down"

    /// The floor, stated rather than applied silently.
    public static let minimumLength = "Minimum 5 minutes"

    /// The one word a half-width card has room for.
    public static let ended = "Ended"
    public static let done = "Done"
    public static let title = "Keep Awake"
}
