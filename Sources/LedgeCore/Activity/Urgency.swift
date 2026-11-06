import Foundation

/// Where a card goes in the queue.
///
/// Everyday cards keep the fixed order of `ActivityKind.defaultPriority`, so
/// the order can be learned: music pausing or a keep-awake starting moves
/// nothing. A card jumps ahead only for news, and only until that news is over.
/// Every boost here should be expressible as one sentence of the form "X has
/// just happened, and the user needs to know now".
///
/// Pure and clock-free on purpose: time-dependent facts (startsIn) are relative
/// values the providers recompute at each publish, so the same activity always
/// scores the same, which is what makes ordering testable and explainable.
public enum Urgency {

    /// A pinned kind outranks every situational boost: the user said "always
    /// this first", and no amount of cleverness overrides a direct order.
    public static let pinBoost = 1_000

    public static func score(of activity: Activity, pinned: ActivityKind? = nil) -> Int {
        // Clamped: every real provider stays well inside this, but a scenario
        // fixture carries a raw JSON priority and the boosts below must never
        // be the thing that overflows it.
        var score = min(max(activity.priority, -1_000_000), 1_000_000)

        if let pinned, activity.kind == pinned {
            score += pinBoost
        }

        switch activity.payload {
        case .privacy(let payload):
            // Recording is the one thing that must never be buried.
            if payload.cameraActive || payload.micActive { score += 100 }

        case .timer(let payload):
            if payload.isFinished { score += 80 }

        case .keepAwake(let payload):
            // A session that has ended says something about the Mac's power
            // that the user did not ask for at that moment, the same shape as
            // the timer's finish. Ready and running stay in their place.
            if case .finished = payload.phase { score += 60 }

        case .event(let payload):
            // Imminent or already under way: this is what the next glance at
            // the notch is for (the Join button lives here).
            if payload.hasEvent, payload.startsIn <= 15 * 60 { score += 60 }

        default:
            break
        }

        return score
    }
}
