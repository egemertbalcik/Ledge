import Foundation
import LedgeCore
import Testing
import os

@testable import LedgeSystem

/// The store, against injected URLs and an injected clock. Never the real
/// Application Support directory, never real hardware.
/// Collects what a consumer was handed.
final class Received: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [BatteryAlert]())
    func append(_ alerts: [BatteryAlert]) { lock.withLock { $0.append(contentsOf: alerts) } }
    var count: Int { lock.withLock { $0.count } }
    var first: BatteryAlert? { lock.withLock { $0.first } }
}

@Suite("Device catalogue store", .serialized)
struct DeviceCatalogueStoreTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-devices-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    private static func observation(
        _ level: Double,
        component: BatteryComponent = .left,
        id: DeviceIdentity = .bluetooth("aa:bb"),
        name: String = "AirPods",
        at seconds: TimeInterval = 0,
        charging: ChargingState = .unknown,
        connected: Bool = true
    ) -> DeviceObservation {
        let when = t0.addingTimeInterval(seconds)
        return DeviceObservation(
            deviceID: id, name: name,
            readings: [BatteryReading(
                component: component, level: level, charging: charging, observedAt: when
            )],
            presence: connected ? .connected : .disconnected, observedAt: when
        )
    }

    @Test("A device is remembered, and a rename is not a new device")
    func recordsAndRenames() async {
        let url = Self.tempURL()
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 })

        await store.record(Self.observation(0.9, name: "AirPods"))
        await store.record(Self.observation(0.8, name: "Ege's AirPods", at: 3600))

        let catalogue = await store.snapshot()
        #expect(catalogue.devices.count == 1, "a rename created a second device")
        #expect(catalogue.devices.first?.name == "Ege's AirPods")
    }

    @Test("Two devices with the same name stay two devices")
    func sameNameStaysSeparate() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.9, id: .bluetooth("aa:aa"), name: "AirPods Pro"))
        await store.record(Self.observation(0.4, id: .bluetooth("bb:bb"), name: "AirPods Pro"))

        let catalogue = await store.snapshot()
        #expect(catalogue.devices.count == 2, "two devices were merged because their names matched")
    }

    @Test("Writes are atomic and survive a reload")
    func writesRoundTrip() async {
        let url = Self.tempURL()
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 })
        await store.record(Self.observation(0.7))
        await store.flush()

        #expect(FileManager.default.fileExists(atPath: url.path))

        let reopened = DeviceCatalogueStore(url: url, now: { Self.t0 })
        let catalogue = await reopened.snapshot()
        #expect(catalogue.devices.count == 1)
        #expect(catalogue.version == DeviceCatalogue.currentVersion)
    }

    @Test("A corrupt file is quarantined and launch continues")
    func corruptStoreRecovers() async throws {
        let url = Self.tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("this is not json".utf8).write(to: url)

        let store = DeviceCatalogueStore(url: url, now: { Self.t0 })
        let catalogue = await store.snapshot()
        #expect(catalogue.devices.isEmpty, "a corrupt file should yield an empty catalogue, not a crash")

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        )
        #expect(
            siblings.contains { $0.contains("corrupt") },
            "the unreadable file was deleted rather than kept for salvage"
        )
    }

    @Test("A catalogue from a newer version is refused, not overwritten blindly")
    func futureVersionIsRefused() async throws {
        let url = Self.tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var future = DeviceCatalogue()
        future.version = DeviceCatalogue.currentVersion + 5
        try JSONEncoder().encode(future).write(to: url)

        let store = DeviceCatalogueStore(url: url, now: { Self.t0 })
        let catalogue = await store.snapshot()
        #expect(catalogue.version == DeviceCatalogue.currentVersion)
        #expect(catalogue.devices.isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        )
        #expect(siblings.contains { $0.contains("future-version") })
    }

    @Test("Migration accepts the current version unchanged")
    func migrationKeepsCurrent() {
        var stored = DeviceCatalogue()
        stored.devices = [DeviceRecord(
            id: .bluetooth("aa:bb"), name: "AirPods", firstSeen: Self.t0, lastSeen: Self.t0
        )]
        let migrated = DeviceCatalogue.migrated(stored)
        #expect(migrated?.devices.count == 1)
        #expect(migrated?.version == DeviceCatalogue.currentVersion)
    }

    @Test("History coalesces repeats and keeps real changes")
    func historyCoalesces() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.90, at: 0))
        for tick in 1...30 {
            await store.record(Self.observation(0.90, at: Double(tick) * 5))
        }
        await store.record(Self.observation(0.60, at: 200))

        let samples = await store.history(for: .bluetooth("aa:bb"))
        #expect(samples.count == 2, "stored \(samples.count) samples for two distinct readings")
    }

    @Test("Maintenance prunes by age, and only when asked")
    func maintenancePrunes() async {
        let old = Self.t0
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { old })
        await store.record(Self.observation(0.9, at: 0))

        // Far in the future, so everything stored is past the retention age.
        let later = DeviceCatalogueStore(
            url: Self.tempURL(),
            now: { Self.t0.addingTimeInterval(BatteryHistory.maximumAge * 2) }
        )
        await later.record(Self.observation(0.9, at: 0))
        await later.runMaintenance()
        let samples = await later.history(for: .bluetooth("aa:bb"))
        #expect(samples.isEmpty, "samples past the retention age survived maintenance")
    }

    /// An alert is queued *or* handed to a consumer, never both. The earlier
    /// shape did both, so every delivered alert stayed in memory and was
    /// delivered a second time the next time a provider started.
    @Test("Subscribing takes the backlog atomically, and it is not left behind")
    func subscriptionTakesBacklogOnce() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.30, at: 0))
        await store.record(Self.observation(0.15, at: 60))

        #expect(await store.queuedAlertCount() == 1)

        let received = Received()
        let (token, backlog) = await store.subscribeToAlerts { alerts in
            received.append(alerts)
        }
        #expect(backlog.count == 1)
        #expect(await store.queuedAlertCount() == 0, "the backlog was handed over and also kept")

        await store.unsubscribeFromAlerts(token)
        let (_, second) = await store.subscribeToAlerts { _ in }
        #expect(second.isEmpty, "a delivered alert was handed out again on the next subscription")
    }

    @Test("A live consumer receives alerts and nothing is queued")
    func liveConsumerGetsAlerts() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let received = Received()
        _ = await store.subscribeToAlerts { alerts in received.append(alerts) }

        await store.record(Self.observation(0.30, at: 0))
        await store.record(Self.observation(0.15, at: 60))

        #expect(received.count == 1)
        #expect(await store.queuedAlertCount() == 0, "an alert was delivered and queued")
    }

    @Test("A stale token cannot unsubscribe a newer consumer")
    func staleTokenCannotUnsubscribe() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let (old, _) = await store.subscribeToAlerts { _ in }
        let received = Received()
        _ = await store.subscribeToAlerts { alerts in received.append(alerts) }

        // The old provider stops, late.
        await store.unsubscribeFromAlerts(old)

        await store.record(Self.observation(0.30, at: 0))
        await store.record(Self.observation(0.15, at: 60))
        #expect(received.count == 1, "a stopped provider's token silenced the live one")
    }

    /// The same earbuds can hold two records — one per source — and there is
    /// no dependable identifier relating them. They stay separate; the alert
    /// does not fire twice.
    @Test("Two records for the same-named device raise one alert, not two")
    func duplicateRecordsAlertOnce() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let received = Received()
        _ = await store.subscribeToAlerts { alerts in received.append(alerts) }

        let byAddress = DeviceIdentity.bluetooth("aa:bb")
        let byPeripheral = DeviceIdentity.peripheral(UUID())

        for id in [byAddress, byPeripheral] {
            await store.record(DeviceObservation(
                deviceID: id, name: "AirPods Pro",
                readings: [BatteryReading(component: .left, level: 0.30, observedAt: Self.t0)],
                presence: .connected, observedAt: Self.t0
            ))
        }
        for id in [byAddress, byPeripheral] {
            await store.record(DeviceObservation(
                deviceID: id, name: "AirPods Pro",
                readings: [BatteryReading(
                    component: .left, level: 0.12,
                    observedAt: Self.t0.addingTimeInterval(60)
                )],
                presence: .connected, observedAt: Self.t0.addingTimeInterval(60)
            ))
        }

        #expect(received.count == 1, "the same dip alerted \(received.count) times across two records")
        #expect(await store.snapshot().devices.count == 2, "the records were merged on a matching name")
    }

    @Test("A reconnect after an alert does not produce another")
    func reconnectDoesNotRepeat() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.30, at: 0))
        await store.record(Self.observation(0.15, at: 60))
        #expect(await store.queuedAlertCount() == 1)

        await store.record(Self.observation(0.15, at: 120, connected: false))
        await store.record(Self.observation(0.15, at: 180, connected: true))
        #expect(
            await store.queuedAlertCount() == 1,
            "a disconnect and reconnect repeated the alert"
        )
    }

    @Test("Forgetting a device can keep or drop its history")
    func forgettingRespectsTheChoice() async {
        let id = DeviceIdentity.bluetooth("aa:bb")

        let keeping = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await keeping.record(Self.observation(0.9))
        await keeping.forget(id, keepingHistory: true)
        #expect(await keeping.snapshot().devices.isEmpty)
        #expect(!(await keeping.history(for: id)).isEmpty, "history was dropped despite the choice to keep it")

        let dropping = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await dropping.record(Self.observation(0.9))
        await dropping.forget(id, keepingHistory: false)
        #expect((await dropping.history(for: id)).isEmpty)
    }

    @Test("Deleting all history leaves the devices in place")
    func deleteAllHistoryKeepsDevices() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.9))
        await store.deleteAllHistory()

        #expect(await store.snapshot().devices.count == 1)
        #expect((await store.history(for: .bluetooth("aa:bb"))).isEmpty)
    }

    @Test("Pinning and hiding are Ledge's own state")
    func pinningAndHiding() async {
        let id = DeviceIdentity.bluetooth("aa:bb")
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.9))

        await store.setPinned(true, for: id)
        await store.setHidden(true, for: id)
        let record = await store.snapshot().devices.first
        #expect(record?.isPinned == true)
        #expect(record?.isHidden == true)
    }

    /// Freshness is a question asked of the clock, not a flag anybody sets.
    @Test("Freshness is derived from the clock, at the boundary and past it")
    func freshnessIsDerived() {
        let record = DeviceRecord(
            id: .bluetooth("aa:bb"), name: "AirPods",
            readings: [BatteryReading(component: .left, level: 0.9, observedAt: Self.t0)],
            firstSeen: Self.t0, lastSeen: Self.t0
        )
        let window = DeviceIdentity.bluetooth("aa:bb").freshnessInterval

        #expect(record.isFresh(now: Self.t0))
        #expect(record.isFresh(now: Self.t0.addingTimeInterval(window)), "the boundary itself should still be fresh")
        #expect(record.isStale(now: Self.t0.addingTimeInterval(window + 1)))

        // A clock that jumps backwards asks the same question and gets a
        // sensible answer rather than a stored flag that has gone wrong.
        #expect(record.isFresh(now: Self.t0.addingTimeInterval(-3600)))
    }

    @Test("Each kind of source gets its own freshness window")
    func freshnessIsSourceSpecific() {
        let advert = DeviceIdentity.peripheral(UUID()).freshnessInterval
        let paired = DeviceIdentity.bluetooth("aa:bb").freshnessInterval
        #expect(advert < paired, "a chatty source should go stale sooner than a slow one")

        let airpods = DeviceRecord(
            id: .peripheral(UUID()), name: "AirPods", firstSeen: Self.t0, lastSeen: Self.t0
        )
        #expect(airpods.isStale(now: Self.t0.addingTimeInterval(paired)))
    }

    /// Silence is not a disconnection. A device that stops advertising is
    /// unknown and stale, never "disconnected" — that would claim an event
    /// nobody saw.
    @Test("Missing advertisements go stale rather than claiming a disconnect")
    func silenceIsNotDisconnection() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let id = DeviceIdentity.peripheral(UUID())
        await store.record(DeviceObservation(
            deviceID: id, name: "AirPods Pro",
            readings: [BatteryReading(component: .left, level: 0.8, observedAt: Self.t0)],
            presence: .unknown, observedAt: Self.t0
        ))

        let record = try! #require(await store.snapshot().devices.first)
        #expect(record.presence == .unknown, "an advertisement was read as a connection")

        let later = Self.t0.addingTimeInterval(id.freshnessInterval + 60)
        #expect(record.isStale(now: later))
        #expect(record.presence == .unknown, "silence was turned into a disconnect")
    }

    @Test("An observed disconnect is recorded, and keeps the last known levels")
    func explicitDisconnectKeepsLevels() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.75, at: 0))

        await store.record(DeviceObservation(
            deviceID: .bluetooth("aa:bb"), name: "AirPods",
            readings: [], presence: .disconnected, observedAt: Self.t0.addingTimeInterval(60)
        ))

        let record = try! #require(await store.snapshot().devices.first)
        #expect(record.presence == .disconnected)
        #expect(
            record.readings.first?.level == 0.75,
            "a disconnect erased the last known level instead of letting it age"
        )
    }

    @Test("A rename across a reconnect keeps identity and history")
    func renameKeepsHistory() async {
        let id = DeviceIdentity.bluetooth("aa:bb")
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.90, name: "AirPods", at: 0))
        await store.record(DeviceObservation(
            deviceID: id, name: "AirPods", readings: [],
            presence: .disconnected, observedAt: Self.t0.addingTimeInterval(60)
        ))
        await store.record(Self.observation(0.40, name: "Ege's AirPods", at: 7200))

        let catalogue = await store.snapshot()
        #expect(catalogue.devices.count == 1, "a rename or reconnect created a second record")
        #expect(catalogue.devices.first?.name == "Ege's AirPods")
        #expect(catalogue.devices.first?.presence == .connected)

        let history = await store.history(for: id)
        #expect(history.count >= 2, "history did not survive the rename")
    }

    @Test("A pinned device stays in the catalogue; forgetting is the only removal")
    func pinnedSurvives() async {
        let id = DeviceIdentity.bluetooth("aa:bb")
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.9))
        await store.setPinned(true, for: id)
        await store.runMaintenance()

        let record = await store.snapshot().devices.first
        #expect(record?.isPinned == true)
        #expect(record != nil, "maintenance removed a pinned device")
    }
}

