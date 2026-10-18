import Foundation
import Testing

@testable import LedgeCore

/// Where Keep Awake sits among the things already competing for the notch.
///
/// All three rules it joins — the resting ears, the satellite seat, the queue's
/// own order — are pure functions with a stated ladder, and a rung added to one
/// of them is exactly the sort of change that is easy to make and impossible to
/// see afterwards.
@Suite("Keep Awake among the activities")
struct KeepAwakeActivityTests {

    private func keepAwake(_ phase: KeepAwakePayload.Phase, remaining: TimeInterval = 0) -> Activity {
        Activity(
            id: ActivityID(kind: .keepAwake, source: "test"),
            createdAt: 0,
            payload: .keepAwake(KeepAwakePayload(phase: phase, remaining: remaining, until: "17:40"))
        )
    }

    private func timer(idle: Bool) -> Activity {
        Activity(
            id: ActivityID(kind: .timer, source: "test"),
            createdAt: 0,
            payload: .timer(TimerPayload(
                label: "Focus", remaining: idle ? 1500 : 600, total: 1500,
                isRunning: !idle, isIdle: idle
            ))
        )
    }

    private var closeEvent: Activity {
        Activity(
            id: ActivityID(kind: .event, source: "calendar"),
            createdAt: 0,
            payload: .event(EventPayload(title: "Standup", location: "", startsIn: 300, hasEvent: true))
        )
    }

    // MARK: - The resting ears

    @Test("A running hold never takes the ears from anything")
    func aHoldTakesNothing() {
        let running = keepAwake(.running, remaining: 3600)
        let countdown = timer(idle: false)
        // Selected or not, it does not outrank a timer, a meeting — or
        // nothing at all.
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: countdown,
            closeEvent: nil, nowPlaying: nil, selected: running
        )?.id == countdown.id)
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: closeEvent, nowPlaying: nil, selected: running
        )?.id == closeEvent.id)
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: nil, nowPlaying: nil, selected: running
        ) == nil)
    }

    /// The cause of the cup that never left: a hold that has just been
    /// started is the selected card, and the selected card was the last rung.
    @Test("No Keep Awake card rests in the ears, running or not")
    func nothingRests() {
        #expect(!keepAwake(.running, remaining: 600).restsInEars)
        #expect(!keepAwake(.ready).restsInEars)
        #expect(!keepAwake(.finished(.timeUp)).restsInEars)
    }

    @Test("Starting is not news; ending and being picked up again are")
    func announcing() {
        #expect(!keepAwake(.ready).isWorthAnnouncing)
        #expect(!keepAwake(.running, remaining: 600).isWorthAnnouncing)
        #expect(keepAwake(.finished(.batteryFloor)).isWorthAnnouncing)
        // Quitting and switching the card off remove the surface the sentence
        // would appear on, so there is nobody to tell.
        #expect(!keepAwake(.finished(.quit)).isWorthAnnouncing)
        #expect(!keepAwake(.finished(.turnedOff)).isWorthAnnouncing)
        // A session that came back on its own says so with `resumed`.
        // `resumable` cannot carry this: it is what a *Finished* card offers
        // the Resume button, and it is nil on everything that is running.
        let resumed = Activity(
            id: ActivityID(kind: .keepAwake, source: "test"),
            createdAt: 0,
            payload: .keepAwake(KeepAwakePayload(
                phase: .running, remaining: 4320, until: "17:40", resumed: true
            ))
        )
        #expect(resumed.isWorthAnnouncing)
    }

    // MARK: - The satellite seat

    @Test("The satellite ladder: transient, timer, Keep Awake, recording")
    func satelliteRungOrder() {
        let level = SatelliteContent.level(HUDReadout(kind: .volume, level: 0.5))
        let countdown = SatelliteContent.timer(
            remaining: 60, total: 300, isBreak: false, isRunning: true
        )
        let awake = SatelliteContent.keepAwake(remaining: 3600)
        let privacy = SatelliteContent.privacy(camera: true, microphone: false)

        #expect(SatelliteArbiter.resolve(
            transient: level, privacy: privacy, timer: countdown, keepAwake: awake,
            timerIsMainIsland: false
        ) == level)
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: privacy, timer: countdown, keepAwake: awake,
            timerIsMainIsland: false
        ) == countdown)
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: privacy, timer: nil, keepAwake: awake,
            timerIsMainIsland: false
        ) == awake)
        // The timer holding the island frees the seat for Keep Awake, not for
        // the recording dot behind it.
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: privacy, timer: countdown, keepAwake: awake,
            timerIsMainIsland: true
        ) == awake)
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: privacy, timer: nil, keepAwake: nil,
            timerIsMainIsland: false
        ) == privacy)
    }

    @Test("The satellite label drops its seconds at a minute, not at an hour")
    func keepAwakeLabel() {
        #expect(SatelliteContent.keepAwakeLabel(remaining: 59) == "0:59")
        #expect(SatelliteContent.keepAwakeLabel(remaining: 60) == "1m")
        #expect(SatelliteContent.keepAwakeLabel(remaining: 45 * 60) == "45m")
        #expect(SatelliteContent.keepAwakeLabel(remaining: 3600) == "1h")
        #expect(SatelliteContent.keepAwakeLabel(remaining: 3600 + 12 * 60) == "1h 12m")
        // The timer keeps its own m:ss under the hour; the two labels agree
        // only where they are meant to.
        #expect(SatelliteContent.timerLabel(remaining: 45 * 60) == "45:00")
    }

    // MARK: - The queue's own order

    @Test("Keep Awake sits one under the timer, and its ending outranks both")
    func priorityOrder() {
        #expect(ActivityKind.keepAwake.defaultPriority == 44)
        #expect(ActivityKind.keepAwake.defaultPriority < ActivityKind.timer.defaultPriority)
        #expect(ActivityKind.keepAwake.defaultPriority > ActivityKind.focus.defaultPriority)

        let running = keepAwake(.running, remaining: 3600)
        let finished = keepAwake(.finished(.timeUp))
        let ready = keepAwake(.ready)
        #expect(Urgency.score(of: ready) == 44)
        #expect(Urgency.score(of: running) == 64)
        #expect(Urgency.score(of: finished) == 104)
        // A running session loses to the running timer it sits under; a
        // finished one comes ahead of it, because the Mac's power just changed.
        #expect(Urgency.score(of: running) < Urgency.score(of: timer(idle: false)))
        #expect(Urgency.score(of: finished) > Urgency.score(of: timer(idle: false)))
    }
}

