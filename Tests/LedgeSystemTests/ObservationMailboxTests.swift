import Foundation
import LedgeCore
import Testing
import os

@testable import LedgeSystem

/// The mailbox exists to stop a steady stream of advertisements becoming a
/// steady stream of catalogue work. So these count *forwards* — the thing the
/// earlier "repeats are inert" test never measured, which is why the loop went
/// unnoticed.
@Suite("Observation mailbox", .serialized)
struct ObservationMailboxTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private final class Counter: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (count: 0, peak: 0, live: 0))
        var count: Int { state.withLock { $0.count } }
        var peak: Int { state.withLock { $0.peak } }

        func enter() {
            state.withLock { s in
                s.count += 1
                s.live += 1
                s.peak = max(s.peak, s.live)
            }
        }
        func leave() { state.withLock { $0.live -= 1 } }
    }

    private static func observation(
        _ level: Double,
        id: DeviceIdentity = .peripheral(UUID(uuidString: "1B4E28BA-2FA1-11D2-883F-000000000001")!),
        name: String = "AirPods Pro",
        charging: ChargingState = .notCharging,
        presence: DevicePresence = .unknown,
        at seconds: TimeInterval
    ) -> DeviceObservation {
        let when = t0.addingTimeInterval(seconds)
        return DeviceObservation(
            deviceID: id, name: name,
            readings: [BatteryReading(
                component: .left, level: level, charging: charging, observedAt: when
            )],
            presence: presence, observedAt: when
        )
    }

    private func settle(_ mailbox: ObservationMailbox) async {
        for _ in 0..<200 where mailbox.isDraining || mailbox.pendingCount > 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    /// An attentive scan delivers advertisements many times a second. Before
    /// the mailbox, each was a task and each reached the catalogue.
    @Test("A stream of unchanged advertisements forwards once, not per advert")
    func unchangedStreamForwardsOnce() async {
        let counter = Counter()
        let mailbox = ObservationMailbox(deliver: { _ in
            counter.enter()
            counter.leave()
        })

        // Ten a second for a minute, all identical.
        for tick in 0..<600 {
            mailbox.submit(Self.observation(0.80, at: Double(tick) / 10))
        }
        await settle(mailbox)

        // One for the first sighting, plus a heartbeat every two minutes —
        // and a minute of adverts does not reach the second heartbeat.
        #expect(counter.count == 1, "600 identical adverts forwarded \(counter.count) times")
        #expect(counter.peak == 1, "\(counter.peak) forwards ran at once")
    }

    @Test("A change in level forwards immediately")
    func changesForwardAtOnce() async {
        let counter = Counter()
        let mailbox = ObservationMailbox(deliver: { _ in counter.enter(); counter.leave() })

        mailbox.submit(Self.observation(0.80, at: 0))
        await settle(mailbox)
        mailbox.submit(Self.observation(0.60, at: 1))
        await settle(mailbox)

        #expect(counter.count == 2)
    }

    @Test("A change in charging, presence or name forwards even at the same level")
    func stateChangesForward() async {
        for (label, second) in [
            ("charging", Self.observation(0.80, charging: .charging, at: 1)),
            ("presence", Self.observation(0.80, presence: .connected, at: 1)),
            ("name", Self.observation(0.80, name: "Ege's AirPods", at: 1)),
        ] {
            let counter = Counter()
            let mailbox = ObservationMailbox(deliver: { _ in counter.enter(); counter.leave() })
            mailbox.submit(Self.observation(0.80, at: 0))
            await settle(mailbox)
            mailbox.submit(second)
            await settle(mailbox)
            #expect(counter.count == 2, "a change of \(label) was swallowed")
        }
    }

    @Test("An unchanged device is forwarded again at the heartbeat, so it does not look stale")
    func heartbeatKeepsLastSeenMoving() async {
        let counter = Counter()
        let mailbox = ObservationMailbox(deliver: { _ in counter.enter(); counter.leave() })

        mailbox.submit(Self.observation(0.80, at: 0))
        await settle(mailbox)
        mailbox.submit(Self.observation(0.80, at: ObservationMailbox.heartbeat - 1))
        await settle(mailbox)
        #expect(counter.count == 1, "the heartbeat fired early")

        mailbox.submit(Self.observation(0.80, at: ObservationMailbox.heartbeat + 1))
        await settle(mailbox)
        #expect(counter.count == 2, "an unchanged device never refreshed its last-seen")
    }

    @Test("Devices are coalesced separately")
    func devicesAreIndependent() async {
        let counter = Counter()
        let mailbox = ObservationMailbox(deliver: { _ in counter.enter(); counter.leave() })
        let a = DeviceIdentity.bluetooth("aa")
        let b = DeviceIdentity.bluetooth("bb")

        for tick in 0..<50 {
            mailbox.submit(Self.observation(0.8, id: a, at: Double(tick)))
            mailbox.submit(Self.observation(0.8, id: b, at: Double(tick)))
        }
        await settle(mailbox)
        #expect(counter.count == 2, "two devices forwarded \(counter.count) times")
    }

    @Test("Invalidating drops what is queued and disowns the drain")
    func invalidateStopsEverything() async {
        let counter = Counter()
        let mailbox = ObservationMailbox(deliver: { _ in
            counter.enter()
            try? await Task.sleep(for: .milliseconds(30))
            counter.leave()
        })

        for tick in 0..<20 {
            mailbox.submit(Self.observation(Double(tick) / 20, at: Double(tick)))
        }
        mailbox.invalidate()
        await settle(mailbox)

        #expect(mailbox.pendingCount == 0, "queued observations survived a stop")
        #expect(counter.count <= 2, "\(counter.count) forwards continued after invalidation")
    }

    /// A drain from a superseded generation must not clear `isDraining` for
    /// the generation that replaced it — that let two drains run at once, and
    /// observations arrive out of order.
    @Test("An obsolete drain cannot let a second drain start alongside the new one")
    func obsoleteDrainCannotReleaseTheLatch() async {
        let concurrent = OSAllocatedUnfairLock(initialState: (live: 0, peak: 0))
        let mailbox = ObservationMailbox(deliver: { _ in
            concurrent.withLock { s in
                s.live += 1
                s.peak = max(s.peak, s.live)
            }
            try? await Task.sleep(for: .milliseconds(15))
            concurrent.withLock { $0.live -= 1 }
        })

        // Start a drain, invalidate mid-flight, then immediately start another
        // — repeatedly, so the old drain resumes while the new one is running.
        for round in 0..<25 {
            mailbox.submit(Self.observation(
                Double(round) / 100, id: .bluetooth("aa"), at: Double(round) * 10
            ))
            try? await Task.sleep(for: .milliseconds(2))
            mailbox.invalidate()
            mailbox.submit(Self.observation(
                Double(round) / 100 + 0.5, id: .bluetooth("bb"), at: Double(round) * 10
            ))
        }
        try? await Task.sleep(for: .milliseconds(300))

        #expect(
            concurrent.withLock { $0.peak } == 1,
            "\(concurrent.withLock { $0.peak }) drains ran at once after invalidation"
        )
    }

    /// The whole point, measured end to end: a device sitting in range must
    /// not keep the catalogue writing.
    @Test("A device in range does not keep the catalogue working")
    func inRangeDeviceIsQuiet() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-mailbox-\(UUID().uuidString)")
            .appendingPathComponent("devices.json")
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 })
        let mailbox = ObservationMailbox(store: store)

        // Five minutes of a duty-cycled scanner, unchanged.
        for tick in 0..<50 {
            mailbox.submit(Self.observation(0.80, at: Double(tick) * 6))
        }
        await settle(mailbox)

        let history = await store.history(for: Self.observation(0.8, at: 0).deviceID)
        #expect(
            history.count <= 3,
            "an unchanging device in range wrote \(history.count) history rows"
        )
        #expect(await store.queuedAlertCount() == 0)
    }
}

