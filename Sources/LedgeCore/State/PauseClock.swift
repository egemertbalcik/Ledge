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

    public init() {}

    /// The track is playing: it owes no pause, and has earned a fresh one for
    /// whenever it stops.
    public mutating func playing(_ key: Key) {
        running = nil
        byTrack[key] = nil
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

    /// The card has been retired for good. The next time this track is seen
    /// paused it starts its own clock, because by then it will have been played
    /// again to get there.
    public mutating func retired(_ key: Key) {
        byTrack[key] = nil
        if running?.key == key { running = nil }
    }

    /// The card has been taken off screen — by a refusal, or by another player
    /// taking the slot. The run stops counting; the track keeps its date.
    public mutating func cardWentAway() {
        running = nil
    }
}
