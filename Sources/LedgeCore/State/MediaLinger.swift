import Foundation

/// How long a paused track may keep its place in the ears.
///
/// The rule sounds like one sentence — "a paused track stays for a couple of
/// minutes" — and is three, each of which was learned from a bug:
///
/// - It must be the track that *was* resting. A paused track that merely turns
///   up gets a card and nothing more. Scrolling a feed showed why: the
///   browser's own media cannot hold the ears, so every gap between clips let
///   the fallback name a player still holding a track paused hours ago, and
///   each of those arrivals looked exactly like the user having just paused
///   something.
///
/// - One pause gets one stay. Every hand-back of the system's now-playing slot
///   republishes the card, and each republish used to start the whole two
///   minutes again — so a track stopped long ago kept surfacing for as long as
///   the scrolling went on.
///
/// - An interrupted stay resumes rather than restarting, which is the same
///   fact from the other side: the deadline belongs to the pause.
///
/// Pure and clockless, like `RestRelease`: the caller passes `now` and owns the
/// timer. This type only answers what is allowed.
public struct MediaLinger: Equatable, Sendable {

    /// What a track is, for this purpose: the player and the track, not the
    /// card. A republished card is a new `Activity` describing the same track.
    public typealias Key = String

    /// The track that last held the ears while it was playing. Only this one
    /// may stay when it stops.
    public private(set) var restingKey: Key?

    /// When each paused track's stay runs out. Small by construction: a
    /// handful of tracks in a session, dropped as they play again.
    private var deadlines: [Key: TimeInterval] = [:]

    /// When the island went quiet on a claim that had no stay running yet, so
    /// the claim can be kept for a moment and then let go.
    private var absentSince: TimeInterval?

    /// How long a claim survives the island going quiet before a stay has
    /// started. Long enough to cover a player that drops out of sight and
    /// comes back, short enough that it cannot reach across a gap a person
    /// would notice.
    public static let unknownGrace: TimeInterval = 10

    public init() {}

    /// A track is playing and holding the ears. It earns a fresh stay for when
    /// it stops.
    public mutating func nowResting(_ key: Key?) {
        if let key { deadlines[key] = nil }
        restingKey = key
        // Seen resting: there is no absence to time.
        absentSince = nil
    }

    /// Nothing rests at all any more — so nothing has a stay owing to it. A
    /// track that has been away and comes back paused must not inherit the
    /// courtesy from whatever played last.
    ///
    /// With one exception, and it is what makes a blink survivable: a track
    /// whose stay is *already running* keeps its claim. The island can go
    /// quiet for a moment without the user doing anything — a player that
    /// drops out of the running-application list and straight back in — and
    /// that moment used to cost the pause everything. The card returned half a
    /// second later, its stay was refused as never having rested, and the
    /// island stayed shut for the remainder of the pause.
    ///
    /// The exception is not the hole the rest of this type exists to close: a
    /// stay only runs because this track was playing and then stopped inside
    /// the last stay's length, so a track paused hours ago has none to keep
    /// and is forgotten exactly as before.
    ///
    /// A claim with no stay running yet is kept too, but only for
    /// `unknownGrace` and only from this moment. That is the gap between a
    /// track *playing* and the first paused reading of it: the source can go
    /// quiet in between — a native player with no scripting fallback does
    /// exactly this — and the pause that follows had no deadline to protect
    /// it. The grace is timed from the absence rather than from when the
    /// track last played, so it expires on its own however long the track had
    /// been playing beforehand.
    public mutating func nothingRests(now: TimeInterval) {
        guard let key = restingKey else {
            absentSince = nil
            return
        }
        if let deadline = deadlines[key], deadline > now {
            // A running stay already protects it; there is no absence to time.
            absentSince = nil
            return
        }
        // Keep the claim, but start its clock. `paused` lets it go.
        if absentSince == nil { absentSince = now }
    }

    /// Lets go of a claim whose grace has run out. Checked where the claim is
    /// used rather than on a timer: this type is clockless, and the caller
    /// only ever asks when something has actually happened.
    private mutating func expireAbsence(now: TimeInterval) {
        guard let since = absentSince, now - since >= Self.unknownGrace else { return }
        restingKey = nil
        absentSince = nil
    }

    /// What a paused track may have.
    public enum Verdict: Equatable, Sendable {
        /// It was never in the ears; it gets a card and no more.
        case neverRested
        /// Its stay has been used up.
        case spent
        /// It keeps the ears for this long — the remainder of one stay, not a
        /// fresh one.
        case stays(TimeInterval)
    }

    /// Whether this paused track may keep the ears, and for how long.
    ///
    /// - Parameters:
    ///   - key: the paused track, or nil when there is nothing to identify.
    ///   - full: the whole stay a pause is worth, from the preference.
    ///   - now: the caller's clock.
    public mutating func paused(
        _ key: Key?,
        full: TimeInterval,
        now: TimeInterval
    ) -> Verdict {
        expireAbsence(now: now)
        guard key == restingKey else { return .neverRested }
        guard let key else {
            // Nothing to remember it by — and nothing to remember it *from*,
            // since an unidentifiable track cannot have been the resting one
            // unless that was unidentifiable too. It gets the plain stay.
            return .stays(full)
        }
        let deadline = deadlines[key] ?? now + full
        deadlines[key] = deadline
        let remaining = deadline - now
        return remaining > 0 ? .stays(remaining) : .spent
    }
}
