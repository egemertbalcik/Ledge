import Foundation
import LedgeCore
import LedgeSystem
import Testing
import os

@testable import LedgeProviders

/// A paired-list read that can fail, succeed, or be counted.
private final class InventorySource: BluetoothDeviceSource, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    nonisolated(unsafe) var answer: [BluetoothDeviceSnapshot]?
    /// When the fake's list was "read". Defaults to now, like a real one.
    nonisolated(unsafe) var readAt = Date()

    init(answer: [BluetoothDeviceSnapshot]?) { self.answer = answer }

    var isAvailable: Bool { true }
    nonisolated var reads: Int { state.withLock { $0 } }

    func pairedDevices() async -> PairedListReading? {
        state.withLock { $0 += 1 }
        guard let answer else { return nil }
        return PairedListReading(devices: answer, readAt: readAt)
    }

    func startWatching(
        onConnect: @escaping (BluetoothDeviceSnapshot) -> Void,
        onDisconnect: @escaping (String) -> Void
    ) {}
    func stopWatching() {}
}

/// Reading the paired list, and what a failed read may not be mistaken for.
///
/// The catalogue prunes every record against this answer. "The Mac is paired
/// with nothing" and "nobody could be asked" used to be the same empty list,
/// so a `system_profiler` that timed out deleted every device and its battery
/// history, permanently.
@MainActor
@Suite("The paired list")
struct PairedInventoryTests {

    private static func snapshot(_ address: String, name: String) -> BluetoothDeviceSnapshot {
        BluetoothDeviceSnapshot(
            name: name,
            address: address,
            isConnected: true,
            symbolName: "airpods.pro",
            isApple: true
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool,
        upTo seconds: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A read that failed is not an answer")
    func failedReadKeepsTheLastAnswer() async {
        let registry = PairedDeviceRegistry()
        // What a good read left behind.
        registry.answer([
            PairedDevice(address: "60:FD:A6:1D:B3:09", name: "Ege’s AirPods Pro", isConnected: true),
        ])
        let before = registry.current

        let source = InventorySource(answer: nil)
        let provider = BluetoothProvider(source: source, paired: registry, now: { 0 })
        _ = provider.start()
        await waitUntil { source.reads >= 1 }
        provider.stop()

        #expect(source.reads >= 1, "the startup read never happened")
        #expect(
            registry.current?.devices == before?.devices,
            "a failed read replaced the paired list with an empty one"
        )
        #expect(registry.current?.generation == before?.generation)
    }

    @Test("A read that succeeded is an answer, even when it is empty")
    func anEmptyAnswerIsStillAnAnswer() async {
        let registry = PairedDeviceRegistry()
        registry.answer([PairedDevice(address: "AA:BB:CC:DD:EE:FF", name: "Old")])

        // A Mac that really is paired with nothing says so, and the
        // catalogue is entitled to act on it.
        let source = InventorySource(answer: [])
        let provider = BluetoothProvider(source: source, paired: registry, now: { 0 })
        _ = provider.start()
        await waitUntil { registry.current?.devices.isEmpty == true }
        provider.stop()

        #expect(registry.current?.devices.isEmpty == true)
    }

    @Test("A connection is recorded as it happens, not ten minutes later")
    func liveConnectionUpdates() {
        let registry = PairedDeviceRegistry()
        registry.answer([
            PairedDevice(address: "60:FD:A6:1D:B3:09", name: "Pods", isConnected: false),
        ])

        registry.connectionChanged(address: "60-fd-a6-1d-b3-09", isConnected: true)
        #expect(registry.current?.devices.first?.isConnected == true)
        // The list is read at startup and every ten minutes; anything asking
        // "is this connected now" was answering from a reading that old.
        #expect(registry.current?.generation == 2)

        registry.connectionChanged(address: "60:FD:A6:1D:B3:09", isConnected: false)
        #expect(registry.current?.devices.first?.isConnected == false)
    }

    @Test("A device the list has never heard of is not invented")
    func unknownDeviceIsIgnored() {
        let registry = PairedDeviceRegistry()
        registry.answer([PairedDevice(address: "60:FD:A6:1D:B3:09", name: "Pods")])
        registry.connectionChanged(address: "11:22:33:44:55:66", isConnected: true)
        #expect(registry.current?.devices.count == 1)
        // Membership is a complete reading's business, and nothing else's.
        #expect(registry.current?.generation == 1)
    }

    @Test("Nothing to patch before the first reading")
    func noAnswerYet() {
        let registry = PairedDeviceRegistry()
        registry.connectionChanged(address: "60:FD:A6:1D:B3:09", isConnected: true)
        #expect(registry.current == nil)
    }

    @Test("A reading that was taken before the event does not undo it")
    func staleReadingLosesToALiveEvent() {
        // `system_profiler` takes seconds to answer, and what it says is true
        // of when it ran. A connect that happens while it is running is newer
        // than the list it hands back.
        let registry = PairedDeviceRegistry()
        let readBegan = Date(timeIntervalSinceReferenceDate: 100)
        let connectedAt = readBegan.addingTimeInterval(2)

        registry.answer(
            [PairedDevice(address: "60:FD:A6:1D:B3:09", name: "Pods", isConnected: false)],
            at: readBegan.addingTimeInterval(-60)
        )
        registry.connectionChanged(
            address: "60:FD:A6:1D:B3:09", isConnected: true, at: connectedAt
        )
        #expect(registry.current?.devices.first?.isConnected == true)

        // The read that was already in flight lands, carrying what it sampled
        // before the connect.
        registry.answer(
            [PairedDevice(address: "60:FD:A6:1D:B3:09", name: "Pods", isConnected: false)],
            at: readBegan
        )
        #expect(
            registry.current?.devices.first?.isConnected == true,
            "a reading taken before the connect undid it"
        )

        // A reading taken *after* the event is the newer evidence, and wins.
        registry.answer(
            [PairedDevice(address: "60:FD:A6:1D:B3:09", name: "Pods", isConnected: false)],
            at: connectedAt.addingTimeInterval(1)
        )
        #expect(registry.current?.devices.first?.isConnected == false)
    }

