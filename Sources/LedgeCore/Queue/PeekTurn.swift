import Foundation

/// Who gets the stage when a peek arrives while the notch is busy.
///
/// Most arrivals wait their turn behind whatever has the stage and play when
/// it clears. Keyboard facts could not: a layout switch lives a second and a
/// Caps Lock toggle 1.6, both shorter than the two-second peek they waited
/// behind, so by the time the stage cleared their card had expired and the
/// queue dropped them without a word. Caps Lock toggled, then a layout switch
/// inside two seconds, and the switch never showed — nor did one made over a
/// track change, an AirPods connect, or an open stack under the pointer.
public enum PeekTurn {

    /// Whether `arrival` takes over the peek on screen instead of queueing.
    ///
    /// A keyboard fact does, over a whisper that does not outrank it: it is
    /// the newest fact about the keyboard, the user is typing *now*, and the
    /// same flash two seconds later comes after the first wrong word. It is
    /// the same move as Caps Lock restarting its own peek in place.
    ///
    /// What it may not cut off is a notch that stood up for news — a timer
    /// ending, a hold that came back on its own — or a card that outranks it,
    /// which today is the recording indicator. Those keep the stage, and the
    /// keyboard fact waits with a copy of itself: see `PendingPeek`. What it
    /// does cut short is put back to play after it: `PendingPeek.resume`.
    ///
    /// Keyboard facts only. Everything else lives long enough to wait, and
    /// letting it cut in would bring back latest-wins, the rule the queue
    /// replaced because the loser never appeared.
    public static func takesOver(
        _ arrival: Activity, from onScreen: Activity?, standingUp: Bool
    ) -> Bool {
        // Nothing known on screen — a debug flash of the selection — and
        // nothing to weigh the arrival against: it waits.
        guard arrival.kind == .keyboard, let onScreen, !standingUp else { return false }
        return onScreen.priority <= arrival.priority
    }
}

/// A peek that arrived while the stage was taken, waiting for its turn.
public struct PendingPeek: Equatable, Sendable {

    /// The full id, not the kind: two queued device connects must each
    /// flash their own card, not the first `.device` in the queue twice.
    public let id: ActivityID
    /// When it arrived, so a stale entry can be dropped at drain time.
    public let at: TimeInterval
    /// A confirmation of the user's own press, which Focus lets through.
    public let byUser: Bool
    /// The card as it arrived — kept for keyboard facts alone.
    ///
    /// A queued entry whose card has left the activity queue is dropped when
    /// its turn comes, and rightly for everything else: a device that has
    /// since gone, re-announced, would be news that is no longer true. A
    /// keyboard card leaves within two seconds whatever happens, which is
    /// shorter than anything it can wait behind — a peek, an announcement, an
    /// open stack, a held readout — while the layout it names is still the
    /// one in use.
    public let copy: Activity?

    public init(_ activity: Activity, at: TimeInterval, byUser: Bool) {
        id = activity.id
        self.at = at
        self.byUser = byUser
        copy = activity.kind == .keyboard ? activity : nil
    }

    /// What to show when this entry's turn comes: the live card, or for a
    /// keyboard fact whose card has expired the copy it brought. Nil means
    /// there is nothing left to announce.
    ///
    /// The copy plays only while the provider that published it is still on.
    /// It does not need its live card, so switching the indicator off in
    /// Settings — which takes the provider's cards away — left it free to
    /// flash once more, inside its eight seconds, for a feature the user had
    /// just turned off.
    public func card(live: Activity?, publisherRunning: Bool) -> Activity? {
        live ?? (publisherRunning ? copy : nil)
    }

    /// Queues `entry` behind the stage, `limit` entries at most.
    ///
    /// Two rules for keyboard facts, both following from the copy:
    /// - The same card already waiting takes the newer copy in its place,
    ///   rather than queueing twice. Live cards are looked up again at drain
    ///   time, so for them a second entry only replays the same card; a copy
    ///   is frozen, and two switches made behind one peek replayed the first,
    ///   stale layout before the one in use.
    /// - They wait at the front, ahead of anything that is not a keyboard
    ///   fact, for the reason they cut in: the stage clearing is when the
    ///   eyes come back, and they come back to type. The rest keep their
    ///   order.
    public static func enqueue(_ entry: PendingPeek, into queue: inout [PendingPeek], limit: Int) {
        if entry.copy != nil, let waiting = queue.firstIndex(where: { $0.id == entry.id }) {
            queue[waiting] = entry
            return
        }
        guard queue.count < limit else { return }
        if entry.copy != nil {
            queue.insert(entry, at: queue.firstIndex(where: { $0.copy == nil }) ?? queue.endIndex)
        } else {
            queue.append(entry)
        }
    }

    /// Puts back the card a keyboard fact just cut short, to play once the
    /// keyboard's own flash is over.
    ///
    /// The cut-in took the stage from a whisper that had had only part of
    /// its peek — an AirPods connect, a message, the low-battery whisper
    /// Focus lets through, a track change — and nothing brought it back: the
    /// layout flipping on an app switch could take an announcement off screen
    /// a fifth of a second in. Nothing comes back when:
    /// - the arrival is the same card restarting itself;
    /// - the card cut short is a keyboard fact too. The newer keyboard fact
    ///   is what is true now, and putting the older one back would bounce
    ///   Caps Lock and the layout off each other for as long as both kept
    ///   arriving;
    /// - its card has left the activity queue, so it was going anyway;
    /// - it is already waiting;
    /// - the queue is full. Those entries have not been seen at all, and this
    ///   one has.
    ///
    /// It goes back ahead of every waiting card that is not a keyboard fact —
    /// it had the stage before any of them — and behind the keyboard facts,
    /// for the reason they cut in. Stamped `time`, the moment it lost the
    /// stage, so the queue's lifetime runs from there like anyone's. A second
    /// switch restarts the keyboard flash in place and puts nothing back; a
    /// switch landing on the card once it replays cuts it short again, and it
    /// comes back again, behind that one.
    public static func resume(
        _ onScreen: Activity?, cutShortBy arrival: Activity, isLive: Bool,
        at time: TimeInterval, into queue: inout [PendingPeek], limit: Int
    ) {
        guard let onScreen, onScreen.id != arrival.id, onScreen.kind != .keyboard, isLive,
              !queue.contains(where: { $0.id == onScreen.id }), queue.count < limit
        else { return }
        queue.insert(
            PendingPeek(onScreen, at: time, byUser: false),
            at: queue.firstIndex(where: { $0.copy == nil }) ?? queue.endIndex
        )
    }
}
