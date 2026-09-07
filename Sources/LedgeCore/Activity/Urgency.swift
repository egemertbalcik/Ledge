import Foundation

/// How much a card matters *right now*.
///
/// The queue used to order cards by a static per-kind rank, which cannot know
/// that a meeting is five minutes away or that the music is paused. The score
/// is that rank plus situational boosts read from the payload itself — and
/// because every provider republishes as its world changes (the calendar each
/// minute, the player each second), scores refresh with no extra clockwork:
/// the payload already carries the situation.
///
/// Pure and clock-free on purpose: time-dependent facts (startsIn, isPlaying,
/// rainSoonMinutes) are relative values the providers recompute at each
/// publish, so the same activity always scores the same — which is what makes
/// ordering testable and the ranking explainable. Every boost here should be
/// expressible as one sentence of the form "X is happening, so X's card
/// matters more".
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
            if payload.isFinished {
                score += 80
            } else if !payload.isIdle {
                score += 40
            }

        case .event(let payload):
            if payload.hasEvent {
                if payload.startsIn <= 15 * 60 {
                    // Imminent or already under way — this is what the next
                    // glance at the notch is for (the Join button lives here).
                    score += 60
                } else if payload.startsIn <= 60 * 60 {
                    score += 20
                }
            }

        case .nowPlaying(let payload):
            if payload.isPlaying { score += 30 }

        case .weather(let payload):
            if payload.rainSoonMinutes != nil { score += 15 }

        default:
            break
        }

        return score
    }
}
