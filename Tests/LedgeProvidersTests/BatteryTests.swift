import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

@Suite("Battery transitions")
@MainActor
struct BatteryTransitionTests {

    private func snapshot(
        _ percentage: Double,
        charging: Bool = false,
        plugged: Bool = false,
        lowPower: Bool = false
    ) -> PowerSnapshot {
        PowerSnapshot(
            percentage: percentage,
            isCharging: charging,
            isPluggedIn: plugged,
            isLowPower: lowPower,
            timeRemaining: nil
        )
    }

    /// Convenience for the single-step cases: a fresh latch each time.
    private func transitions(
        from old: PowerSnapshot?,
        to new: PowerSnapshot
    ) -> [BatteryProvider.Transition] {
        var warnings = BatteryProvider.Warnings()
        return BatteryProvider.transitions(from: old, to: new, warnings: &warnings)
    }

    @Test("The first reading is a baseline, not news")
    func firstReadingIsSilent() {
        // Otherwise a card would pop every time the app launches.
        #expect(transitions(from: nil, to: snapshot(0.5)).isEmpty)
        #expect(transitions(from: nil, to: snapshot(0.05)).isEmpty)
    }

    @Test("A percentage change on its own publishes nothing")
    func percentAloneIsSilent() {
        // The whole point of the transition filter: a card per percent would
        // peek continuously while the machine discharges.
        #expect(transitions(from: snapshot(0.80), to: snapshot(0.79)).isEmpty)
        #expect(transitions(from: snapshot(0.50), to: snapshot(0.49)).isEmpty)
    }

    @Test("Plugging in and unplugging are both reported")
    func powerConnectionChanges() {
        #expect(
            transitions(from: snapshot(0.5), to: snapshot(0.5, plugged: true)) == [.pluggedIn]
        )
        #expect(
            transitions(from: snapshot(0.5, plugged: true), to: snapshot(0.5)) == [.unplugged]
        )
    }

    @Test("Reaching full is reported once, not on every later reading")
    func fullyChargedFiresOnce() {
        let charging = snapshot(0.99, charging: true, plugged: true)
        let full = snapshot(1.0, plugged: true)
        #expect(transitions(from: charging, to: full) == [.fullyCharged])
        // Still plugged in and still full: nothing new to say.
        #expect(transitions(from: full, to: full).isEmpty)
    }

    @Test("Crossing the low threshold fires once")
    func lowFiresOnCrossing() {
        var warnings = BatteryProvider.Warnings()
        #expect(
            BatteryProvider.transitions(
                from: snapshot(0.21), to: snapshot(0.20), warnings: &warnings
            ) == [.low]
        )
        // Still discharging below the line — the warning has been given, and
        // the latch is what remembers that, not the previous reading.
        #expect(
            BatteryProvider.transitions(
                from: snapshot(0.20), to: snapshot(0.19), warnings: &warnings
            ).isEmpty
        )
    }

    @Test("Hovering on the threshold does not republish")
    func hoveringDoesNotRepeat() {
        // Charge fluctuates by a tenth of a percent constantly. Re-warning on
        // every wobble across the line would be unusable.
        var previous = snapshot(0.21)
        var warnings = BatteryProvider.Warnings()
        var fired = 0
        for value in [0.20, 0.201, 0.199, 0.20, 0.198] {
            let next = snapshot(value)
            let events = BatteryProvider.transitions(
                from: previous, to: next, warnings: &warnings
            )
            if !events.isEmpty { fired += 1 }
            previous = next
        }
        #expect(fired == 1, "only the first crossing counts")
    }

    @Test("The warning re-arms once the battery is meaningfully charged again")
    func warningRearmsAfterCharging() {
        var warnings = BatteryProvider.Warnings()
        var previous = snapshot(0.21)

        _ = BatteryProvider.transitions(from: previous, to: snapshot(0.19), warnings: &warnings)
        previous = snapshot(0.19)

        // Charged well clear of the threshold, then drained again — this is a
        // new discharge and deserves a fresh warning.
        _ = BatteryProvider.transitions(from: previous, to: snapshot(0.40), warnings: &warnings)
        previous = snapshot(0.40)

        let events = BatteryProvider.transitions(
            from: previous, to: snapshot(0.19), warnings: &warnings
        )
        #expect(events == [.low])
    }

    @Test("Starting up already low does not warn about what the user can see")
    func startingLowIsSilent() {
        // The latch is seeded from the first reading, so launching at 15% is
        // not treated as having just crossed the line.
        var warnings = BatteryProvider.Warnings()
        warnings.low = true
        let events = BatteryProvider.transitions(
            from: snapshot(0.15), to: snapshot(0.14), warnings: &warnings
        )
        #expect(events.isEmpty)
    }

    @Test("Critical outranks low at the same crossing")
    func criticalWinsOverLow() {
        let events = transitions(from: snapshot(0.11), to: snapshot(0.09))
        #expect(events == [.critical])
        #expect(!events.contains(.low), "one warning, not two")
    }

    @Test("Charging back up past a threshold is not a warning")
    func chargingUpIsSilent() {
        let events = transitions(
            from: snapshot(0.19, charging: true, plugged: true),
            to: snapshot(0.21, charging: true, plugged: true)
        )
        #expect(!events.contains(.low))
        #expect(!events.contains(.critical))
    }

    @Test("A low battery warning is suppressed while plugged in")
    func noLowWarningOnPower() {
        // Draining below 20% while connected to a charger that cannot keep up
        // is not something to interrupt anyone about.
        let events = transitions(
            from: snapshot(0.21, plugged: true),
            to: snapshot(0.19, plugged: true)
        )
        #expect(events.isEmpty)
    }

    @Test("Low Power Mode is reported in both directions")
    func lowPowerModeToggles() {
        #expect(
            transitions(from: snapshot(0.5), to: snapshot(0.5, lowPower: true))
                == [.lowPowerMode(true)]
        )
        #expect(
            transitions(from: snapshot(0.5, lowPower: true), to: snapshot(0.5))
                == [.lowPowerMode(false)]
        )
    }
}

