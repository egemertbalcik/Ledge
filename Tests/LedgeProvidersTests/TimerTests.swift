import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders

@Suite("Pomodoro cycle")
struct TimerCycleTests {

    @Test("Work leads to a short break, which leads back to work")
    func workToShortBreak() {
        let (leg, completed) = TimerProvider.next(after: .work, completedSessions: 0)
        #expect(leg == .shortBreak)
        #expect(completed == 1)

        let (back, stillOne) = TimerProvider.next(after: .shortBreak, completedSessions: 1)
        #expect(back == .work)
        #expect(stillOne == 1)
    }

    @Test("Every fourth work session earns the long break")
    func fourthSessionIsLong() {
        // Three completed already; finishing the fourth closes the cycle.
        let (leg, completed) = TimerProvider.next(after: .work, completedSessions: 3)
        #expect(leg == .longBreak)
        #expect(completed == 4)
    }

    @Test("A long break resets the cycle counter")
    func longBreakResets() {
        let (leg, completed) = TimerProvider.next(after: .longBreak, completedSessions: 4)
        #expect(leg == .work)
        #expect(completed == 0, "the dots start over after a long break")
    }

    @Test("A full cycle visits short, short, short, long")
    func fullCycle() {
        var leg = TimerProvider.Leg.work
        var completed = 0
        var breaks: [TimerProvider.Leg] = []

        for _ in 0..<4 {
            let afterWork = TimerProvider.next(after: leg, completedSessions: completed)
            breaks.append(afterWork.leg)
            completed = afterWork.completedSessions
            leg = TimerProvider.next(after: afterWork.leg, completedSessions: completed).leg
        }

        #expect(breaks == [.shortBreak, .shortBreak, .shortBreak, .longBreak])
    }
}

@Suite("Timer session arithmetic")
struct TimerSessionTests {

    @Test("Remaining comes from the deadline, so a late tick cannot drift it")
    func remainingFromDeadline() {
        let session = TimerProvider.Session(
            leg: .work, total: 100, deadline: 1000, pausedRemaining: nil, completedSessions: 0
        )
        #expect(session.remaining(at: 900) == 100)
        #expect(session.remaining(at: 950) == 50)
        // A tick that arrives ten seconds late still reports the truth, rather
        // than the counter it would have decremented to.
        #expect(session.remaining(at: 990) == 10)
    }

    @Test("Remaining never goes negative once the deadline has passed")
    func remainingClampsAtZero() {
        let session = TimerProvider.Session(
            leg: .work, total: 100, deadline: 1000, pausedRemaining: nil, completedSessions: 0
        )
        #expect(session.remaining(at: 1200) == 0)
    }

    @Test("A paused session freezes, and reports as not running")
    func pausedFreezes() {
        let session = TimerProvider.Session(
            leg: .work, total: 100, deadline: nil, pausedRemaining: 42, completedSessions: 1
        )
        #expect(session.isRunning == false)
        #expect(session.remaining(at: 5_000) == 42, "time must not pass while paused")
    }
}

@Suite("Timer provider")
@MainActor
struct TimerProviderStreamTests {