    @Test("An event before the first reading is not lost")
    func eventBeforeTheFirstReading() {
        let registry = PairedDeviceRegistry()
        let at = Date(timeIntervalSinceReferenceDate: 100)
        // Nothing to patch yet — but the reading that is about to land may
        // have been taken before this happened.
        registry.connectionChanged(address: "60:FD:A6:1D:B3:09", isConnected: true, at: at)
        registry.answer(
            [PairedDevice(address: "60:FD:A6:1D:B3:09", name: "Pods", isConnected: false)],
            at: at.addingTimeInterval(-5)
        )
        #expect(registry.current?.devices.first?.isConnected == true)
    }

    @Test("A reading taken earlier does not replace one taken later")
    func olderReadingLoses() {
        // Two reads can be in flight at once — the startup read and the
        // ten-minute one, or two providers — and the last to *finish* is not
        // the last to have looked.
        let registry = PairedDeviceRegistry()
        let later = Date(timeIntervalSinceReferenceDate: 200)
        registry.answer([PairedDevice(address: "60:FD:A6:1D:B3:09", name: "Pods")], at: later)

        registry.answer([], at: later.addingTimeInterval(-60))
        #expect(
            registry.current?.devices.count == 1,
            "an older reading replaced a newer list with a staler one"
        )
        #expect(registry.current?.at == later)

