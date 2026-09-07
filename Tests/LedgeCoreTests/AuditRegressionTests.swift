import Foundation
import Testing

@testable import LedgeCore

/// Regressions for defects found in the audit. Each test names the failure it
/// prevents, so a future change that reintroduces one fails loudly.
@Suite("Audit regressions")
struct AuditRegressionTests {

    private func message(_ source: String, priority: Int? = nil, at time: TimeInterval = 0) -> Activity {
        Activity(
            id: ActivityID(kind: .message, source: source),
            priority: priority,
            createdAt: time,
            payload: .message(MessagePayload(title: source))
        )
    }

    // MARK: - Reducer

    @Test("A HUD during a peek cannot strand the overlay open")
    func hudDuringPeekDoesNotStrand() {
        // `hudRequested` cancels the peek timer. Restoring `.peek` afterwards
        // left the overlay open with nothing armed to close it — not pinned,
        // not hovered, no timer.
        var state = NotchState()
        _ = NotchReducer.reduce(&state, .peekRequested(2))
        _ = NotchReducer.reduce(&state, .hudRequested(1))
        _ = NotchReducer.reduce(&state, .timerFired(.hud))

        #expect(state.phase == .idle, "must not restore a peek whose timer was cancelled")
        #expect(state.suspended == nil)
    }

    @Test("A HUD during a peek while hovering holds, then settles cleanly")
    func hudDuringPeekWithHover() {
        var state = NotchState()
        _ = NotchReducer.reduce(&state, .peekRequested(2))
        _ = NotchReducer.reduce(&state, .hoverChanged(true))
        _ = NotchReducer.reduce(&state, .hudRequested(1))
        // While the pointer stays on it, the readout is held for adjustment.
        _ = NotchReducer.reduce(&state, .timerFired(.hud))
        #expect(state.phase == .hud, "held open under the pointer")
        // Pointer leaves; the tail timer then puts things back.
        _ = NotchReducer.reduce(&state, .hoverChanged(false))
        _ = NotchReducer.reduce(&state, .timerFired(.hud))
        #expect(state.phase == .idle)
    }

    // MARK: - HUD readout

    @Test("A non-finite level cannot crash the percentage conversion")
    func nonFiniteLevelIsSafe() {
        // `min`/`max` do not clamp NaN — it passed straight through and then
        // trapped converting to Int, taking down the app over a bad reading.
        for bad in [Double.nan, .infinity, -.infinity] {
            let readout = HUDReadout(kind: .volume, level: bad)
            #expect(readout.level == 0)
            #expect(readout.percentage == 0)
        }
    }

    @Test("Percentage never exceeds 100 for any input")
    func percentageBounded() {
        for level in [-5.0, 0, 0.5, 1, 42] {
            let percentage = HUDReadout(kind: .brightness, level: level).percentage
            #expect((0...100).contains(percentage))
        }
    }

    // MARK: - Queue

    @Test("Retracting a dismissed activity forgets the dismissal")
    func retractOfDismissedClearsUndo() {
        // The guard returned before clearing `dismissed`, so undo could
        // resurrect something the provider had explicitly retired.
        var queue = ActivityQueue()
        queue.upsert(message("buds"))
        queue.dismiss(ActivityID(kind: .message, source: "buds"))
        queue.retract(ActivityID(kind: .message, source: "buds"))
        #expect(!queue.canRestore)
    }

    @Test("Restoring does not overwrite a newer copy with a stale one")
    func restoreDoesNotClobberLiveActivity() {
        // Now playing republishes every second, so a dismissed card is already
        // back by the time undo is pressed; upserting the old snapshot rolled
        // the card back to the previous track.
        var queue = ActivityQueue()
        queue.upsert(Activity(
            id: ActivityID(kind: .nowPlaying, source: "spotify"),
            createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(title: "First", artist: "a"))
        ))
        queue.dismissSelected()
        queue.upsert(Activity(
            id: ActivityID(kind: .nowPlaying, source: "spotify"),
            createdAt: 5,
            payload: .nowPlaying(NowPlayingPayload(title: "Second", artist: "a"))
        ))

