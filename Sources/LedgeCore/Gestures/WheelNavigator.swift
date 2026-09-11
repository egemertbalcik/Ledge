import Foundation

/// Turns a mouse wheel's vertical scrolling into card changes.
///
/// A trackpad moves sideways, so swiping is the natural way through the cards
/// and `SwipeRecognizer` handles it. A mouse wheel usually cannot: it has one
/// axis, and on that axis the app has deliberately claimed nothing — vertical
/// scrolling belongs to whatever is under the pointer. So a mouse had no way
/// through the cards at all except the middle button.
///
/// This claims the wheel, and *only* the wheel:
///
/// - **Phase is the test.** A trackpad and a Magic Mouse report a touch phase
///   on every scroll event — began, changed, ended — because a finger is on
///   them. A wheel reports none: there is nothing to begin or end. So an event
///   with no phase and no momentum came from a wheel, and an event with either
///   did not. That leaves every trackpad gesture exactly as it was.
/// - **A card is a distance, and a pace.** A notched wheel sends about ten
///   points per click, so one click is one card. A free-spinning wheel sends
///   hundreds of points in a flick, so the same distance would blur the whole
///   queue past: cards are also rate-limited, and the movement is held rather
///   than banked while the limit holds, so a spin stops where the hand stops
///   instead of catching up afterwards.
///
/// Pure and clockless, like the recogniser beside it.
public struct WheelNavigator: Equatable, Sendable {

    /// How far the wheel must travel for one card.
    ///
    /// A notched wheel reports about ten points per click, so one click is one
    /// card — which is what anybody who has used a scroll wheel expects, and
    /// the smallest movement the device can make. A high-resolution wheel
    /// sends a few points at a time and reaches the same distance smoothly.
    public static let step: Double = 10

    /// What one line of scrolling is worth in points.
    ///
    /// A notched wheel does not report points at all: its events carry a line
    /// count, one per click, and it is the reader's job to decide what a line
    /// is worth. macOS uses ten points, and so does this — which is what makes
    /// one click exactly one card.
    public static let linePoints: Double = 10

    /// The least time between two cards.
    ///
    /// The step alone is not enough for a free-spinning wheel: one flick sends
    /// hundreds of points in a moment, and without this the queue would blur
    /// past. With it, a spin moves at a readable pace and stops where the hand
    /// stops, rather than continuing to catch up afterwards.
    public static let minimumInterval: TimeInterval = 0.14

    /// How long without an event before the wheel is considered still.
    public var idleTimeout: TimeInterval

    /// Follows the system's "natural" scrolling setting, exactly as the swipe
    /// recogniser does: with it on, the delta follows the wheel's movement;
    /// with it off, it describes where the content should go.
    public var isNatural: Bool

    private var accumulated: Double = 0
    private var lastTimestamp: TimeInterval?
    /// When a card was last offered, for the pace limit.
    private var lastFired: TimeInterval?

    public init(isNatural: Bool = true, idleTimeout: TimeInterval = 0.25) {
        self.isNatural = isNatural
        self.idleTimeout = idleTimeout
    }

    public mutating func reset() {
        accumulated = 0
        lastTimestamp = nil
        lastFired = nil
    }

    /// Whether this event came from a wheel rather than a touch surface.
    ///
    /// Static because the caller needs the answer *before* deciding whether the
    /// wheel path applies at all — a trackpad's vertical scroll must reach the
    /// list under the pointer untouched, and must not even be accumulated here.
    public static func isWheel(hasPhase: Bool, isMomentum: Bool) -> Bool {
        !hasPhase && !isMomentum
    }

    /// Feeds one wheel event. Returns a swipe at most once per movement.
    ///
    /// The returned swipe is the same one a trackpad would produce, so
    /// everything downstream — cycling, wraparound, the sideways transition —
    /// is shared rather than reimplemented. Wheel down is the next card, which
    /// is what swiping left does.
    public mutating func feed(_ sample: ScrollSample) -> Swipe? {
        guard sample.dy.isFinite, sample.timestamp.isFinite else { return nil }
        // A gap means the hand left the wheel: whatever was accumulated was a
        // separate movement, and the next one starts fresh.
        if let last = lastTimestamp, abs(sample.timestamp - last) >= idleTimeout {
            reset()
        }
        lastTimestamp = sample.timestamp

        // With natural scrolling the delta follows the wheel, so turning it
        // away from you — scrolling up — is positive. With it off the delta
        // describes the content's movement, which is the opposite.
        let travel = isNatural ? sample.dy : -sample.dy
        // Turning back is a change of mind, not a continuation: whatever was
        // banked in the other direction is dropped, so the reversal answers on
        // its own merits rather than having to undo the previous movement
        // first.
        if travel != 0, accumulated != 0, (travel < 0) != (accumulated < 0) {
            accumulated = 0
        }
        accumulated += travel

        guard abs(accumulated) >= Self.step else { return nil }

        // Too soon after the last card. The movement is held at one step's
        // worth rather than banked, so a fast spin cannot store up cards to
        // deal out after the hand has stopped.
        if let lastFired, sample.timestamp - lastFired < Self.minimumInterval {
            accumulated = accumulated > 0 ? Self.step : -Self.step
            return nil
        }

        lastFired = sample.timestamp
        let isUp = accumulated > 0
        // The remainder is kept, so a smooth wheel's travel is not thrown away
        // a fraction at a time.
        accumulated -= isUp ? Self.step : -Self.step
        // Up is the previous card — the same as swiping right — and down is
        // the next one.
        return isUp ? .right : .left
    }
}
