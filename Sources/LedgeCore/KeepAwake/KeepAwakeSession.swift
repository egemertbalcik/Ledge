import Foundation

/// Why a Keep Awake session stopped.
///
/// Every reason gets its own sentence in `KeepAwakeCopy`, because a session
/// that ends on its own is a system-wide power change the user did not ask for
/// at that moment, and "Keep Awake ended" alone does not tell them whether
/// their Mac is about to sleep, whether their work survived, or what to do.
public enum KeepAwakeEndReason: String, Equatable, Sendable, Codable, CaseIterable {
    /// The deadline arrived while Ledge was running.
    case timeUp
    /// The End button. The only reason a session can be resumed from.
    case endedByYou
    /// Battery fell to the floor while not charging.
    case batteryFloor
    /// The battery level could not be read twice in a row.
    case batteryUnreadable
    /// The Mac got too hot.
    case thermal
    /// A different boot: the Mac restarted while the session was recorded.
    case macRestarted
    /// The deadline passed while Ledge was not running.
    case ledgeNotRunning
    /// Ledge was quit.
    case quit
    /// The card was switched off, or settings were reset.
    case turnedOff
    /// Phase 2: something outside Ledge changed the sleep setting.
    case sleepChangedElsewhere

    /// Whether the Finished card is worth showing at all.
    ///
    /// Quitting and switching the card off both remove the surface the card
    /// would appear on, so there is nobody to tell.
    public var isVisible: Bool {
        switch self {
        case .quit, .turnedOff: false
        default: true
        }
    }

    /// Whether this is the user's own cancellation, and so recoverable.
    public var isUserCancellation: Bool { self == .endedByYou }
}

/// A running Keep Awake session.
///
/// The deadline is absolute wall-clock time rather than a duration counted
/// down, so it survives sleep, a relaunch and a clock change: the only question
/// ever asked is "is it later than this yet", which has the same answer however
/// the Mac spent the intervening time.
public struct KeepAwakeSession: Equatable, Sendable, Codable {
    public var id: String
    public var startedAt: Date
    public var deadline: Date
    /// What the user asked for, kept so the Finished summary can say how long
    /// it ran for rather than how long was left.
    public var total: TimeInterval
    /// The boot this session belongs to. A session never crosses a restart.
    public var bootID: String
    /// Phase 2: whether the user asked for the lid-closed hold.
    public var lidHoldRequested: Bool

    public init(
        id: String = UUID().uuidString,
        startedAt: Date,
        deadline: Date,
        total: TimeInterval,
        bootID: String,
        lidHoldRequested: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.deadline = deadline
        self.total = total
        self.bootID = bootID
        self.lidHoldRequested = lidHoldRequested
    }

    public func remaining(at now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    public func hasExpired(at now: Date) -> Bool {
        now >= deadline
    }
}

/// How a session ended, and what can still be done about it.
public struct KeepAwakeFinish: Equatable, Sendable {
    public var reason: KeepAwakeEndReason
    public var endedAt: Date
    /// What the session had left when it ended, so Resume can offer it.
    public var remaining: TimeInterval
    /// How long it actually ran.
    public var ran: TimeInterval
    /// The session that ended, kept so Resume starts the same one again.
    public var sessionID: String
    /// The deadline it would have had, so Resume can tell whether there is
    /// anything left to resume *to*.
    public var deadline: Date
    /// True when the end could not be written down (§6.1.1). The card says so,
    /// because a relaunch may bring the session back.
    public var endUnrecorded: Bool

    public init(
        reason: KeepAwakeEndReason,
        endedAt: Date,
        remaining: TimeInterval,
        ran: TimeInterval,
        sessionID: String,
        deadline: Date,
        endUnrecorded: Bool = false
    ) {
        self.reason = reason
        self.endedAt = endedAt
        self.remaining = remaining
        self.ran = ran
        self.sessionID = sessionID
        self.deadline = deadline
        self.endUnrecorded = endUnrecorded
    }

    /// Whether the Finished card offers Resume.
    ///
    /// Only the user's own End, and only while the original deadline is still
    /// ahead: resuming into a deadline that has already passed would start a
    /// session that ends in the same breath.
    public func canResume(at now: Date) -> Bool {
        reason.isUserCancellation && deadline > now
    }
}

/// What the card is showing.
///
/// There is no Paused state, deliberately. Pausing a keep-awake cannot be told
/// apart from ending it — the Mac is free to sleep either way, so a "paused"
/// session would be a label on nothing. The recipe's "an accidental
/// cancellation is recoverable" is met by Resume on the Finished card instead.
/// Do not add Pause.
public enum KeepAwakeState: Equatable, Sendable {
    case ready
    case running(KeepAwakeSession)
    case finished(KeepAwakeFinish)

    public var session: KeepAwakeSession? {
        if case .running(let session) = self { return session }
        return nil
    }

    public var isRunning: Bool { session != nil }
}
