import Foundation

/// Decides, once per trackpad stroke, whether a stroke over a sideways control
/// — the timer's rule — belongs to it.
///
/// Sideways is how the notch moves between cards, so a control that takes
/// sideways scrolling for itself has to be careful about which strokes it
/// takes. Three rules:
///
/// - **Only a stroke that began here.** A swipe that started somewhere else
///   and is still coasting when a card with an open rule slides in under the
///   pointer is the swipe's, not the rule's.
/// - **Judged once.** The lean of the first few points decides the stroke, and
///   the decision holds to the end of its coast, the way the swipe recogniser
///   holds its own. A stroke that wobbles cannot start on the rule and finish
///   on the cards.
/// - **Vertical is not the rule's.** It is handed back, exactly as it would
///   have been anywhere else on the card.
///
/// The coast after the fingers lift stays with a stroke the rule took: a rule
/// that stops dead when the hand lets go is a rule that feels stuck.
///
/// Pure and clockless, like the recogniser beside it. Wheels have no strokes
/// and never come here.
public struct SidewaysStroke: Equatable, Sendable {

    /// What became of one event of the stroke.
    public enum Verdict: Equatable, Sendable {
        /// Too little movement yet to say which way. Held, so it reaches
        /// neither the rule nor the cards.
        case undecided
        /// The rule's: this much sideways travel, as reported by the event.
        case sideways(Double)
        /// Not the rule's. The caller hands it on as if the rule were not
        /// there.
        case notOurs
    }

    private enum Lock: Equatable, Sendable {
        /// No stroke began here, or the last one is over.
        case none
        case gathering
        case sideways
        case vertical
    }

    /// How far a stroke must lean before it is judged: the same distance the
    /// swipe recogniser uses, so a stroke reads the same on the rule as off it.
    public static let axisLockDistance: Double = 3

    private var lock: Lock = .none
    private var gatheredX: Double = 0
    private var gatheredY: Double = 0

    public init() {}

    /// Forgets the stroke under way. Called when the pointer moves on to
    /// another control, or off them all.
    public mutating func reset() {
        lock = .none
        gatheredX = 0
        gatheredY = 0
    }

    /// Feeds one event.
    ///
    /// - Parameters:
    ///   - sample: the event's travel and phase.
    ///   - began: the fingers started moving with this event.
    ///   - coastEnded: this event is the last of the stroke's coast.
    public mutating func feed(_ sample: ScrollSample, began: Bool, coastEnded: Bool = false) -> Verdict {
        defer { if coastEnded { reset() } }
        if began {
            reset()
            lock = .gathering
        }
        guard sample.dx.isFinite, sample.dy.isFinite else {
            return lock == .vertical || lock == .none ? .notOurs : .undecided
        }

        switch lock {
        case .none, .vertical:
            return .notOurs
        case .sideways:
            return .sideways(sample.dx)
        case .gathering:
            // A coast with nothing judged before it is the tail of a stroke
            // too short to say anything. It is nobody's to act on.
            guard !sample.isMomentum else { return .undecided }
            gatheredX += sample.dx
            gatheredY += sample.dy
            let x = abs(gatheredX)
            let y = abs(gatheredY)
            if y > x, y >= Self.axisLockDistance {
                lock = .vertical
                return .notOurs
            }
            guard x >= Self.axisLockDistance else { return .undecided }
            lock = .sideways
            // Everything gathered so far is paid out at once, so the first
            // few points of the stroke are not lost to the judging.
            let gathered = gatheredX
            gatheredX = 0
            gatheredY = 0
            return .sideways(gathered)
        }
    }
}
