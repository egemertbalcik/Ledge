import Foundation

/// How a permission reads, and the one thing that can move it.
///
/// Pure, and in `LedgeCore`, because three places have to agree about it: the
/// Permissions pane, a card's own page, and the welcome tour. They used to
/// decide separately, and they disagreed — a grant that macOS had not handed
/// over yet read "Granted" in one place, a dead switch in another, and had no
/// explanation in either.
public enum PermissionTone: String, Equatable, Sendable {
    case ok
    case attention
    case problem
    /// Nothing is wrong and nothing can be done here.
    case quiet
}

/// The single thing a row offers. One at most: a row with two buttons is a
/// row that has not decided what the problem is.
public enum PermissionRemedy: String, Equatable, Sendable, CaseIterable {

    /// Show macOS's own prompt.
    case ask

    /// Open Privacy & Security at this permission.
    case openSettings

    /// Open Music, so Automation has something to be asked about.
    case openPlayer

    public var label: String {
        switch self {
        case .ask: "Allow…"
        case .openSettings: "Open System Settings…"
        case .openPlayer: "Open Music…"
        }
    }
}

/// What one permission row says and offers.
public struct PermissionFace: Equatable, Sendable {

    public var tone: PermissionTone

    /// The state, in one phrase. Never colour alone: this is always drawn.
    public var word: String

    /// Why it is in that state, or what to do about it. Nil when the word
    /// says everything.
    public var note: String?

    public var remedy: PermissionRemedy?

    public init(
        tone: PermissionTone,
        word: String,
        note: String? = nil,
        remedy: PermissionRemedy? = nil
    ) {
        self.tone = tone
        self.word = word
        self.note = note
        self.remedy = remedy
    }
}

public enum PermissionCopy {

    /// While macOS's own prompt is up.
    public static let waitingForAnswer = "Waiting for your answer…"

    /// While the person is in System Settings. There is no timeout on this:
    /// they may take as long as they take.
    public static let waitingInSettings = "Waiting for you in System Settings…"

    public static let askedOnce =
        "macOS asks only once. The switch is in Privacy & Security"

    public static let restricted =
        "A profile on this Mac decides this one, so there is nothing to change here. Whoever manages the Mac can allow it."

    public static let addOnly =
        "Ledge can add events but can't read them, so the calendar card stays hidden. Choose Full Access in System Settings."

    public static let accessibilityIsManual =
        "Switched on in System Settings, not in a prompt. Ledge opens the right place."

    public static let automationNeedsAPlayer =
        "Automation is granted per app, and asking about a closed one would launch it."

    /// Where the switch lives, for the sentence under a refusal.
    public static func switchLives(_ kind: PermissionKind) -> String {
        "\(askedOnce) › \(settingsPaneName(kind))."
    }

    /// The name of the System Settings list this permission is in.
    public static func settingsPaneName(_ kind: PermissionKind) -> String {
        switch kind {
        case .accessibility: "Accessibility"
        case .automation: "Automation"
        case .calendars: "Calendars"
        case .bluetooth: "Bluetooth"
        case .location: "Location Services"
        case .focusStatus: "Focus"
        }
    }
}

public enum PermissionPresentation {

    /// The face for a reading.
    ///
    /// - Parameters:
    ///   - isInEffect: whether a grant has actually reached the app.
    ///
    ///     It no longer changes the face, and the parameter is kept only so
    ///     the callers that have the fact can keep passing it. The face it
    ///     used to produce — "Granted, not in effect yet", with Quit and
    ///     Reopen — cannot be detected: Accessibility's *status* is
    ///     `MediaKeyInterceptor.isTrusted`, and so is this, so the two can
    ///     only disagree between two reads. The state it was written for, a
    ///     switch macOS has not handed over, is unknowable from inside the
    ///     app, and the combination that offered the remedy was unreachable.
    ///     What it actually produced was a relaunch offered after a *revoked*
    ///     grant. Said here rather than deleted quietly, because the next
    ///     person to meet a dead switch will reach for it again.
    ///   - waitingFor: what the row is waiting on, if a press has just sent
    ///     the person somewhere. It outranks everything else, because a
    ///     second prompt must not be offered while the first is up.
    ///   - cameBackStillOff: whether the person has come back from System
    ///     Settings during a handoff for this permission and the reading has
    ///     not moved. Said instead of the state they started in, because
    ///     "Not requested" is wrong twice over by then — they did request it,
    ///     and the commonest reason it is still off is a list holding an
    ///     older copy of Ledge, which nothing in the app can read.
    public static func face(
        _ kind: PermissionKind,
        status: PermissionStatus,
        isInEffect: Bool = true,
        waitingFor: String? = nil,
        cameBackStillOff: Bool = false
    ) -> PermissionFace {
        if let waitingFor {
            return PermissionFace(tone: .quiet, word: waitingFor)
        }
        // Only while the switch really is still off. A grant that landed, or
        // a refusal, has its own face and says more than this one.
        if cameBackStillOff, status == .notDetermined {
            return PermissionFace(
                tone: .attention,
                word: PermissionGuideCopy.stillOff,
                note: PermissionGuideCopy.stillOffNote,
                remedy: .openSettings
            )
        }
        switch status {
        case .granted:
            return PermissionFace(tone: .ok, word: status.summary)
        case .notDetermined:
            // Accessibility has no prompt worth showing: macOS shows it at
            // most once in the app's life, and the switch is in System
            // Settings either way.
            return kind.isGrantedInSystemSettings
                ? PermissionFace(
                    tone: .attention,
                    word: status.summary,
                    note: PermissionCopy.accessibilityIsManual,
                    remedy: .openSettings
                )
                : PermissionFace(tone: .attention, word: status.summary, remedy: .ask)
        case .denied:
            return PermissionFace(
                tone: .problem,
                word: status.summary,
                note: PermissionCopy.switchLives(kind),
                remedy: .openSettings
            )
        case .restricted:
            // No button: System Settings would only show a greyed-out switch,
            // and sending somebody there to find that out is worse than the
            // sentence.
            return PermissionFace(
                tone: .quiet,
                word: status.summary,
                note: PermissionCopy.restricted
            )
        case .addOnly:
            return PermissionFace(
                tone: .attention,
                word: status.summary,
                note: PermissionCopy.addOnly,
                remedy: .openSettings
            )
        case .notApplicableNow:
            // Only Automation is ever per-app, and only Automation has a
            // player to open. An earlier version of this decision guarded on
            // `isRequestable`, which is true of everything — so a Calendar
            // row in this state offered to open Music.
            guard kind == .automation else {
                return PermissionFace(tone: .quiet, word: status.summary)
            }
            return PermissionFace(
                tone: .quiet,
                word: status.summary,
                note: PermissionCopy.automationNeedsAPlayer,
                remedy: .openPlayer
            )
        case .unavailable:
            return PermissionFace(tone: .quiet, word: status.summary)
        }
    }

    /// Whether this reading is one the person could still do something about.
    /// What the Permissions pane counts when it says how many are waiting.
    public static func isWaitingOnSomebody(
        _ kind: PermissionKind,
        status: PermissionStatus,
        isInEffect: Bool = true
    ) -> Bool {
        face(kind, status: status, isInEffect: isInEffect).remedy != nil
    }
}
