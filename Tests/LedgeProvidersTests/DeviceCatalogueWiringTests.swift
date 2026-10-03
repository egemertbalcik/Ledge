import Foundation
import LedgeCore
import LedgeSystem
import Testing
import os

@testable import LedgeProviders

/// Counts what reached the sink. Synchronous, like the real one.
private final class CountingSink: DeviceObservationSink, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [DeviceObservation]())
    var observations: [DeviceObservation] { state.withLock { $0 } }
    func submit(_ observation: DeviceObservation) {
        state.withLock { $0.append(observation) }
    }
}

/// A Bluetooth source that counts every hardware read asked of it.
private final class CountingBluetoothSource: BluetoothDeviceSource, @unchecked Sendable {
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    nonisolated(unsafe) var devices: [BluetoothDeviceSnapshot] = []

    nonisolated var reads: Int { counter.withLock { $0 } }
    var isAvailable: Bool { true }

    func connectedDevices() async -> [BluetoothDeviceSnapshot] {
        counter.withLock { $0 += 1 }
        return devices
    }

    func startWatching(
        onConnect: @escaping (BluetoothDeviceSnapshot) -> Void,
        onDisconnect: @escaping (String) -> Void
    ) {}

    func stopWatching() {}
}

/// A source whose read can be held open, to exercise the stop race.
private final class SlowBluetoothSource: BluetoothDeviceSource, @unchecked Sendable {
    private let gate = OSAllocatedUnfairLock(
        initialState: (reading: false, released: false, finished: false)
    )
    nonisolated(unsafe) var devices: [BluetoothDeviceSnapshot] = []

    var isAvailable: Bool { true }
    nonisolated var isReading: Bool { gate.withLock { $0.reading } }
    /// Whether the held read has returned. Waited for, so the test does not
    /// have to guess how long "afterwards" is.
    nonisolated var hasFinished: Bool { gate.withLock { $0.finished } }
    nonisolated func release() { gate.withLock { $0.released = true } }

    func connectedDevices() async -> [BluetoothDeviceSnapshot] {
        gate.withLock { $0.reading = true }
        while !gate.withLock({ $0.released }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        gate.withLock { $0.finished = true }
        return devices
    }

    func startWatching(
        onConnect: @escaping (BluetoothDeviceSnapshot) -> Void,
        onDisconnect: @escaping (String) -> Void
    ) {}
    func stopWatching() {}
}

@Suite("Device catalogue wiring")
struct DeviceCatalogueWiringTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func snapshot(
        address: String = "AA:BB:CC:DD:EE:FF",
        name: String = "AirPods Pro",
        levels: [String: Double] = ["Left": 0.9, "Right": 0.9, "Case": 0.5]
    ) -> BluetoothDeviceSnapshot {
        BluetoothDeviceSnapshot(
            name: name, address: address, isConnected: true,
            batteryLevels: levels, symbolName: "airpods.pro", isApple: true
        )
    }

    // MARK: - No extra hardware work

