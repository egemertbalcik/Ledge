import Foundation

/// What the self-view is doing, on the one card that has one.
///
/// Off is not "no camera" — it is the ordinary calendar card, with the month
/// on show and a segment beside Join that nobody has pressed. Every other case
/// draws the frame over the month, and only three of them have a camera
/// running.
public enum SelfViewPhase: String, Equatable, Sendable, CaseIterable {

    /// The month is on show. The card is exactly what it has always been.
    case off

    /// macOS's own permission dialog is up. Ledge is waiting on the person,
    /// not on the camera.
    case asking

    /// The session is running and no frame has arrived yet.
    case waking

    /// A picture.
    case live

    /// Not allowed — refused now, or months ago and never revisited.
    case refused

    /// Refused by a configuration profile. Nothing the person can do here.
    case blocked

    /// No built-in front camera on this Mac.
    case noCamera

    /// The session started and never produced a frame.
    case failed

    /// Whether the frame is over the month at all.
    ///
    /// Everything but `off`: a refusal is still something the frame has to
    /// say, and it says it in the space the picture would have used.
    public var showsFrame: Bool { self != .off }

    /// Whether Ledge is actually holding the camera.
    ///
    /// The green light in the menu bar is on for exactly these two, which is
    /// also the only time Ledge's own privacy card may be quiet about it.
    public var isRunningCamera: Bool { self == .waking || self == .live }

    /// Whether the notch must stay open against the ordinary rules.
    ///
    /// `asking` is included even though no camera is running yet: the pointer
    /// has to travel to macOS's dialog, and a notch that shut on the way would
    /// take the question with it.
    public var holdsNotchOpen: Bool {
        self == .asking || self == .waking || self == .live
    }

    /// Whether this face ends with nothing to watch — a sentence centred in
    /// the frame rather than a picture behind one.
    public var isDeadEnd: Bool {
        self == .refused || self == .blocked || self == .noCamera || self == .failed
    }
}

/// What macOS says about Ledge and the camera, in Ledge's own words.
///
/// `AVAuthorizationStatus` has four cases and this has five: "there is no
/// camera" is not an authorisation answer, but it is the same question from
/// where the card is standing — can this press show you anything?
public enum CameraAccess: String, Equatable, Sendable, CaseIterable {
    case allowed
    /// Never asked. The first press is what asks.
    case notAsked
    case refused
    /// A configuration profile decided, not the person.
    case blocked
    /// No built-in front camera.
    case missing
}

/// What a press on the segment is asking for.
public enum SelfViewPress: Equatable, Sendable {
    /// Check access, then open the frame.
    case open
    /// Let the camera go and put the month back.
    case close
    /// Put the month back. Nothing is running, so nothing is given up.
    case backToMonth
}

/// How long the self-view waits, and for what.
///
/// All five numbers are here rather than spread through the shell, because
/// every one of them is a promise to somebody looking at their own face in a
/// notch.
public enum SelfViewTiming {

    /// How long a silent wait is allowed to last before the card says it is
    /// waking the camera. Under this, the sentence would be a flicker.
    public static let patience: TimeInterval = 0.6

    /// How long a session may run without producing a frame before Ledge
    /// gives up on it and says so.
    ///
    /// Ten, not five: the first start after sleep can take the camera several
    /// seconds to wake, and five gave up on a camera that was about to come
    /// up. The card already says it is waking, so the wait is never silent.
    public static let giveUp: TimeInterval = 10

    /// How long the camera stays on once the pointer has left the notch.
    ///
    /// Long enough to change a microphone in the menu bar or answer someone;
    /// short enough that a forgotten camera is not on all afternoon.
    public static let awayLimit: TimeInterval = 60

    /// How long the camera may be on at all, pointer or not. A cursor parked
    /// on the notch would otherwise hold it open until the Mac slept.
    public static let totalCap: TimeInterval = 300

    /// How much of the end is counted out loud.
    public static let countdownWindow: TimeInterval = 10
}

/// The rules the self-view runs on: which face a reading implies, how long is
/// left, what a press means, and which single sentence is shown.
///
/// Pure and clockless, like `MeetingJoin` beside it — the caller passes the
/// times it already has.
public enum SelfViewPolicy {

    /// The face a fresh access reading puts the card on.
    ///
    /// `allowed` goes straight to `waking`, not to `live`: a session that has
    /// been asked to start has not yet shown anything, and the difference is
    /// the whole reason the waking face exists.
    public static func phase(for access: CameraAccess) -> SelfViewPhase {
        switch access {
        case .allowed: .waking
        case .notAsked: .asking
        case .refused: .refused
        case .blocked: .blocked
        case .missing: .noCamera
        }
    }

    /// What pressing the segment does from a given face.
    public static func press(on phase: SelfViewPhase) -> SelfViewPress {
        switch phase {
        case .off: .open
        // The camera is running, or a dialog is up on its behalf. Both are
        // given up by the same press that started them.
        case .asking, .waking, .live: .close
        // Nothing is running behind these, so there is nothing to let go of.
        case .refused, .blocked, .noCamera, .failed: .backToMonth
        }
    }