        queue.restoreLastDismissed()
        #expect(queue.count == 1)
        guard case .nowPlaying(let payload)? = queue.selected?.payload else {
            Issue.record("expected a now playing payload")
            return
        }
        #expect(payload.title == "Second", "the live value must win")
    }

    @Test("Ordering is total across kinds that share a source")
    func orderingIsTotalAcrossKinds() {
        // Identity is (kind, source); tie-breaking on source alone left two
        // distinct activities ordered by insertion, which `Array.sort` does not
        // promise to keep stable.
        func build(_ first: ActivityKind, _ second: ActivityKind) -> [ActivityID] {
            var queue = ActivityQueue()
            for kind in [first, second] {
                queue.upsert(Activity(
                    id: ActivityID(kind: kind, source: "shared"),
                    priority: 50,
                    createdAt: 1,
                    payload: .message(MessagePayload(title: "t"))
                ))
            }
            return queue.activities.map(\.id)
        }
        #expect(build(.message, .device) == build(.device, .message))
    }

    @Test("An in-place update keeps its original creation time")
    func upsertPreservesCreatedAt() {
        // `createdAt` is the second sort key. A provider re-stamping it on every
        // poll silently broke the ordering without triggering a re-sort.
        var queue = ActivityQueue()
        queue.upsert(message("a", priority: 50, at: 1))
        queue.upsert(message("b", priority: 50, at: 2))
        #expect(queue.activities.map(\.id.source) == ["b", "a"])

        queue.upsert(message("a", priority: 50, at: 99))
        #expect(queue.activities.map(\.id.source) == ["b", "a"], "order must not drift")
    }

    @Test("Dismissing the same activity twice needs only one undo")
    func dismissDoesNotStack() {
        var queue = ActivityQueue()
        queue.upsert(message("a"))
        queue.dismissSelected()
        queue.upsert(message("a"))
        queue.dismissSelected()

        queue.restoreLastDismissed()
        #expect(!queue.canRestore, "a second undo would visibly do nothing")
    }

    // MARK: - Layout

    @Test("A zero-size screen cannot produce a negative width")
    func degenerateScreenIsSafe() {
        // NSScreen.frame can be transiently zero during display reconfiguration,
        // and a negative width flowed into the shape path and the panel frame.
        let geometry = NotchGeometry.simulated(screenSize: .zero)
        let layout = NotchLayout.expanded(
            geometry,
            size: CGSize(width: 420, height: 160),
            bottomRadius: 14,
            gutterRadius: 10
        )
        #expect(layout.bodySize.width >= 0)
        #expect(layout.bodySize.height >= 0)
        #expect(layout.boundingSize.width >= 0)
    }

    @Test("Radii can never exceed the body they round")
    func radiiClamped() {
        // Peek and HUD bodies are only a few points taller than the cutout,
        // while the Appearance slider goes to 40 — a radius larger than the
        // height produces a self-intersecting path.
        let air = NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: 735.5,
            isHardwareNotch: true
        )
        for phase in NotchPhase.allCases {
            let layout = NotchLayout.layout(
                for: phase,
                geometry: air,
                expandedSize: CGSize(width: 420, height: 160),
                bottomRadius: 40,
                closedBottomRadius: 999,
                gutterRadius: 30
            )
            #expect(layout.bottomRadius <= layout.bodySize.height / 2, "\(phase)")
            #expect(layout.bottomRadius <= layout.bodySize.width / 2, "\(phase)")
            #expect(layout.bottomRadius >= 0, "\(phase)")
            #expect(layout.gutterRadius >= 0, "\(phase)")
        }
    }

    // MARK: - Gestures

    @Test("A backwards clock ends the gesture instead of carrying it over")
    func backwardsTimestampResets() {
        // Event timestamps jump backwards across sleep/wake. A signed comparison
        // never noticed, so stale accumulation fired a swipe that never happened.
        var recognizer = SwipeRecognizer(threshold: 30)
        #expect(recognizer.feed(ScrollSample(dx: 20, dy: 0, timestamp: 100)) == .pending)
        #expect(recognizer.feed(ScrollSample(dx: 20, dy: 0, timestamp: 0)) == .pending)
    }

    @Test("A non-finite delta does not poison the recogniser")
    func nonFiniteDeltaIgnored() {
        // NaN propagates through the accumulator and every later comparison is
        // false, so the recogniser failed silently and closed.
        var recognizer = SwipeRecognizer(threshold: 20)
        #expect(recognizer.feed(ScrollSample(dx: .nan, dy: 0, timestamp: 0)) == .pending)
        #expect(recognizer.feed(ScrollSample(dx: 30, dy: 0, timestamp: 0.01)) == .swipe(.right))
    }

    @Test("A zero threshold cannot fire on every event")
    func zeroThresholdIsInert() {
        // Not reachable from the slider, but the value is read from user
        // defaults with no validation.
        var recognizer = SwipeRecognizer(threshold: 0)
        #expect(recognizer.feed(ScrollSample(dx: 0, dy: 0, timestamp: 0)) == .pending)
    }
}