/// The blockers found in review, as permanent tests.
@Suite("Device catalogue store hardening", .serialized)
struct DeviceCatalogueStoreHardeningTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-harden-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    private static func observation(
        _ level: Double,
        id: DeviceIdentity = .bluetooth("aa:bb"),
        presence: DevicePresence = .connected,
        at seconds: TimeInterval = 0
    ) -> DeviceObservation {
        let when = t0.addingTimeInterval(seconds)
        return DeviceObservation(
            deviceID: id, name: "AirPods",
            readings: [BatteryReading(component: .left, level: level, observedAt: when)],
            presence: presence, observedAt: when
        )
    }

    /// The latch must be on disk from a catalogue that contains it. Writing
    /// before the record was stored put the *old* state on disk, so a crash
    /// inside the debounce window repeated the alert after relaunch.
    @Test("An alert latch reaches disk immediately, from the stored record")
    func latchIsDurableAtOnce() async {
        let url = Self.tempURL()
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 })
        await store.record(Self.observation(0.30, at: 0))
        await store.record(Self.observation(0.15, at: 60))

        // No flush: simulating a crash straight after the alert.
        let reopened = DeviceCatalogueStore(url: url, now: { Self.t0 })
        let record = try! #require(await reopened.snapshot().devices.first)
        #expect(
            !(record.alertState[.left]?.firedRuleIDs.isEmpty ?? true),
            "the latch was not on disk, so the alert would repeat after a crash"
        )

        // And the reloaded state does not alert again.
        await reopened.record(Self.observation(0.15, at: 120))
        #expect(await reopened.queuedAlertCount() == 0, "the alert repeated after reload")
    }

    /// "Remove, Keep History" was undone by the next maintenance pass.
    @Test("History kept on removal survives maintenance")
    func keptHistorySurvivesMaintenance() async {
        let id = DeviceIdentity.bluetooth("aa:bb")
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.90, at: 0))
        await store.forget(id, keepingHistory: true)

        await store.runMaintenance()
        #expect(
            !(await store.history(for: id)).isEmpty,
            "maintenance deleted the history the user chose to keep"
        )
    }

    @Test("History dropped on removal stays dropped")
    func droppedHistoryStaysDropped() async {
        let id = DeviceIdentity.bluetooth("aa:bb")
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.90, at: 0))
        await store.forget(id, keepingHistory: false)
        await store.runMaintenance()
        #expect((await store.history(for: id)).isEmpty)
    }

    /// A catalogue written before `retainedHistory` existed must still load.
    /// A synthesised decoder would have demanded the key, made every old file
    /// unreadable, and quarantined everyone's history on first upgrade.
    @Test("A catalogue without the newest field still loads")
    func olderCatalogueStillLoads() async throws {
        let url = Self.tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Exactly the shape version 1 had before the field was added.
        let json = """
            {"version":1,"devices":[],"history":{"bluetoothAddress:aa:bb":[]}}
            """
        try Data(json.utf8).write(to: url)

        let store = DeviceCatalogueStore(url: url, now: { Self.t0 })
        let catalogue = await store.snapshot()
        #expect(catalogue.version == 1)
        #expect(catalogue.retainedHistory.isEmpty)

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        )
        #expect(
            !siblings.contains { $0.contains("corrupt") },
            "an older catalogue was quarantined instead of read"
        )
    }

    /// A device attaching below the threshold is news, as it was in the
    /// shipped app. The store is what knows whether this is an attach.
    @Test("A device that connects already low is announced")
    func connectingLowAnnounces() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(0.12, presence: .connected, at: 0))
        #expect(
            await store.queuedAlertCount() == 1,
            "a device connected at 12% said nothing"
        )
    }

    @Test("A passive sighting of a low device stays quiet")
    func passiveSightingIsQuiet() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.observation(
            0.12, id: .peripheral(UUID()), presence: .unknown, at: 0
        ))
        #expect(await store.queuedAlertCount() == 0)
    }

    @Test("This Mac never alerts from the catalogue")
    func macNeverAlerts() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        for (level, seconds) in [(0.5, 0.0), (0.3, 60.0), (0.08, 120.0)] {
            await store.record(DeviceObservation(
                deviceID: .thisMac, name: "This Mac",
                readings: [BatteryReading(
                    component: .main, level: level, charging: .notCharging,
                    observedAt: Self.t0.addingTimeInterval(seconds)
                )],
                presence: .connected, observedAt: Self.t0.addingTimeInterval(seconds)
            ))
        }
        #expect(
            await store.queuedAlertCount() == 0,
            "the catalogue announced the Mac's battery, which BatteryProvider already does"
        )
    }

    /// An alert handed to a consumer that could not take it must come back,
    /// not vanish.
    @Test("A rejected alert is requeued rather than lost")
    func rejectedAlertIsRequeued() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let received = Received()
        let (token, _) = await store.subscribeToAlerts { alerts in received.append(alerts) }

        await store.record(Self.observation(0.30, at: 0))
        await store.record(Self.observation(0.15, at: 60))
        #expect(received.count == 1)
        #expect(await store.queuedAlertCount() == 0)

        // The consumer stopped and could not present it.
        await store.unsubscribeFromAlerts(token)
        await store.requeueAlerts([BatteryAlert(
            ruleID: UUID(), kind: .low, deviceID: .bluetooth("aa:bb"),
            deviceName: "AirPods", component: .left, level: 0.15,
            delivery: .notch, firedAt: Self.t0
        )])
        #expect(
            await store.queuedAlertCount() == 1,
            "an alert the consumer could not take was lost"
        )
    }

    /// The card must keep the device's own glyph, tint and full battery
    /// picture, or an AirPods alert looks like a generic accessory.
    @Test("An alert carries the device's styling and every battery it reports")
    func alertKeepsDeviceContext() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let id = DeviceIdentity.peripheral(UUID())

        func observe(_ left: Double, at seconds: TimeInterval) -> DeviceObservation {
            let when = Self.t0.addingTimeInterval(seconds)
            return DeviceObservation(
                deviceID: id, name: "AirPods Pro",
                readings: [
                    BatteryReading(component: .left, level: left, observedAt: when),
                    BatteryReading(component: .right, level: 0.80, observedAt: when),
                    BatteryReading(component: .case, level: 0.55, observedAt: when),
                ],
                presence: .unknown, observedAt: when,
                symbolName: "airpods.pro", isApple: true
            )
        }

        let received = Received()
        _ = await store.subscribeToAlerts { alerts in received.append(alerts) }
        await store.record(observe(0.40, at: 0))
        await store.record(observe(0.12, at: 60))

        let alert = try! #require(received.first)
        #expect(alert.allLevels.count == 3, "the card lost the other batteries")
        #expect(alert.allLevels["Right"] == 0.80)
        // Checked against the *specific* glyph, not merely non-empty: the
        // default is "headphones", so a non-empty check passed while every
        // record was in fact carrying the default.
        #expect(
            alert.symbolName == "airpods.pro",
            "the card fell back to the default glyph: \(alert.symbolName)"
        )
        #expect(alert.isApple, "the card lost the Apple tint")
    }
}

