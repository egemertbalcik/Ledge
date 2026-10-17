import Foundation

/// The words for a grant that happens in System Settings, and for the one
/// folder Ledge asks for in an open panel.
///
/// Apart from the rest of `PermissionCopy` because these are not a row's
/// words: they belong to the guide that opens when somebody has been sent to
/// another app, which the tour and the Permissions pane both draw.
public enum PermissionGuideCopy {

    /// What to do, once there. The list is a diagram, so the sentence has to
    /// carry the instruction on its own.
    public static func caption(_ kind: PermissionKind) -> String {
        kind == .accessibility
            ? "Find Ledge in the list and switch it on. macOS asks for your password or Touch ID, and Ledge notices by itself."
            : "Find Ledge under \(PermissionCopy.settingsPaneName(kind)) and switch it on. Ledge notices by itself."
    }

    /// macOS's own one-time Accessibility message, mentioned once because it
    /// is what puts Ledge in the list at all.
    public static let firstTime = """
        The first time, macOS also shows its own Accessibility message on top. \
        Either of its buttons leaves you at this same list.
        """

    /// Said under the diagram, every time. Drawing a copy of another app's
    /// window and letting somebody mistake it for the real one would be worse
    /// than drawing nothing.
    public static let isADiagram = "A diagram of where to look, not a picture of System Settings."

    /// The list's own title in the diagram.
    public static let allPermissions = "All permissions"

    public static let notInList = "Ledge isn't in the list?"
    public static let notInListBody = """
        Drag this into the list. Or press + under the list and choose Ledge in \
        Applications: Copy Location puts its address on the clipboard for the Go \
        to Folder box (⌘⇧G).
        """

    public static let tileName = "Ledge"
    public static let tileHint = "Drag into the list"
    public static let copyLocation = "Copy Location"
    public static let openAgain = "Open System Settings Again"
    public static let stopWaiting = "Stop Waiting"

    /// Ledge became active again during a handoff and the probe still says no.
    /// Not a failure: the commonest cause is a list holding an older copy of
    /// Ledge, which looks switched on and grants nothing. Nothing in the app
    /// can read that list, so this is said rather than detected.
    public static let stillOff = "Still off"
    public static let stillOffNote = """
        Ledge isn't switched on yet. If the list already shows Ledge switched on, \
        it's holding an older copy of Ledge: select it, press −, then drag this \
        one in.
        """

    public static let dropMissed = "That didn't land in the list. Drop it on the list of apps in System Settings."
    public static let dropLandedElsewhere = """
        It landed outside System Settings. If that was a Finder window, it left an \
        alias of Ledge there, which is safe to delete.
        """

    /// When Ledge is running from the disk image or a translocated path. The
    /// list would hold a copy that disappears with the image, which looks
    /// exactly like a grant that stopped working.
    public static let moveFirst = "Move Ledge to Applications first"
    public static let moveFirstNote = """
        Ledge is running from the disk image, so the list would hold a copy that \
        disappears when the disk image does. Drag Ledge to Applications, open it \
        from there, and come back.
        """

    public static func copied(_ path: String) -> String { "Copied \(path)" }

    // MARK: What the notch says during a handoff

    /// Ledge is an accessory: no Dock icon, no Cmd-Tab entry. The window that
    /// sent somebody to System Settings cannot be found again by the usual
    /// means, so the notch — the one piece of Ledge that is always in the same
    /// place — holds the thread while they are gone.
    public static func waitingTitle(_ name: String) -> String { "Waiting for \(name)" }

    public static let waitingDetail =
        "Switch Ledge on in System Settings. Click here to bring Ledge back."

    /// Said in the notch, where it is seen with System Settings still in
    /// front, and where Ledge lives.
    public static func arrivedTitle(_ name: String) -> String { "\(name) is on" }

    public static func arrivedDetail(_ kind: PermissionKind) -> String {
        kind == .accessibility
            ? "The volume and brightness keys now show Ledge's readout."
            : "Ledge noticed by itself. Nothing else to do."
    }

    /// How long the arrival card holds. A little longer with Reduce Motion
    /// on, where it neither springs in nor springs out.
    public static func arrivalHold(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 3.4 : 2.8
    }
}

/// Where the one folder Ledge asks for stands.
///
/// Five states, because the open panel has four endings and the folder does
/// not always exist: macOS makes it the first time a Focus is used.
public enum FocusFolderState: Equatable, Sendable {

    /// Never given, and the folder exists to give.
    case notGranted

    /// No Focus has ever been turned on, so there is nothing to hand over.
    case noFolderYet

    /// The panel is up.
    case waiting

    /// Something else was picked. Ledge kept nothing — it used to keep
    /// whatever was chosen, hold its scope open for the life of the process,
    /// and go on saying "Not granted" with no word about why.
    case wrongFolder(picked: String)

    case granted
}

/// What the Focus folder row says and offers.
///
/// Its own type rather than a `PermissionFace` because its button is not one
/// of the three system remedies: this grant is an open panel, not a switch.
public struct FocusFolderFace: Equatable, Sendable {

    public var tone: PermissionTone
    public var word: String
    public var note: String
    /// The button, when there is one to offer.
    public var button: String?

    public init(tone: PermissionTone, word: String, note: String, button: String? = nil) {
        self.tone = tone
        self.word = word
        self.note = note
        self.button = button
    }
}

public enum FocusFolderCopy {

    public static let choose = "Choose Folder…"
    public static let chooseAnother = "Choose a Different Folder…"

    /// The panel's own message and approve button.
    public static let panelMessage = """
        Give Ledge this one folder, so the Focus card is immediate and shows the \
        mode's name.
        """
    public static let panelPrompt = "Grant Access"

    public static func face(_ state: FocusFolderState) -> FocusFolderFace {
        switch state {
        case .notGranted:
            FocusFolderFace(
                tone: .attention,
                word: "Not granted",
                note: "Optional. Without it the Focus card checks every few seconds and reads \u{201C}Focus\u{201D}.",
                button: choose
            )
        case .noFolderYet:
            // No button: the panel would open on a folder that is not there,
            // and the only way forward is to use a Focus once.
            FocusFolderFace(
                tone: .quiet,
                word: "Turn a Focus on first",
                note: """
                    macOS makes this folder the first time a Focus is used. Turn one on, \
                    then come back; there's nothing to give Ledge yet.
                    """
            )
        case .waiting:
            FocusFolderFace(
                tone: .quiet,
                word: "Waiting for you in the folder window…",
                note: "The window opens on the right folder already. Press Grant Access."
            )
        case .wrongFolder(let picked):
            FocusFolderFace(
                tone: .attention,
                word: "That wasn't the Focus folder",
                note: """
                    You chose \(picked), so Ledge kept nothing. The window opens on the \
                    right folder; press Grant Access without moving.
                    """,
                button: choose
            )
        case .granted:
            FocusFolderFace(
                tone: .ok,
                word: "Granted",
                note: "Ledge reads ~/Library/DoNotDisturb/DB and nothing else.",
                button: chooseAnother
            )
        }
    }
}
