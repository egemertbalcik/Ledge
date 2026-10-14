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
    /// The daemon answered, and the answer was no.
    case refused(KeepAwakeLidCode)

    /// The hold is in force as far as anything here can tell.
    ///
    /// `unconfirmed` counts. The Mac is being held awake under a lease that
    /// has not lapsed, so every part of the app that asks "is this on" — the
    /// menu-bar item above all — must answer yes.
    public var isLive: Bool {
        switch self {
        case .holding, .unconfirmed: true
        case .unsignedBuild, .notInstalled, .off, .refused: false
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
        case .holding, .unconfirmed, .unsignedBuild, .notInstalled: false
        }
    }

    /// One short word per state, for a log line and for the preview
    /// gallery's own naming. Not shown to anybody.
    public var name: String {
        switch self {
        case .unsignedBuild: "unsigned-build"
        case .notInstalled: "not-installed"
        case .off: "off"
        case .holding: "holding"
        case .unconfirmed: "unconfirmed"
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
    public var belongsOnARunningCard: Bool { isLive || isRefusal }

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
        guard state.isLive else { return nil }
        let headline = remaining.map(KeepAwakeCopy.lidMenuHeadline(remaining:))
            ?? KeepAwakeCopy.lidMenuHeadlineOpenEnded
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
        reading = installation == .unsignedBuild ? .unsignedBuild : .notInstalled
    }

    public func state() async -> KeepAwakeLidState { reading }
    public func arm(session: String, until deadline: Date) async -> KeepAwakeLidState { reading }
    public func disarm(session: String?) async {}
}