/// A hold says itself once.
///
/// While the ears are showing it — the cup in one, the state in the other —
/// a disc beside the island saying the same thing is the same fact twice, and
/// the detached disc hides the ear that was saying it properly.
@Suite("Keep Awake does not orbit itself")
struct KeepAwakeSelfOrbitTests {

    private let awake = SatelliteContent.keepAwake(remaining: 3_600)
    private let privacy = SatelliteContent.privacy(camera: true, microphone: false)

    @Test("While the ears show the hold, the seat stays empty for it")
    func itYieldsWhileItIsTheIsland() {
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: nil, timer: nil, keepAwake: awake,
            timerIsMainIsland: false, keepAwakeIsMainIsland: true
        ) == nil)
    }

    @Test("Once the ears belong to something else it takes the seat")
    func itTakesTheSeatWhenItIsNotTheIsland() {
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: nil, timer: nil, keepAwake: awake,
            timerIsMainIsland: false, keepAwakeIsMainIsland: false
        ) == awake)
    }

    /// Yielding is not the same as having nothing: what is behind it still
    /// gets the seat.
    @Test("Yielding lets the recording dot through")
    func whatIsBehindItStillShows() {
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: privacy, timer: nil, keepAwake: awake,
            timerIsMainIsland: false, keepAwakeIsMainIsland: true
        ) == privacy)
    }

    @Test("A timer holding the island is unaffected by the hold's own rule")
    func theTimerRuleIsSeparate() {
        let countdown = SatelliteContent.timer(
            remaining: 60, total: 300, isBreak: false, isRunning: true
        )
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: nil, timer: countdown, keepAwake: awake,
            timerIsMainIsland: true, keepAwakeIsMainIsland: true
        ) == nil)
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: nil, timer: countdown, keepAwake: awake,
            timerIsMainIsland: false, keepAwakeIsMainIsland: true
        ) == countdown)
    }
}