/// Who gets the satellite seat.
@Suite("Satellite arbiter")
struct SatelliteArbiterTests {

    private let level = SatelliteContent.level(HUDReadout(kind: .volume, level: 0.5))
    private let timer = SatelliteContent.timer(remaining: 60, total: 300, isBreak: false, isRunning: true)
    private let privacy = SatelliteContent.privacy(camera: true, microphone: false)

    @Test("The freshest transient preempts every standing tenant")
    func transientWins() {
        #expect(SatelliteArbiter.resolve(
            transient: level, privacy: privacy, timer: timer, timerIsMainIsland: false
        ) == level)
    }

    @Test("The timer outranks recording — macOS already draws its own mic dot")
    func timerOverPrivacy() {
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: privacy, timer: timer, timerIsMainIsland: false
        ) == timer)
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: privacy, timer: nil, timerIsMainIsland: false
        ) == privacy)
        // With the timer as the island itself, recording takes the seat.
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: privacy, timer: timer, timerIsMainIsland: true
        ) == privacy)
    }

    @Test("The timer never orbits itself")
    func timerNotOwnSatellite() {
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: nil, timer: timer, timerIsMainIsland: true
        ) == nil)
        // But a transient still may sit beside a timer island.
        #expect(SatelliteArbiter.resolve(
            transient: level, privacy: nil, timer: timer, timerIsMainIsland: true
        ) == level)
    }
}

/// The timer blob's countdown label across the hour boundary.
@Suite("Satellite timer label")
struct SatelliteTimerLabelTests {

    @Test("Under an hour is m:ss, an hour or more is spelled h/m")
    func formats() {
        #expect(SatelliteContent.timerLabel(remaining: 0) == "0:00")
        #expect(SatelliteContent.timerLabel(remaining: 754) == "12:34")
        #expect(SatelliteContent.timerLabel(remaining: 3600) == "1h")
        #expect(SatelliteContent.timerLabel(remaining: 5400) == "1h 30m")
    }

    @Test("The tick across the hour goes 1h to 59:59, never 0:59")
    func hourBoundary() {
        #expect(SatelliteContent.timerLabel(remaining: 3601) == "1h")
        #expect(SatelliteContent.timerLabel(remaining: 3599) == "59:59")
    }

    @Test("Hostile values clamp instead of trapping")
    func hostile() {
        #expect(SatelliteContent.timerLabel(remaining: .nan) == "0:00")
        #expect(SatelliteContent.timerLabel(remaining: -5) == "0:00")
        // The 359_940s clamp is 99h 3540s exactly.
        #expect(SatelliteContent.timerLabel(remaining: 1e300) == "99h 59m")
    }
}

/// The urgency ranking: situational boosts over static ranks.
@Suite("Urgency")
struct UrgencyTests {

    private func make(_ payload: ActivityPayload, kind: ActivityKind, priority: Int? = nil) -> Activity {
        Activity(
            id: ActivityID(kind: kind, source: "t"),
            priority: priority,
            createdAt: 0,
            payload: payload
        )
    }