@Suite("Battery provider")
@MainActor
struct BatteryProviderTests {

    private func collect(
        _ provider: BatteryProvider,
        while body: () -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        body()
        provider.stop()

        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("A transition publishes exactly one card")
    func publishesOnTransition() async {
        let source = StubPowerSource(value: PowerSnapshot(
            percentage: 0.5, isCharging: false, isPluggedIn: false,
            isLowPower: false, timeRemaining: nil
        ))
        let provider = BatteryProvider(source: source, now: { 100 })

        let events = await collect(provider) {
            source.set(PowerSnapshot(
                percentage: 0.5, isCharging: true, isPluggedIn: true,
                isLowPower: false, timeRemaining: nil
            ))
        }

        #expect(events.count == 1)
        guard case .publish(let activity)? = events.first else {
            Issue.record("expected a publish")
            return
        }
        #expect(activity.id == ActivityID(kind: .power, source: "internal"))
        // Transient by construction: a battery card must not outstay its news.
        #expect(activity.expiresAfter != nil)
    }

    @Test("Nothing is published when nothing interesting happened")
    func silentWithoutTransition() async {
        let source = StubPowerSource(value: PowerSnapshot(
            percentage: 0.5, isCharging: false, isPluggedIn: false,
            isLowPower: false, timeRemaining: nil
        ))
        let provider = BatteryProvider(source: source, now: { 100 })

        let events = await collect(provider) {
            source.set(PowerSnapshot(
                percentage: 0.49, isCharging: false, isPluggedIn: false,
                isLowPower: false, timeRemaining: nil
            ))
        }
        #expect(events.isEmpty)
    }

    @Test("A critical warning outranks a routine battery card")
    func criticalIsPrioritised() async {
        let source = StubPowerSource(value: PowerSnapshot(
            percentage: 0.11, isCharging: false, isPluggedIn: false,
            isLowPower: false, timeRemaining: nil
        ))
        let provider = BatteryProvider(source: source, now: { 100 })

        let events = await collect(provider) {
            source.set(PowerSnapshot(
                percentage: 0.08, isCharging: false, isPluggedIn: false,
                isLowPower: false, timeRemaining: nil
            ))
        }
        guard case .publish(let activity)? = events.first else {
            Issue.record("expected a publish")
            return
        }
        #expect(activity.priority > ActivityKind.power.defaultPriority)
    }

    // MARK: - The charger changing its mind under a live card

    private func power(
        _ percentage: Double, charging: Bool, plugged: Bool
    ) -> PowerSnapshot {
        PowerSnapshot(
            percentage: percentage, isCharging: charging, isPluggedIn: plugged,
            isLowPower: false, timeRemaining: nil
        )
    }

    private func charging(_ event: ProviderEvent) -> Bool? {
        guard case .publish(let activity) = event,
              case .power(let payload) = activity.payload
        else { return nil }
        return payload.isCharging
    }

    /// A real Mac reports the plug before it reports charging. The card was
    /// published from the first reading and never heard the second, so it spent
    /// its whole life saying the battery was not charging while it was.
    @Test("Charging starting a moment after the plug reaches the card")
    func chargingAfterConnection() async {
        var clock: TimeInterval = 100
        let source = StubPowerSource(value: power(0.5, charging: false, plugged: false))
        let provider = BatteryProvider(source: source, now: { clock })

        let events = await collect(provider) {
            source.set(power(0.5, charging: false, plugged: true))
            clock += 1
            source.set(power(0.5, charging: true, plugged: true))
        }

        #expect(events.count == 2, "the announcement, then the correction")
        #expect(charging(events[0]) == false)
        #expect(charging(events[1]) == true)
    }

    /// macOS holds at 80% on purpose. Charging stops, the plug stays in, and
    /// the card went on showing the bolt until it timed out.
    @Test("Charging stopping below full reaches the card")
    func chargingPausedWhilePlugged() async {
        var clock: TimeInterval = 100
        let source = StubPowerSource(value: power(0.5, charging: false, plugged: false))
        let provider = BatteryProvider(source: source, now: { clock })

        let events = await collect(provider) {
            source.set(power(0.8, charging: true, plugged: true))
            clock += 2
            source.set(power(0.8, charging: false, plugged: true))
        }

        #expect(events.count == 2)
        #expect(charging(events[0]) == true)
        #expect(charging(events[1]) == false, "held at 80%, and the card says so")
    }

    /// The refresh must not become a way to keep the island open: the card
    /// keeps the deadline it was published with.
    @Test("A refreshed card does not live longer for it")
    func refreshKeepsTheDeadline() async {
        var clock: TimeInterval = 100
        let source = StubPowerSource(value: power(0.5, charging: false, plugged: false))
        let provider = BatteryProvider(source: source, now: { clock })

        let events = await collect(provider) {
            source.set(power(0.5, charging: false, plugged: true))
            clock += 2
            source.set(power(0.5, charging: true, plugged: true))
        }

        guard case .publish(let first) = events[0], case .publish(let second) = events[1] else {
            Issue.record("expected two publishes")
            return
        }
        #expect(first.expiresAfter == BatteryProvider.lifetime)
        #expect(second.expiresAfter == BatteryProvider.lifetime - 2, "two seconds already spent")
        #expect(first.createdAt + first.expiresAfter! == second.createdAt + second.expiresAfter!)
    }

    /// With no card on screen there is nothing to correct, and a charger that
    /// flickers must not start summoning cards of its own.
    @Test("A charger flickering after the card has gone says nothing")
    func flickerAfterExpiryIsSilent() async {
        var clock: TimeInterval = 100
        let source = StubPowerSource(value: power(0.5, charging: false, plugged: false))
        let provider = BatteryProvider(source: source, now: { clock })

        let events = await collect(provider) {
            source.set(power(0.5, charging: true, plugged: true))
            clock += BatteryProvider.lifetime + 1
            source.set(power(0.5, charging: false, plugged: true))
            source.set(power(0.5, charging: true, plugged: true))
        }

        #expect(events.count == 1, "only the plug itself was news")
    }

    /// Unplugging is its own announcement, and must not be mistaken for the
    /// charger changing its mind.
    @Test("Unplugging still announces rather than refreshing")
    func unplugStillAnnounces() async {
        var clock: TimeInterval = 100
        let source = StubPowerSource(value: power(0.5, charging: true, plugged: true))
        let provider = BatteryProvider(source: source, now: { clock })

        let events = await collect(provider) {
            clock += 1
            source.set(power(0.5, charging: false, plugged: false))
        }

        #expect(events.count == 1)
        guard case .publish(let activity) = events[0] else { return }
        #expect(activity.expiresAfter == BatteryProvider.lifetime, "a fresh card, fully alive")
    }
}

@Suite("Power source parsing")
struct PowerSourceParsingTests {

