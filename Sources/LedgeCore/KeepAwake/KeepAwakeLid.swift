import Foundation

/// A refusal from the privileged helper, in the app's own vocabulary.
///
/// One case per non-`ok` answer the daemon can give. Mirrored here rather than
/// imported because LedgeCore depends on nothing, and because the card's
/// vocabulary and the wire's vocabulary are allowed to drift apart one day —
/// what must never drift is the mapping, which is one function in LedgeSystem
/// with a test that walks every code.
public enum KeepAwakeLidCode: String, Equatable, Sendable, Codable, CaseIterable {
    /// Sleep is already disabled and no Ledge claim explains it.
    case foreign
    /// The other build's daemon — debug against release — holds it.
    case inUseByOtherLedge
    /// The lease lapsed while nobody was watching, and the generation the app
    /// was still using has been retired.
    case stale
    /// More requests are queued than the daemon will take.
    case busy
    /// The claim store refused the write, so nothing privileged was done.
    case persistFailed
    /// `pmset` refused the change, or the readback contradicted it.
    case pmsetFailed
    /// The session named is not the one being held.
    case notHolder
    /// A malformed request. A bug on this side, not something the user did.
    case invalidArgument

    /// Whether pressing it again could plausibly work.
    ///
    /// Two refusals are standing facts about the Mac rather than bad luck:
    /// somebody else owns the setting, or the other build of Ledge does.
    /// Offering a retry for those is offering a button that cannot work, and
    /// a button that cannot work is worse than no button — it costs a press
    /// and teaches the user the feature is broken rather than busy.
    public var isWorthRetrying: Bool {
        switch self {
        case .foreign, .inUseByOtherLedge: false
        case .stale, .busy, .persistFailed, .pmsetFailed, .notHolder, .invalidArgument: true
        }
    }
}

/// Whether this copy of Ledge can have a privileged helper at all.
///
/// `unsignedBuild` is not a failure to install; it is the honest answer that
/// installing is impossible here. `SMAppService` will not register a daemon
/// from an ad-hoc signed bundle, so a build made on somebody's own Mac without
/// a Developer ID can never hold the lid closed however many times the button
/// is pressed. Saying so once is kinder than failing differently each time.
public enum KeepAwakeHelperInstallation: String, Equatable, Sendable, Codable {
    case unsignedBuild
    case notInstalled
    /// Registered with macOS, and waiting for the user to allow it.
    ///
    /// Its own state rather than a flavour of `notInstalled`, which is what it
    /// used to be. The reasoning for folding it in was sound as far as it went
    /// — an unapproved daemon holds nothing, so saying "set up" would promise a
    /// hold that cannot happen — but it left the two states that need
    /// *different things from the user* looking identical. Somebody who has
    /// just pressed Set Up was told to go and press Set Up.
    case needsApproval
    case installed
}

/// What the lid-closed mode is doing, as the card and the menu bar see it.
///
/// Deliberately not an `Optional<Error>`: the two states that are neither on
/// nor broken — `off` and `unconfirmed` — are the ones the user most needs
/// told apart, and an error type would collapse the second into the first.
public enum KeepAwakeLidState: Equatable, Sendable, Codable {

    /// This build cannot install the helper, so the mode cannot exist here.
    case unsignedBuild
    /// The helper is not set up yet. A one-time setup away.
    case notInstalled
    /// Set up, and waiting for the user to allow it in System Settings.
    case needsApproval
    /// Asked for, and the daemon has never answered — so nothing is held.
    ///
    /// Not `unconfirmed`. That one means the Mac is very probably held and
    /// Ledge cannot prove it; this one means it is not held at all. They were
    /// the same state for a while, and the card told somebody their Mac was
    /// almost certainly staying awake while nothing was keeping it awake.
    case unreachable
    /// Installed, nothing held, and the mode can be switched on.
    case off
    /// Held, and the daemon said so.
    case holding
    /// Held, and the daemon has stopped answering.
    ///
    /// **Not a failure.** The daemon drops a hold on its own lease, not on our
    /// inability to reach it, so silence means "probably still held, we just
    /// cannot confirm". Telling the user their Mac is about to sleep here
    /// would be telling them something that is almost certainly untrue, and
    /// the one thing they might do about it — open the lid — is the exact
    /// thing the mode exists to save them.
    case unconfirmed
    /// Asked for, accepted, and not yet applied.
    ///
    /// The daemon answers a hold once its lease is on disk and *before* it
    /// runs the privileged write, so an acceptance is not a hold. This shared
    /// a case with `unconfirmed` and therefore shared its sentence — "it
    /// almost certainly still stands" — which is true of a hold that was
    /// established and has gone quiet and false of one that has never been
    /// established at all. Same drawing, different sentence: one says keep
    /// the lid open a moment longer, the other says you may shut it.
    case applying
    /// Asked for, got through, and nothing can vouch for it now.
    ///
    /// Accepted and never confirmed, or confirmed longer ago than the lease.
    /// Between `unconfirmed`, which says the hold almost certainly stands,
    /// and `unreachable`, which says nothing is held: both of those were
    /// being said about this, and both were claims nobody could make.
    case cannotTell
    /// The daemon answered, and the answer was no.
    case refused(KeepAwakeLidCode)