    @Test("Playing music outranks a quiet calendar; an imminent meeting outranks playing music")
    func situationalOrdering() {
        let playing = make(.nowPlaying(NowPlayingPayload(title: "t", artist: "a", isPlaying: true)), kind: .nowPlaying)
        let paused = make(.nowPlaying(NowPlayingPayload(title: "t", artist: "a", isPlaying: false)), kind: .nowPlaying)
        let quietCalendar = make(.event(EventPayload(title: "", startsIn: 0, hasEvent: false)), kind: .event)
        let imminent = make(.event(EventPayload(title: "Standup", startsIn: 5 * 60, hasEvent: true)), kind: .event)
        let soon = make(.event(EventPayload(title: "Standup", startsIn: 45 * 60, hasEvent: true)), kind: .event)

        #expect(Urgency.score(of: playing) > Urgency.score(of: quietCalendar))
        #expect(Urgency.score(of: quietCalendar) > Urgency.score(of: paused))
        #expect(Urgency.score(of: imminent) > Urgency.score(of: playing))
        #expect(Urgency.score(of: soon) > Urgency.score(of: playing))
        #expect(Urgency.score(of: imminent) > Urgency.score(of: soon))
    }

    @Test("A running timer beats music; a finished one beats nearly everything")
    func timerBoosts() {
        let running = make(.timer(TimerPayload(label: "Focus", remaining: 60, total: 300, isRunning: true)), kind: .timer)
        let finished = make(
            .timer(TimerPayload(label: "Focus", remaining: 0, total: 300, isRunning: false, isFinished: true)),
            kind: .timer, priority: ActivityKind.timer.defaultPriority + 25
        )
        let idle = make(.timer(TimerPayload(label: "Timer", remaining: 300, total: 300, isRunning: false, isIdle: true)), kind: .timer, priority: 18)
        let playing = make(.nowPlaying(NowPlayingPayload(title: "t", artist: "a", isPlaying: true)), kind: .nowPlaying)

        #expect(Urgency.score(of: running) > Urgency.score(of: playing))
        #expect(Urgency.score(of: finished) > Urgency.score(of: running))
        #expect(Urgency.score(of: playing) > Urgency.score(of: idle))
    }

    @Test("Active recording outranks even a finished timer; a pin outranks everything")
    func topOfTheWorld() {
        let recording = make(.privacy(PrivacyPayload(cameraActive: true)), kind: .privacy)
        let finished = make(
            .timer(TimerPayload(label: "Focus", remaining: 0, total: 300, isRunning: false, isFinished: true)),
            kind: .timer, priority: ActivityKind.timer.defaultPriority + 25
        )
        #expect(Urgency.score(of: recording) > Urgency.score(of: finished))
        #expect(Urgency.score(of: finished, pinned: .timer) > Urgency.score(of: recording, pinned: .timer))
    }

    @Test("Rain lifts the weather card; a dry forecast leaves it at base")
    func weather() {
        let dry = make(.weather(WeatherPayload(temperatureCelsius: 20)), kind: .weather)
        let wet = make(.weather(WeatherPayload(temperatureCelsius: 20, rainSoonMinutes: 20)), kind: .weather)
        #expect(Urgency.score(of: wet) == Urgency.score(of: dry) + 15)
    }
}

/// The freeze contract: nothing reorders under the cursor.
@Suite("Order freeze")
struct OrderFreezeTests {

    @Test("An in-place score change waits out the freeze, then lands")
    func freezeDefersReorder() {
        var queue = ActivityQueue()
        queue.upsert(Activity(
            id: ActivityID(kind: .nowPlaying, source: "m"), createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(title: "t", artist: "a", isPlaying: true))
        ))
        queue.upsert(Activity(
            id: ActivityID(kind: .event, source: "calendar"), createdAt: 1,
            payload: .event(EventPayload(title: "", startsIn: 0, hasEvent: false))
        ))
        #expect(queue.activities.first?.id.kind == .nowPlaying)

        queue.orderFrozen = true
        // The meeting enters its final quarter-hour while the stack is open.
        queue.upsert(Activity(
            id: ActivityID(kind: .event, source: "calendar"), createdAt: 2,
            payload: .event(EventPayload(title: "Standup", startsIn: 5 * 60, hasEvent: true))
        ))
        #expect(queue.activities.first?.id.kind == .nowPlaying, "frozen order must hold")

        queue.orderFrozen = false
        #expect(queue.activities.first?.id.kind == .event, "unfreezing applies the re-rank")
    }
}