    private func description(
        current: Int = 50,
        max: Int = 100,
        charging: Bool = false,
        state: String = "Battery Power",
        timeToEmpty: Int? = nil,
        timeToFull: Int? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            kIOPSCurrentCapacityKey: current,
            kIOPSMaxCapacityKey: max,
            kIOPSIsChargingKey: charging,
            kIOPSPowerSourceStateKey: state,
        ]
        if let timeToEmpty { result[kIOPSTimeToEmptyKey] = timeToEmpty }
        if let timeToFull { result[kIOPSTimeToFullChargeKey] = timeToFull }
        return result
    }

    @Test("Capacity becomes a fraction")
    func percentage() {
        let snapshot = IOKitPowerSource.parse(description(current: 42, max: 100))
        #expect(snapshot?.percentage == 0.42)
    }

    @Test("A zero maximum cannot divide by zero")
    func zeroMaximumRejected() {
        #expect(IOKitPowerSource.parse(description(current: 10, max: 0)) == nil)
    }

    @Test("The still-calculating sentinel becomes nil, never a negative time")
    func timeSentinel() {
        // IOKit reports -1 while it works the estimate out. A sentinel that
        // reaches the UI turns into "-1 minutes remaining".
        let snapshot = IOKitPowerSource.parse(description(timeToEmpty: -1))
        #expect(snapshot?.timeRemaining == nil)
    }

    @Test("A real estimate is converted from minutes to seconds")
    func timeConverted() {
        let snapshot = IOKitPowerSource.parse(description(timeToEmpty: 90))
        #expect(snapshot?.timeRemaining == 5400)
    }

    @Test("A missing capacity key is rejected rather than assumed")
    func missingKeys() {
        #expect(IOKitPowerSource.parse([:]) == nil)
        #expect(IOKitPowerSource.parse([kIOPSCurrentCapacityKey: 50]) == nil)
    }
}
