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