    /// Drains the stream after stopping — `AsyncStream` buffers, so events
    /// emitted synchronously in `body` are still there.
    private func collect(
        _ provider: TimerProvider,
        while body: () -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func provider(
        now: @escaping () -> TimeInterval = { 1000 },
        autoAdvance: Bool = true
    ) -> TimerProvider {
        TimerProvider(
            durations: {
                TimerProvider.Durations(
                    work: 60, shortBreak: 30, longBreak: 90, autoAdvance: autoAdvance
                )
            },
            now: now
        )
    }

    @Test("Starting a focus session publishes a running card")
    func startPublishes() async {
        let timer = provider()
        let events = await collect(timer) { timer.startFocus() }

        // start() now leads with the standing ready card and startFocus
        // retracts it; the session publish is the first *session* event.
        let sessionPublish = events.first { event in
            if case .publish(let activity) = event {
                return activity.id == TimerProvider.activityID
            }
            return false
        }
        guard case .publish(let activity)? = sessionPublish else {
            Issue.record("expected a session publish")
            return
        }
        #expect(activity.id == ActivityID(kind: .timer, source: "session"))
        guard case .timer(let payload) = activity.payload else {
            Issue.record("expected a timer payload")
            return
        }
        #expect(payload.label == "Focus")
        #expect(payload.isRunning)
        #expect(payload.remaining == 60)
        #expect(payload.total == 60)
        #expect(payload.isFinished == false)
    }

    @Test("With no session, the provider stands a ready card")
    func idleCardStands() async {
        let timer = provider()
        let events = await collect(timer) {}

        guard case .publish(let activity)? = events.first else {
            Issue.record("expected the ready card")
            return
        }
        #expect(activity.id == TimerProvider.idleActivityID)
        #expect(activity.priority == TimerProvider.idlePriority)
        #expect(activity.expiresAfter == nil)
        guard case .timer(let payload) = activity.payload else {
            Issue.record("expected a timer payload")
            return
        }
        #expect(payload.isIdle)
        #expect(!payload.isRunning)
    }

    @Test("Cancelling a session rests back on the ready card")
    func cancelRestsOnIdle() async {
        let timer = provider()
        let events = await collect(timer) {
            timer.startFocus()
            timer.cancel()
        }
        // The last event must be the ready card returning.
        guard case .publish(let activity)? = events.last else {
            Issue.record("expected a publish last")
            return
        }
        #expect(activity.id == TimerProvider.idleActivityID)
    }

    @Test("A running card never carries an expiry")
    func runningCardDoesNotExpire() async {
        // Load-bearing: expiry is measured from the ORIGINAL createdAt, which
        // upsert preserves, so a ticking card with an expiry would vanish
        // mid-session no matter how often it was republished.
        let timer = provider()
        let events = await collect(timer) { timer.startFocus() }

        guard case .publish(let activity)? = events.first else {
            Issue.record("expected a publish")
            return
        }
        #expect(activity.expiresAfter == nil)
    }

    @Test("Pausing stops the clock and republishes as paused")
    func pausePublishes() async {
        var clock: TimeInterval = 1000
        let timer = provider(now: { clock })
        let events = await collect(timer) {
            timer.startFocus()
            clock = 1020
            timer.pause()
        }

        guard case .publish(let activity) = events.last else {
            Issue.record("expected a publish")
            return
        }
        guard case .timer(let payload) = activity.payload else {
            Issue.record("expected a timer payload")
            return
        }
        #expect(payload.isRunning == false)
        #expect(payload.remaining == 40, "20 of the 60 seconds were used")
    }

    @Test("Resuming after a long pause keeps the remaining time")
    func resumeKeepsRemaining() async {
        var clock: TimeInterval = 1000
        let timer = provider(now: { clock })
        _ = await collect(timer) {
            timer.startFocus()
            clock = 1020
            timer.pause()
            // An hour goes by while paused.
            clock = 4620
            timer.resume()
        }
        // The stream ended (collect stops the provider), but the session
        // itself survives a stop: it is what lets a provider toggled off and
        // on mid-pomodoro keep the countdown. The remaining time is what
        // resume computed.
        let session = timer.session
        #expect(session != nil, "stop() keeps the session for re-enable")
        #expect(session?.remaining(at: clock) == 40, "20 of the 60 seconds were used")
    }

    @Test("A custom countdown finishes to the ready card, never into the cycle")
    func customFinishesToIdle() async {
        var clock: TimeInterval = 1000
        // Auto-advance ON: the pomodoro preference must not drag a one-off
        // chip countdown into a break.
        let timer = provider(now: { clock }, autoAdvance: true)
        let events = await collect(timer) {
            timer.startCustom(minutes: 45)
            clock = 1020
            // Ending a custom leg (skip and natural finish share the same
            // custom branch) must rest at the ready card.
            timer.skip()
        }
        let totals: [TimeInterval] = events.compactMap { event in
            guard case .publish(let activity) = event,
                  case .timer(let payload) = activity.payload, !payload.isIdle
            else { return nil }
            return payload.total
        }
        #expect(totals.contains(45 * 60), "the chip's own duration runs")
        let startedBreak = events.contains { event in
            guard case .publish(let activity) = event,
                  case .timer(let payload) = activity.payload
            else { return false }
            return payload.isBreak
        }
        #expect(!startedBreak, "no break follows a custom countdown")
        let idleAgain = events.suffix(2).contains { event in
            guard case .publish(let activity) = event,
                  case .timer(let payload) = activity.payload
            else { return false }
            return payload.isIdle
        }
        #expect(idleAgain, "the ready card returns")
    }

    @Test("Cancelling retracts the card")
    func cancelRetracts() async {
        let timer = provider()
        let events = await collect(timer) {
            timer.startFocus()
            timer.cancel()
        }
        #expect(events.contains(.retract(ActivityID(kind: .timer, source: "session"))))
    }

    @Test("Skipping a work session advances to the break")
    func skipAdvances() async {
        let timer = provider()
        _ = await collect(timer) {
            timer.startFocus()
            timer.skip()
        }
        // The session is cleared by stop(), so assert on what was published.
        let second = provider()
        let events = await collect(second) {
            second.startFocus()
            second.skip()
        }
        let labels: [String] = events.compactMap { event in
            guard case .publish(let activity) = event,
                  case .timer(let payload) = activity.payload
            else { return nil }
            return payload.label
        }
        #expect(labels.contains("Break"), "skipping work starts the break")
    }

    @Test("With auto-advance off, skipping ends the session entirely")
    func skipWithoutAutoAdvance() async {
        let timer = provider(autoAdvance: false)
        let events = await collect(timer) {
            timer.startFocus()
            timer.skip()
        }
        #expect(events.contains(.retract(ActivityID(kind: .timer, source: "session"))))
    }

    @Test("Stopping keeps the session, so re-enabling resumes the countdown")
    func stopKeepsSession() async {
        var clock: TimeInterval = 1000
        let timer = provider(now: { clock })
        _ = await collect(timer) { timer.startFocus() }
        // The provider was switched off mid-session (collect stops it): the
        // wall-clock deadline survives, so switching it back on shows the
        // same countdown instead of silently cancelling the pomodoro.
        #expect(timer.session != nil)
        #expect(timer.isActive)
        clock = 1010
        let events = await collect(timer) {}
        let republished = events.contains { event in
            guard case .publish(let activity) = event,
                  case .timer(let payload) = activity.payload
            else { return false }
            return !payload.isIdle
        }
        #expect(republished, "re-enabling publishes the running session, not the ready card")
    }
}

@Suite("The next leg waits for the notch to sit back down", .timeLimit(.minutes(10)))
@MainActor
struct TimerHandOverTests {