/// Device records must not grow without limit.
///
/// Found by installing and looking: macOS rotates CoreBluetooth peripheral
/// identifiers, so one set of AirPods produced a fresh record every few
/// minutes. Bounding history per device does nothing about the number of
/// devices, and nothing was bounding that.
@Suite("Rotating identity", .serialized)
struct RotatingIdentityTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-rotate-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    private static func advert(
        _ level: Double,
        name: String = "AirPods Pro",
        at seconds: TimeInterval
    ) -> DeviceObservation {
        let when = t0.addingTimeInterval(seconds)
        return DeviceObservation(
            deviceID: .peripheral(UUID()),        // a fresh one every time
            name: name,
            readings: [BatteryReading(component: .left, level: level, observedAt: when)],
            presence: .unknown, observedAt: when,
            symbolName: "airpods.pro", isApple: true
        )
    }

    @Test("A rotating identifier canonicalises to the device's name")
    func canonicalisation() {
        let rotating = DeviceIdentity.peripheral(UUID())
        let canonical = rotating.canonical(name: "AirPods Pro")
        #expect(canonical.source == .proximityName)
        #expect(canonical.value == "airpods pro")
        #expect(canonical.isDurable, "the canonical form must be keepable")

        // Two rotations of the same device land on the same key.
        let other = DeviceIdentity.peripheral(UUID()).canonical(name: "AirPods Pro")
        #expect(canonical == other)

        // Stable identities are already canonical.
        #expect(DeviceIdentity.bluetooth("aa:bb").canonical(name: "x").source == .bluetoothAddress)
        #expect(DeviceIdentity.thisMac.canonical(name: "x") == .thisMac)
    }

    @Test("A nameless advertisement keeps its rotating identity, so retention can retire it")
    func namelessStaysTransient() {
        let rotating = DeviceIdentity.peripheral(UUID())
        #expect(rotating.canonical(name: "   ") == rotating)
        #expect(!rotating.canonical(name: "").isDurable)
    }

    /// The shape observed live: a fresh identifier every few minutes. One
    /// record, all along — not a record per rotation, and not one created and
    /// later deleted.
    @Test("Rotation keeps one record, without maintenance having to intervene")
    func rotationKeepsOneRecord() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        // Deliberately no maintenance call between rotations: production runs
        // it hourly, so correctness must not depend on it.
        for step in 0..<50 {
            await store.record(Self.advert(0.9 - Double(step) / 100, at: Double(step) * 300))
        }
        let devices = await store.snapshot().devices
        #expect(devices.count == 1, "50 rotations left \(devices.count) records")
        #expect(devices.first?.id.source == .proximityName)
    }

    /// The point of canonicalisation: everything the user and the app built up
    /// survives a rotation.
    @Test("Rotation preserves history, pinning, custom rules and alert latches")
    func rotationPreservesEverything() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.advert(0.90, at: 0))

        let canonical = DeviceIdentity.peripheral(UUID()).canonical(name: "AirPods Pro")
        await store.setPinned(true, for: canonical)
        await store.setAlerts(
            DeviceAlertConfiguration(
                rules: [BatteryAlertRule(kind: .low, component: .left, threshold: 0.3)],
                isCustomised: true
            ),
            for: canonical
        )

        // Cross the threshold, which latches.
        await store.record(Self.advert(0.25, at: 600))
        let firedFirst = await store.queuedAlertCount()
        #expect(firedFirst == 1)

        // Now rotate, several times, still low.
        for step in 1...10 {
            await store.record(Self.advert(0.24, at: 600 + Double(step) * 300))
        }

        let devices = await store.snapshot().devices
        #expect(devices.count == 1, "rotation created a second record")
        let record = try! #require(devices.first)
        #expect(record.isPinned, "pinning was lost in a rotation")
        #expect(record.alerts.isCustomised, "the user's own rules were lost in a rotation")
        #expect(record.alerts.rules.first?.threshold == 0.3)
        #expect(
            await store.queuedAlertCount() == 1,
            "the latch was lost, so rotation re-announced the same dip"
        )
        #expect(
            (await store.history(for: canonical)).count >= 2,
            "history did not survive rotation"
        )
    }

    @Test("Two differently-named proximity devices stay separate")
    func distinctNamesStaySeparate() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.advert(0.9, name: "AirPods Pro", at: 0))
        await store.record(Self.advert(0.5, name: "Beats Fit Pro", at: 60))
        #expect(await store.snapshot().devices.count == 2)
    }

    /// Stated plainly so the cost is visible: two same-model sets share the
    /// model's default name and therefore share one record.
    @Test("Two same-named proximity devices share one record, which is the documented cost")
    func sameNameCollapses() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.advert(0.9, name: "AirPods Pro", at: 0))
        await store.record(Self.advert(0.2, name: "AirPods Pro", at: 60))
        #expect(await store.snapshot().devices.count == 1)
    }

    @Test("A record keeps the device's glyph and Apple tint")
    func stylingIsKept() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        await store.record(Self.advert(0.9, at: 0))
        let record = try! #require(await store.snapshot().devices.first)
        #expect(
            record.symbolName == "airpods.pro",
            "the record kept the default glyph instead of the device's: \(record.symbolName)"
        )
        #expect(record.isApple, "the Apple tint was lost")
    }
}

