import Foundation
import LedgeCore
import LedgeSystem
import Testing
import os

@testable import LedgeProviders

private final class Box: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ s: String) { state.withLock { $0.append(s) } }
    var all: [String] { state.withLock { $0 } }
}

/// The alert provider's lifecycle — the part with no direct coverage before.
/// A fixed instant, outside the main actor so store closures can read it.
private let t0 = Date(timeIntervalSinceReferenceDate: 0)

@Suite("Device alert provider lifecycle", .serialized)
@MainActor
struct DeviceAlertProviderTests {

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-alertprov-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    private static func observation(_ level: Double, at seconds: TimeInterval) -> DeviceObservation {
        let when = t0.addingTimeInterval(seconds)
        return DeviceObservation(
            deviceID: .bluetooth("aa:bb"), name: "AirPods",
            readings: [BatteryReading(component: .left, level: level, observedAt: when)],
            presence: .connected, observedAt: when,
            symbolName: "airpods", isApple: true
        )
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(60))
    }

    /// Decided before anyone was listening, then delivered when a provider
    /// starts. Not delivered twice.
    @Test("A backlog reaches the first provider to start, exactly once")
    func backlogDeliveredOnce() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { t0 })
        await store.record(Self.observation(0.30, at: 0))
        await store.record(Self.observation(0.15, at: 60))
        #expect(await store.queuedAlertCount() == 1)

        let provider = DeviceAlertProvider(store: store, notifier: SilentNotifier(), now: { 0 })
        let events = Box()
        let stream = provider.start()
        let consumer = Task { @MainActor in
            for await event in stream {
                if case .publish = event { events.add("publish") }
            }
        }
        await settle()

        #expect(events.all.count == 1, "the backlog produced \(events.all.count) cards")
        #expect(await store.queuedAlertCount() == 0)

        provider.stop()
        consumer.cancel()
    }

    /// Subscribing takes the backlog out of the store. If the provider has
    /// already stopped, that backlog must go back — not vanish with it.
    @Test("A backlog is returned when the provider stops mid-subscription")
    func backlogReturnedOnRace() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { t0 })
        await store.record(Self.observation(0.30, at: 0))
        await store.record(Self.observation(0.15, at: 60))

        let provider = DeviceAlertProvider(store: store, notifier: SilentNotifier(), now: { 0 })
        _ = provider.start()
        // Stops before the subscription task can reach the main actor.
        provider.stop()
        await settle()

        #expect(
            await store.queuedAlertCount() == 1,
            "the backlog was lost when the provider stopped mid-subscription"
        )
    }

    /// An alert handed to a provider that has already stopped must reach the
    /// next one rather than waiting for a restart that may never come.
    @Test("An alert rejected by a stopped provider reaches the live one")
    func rejectedAlertReachesTheLiveProvider() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { t0 })

        let live = DeviceAlertProvider(store: store, notifier: SilentNotifier(), now: { 0 })
        let events = Box()
        let stream = live.start()
        let consumer = Task { @MainActor in
            for await event in stream {
                if case .publish = event { events.add("publish") }
            }
        }
        await settle()

        // Something a stopped provider could not present.
        await store.requeueAlerts([BatteryAlert(
            ruleID: UUID(), kind: .low, deviceID: .bluetooth("aa:bb"),
            deviceName: "AirPods", component: .left, level: 0.1, threshold: 0.1,
            delivery: .notch, firedAt: t0
        )])
        await settle()

        #expect(
            events.all.count == 1,
            "a requeued alert sat in storage while a provider was listening"
        )
        #expect(await store.queuedAlertCount() == 0)

        live.stop()
        consumer.cancel()
    }

    @Test("Stopping and starting does not duplicate a delivered alert")
    func restartDoesNotDuplicate() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { t0 })
        let events = Box()

        let first = DeviceAlertProvider(store: store, notifier: SilentNotifier(), now: { 0 })
        let s1 = first.start()
        let c1 = Task { @MainActor in
            for await e in s1 { if case .publish = e { events.add("first") } }
        }
        await settle()
        await store.record(Self.observation(0.30, at: 0))
        await store.record(Self.observation(0.15, at: 60))
        await settle()
        #expect(events.all.count == 1)

        first.stop()
        c1.cancel()
        await settle()

        let second = DeviceAlertProvider(store: store, notifier: SilentNotifier(), now: { 0 })
        let s2 = second.start()
        let c2 = Task { @MainActor in
            for await e in s2 { if case .publish = e { events.add("second") } }
        }
        await settle()

        #expect(
            events.all.filter { $0 == "second" }.isEmpty,
            "restarting re-presented an alert that had already been shown"
        )
        second.stop()
        c2.cancel()
    }

    /// With the provider switched off, decisions must not accumulate for ever.
    @Test("The pending queue is bounded and deduplicated")
    func pendingQueueIsBounded() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { t0 })
        let rule = UUID()

        // Far more alerts than the ceiling, all for the same rule.
        for step in 0..<200 {
            await store.requeueAlerts([BatteryAlert(
                ruleID: rule, kind: .low, deviceID: .bluetooth("aa:bb"),
                deviceName: "AirPods", component: .left,
                level: 0.2 - Double(step) / 1000, threshold: 0.2,
                delivery: .notch, firedAt: t0
            )])
        }
        let sameRule = await store.queuedAlertCount()
        #expect(sameRule == 1, "the same rule queued \(sameRule) pending alerts")

        // Distinct rules are bounded by the ceiling.
        for _ in 0..<200 {
            await store.requeueAlerts([BatteryAlert(
                ruleID: UUID(), kind: .low, deviceID: .bluetooth("aa:bb"),
                deviceName: "AirPods", component: .left, level: 0.1, threshold: 0.1,
                delivery: .notch, firedAt: t0
            )])
        }
        let queued = await store.queuedAlertCount()
        #expect(
            queued <= DeviceCatalogueStore.maximumPendingAlerts,
            "\(queued) pending alerts, past the ceiling"
        )
    }

    @Test("An alert older than the pending lifetime is not presented later")
    func stalePendingAlertsAreDropped() async {
        let clock = OSAllocatedUnfairLock(initialState: t0)
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { clock.withLock { $0 } })

        await store.requeueAlerts([BatteryAlert(
            ruleID: UUID(), kind: .low, deviceID: .bluetooth("aa:bb"),
            deviceName: "AirPods", component: .left, level: 0.1, threshold: 0.1,
            delivery: .notch, firedAt: t0
        )])
        #expect(await store.queuedAlertCount() == 1)

        // An hour later, a second alert arrives and ages the first out.
        clock.withLock { $0 = t0.addingTimeInterval(3600) }
        await store.requeueAlerts([BatteryAlert(
            ruleID: UUID(), kind: .low, deviceID: .bluetooth("cc:dd"),
            deviceName: "Mouse", component: .main, level: 0.1, threshold: 0.1,
            delivery: .notch, firedAt: t0.addingTimeInterval(3600)
        )])
        #expect(
            await store.queuedAlertCount() == 1,
            "an alert from an hour ago was still waiting to be presented"
        )
    }

    /// A notch-only rule must never touch notification authorisation.
    @Test("A notch-only alert asks for no notification permission")
    func notchOnlyDoesNotAskPermission() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { t0 })
        let notifier = RecordingNotifier()
        let provider = DeviceAlertProvider(store: store, notifier: notifier, now: { 0 })
        let stream = provider.start()
        let consumer = Task { @MainActor in for await _ in stream {} }
        await settle()

        await store.record(Self.observation(0.30, at: 0))
        await store.record(Self.observation(0.15, at: 60))
        await settle()

        #expect(notifier.asked == 0, "a notch-only alert asked for notification permission")
        #expect(notifier.delivered == 0)

        provider.stop()
        consumer.cancel()
    }
}