    /// The hold is in force as far as anything here can tell.
    ///
    /// `unconfirmed` counts. The Mac is being held awake under a lease that
    /// has not lapsed, so every part of the app that asks "is this on" — the
    /// menu-bar item above all — must answer yes.
    /// Whether the daemon has *said* it holds this Mac.
    ///
    /// Only `.holding`. `.unconfirmed` is a hold that was asked for and not
    /// answered — the daemon may have taken it and lost the reply — and
    /// treating that as evidence is how the card came to draw a filled
    /// switch, a countdown and "nothing is being held" at the same time.
    /// `isLive` is the looser question and still has its uses; this is the
    /// one anything claiming protection must ask.
    public var isConfirmed: Bool { self == .holding }

    public var isLive: Bool {
        switch self {
        // `applying` counts. The lease is on the daemon's disk, so the Mac
        // is as held as a lease can make it; what has not happened yet is the
        // privileged write.
        case .holding, .unconfirmed, .applying: true
        // `cannotTell` is not live: nothing may tell the user their Mac is
        // covered on the strength of it. Whether they need a *control* is a
        // different question, and `needsAWayOut` is where that is asked —
        // answering it here took the menu-bar item away from somebody whose
        // lid was already shut over a hold that may well have been standing.
        case .cannotTell: false
        case .unsignedBuild, .notInstalled, .needsApproval, .unreachable, .off, .refused: false
        }
    }

    /// Whether the card may offer to switch the mode on.
    ///
    /// Not simply `!isLive`: a mode that cannot be installed, or that somebody
    /// else's claim stands in the way of, is refused for a reason no press
    /// will change.
    public var mayArm: Bool {
        switch self {
        case .off: true
        case .refused(let code): code.isWorthRetrying
        // Unreachable is offerable again: the daemon not answering once is
        // a reason to try, not a reason no press will change.
        case .unreachable: true
        // Worth another press: taking the hold again is exactly what
        // resolves not knowing.
        case .cannotTell: true
        case .holding, .unconfirmed, .applying,
             .unsignedBuild, .notInstalled, .needsApproval: false
        }
    }

    /// One short word per state, for a log line and for the preview
    /// gallery's own naming. Not shown to anybody.
    public var name: String {
        switch self {
        case .unsignedBuild: "unsigned-build"
        case .notInstalled: "not-installed"
        case .needsApproval: "needs-approval"
        case .unreachable: "unreachable"
        case .off: "off"
        case .holding: "holding"
        case .unconfirmed: "unconfirmed"
        case .applying: "applying"
        case .cannotTell: "cannot-tell"
        case .refused(let code): "refused-\(code.rawValue)"
        }
    }

    /// The daemon said no, whatever it said no about.
    public var isRefusal: Bool {
        if case .refused = self { return true }
        return false
    }

    /// Whether this state belongs on a card that is already running.
    ///
    /// A hold that is live, or one that was asked for and refused, is about
    /// *this session*. "Not set up" and "this build can't" are about the app,
    /// and a session that is running was plainly started without them.
    /// Whether a running card has to say this.
    ///
    /// `unreachable` belongs here above all: a session that asked for the lid
    /// and never got it looks exactly like a healthy one otherwise, and the
    /// user shuts the lid on it. A refusal at least arrives as an answer to
    /// something they pressed; this arrives as silence.
    /// Whether the user needs a way to end this, whatever it is.
    ///
    /// Live *or* unknown. A hold nobody can vouch for may still be holding
    /// the Mac, and the one surface that exists when the lid is already shut
    /// is the menu-bar item — so taking it away on uncertainty leaves the
    /// person it was built for with no way out at all.
    public var needsAWayOut: Bool {
        switch self {
        // Nothing was ever asked for here, so there is nothing to end.
        case .off, .notInstalled, .needsApproval, .unsignedBuild: false
        // Everything else. A hold that is live, one nothing can vouch for,
        // one the daemon stopped answering about — and a *renewal* that was
        // refused, which is the case this was written without: the daemon
        // can answer `busy` to a renewal while the lease it refused to renew
        // is still standing, and reading that as "nothing to end" took the
        // menu-bar item away from a Mac that was being held.
        case .holding, .unconfirmed, .applying, .cannotTell, .unreachable, .refused: true
        }
    }

    public var belongsOnARunningCard: Bool {
        isLive || isRefusal || self == .unreachable || self == .cannotTell
    }

    /// Whether the helper exists to be talked to at all. Settings asks this to
    /// decide between "set it up" and "there is nothing to set up here".
    public var isInstallable: Bool { self != .unsignedBuild }
}