/// The event-steal hand-back: an expiring announcement borrows the stage and
/// returns it to the card the user had chosen.
@Suite("Event steal hand-back")
struct EventStealTests {

    private func standing(_ kind: ActivityKind, _ source: String, priority: Int) -> Activity {
        Activity(
            id: ActivityID(kind: kind, source: source),
            priority: priority, createdAt: 0,
            payload: .focus(FocusPayload(name: source))
        )
    }

    @Test("An event does not steal a frozen stage")
    func eventRespectsFreeze() {
        var queue = ActivityQueue()
        queue.upsert(standing(.event, "a", priority: 50))
        queue.select(ActivityID(kind: .event, source: "a"))
        queue.orderFrozen = true

        let announcement = Activity(
            id: ActivityID(kind: .keyboard, source: "k"),
            priority: 72, createdAt: 1, expiresAfter: 2,
            payload: .focus(FocusPayload(name: "k"))
        )
        queue.upsert(announcement)
        // The user is reading the open card; the announcement flashes from
        // the presentation's peeked slot instead of yanking the selection.
        #expect(queue.selectedID?.source == "a", "nothing moves under the cursor")

        queue.orderFrozen = false
        let second = Activity(
            id: ActivityID(kind: .keyboard, source: "k2"),
            priority: 72, createdAt: 3, expiresAfter: 2,
            payload: .focus(FocusPayload(name: "k2"))
        )
        queue.upsert(second)
        #expect(queue.selectedID?.source == "k2", "unfrozen, events take the stage as before")
    }

    @Test("Expiry returns the stage to the preempted card, not the slot's neighbour")
    func handBack() {
        var queue = ActivityQueue()
        queue.upsert(standing(.event, "a", priority: 50))
        queue.upsert(standing(.nowPlaying, "b", priority: 30))
        queue.upsert(standing(.weather, "c", priority: 10))
        queue.select(ActivityID(kind: .weather, source: "c"))

        let stealer = Activity(
            id: ActivityID(kind: .keyboard, source: "k"),
            priority: 72, createdAt: 1, expiresAfter: 2,
            payload: .focus(FocusPayload(name: "k"))
        )
        queue.upsert(stealer)
        #expect(queue.selectedID == stealer.id, "the announcement takes the stage")

        queue.retract(stealer.id)
        #expect(queue.selectedID?.source == "c", "the stage goes back to the user's card")
    }

    @Test("Chained steals hand back to the original owner")
    func chainedSteals() {
        var queue = ActivityQueue()
        queue.upsert(standing(.nowPlaying, "b", priority: 30))
        queue.select(ActivityID(kind: .nowPlaying, source: "b"))
        let first = Activity(
            id: ActivityID(kind: .keyboard, source: "k1"),
            priority: 72, createdAt: 1, expiresAfter: 2,
            payload: .focus(FocusPayload(name: "k1"))
        )
        let second = Activity(
            id: ActivityID(kind: .device, source: "d1"),
            priority: 60, createdAt: 2, expiresAfter: 2,
            payload: .focus(FocusPayload(name: "d1"))
        )
        queue.upsert(first)
        queue.upsert(second)
        queue.retract(second.id)
        #expect(queue.selectedID?.source == "b", "back to the original owner")
    }

    @Test("Cycling away cancels the promise — the user moved on")
    func userMoveCancels() {
        var queue = ActivityQueue()
        queue.upsert(standing(.event, "a", priority: 50))
        queue.upsert(standing(.nowPlaying, "b", priority: 30))
        queue.select(ActivityID(kind: .nowPlaying, source: "b"))
        let stealer = Activity(
            id: ActivityID(kind: .keyboard, source: "k"),
            priority: 72, createdAt: 1, expiresAfter: 2,
            payload: .focus(FocusPayload(name: "k"))
        )
        queue.upsert(stealer)
        queue.cycleForward()
        let chosen = queue.selectedID
        queue.retract(stealer.id)
        // Wherever the user cycled to (or its slot-neighbour if it was the
        // stealer itself), the old promise must not yank selection.
        if chosen != stealer.id {
            #expect(queue.selectedID == chosen)
        }
    }