/// Does nothing, and never asks for anything.
struct SilentNotifier: AlertNotifying {
    func requestAuthorization() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func deliver(title: String, body: String) async {}
}

/// Counts what was asked of it.
final class RecordingNotifier: AlertNotifying, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (asked: 0, delivered: 0))
    var asked: Int { state.withLock { $0.asked } }
    var delivered: Int { state.withLock { $0.delivered } }

    func requestAuthorization() async -> Bool {
        state.withLock { $0.asked += 1 }
        return false
    }
    func isAuthorized() async -> Bool { false }
    func deliver(title: String, body: String) async {
        state.withLock { $0.delivered += 1 }
    }
}

/// The provider's own rejection path — the one the store-level token tests
/// never touched.
@Suite("Device alert provider rejection path", .serialized)
@MainActor
struct DeviceAlertProviderRejectionTests {

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-reject-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    private func settle() async {
        for _ in 0..<60 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(80))
    }

    // NOTE: there is deliberately no test here asserting that a provider
    // rejection names its subscription.
    //
    // Two attempts at one were written and both were vacuous: the rejection
    // path needs the delivery closure to run with a superseded session *while*
    // the store still holds that consumer, and that window cannot be scheduled
    // from a test — `stop()`'s unsubscribe runs on the store's own executor and
    // may land before or after anything the test injects. Both attempts
    // therefore passed with the defect deliberately reintroduced, which is
    // worse than having no test at all.
    //
    // What is covered instead: the store's behaviour given a token
    // (`refusedAlertIsNotBounced`, `refusedAlertReachesNewConsumer`), and the
    // invariant below that no alert is lost or duplicated across a stop. That
    // the provider passes an immutable token minted before registration is
    // established by reading it, not by a test.

    @Test("An alert rejected during stop is neither lost nor duplicated")
    func rejectionDuringStopQueues() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { t0 })
        let presented = Box()

        let provider = DeviceAlertProvider(store: store, notifier: SilentNotifier(), now: { 0 })
        let stream = provider.start()
        let consumer = Task { @MainActor in
            for await event in stream {
                if case .publish = event { presented.add("publish") }
            }
        }
        await settle()

        // Decide an alert and stop in the same turn, so the delivery is in
        // flight while the provider is going away.
        let alert = BatteryAlert(
            ruleID: UUID(), kind: .low, deviceID: .bluetooth("aa:bb"),
            deviceName: "AirPods", component: .left, level: 0.1, threshold: 0.1,
            delivery: .notch, firedAt: t0
        )
        await store.requeueAlerts([alert])
        provider.stop()
        await settle()

        // Either it was presented before the stop landed, or it is queued for
        // the next provider. What must never happen is that it is lost — or
        // that it bounces between the two.
        let queued = await store.queuedAlertCount()
        #expect(
            presented.all.count + queued == 1,
            "presented \(presented.all.count), queued \(queued) — the alert was lost or duplicated"
        )
        consumer.cancel()
    }

    /// With the provider gone, a late rejection must leave the alert for the
    /// next one rather than vanishing.
    @Test("A rejection after stop leaves the alert queued for the next provider")
    func rejectionAfterStopIsRecoverable() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { t0 })

        let first = DeviceAlertProvider(store: store, notifier: SilentNotifier(), now: { 0 })
        let s1 = first.start()
        let c1 = Task { @MainActor in for await _ in s1 {} }
        await settle()
        first.stop()
        await settle()
        c1.cancel()

        await store.requeueAlerts([BatteryAlert(
            ruleID: UUID(), kind: .low, deviceID: .bluetooth("aa:bb"),
            deviceName: "AirPods", component: .left, level: 0.1, threshold: 0.1,
            delivery: .notch, firedAt: t0
        )])

        #expect(
            await store.queuedAlertCount() == 1,
            "the alert was neither queued nor delivered"
        )

        // The next provider gets it.
        let presented = Box()
        let second = DeviceAlertProvider(store: store, notifier: SilentNotifier(), now: { 0 })
        let s2 = second.start()
        let c2 = Task { @MainActor in
            for await e in s2 { if case .publish = e { presented.add("publish") } }
        }
        await settle()
        #expect(presented.all.count == 1, "the queued alert never reached the next provider")

        second.stop()
        c2.cancel()
    }
}