    private func provider(
        now: @escaping () -> TimeInterval,
        delay: TimeInterval
    ) -> TimerProvider {
        TimerProvider(
            durations: {
                TimerProvider.Durations(work: 60, shortBreak: 30, longBreak: 90, autoAdvance: true)
            },
            now: now,
            handOverDelay: delay
        )
    }

    private func sessions(in events: [ProviderEvent]) -> [TimerPayload] {
        events.compactMap { event in
            guard case .publish(let activity) = event,
                  activity.id == TimerProvider.activityID,
                  case .timer(let payload) = activity.payload
            else { return nil }
            return payload
        }
    }

    /// A break that starts while the notch is still saying the work session
    /// ended spends its first seconds unannounced — the app taking back the
    /// time it is in the middle of granting.
    @Test("A break does not start while the end is still being announced")
    func breakWaitsForTheAnnouncement() async throws {
        var clock: TimeInterval = 1_000
        // A wide margin on purpose: this asserts that something has *not*
        // happened yet, and a narrow one only asserts that the machine was not
        // busy. Five seconds against a tenth is a margin no amount of load
        // closes.
        let timer = provider(now: { clock }, delay: 5)
        let stream = timer.start()
        timer.startFocus()

        // Run the work leg out.
        clock += 61
        timer.tickNow()

        // The break must not have begun yet — and that is checked *without*
        // waiting.
        //
        // The handoff is a `DispatchQueue.main.asyncAfter`, so it cannot run
        // until this main-actor function yields. Sleeping first and then
        // asserting made the test a bet that the sleep would resume before the
        // five-second handoff fired; under a loaded suite a 100ms sleep was
        // measured resuming after thirteen seconds, and the bet lost. Nothing
        // is awaited between the tick and the assertion now, so load cannot
        // reach it.
        timer.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }

        let breaks = sessions(in: events).filter(\.isBreak)
        #expect(breaks.isEmpty, "the notch is still announcing")
    }

    @Test("And starts once the announcement is over")
    func breakStartsAfterwards() async throws {
        var clock: TimeInterval = 1_000
        let timer = provider(now: { clock }, delay: 0.05)
        let stream = timer.start()
        timer.startFocus()
        clock += 61
        timer.tickNow()

        // Waited for rather than slept through: this asserts something *has*
        // happened, and a held main thread outlasts any fixed sleep with the
        // hand-over still queued behind it. The suite's time limit catches a
        // break that never starts.
        while timer.session?.leg.isBreak != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        timer.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }

        #expect(sessions(in: events).contains { $0.isBreak })
    }

    /// Cancelling matters as much as scheduling: a cycle stopped inside those
    /// seconds used to start its next leg anyway, moments after being told to
    /// stop.
    @Test("Cancelling during the gap cancels the next leg too")
    func cancellingInTheGapWins() async throws {
        var clock: TimeInterval = 1_000
        let timer = provider(now: { clock }, delay: 0.05)
        let stream = timer.start()
        timer.startFocus()
        clock += 61
        timer.tickNow()

        timer.cancel()
        // A chance for the cancelled hand-over to go wrong, sixteen times its
        // delay. A late one can only make this miss the fault, never invent it.
        try await Task.sleep(for: .milliseconds(800))
        timer.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }

        #expect(sessions(in: events).contains { $0.isBreak } == false)
    }
}

@Suite("Timer stream lifecycle", .timeLimit(.minutes(10)))
@MainActor
struct TimerLifecycleTests {
    @Test("Old stream termination cannot stop an immediate restart")
    func immediateRestartKeepsFreshStreamAlive() async throws {
        let timer = TimerProvider()
        let old = timer.start()
        timer.stop()
        let fresh = timer.start()
        // Until the old stream's handler has actually run. A count of yields
        // was a guess at how many turns it needed, and when the guess was
        // short the test passed without the handler having had its go.
        while timer.terminationsHandled == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        timer.startCustom(minutes: 1)
        timer.stop()
        var publications = 0
        for await event in fresh {
            if case .publish(let activity) = event, activity.id == TimerProvider.activityID {
                publications += 1
            }
        }
        withExtendedLifetime(old) {}
        #expect(publications == 1)
    }

    @Test("Pausing the countdown preserves stopwatch publications")
    func pausedCountdownKeepsStopwatchPublishing() async throws {
        var clock: TimeInterval = 1_000
        let timer = TimerProvider(now: { clock })
        let stream = timer.start()
        defer { timer.stop() }
        timer.stopwatchToggle()
        timer.startCustom(minutes: 1)
        timer.pause()
        // Everything published so far is stamped before this, so a
        // publication stamped after it can only have come from a tick. That
        // tells the scheduler's own publications from the ones the commands
        // above buffered, which counting them after a number of yields did
        // not: a consumer that had not caught up saw the buffered ones arrive
        // late and took them for ticks.
        clock += 100
        // The regular scheduler fires at least once per second. Test the
        // publications, not the separate TimelineView stopwatch rendering.
        // Waited for however long that takes; the suite's time limit catches
        // a tick that never comes.
        var ticked = false
        for await event in stream {
            if case .publish(let activity) = event, activity.createdAt >= 1_100 {
                ticked = true
                break
            }
        }
        #expect(ticked, "nothing was published after the pause")
        #expect(timer.stopwatch.isRunning)
        #expect(timer.session?.isRunning == false)
    }
}

/// A pomodoro left running when the lid closes. The displays stay off through
/// every Power Nap dark wake, and the main queue runs in each, so the overdue
/// tick lands there: it used to finish a leg per wake and start the next from
/// that moment, and the user came back hours later to an arbitrary leg.
@Suite("A pomodoro nobody can see does not run on", .timeLimit(.minutes(10)))
@MainActor
struct TimerScreensDarkTests {

    private func finishes(in events: [ProviderEvent]) -> [(createdAt: TimeInterval, payload: TimerPayload)] {
        events.compactMap { event in
            guard case .publish(let activity) = event,
                  activity.id == TimerProvider.finishedActivityID,
                  case .timer(let payload) = activity.payload,
                  payload.isFinished
            else { return nil }
            return (activity.createdAt, payload)
        }
    }