    @Test("While frozen, a standing arrival cannot steal the stage")
    func frozenStandingNoSteal() {
        var queue = ActivityQueue()
        queue.upsert(standing(.weather, "c", priority: 10))
        queue.select(ActivityID(kind: .weather, source: "c"))
        queue.orderFrozen = true
        queue.upsert(standing(.privacy, "p", priority: 75))
        #expect(queue.selectedID?.source == "c", "frozen stage holds against standing arrivals")
        queue.orderFrozen = false
        #expect(queue.activities.first?.id.source == "p", "the re-rank still lands after")
    }
}

extension EventStealTests {

    @Test("Dismissing the stealer kills the promise — no ancient-card graft")
    func dismissKillsPromise() {
        var queue = ActivityQueue()
        queue.upsert(Activity(
            id: ActivityID(kind: .event, source: "a"), priority: 50, createdAt: 0,
            payload: .focus(FocusPayload(name: "a"))
        ))
        queue.upsert(Activity(
            id: ActivityID(kind: .weather, source: "c"), priority: 10, createdAt: 0,
            payload: .focus(FocusPayload(name: "c"))
        ))
        queue.select(ActivityID(kind: .weather, source: "c"))

        let first = Activity(
            id: ActivityID(kind: .keyboard, source: "k"), priority: 72,
            createdAt: 1, expiresAfter: 2, payload: .focus(FocusPayload(name: "k"))
        )
        queue.upsert(first)
        // The user swipes the announcement away; the hand-back happens now and
        // the promise dies with it.
        queue.dismiss(first.id)
        #expect(queue.selectedID?.source == "c", "dismissal hands back like expiry")

        // The provider's retract for the dismissed card arrives later — the
        // early-return path that used to skip promise cleanup.
        queue.retract(first.id)

        // A second steal arrives immediately — before any deliberate
        // selection could launder a stale promise. If the dismissal failed to
        // kill it, the chain grafts "c"'s ancient claim here and the hand-back
        // goes to the wrong card. (The earlier version of this test selected
        // a card in between, which cleared the stale promise itself and made
        // the test pass with the fix reverted — mutation testing caught it.)
        let second = Activity(
            id: ActivityID(kind: .device, source: "d"), priority: 60,
            createdAt: 2, expiresAfter: 2, payload: .focus(FocusPayload(name: "d"))
        )
        queue.upsert(second)
        queue.retract(second.id)
        #expect(queue.selectedID?.source == "c", "hand-back to the fresh preempted card, no graft")
    }

    @Test("Dismissing the preempted card clears its claim from the promise")
    func dismissPreemptedClears() {
        var queue = ActivityQueue()
        queue.upsert(Activity(
            id: ActivityID(kind: .weather, source: "c"), priority: 10, createdAt: 0,
            payload: .focus(FocusPayload(name: "c"))
        ))
        queue.upsert(Activity(
            id: ActivityID(kind: .event, source: "x"), priority: 50, createdAt: 0,
            payload: .focus(FocusPayload(name: "x"))
        ))
        queue.select(ActivityID(kind: .weather, source: "c"))
        let first = Activity(
            id: ActivityID(kind: .keyboard, source: "k"), priority: 72,
            createdAt: 1, expiresAfter: 2, payload: .focus(FocusPayload(name: "k"))
        )
        queue.upsert(first)
        // The user dismisses the card the promise points AT, not the stealer.
        queue.dismiss(ActivityID(kind: .weather, source: "c"))

        // A second steal chains; with a stale promise it would chain the
        // absent "c" and the hand-back would fall to slot arithmetic.
        let second = Activity(
            id: ActivityID(kind: .device, source: "d"), priority: 60,
            createdAt: 2, expiresAfter: 2, payload: .focus(FocusPayload(name: "d"))
        )
        queue.upsert(second)
        queue.retract(second.id)
        #expect(queue.selectedID?.source == "k", "the fresh promise points at the stealer the user was on")
    }