        // A newer one is still an answer.
        registry.answer([], at: later.addingTimeInterval(60))
        #expect(registry.current?.devices.isEmpty == true)
    }

    @Test("A connection event does not discard a newer list")
    func eventDoesNotBlockMembership() {
        // The two clocks were one: an event advanced the same timestamp the
        // next inventory was judged against, so one device's churn could
        // keep throwing away another device's arrival in the list.
        let registry = PairedDeviceRegistry()
        let a = PairedDevice(address: "60:FD:A6:1D:B3:09", name: "Pods", isConnected: false)
        let b = PairedDevice(address: "AA:BB:CC:DD:EE:FF", name: "Speaker", isConnected: false)
        let t = Date(timeIntervalSinceReferenceDate: 0)

        registry.answer([a], at: t.addingTimeInterval(90))
        // A read taken at 100 is about to land, carrying the newly paired B.
        registry.connectionChanged(
            address: a.address, isConnected: true, at: t.addingTimeInterval(102)
        )
        registry.answer([a, b], at: t.addingTimeInterval(100))

        #expect(
            registry.current?.devices.count == 2,
            "a connection event threw away a newer reading of the list"
        )
        // And the event is still the newer evidence about A.
        #expect(registry.current?.devices.first { $0.address == a.address }?.isConnected == true)
    }

    @Test("A reading older than the last reading says so")
    func acceptanceIsReported() {
        let registry = PairedDeviceRegistry()
        let t = Date(timeIntervalSinceReferenceDate: 100)
        #expect(registry.answer([], at: t).wasAccepted)
        // Everything derived from an older reading is as old as it is — its
        // battery levels included, which is why the caller has to be told.
        #expect(!registry.answer([], at: t.addingTimeInterval(-10)).wasAccepted)
        #expect(registry.answer([], at: t.addingTimeInterval(10)).wasAccepted)
    }

    @Test("What is reported as connected is what the registry still believes")
    func reportsTheMergedTruth() {
        // A device that disconnected while the read was running is still
        // "connected" in what the read hands back; recording that presence
        // contradicts what the system has already said.
        let pods = BluetoothDeviceSnapshot(
            name: "Pods", address: "60:FD:A6:1D:B3:09", isConnected: true
        )
        let speaker = BluetoothDeviceSnapshot(
            name: "Speaker", address: "AA:BB:CC:DD:EE:FF", isConnected: true
        )
        let answer = PairedDeviceRegistry.Answer(
            devices: [
                PairedDevice(address: pods.address, name: "Pods", isConnected: false),
                PairedDevice(address: speaker.address, name: "Speaker", isConnected: true),
            ],
            generation: 2,
            at: Date(timeIntervalSinceReferenceDate: 0)
        )
        let reported = BluetoothProvider.stillConnected(in: [pods, speaker], by: answer)
        #expect(reported.map(\.name) == ["Speaker"])
    }

    @Test("A device that connected while the read was running is reported connected")
    func repairsTheOtherDirection() {
        // The opposite direction of the same bug: the snapshot says
        // disconnected because that is what the list held when it was read,
        // and the catalogue recorded a departure the system had already
        // contradicted.
        let pods = BluetoothDeviceSnapshot(
            name: "Pods", address: "60:FD:A6:1D:B3:09", isConnected: false
        )
        let answer = PairedDeviceRegistry.Answer(
            devices: [PairedDevice(address: pods.address, name: "Pods", isConnected: true)],
            generation: 2,
            at: Date(timeIntervalSinceReferenceDate: 0)
        )
        let reported = BluetoothProvider.stillConnected(in: [pods], by: answer)
        #expect(reported.count == 1)
        #expect(
            reported.first?.isConnected == true,
            "the device was reported, still carrying the stale answer"
        )
    }

    @Test("A device the authoritative list does not hold is not reported")
    func omissionIsAnAnswer() {
        let stranger = BluetoothDeviceSnapshot(
            name: "Someone else's", address: "11:22:33:44:55:66", isConnected: true
        )
        let answer = PairedDeviceRegistry.Answer(
            devices: [], generation: 2, at: Date(timeIntervalSinceReferenceDate: 0)
        )
        #expect(BluetoothProvider.stillConnected(in: [stranger], by: answer).isEmpty)
    }

    @Test("The paired list is only re-read when nobody else is keeping it current")
    func inventoryCadence() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        #expect(AirPodsProximityProvider.needsAReading(nil, now: now))
        let fresh = PairedDeviceRegistry.Answer(devices: [], generation: 1, at: now)
        // The Bluetooth card reads it every ten minutes; a second
        // `system_profiler` for the same list is pure cost.
        #expect(!AirPodsProximityProvider.needsAReading(fresh, now: now))
        let old = PairedDeviceRegistry.Answer(
            devices: [], generation: 1,
            at: now.addingTimeInterval(-AirPodsProximityProvider.inventoryRefresh - 1)
        )
        // Nobody has read it in ten minutes: a device paired since would
        // never be recognised.
        #expect(AirPodsProximityProvider.needsAReading(old, now: now))
    }
}

/// What a reading of the paired list is allowed to be.
@Suite("Reading the profiler's output")
struct ProfilerIdentityTests {

    @Test("An address has to be an address")
    func usableAddresses() {
        #expect(IOBluetoothDeviceSource.isUsableAddress("60:FD:A6:1D:B3:09"))
        #expect(IOBluetoothDeviceSource.isUsableAddress("60-fd-a6-1d-b3-09"))
        // The one that passed every check and became the only identity in a
        // "complete" inventory — with the real device missing from it, and
        // therefore deleted.
        #expect(!IOBluetoothDeviceSource.isUsableAddress(""))
        #expect(!IOBluetoothDeviceSource.isUsableAddress("not an address"))
        #expect(!IOBluetoothDeviceSource.isUsableAddress("60:FD:A6:1D:B3"))
        #expect(!IOBluetoothDeviceSource.isUsableAddress("60:FD:A6:1D:B3:0Z"))
    }

