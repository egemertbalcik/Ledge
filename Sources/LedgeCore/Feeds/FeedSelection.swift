import Foundation

/// Which feed has the closed notch.
public enum FeedSelection {

    /// The feed whose compact text goes in the ears: the most recently
    /// updated of those that have any, and are not stale.
    ///
    /// One at a time, because the ears hold one thing. Ties go to the lower
    /// id so the choice is the same every time it is asked.
    ///
    /// A stale feed gives the ears up. A number that has stopped being true
    /// is worse than no number in the one place that is only ever glanced at,
    /// and the card — which can say how old it is — still has it.
    public static func compactFeed(among activities: [Activity]) -> Activity? {
        var best: (activity: Activity, updatedAt: TimeInterval)?
        for activity in activities {
            guard activity.restsInEars, case .feeds(let payload) = activity.payload else { continue }
            if let current = best {
                if payload.updatedAt < current.updatedAt { continue }
                if payload.updatedAt == current.updatedAt,
                   activity.id.source >= current.activity.id.source { continue }
            }
            best = (activity, payload.updatedAt)
        }
        return best?.activity
    }
}

/// When a feed's level is worth the notch's attention.
public enum FeedAttention {

    /// Whether a feed going from `previous` to `current` should stand the
    /// notch up.
    ///
    /// Only a step into critical from something that was not. A feed seen for
    /// the first time (`previous == nil`) is a baseline, the way a Focus
    /// already on at launch is: a limit that was already reached before Ledge
    /// started is not news, and a producer rewriting the file every minute
    /// must not make the same fact news every minute.
    public static func isEscalation(from previous: FeedLevel?, to current: FeedLevel) -> Bool {
        guard let previous else { return false }
        return previous != .critical && current == .critical
    }
}