    /// The point of the whole design: the catalogue consumes readings that
    /// were already taken. Wiring it must not add a read, a scan or a query.
    /// Waits for a condition rather than reading a counter immediately.
    ///
    /// The startup read is an async task, so sampling straight after `start()`
    /// compared 0 against 0 and passed whatever happened — it proved neither
    /// population nor the absence of extra reads.
    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool,
        upTo seconds: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Reporting to the catalogue adds no hardware reads")
    @MainActor
    func wiringAddsNoHardwareReads() async {
        let source = CountingBluetoothSource()
        source.devices = [Self.snapshot()]

        // Without a sink. Waited for, so the startup read has actually run.
        let bare = BluetoothProvider(source: source, now: { 0 })
        _ = bare.start()
        await waitUntil { source.reads >= 1 }
        let readsWithoutSink = source.reads
        bare.stop()
        #expect(readsWithoutSink >= 1, "the startup read never happened")

        // With one. Same provider, same source, same lifecycle.
        let sink = CountingSink()
        let wired = BluetoothProvider(source: source, observations: sink, now: { 0 })
        _ = wired.start()
        await waitUntil { !sink.observations.isEmpty }
        let readsWithSink = source.reads - readsWithoutSink
        wired.stop()

        #expect(
            readsWithSink == readsWithoutSink,
            "wiring the catalogue changed the reads from \(readsWithoutSink) to \(readsWithSink)"
        )
        #expect(
            !sink.observations.isEmpty,
            "an already-connected device was never reported to the catalogue"
        )
    }

    /// A device connected before Ledge started produces no connect event, so
    /// without the startup report the catalogue would not hear of it until the
    /// ten-minute refresh.
    @Test("An already-connected device is reported at startup")
    @MainActor
    func startupPopulatesTheCatalogue() async {
        let source = CountingBluetoothSource()
        source.devices = [Self.snapshot()]
        let sink = CountingSink()

        let provider = BluetoothProvider(source: source, observations: sink, now: { 0 })
        _ = provider.start()
        await waitUntil { !sink.observations.isEmpty }
        provider.stop()

        let reported = sink.observations
        #expect(reported.count >= 1)
        #expect(reported.first?.deviceID == .bluetooth("AA:BB:CC:DD:EE:FF"))
        #expect(reported.first?.presence == .connected)
    }

    /// `system_profiler` takes seconds, so a read can land after the provider
    /// has stopped. Its result must not repopulate anything.
    @Test("A read that finishes after stop reports nothing")
    @MainActor
    func stoppedProviderDiscardsLateRead() async {
        let source = SlowBluetoothSource()
        source.devices = [Self.snapshot()]
        let sink = CountingSink()

        let provider = BluetoothProvider(source: source, observations: sink, now: { 0 })
        _ = provider.start()

        // The read must *actually* be in flight before stopping, or this tests
        // nothing: a wait that silently expired left the read never started,
        // and the test then passed because nothing had been reported for
        // entirely the wrong reason. Measured at 5.958s on a loaded machine
        // against a 5s wait, so the timeout is generous and asserted.
        await waitUntil({ source.isReading }, upTo: 30)
        #expect(source.isReading, "the read never began, so the stop race was never exercised")

        provider.stop()
        source.release()

        // Wait for the read to have genuinely finished inside the source,
        // rather than guessing at an interval.
        await waitUntil({ source.hasFinished }, upTo: 30)
        #expect(source.hasFinished, "the released read never completed")

        // And give its result every chance to be applied.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(
            sink.observations.isEmpty,
            "a read that outlived the provider reported \(sink.observations.count) observations"
        )
    }

    @Test("An observation carries the component, charging evidence and timestamp through")
    func observationsArePreserved() {
        let at = Self.t0.addingTimeInterval(120)
        let observation = DeviceObservations.fromBluetooth(Self.snapshot(), at: at, cause: .connectionEvent)

        #expect(observation.deviceID == .bluetooth("AA:BB:CC:DD:EE:FF"))
        #expect(observation.readings.count == 3)
        #expect(observation.reading(for: .left)?.level == 0.9)
        #expect(observation.reading(for: .case)?.level == 0.5)
        #expect(observation.readings.allSatisfy { $0.observedAt == at })
        // system_profiler and IOBluetooth report a level and nothing else.
        #expect(
            observation.readings.allSatisfy { $0.charging == .unknown },
            "a charging state was invented for a source that cannot report one"
        )
    }

    @Test("Identity comes from the address, never the name")
    func identityIsTheAddress() {
        let first = DeviceObservations.fromBluetooth(
            Self.snapshot(address: "AA:AA", name: "AirPods Pro"), at: Self.t0, cause: .connectionEvent
        )
        let second = DeviceObservations.fromBluetooth(
            Self.snapshot(address: "BB:BB", name: "AirPods Pro"), at: Self.t0, cause: .connectionEvent
        )
        #expect(first.deviceID != second.deviceID, "two devices collided on a shared name")

        let renamed = DeviceObservations.fromBluetooth(
            Self.snapshot(address: "AA:AA", name: "Ege's AirPods"), at: Self.t0, cause: .connectionEvent
        )
        #expect(first.deviceID == renamed.deviceID, "a rename was treated as a new device")
    }

    @Test("Address case does not split one device in two")
    func addressCaseIsNormalised() {
        let upper = DeviceObservations.fromBluetooth(Self.snapshot(address: "AA:BB"), at: Self.t0, cause: .connectionEvent)
        let lower = DeviceObservations.fromBluetooth(Self.snapshot(address: "aa:bb"), at: Self.t0, cause: .connectionEvent)
        #expect(upper.deviceID == lower.deviceID)
    }

    @Test("A device reporting no battery still produces an observation")
    func missingComponentsAreFine() {
        let observation = DeviceObservations.fromBluetooth(
            Self.snapshot(levels: [:]), at: Self.t0, cause: .connectionEvent
        )
        #expect(observation.readings.isEmpty)
        #expect(observation.deviceID == .bluetooth("AA:BB:CC:DD:EE:FF"))
    }

    @Test("This Mac reports charging evidence, so it can support charged alerts")
    func macSupportsCharging() {
        let observation = DeviceObservations.fromMac(
            name: "This Mac", level: 0.42, isCharging: true, at: Self.t0
        )
        #expect(observation.deviceID == .thisMac)
        #expect(observation.reading(for: .main)?.charging == .charging)
        #expect(BatteryAlertEngine.supportsCharged(observation.readings, for: .main))
    }

    @Test("A Bluetooth accessory does not claim charged support it cannot honour")
    func bluetoothDoesNotSupportCharged() {
        let observation = DeviceObservations.fromBluetooth(Self.snapshot(), at: Self.t0, cause: .connectionEvent)
        #expect(!BatteryAlertEngine.supportsCharged(observation.readings, for: .left))
    }

    // MARK: - Repeated observations

    /// A duty-cycled scanner and a ten-minute refresh both produce the same
    /// reading over and over. None of them is news, and none should cost a
    /// decision, a write or a history row.
    @Test("Repeated identical observations produce no decisions and no history growth")
    func repeatsAreInert() async {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-wiring-\(UUID().uuidString)")
            .appendingPathComponent("devices.json")
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 })

        let observation = DeviceObservations.fromBluetooth(Self.snapshot(), at: Self.t0, cause: .connectionEvent)
        for _ in 0..<100 { await store.record(observation) }

        let queued = await store.queuedAlertCount()
        #expect(queued == 0, "an unchanging reading produced \(queued) alerts")

        let history = await store.history(for: .bluetooth("AA:BB:CC:DD:EE:FF"))
        #expect(history.count == 3, "100 identical observations stored \(history.count) samples")

        let catalogue = await store.snapshot()
        #expect(catalogue.devices.count == 1)
    }
}
