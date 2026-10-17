import Foundation
import LedgeCore
import LedgeSystem
import Testing

@testable import LedgeProviders

/// Whose earbuds are these?
///
/// The install that prompted this had seventeen records named "AirPods" with
/// model ids like `airpods-model-47759`, every one of them created by an
/// advertisement from somebody else's hardware. Nothing here needs a radio:
/// an advertisement is a value and the paired list is a value.
@Suite("Proximity ownership")
struct ProximityOwnershipTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-prox-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    /// An advertisement as the scanner hands one over.
    private static func advert(
        model: UInt16,
        left: Double? = 0.7,
        right: Double? = 0.8,
        caseLevel: Double? = 0.5
    ) -> AirPodsProximity {
        var proximity = AirPodsProximity(
            model: model,
            leftBattery: left, rightBattery: right, caseBattery: caseLevel,
            isChargingLeft: false, isChargingRight: false, isChargingCase: true,
            lidCounter: 3
        )
        proximity.peripheralID = UUID()
        return proximity
    }

    /// The owner's own AirPods Pro, as `system_profiler` lists them.
    private static let ownPods = PairedDevice(
        address: "60:FD:A6:1D:B3:09", name: "Ege Mert’s AirPods Pro",
        isConnected: false, vendorID: 0x004C, productID: 0x2024
    )

    private static func answer(_ devices: [PairedDevice]) -> PairedDeviceRegistry.Answer {
        PairedDeviceRegistry.Answer(devices: devices, generation: 1, at: t0)
    }

    @Test("A stranger's advertisement produces nothing to record")
    func strangersAdvertIsNothing() {
        let paired = Self.answer([Self.ownPods])

        // The fixture first: the owner's own model must produce an
        // observation, or "nil" below would mean the matcher is simply broken.
        #expect(
            DeviceObservations.fromProximity(
                Self.advert(model: 0x2420), paired: paired, at: Self.t0
            ) != nil,
            "the owner's own AirPods were not recognised"
        )

        // AirPods Pro (1st gen) — a real Apple model, paired with somebody
        // else's Mac.
        #expect(
            DeviceObservations.fromProximity(
                Self.advert(model: 0x0E20), paired: paired, at: Self.t0
            ) == nil,
            "a stranger's AirPods produced a catalogue observation"
        )
    }

    @Test("A model id no AirPods ever advertised is a misread, not a device")
    func unknownModelIsRefused() {
        // 47759 = 0xBA8F, one of the ids the real catalogue had a record for.
        #expect(
            DeviceObservations.fromProximity(
                Self.advert(model: 47759), paired: Self.answer([Self.ownPods]), at: Self.t0
            ) == nil
        )
    }

    /// `isKnownModel` is not redundant with the paired match: the owner's
    /// Magic Trackpad reports product `0x0324`, which byte-swaps to `0x2403`.
    /// A misdecoded advertisement claiming that model would otherwise hang
    /// earbud batteries off the trackpad's record.
    @Test("A misread model does not land on whatever paired device byte-swaps onto it")
    func misreadModelDoesNotHitAnotherDevice() {
        let trackpad = PairedDevice(
            address: "04:41:A5:97:A6:0D", name: "Ege Mert’s Magic Trackpad",
            isConnected: true, vendorID: 0x004C, productID: 0x0324
        )
        let paired = Self.answer([trackpad])
        #expect(
            paired.devices.first?.advertisedModel == 0x2403,
            "the fixture does not reproduce the collision it is about to test"
        )
        #expect(
            DeviceObservations.fromProximity(
                Self.advert(model: 0x2403), paired: paired, at: Self.t0
            ) == nil,
            "an advertisement attached earbud batteries to a trackpad"
        )
    }

    @Test("An advertisement arriving before the paired list is read produces nothing")
    func noAnswerMeansNoObservation() {
        #expect(
            DeviceObservations.fromProximity(
                Self.advert(model: 0x2420), paired: nil, at: Self.t0
            ) == nil,
            "an advertisement was catalogued on no evidence of ownership at all"
        )
    }

    @Test("An advertisement attaches to the paired device, under its own name")
    func advertAttachesToThePairedRecord() throws {
        let observation = try #require(DeviceObservations.fromProximity(
            Self.advert(model: 0x2420), paired: Self.answer([Self.ownPods]), at: Self.t0
        ))
        #expect(observation.deviceID == .bluetooth("60:fd:a6:1d:b3:09"))
        #expect(observation.canonicalID == .bluetooth("60:fd:a6:1d:b3:09"))
        #expect(
            observation.name == "Ege Mert’s AirPods Pro",
            "the observation carried the model's generic name instead of the Mac's"
        )
        #expect(observation.presence == .unknown, "an advertisement claimed an attachment")
        #expect(observation.cause == .advertisement)
        // The charging evidence is the reason to keep these at all.
        #expect(observation.reading(for: .case)?.charging == .charging)
        #expect(observation.readings.count == 3)
    }

    @Test("An advertisement with nothing to say is still nothing to record")
    func emptyAdvertIsRefused() {
        #expect(
            DeviceObservations.fromProximity(
                Self.advert(model: 0x2420, left: nil, right: nil, caseLevel: nil),
                paired: Self.answer([Self.ownPods]), at: Self.t0
            ) == nil
        )
    }

    /// The card is the other half of the same bug: a stranger's case opening
    /// at the next table popped "AirPods, 90%" on the owner's screen.
    @Test("A lid card is shown for the owner's earbuds and nobody else's")
    func lidCardsAreOwnersOnly() {
        let paired = Self.answer([Self.ownPods])
        #expect(AirPodsProximityProvider.isWorthShowing(
            Self.advert(model: 0x2420), paired: paired
        ))
        #expect(
            !AirPodsProximityProvider.isWorthShowing(
                Self.advert(model: 0x0E20), paired: paired
            ),
            "a stranger's case opening published a card"
        )
        // Before anything has read the paired list a card is still shown: it
        // is transient, and withholding the owner's own is the worse failure.
        #expect(AirPodsProximityProvider.isWorthShowing(
            Self.advert(model: 0x0E20), paired: nil
        ))
    }

    /// End to end, through the real catalogue: the thing the owner actually
    /// saw was records appearing, so that is what is asserted.
    @Test("Strangers' advertisements leave the catalogue empty; the owner's fills one record")
    func cataloguingIsOwnersOnly() async throws {
        let registry = PairedDeviceRegistry()
        registry.answer([Self.ownPods])
        let store = DeviceCatalogueStore(
            url: Self.tempURL(), now: { Self.t0 }, paired: registry
        )

        // A café: six sets of earbuds, none of them this Mac's.
        for model: UInt16 in [0x0E20, 0x0220, 0x1320, 0x1920, 0x0A20, 0x1F20] {
            guard let observation = DeviceObservations.fromProximity(
                Self.advert(model: model), paired: registry.current, at: Self.t0
            ) else { continue }
            await store.record(observation)
        }
        let afterStrangers = await store.snapshot().devices
        #expect(
            afterStrangers.isEmpty,
            "strangers' earbuds were catalogued: \(afterStrangers.map(\.name))"
        )

        let mine = try #require(DeviceObservations.fromProximity(
            Self.advert(model: 0x2420), paired: registry.current, at: Self.t0
        ))
        await store.record(mine)
        let devices = await store.snapshot().devices
        #expect(devices.count == 1)
        #expect(devices.first?.id == .bluetooth("60:fd:a6:1d:b3:09"))
        #expect(
            devices.first?.id.source == .bluetoothAddress,
            "the owner's own earbuds got a second record keyed by model id"
        )
    }
}

