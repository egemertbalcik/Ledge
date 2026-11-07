import CoreGraphics
import Foundation

/// The categories of thing the notch can show.
public enum ActivityKind: String, Equatable, Sendable, CaseIterable, Codable {
    case nowPlaying
    case device
    case power
    case focus
    case event
    case message
    case weather
    case timer
    case shelf
    case privacy
    case keyboard
    case levels
    case notes
    case keepAwake
    case feeds

    /// Default ordering weight. Higher wins a place nearer the front.
    ///
    /// News comes first: a device connecting is something that just happened.
    /// Everyday cards follow in one fixed order, cards with something to read
    /// ahead of controls and containers, so moving through them always goes
    /// the same way. What they are doing does not move them: `Urgency` lets
    /// only real news jump ahead.
    public var defaultPriority: Int {
        switch self {
        // A recording indicator outranks everything: it is the one card whose
        // absence would actually matter.
        case .privacy: 75
        case .keyboard: 72
        case .message: 70
        // Interruptive and time-bound, like a notification.
        case .device: 60
        case .power: 55

        // The everyday order. All of it stays under the news above.
        case .nowPlaying: 50
        case .event: 48
        case .weather: 46
        case .focus: 44
        // A condition the user set and stopped thinking about, on or off.
        case .keepAwake: 42
        // Something a script wrote down for the user to read, after the cards
        // the app makes itself and ahead of the controls.
        case .feeds: 41
        case .levels: 40
        // The launcher and a running session sit in the same place. Only a
        // finished session is news: see `Urgency`.
        case .timer: 38
        case .notes: 36
        // Parked files should be reachable by moving through the cards, never
        // the first thing the notch shows. At 65 every screenshot yanked the
        // screen away from whatever mattered.
        case .shelf: 34
        }
    }
}

/// Identity for deduplication.
///
/// Two activities with the same id are the *same thing*, so a second one
/// replaces the first in place rather than stacking. `source` distinguishes
/// simultaneous instances of a kind — two Bluetooth devices, two calendar
/// events — so they can coexist.
public struct ActivityID: Hashable, Sendable, Codable {
    public let kind: ActivityKind
    public let source: String

    public init(kind: ActivityKind, source: String) {
        self.kind = kind
        self.source = source
    }
}

public struct Activity: Identifiable, Equatable, Sendable {

    public let id: ActivityID
    public var priority: Int

    /// Monotonic timestamp supplied by the caller. The core never reads a clock,
    /// so ordering is reproducible in tests.
    public var createdAt: TimeInterval

    /// How long this should live if nothing retracts it. `nil` means it stays
    /// until its provider takes it away.
    public var expiresAfter: TimeInterval?

    public var payload: ActivityPayload

    public init(
        id: ActivityID,
        priority: Int? = nil,
        createdAt: TimeInterval,
        expiresAfter: TimeInterval? = nil,
        payload: ActivityPayload
    ) {
        self.id = id
        self.priority = priority ?? id.kind.defaultPriority
        self.createdAt = createdAt
        self.expiresAfter = expiresAfter
        self.payload = payload
    }

    public var kind: ActivityKind { id.kind }
}

extension Activity {

    /// Whether this may sit in the ears while nothing is happening.
    ///
    /// The compact view is for things that are *going on*: a track playing, a
    /// countdown running, a meeting about to start. Several cards exist to be
    /// opened rather than watched, and resting one of them puts a number in
    /// the notch that answers no question:
    ///
    /// - **An idle timer** is a launcher. Cancelling a countdown leaves it
    ///   behind showing the default work length — a notch reading 25:00 for a
    ///   timer nobody started.
    /// - **Paused music** rests only for its linger, which the companion
    ///   already governs; looking at the card must not restart it.
    /// - **Levels and the shelf** are control surfaces. Neither has news.
    /// - **A calendar with nothing imminent** is a reference, not an event;
    ///   only a meeting inside the hour earns the ears.
    /// - **Keep Awake** rests only while it is holding the Mac awake. Its
    ///   Ready card is a launcher like the timer's, and its Finished card is a
    ///   sentence to read once, not a standing fact to watch.
    /// - **A feed** rests only if its producer gave the ears something to say,
    ///   and only while that is still true. A feed that has gone stale keeps
    ///   its card, which can say how old it is; the ears cannot.
    ///
    /// Announcements are not covered by this rule — a peek is explicitly news
    /// and shows whatever it is announcing, including a shelf drop.
    public var restsInEars: Bool {
        switch payload {
        case .nowPlaying(let payload):
            // Playing music rests for as long as it plays. Paused music rests
            // only through its linger, which the companion runs on its own —
            // so it must not earn a fresh rest here by being *looked at*.
            // Opening the media card to see what was on, then leaving without
            // pressing play, used to put the track back in the ears.
            //
            // Video rests on the same terms, unless it has been turned out of
            // the compact view or is too short to be worth opening for — both
            // of which the provider has already decided.
            return payload.isPlaying && payload.showsInCompact
        case .timer(let payload):
            return !payload.isIdle
        case .keepAwake:
            // Never, running or not. A hold is announced the way a Focus
            // change is — the cup and its state for a moment — and then it
            // is a fact about the Mac, not something going on in front of the
            // user. Resting here let it back in through the last rung of
            // `CompactRest` the moment its card was the selected one, which
            // was every time it had just been started: the cup stayed in the
            // ear for the whole hold, and a disc with the same cup sat beside
            // it. The side readout carries it whenever the island is held by
            // something else.
            return false
        case .event(let payload):
            return payload.hasEvent && payload.startsIn <= 60 * 60 && payload.startsIn >= -60
        case .feeds(let payload):
            return payload.hasCompactText && !payload.isStale
        case .levels, .shelf, .notes:
            return false
        default:
            return true
        }
    }
}

