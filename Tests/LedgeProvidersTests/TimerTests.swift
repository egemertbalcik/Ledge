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

@Suite("The next leg waits for the notch to sit back down")
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

        // The break must not have begun yet.
        try await Task.sleep(for: .milliseconds(100))
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

        // Generous the other way for the same reason: this asserts something
        // *has* happened, so the wait must outlast a slow moment.
        try await Task.sleep(for: .milliseconds(800))
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
        try await Task.sleep(for: .milliseconds(800))
        timer.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }

        #expect(sessions(in: events).contains { $0.isBreak } == false)
    }
}

@Suite("Timer stream lifecycle")
@MainActor
struct TimerLifecycleTests {
    @Test("Old stream termination cannot stop an immediate restart")
    func immediateRestartKeepsFreshStreamAlive() async {
        let timer = TimerProvider()
        let old = timer.start()
        timer.stop()
        let fresh = timer.start()
        for _ in 0..<20 { await Task.yield() }
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
        let timer = TimerProvider()
        let stream = timer.start()
        timer.stopwatchToggle()
        timer.startCustom(minutes: 1)
        timer.pause()
        var publications = 0
        let consumer = Task { @MainActor in
            for await event in stream {
                if case .publish = event { publications += 1 }
            }
        }
        defer { timer.stop(); consumer.cancel() }
        for _ in 0..<20 { await Task.yield() }
        let before = publications
        // The regular scheduler fires at least once per second. Test the
        // publications, not the separate TimelineView stopwatch rendering.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(publications > before)
        #expect(timer.stopwatch.isRunning)
        #expect(timer.session?.isRunning == false)
    }
}