    /// How long the self-view has left, in seconds.
    ///
    /// Two clocks run at once and the nearer one wins: the minute that starts
    /// when the pointer leaves the notch, and the five minutes that start when
    /// the camera does. Coming back to the notch clears the first and does
    /// nothing to the second.
    ///
    /// - Parameters:
    ///   - startedAt: when the camera was asked for.
    ///   - awaySince: when the pointer left the notch; nil while it is on it.
    ///   - now: the moment being asked about.
    public static func secondsLeft(
        startedAt: TimeInterval,
        awaySince: TimeInterval?,
        now: TimeInterval
    ) -> TimeInterval {
        let cap = SelfViewTiming.totalCap - (now - startedAt)
        guard let awaySince else { return cap }
        let away = SelfViewTiming.awayLimit - (now - awaySince)
        return min(cap, away)
    }

    /// Whether the time is up.
    public static func hasExpired(
        startedAt: TimeInterval,
        awaySince: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        secondsLeft(startedAt: startedAt, awaySince: awaySince, now: now) <= 0
    }

    /// The count shown over the picture, or nil when there is nothing to say
    /// yet.
    ///
    /// Only over a live picture, and only for the last ten seconds. Rounded
    /// up, so the number a person reads is the number of seconds they still
    /// have, and never nought while the picture is still there.
    public static func countdown(
        phase: SelfViewPhase,
        startedAt: TimeInterval,
        awaySince: TimeInterval?,
        now: TimeInterval
    ) -> Int? {
        guard phase == .live else { return nil }
        let left = secondsLeft(startedAt: startedAt, awaySince: awaySince, now: now)
        guard left <= SelfViewTiming.countdownWindow else { return nil }
        return max(1, Int(left.rounded(.up)))
    }

    /// The one sentence the frame shows, or nil for silence.
    ///
    /// Only one at a time, and the one that blocks more wins. The order is the
    /// ladder in the design: no camera, blocked, not allowed, didn't start,
    /// asking, waking, closing. A count can only ever meet a live picture, so
    /// it sits at the bottom and never fights the others.
    ///
    /// - Parameters:
    ///   - waitedFor: how long the current wait has lasted, for the patience
    ///     before "Waking the camera…". A wait shorter than that is silent.
    public static func sentence(
        phase: SelfViewPhase,
        waitedFor: TimeInterval = 0,
        countdown: Int? = nil
    ) -> String? {
        switch phase {
        case .noCamera: SelfViewCopy.noCamera
        case .blocked: SelfViewCopy.blocked
        case .refused: SelfViewCopy.refused
        case .failed: SelfViewCopy.didNotStart
        case .asking: SelfViewCopy.asking
        case .waking: waitedFor >= SelfViewTiming.patience ? SelfViewCopy.waking : nil
        case .live: countdown.map(SelfViewCopy.closesIn)
        case .off: nil
        }
    }

    /// The action under a dead-end sentence, if there is one to offer.
    ///
    /// Blocked and no-camera get none on purpose: a button that cannot help is
    /// worse than the sentence alone.
    public static func action(for phase: SelfViewPhase) -> SelfViewAction? {
        switch phase {
        case .refused: .openSettings
        case .failed: .tryAgain
        default: nil
        }
    }
}

/// The one thing a dead-end face can offer.
public enum SelfViewAction: String, Equatable, Sendable {
    case openSettings
    case tryAgain

    public var label: String {
        switch self {
        case .openSettings: SelfViewCopy.openSettings
        case .tryAgain: SelfViewCopy.tryAgain
        }
    }
}

/// Everything the self-view says, in one place, so a sentence can be read
/// without opening a view.
public enum SelfViewCopy {

    /// The segment's tooltip, and its accessibility hint.
    public static let hint = "See yourself before you join"

    /// The segment at rest.
    public static let label = "Camera preview"

    /// The segment while the frame is open. It is the same control, so it
    /// says what pressing it now does.
    public static let closeLabel = "Turn off camera preview"

    public static let asking = "macOS is asking for camera access."
    public static let waking = "Waking the camera…"
    public static let refused = "Ledge isn’t allowed to use the camera."
    public static let openSettings = "Open Settings"
    public static let blocked = "Camera access is blocked on this Mac."
    public static let noCamera = "No camera found."
    public static let didNotStart = "The camera didn’t start."
    public static let tryAgain = "Try again"

    public static func closesIn(_ seconds: Int) -> String { "Closes in \(seconds)s" }
}

/// What the card is told about the self-view.
///
/// Three values, all of them facts the shell owns. The card draws them and
/// decides nothing: a view that worked out its own patience would have to do
/// it in `.task`, and `ImageRenderer` — which photographs every card in this
/// app for the gallery — never mounts a view, so every exported waking face
/// would be a silent one. A fact the shell carries is a fact a photograph
/// can show.
public struct SelfViewPayload: Equatable, Sendable {

    public var phase: SelfViewPhase

    /// Whether the silent wait has lasted long enough to be worth a sentence.
    /// Under `SelfViewTiming.patience` the card says nothing, because a camera
    /// that wakes in a third of a second should not flash a word about it.
    public var waitHasLasted: Bool

    /// The seconds left, when they are worth saying out loud. Nil at every
    /// other moment, including a live picture with minutes left.
    public var countdown: Int?

    public init(
        phase: SelfViewPhase = .off,
        waitHasLasted: Bool = false,
        countdown: Int? = nil
    ) {
        self.phase = phase
        self.waitHasLasted = waitHasLasted
        self.countdown = countdown
    }

    /// The resting card: a month, and a segment nobody has pressed.
    public static let off = SelfViewPayload()

    /// The sentence this payload shows, if any.
    public var sentence: String? {
        SelfViewPolicy.sentence(
            phase: phase,
            waitedFor: waitHasLasted ? SelfViewTiming.patience : 0,
            countdown: countdown
        )
    }
}
