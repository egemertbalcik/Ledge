import Foundation

/// When each paused track was paused, so its card can be retired at the right
/// moment — once, from the pause itself.
///
/// The subtlety this exists for: the card is retracted whenever something else
/// takes the system's now-playing slot (a browser clip, say) and republished
/// when that goes away again. Dating the pause from the republish let a track
/// paused in the morning still be in the cycle at lunch, as long as something
/// kept interrupting it. So the date is kept against the *track*, and survives
/// the card being taken away and put back.
///
/// Pure and clockless, like `RestRelease` and `MediaLinger`: the caller passes
/// `now`.
public struct PauseClock: Equatable, Sendable {

    /// Player and track together. A republished card is a new activity
    /// describing the same track, so the activity cannot be the identity.
    public typealias Key = String

    /// The pause the current run of the card is counting, if it is counting
    /// one. A named pair rather than a tuple, so the type can be `Equatable`
    /// like its siblings and be compared in a test.
    private struct Run: Equatable, Sendable {
        var key: Key
        var since: TimeInterval
    }

    private var running: Run?

    /// When each track was paused, across interruptions. Small by
    /// construction: entries go as tracks play again or their cards retire.
    private var byTrack: [Key: TimeInterval] = [:]

    /// Tracks whose cards have been retired, oldest first.
    ///
    /// Retirement has to outlive the reading that caused it. Forgetting the
    /// date was enough to take the card away once — and then the next poll,
    /// the same paused track with nobody having touched anything, found no
    /// date, started a fresh quarter of an hour, and put the card straight
    /// back. A card the user had watched expire returned seconds later and sat
    /// there for another fifteen minutes.
    ///
    /// Three things end a retirement and nothing else does: the track plays
    /// again, a different track arrives (a different key, which was never
    /// retired), or the user presses something.
    private var retiredTracks: [Key] = []

    /// How many retirements are remembered. Nothing else prunes this list, so
    /// it is bounded here and the oldest is dropped first — generous for the
    /// handful of players and tracks that can be sitting paused at once.
    public static let retiredMemory = 16

    public init() {}

    /// The track is playing: it owes no pause, it has earned a fresh one for
    /// whenever it stops, and it is no longer retired — playing again is the
    /// plainest statement there is that somebody came back to it.
    public mutating func playing(_ key: Key) {
        running = nil
        byTrack[key] = nil
        retiredTracks.removeAll { $0 == key }
    }

    /// Whether this track's card has already been retired and must not be put
    /// back by a reading that says nothing new.
    public func isRetired(_ key: Key) -> Bool {
        retiredTracks.contains(key)
    }

    /// The user pressed a transport button. A press is the one unambiguous
    /// sign that somebody is at the keyboard, so every retirement is lifted:
    /// a card that refused to come back after a press would read as the
    /// transport being dead.
    public mutating func userAsked() {
        retiredTracks.removeAll()
    }

    /// When this paused track's pause began.
    ///
    /// - Parameter continuing: whether this is the same track the last reading
    ///   saw. The three cases are not interchangeable — the same track still
    ///   paused (the clock already running), a different track (its own clock,
    ///   from its own memory or from now), and this same track coming back
    ///   after something else held the slot, which arrives looking like a
    ///   different one and is exactly what the memory is for.
    public mutating func pausedSince(
        _ key: Key,
        continuing: Bool,
        now: TimeInterval
    ) -> TimeInterval {
        let started: TimeInterval
        if continuing, let running, running.key == key {
            started = running.since
        } else {
            started = byTrack[key] ?? now
        }
        running = Run(key: key, since: started)
        byTrack[key] = started
        return started
    }

    /// The card has been retired. The track is remembered as retired until it
    /// plays again or the user asks for it, so the reading that follows — the
    /// same paused track, unchanged — cannot hand it a fresh quarter of an
    /// hour and put the card back up.
    public mutating func retired(_ key: Key) {
        byTrack[key] = nil
        if running?.key == key { running = nil }
        guard !retiredTracks.contains(key) else { return }
        retiredTracks.append(key)
        if retiredTracks.count > Self.retiredMemory { retiredTracks.removeFirst() }
    }

    /// The card has been taken off screen — by a refusal, or by another player
    /// taking the slot. The run stops counting; the track keeps its date.
    public mutating func cardWentAway() {
        running = nil
    }
}