/// The menu-bar item a live lid-closed hold puts up, as values.
///
/// With the lid shut and an external display attached, the built-in panel is
/// off — so the notch, which is the whole of Ledge's UI, does not exist. A
/// hold with no surface at all would be a Mac held awake with no way to see it
/// and no way to stop it short of opening the lid. This is that surface, and
/// it is session-scoped on purpose: it appears with the hold and goes with it,
/// so it is never a permanent icon in a menu bar that did not ask for one.
///
/// Values rather than an `NSStatusItem`, because the only interesting
/// decisions — when it exists at all, and what it says — are the ones an
/// AppKit object cannot be asked about in a test.
public struct KeepAwakeLidBadge: Equatable, Sendable {

    /// The symbol in the menu bar.
    public var symbolName: String
    /// The item's own accessibility label, since a symbol says nothing aloud.
    public var spoken: String
    /// The first line of the menu: what is happening, in a sentence.
    public var headline: String
    /// The second line, when there is more to say than the headline holds.
    public var detail: String?
    /// The one thing the menu can do.
    public var endTitle: String

    public init(symbolName: String, spoken: String, headline: String,
                detail: String? = nil, endTitle: String) {
        self.symbolName = symbolName
        self.spoken = spoken
        self.headline = headline
        self.detail = detail
        self.endTitle = endTitle
    }

    /// The badge for a state, or nil when there should be no item at all.
    ///
    /// - Parameter remaining: how long is left, already formatted. Nil when
    ///   nothing is counting down.
    public static func badge(for state: KeepAwakeLidState,
                             remaining: String?) -> KeepAwakeLidBadge? {
        guard state.needsAWayOut else { return nil }
        // Live is not confirmed. An unconfirmed hold keeps its item — the
        // lease is taken and the user must be able to end it — but it does
        // not get the headline that says the lid is covered.
        let headline: String
        if state.isConfirmed {
            headline = remaining.map(KeepAwakeCopy.lidMenuHeadline(remaining:))
                ?? KeepAwakeCopy.lidMenuHeadlineOpenEnded
        } else if state == .cannotTell || state.isRefusal || state == .unreachable {
            // The item is here so the hold can be ended, not to say it is
            // working. A renewal the daemon refused leaves a lease that may
            // well be standing, and this is the only surface once the lid is
            // down.
            headline = KeepAwakeCopy.lidMenuHeadlineCannotTell
        } else {
            headline = KeepAwakeCopy.lidMenuHeadlineUnconfirmed(remaining: remaining)
        }
        return KeepAwakeLidBadge(
            // One symbol for both live states. A different glyph for
            // `unconfirmed` would read as a different feature at the size a
            // menu bar draws it; the sentence in the menu is where the
            // difference belongs, because it is where there is room to say it.
            symbolName: "cup.and.saucer.fill",
            spoken: headline,
            headline: headline,
            detail: state == .unconfirmed ? KeepAwakeCopy.lidUnconfirmed : nil,
            endTitle: KeepAwakeCopy.lidMenuEnd
        )
    }
}

/// The lid-closed hold, as everything above the daemon sees it.
///
/// A protocol because the real thing is an XPC connection to a root daemon,
/// and none of the states worth building a card for — refused, silent, held by
/// somebody else — can be produced on demand against one.
public protocol KeepAwakeLidHolding: Sendable {
    /// What it is doing now, without changing anything.
    func state() async -> KeepAwakeLidState
    /// Takes the hold, to a deadline that is fixed here and never moved.
    func arm(session: String, until deadline: Date) async -> KeepAwakeLidState
    /// Gives it back. Never refused.
    ///
    /// - Parameter session: the session giving it back, or nil for "whatever
    ///   is held" — which is what switching the whole feature off means. A
    ///   provider on its way out must name its own: its release can be
    ///   delayed past the point where a replacement has taken a hold of its
    ///   own, and an unnamed release would end that one instead.
    func disarm(session: String?) async
}

/// The lid-closed hold on a Ledge that has no helper.
///
/// The shipping default until the installation path exists. It is a real
/// implementation rather than an optional, so every caller above it is written
/// once and the card draws the honest "not set up" state rather than a
/// disabled nothing.
public struct KeepAwakeLidUnavailable: KeepAwakeLidHolding {

    private let reading: KeepAwakeLidState

    public init(_ installation: KeepAwakeHelperInstallation = .notInstalled) {
        // Each state keeps its own name here too. The same collapse lived in
        // both places, so fixing one would have left the other telling an
        // approved helper it was missing.
        reading = switch installation {
        case .unsignedBuild: .unsignedBuild
        case .needsApproval: .needsApproval
        case .notInstalled, .installed: .notInstalled
        }
    }

    public func state() async -> KeepAwakeLidState { reading }
    public func arm(session: String, until deadline: Date) async -> KeepAwakeLidState { reading }
    public func disarm(session: String?) async {}
}