/// The mailbox must not grow for a device whose identifier rotates.
@Suite("Observation mailbox bookkeeping", .serialized)
struct ObservationMailboxBookkeepingTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func advert(_ level: Double, at seconds: TimeInterval) -> DeviceObservation {
        let when = t0.addingTimeInterval(seconds)
        return DeviceObservation(
            deviceID: .peripheral(UUID()),       // rotates every time
            name: "AirPods Pro",
            readings: [BatteryReading(component: .left, level: level, observedAt: when)],
            presence: .unknown, observedAt: when,
            canonicalHint: "airpods-model-3616"
        )
    }

    /// The catalogue was fixed to canonicalise and the mailbox was still
    /// indexing by the raw UUID, so the leak moved rather than went.
    @Test("Rotation does not grow the mailbox's bookkeeping")
    func rotationDoesNotGrowBookkeeping() async {
        let mailbox = ObservationMailbox(deliver: { _ in })
        for step in 0..<200 {
            mailbox.submit(Self.advert(0.8, at: Double(step) * 300))
        }
        for _ in 0..<100 where mailbox.isDraining { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(
            mailbox.trackedDeviceCount == 1,
            "200 rotations left \(mailbox.trackedDeviceCount) tracked devices"
        )
    }

    @Test("Rotation still coalesces, because the key is canonical")
    func rotationCoalesces() async {
        let forwards = OSAllocatedUnfairLock(initialState: 0)
        let mailbox = ObservationMailbox(deliver: { _ in forwards.withLock { $0 += 1 } })

        // Same level, new identifier each time, inside one heartbeat window.
        for step in 0..<20 {
            mailbox.submit(Self.advert(0.8, at: Double(step)))
        }
        for _ in 0..<100 where mailbox.isDraining { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(40))

        #expect(
            forwards.withLock { $0 } == 1,
            "rotation defeated coalescing: \(forwards.withLock { $0 }) forwards"
        )
    }
}