    @Test("Restore cancels the promise like any deliberate selection")
    func restoreCancelsPromise() {
        var queue = ActivityQueue()
        queue.upsert(Activity(
            id: ActivityID(kind: .weather, source: "c"), priority: 10, createdAt: 0,
            payload: .focus(FocusPayload(name: "c"))
        ))
        queue.select(ActivityID(kind: .weather, source: "c"))
        queue.upsert(Activity(
            id: ActivityID(kind: .nowPlaying, source: "b"), priority: 30, createdAt: 0,
            payload: .focus(FocusPayload(name: "b"))
        ))
        queue.dismiss(ActivityID(kind: .nowPlaying, source: "b"))

        let stealer = Activity(
            id: ActivityID(kind: .keyboard, source: "k"), priority: 72,
            createdAt: 1, expiresAfter: 2, payload: .focus(FocusPayload(name: "k"))
        )
        queue.upsert(stealer)
        // Undo restores the dismissed card — a deliberate move.
        _ = queue.restoreLastDismissed(at: 2)
        #expect(queue.selectedID?.source == "b")
        // A second steal while the first is still alive: a promise surviving
        // the restore would graft the pre-restore card onto this chain.
        let second = Activity(
            id: ActivityID(kind: .device, source: "d"), priority: 60,
            createdAt: 3, expiresAfter: 2, payload: .focus(FocusPayload(name: "d"))
        )
        queue.upsert(second)
        queue.retract(second.id)
        #expect(queue.selectedID?.source == "b", "the promise died at the restore, no graft")
    }
}

/// House-pattern decode drift: every payload's hand-written `init(from:)`
/// defaults missing keys the way the memberwise init does.
@Suite("Payload decode defaults")
struct PayloadDecodeDefaultTests {

    @Test("A day dot with no entry detail decodes")
    func monthDayEventsDefaultsEntries() throws {
        let decoded = try JSONDecoder().decode(
            MonthDayEvents.self,
            from: Data(#"{"day": 4}"#.utf8)
        )
        #expect(decoded.day == 4)
        #expect(decoded.entries.isEmpty)
    }

    @Test("A bare levels payload decodes with both defaults")
    func levelsDefaults() throws {
        let decoded = try JSONDecoder().decode(
            LevelsPayload.self,
            from: Data("{}".utf8)
        )
        #expect(decoded.volume == 0.5)
        #expect(decoded.brightness == 0.5)
    }

    @Test("Same-titled simultaneous entries keep distinct identities")
    func entryIdentityIncludesEventID() {
        let a = MonthDayEntry(title: "Birthday", time: "", eventID: "a")
        let b = MonthDayEntry(title: "Birthday", time: "", eventID: "b")
        #expect(a.id != b.id)
    }
}


/// The synthesized equalizer: what replaced the audio tap. Deterministic and
/// bounded, or the bars would disagree between views and clip the layout.
@Suite("Level simulator")
struct LevelSimulatorTests {

    @Test("Deterministic: same track, same instant, same bars")
    func deterministic() {
        let seed = LevelSimulator.seed(for: "track|artist")
        #expect(LevelSimulator.levels(at: 12.34, seed: seed)
            == LevelSimulator.levels(at: 12.34, seed: seed))
        // Different tracks read differently at the same instant.
        let other = LevelSimulator.seed(for: "another|artist")
        #expect(LevelSimulator.levels(at: 12.34, seed: seed)
            != LevelSimulator.levels(at: 12.34, seed: other))
    }

    @Test("Bounded and sized across a minute of samples")
    func boundedAndSized() {
        let seed = LevelSimulator.seed(for: "any")
        for tick in 0..<600 {
            let levels = LevelSimulator.levels(at: Double(tick) / 10, seed: seed)
            #expect(levels.count == 6)
            #expect(levels.allSatisfy { $0 >= 0 && $0 <= 1 && $0.isFinite })
        }
    }

    @Test("Hostile inputs stay safe")
    func hostileInputs() {
        #expect(LevelSimulator.levels(at: .nan, seed: 1).isEmpty)
        #expect(LevelSimulator.levels(at: 5, seed: 0, bands: 0).isEmpty)
        #expect(LevelSimulator.levels(at: 5, seed: .max, bands: 1).count == 1)
    }

    @Test("The seed is stable across processes")
    func stableSeed() {
        // FNV-1a of "abc" — a fixed value, not hashValue's per-launch salt.
        #expect(LevelSimulator.seed(for: "abc") == 0xe71fa2190541574b)
    }
}