@Suite("Device record retention", .serialized)
struct DeviceRecordRetentionTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-retain-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    private static func sighting(
        _ id: DeviceIdentity,
        name: String = "AirPods",
        at seconds: TimeInterval
    ) -> DeviceObservation {
        let when = t0.addingTimeInterval(seconds)
        return DeviceObservation(
            deviceID: id, name: name,
            readings: [BatteryReading(component: .left, level: 0.8, observedAt: when)],
            presence: id.isDurable ? .connected : .unknown, observedAt: when
        )
    }

    @Test("Rotating identifiers are classified as not durable")
    func rotationIsRecognised() {
        #expect(!DeviceIdentity.peripheral(UUID()).isDurable)
        #expect(DeviceIdentity.bluetooth("aa:bb").isDurable)
        #expect(DeviceIdentity.thisMac.isDurable)
    }

    /// Nameless advertisements have no canonical form, so each is its own
    /// transient record — which is precisely what retention must bound.
    /// Named rotation is covered by `RotatingIdentityTests`.
    @Test("Nameless rotating sightings do not accumulate")
    func rotationDoesNotAccumulate() async {
        let clock = OSAllocatedUnfairLock(initialState: Self.t0)
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { clock.withLock { $0 } })

        // Eight hours of rotation, a fresh identifier every five minutes.
        for step in 0..<96 {
            let seconds = TimeInterval(step) * 300
            clock.withLock { $0 = Self.t0.addingTimeInterval(seconds) }
            await store.record(DeviceObservation(
                deviceID: .peripheral(UUID()), name: "",
                readings: [BatteryReading(
                    component: .left, level: 0.8,
                    observedAt: Self.t0.addingTimeInterval(seconds)
                )],
                presence: .unknown,
                observedAt: Self.t0.addingTimeInterval(seconds)
            ))
            await store.runMaintenance()
        }

        let devices = await store.snapshot().devices
        // The grace is ten minutes and these arrive every five, so at most two
        // retiring records plus the current one coexist. What matters is that
        // it is a small constant rather than one per rotation.
        let ceiling = Int(BatteryHistory.rotatingRecordGrace / 300) + 1
        #expect(
            devices.count <= ceiling,
            "96 rotations left \(devices.count) device records"
        )
    }

    /// Two same-model sets under rotating identifiers share the model's
    /// default name and therefore collapse to one row. Recorded here so the
    /// cost is visible rather than discovered.
    @Test("Same-named rotating devices collapse, which is the documented cost")
    func sameNamedRotatingCollapse() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0.addingTimeInterval(60) })
        await store.record(Self.sighting(.peripheral(UUID()), name: "AirPods Pro", at: 0))
        await store.record(Self.sighting(.peripheral(UUID()), name: "AirPods Pro", at: 30))
        await store.record(Self.sighting(.peripheral(UUID()), name: "Beats Fit Pro", at: 30))
        await store.runMaintenance()

        let devices = await store.snapshot().devices
        #expect(devices.count == 2, "distinct names should survive: \(devices.map(\.name))")
        #expect(Set(devices.map(\.name)) == ["AirPods Pro", "Beats Fit Pro"])
    }

    /// Pinning survives rotation because the record itself does — there is
    /// one canonical record, not an appearance per rotation.
    @Test("Pinning a proximity device survives its identifier rotating")
    func pinnedProximitySurvivesRotation() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0.addingTimeInterval(60) })
        await store.record(Self.sighting(.peripheral(UUID()), name: "AirPods Pro", at: 0))

        // The identity to address is the one the catalogue holds.
        let canonical = try! #require(await store.snapshot().devices.first?.id)
        await store.setPinned(true, for: canonical)

        await store.record(Self.sighting(.peripheral(UUID()), name: "AirPods Pro", at: 30))
        await store.runMaintenance()

        let devices = await store.snapshot().devices
        #expect(devices.count == 1)
        #expect(devices.first?.isPinned == true, "pinning was lost when the identifier rotated")
    }

    @Test("A stable device is kept for as long as its history would be")
    func stableDevicesSurvive() async {
        let clock = OSAllocatedUnfairLock(initialState: Self.t0)
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { clock.withLock { $0 } })
        await store.record(Self.sighting(.bluetooth("aa:bb"), name: "Magic Mouse", at: 0))

        // A week later, still remembered.
        clock.withLock { $0 = Self.t0.addingTimeInterval(7 * 86_400) }
        await store.runMaintenance()
        #expect(await store.snapshot().devices.count == 1)

        // Past the retention age, retired.
        clock.withLock { $0 = Self.t0.addingTimeInterval(BatteryHistory.staleRecordAge + 86_400) }
        await store.runMaintenance()
        #expect(await store.snapshot().devices.isEmpty)
    }

    @Test("A pinned device is never retired, however long it is gone")
    func pinnedNeverRetired() async {
        let clock = OSAllocatedUnfairLock(initialState: Self.t0)
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { clock.withLock { $0 } })
        await store.record(Self.sighting(.peripheral(UUID()), at: 0))
        let id = try! #require(await store.snapshot().devices.first?.id)
        await store.setPinned(true, for: id)

        clock.withLock { $0 = Self.t0.addingTimeInterval(365 * 86_400) }
        await store.runMaintenance()
        #expect(
            await store.snapshot().devices.count == 1,
            "a pinned device was retired to save space"
        )
    }

    @Test("A device the user configured is never retired")
    func customisedNeverRetired() async {
        let clock = OSAllocatedUnfairLock(initialState: Self.t0)
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { clock.withLock { $0 } })
        await store.record(Self.sighting(.peripheral(UUID()), at: 0))
        let id = try! #require(await store.snapshot().devices.first?.id)
        await store.setAlerts(
            DeviceAlertConfiguration(
                rules: [BatteryAlertRule(kind: .low, threshold: 0.3)], isCustomised: true
            ),
            for: id
        )

        clock.withLock { $0 = Self.t0.addingTimeInterval(365 * 86_400) }
        await store.runMaintenance()
        #expect(
            await store.snapshot().devices.count == 1,
            "a device with the user's own alert rules was retired"
        )
    }

    @Test("The record count has a ceiling whatever happens")
    func recordCeilingHolds() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        // All seen at the same instant, so age cannot be what prunes them.
        for index in 0..<(BatteryHistory.maximumDevices + 40) {
            await store.record(Self.sighting(
                .bluetooth("aa:\(index)"), name: "Thing \(index)", at: 0
            ))
        }
        await store.runMaintenance()
        #expect(await store.snapshot().devices.count <= BatteryHistory.maximumDevices)
    }

    @Test("Retiring a record takes its history unless it was retained")
    func retiredHistoryGoes() async {
        let clock = OSAllocatedUnfairLock(initialState: Self.t0)
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { clock.withLock { $0 } })
        // A nameless advertisement has no canonical form, so it stays under a
        // rotating identity — which is what retention is for.
        let id = DeviceIdentity.peripheral(UUID())
        await store.record(DeviceObservation(
            deviceID: id, name: "",
            readings: [BatteryReading(component: .left, level: 0.8, observedAt: Self.t0)],
            presence: .unknown, observedAt: Self.t0
        ))

        clock.withLock { $0 = Self.t0.addingTimeInterval(BatteryHistory.rotatingRecordGrace + 60) }
        await store.runMaintenance()
        #expect(await store.snapshot().devices.isEmpty)
        #expect((await store.history(for: id)).isEmpty, "retired history was left behind")
    }
}