/// Forgetting a device must clear what the mailbox remembers about it.
@Suite("Observation mailbox forgetting", .serialized)
struct ObservationMailboxForgetTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private static let id = DeviceIdentity.bluetooth("aa:bb")

    private static func observation(_ level: Double, at seconds: TimeInterval) -> DeviceObservation {
        let when = t0.addingTimeInterval(seconds)
        return DeviceObservation(
            deviceID: id, name: "Mouse",
            readings: [BatteryReading(component: .main, level: level, observedAt: when)],
            presence: .connected, observedAt: when
        )
    }

    private func settle(_ mailbox: ObservationMailbox) async {
        for _ in 0..<200 where mailbox.isDraining || mailbox.pendingCount > 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test("A forgotten device is reported again at once, not after the heartbeat")
    func forgettingAllowsImmediateReport() async {
        let forwards = OSAllocatedUnfairLock(initialState: 0)
        let mailbox = ObservationMailbox(deliver: { _ in forwards.withLock { $0 += 1 } })

        mailbox.submit(Self.observation(0.5, at: 0))
        await settle(mailbox)
        #expect(forwards.withLock { $0 } == 1)

        // Unchanged, so ordinarily coalesced away.
        mailbox.submit(Self.observation(0.5, at: 10))
        await settle(mailbox)
        #expect(forwards.withLock { $0 } == 1, "an unchanged reading was forwarded twice")

        // The user forgets the device; the next sighting is news again.
        mailbox.forget(Self.id)
        mailbox.submit(Self.observation(0.5, at: 20))
        await settle(mailbox)
        #expect(
            forwards.withLock { $0 } == 2,
            "a forgotten device had to wait out the heartbeat to reappear"
        )
        #expect(mailbox.trackedDeviceCount == 1)
    }
}

