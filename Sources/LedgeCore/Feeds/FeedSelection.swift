import Foundation

/// Which feed has the closed notch.
public enum FeedSelection {

    /// The feed whose compact text goes in the ears.
    ///
    /// The one already there keeps them for as long as it still has something
    /// to say. Without that, two feeds written at different rhythms would trade
    /// the ears on every write, and the notch would change its content and its
    /// width every few seconds for no reason the user could see.
    ///
    /// Otherwise the most recently updated of those that have compact text and
    /// are not stale. Ties go to the lower id so the choice is the same every
    /// time it is asked.
    ///
    /// A stale feed gives the ears up. A number that has stopped being true
    /// is worse than no number in the one place that is only ever glanced at,
    /// and the card — which can say how old it is — still has it.
    public static func compactFeed(among activities: [Activity], keeping current: ActivityID? = nil) -> Activity? {
        if let current,
           let incumbent = activities.first(where: { $0.id == current }),
           incumbent.restsInEars, case .feeds = incumbent.payload {
            return incumbent
        }
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

    /// Whether a feed going from `previous` to `current` is a step into
    /// critical.
    ///
    /// Only a step from something that was not critical. A feed seen for the
    /// first time (`previous == nil`) is a baseline, the way a Focus already
    /// on at launch is: a limit that was already reached before Ledge started
    /// is not news. Whether the step is also *allowed* to peek is
    /// `FeedEscalations`' to say.
    public static func isEscalation(from previous: FeedLevel?, to current: FeedLevel) -> Bool {
        guard let previous else { return false }
        return previous != .critical && current == .critical
    }
}

/// What each feed's level was, and when it last made the notch peek.
///
/// A step into critical peeks once, and then not again for that feed until
/// `cooldown` has passed. Without the cooldown a reading that sits on its
/// threshold — 89% warning, 91% critical, 89%, 91% — made the notch peek on
/// every crossing, for as long as it hovered there.
///
/// Clockless, like `MediaLinger`: the caller says what time it is, so the
/// rules can be tested without waiting.
public struct FeedEscalations: Sendable {

    /// How long a feed that has peeked stays quiet, whatever it does.
    public static let cooldown: TimeInterval = 30 * 60

    private var levels: [ActivityID: FeedLevel] = [:]
    private var lastPeek: [ActivityID: TimeInterval] = [:]

    public init() {}

    /// Records a feed's level and says whether it may peek now.
    ///
    /// Saying yes starts nothing. The notch can still turn the peek down —
    /// during a Focus, over the greeting — and a peek nobody saw must not
    /// silence the next real one for half an hour, so the cooldown starts
    /// only at `didPeek`.
    public mutating func observe(_ id: ActivityID, level: FeedLevel, now: TimeInterval) -> Bool {
        let previous = levels[id]
        levels[id] = level
        guard FeedAttention.isEscalation(from: previous, to: level) else { return false }
        if let last = lastPeek[id], now - last < Self.cooldown { return false }
        return true
    }

    /// The notch took the peek `observe` allowed: shown, or waiting its turn.
    public mutating func didPeek(_ id: ActivityID, now: TimeInterval) {
        lastPeek[id] = now
    }

    /// The feed is gone for good: its file was removed, or Feeds was turned
    /// off. A card that is merely out of the queue for a while — dismissed by
    /// the user — keeps its level, so that coming back already critical is
    /// still read against what it was.
    public mutating func forget(_ id: ActivityID) {
        levels[id] = nil
        lastPeek[id] = nil
    }

    public mutating func forgetAll() {
        levels.removeAll()
        lastPeek.removeAll()
    }

    /// Everything known, for tests and for dropping feeds that have gone.
    public var knownIDs: Set<ActivityID> { Set(levels.keys) }
}
