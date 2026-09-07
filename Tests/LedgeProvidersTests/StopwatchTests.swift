import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders

@Suite("Stopwatch state")
struct StopwatchStateTests {

    @Test("Elapsed derives from the start instant, never from ticks")
    func elapsedFromInstant() {
        let watch = StopwatchState(elapsedBase: 10, runningSince: 1000)
        #expect(watch.elapsed(at: 1000) == 10)
        #expect(watch.elapsed(at: 1042.5) == 52.5)
        #expect(watch.isRunning)
        #expect(watch.isActive)
    }

    @Test("A stopped watch reports its banked time and a clock jump backwards never goes negative")
    func stoppedAndClockJump() {
        #expect(StopwatchState(elapsedBase: 7).elapsed(at: 5) == 7)
        #expect(StopwatchState(elapsedBase: 7, runningSince: 1000).elapsed(at: 900) == 7)
    }

    @Test("A fresh watch is inactive; time or laps make it active")
    func activity() {
        #expect(!StopwatchState().isActive)
        #expect(StopwatchState(elapsedBase: 0.5).isActive)
        #expect(StopwatchState(laps: [3]).isActive)
    }

    @Test("The current lap measures from the last mark")
    func currentLap() {
        let watch = StopwatchState(elapsedBase: 0, runningSince: 1000, laps: [12, 30])
        #expect(watch.currentLap(at: 1045) == 15)
        #expect(StopwatchState(runningSince: 1000).currentLap(at: 1009) == 9)
    }

    @Test("Decoding an old payload with no stopwatch keys yields a fresh watch")
    func decodeDefaults() throws {
        let json = #"{"label":"Focus","remaining":30,"total":60}"#.data(using: .utf8)!
        let payload = try JSONDecoder().decode(TimerPayload.self, from: json)
        #expect(payload.mode == .countdown)
        #expect(payload.stopwatch == StopwatchState())
        #expect(payload.recents.isEmpty)
        #expect(payload.hasCountdown)
    }

    @Test("Non-finite state is scrubbed on the way in")
    func scrubbing() {
        let watch = StopwatchState(elapsedBase: .nan, runningSince: .infinity, laps: [1, .nan, -2])
        #expect(watch.elapsedBase == 0)
        #expect(watch.runningSince == nil)
        #expect(watch.laps == [1, 0])
    }
}

@Suite("Quick-timer recents")
struct RecentsTests {

    @Test("Recents are distinct, sane, freshest first, and three at most")
    func sanitized() {
        #expect(TimerProvider.sanitizedRecents([45, 15, 45, 0, 5000, 20, 10]) == [45, 15, 20])
    }

    @Test("Encoding and decoding round-trip through the preference form")
    func roundTrip() {
        let encoded = TimerProvider.encodeRecents([20, 15])
        #expect(encoded == "20,15")
        #expect(TimerProvider.decodeRecents(" 20 , 15,junk,") == [20, 15])
        #expect(TimerProvider.decodeRecents("") == [])
    }
}

@Suite("Stopwatch provider")
@MainActor
struct StopwatchProviderTests {