/// Quitting is an ordered barrier, not a flush. A late observation must either
/// reach the catalogue before it is written to disk or never be accepted at
/// all — an alert latch lost in that window says the same thing again after
/// the next launch, which is the one thing the latch exists to prevent.
@Suite("Closing the mailbox")
struct MailboxShutdownTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func observation(
        _ address: String,
        level: Double = 0.5,
        at seconds: TimeInterval = 0
    ) -> DeviceObservation {
        DeviceObservation(
            deviceID: .bluetooth(address), name: "AirPods",
            readings: [BatteryReading(
                component: .left, level: level,
                observedAt: t0.addingTimeInterval(seconds)
            )],
            presence: .connected, observedAt: t0.addingTimeInterval(seconds),
            cause: .connectionEvent
        )
    }

    /// Order, not timing: the log says which finished first, so the test
    /// cannot pass by being lucky about scheduling.
    @Test("Close waits for the delivery that is already in flight")
    func closeAwaitsTheDrain() async {
        let held = AsyncGate()
        let log = EventLog()
        let mailbox = ObservationMailbox(deliver: { _ in
            await held.wait()
            await log.append("delivered")
        })

        mailbox.submit(Self.observation("aa:aa"))
        // Let the drain reach the delivery and block there.
        await untilDraining(mailbox)

        let closing = Task {
            await mailbox.close()
            await log.append("closed")
        }
        // Give a close that does not wait every chance to finish early.
        await briefly()
        await held.open()
        await closing.value

        let order = await log.events
        #expect(
            order == ["delivered", "closed"],
            "close returned before the delivery landed: \(order)"
        )
        #expect(mailbox.isDraining == false)
    }

    @Test("A closed mailbox accepts nothing new")
    func closedMailboxRefusesWork() async {
        let delivered = DeliveryCount()
        let mailbox = ObservationMailbox(deliver: { _ in await delivered.increment() })
        await mailbox.close()

        mailbox.submit(Self.observation("bb:bb"))
        // Nothing to wait for, but give a stray task every chance to run.
        await briefly()
        #expect(await delivered.value == 0)
        #expect(mailbox.pendingCount == 0)
    }

    @Test("Closing twice is not an error and does not hang")
    func closeIsIdempotent() async {
        let mailbox = ObservationMailbox(deliver: { _ in })
        await mailbox.close()
        await mailbox.close()
        #expect(mailbox.isClosed)
    }

    /// Everything accepted before the close has to land: an observation may
    /// carry the history sample or the alert latch that stops the same alert
    /// being raised again after the next launch.
    @Test("Work accepted before the close is delivered, not discarded")
    func acceptedWorkIsDelivered() async {
        let delivered = DeliveryCount()
        let mailbox = ObservationMailbox(deliver: { _ in await delivered.increment() })
        mailbox.submit(Self.observation("cc:cc"))
        await mailbox.close()
        let landed = await delivered.value
        #expect(landed == 1, "an accepted observation was thrown away at shutdown")
    }

    /// One delivery held in flight and a second observation waiting behind
    /// it: both must land *before* close returns. The two deliveries have no
    /// order between them — the queue is keyed by device and coalesces, and
    /// never promised one — so what is asserted is the barrier itself.
    @Test("A queued observation behind one in flight still lands")
    func queuedWorkBehindAnInFlightDeliveryLands() async {
        let held = AsyncGate()
        let log = EventLog()
        let mailbox = ObservationMailbox(deliver: { observation in
            await log.append("started \(observation.deviceID.value)")
            if observation.deviceID == .bluetooth("first") { await held.wait() }
            await log.append(observation.deviceID.value)
        })

        mailbox.submit(Self.observation("first"))
        // Wait for the delivery to really be in flight, not merely for the
        // flag that says one is about to be: the queue is a dictionary, and a
        // second submit landing first would otherwise be delivered first.
        await until { await log.events.contains("started first") }
        mailbox.submit(Self.observation("second", level: 0.1, at: 300))

        let closing = Task {
            await mailbox.close()
            await log.append("closed")
        }
        await briefly()
        await held.open()
        await closing.value

        let order = await log.events
        #expect(order.last == "closed", "something landed after the barrier returned: \(order)")
        #expect(order.contains("first"), "the delivery in flight did not land")
        #expect(
            order.contains("second"),
            "the observation queued before the close was thrown away: \(order)"
        )
        #expect(mailbox.pendingCount == 0)
    }

    /// A reset mid-session is a different thing: that one discards on purpose,
    /// because the work belongs to a provider run that is over.
    @Test("A mid-session reset still discards")
    func invalidateStillDiscards() async {
        let held = AsyncGate()
        let mailbox = ObservationMailbox(deliver: { _ in await held.wait() })
        mailbox.submit(Self.observation("dd:dd"))
        await untilDraining(mailbox)
        mailbox.submit(Self.observation("ee:ee", level: 0.2, at: 300))
        mailbox.invalidate()
        #expect(mailbox.pendingCount == 0, "the queued work was kept by a reset")
        await held.open()
    }

    /// The bookkeeping exists to tell news from noise for the devices that are
    /// around, not to remember every device the Mac has ever met.
    @Test("The forwarded history stays bounded")
    func bookkeepingIsBounded() async {
        let mailbox = ObservationMailbox(deliver: { _ in })
        for index in 0..<(ObservationMailbox.trackedDeviceLimit + 40) {
            mailbox.submit(Self.observation("device-\(index)", at: Double(index)))
            // Let each drain turn complete, so these are forwarded rather than
            // coalesced into one pending entry.
            for _ in 0..<500 where mailbox.isDraining {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        #expect(mailbox.trackedDeviceCount <= ObservationMailbox.trackedDeviceLimit)
    }
}

/// A gate a delivery can be held at, so a test can watch the barrier wait.
private actor AsyncGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let resume = waiting
        waiting.removeAll()
        for continuation in resume { continuation.resume() }
    }
}

