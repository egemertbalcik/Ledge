import Foundation

/// Whether the lid is down.
public enum LidState: Sendable, Equatable, CaseIterable {
    case open
    case closed
    /// Nothing could be read. A desktop Mac has no lid, and a reading that
    /// cannot be taken is never treated as closed: everything the closed state
    /// turns on is something that would be wrong on a Mac somebody is using.
    case unknown
}

/// The lid, and what else is plugged into the Mac.
///
/// Both halves are needed to say anything useful, because a closed lid means
/// two opposite things. Shut with nothing else attached, the Mac has been put
/// down and nobody can see it. Shut with an external display, the Mac is on a
/// desk being worked at in clamshell mode — the built-in panel is already off,
/// the user is looking at the other screen, and muting their audio or dimming
/// their session would be an unpleasant surprise.
public struct LidReading: Sendable, Equatable {

    public let state: LidState
    /// Whether the built-in panel is the only display attached.
    public let builtInIsOnlyDisplay: Bool

    public init(state: LidState, builtInIsOnlyDisplay: Bool) {
        self.state = state
        self.builtInIsOnlyDisplay = builtInIsOnlyDisplay
    }

    /// Whether the lid-closed savings apply right now.
    ///
    /// Deliberately false for `.unknown`: everything gated on this is a change
    /// to a Mac somebody may be sitting in front of, and a reading nobody could
    /// take is not evidence that they are not.
    public var isPutAway: Bool {
        state == .closed && builtInIsOnlyDisplay
    }

    /// Whether the built-in panel has a brightness worth saving.
    ///
    /// Only while the lid is up. DisplayServices reports nothing for a panel in
    /// clamshell, and the value read as the lid comes down is not the user's
    /// anyway — the lid covers the ambient light sensor, so auto-brightness has
    /// already pulled the panel down before the close is reported.
    public var canSampleBrightness: Bool {
        state == .open
    }

    public static let unknown = LidReading(state: .unknown, builtInIsOnlyDisplay: true)
}

/// What the displays attached to this Mac mean for a closed lid.
///
/// Pure, because the whole of the rule is "what counts as evidence", and the
/// two ways of getting it wrong are both about absence: a display that is
/// asleep is still attached, and a list nobody could read is not an empty one.
public enum LidDisplays {

    /// Whether the built-in panel is the only display there is.
    ///
    /// - Parameter online: for each display the Mac has, whether it is the
    ///   built-in one. Nil when the list could not be read at all.
    ///
    /// The question is asked of what is *attached*, never of what is awake.
    /// An external monitor that has gone to sleep is still the screen the user
    /// is sitting at, and a Mac in clamshell on a desk is the one case where
    /// everything the closed-lid mode does — darkening, muting — would be an
    /// unpleasant surprise rather than a saving.
    ///
    /// Both kinds of absence answer `false`, which reads as "there is
    /// something else out there". That is the conservative direction: the
    /// cost of not conserving a Mac that was put away is a warm battery, and
    /// the cost of conserving one somebody is working at is their screen going
    /// black and their audio going silent while they use it.
    public static func builtInIsOnly(online: [Bool]?) -> Bool {
        guard let online, !online.isEmpty else { return false }
        return online.allSatisfy { $0 }
    }
}

/// What the lid's position should cause.
///
/// A pure function of the reading and whether a session is running, so the
/// decision can be tested without a hinge. Everything it returns is reversible,
/// and the reverse is what `.restore` means.
public enum LidAction: Sendable, Equatable {
    /// Put the savings in place: darken, mute, low power.
    case conserve
    /// Undo whatever is in place. Also the answer when no session is running,
    /// which is how a session ending while the lid is still shut gets undone.
    case restore
    /// Nothing to do.
    case none
}

public enum LidPolicy {

    /// - Parameters:
    ///   - reading: the lid and the displays, now.
    ///   - sessionRunning: whether a lid-closed hold is live.
    ///   - conserving: whether the savings are in place already.
    ///
    /// Restoring is the answer to every doubt. A session that ended, a lid that
    /// came up, a reading nobody could take, an external display appearing —
    /// each of them ends with the Mac as the user left it, because the cost of
    /// restoring when it was not needed is nothing, and the cost of conserving
    /// when it was not wanted is a dark screen and silent audio on a Mac
    /// somebody is working at.
    public static func action(for reading: LidReading,
                              sessionRunning: Bool,
                              conserving: Bool) -> LidAction {
        let wanted = sessionRunning && reading.isPutAway
        if wanted { return conserving ? .none : .conserve }
        return conserving ? .restore : .none
    }
}
