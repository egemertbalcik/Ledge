import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

/// What the catalogue is allowed to remember.
///
/// Written against a real install that had grown twenty-five records while
/// macOS was paired with ten devices and reported one of them connected:
/// seventeen strangers' AirPods from proximity advertisements, five ghosts
/// under randomised LE addresses, and nothing that ever left.
@Suite("Device ownership", .serialized)
struct DeviceOwnershipTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-owned-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    /// The Mac's real trackpad, as `system_profiler` reports it.
    private static let trackpad = PairedDevice(
        address: "04:41:A5:97:A6:0D", name: "Ege Mert’s Magic Trackpad",
        isConnected: true, vendorID: 0x004C, productID: 0x0324
    )

    /// A randomised LE address that is in no paired list anywhere.
    private static let ghostAddress = "e9:a8:8f:67:4c:94"

    private static func connect(
        _ address: String,
        name: String = "Ege AirPods",
        level: Double = 0.8,
        at seconds: TimeInterval = 0
    ) -> DeviceObservation {
        let when = t0.addingTimeInterval(seconds)
        return DeviceObservation(
            deviceID: .bluetooth(address), name: name,
            readings: [BatteryReading(component: .left, level: level, observedAt: when)],
            presence: .connected, observedAt: when, cause: .connectionEvent
        )
    }

    /// Writes a catalogue from before the ownership rule.
    private static func writeStoredCatalogue(
        _ records: [DeviceRecord], to url: URL, version: Int = 1
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var stored = DeviceCatalogue(devices: records)
        stored.version = version
        try JSONEncoder().encode(stored).write(to: url)
    }

    private static func record(
        _ id: DeviceIdentity,
        name: String,
        presence: DevicePresence = .connected,
        pinned: Bool = false,
        customised: Bool = false
    ) -> DeviceRecord {
        DeviceRecord(
            id: id, name: name, presence: presence,
            firstSeen: t0, lastSeen: t0,
            isPinned: pinned,
            alerts: DeviceAlertConfiguration(
                rules: customised
                    ? [BatteryAlertRule(kind: .low, component: .left, threshold: 0.3)]
                    : [],
                isCustomised: customised
            )
        )
    }

    // MARK: - Creation

    @Test("A connect notification for an address the Mac is not paired with creates nothing")
    func unpairedConnectCreatesNothing() async {
        let registry = PairedDeviceRegistry()
        registry.answer([Self.trackpad])
        let store = DeviceCatalogueStore(
            url: Self.tempURL(), now: { Self.t0 }, paired: registry
        )

        // The fixture proves the path works before it proves anything is
        // refused: the same call with a paired address must produce a record.
        await store.record(Self.connect(Self.trackpad.address, name: "Magic Trackpad"))
        #expect(
            await store.snapshot().devices.count == 1,
            "a paired device was refused, so the refusal below proves nothing"
        )

        await store.record(Self.connect(Self.ghostAddress))
        let devices = await store.snapshot().devices
        #expect(devices.count == 1, "an unpaired connect notification created a record")
        #expect(!devices.contains { $0.id == .bluetooth(Self.ghostAddress) })
    }

    /// The choice, argued: an unpaired address may *update* a record that is
    /// already there, because the record is keyed by that same address and so
    /// is that device. Only creation is refused.
    @Test("An unpaired address updates the record the user kept, but still creates none")
    func unpairedUpdatesWhatSurvives() async {
        let url = Self.tempURL()
        try! Self.writeStoredCatalogue(
            [Self.record(.bluetooth(Self.ghostAddress), name: "Ege AirPods", pinned: true)],
            to: url
        )
        let registry = PairedDeviceRegistry()
        registry.answer([Self.trackpad])
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 }, paired: registry)

        let kept = await store.snapshot().devices
        #expect(kept.count == 1, "the pinned record was swept away, so this tests nothing")

        await store.record(Self.connect(Self.ghostAddress, level: 0.42, at: 60))
        let devices = await store.snapshot().devices
        #expect(devices.count == 1)
        #expect(
            devices.first?.readings.first?.level == 0.42,
            "a pinned record was frozen instead of taking the reading its own device sent"
        )
    }

    @Test("Something heard over the air never becomes a record of its own")
    func overTheAirIdentityCreatesNothing() async {
        let registry = PairedDeviceRegistry()
        registry.answer([Self.trackpad])
        let store = DeviceCatalogueStore(
            url: Self.tempURL(), now: { Self.t0 }, paired: registry
        )

        await store.record(DeviceObservation(
            deviceID: .peripheral(UUID()), name: "AirPods",
            readings: [BatteryReading(component: .left, level: 0.5, observedAt: Self.t0)],
            presence: .unknown, observedAt: Self.t0, cause: .advertisement
        ))
        #expect(
            await store.snapshot().devices.isEmpty,
            "an advertisement created a catalogue record"
        )
    }

    @Test("A paired device may be catalogued the first time it is heard")
    func pairedDeviceIsAdmitted() async {
        let registry = PairedDeviceRegistry()
        registry.answer([
            Self.trackpad,
            PairedDevice(
                address: "60:FD:A6:1D:B3:09", name: "Ege Mert’s AirPods Pro",
                vendorID: 0x004C, productID: 0x2024
            ),
        ])
        let store = DeviceCatalogueStore(
            url: Self.tempURL(), now: { Self.t0 }, paired: registry
        )
        await store.record(Self.connect("60:FD:A6:1D:B3:09", name: "Ege Mert’s AirPods Pro"))
        #expect(await store.snapshot().devices.count == 1)
    }

    // MARK: - The not-yet-answered trap

    /// Decoding happens long before the Bluetooth stack has said anything. A
    /// prune that ran then would prune against "paired with nothing".
    @Test("Loading a catalogue before the paired list is known drops nothing")
    func decodingWithNoAnswerDropsNothing() async {
        let url = Self.tempURL()
        try! Self.writeStoredCatalogue([
            Self.record(.thisMac, name: "This Mac"),
            Self.record(.bluetooth(Self.trackpad.address), name: "Magic Trackpad"),
            Self.record(.bluetooth(Self.ghostAddress), name: "Ege AirPods"),
            Self.record(
                .init(source: .proximityName, value: "airpods-model-47759"),
                name: "AirPods", presence: .unknown
            ),
        ], to: url)

        let store = DeviceCatalogueStore(
            url: url, now: { Self.t0 }, paired: PairedDeviceRegistry()
        )
        let catalogue = await store.snapshot()
        #expect(
            catalogue.devices.count == 4,
            "records were dropped against a paired list nobody had read"
        )
        #expect(catalogue.needsOwnershipSweep, "the sweep was marked done without running")
    }

    // MARK: - The sweep

    @Test("The sweep drops what the Mac is not paired with, and keeps the user's own choices")
    func sweepDropsUnownedAndKeepsChosen() async {
        let url = Self.tempURL()
        try! Self.writeStoredCatalogue([
            Self.record(.thisMac, name: "This Mac"),
            Self.record(.bluetooth(Self.trackpad.address), name: "Ege Mert’s Magic Trackpad"),
            Self.record(.bluetooth(Self.ghostAddress), name: "Ege AirPods"),
            Self.record(.bluetooth("4c:15:2b:da:43:d2"), name: ""),
            Self.record(
                .init(source: .proximityName, value: "airpods-model-47759"),
                name: "AirPods", presence: .unknown
            ),
            Self.record(
                .bluetooth("d5:fe:e6:68:f6:0e"), name: "Ege AirPods", pinned: true
            ),
            Self.record(
                .bluetooth("c5:3b:ec:b5:86:17"), name: "Ege AirPods", customised: true
            ),
        ], to: url)

        let registry = PairedDeviceRegistry()
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 }, paired: registry)

        #expect(
            await store.snapshot().devices.count == 7,
            "the fixture did not load, so the sweep below has nothing to prove"
        )

        registry.answer([Self.trackpad])
        let devices = await store.snapshot().devices
        let names = Set(devices.map(\.id))
        #expect(devices.count == 4, "the sweep kept \(devices.count) records instead of four")
        #expect(names.contains(.thisMac), "this Mac was swept away")
        #expect(names.contains(.bluetooth(Self.trackpad.address)), "a paired device was swept away")
        #expect(names.contains(.bluetooth("d5:fe:e6:68:f6:0e")), "a pinned record was swept away")
        #expect(
            names.contains(.bluetooth("c5:3b:ec:b5:86:17")),
            "a record with the user's own alert rules was swept away"
        )
        #expect(!names.contains(.bluetooth(Self.ghostAddress)))
        #expect(
            !names.contains(.init(source: .proximityName, value: "airpods-model-47759")),
            "a stranger's advertisement record survived the sweep"
        )
    }

    /// The other half of the same rule, decided rather than overlooked.
    ///
    /// A shipped version of Ledge kept the user's own AirPods under a model
    /// id, and nothing carries those records onto the paired identity. They
    /// go: the device itself comes back the moment it connects, under the
    /// identity it should have had all along, and what is lost is an old
    /// chart and a hidden flag for a feature that had barely shipped when the
    /// identity changed. A record somebody pinned or gave their own alert
    /// rules is exempt, as it always was.
    @Test("A record from the model-id era goes, whatever the Mac is paired with")
    func sweepDropsTheLegacyRecord() async {
        let url = Self.tempURL()
        // 0x2420 as the old version wrote it: AirPods Pro (2nd gen).
        let legacy = DeviceIdentity(source: .proximityName, value: "airpods-model-9248")
        let kept = DeviceIdentity(source: .proximityName, value: "airpods-model-9249")
        try! Self.writeStoredCatalogue([
            Self.record(legacy, name: "AirPods Pro", presence: .unknown),
            Self.record(kept, name: "AirPods Pro", presence: .unknown, pinned: true),
        ], to: url)

        let registry = PairedDeviceRegistry()
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 }, paired: registry)
        #expect(await store.snapshot().devices.count == 2, "the fixture did not load")

        // Even with the Mac paired with exactly the earbuds that record was
        // about: a model id was never a Bluetooth address, and no answer can
        // ever contain it.
        registry.answer([
            PairedDevice(
                address: "60:FD:A6:1D:B3:09", name: "Ege Mert’s AirPods Pro",
                isConnected: false, vendorID: 0x004C, productID: 0x2024
            ),
        ])
        let names = Set(await store.snapshot().devices.map(\.id))
        #expect(!names.contains(legacy))
        #expect(
            names.contains(kept),
            "a pinned record was swept away, and that exemption is older than this rule"
        )
    }

    @Test("A swept catalogue records that it has been swept")
    func sweepBumpsTheVersion() async {
        let url = Self.tempURL()
        try! Self.writeStoredCatalogue(
            [Self.record(.bluetooth(Self.ghostAddress), name: "Ege AirPods")], to: url
        )
        let registry = PairedDeviceRegistry()
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 }, paired: registry)
        #expect(await store.snapshot().version == 1, "the fixture was not written as version 1")

        registry.answer([Self.trackpad])
        let catalogue = await store.snapshot()
        #expect(catalogue.version == DeviceCatalogue.currentVersion)
        #expect(!catalogue.needsOwnershipSweep)

        // And it survives the trip through disk, so the next launch knows.
        await store.flush()
        let reopened = DeviceCatalogueStore(
            url: url, now: { Self.t0 }, paired: PairedDeviceRegistry()
        )
        #expect(await reopened.snapshot().version == DeviceCatalogue.currentVersion)
    }

    // MARK: - Presence

    @Test("A record macOS no longer reports as connected stops claiming it")
    func presenceFollowsThePairedList() async {
        let url = Self.tempURL()
        try! Self.writeStoredCatalogue(
            [Self.record(.bluetooth(Self.trackpad.address), name: "Magic Trackpad")], to: url
        )
        let registry = PairedDeviceRegistry()
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 }, paired: registry)

        registry.answer([Self.trackpad])
        #expect(
            await store.snapshot().devices.first?.presence == .connected,
            "the fixture never reached the connected state it is about to leave"
        )

        var away = Self.trackpad
        away.isConnected = false
        registry.answer([away])
        #expect(
            await store.snapshot().devices.first?.presence == .disconnected,
            "a record stayed connected after macOS said it was not"
        )
    }

    @Test("A connected record the paired list does not mention falls back to unknown")
    func unlistedConnectionBecomesUnknown() async {
        let url = Self.tempURL()
        try! Self.writeStoredCatalogue(
            [Self.record(.bluetooth(Self.ghostAddress), name: "Ege AirPods", pinned: true)],
            to: url
        )
        let registry = PairedDeviceRegistry()
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 }, paired: registry)
        #expect(await store.snapshot().devices.first?.presence == .connected)

        registry.answer([Self.trackpad])
        let record = await store.snapshot().devices.first
        #expect(record != nil, "the pinned record was removed, so presence proves nothing")
        #expect(
            record?.presence == .unknown,
            "a device the system does not list was still claiming to be connected"
        )
    }

    @Test("The paired list is the authority on a device's name")
    func nameFollowsThePairedList() async {
        let url = Self.tempURL()
        try! Self.writeStoredCatalogue(
            [Self.record(.bluetooth("08:5d:53:a9:d9:3e"), name: "AirPods 4 (ANC)")], to: url
        )
        let registry = PairedDeviceRegistry()
        let store = DeviceCatalogueStore(url: url, now: { Self.t0 }, paired: registry)
        #expect(await store.snapshot().devices.first?.name == "AirPods 4 (ANC)")

        registry.answer([PairedDevice(
            address: "08:5D:53:A9:D9:3E", name: "Ege AirPods",
            isConnected: true, vendorID: 0x004C, productID: 0x201B
        )])
        #expect(
            await store.snapshot().devices.first?.name == "Ege AirPods",
            "the record kept a name that came from the air rather than from macOS"
        )
    }

    /// The backstop, for when there is no paired reading at all: Bluetooth off,
    /// the provider disabled, or a catalogue reloaded hours after a crash.
    @Test("A stored connection does not survive a long silence")
    func stalePresenceDecays() async {
        let url = Self.tempURL()
        try! Self.writeStoredCatalogue(
            [Self.record(.bluetooth(Self.trackpad.address), name: "Magic Trackpad")], to: url
        )

        let fresh = DeviceCatalogueStore(
            url: url, now: { Self.t0.addingTimeInterval(60) }, paired: PairedDeviceRegistry()
        )
        #expect(
            await fresh.snapshot().devices.first?.presence == .connected,
            "a minute-old connection was discarded, which is not what rot means"
        )

        let late = DeviceIdentity.bluetooth("aa:bb").freshnessInterval + 60
        let stale = DeviceCatalogueStore(
            url: url, now: { Self.t0.addingTimeInterval(late) }, paired: PairedDeviceRegistry()
        )
        #expect(
            await stale.snapshot().devices.first?.presence == .unknown,
            "a record nothing has spoken for in half an hour still claimed a connection"
        )
    }

    /// An advertisement says "in range". It must not overwrite what something
    /// actually looked at.
    @Test("An advertisement does not erase an observed connection")
    func unknownDoesNotOverwriteKnown() async {
        let registry = PairedDeviceRegistry()
        registry.answer([Self.trackpad])
        let store = DeviceCatalogueStore(
            url: Self.tempURL(), now: { Self.t0 }, paired: registry
        )
        await store.record(Self.connect(Self.trackpad.address, name: "Magic Trackpad"))
        #expect(await store.snapshot().devices.first?.presence == .connected)

        await store.record(DeviceObservation(
            deviceID: .bluetooth(Self.trackpad.address), name: "Magic Trackpad",
            readings: [BatteryReading(component: .left, level: 0.6, observedAt: Self.t0)],
            presence: .unknown, observedAt: Self.t0.addingTimeInterval(30),
            cause: .advertisement
        ))
        let record = await store.snapshot().devices.first
        #expect(record?.presence == .connected, "an advertisement unlearned a connection")
        #expect(record?.readings.first?.level == 0.6, "the advertisement's reading was dropped")
    }
}