/// The paired list as `system_profiler` actually prints it.
@Suite("Paired list parsing")
struct PairedListParsingTests {

    @Test("Vendor and product ids are carried off the profiler output")
    func idsAreParsed() throws {
        let snapshots = try #require(IOBluetoothDeviceSource.parse(
            Data(IOBluetoothDeviceSource.sampleJSON.utf8)
        ))
        let pods = try #require(snapshots.first { $0.name.contains("AirPods") })
        #expect(pods.vendorID == 0x004C)
        #expect(pods.productID == 0x2024)
        #expect(pods.isApple, "Apple's own vendor id did not mark the device as Apple's")
        #expect(
            pods.pairedDevice.advertisedModel == 0x2420,
            "the paired device could not be related to the advertisements it broadcasts"
        )
        // And the glyph now comes from the model rather than from a name the
        // user is free to change.
        #expect(pods.symbolName == "airpods.pro")

        let keyboard = try #require(snapshots.first { $0.name == "Wireless Keyboard" })
        #expect(keyboard.vendorID == 0x19F5)
        #expect(!keyboard.isApple)
        #expect(keyboard.pairedDevice.advertisedModel == nil)
    }

    @Test("A device the profiler says is not connected still belongs to the paired list")
    func disconnectedDevicesAreStillPaired() throws {
        let snapshots = try #require(IOBluetoothDeviceSource.parse(
            Data(IOBluetoothDeviceSource.sampleJSON.utf8)
        ))
        let keyboard = try #require(snapshots.first { $0.name == "Wireless Keyboard" })
        #expect(!keyboard.isConnected)
        #expect(
            snapshots.contains { $0.isConnected },
            "the fixture holds no connected device, so this proves nothing"
        )
    }

    @Test("Output that cannot be read is not a Mac with nothing paired")
    func unusableOutputIsNotAnEmptyList() {
        // The difference is the user's data: an empty list is an answer, and
        // the catalogue deletes every record it does not contain. A profiler
        // that printed something unusable used to say exactly that.
        #expect(IOBluetoothDeviceSource.parse(Data("not json at all".utf8)) == nil)
        #expect(IOBluetoothDeviceSource.parse(Data("{\"SomethingElse\":[]}".utf8)) == nil)
        #expect(IOBluetoothDeviceSource.parse(Data("[]".utf8)) == nil)
        // The root alone is not enough: sections holding nothing this
        // recognises are not a reading of anything.
        #expect(IOBluetoothDeviceSource.parse(Data("{\"SPBluetoothDataType\":[]}".utf8)) == nil)
        #expect(
            IOBluetoothDeviceSource.parse(Data("{\"SPBluetoothDataType\":[{\"x\":1}]}".utf8)) == nil
        )
        // A Mac that really is paired with nothing still prints its
        // controller, and that is an answer: an empty one.
        let noDevices = #"{"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"}}]}"#
        #expect(IOBluetoothDeviceSource.parse(Data(noDevices.utf8)) == [])
        // Recognising a familiar key is not the same as having read the
        // list. A device that is listed but cannot be identified is a device
        // the catalogue would never hear about again — and an answer missing
        // a device is what deletes it.
        let noAddress = """
            {"SPBluetoothDataType":[{
              "controller_properties":{"controller_state":"attrib_on"},
              "device_connected":[{"My Pods":{"device_batteryLevelLeft":"70%"}}]
            }]}
            """
        #expect(IOBluetoothDeviceSource.parse(Data(noAddress.utf8)) == nil)

        // A known group that is not even a list.
        let brokenGroup = #"{"SPBluetoothDataType":[{"device_connected":"nonsense"}]}"#
        #expect(IOBluetoothDeviceSource.parse(Data(brokenGroup.utf8)) == nil)

        // One device readable, one not: the readable half alone is a partial
        // list presented as a complete one.
        let halfRead = """
            {"SPBluetoothDataType":[{
              "device_connected":[
                {"Pods":{"device_address":"60:FD:A6:1D:B3:09"}},
                {"Mystery":{"device_batteryLevelLeft":"70%"}}
              ]
            }]}
            """
        #expect(IOBluetoothDeviceSource.parse(Data(halfRead.utf8)) == nil)

    }
}