    @Test("A device listed with an unusable address is an incomplete reading")
    func emptyAddressIsIncomplete() {
        let json = """
            {"SPBluetoothDataType":[{
              "controller_properties":{"controller_state":"attrib_on"},
              "device_connected":[{"My Pods":{"device_address":"","device_batteryLevelLeft":"70%"}}]
            }]}
            """
        #expect(IOBluetoothDeviceSource.parse(Data(json.utf8)) == nil)
    }

    @Test("An address is judged as it was written, not after normalising")
    func rawAddressIsWhatCounts() {
        // Normalising throws away everything that is not a hex digit, so a
        // check afterwards is a check on something the output never said.
        let json = """
            {"SPBluetoothDataType":[{
              "controller_properties":{"controller_state":"attrib_on"},
              "device_connected":[{"Pods":{"device_address":"AA:BB:CC:DD:EE:00!"}}]
            }]}
            """
        #expect(IOBluetoothDeviceSource.parse(Data(json.utf8)) == nil)
    }

    @Test("A controller section that is not a section certifies nothing")
    func malformedControllerIsNotAnAnswer() {
        for value in ["null", "17", "\"attrib_on\""] {
            let json = "{\"SPBluetoothDataType\":[{\"controller_properties\":\(value)}]}"
            #expect(
                IOBluetoothDeviceSource.parse(Data(json.utf8)) == nil,
                "controller_properties: \(value) was taken as a reading"
            )
        }
    }
}

/// Which of two readings of the same cell is the one on screen.
@Suite("The newest reading of each component")
struct FreshestReadingTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func reading(
        _ component: BatteryComponent,
        _ level: Double,
        at seconds: TimeInterval
    ) -> BatteryReading {
        BatteryReading(
            component: component, level: level,
            observedAt: t0.addingTimeInterval(seconds)
        )
    }

    @Test("An older sample does not replace a newer one")
    func olderSampleLoses() {
        // A reading of the paired list takes seconds, so one sampled before
        // an advertisement can arrive after it. It is still the right thing
        // to accept for membership; its battery levels are not.
        let held = [Self.reading(.left, 0.2, at: 102)]
        let arriving = [Self.reading(.left, 0.7, at: 100)]
        let merged = DeviceCatalogueStore.freshest(held, arriving)
        #expect(merged.count == 1)
        #expect(merged.first?.level == 0.2)
    }

    @Test("A newer sample replaces an older one")
    func newerSampleWins() {
        let merged = DeviceCatalogueStore.freshest(
            [Self.reading(.left, 0.7, at: 100)],
            [Self.reading(.left, 0.2, at: 102)]
        )
        #expect(merged.first?.level == 0.2)
    }

    @Test("A late older sample is not news for the alert engine")
    func olderSampleIsNotNews() {
        // The display was already protected; the alert engine was not. A
        // stale 70% arriving after a 20% advertisement released the low
        // latch, and the next advertisement announced the same low battery
        // all over again.
        let held = [Self.reading(.left, 0.2, at: 102)]
        let late = [Self.reading(.left, 0.7, at: 100)]
        #expect(DeviceCatalogueStore.newsOnly(late, against: held).isEmpty)

        // What is genuinely new still is, including the first reading of a
        // cell nothing was known about.
        let fresh = [Self.reading(.left, 0.7, at: 103), Self.reading(.case, 0.9, at: 90)]
        #expect(DeviceCatalogueStore.newsOnly(fresh, against: held).count == 2)
    }

    @Test("A cell the arriving reading does not mention is kept")
    func untouchedCellsSurvive() {
        let merged = DeviceCatalogueStore.freshest(
            [Self.reading(.left, 0.7, at: 100), Self.reading(.case, 0.9, at: 100)],
            [Self.reading(.left, 0.2, at: 102)]
        )
        #expect(merged.count == 2)
        #expect(merged.first { $0.component == .case }?.level == 0.9)
        #expect(merged.first { $0.component == .left }?.level == 0.2)
    }
}
