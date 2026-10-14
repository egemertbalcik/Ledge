import Foundation

/// The transitions of the Keep Awake state machine, with nothing behind them.
///
/// Pure and clockless: `now` arrives as an argument, nothing is scheduled here,
/// and no resource is touched. The provider sequences the real work — writing
/// the journal, taking the assertion — because the order of those two is a
/// safety rule (§6.1.1: acquiring depends on the write, releasing never does)
/// and belongs where it can be observed, not inside a value transform.
public enum KeepAwakeReducer {

    /// The shortest and longest a session may be.
    ///
    /// Five minutes because anything less is better served by not sleeping yet
    /// anyway; a day because a keep-awake that outlives the reason for it is
    /// how a laptop cooks in a bag. The timer card clamps to the same upper
    /// bound in minutes.
    public static let minimumMinutes = 5
    /// Seven days. Long enough for a render or a sync left over a weekend,
    /// short enough that a number arrived at by accident still looks like one.
    public static let maximumMinutes = 7 * 24 * 60

    public static func clamp(minutes: Int) -> Int {
        min(maximumMinutes, max(minimumMinutes, minutes))
    }

    /// Begins a session. Refused unless the card is at rest.
    ///
    /// A Start while one is already running would silently move the deadline,
    /// which is a different thing from what the button says.
    /// Begins a hold that runs until it is switched off.
    ///
    /// Keep Awake is a switch. The timed form below still exists and is what
    /// the lid-closed mode will use, but the plain card has no deadline: the
    /// user turned it on, and only the user — or a floor — turns it off.
    public static func start(
        from state: KeepAwakeState,
        now: Date,
        id: String,
        bootID: String,
        lidHoldRequested: Bool = false
    ) -> KeepAwakeState? {
        guard !state.isRunning else { return nil }
        return .running(
            KeepAwakeSession(
                id: id,
                startedAt: now,
                deadline: nil,
                total: 0,
                bootID: bootID,
                lidHoldRequested: lidHoldRequested
            )
        )
    }

    /// Begins a hold that ends by itself. Kept for the lid-closed mode, where
    /// a deadline is the thing that bounds a privileged hold.
    public static func start(
        from state: KeepAwakeState,
        minutes: Int,
        now: Date,
        id: String,
        bootID: String,
        lidHoldRequested: Bool = false
    ) -> KeepAwakeState? {
        guard !state.isRunning else { return nil }
        let total = TimeInterval(clamp(minutes: minutes) * 60)
        return .running(
            KeepAwakeSession(
                id: id,
                startedAt: now,
                deadline: now.addingTimeInterval(total),
                total: total,
                bootID: bootID,
                lidHoldRequested: lidHoldRequested
            )
        )
    }

    /// Ends a running session for a stated reason.
    ///
    /// Returns nil when there is nothing running, so callers that end
    /// defensively — quitting, switching the card off — do not manufacture a
    /// Finished card out of a session nobody started.
    public static func end(
        from state: KeepAwakeState,
        reason: KeepAwakeEndReason,
        now: Date,
        endUnrecorded: Bool = false
    ) -> KeepAwakeState? {
        guard let session = state.session else { return nil }
        return .finished(finish(session, reason: reason, at: now, endUnrecorded: endUnrecorded))
    }

    public static func finish(
        _ session: KeepAwakeSession,
        reason: KeepAwakeEndReason,
        at now: Date,
        endUnrecorded: Bool = false
    ) -> KeepAwakeFinish {
        KeepAwakeFinish(
            reason: reason,
            endedAt: now,
            remaining: session.remaining(at: now),
            ran: max(0, now.timeIntervalSince(session.startedAt)),
            sessionID: session.id,
            deadline: session.deadline,
            endUnrecorded: endUnrecorded
        )
    }

    /// The deadline check. Called when the timer fires, on wake, and whenever
    /// the clock moves — the timer firing is evidence of nothing on its own.
    public static func tick(_ state: KeepAwakeState, now: Date) -> KeepAwakeState? {
        guard let session = state.session, session.hasExpired(at: now),
              let deadline = session.deadline
        else { return nil }
        return .finished(finish(session, reason: .timeUp, at: deadline))
    }

    /// Picks the session up again after the user ended it by mistake.
    ///
    /// Keeps the original deadline rather than starting a fresh stretch: the
    /// button says "Resume (1h 12m left)", and giving back more than that would
    /// be a different promise. A new id, because the journal's record of the
    /// ended one must not be overwritten by its successor.
    public static func resume(
        from state: KeepAwakeState,
        now: Date,
        id: String,
        bootID: String
    ) -> KeepAwakeState? {
        guard case .finished(let finish) = state, finish.canResume(at: now) else { return nil }
        // A hold with no deadline resumes as one: there is nothing to count
        // back to, and it runs until it is switched off again.
        return .running(
            KeepAwakeSession(
                id: id,
                startedAt: now,
                deadline: finish.deadline,
                total: finish.deadline.map { $0.timeIntervalSince(now) } ?? 0,
                bootID: bootID,
                lidHoldRequested: false
            )
        )
    }

    /// Clears a Finished card.
    public static func dismiss(_ state: KeepAwakeState) -> KeepAwakeState? {
        guard case .finished = state else { return nil }
        return .ready
    }

    /// What a journal record from a previous run means now.
    ///
    /// The whole continuity policy is this one function, which is why it takes
    /// its facts as arguments and answers without touching anything.
    public enum Recovery: Equatable, Sendable {
        /// Pick it up where it left off, and say so out loud.
        case resume(KeepAwakeSession)
        /// It is over; show the summary once.
        case ended(KeepAwakeFinish)
        /// There was nothing to recover.
        case nothing
    }

    public static func recover(
        _ session: KeepAwakeSession,
        bootID: String,
        now: Date,
        tombstoned: Bool
    ) -> Recovery {
        // A tombstone means the user ended this session and only the journal
        // write failed. Believing the journal over it would resurrect a session
        // they already stopped.
        if tombstoned {
            return .ended(finish(session, reason: .endedByYou, at: now, endUnrecorded: true))
        }
        guard session.bootID == bootID else {
            return .ended(finish(session, reason: .macRestarted, at: now))
        }
        if session.hasExpired(at: now), let deadline = session.deadline {
            // Dated to the deadline, not to now: the Mac was free to sleep from
            // the moment the session ran out, and the summary says so.
            return .ended(finish(session, reason: .ledgeNotRunning, at: deadline))
        }
        return .resume(session)
    }
}
