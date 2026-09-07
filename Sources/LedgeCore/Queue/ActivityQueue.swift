import Foundation

/// What a provider tells the queue.
public enum ProviderEvent: Equatable, Sendable {
    case publish(Activity)
    case retract(ActivityID)
}

/// The ordered set of things the notch can show, plus which one is on screen.
///
/// Pure and timer-free: expiry is expressed by `Activity.expiresAfter` and
/// scheduled by the shell. Everything here is deterministic, so the whole
/// interaction model is testable without a WindowServer or a clock.
public struct ActivityQueue: Equatable, Sendable {

    /// Ordered front-to-back: highest priority first, newest first within a
    /// priority.
    public private(set) var activities: [Activity] = []

    /// The activity currently on screen. Always either `nil` (queue empty) or
    /// present in `activities` — never a dangling id.
    public private(set) var selectedID: ActivityID?

    /// Recently dismissed, most recent last, so a restore pops the right one.
    public private(set) var dismissed: [Activity] = []

    /// Whose place the last expiring event stole. The steal's contract is
    /// "until it expires, then hand it straight back" — and handing back
    /// requires remembering, because the slot arithmetic in
    /// `selectAfterRemoval` lands on whatever occupies the *event's* index,
    /// not on the card the user had cycled to. Cleared by any deliberate
    /// selection: the user moving on outranks the promise.
    private struct EventSteal: Equatable, Sendable {
        var stealer: ActivityID
        var preempted: ActivityID
    }
    private var eventSteal: EventSteal?

    /// The kind the user pinned first, folded into every score. A change
    /// while the stack is open waits for the unfreeze like everything else.
    public var pinnedKind: ActivityKind? {
        didSet { if pinnedKind != oldValue && !orderFrozen { sort() } }
    }

    /// While the open card stack is on screen, in-place score changes do not
    /// re-sort — nothing may reorder under the user's cursor. Arrivals and
    /// removals still behave normally (an announcement taking the stage is the
    /// point of an announcement). Unfreezing re-sorts once, so the world's
    /// accumulated changes land in one motion after the stack closes.
    public var orderFrozen = false {
        didSet { if !orderFrozen && oldValue { sort() } }
    }

    private func score(_ activity: Activity) -> Int {
        Urgency.score(of: activity, pinned: pinnedKind)
    }

    /// Bound on the undo stack, so a long session cannot grow it without limit.
    public static let dismissedLimit = 10

    public init() {}

    // MARK: - Reading

    public var isEmpty: Bool { activities.isEmpty }
    public var count: Int { activities.count }

    public var selected: Activity? {
        guard let selectedID else { return nil }
        return activities.first { $0.id == selectedID }
    }

