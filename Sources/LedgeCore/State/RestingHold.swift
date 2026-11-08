/// Whether the island may rest, from its two sources.
///
/// The facts — music, a timer, a meeting, a paused track inside its linger —
/// and a feed resting in the ears. Kept apart so either can change without
/// the other having to: the feed is the lowest resident and the only one that
/// does not come and go, so when everything else lets go of the island it is
/// what is left, and when it goes the island follows the facts again.
///
/// A feed used to reach the shell only folded into the music's "present", so
/// with a paused track in Now Playing a feed could come or go unheard: the
/// island stayed shut for a new feed, or open and empty after one left.
///
/// Clockless and notch-free, like `RestRelease`, so the rules can be tested.
/// Each change answers what to tell the reducer, or nil for nothing.
public struct RestingHold: Equatable, Sendable {

    public private(set) var facts = false
    public private(set) var feed = false

    public init() {}

    /// What the reducer's `hasNowPlaying` should be, and what a farewell hands
    /// back when it ends.
    public var holds: Bool { facts || feed }

    /// The facts changed. Always said, as the fact path always has: its
    /// callers rely on the reducer hearing every fact, changed or not.
    public mutating func factsChanged(_ holds: Bool) -> Bool {
        facts = holds
        return self.holds
    }

    /// A feed started or stopped resting.
    ///
    /// Said only when the combined hold changes, and never over a farewell:
    /// the farewell borrows `hasNowPlaying` for its seconds and hands `holds`
    /// back itself when it ends, so a feed that went meanwhile is not lost.
    public mutating func feedChanged(_ rests: Bool, farewellRunning: Bool) -> Bool? {
        let before = holds
        feed = rests
        guard holds != before, !farewellRunning else { return nil }
        return holds
    }
}
