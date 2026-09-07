import Foundation

/// One scroll event, reduced to what the recogniser needs.
public struct ScrollSample: Equatable, Sendable {
    public let dx: Double
    public let dy: Double
    public let timestamp: TimeInterval

    /// Trackpad scrolls continue coasting after the fingers lift. Momentum is
    /// tracked separately so one flick cannot fire a second swipe as it decays.
    public let isMomentum: Bool

    /// True on the event where the fingers lift, which ends the gesture.
    public let isEnded: Bool

    public init(
        dx: Double,
        dy: Double,
        timestamp: TimeInterval,
        isMomentum: Bool = false,
        isEnded: Bool = false
    ) {
        self.dx = dx
        self.dy = dy
        self.timestamp = timestamp
        self.isMomentum = isMomentum
        self.isEnded = isEnded
    }
}

public enum Swipe: Equatable, Sendable {
    case left
    case right
}

/// What to do with a scroll event, once the recogniser has seen it.
///
/// Vertical scrolling is not a gesture this app claims. It used to be — down
/// opened a card or threw the open one away, up collapsed it — and a card
/// could vanish under a scroll the user meant for the window behind, with no
/// visible control saying that would happen. So vertical is handed back
/// untouched, and the notch keeps only what it can be seen to offer.
public enum ScrollOutcome: Equatable, Sendable {
    /// Still gathering. Ours for now — it may yet become a swipe.
    case pending
    /// A horizontal swipe, recognised.
    case swipe(Swipe)
    /// Vertical: not ours. The caller must let the event through, so anything
    /// scrollable under the pointer — the media card's output list — still
    /// scrolls.
    case notOurs
}

/// Turns a stream of scroll deltas into at most one swipe per gesture.
///
/// Two properties matter and neither is free:
///
/// - **One swipe per gesture.** Once a direction fires, everything until the
///   gesture ends is ignored. Otherwise a single flick across the trackpad
///   would cycle through every activity at once.
/// - **Axis lock.** The dominant axis is chosen early and held, so a gesture
///   that starts vertical stays vertical — and is disclaimed — rather than
///   turning into a card change halfway through.
public struct SwipeRecognizer: Equatable, Sendable {

    /// Accumulated distance, in points, before a swipe fires.
    public var threshold: Double

    /// Follows the system's "natural" scrolling setting. When true, content
    /// moves with the fingers, so a physical swipe left reports positive dx.
    public var isNatural: Bool

    /// A gesture is considered over after this long with no events, for mice
    /// that never send a phase-ended event.
    public var idleTimeout: TimeInterval

    private var accumulatedX: Double = 0
    private var accumulatedY: Double = 0
    private var hasFired: Bool = false
    private var isVertical: Bool = false
    private var lastTimestamp: TimeInterval?

    /// How far a gesture must lean vertically before it is disclaimed. Small,
    /// so a scroll aimed at a list starts scrolling straight away rather than
    /// after the swipe threshold's worth of stalled movement.
    private static let axisLockDistance: Double = 3

    public init(
        threshold: Double = 28,
        isNatural: Bool = true,
        idleTimeout: TimeInterval = 0.25
    ) {
        self.threshold = threshold
        self.isNatural = isNatural
        self.idleTimeout = idleTimeout
    }

    public mutating func reset() {
        accumulatedX = 0
        accumulatedY = 0
        hasFired = false
        isVertical = false
        lastTimestamp = nil
    }

    /// Feeds one sample. Returns a swipe at most once per gesture.
    public mutating func feed(_ sample: ScrollSample) -> ScrollOutcome {
        // One non-finite delta would poison the accumulator permanently:
        // NaN propagates, and every subsequent threshold comparison is false,
        // so the recogniser would fail silently and closed.
        guard sample.dx.isFinite, sample.dy.isFinite, sample.timestamp.isFinite else {
            return .pending
        }

        // A long enough gap means the previous gesture is over, even if its end
        // event never arrived. Compared as a magnitude: event timestamps can
        // jump backwards across a sleep/wake, and a signed test would never
        // notice, carrying stale accumulation into the next gesture.
        if let last = lastTimestamp, abs(sample.timestamp - last) >= idleTimeout {
            reset()
        }
        lastTimestamp = sample.timestamp

        if sample.isEnded {
            reset()
            return .pending
        }

        // Momentum is the tail of a gesture that has already been judged.
        // Feeding it in would let one flick fire repeatedly.
        guard !sample.isMomentum else { return isVertical ? .notOurs : .pending }
        guard !hasFired else { return isVertical ? .notOurs : .pending }

        accumulatedX += sample.dx
        accumulatedY += sample.dy

        let magnitudeX = abs(accumulatedX)
        let magnitudeY = abs(accumulatedY)

        // Decided once and held for the rest of the gesture.
        if isVertical || (magnitudeY > magnitudeX && magnitudeY >= Self.axisLockDistance) {
            isVertical = true
            return .notOurs
        }
        // A threshold of zero or less would fire on every single event,
        // cycling activities on any scroll. The slider cannot produce that, but
        // the value is read from user defaults and is not otherwise validated.
        guard threshold > 0, magnitudeX >= threshold else { return .pending }

        hasFired = true

        // With natural scrolling the reported delta follows the fingers, so a
        // rightward swipe is a positive dx. With it off, the delta describes
        // where the *content* should go, which is the opposite.
        let isRightward = isNatural ? accumulatedX > 0 : accumulatedX < 0
        return .swipe(isRightward ? .right : .left)
    }
}

/// What a swipe means, given what is on screen.
///
/// Kept separate from the recogniser so the mapping is testable on its own and
/// can change without touching the gesture maths.
public enum SwipeIntent: Equatable, Sendable {
    case cycleForward
    case cycleBackward

    /// Sideways moves between cards, in any phase. Nothing else is a gesture:
    /// opening, closing and putting a card away are all things the user can
    /// see and click.
    public static func from(_ swipe: Swipe, phase: NotchPhase) -> SwipeIntent? {
        switch swipe {
        case .left: return .cycleForward
        case .right: return .cycleBackward
        }
    }
}