    public var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return activities.firstIndex { $0.id == selectedID }
    }

    /// The activity shown alongside the selected one in duo mode: the next in
    /// the cycle. `nil` when there is nothing else to show.
    public var companion: Activity? {
        guard activities.count > 1, let index = selectedIndex else { return nil }
        return activities[(index + 1) % activities.count]
    }

    public var canRestore: Bool { !dismissed.isEmpty }

    // MARK: - Writing

    public mutating func apply(_ event: ProviderEvent) {
        switch event {
        case .publish(let activity): upsert(activity)
        case .retract(let id): retract(id)
        }
    }

    /// Inserts, or replaces an existing activity with the same id in place.
    ///
    /// Replacing in place matters: a now-playing update arrives several times a
    /// second, and re-sorting on each one would make the card the user is
    /// reading jump around.
    public mutating func upsert(_ activity: Activity) {
        // A republishing provider brings a dismissed card straight back; the
        // remembered snapshot is then stale history. Leaving it made
        // "Restore Last Dismissed" an enabled menu item whose click was a
        // visible no-op — selecting a card that was already live.
        dismissed.removeAll { $0.id == activity.id }

        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            // The *score* is part of the identity of a slot: a payload change
            // that moves the score (music pausing, a meeting entering its
            // last quarter-hour) re-ranks the queue — unless the stack is
            // open, where nothing may move under the cursor. Republises that
            // change nothing (the every-second now-playing poll) never sort.
            let scoreChanged = score(activities[index]) != score(activity)
            var replacement = activity
            // Keep the original creation time for standing cards. `createdAt`
            // is the second sort key, and a provider that re-stamps it on every
            // poll (now playing does, once a second) would otherwise silently
            // break the ordering invariant without ever triggering a re-sort.
            //
            // An *expiring* card is different: its createdAt is also its
            // expiry anchor, and preserving the old one made a repeat event —
            // a second keyboard switch, an unplug after a plug-in — die on the
            // first event's clock, sometimes instantly.
            if activity.expiresAfter == nil {
                replacement.createdAt = activities[index].createdAt
            }
            let orderChanged = scoreChanged
                || replacement.createdAt != activities[index].createdAt
            activities[index] = replacement
            if orderChanged && !orderFrozen { sort() }
            return
        }

        if orderFrozen {
            // A newcomer slots in by score, but the frozen residents keep
            // their relative order: a full sort here would flush every
            // deferred score change under the cursor — the exact reorder the
            // freeze exists to prevent, arriving disguised as an insertion.
            let pinned = pinnedKind
            let newcomer = Urgency.score(of: activity, pinned: pinned)
            let at = activities.firstIndex {
                Urgency.score(of: $0, pinned: pinned) < newcomer
            } ?? activities.endIndex
            activities.insert(activity, at: at)
        } else {
            activities.append(activity)
            sort()
        }

        // A newly arrived, more important activity takes the screen. An equal or
        // lesser one waits its turn, so a background update never yanks the user
        // away from what they deliberately cycled to.
        //
        // The exception is an activity that expires on its own. Those are
        // *events* — a layout switch, a device connecting — not status, and an
        // event that is never shown may as well not have fired. Without this a
        // standing card silently swallows every announcement beneath it: with
        // the camera in use (privacy, 75) a keyboard switch (72) was invisible,
        // and so was every Bluetooth card. It keeps the screen only until it
        // expires, and `selectAfterRemoval` then hands it straight back.
        let isEvent = activity.expiresAfter != nil
        // A standing newcomer may outrank the selection, but not while the
        // stack is open under the cursor.
        let standingSteal = !orderFrozen
            && score(activity) > selected.map({ score($0) }) ?? Int.min
        // Events used to take even a frozen stage — the steal was how an
        // announcement got shown at all. The presentation's peeked slot now
        // carries the flash, so an event arriving while the user is reading
        // an open card no longer yanks the selection out from under them; it
        // announces from the wings and the open card stays put.
        let eventTakesStage = isEvent && !orderFrozen
        if eventTakesStage, let preempted = selectedID, preempted != activity.id {
            // Chained steals keep the original owner: the hand-back goes to
            // the card the *user* chose, however many announcements interpose.
            eventSteal = EventSteal(
                stealer: activity.id,
                preempted: eventSteal?.preempted ?? preempted
            )
        }
        if selectedID == nil || eventTakesStage || standingSteal {
            selectedID = activity.id
        }
    }

    public mutating func retract(_ id: ActivityID) {
        // Dropping an activity also drops any memory of dismissing it, so a
        // later restore cannot resurrect something its provider has retired.
        // This runs *before* the guard: the common case is retracting something
        // the user already dismissed, which is not in `activities` at all.
        dismissed.removeAll { $0.id == id }

        // Promise cleanup runs even when the card itself is already gone: the
        // stealer is often dismissed first (absent here) and its provider's
        // retract arrives later — the early return below used to skip this,
        // leaving an immortal promise that grafted an ancient card onto the
        // next steal.
        defer {
            if eventSteal?.stealer == id || eventSteal?.preempted == id {
                eventSteal = nil
            }
        }

        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedID == id
        activities.remove(at: index)
        if wasSelected {
            if let steal = eventSteal, steal.stealer == id,
               activities.contains(where: { $0.id == steal.preempted }) {
                selectedID = steal.preempted
            } else {
                selectAfterRemoval(at: index)
            }
        }
    }

    /// User-initiated hide. Unlike `retract`, this is remembered so it can be
    /// undone.
    public mutating func dismiss(_ id: ActivityID) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        let activity = activities.remove(at: index)
        // One entry per activity. Dismissing the same thing twice should not
        // require two undos, the second of which would visibly do nothing.
        dismissed.removeAll { $0.id == id }
        dismissed.append(activity)
        if dismissed.count > Self.dismissedLimit {
            dismissed.removeFirst(dismissed.count - Self.dismissedLimit)
        }
        if selectedID == id {
            // A dismissed stealer hands back like an expired one — swiping the
            // announcement away is the strongest possible "give me my card".
            if let steal = eventSteal, steal.stealer == id,
               activities.contains(where: { $0.id == steal.preempted }) {
                selectedID = steal.preempted
            } else {
                selectAfterRemoval(at: index)
            }
        }
        // Either way the promise dies here: dismiss() does not go through
        // retract(), and a promise that outlives its stealer grafts an
        // ancient card onto the next steal's hand-back.
        if eventSteal?.stealer == id || eventSteal?.preempted == id {
            eventSteal = nil
        }
    }

    public mutating func dismissSelected() {
        guard let selectedID else { return }
        dismiss(selectedID)
    }

    @discardableResult
    public mutating func restoreLastDismissed(at now: TimeInterval? = nil) -> Activity? {
        guard var activity = dismissed.popLast() else { return nil }

        // The provider may have republished this id since it was dismissed —
        // now-playing does so every second. Upserting the snapshot taken at
        // dismissal time would overwrite the live one with a stale track, so
        // when a current copy exists, just select it.
        if activities.contains(where: { $0.id == activity.id }) {
            selectedID = activity.id
            // Restoring is as deliberate as selecting; the promise dies.
            eventSteal = nil
            return activities.first { $0.id == activity.id }
        }

        // An expiring card restored after its lifetime would be re-scheduled
        // against its original createdAt and retracted in the same tick — an
        // undo that visibly does nothing. Give it a fresh clock.
        if activity.expiresAfter != nil, let now {
            activity.createdAt = now
        }
        upsert(activity)
        selectedID = activity.id
        eventSteal = nil
        return activity
    }

    // MARK: - Cycling

    public mutating func cycleForward() { cycle(by: 1) }
    public mutating func cycleBackward() { cycle(by: -1) }

    private mutating func cycle(by offset: Int) {
        eventSteal = nil
        guard activities.count > 1 else { return }
        guard let index = selectedIndex else {
            selectedID = activities.first?.id
            return
        }
        // Wraps in both directions; the modulo is written to stay positive for
        // a negative offset.
        let next = ((index + offset) % activities.count + activities.count) % activities.count
        selectedID = activities[next].id
    }

    public mutating func select(_ id: ActivityID) {
        guard activities.contains(where: { $0.id == id }) else { return }
        selectedID = id
        eventSteal = nil
    }

    // MARK: - Expiry

    /// Ids whose lifetime has run out at `now`. The shell schedules the actual
    /// timers; this exists so a missed timer still gets cleaned up on the next
    /// sweep rather than leaving a card up forever.
    public func expiredIDs(at now: TimeInterval) -> [ActivityID] {
        activities.compactMap { activity in
            guard let expiresAfter = activity.expiresAfter else { return nil }
            return now >= activity.createdAt + expiresAfter ? activity.id : nil
        }
    }

    public mutating func removeExpired(at now: TimeInterval) {
        for id in expiredIDs(at: now) { retract(id) }
    }

    // MARK: - Internals

    private mutating func sort() {
        // Captured locally: calling a method on self inside the sort closure
        // overlaps exclusive access to the array being sorted.
        let pinned = pinnedKind
        activities.sort { lhs, rhs in
            let left = Urgency.score(of: lhs, pinned: pinned)
            let right = Urgency.score(of: rhs, pinned: pinned)
            if left != right { return left > right }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            // Final tiebreak on the *whole* id, so the order is total and
            // therefore stable. Comparing only `source` is not enough: identity
            // is (kind, source), so two different activities can share a source
            // and end up ordered by insertion instead — and `Array.sort` is not
            // guaranteed stable, so they could swap between sorts and flicker.
            if lhs.id.source != rhs.id.source { return lhs.id.source < rhs.id.source }
            return lhs.id.kind.rawValue < rhs.id.kind.rawValue
        }
    }

    /// After removing the selected activity, land on the one that took its
    /// place, or the new last one if it was at the end.
    private mutating func selectAfterRemoval(at index: Int) {
        guard !activities.isEmpty else {
            selectedID = nil
            return
        }
        selectedID = activities[min(index, activities.count - 1)].id
    }
}