/// Counts deliveries from whatever context they arrive on.
private actor DeliveryCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// What happened, in the order it happened.
private actor EventLog {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

/// Waits for the mailbox to own its queue, without spinning: a hot
/// `Task.yield()` loop starves everything else on the runtime, which showed up
/// as unrelated timing tests failing under a full suite run.
private func untilDraining(_ mailbox: ObservationMailbox) async {
    for _ in 0..<2_000 where !mailbox.isDraining {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Long enough for anything already scheduled to run, short enough to be free.
private func briefly() async {
    try? await Task.sleep(for: .milliseconds(20))
}

/// Waits for a condition rather than for a guessed interval.
private func until(_ condition: @escaping () async -> Bool) async {
    for _ in 0..<2_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Provider liveness goes through the same ordered path observations take. One
/// unstructured task per update let a start overtake the stop that followed
/// it, which left This Mac marked live after its provider had gone — and a
/// record claiming a live reading from a provider that is not running is the
/// staleness the liveness flag exists to prevent.
@Suite("Ordered provider liveness")
struct LivenessOrderingTests {

    private func mailbox(
        onLiveness: @escaping @Sendable (Bool, DeviceIdentity.Source) async -> Void
    ) -> ObservationMailbox {
        let mailbox = ObservationMailbox(deliver: { _ in })
        mailbox.setLivenessHandlerForTesting(onLiveness)
        return mailbox
    }

    /// The gated case: the earlier `live = true` delivery is held, and
    /// `live = false` is queued behind it. Whatever the scheduling, the last
    /// state submitted is the state the store ends on.
    @Test("A delayed start cannot overtake the stop that followed it")
    func stopWinsOverDelayedStart() async {
        let held = AsyncGate()
        let log = EventLog()
        let mailbox = mailbox(onLiveness: { live, _ in
            if live { await held.wait() }
            await log.append(live ? "live" : "stopped")
        })

        mailbox.sourceBecame(live: true, for: DeviceIdentity.Source.thisMac)
        // Let the first delivery reach the gate before the stop is queued.
        await briefly()
        mailbox.sourceBecame(live: false, for: DeviceIdentity.Source.thisMac)
        await held.open()
        await mailbox.close()

        let events = await log.events
        #expect(
            events.last == "stopped",
            "a start overtook the stop that followed it: \(events)"
        )
    }

    /// Coalesced per source: a provider toggled repeatedly leaves one update,
    /// not a queue of them.
    @Test("Repeated updates for one source coalesce")
    func updatesCoalesce() async {
        let log = EventLog()
        let mailbox = ObservationMailbox(deliver: { _ in })
        mailbox.setLivenessHandlerForTesting({ live, _ in
            await log.append(live ? "live" : "stopped")
        })

        // Twenty toggles, ending on a start: that is the state the store must
        // settle on, and it should not take twenty deliveries to get there.
        for index in 0..<21 {
            mailbox.sourceBecame(live: index % 2 == 0, for: DeviceIdentity.Source.thisMac)
        }
        await mailbox.close()
        let events = await log.events
        #expect(events.count <= 2, "\(events.count) deliveries for twenty-one toggles")
        #expect(events.last == "live", "the last state submitted did not win")
    }

    /// And the barrier waits for it: liveness accepted before a close must
    /// reach the store, like any other accepted work.
    @Test("Close delivers liveness accepted before it")
    func closeDeliversLiveness() async {
        let log = EventLog()
        let mailbox = ObservationMailbox(deliver: { _ in })
        mailbox.setLivenessHandlerForTesting({ live, _ in
            await log.append(live ? "live" : "stopped")
        })
        mailbox.sourceBecame(live: false, for: DeviceIdentity.Source.thisMac)
        await mailbox.close()
        let delivered = await log.events
        #expect(delivered == ["stopped"], "a liveness update was dropped at shutdown")
        #expect(mailbox.pendingLivenessCount == 0)
    }

    @Test("A closed mailbox accepts no more liveness")
    func closedMailboxRefusesLiveness() async {
        let log = EventLog()
        let mailbox = ObservationMailbox(deliver: { _ in })
        mailbox.setLivenessHandlerForTesting({ live, _ in
            await log.append(live ? "live" : "stopped")
        })
        await mailbox.close()
        mailbox.sourceBecame(live: true, for: DeviceIdentity.Source.thisMac)
        await briefly()
        let afterClose = await log.events
        #expect(afterClose.isEmpty)
    }
}
