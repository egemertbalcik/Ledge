import Foundation
import LedgeCore
import os

/// A countdown timer and pomodoro cycle, driven entirely from user commands.
///
/// Unlike every other provider there is no system source to watch — the user is
/// the source. So this follows `WeatherProvider`'s shape rather than
/// `FocusProvider`'s: a self-rescheduling tick that republishes a *standing*
/// card, and an explicit retract when the session ends.
///
/// Two decisions are load-bearing:
///
/// - **Remaining time is derived from a deadline, never decremented.** A ticking
///   counter drifts whenever the machine sleeps or the timer coalesces; a
///   deadline is correct no matter how late the tick arrives.
/// - **The running card carries no `expiresAfter`.** `ActivityQueue.upsert`
///   preserves the original `createdAt` across updates, and expiry is scheduled
///   against `createdAt` — so an expiring card would vanish mid-session no
///   matter how often it was republished. Only the finishing publish expires.
@MainActor
public final class TimerProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "timer")

    public let identifier = "timer"

    /// One stable slot: a tick replaces the card in place rather than stacking.
    public static let activityID = ActivityID(kind: .timer, source: "session")

    /// The standing "ready" card. Its own id, so starting a session retracts
    /// it cleanly and the running card never inherits its low priority.
    public static let idleActivityID = ActivityID(kind: .timer, source: "idle")

    /// The completion announcement. Its own id: published over the *session*
    /// id it was an in-place upsert, which preserved the session's original
    /// createdAt — so the 12-second expiry was measured from the start of the
    /// leg and fired instantly. The user got the beep and nothing on screen.
    static let finishedActivityID = ActivityID(kind: .timer, source: "finished")

    /// Below everything, weather included (10, +15 when rain is coming).
    /// The ready card is a launcher, not an announcement — the *last* stop
    /// in the cycle, never on top. A running or finished session publishes
    /// under its own id at full timer priority, so only the idle launcher
    /// sits back here.
    static let idlePriority = 5

    /// How long the "finished" card lingers before it clears itself.
    static let finishedLifetime: TimeInterval = 12

    /// How many work sessions before the long break.
    nonisolated static let sessionsPerCycle = 4

    /// Which leg of the cycle is running.
    public enum Leg: Equatable, Sendable {
        case work
        case shortBreak
        case longBreak

        var isBreak: Bool { self != .work }

        var label: String {
            switch self {
            case .work: "Focus"
            case .shortBreak: "Break"
            case .longBreak: "Long Break"
            }
        }
    }

    /// Everything about a session that is not the clock. Pure, so the cycle
    /// rules can be tested without running a timer.
    public struct Session: Equatable, Sendable {
        public var leg: Leg
        public var total: TimeInterval
        /// Wall-clock instant the leg ends. Nil while paused.
        public var deadline: TimeInterval?
        /// Seconds left, captured when paused.
        public var pausedRemaining: TimeInterval?
        public var completedSessions: Int
        /// A one-off chip countdown: finishes to the ready card, never into
        /// the pomodoro cycle.
        public var isCustom: Bool = false

        public var isRunning: Bool { deadline != nil }

        /// Seconds left at `now`, from whichever source is authoritative.
        public func remaining(at now: TimeInterval) -> TimeInterval {
            if let pausedRemaining { return max(0, pausedRemaining) }
            guard let deadline else { return 0 }
            return max(0, deadline - now)
        }
    }

    /// Durations, read fresh each time a leg starts so a settings change applies
    /// to the next session without a restart.
    public struct Durations: Equatable, Sendable {
        public var work: TimeInterval
        public var shortBreak: TimeInterval
        public var longBreak: TimeInterval
        public var autoAdvance: Bool

        public init(
            work: TimeInterval = 25 * 60,
            shortBreak: TimeInterval = 5 * 60,
            longBreak: TimeInterval = 15 * 60,
            autoAdvance: Bool = true
        ) {
            self.work = work
            self.shortBreak = shortBreak
            self.longBreak = longBreak
            self.autoAdvance = autoAdvance
        }

        func length(of leg: Leg) -> TimeInterval {
            switch leg {
            case .work: work
            case .shortBreak: shortBreak
            case .longBreak: longBreak
            }
        }
    }

    private let durations: () -> Durations
    private let now: () -> TimeInterval
    private let persistRecents: ([Int]) -> Void
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var pending: DispatchWorkItem?

    /// Nil when no session exists at all.
    public private(set) var session: Session?

    /// The stopwatch, alive alongside or instead of a countdown. It shares
    /// the session card: when only the stopwatch is going the card wears the
    /// stopwatch face, and the ears count up through the same fields.
    public private(set) var stopwatch = StopwatchState()

    /// Recently used quick-timer minutes, freshest first, at most three.
    public private(set) var recents: [Int]

    /// Fired when a leg completes, so the shell can chime. Kept as a closure
    /// because `LedgeProviders` may not reach AppKit.
    public var onFinished: (Leg) -> Void = { _ in }

    public init(
        durations: @escaping () -> Durations = { Durations() },
        recents: [Int] = [],
        persistRecents: @escaping ([Int]) -> Void = { _ in },
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        handOverDelay: TimeInterval = NotchAnnouncement.duration
    ) {
        self.durations = durations
        self.recents = Self.sanitizedRecents(recents)
        self.persistRecents = persistRecents
        self.now = now
        self.handOverDelay = handOverDelay
    }

    /// How long the next leg waits while the notch finishes announcing the
    /// last one. Injected so a test need not sit through it.
    private let handOverDelay: TimeInterval

    /// Recents as stored: distinct, sane minutes, freshest first, three at most.
    nonisolated static func sanitizedRecents(_ minutes: [Int]) -> [Int] {
        var seen: Set<Int> = []
        return minutes
            .filter { (1...(24 * 60)).contains($0) && seen.insert($0).inserted }
            .prefix(3)
            .map { $0 }
    }

    /// Replaces the recents wholesale — the preference was reset (or edited)
    /// underneath the provider, which otherwise keeps writing its own list back.
    public func replaceRecents(_ minutes: [Int]) {
        recents = Self.sanitizedRecents(minutes)
        if session != nil || stopwatch.isActive { publish() } else { publishIdle() }
    }

    /// The comma-joined preference form.
    nonisolated public static func decodeRecents(_ joined: String) -> [Int] {
        sanitizedRecents(joined.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    nonisolated public static func encodeRecents(_ minutes: [Int]) -> String {
        sanitizedRecents(minutes).map(String.init).joined(separator: ",")
    }

    // MARK: - Lifecycle

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            // A provider that is switched on mid-session keeps showing it;
            // otherwise the ready card stands so the timer can be started from
            // the notch at all.
            if self.session != nil || self.stopwatch.isActive {
                self.publish()
                // And resume ticking: `stop()` cancelled the pending tick but
                // kept the session, so the countdown must pick its clock back
                // up or the card freezes at the re-enable instant.
                self.scheduleTick()
            } else {
                self.publishIdle()
            }
        }
    }

    public func stop() {
        cancelHandOver()
        pending?.cancel()
        pending = nil
        continuation?.finish()
        continuation = nil
        // The session survives deliberately: it is what makes the documented
        // "switched on mid-session keeps showing it" branch of `start()`
        // reachable. Toggling the provider off and on in Settings must not
        // silently cancel a running pomodoro — the deadline is wall-clock, so
        // the countdown is still correct when watching resumes.
    }

    // MARK: - Commands

    /// Begins a leg, replacing whatever was running.
    public func begin(_ leg: Leg, completedSessions: Int? = nil) {
        cancelHandOver()
        continuation?.yield(.retract(Self.idleActivityID))
        let config = durations()
        // Floored at a minute: a zero-length leg with auto-advance on is a
        // begin->finish loop that chimes every 20 milliseconds.
        let total = max(config.length(of: leg), 60)
        session = Session(
            leg: leg,
            total: total,
            deadline: now() + total,
            pausedRemaining: nil,
            completedSessions: completedSessions ?? session?.completedSessions ?? 0
        )
        Self.log.notice("timer: \(leg.label, privacy: .public) for \(total, privacy: .public)s")
        publish()
        scheduleTick()
    }

    /// Starts a fresh cycle from a work session.
    public func startFocus() {
        begin(.work, completedSessions: 0)
    }

    /// A one-off countdown from a duration chip — iOS's quick-timer, not a
    /// pomodoro leg: it finishes back to the ready card regardless of the
    /// auto-advance preference.
    public func startCustom(minutes: Int) {
        cancelHandOver()
        continuation?.yield(.retract(Self.idleActivityID))
        let total = TimeInterval(max(1, min(minutes, 24 * 60))) * 60
        session = Session(
            leg: .work,
            total: total,
            deadline: now() + total,
            pausedRemaining: nil,
            completedSessions: 0,
            isCustom: true
        )
        Self.log.notice("timer: custom for \(total, privacy: .public)s")
        recents = Self.sanitizedRecents([Int(total / 60)] + recents)
        persistRecents(recents)
        publish()
        scheduleTick()
    }

    public func pause() {
        guard var current = session, current.isRunning else { return }
        current.pausedRemaining = current.remaining(at: now())
        current.deadline = nil
        session = current
        pending?.cancel()
        pending = nil
        publish()
    }

    public func resume() {
        guard var current = session, !current.isRunning else { return }
        let left = current.pausedRemaining ?? current.total
        current.deadline = now() + left
        current.pausedRemaining = nil
        session = current
        publish()
        scheduleTick()
    }

    public func toggle() {
        guard let current = session else { startFocus(); return }
        current.isRunning ? pause() : resume()
    }

    /// Ends the session and clears the card, leaving the ready card standing
    /// — or the stopwatch face, if the stopwatch is still going.
    public func cancel() {
        cancelHandOver()
        session = nil
        rest()
    }

    // MARK: - Stopwatch

    /// Start, or stop — the single primary button of the stopwatch face.
    public func stopwatchToggle() {
        cancelHandOver()
        if stopwatch.isRunning {
            stopwatch.elapsedBase = stopwatch.elapsed(at: now())
            stopwatch.runningSince = nil
        } else {
            continuation?.yield(.retract(Self.idleActivityID))
            stopwatch.runningSince = now()
        }
        publish()
        scheduleTick()
    }

    /// Marks a lap at the current elapsed time. Only while running, as on iOS.
    public func stopwatchLap() {
        guard stopwatch.isRunning else { return }
        stopwatch.laps.append(stopwatch.elapsed(at: now()))
        // Bounded: a stopwatch left lapping for a week must not grow a payload
        // without limit; the face shows the last few anyway.
        if stopwatch.laps.count > 50 { stopwatch.laps.removeFirst(stopwatch.laps.count - 50) }
        publish()
    }

    /// Back to zero. Only while stopped, as on iOS.
    public func stopwatchReset() {
        guard !stopwatch.isRunning else { return }
        stopwatch = StopwatchState()
        rest()
    }

    /// Republishes whatever remains after a session ends: the stopwatch face
    /// if the stopwatch is going, otherwise the ready card. Cancels the tick
    /// first; a live stopwatch re-arms it.
    private func rest() {
        pending?.cancel()
        pending = nil
        if session != nil || stopwatch.isActive {
            publish()
            scheduleTick()
        } else {
            retract()
            publishIdle()
        }
    }

    /// Ends this leg early and moves to whatever comes next.
    public func skip() {
        guard session != nil else { return }
        advance(finishedNaturally: false)
    }

    public var isActive: Bool { session != nil }
    public var isRunning: Bool { session?.isRunning ?? false }

    // MARK: - Ticking

    private func scheduleTick() {
        pending?.cancel()
        let countdownRunning = session?.isRunning ?? false
        guard countdownRunning || stopwatch.isRunning else { return }

        // Land just after the next whole second — of remaining time for a
        // countdown, of elapsed time for a stopwatch — so the displayed digits
        // change exactly when they should.
        let delay: TimeInterval
        if let current = session, current.isRunning {
            let left = current.remaining(at: now())
            delay = left <= 0 ? 0 : min(1.0, left.truncatingRemainder(dividingBy: 1.0) + 0.02)
        } else {
            let elapsed = stopwatch.elapsed(at: now())
            delay = min(1.0, 1.0 - elapsed.truncatingRemainder(dividingBy: 1.0) + 0.02)
        }

        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.02), execute: item)
    }

    /// Runs a tick now. The scheduler is wall-clock, so a test that has jumped
    /// the injected clock should not have to wait out a real second to see
    /// what the jump did.
    func tickNow() { tick() }

    private func tick() {
        if let current = session, current.isRunning {
            if current.remaining(at: now()) <= 0 {
                advance(finishedNaturally: true)
                return
            }
        } else if !stopwatch.isRunning {
            return
        }
        publish()
        scheduleTick()
    }

    /// The cycle rule: work → short break → work … → long break every fourth.
    /// Pure and static so it can be tested without a clock.
    nonisolated static func next(
        after leg: Leg,
        completedSessions: Int
    ) -> (leg: Leg, completedSessions: Int) {
        switch leg {
        case .work:
            let completed = completedSessions + 1
            let isCycleEnd = completed % sessionsPerCycle == 0
            return (isCycleEnd ? .longBreak : .shortBreak, completed)
        case .shortBreak:
            return (.work, completedSessions)
        case .longBreak:
            // A long break closes the cycle; the dots start over.
            return (.work, 0)
        }
    }

    /// The pause between one leg ending and the next beginning, while the
    /// notch is still announcing the end. Cancelled by anything the user does
    /// in that gap.
    ///
    /// Cancelling matters as much as scheduling: without it, a cycle stopped
    /// during those three seconds started its next leg anyway, seconds after
    /// being told to stop.
    private var handOver: DispatchWorkItem?

    private func cancelHandOver() {
        handOver?.cancel()
        handOver = nil
    }

    private func advance(finishedNaturally: Bool) {
        guard let current = session else { return }

        // A chip countdown has no next leg: announce the finish and rest as
        // the ready card, whatever the pomodoro auto-advance preference says.
        if current.isCustom {
            if finishedNaturally {
                publishFinished(current, completedSessions: 0)
                onFinished(current.leg)
            }
            session = nil
            rest()
            return
        }
        let (nextLeg, completed) = Self.next(
            after: current.leg,
            completedSessions: current.completedSessions
        )

        if finishedNaturally {
            // Announce the completed leg once, with an expiry so it clears
            // itself even if nothing comes next.
            publishFinished(current, completedSessions: completed)
            onFinished(current.leg)
        }

        if durations().autoAdvance {
            // The next leg waits for the notch to finish saying the last one
            // ended. Starting it immediately spent the announcement out of the
            // break: three seconds of a five-minute rest gone before the user
            // had been told the rest had begun — the app taking back the time
            // it was in the middle of granting.
            //
            // Only on a natural finish. Skipping a leg by hand is a decision
            // already made, and nothing is being announced, so the next one
            // starts at once.
            guard finishedNaturally else {
                begin(nextLeg, completedSessions: completed)
                return
            }
            handOver?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.handOver != nil else { return }
                    self.handOver = nil
                    // The user may have started, cancelled or skipped
                    // something in the gap; theirs wins.
                    guard self.session == nil else { return }
                    self.begin(nextLeg, completedSessions: completed)
                }
            }
            handOver = work
            session = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + handOverDelay, execute: work)
        } else {
            session = nil
            // Rest as the ready card (or the stopwatch face). On the
            // natural-finish path the finished announcement is still up (it
            // expires on its own); the resting card sits beneath it and is
            // what remains afterwards.
            rest()
        }
    }

    // MARK: - Publishing

    private func payload(_ current: Session, finished: Bool) -> TimerPayload {
        TimerPayload(
            label: current.isCustom ? "Timer" : current.leg.label,
            remaining: current.remaining(at: now()),
            total: current.total,
            isRunning: current.isRunning,
            isFinished: finished,
            isBreak: current.leg.isBreak,
            completedSessions: current.completedSessions,
            isCustom: current.isCustom,
            mode: .countdown,
            stopwatch: stopwatch,
            recents: recents
        )
    }

    /// The stopwatch face: no countdown, so `remaining` carries the elapsed
    /// time and `total` is zero — the ears and the satellite count up through
    /// the fields they already read.
    private func stopwatchPayload() -> TimerPayload {
        TimerPayload(
            label: "Stopwatch",
            remaining: stopwatch.elapsed(at: now()),
            total: 0,
            isRunning: stopwatch.isRunning,
            isFinished: false,
            isBreak: false,
            completedSessions: 0,
            isCustom: false,
            mode: .stopwatch,
            stopwatch: stopwatch,
            recents: recents
        )
    }

    private func publish() {
        let face: TimerPayload
        if let current = session {
            face = payload(current, finished: false)
        } else if stopwatch.isActive {
            face = stopwatchPayload()
        } else {
            return
        }
        continuation?.yield(.publish(Activity(
            id: Self.activityID,
            createdAt: now(),
            // Deliberately no expiry: expiry is measured from the *original*
            // createdAt, which upsert preserves, so a standing card must not
            // carry one.
            expiresAfter: nil,
            payload: .timer(face)
        )))
    }

    private func publishFinished(_ current: Session, completedSessions: Int) {
        var done = current
        done.deadline = nil
        done.pausedRemaining = 0
        done.completedSessions = completedSessions
        // The session card retires; the announcement arrives fresh, so it
        // peeks, takes the screen (it expires, and expiring arrivals do), and
        // its lifetime is measured from *now*.
        continuation?.yield(.retract(Self.activityID))
        continuation?.yield(.publish(Activity(
            id: Self.finishedActivityID,
            priority: ActivityKind.timer.defaultPriority + 25,
            createdAt: now(),
            expiresAfter: Self.finishedLifetime,
            payload: .timer(payload(done, finished: true))
        )))
    }

    private func retract() {
        continuation?.yield(.retract(Self.activityID))
    }

    /// The standing card a stopped timer rests as: presets and a start button.
    private func publishIdle() {
        let work = durations().length(of: .work)
        continuation?.yield(.publish(Activity(
            id: Self.idleActivityID,
            priority: Self.idlePriority,
            createdAt: now(),
            // Standing: it is the timer's resting state, not an announcement.
            payload: .timer(TimerPayload(
                label: "Timer",
                remaining: work,
                total: work,
                isRunning: false,
                isBreak: false,
                isIdle: true,
                recents: recents
            ))
        )))
    }
}