    private func collect(_ provider: TimerProvider, while body: () -> Void) async -> [ProviderEvent] {
        let stream = provider.start()
        body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func sessionPayloads(_ events: [ProviderEvent]) -> [TimerPayload] {
        events.compactMap { event in
            guard case .publish(let activity) = event, activity.id == TimerProvider.activityID,
                  case .timer(let payload) = activity.payload
            else { return nil }
            return payload
        }
    }

    @Test("Starting the stopwatch publishes the session card wearing the stopwatch face")
    func startWearsStopwatchFace() async {
        var clock: TimeInterval = 1000
        let timer = TimerProvider(now: { clock })
        let events = await collect(timer) {
            timer.stopwatchToggle()
            clock = 1012
            timer.stopwatchLap()
        }
        let faces = sessionPayloads(events)
        #expect(faces.count == 2)
        #expect(faces.first?.mode == .stopwatch)
        #expect(faces.first?.isIdle == false)
        #expect(faces.first?.isRunning == true)
        #expect(faces.first?.total == 0, "no countdown: the ring has nothing to drain")
        #expect(faces.last?.stopwatch.laps == [12])
        #expect(faces.last?.remaining == 12, "remaining carries the elapsed time")
        let retractedIdle = events.contains { event in
            if case .retract(let id) = event { return id == TimerProvider.idleActivityID }
            return false
        }
        #expect(retractedIdle, "the ready card steps aside for the running face")
    }

    @Test("Stopping banks the elapsed time; reset rests on the ready card")
    func stopBanksResetRests() async {
        var clock: TimeInterval = 1000
        let timer = TimerProvider(now: { clock })
        let events = await collect(timer) {
            timer.stopwatchToggle()
            clock = 1030
            timer.stopwatchToggle()
            clock = 1100
            timer.stopwatchReset()
        }
        let faces = sessionPayloads(events)
        #expect(faces.last?.isRunning == false)
        #expect(faces.last?.stopwatch.elapsedBase == 30)
        #expect(faces.last?.stopwatch.elapsed(at: 1100) == 30, "stopped: no drift while the clock moves")
        guard case .publish(let last)? = events.last, case .timer(let payload) = last.payload else {
            Issue.record("expected the ready card last")
            return
        }
        #expect(payload.isIdle)
        #expect(payload.stopwatch == StopwatchState())
    }

    @Test("Laps only mark while running; reset only lands while stopped")
    func lapAndResetGuards() async {
        var clock: TimeInterval = 1000
        let timer = TimerProvider(now: { clock })
        _ = await collect(timer) {
            timer.stopwatchLap()
            timer.stopwatchToggle()
            clock = 1005
            timer.stopwatchReset()
        }
        #expect(timer.stopwatch.laps.isEmpty)
        #expect(timer.stopwatch.isRunning, "reset while running is refused")
    }

    @Test("A countdown that ends while the stopwatch runs rests on the stopwatch face, not the ready card")
    func countdownEndsIntoStopwatch() async {
        var clock: TimeInterval = 1000
        let timer = TimerProvider(now: { clock })
        let events = await collect(timer) {
            timer.stopwatchToggle()
            timer.startCustom(minutes: 1)
            clock = 1010
            timer.cancel()
        }
        let faces = sessionPayloads(events)
        #expect(faces.contains { $0.mode == .countdown && $0.stopwatch.isRunning },
                "the countdown face carries the live stopwatch alongside")
        #expect(faces.last?.mode == .stopwatch)
        let idleAtEnd = events.suffix(1).contains { event in
            guard case .publish(let activity) = event, case .timer(let payload) = activity.payload else { return false }
            return payload.isIdle
        }
        #expect(!idleAtEnd, "no ready card while the stopwatch is going")
    }

    @Test("A quick timer records its length in recents, freshest first, and persists it")
    func recentsRecorded() async {
        var persisted: [[Int]] = []
        let timer = TimerProvider(recents: [15], persistRecents: { persisted.append($0) }, now: { 1000 })
        let events = await collect(timer) {
            timer.startCustom(minutes: 20)
        }
        #expect(timer.recents == [20, 15])
        #expect(persisted == [[20, 15]])
        #expect(sessionPayloads(events).last?.recents == [20, 15])
    }

    @Test("Stopping the provider keeps a running stopwatch, and restarting resumes its face")
    func stopKeepsStopwatch() async {
        var clock: TimeInterval = 1000
        let timer = TimerProvider(now: { clock })
        _ = await collect(timer) { timer.stopwatchToggle() }
        clock = 1050
        let events = await collect(timer) {}
        let faces = sessionPayloads(events)
        #expect(faces.first?.mode == .stopwatch)
        #expect(faces.first?.remaining == 50)
    }
}