    /// Waits out a hand-over if one is running. The provider has no session
    /// only while a hand-over is pending, so this settles either way and
    /// never bets on a fixed sleep — nor on a deadline, which a held main
    /// thread outlasts with the hand-over still queued behind it.
    private func settle(_ timer: TimerProvider) async throws {
        while timer.session == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Twelve dark wakes end one leg, count one session, and start nothing")
    func darkWakesDoNotChainLegs() async throws {
        var clock: TimeInterval = 1_000
        let timer = TimerProvider(
            durations: { TimerProvider.Durations() },   // 25/5/15, auto-advance on
            now: { clock },
            handOverDelay: 0.05
        )
        let stream = timer.start()
        timer.startFocus()
        clock += 10 * 60
        timer.setScreensDark(true)                     // the lid closes ten minutes in

        var legs: [TimerProvider.Session] = []
        var waitedOnAHandOver = false
        for _ in 0..<12 {
            clock += 15 * 60
            timer.tickNow()                            // the overdue tick, in the dark wake
            // Checked before anything is awaited: no hand-over is even begun.
            if timer.session == nil { waitedOnAHandOver = true }
            try await settle(timer)
            if let session = timer.session { legs.append(session) }
        }

        // Reached: the first wake found the work leg over at its wall-clock end.
        try #require(legs.count == 12)
        try #require(legs[0].leg == .shortBreak, "the work leg ended while the lid was shut")
        #expect(waitedOnAHandOver == false)

        for session in legs {
            #expect(session.leg == .shortBreak)
            #expect(session.completedSessions == 1)
            #expect(session.isRunning == false)
            #expect(session.remaining(at: clock) == 5 * 60)
        }

        // The lid opens: the finish is told now, and the break waits for play.
        clock += 60
        let opened = clock
        timer.setScreensDark(false)
        try await Task.sleep(for: .milliseconds(300))   // six hand-overs' worth
        #expect(timer.session?.leg == .shortBreak)
        #expect(timer.session?.isRunning == false)

        timer.resume()
        #expect(timer.session?.deadline == clock + 5 * 60)

        timer.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        let finished = finishes(in: events)
        #expect(finished.count == 1)
        #expect(finished.first?.createdAt == opened, "announced when someone could see it")
        #expect(finished.first?.payload.label == "Focus")
        #expect(finished.first?.payload.completedSessions == 1)

        // The announcement retires the session card; the waiting break must
        // stand beneath it again, or it is gone once the finish clears.
        let announced = try #require(events.firstIndex { event in
            if case .publish(let a) = event { return a.id == TimerProvider.finishedActivityID }
            return false
        })
        let restored = events[announced...].contains { event in
            guard case .publish(let a) = event, a.id == TimerProvider.activityID,
                  case .timer(let p) = a.payload else { return false }
            return p.isBreak && !p.isRunning
        }
        #expect(restored)
    }

    @Test("A leg that ended in the dark still waits when the lid opens before the tick lands")
    func revealCatchesUpBeforeTheTick() async throws {
        var clock: TimeInterval = 1_000
        let timer = TimerProvider(
            durations: {
                TimerProvider.Durations(work: 60, shortBreak: 120, longBreak: 300, autoAdvance: true)
            },
            now: { clock },
            handOverDelay: 0.05
        )
        let stream = timer.start()
        timer.startFocus()
        timer.setScreensDark(true)
        clock += 2 * 60 * 60                           // asleep; no tick ran
        try #require(timer.session?.leg == .work, "reached: the leg is over but nothing has noticed")

        timer.setScreensDark(false)
        // Nothing awaited: the uptime tick has had no chance to land first.
        #expect(timer.session?.leg == .shortBreak)
        #expect(timer.session?.isRunning == false)

        timer.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        #expect(finishes(in: events).count == 1)
    }

    @Test("With the screens lit, a pomodoro hands over to the next leg as before")
    func awakePomodoroStillAdvances() async throws {
        var clock: TimeInterval = 1_000
        let timer = TimerProvider(
            durations: {
                TimerProvider.Durations(work: 60, shortBreak: 120, longBreak: 300, autoAdvance: true)
            },
            now: { clock },
            handOverDelay: 0.05
        )
        let stream = timer.start()
        timer.startFocus()
        // A dark spell that ends before the leg does changes nothing.
        timer.setScreensDark(true)
        clock += 20
        timer.setScreensDark(false)

        clock += 41
        let ended = clock
        timer.tickNow()
        try #require(timer.session == nil, "reached: the leg ended and the hand-over is pending")

        try await settle(timer)
        #expect(timer.session?.leg == .shortBreak)
        #expect(timer.session?.isRunning == true)
        #expect(timer.session?.completedSessions == 1)
        #expect(timer.session?.deadline == ended + 120)

        timer.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        let finished = finishes(in: events)
        #expect(finished.count == 1)
        #expect(finished.first?.createdAt == ended, "announced the moment it ended")
    }

    /// Switched off in Settings, the provider keeps its session but no tick:
    /// the screens lighting must not start one behind the user's back.
    @Test("A switched-off timer is left alone when the screens light")
    func stoppedProviderIsNotTicked() async throws {
        var clock: TimeInterval = 1_000
        let timer = TimerProvider(
            durations: {
                TimerProvider.Durations(work: 60, shortBreak: 120, longBreak: 300, autoAdvance: true)
            },
            now: { clock },
            handOverDelay: 0.05
        )
        let stream = timer.start()
        timer.startFocus()
        timer.setScreensDark(true)
        timer.stop()
        for await _ in stream {}
        clock += 2 * 60 * 60
        try #require(timer.session?.isRunning == true, "reached: a stopped provider holding an overdue leg")

        timer.setScreensDark(false)
        #expect(timer.session?.leg == .work)
        #expect(timer.session?.isRunning == true)
    }

    private func darkProvider(now: @escaping () -> TimeInterval) -> TimerProvider {
        TimerProvider(
            durations: {
                TimerProvider.Durations(work: 60, shortBreak: 120, longBreak: 300, autoAdvance: true)
            },
            now: now,
            handOverDelay: 0.05
        )
    }

    /// The held finish belongs to the session that finished. A command that
    /// replaces or ends that session before the lid opens used to leave it
    /// held, and the reveal then announced "Focus finished" over the new
    /// countdown.
    @Test(
        "A held finish is retired by whatever replaces the session before the lid opens",
        arguments: ["cancel", "cancel then new timer", "new timer", "new focus", "skip", "done"]
    )
    func replacingCommandRetiresTheHeldFinish(command: String) async throws {
        var clock: TimeInterval = 1_000
        let timer = darkProvider(now: { clock })
        let stream = timer.start()
        timer.startFocus()
        timer.setScreensDark(true)
        clock += 61
        timer.tickNow()
        try #require(timer.session?.leg == .shortBreak, "reached: the work leg ended in the dark")
        try #require(timer.session?.isRunning == false, "reached: the break is parked")

        switch command {
        case "cancel": timer.cancel()
        case "cancel then new timer": timer.cancel(); timer.startCustom(minutes: 5)
        case "new timer": timer.startCustom(minutes: 5)
        case "new focus": timer.startFocus()
        case "skip": timer.skip()
        default: timer.dismissFinished()
        }
        let after = timer.session
        clock += 30
        timer.setScreensDark(false)
        #expect(timer.session?.deadline == after?.deadline, "the new state survives the reveal")

        timer.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        #expect(finishes(in: events).isEmpty)
    }

    /// Settings switching the timer off while a finish is held, then on again:
    /// whether the lid opens while it is off or after it is back, what comes
    /// back is the waiting leg, and no summary of the old one.
    @Test(
        "Switching the timer off and on retires a held finish but keeps the waiting leg",
        arguments: [false, true]
    )
    func offAndOnRetiresTheHeldFinish(revealWhileOff: Bool) async throws {
        var clock: TimeInterval = 1_000
        let timer = darkProvider(now: { clock })
        let first = timer.start()
        timer.startFocus()
        timer.setScreensDark(true)
        clock += 61
        timer.tickNow()
        try #require(timer.session?.leg == .shortBreak, "reached: the work leg ended in the dark")
        timer.stop()
        var before: [ProviderEvent] = []
        for await event in first { before.append(event) }
        try #require(finishes(in: before).isEmpty, "reached: the finish was held, not spent")

        if revealWhileOff { timer.setScreensDark(false) }
        let second = timer.start()
        if !revealWhileOff { timer.setScreensDark(false) }
        timer.stop()
        var events: [ProviderEvent] = []
        for await event in second { events.append(event) }

        #expect(finishes(in: events).isEmpty)
        let waiting = events.contains { event in
            guard case .publish(let a) = event, a.id == TimerProvider.activityID,
                  case .timer(let p) = a.payload else { return false }
            return p.isBreak && !p.isRunning && p.remaining == 120
        }
        #expect(waiting, "the parked break is what comes back")
    }

    @Test("Screens that go dark inside the hand-over leave the next leg waiting")
    func darkDuringHandOverParks() async throws {
        var clock: TimeInterval = 1_000
        let timer = TimerProvider(
            durations: {
                TimerProvider.Durations(work: 60, shortBreak: 120, longBreak: 300, autoAdvance: true)
            },
            now: { clock },
            handOverDelay: 0.05
        )
        let stream = timer.start()
        timer.startFocus()
        clock += 61
        timer.tickNow()
        try #require(timer.session == nil, "reached: the hand-over is pending")
        timer.setScreensDark(true)

        try await settle(timer)
        #expect(timer.session?.leg == .shortBreak)
        #expect(timer.session?.isRunning == false)
        #expect(timer.session?.remaining(at: clock) == 120)

        timer.stop()
        for await _ in stream {}
    }
}
