import Foundation

/// The position a scrub asked for, held on screen until the player agrees.
///
/// A drag ends and the bar has to show something while the player catches up.
/// It used to show the asked-for position for a flat 600ms and then fall back
/// to whatever the last reading said — which, for a player that had not acted
/// yet, was the position before the drag. So the bar went where you put it,
/// jumped back to where it started, and arrived a second later: one seek drawn
/// as three movements, and the middle one backwards.
///
/// A longer timer is not the fix. A timer knows nothing about the player, and
/// the thing being waited for is the player. What ends the hold is the player
/// agreeing, the song changing, the command being refused outright, or a
/// deadline past which holding stops being honest rather than patient.
///
/// Scoped to the item on purpose: a position means nothing without the song it
/// was measured in, and drawing the old song's position over its successor is
/// how a skip during a scrub used to show the wrong place.
///
/// Pure and clockless, like `PlaybackIntent` and `PauseClock`: the caller
/// passes `now`.
public struct SeekIntent: Equatable, Sendable {

    /// How near the player has to land for the seek to count as done.
    ///
    /// Players answer with the position they actually reached, not the one
    /// that was asked for, and a beat passes between the two. Demanding
    /// exactness would hold every seek to its deadline.
    public static let tolerance: TimeInterval = 2.5

    /// How long a seek may go unacknowledged before the player's own position
    /// wins, whatever it says.
    ///
    /// Longer than the command queue's own four-second expiry plus the beat it
    /// takes to act and be read back. Past it there is nothing left to wait
    /// for: either the command was dropped or the player is not answering, and
    /// a bar still pointing at a place nothing is going to is a lie.
    public static let deadline: TimeInterval = 6

    private struct Ask: Equatable, Sendable {
        var item: String
        var position: TimeInterval
        var at: TimeInterval
    }

    private var ask: Ask?

    public init() {}

    /// Whether the bar is currently speaking for the player.
    public func isWaiting(at now: TimeInterval) -> Bool {
        guard let ask else { return false }
        return now - ask.at < Self.deadline
    }

    /// The user let go of the bar, and something left the app.
    ///
    /// - Parameter from: where the player was when they asked.
    ///
    /// A seek shorter than the tolerance has nothing to hold for, and holding
    /// for it does harm. The first reading back is the poll that was already
    /// in flight — the player's position from *before* the press — and for a
    /// short seek that reading is already "near enough" to the target. So the
    /// hold ended before the player had moved at all, and the bar snapped back
    /// to where the drag started: the backward jump this whole type exists to
    /// remove, reappearing for every small nudge of the bar. Two seconds out
    /// of a three-minute track is a few pixels, so showing the player's own
    /// position straight away costs nothing and cannot lie.
    public mutating func asked(
        for position: TimeInterval,
        from: TimeInterval,
        on item: String,
        at now: TimeInterval
    ) {
        guard abs(position - from) > Self.tolerance else {
            ask = nil
            return
        }
        ask = Ask(item: item, position: position, at: now)
    }

    /// Nothing left the app. There is nothing to wait for, and the bar must
    /// not point at a place the player was never asked to go to.
    public mutating func refused() { ask = nil }

    /// A different song is on. The position belonged to the one before it.
    public mutating func itemChanged() { ask = nil }

    /// The player said where it is.
    ///
    /// This is what ends a hold, which is why it is separate from `displayed`:
    /// arrival has to be *remembered*, or a player that drifts on past the
    /// target afterwards would be read as having never arrived and the bar
    /// would jump backwards to the asked-for position.
    public mutating func reconcile(
        reported: TimeInterval,
        on item: String,
        at now: TimeInterval
    ) {
        guard let ask else { return }
        let arrived = abs(reported - ask.position) <= Self.tolerance
        if arrived || ask.item != item || now - ask.at >= Self.deadline {
            self.ask = nil
        }
    }

    /// Where the bar should be. Pure — `reconcile` is what ends a hold; the
    /// guards here only keep a hold from outliving its item or its deadline.
    public func displayed(
        reported: TimeInterval,
        on item: String,
        at now: TimeInterval
    ) -> TimeInterval {
        guard let ask, ask.item == item, now - ask.at < Self.deadline
        else { return reported }
        return ask.position
    }
}
