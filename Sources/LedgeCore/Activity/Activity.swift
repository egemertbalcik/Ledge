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

    /// Default ordering weight. Higher wins a place nearer the front.
    ///
    /// Transient, interruptive things outrank ambient ones: a device connecting
    /// is news, whereas what is playing is a standing fact you can cycle to.
    public var defaultPriority: Int {
        switch self {
        // A recording indicator outranks everything: it is the one card whose
        // absence would actually matter.
        case .privacy: 75
        case .keyboard: 72
        case .message: 70
        // Interruptive and time-bound, like a notification.
        // A standing container, not news: parked files should be reachable by
        // cycling, never the first thing the notch shows — at 65 every
        // screenshot yanked the screen away from whatever mattered.
        case .shelf: 24
        case .device: 60
        case .power: 55
        case .event: 50
        // A running session outranks an ambient Focus card, but a meeting about
        // to start still wins. The finishing publish overrides this upward.
        case .timer: 45
        case .focus: 40
        case .nowPlaying: 30
        // Ambient by design: a standing widget you cycle to, never something
        // that pushes in front of actual news.
        case .weather: 10
        // A control surface, not information: sound and brightness sliders
        // for the mouse. Behind weather, ahead of the timer launcher.
        case .levels: 8
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
        case .event(let payload):
            return payload.hasEvent && payload.startsIn <= 60 * 60 && payload.startsIn >= -60
        case .levels, .shelf:
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
public enum CompactRest {

    /// - Parameter standing: a fact that is simply true until it stops being
    ///   true — VoiceOver running. It sits below everything with a clock on
    ///   it, because those are the ones that will be gone in a moment and this
    ///   one will still be here afterwards.
    public static func resolve(
        farewell: Activity?,
        playingNowPlaying: Activity?,
        runningTimer: Activity?,
        closeEvent: Activity?,
        nowPlaying: Activity?,
        selected: Activity?,
        standing: Activity? = nil
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
        if let standing { return standing }
        // The last resort is the only one that is not already a live fact, so
        // it is the only one that has to earn its place.
        if let selected, selected.restsInEars { return selected }
        return nil
    }
}