extension Activity {

    /// Whether this arriving card is *news*.
    ///
    /// Most arrivals are: a track started, AirPods connected, a timer
    /// finished. The timer's launcher is the exception — it arrives every time
    /// a countdown ends or is cancelled, and announcing it flashed the default
    /// work length in the ears for a timer nobody had started. Its arrival is
    /// the *absence* of a timer, which is not something to say out loud.
    ///
    /// Distinct from `restsInEars`: the shelf never rests, but a file landing
    /// on it is genuinely news.
    public var isWorthAnnouncing: Bool {
        switch payload {
        case .timer(let payload):
            return !payload.isIdle
        case .keepAwake(let payload):
            switch payload.phase {
            case .ready:
                // The launcher, exactly as the timer's: its arrival is the
                // absence of a session.
                return false
            case .running:
                // Starting is something the user just did and is looking at.
                // A session picked up again is not: it comes back on its own
                // after a relaunch, and the first the user knows of it is the
                // notch saying so. The provider marks that publish by carrying
                // what was given back in `resumable`.
                return payload.resumed
            case .finished(let reason):
                // A session ending on its own is a power change nobody asked
                // for at that moment, which is the whole reason each reason
                // has a sentence. Quitting and switching the card off are the
                // two that have no surface left to say it on.
                return reason.isVisible
            }
        case .nowPlaying(let payload):
            // Nothing that has no place in the ears announces itself into
            // them: the peek would flash a card and hand back to an empty
            // island.
            //
            // And a *paused* track is never news, however it arrives. Its card
            // is republished whenever something else lets go of the system's
            // now-playing slot — which, while a feed is scrolling, is every
            // few seconds — and each of those arrivals flashed a track that
            // had been stopped for hours. Announcing is for something that
            // started.
            return payload.isPlaying && payload.showsInCompact
        case .feeds:
            // A status somebody else keeps, rewritten whenever its producer
            // likes — often every minute. Nothing about a file changing is
            // news, and a card that announced itself each time would be the
            // notch tapping the user on the shoulder for a number that did
            // not move. The one thing that is news, a feed turning critical,
            // is the coordinator's to say: it is the only place that has seen
            // the level before.
            return false
        case .notes:
            // Saving a note is not an event. The card republishes on every
            // keystroke's worth of debounce, and announcing any of that would
            // flash the island while the user is typing into a window in
            // front of it.
            return false
        case .levels:
            // A control surface, not news — the same reason it never rests in
            // the ears. Its card arrives the first time a level is touched,
            // which is a side effect of the user pressing a key, and the
            // readout they pressed it for is already on screen. Announcing it
            // took the whole compact view for that first press while every
            // press after it showed as a companion beside the music, because
            // only the first is an arrival.
            return false
        default:
            return true
        }
    }
}

/// What the ears draw while the island rests.
///
/// The precedence lives here, as a pure function, because it is a *rule*
/// rather than a view detail: a farewell outranks the residents for its four
/// seconds, then playing music, then a running timer, then an imminent
/// meeting, then paused music inside its linger. Only then the card the user
/// last looked at — and only if that card has any business resting.
///
/// Keep Awake is deliberately absent. It is announced like a Focus change and
/// then lives in the side readout; see `Activity.restsInEars`.
///
/// A feed's compact text is the lowest of the residents. It is a standing
/// glance, there all day, so everything that is actually going on takes the
/// ears from it — and gives them back, because the feed is still true.
public enum CompactRest {

    public static func resolve(
        farewell: Activity?,
        playingNowPlaying: Activity?,
        runningTimer: Activity?,
        closeEvent: Activity?,
        nowPlaying: Activity?,
        feed: Activity? = nil,
        selected: Activity?
    ) -> Activity? {
        // Media the compact view will not draw is turned away wherever it is
        // offered, and whatever the caller believes. Enforced here rather than
        // trusted to each caller: the one time a caller decided for itself,
        // the island opened for a video these ears then declined to draw.
        func restable(_ activity: Activity?) -> Activity? {
            guard case .nowPlaying(let payload) = activity?.payload else { return activity }
            return payload.showsInCompact ? activity : nil
        }

        if let farewell { return farewell }
        if let playingNowPlaying = restable(playingNowPlaying) { return playingNowPlaying }
        if let runningTimer { return runningTimer }
        if let closeEvent { return closeEvent }
        if let nowPlaying = restable(nowPlaying) { return nowPlaying }
        // Ahead of `selected`: the feed is a resident, and the card last read
        // is only ever a courtesy for the moment after walking away from it.
        if let feed, feed.restsInEars { return feed }
        // The last resort is the only one that is not already a live fact, so
        // it is the only one that has to earn its place.
        if let selected, selected.restsInEars { return selected }
        return nil
    }
}