/// Regressions for the third review round.
@Suite("Device catalogue round three", .serialized)
struct DeviceCatalogueRoundThreeTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-r3-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    /// The built-in low rule has one shared id, so keying pending alerts by
    /// rule and component alone made two keyboards collapse into one.
    @Test("Two devices on the default rule queue two pending alerts")
    func perDeviceDeduplication() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let shared = BatteryAlertRule.defaultLowID

        for address in ["aa:aa", "bb:bb"] {
            await store.requeueAlerts([BatteryAlert(
                ruleID: shared, kind: .low, deviceID: .bluetooth(address),
                deviceName: "Keyboard \(address)", component: .main, level: 0.1,
                delivery: .notch, firedAt: Self.t0
            )])
        }
        let queued = await store.queuedAlertCount()
        #expect(queued == 2, "two devices collapsed into \(queued) pending alert(s)")
    }

    @Test("The same device and rule still collapses to one")
    func sameDeviceStillCollapses() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let rule = BatteryAlertRule.defaultLowID
        for level in [0.19, 0.15, 0.10] {
            await store.requeueAlerts([BatteryAlert(
                ruleID: rule, kind: .low, deviceID: .bluetooth("aa:aa"),
                deviceName: "Keyboard", component: .main, level: level,
                delivery: .notch, firedAt: Self.t0
            )])
        }
        #expect(await store.queuedAlertCount() == 1)
    }

    @Test("Low and charged for one component are separate pending alerts")
    func kindIsPartOfTheKey() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let rule = UUID()
        for kind in [AlertKind.low, .charged] {
            await store.requeueAlerts([BatteryAlert(
                ruleID: rule, kind: kind, deviceID: .bluetooth("aa:aa"),
                deviceName: "Mouse", component: .main, level: 0.1,
                delivery: .notch, firedAt: Self.t0
            )])
        }
        #expect(await store.queuedAlertCount() == 2)
    }

    /// Expiry used to run only when another alert arrived, so enabling the
    /// provider after an hour of quiet presented whatever had been waiting.
    @Test("Subscribing after a long silence hands over nothing stale")
    func expiryOnSubscribe() async {
        let clock = OSAllocatedUnfairLock(initialState: Self.t0)
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { clock.withLock { $0 } })

        await store.requeueAlerts([BatteryAlert(
            ruleID: UUID(), kind: .low, deviceID: .bluetooth("aa:aa"),
            deviceName: "Mouse", component: .main, level: 0.1,
            delivery: .notch, firedAt: Self.t0
        )])
        #expect(await store.queuedAlertCount() == 1)

        // An hour of silence: nothing arrives to trigger a purge.
        clock.withLock { $0 = Self.t0.addingTimeInterval(3600) }
        let (_, backlog) = await store.subscribeToAlerts { _ in }
        #expect(
            backlog.isEmpty,
            "an alert from an hour ago was handed to a new subscriber"
        )
    }

    /// A consumer that refuses an alert must not be handed it straight back
    /// while its own unsubscribe is still in flight.
    @Test("An alert refused by the current consumer is queued, not bounced back")
    func refusedAlertIsNotBounced() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let received = Received()
        let (token, _) = await store.subscribeToAlerts { alerts in received.append(alerts) }

        let alert = BatteryAlert(
            ruleID: UUID(), kind: .low, deviceID: .bluetooth("aa:aa"),
            deviceName: "Mouse", component: .main, level: 0.1,
            delivery: .notch, firedAt: Self.t0
        )
        // The still-registered consumer rejects it.
        await store.requeueAlerts([alert], from: token)

        #expect(received.count == 0, "the alert was handed back to the consumer that refused it")
        #expect(await store.queuedAlertCount() == 1)
    }

    @Test("An alert refused by an older consumer reaches the current one")
    func refusedAlertReachesNewConsumer() async {
        let store = DeviceCatalogueStore(url: Self.tempURL(), now: { Self.t0 })
        let (old, _) = await store.subscribeToAlerts { _ in }
        let received = Received()
        _ = await store.subscribeToAlerts { alerts in received.append(alerts) }

        await store.requeueAlerts([BatteryAlert(
            ruleID: UUID(), kind: .low, deviceID: .bluetooth("aa:aa"),
            deviceName: "Mouse", component: .main, level: 0.1,
            delivery: .notch, firedAt: Self.t0
        )], from: old)

        #expect(received.count == 1, "an older consumer's rejection did not reach the live one")
    }

    /// A disconnect keeps the last known levels on purpose. They describe the
    /// past from that moment, however recent the disconnect was.
    @Test("A disconnected device's levels are historical at once")
    func disconnectedLevelsAreHistorical() {
        let record = DeviceRecord(
            id: .bluetooth("aa:bb"), name: "AirPods", presence: .disconnected,
            readings: [BatteryReading(component: .left, level: 0.8, observedAt: Self.t0)],
            firstSeen: Self.t0, lastSeen: Self.t0
        )
        // Last seen *now* — the record is fresh, and the reading still is not.
        #expect(record.isFresh(now: Self.t0))
        #expect(
            !record.isCurrent(record.readings[0], now: Self.t0),
            "a disconnected device's level was presented as current"
        )
        let shown = record.displayedLowestInUse(now: Self.t0)
        #expect(shown.level == 0.8)
        #expect(shown.isHistorical, "the row would have shown it in the primary style")
    }

    @Test("A connected device's recent reading is current")
    func connectedRecentIsCurrent() {
        let record = DeviceRecord(
            id: .bluetooth("aa:bb"), name: "AirPods", presence: .connected,
            readings: [BatteryReading(component: .left, level: 0.8, observedAt: Self.t0)],
            firstSeen: Self.t0, lastSeen: Self.t0
        )
        #expect(record.isCurrent(record.readings[0], now: Self.t0))
        #expect(!record.displayedLowestInUse(now: Self.t0).isHistorical)
    }

    /// A reading can age out even while the record keeps being seen — a
    /// device still present that stopped reporting a battery.
    @Test("An old reading on a still-seen device is historical")
    func oldReadingOnSeenDevice() {
        let interval = DeviceIdentity.bluetooth("aa:bb").freshnessInterval
        let record = DeviceRecord(
            id: .bluetooth("aa:bb"), name: "AirPods", presence: .connected,
            readings: [BatteryReading(component: .left, level: 0.8, observedAt: Self.t0)],
            firstSeen: Self.t0,
            lastSeen: Self.t0.addingTimeInterval(interval + 600)   // still being seen
        )
        let now = Self.t0.addingTimeInterval(interval + 600)
        #expect(record.isFresh(now: now), "the record itself is current")
        #expect(
            !record.isCurrent(record.readings[0], now: now),
            "the reading's own age was ignored in favour of the record's"
        )
    }
}
