import Foundation
import Testing

@testable import LedgeCore

/// Ownership, as a value. No radio, no catalogue — just the rule that decides
/// whose hardware a thing is.
@Suite("Paired devices")
struct PairedDeviceTests {

    private static func airPodsPro(
        address: String = "60:FD:A6:1D:B3:09",
        name: String = "Ege Mert’s AirPods Pro"
    ) -> PairedDevice {
        PairedDevice(
            address: address, name: name, isConnected: false,
            vendorID: 0x004C, productID: 0x2024
        )
    }

    @Test("An address is comparable whichever source printed it")
    func addressesNormalise() {
        let upperColons = PairedDevice(address: "08:5D:53:A9:D9:3E", name: "Ege AirPods")
        let lowerDashes = PairedDevice(address: "08-5d-53-a9-d9-3e", name: "Ege AirPods")
        #expect(upperColons.address == lowerDashes.address)
        #expect(upperColons.identity == DeviceIdentity.bluetooth("08:5d:53:a9:d9:3e"))
    }

    /// The link the catalogue was missing. Taken from this Mac's own paired
    /// list: "Ege Mert's AirPods Pro" reports product `0x2024` and advertises
    /// model `0x2420`.
    @Test("A reported product id is the model id its advertisements carry, byte for byte")
    func productIDIsTheAdvertisedModel() {
        #expect(Self.airPodsPro().advertisedModel == 0x2420)
        #expect(
            PairedDevice(
                address: "08:5D:53:A9:D9:3E", name: "Ege AirPods",
                vendorID: 0x004C, productID: 0x201B
            ).advertisedModel == 0x1B20
        )
    }

    @Test("Nothing is read as an Apple model without Apple's vendor id")
    func nonAppleHasNoModel() {
        // A Samsung monitor whose product id would byte-swap into something
        // that looks like an AirPods model if nobody checked the vendor.
        let monitor = PairedDevice(
            address: "B0:E4:5C:0A:EF:61", name: "27\" Smart Monitor M5",
            vendorID: 0x04E8, productID: 0x2024
        )
        #expect(monitor.advertisedModel == nil)
        // And a device macOS reports no ids for at all.
        #expect(PairedDevice(address: "aa:bb:cc:dd:ee:ff", name: "BT5.1 Mouse")
            .advertisedModel == nil)
    }

    @Test("An advertisement finds the one paired device that claims its model")
    func ownerIsFound() {
        let answer = PairedDeviceRegistry.Answer(
            devices: [
                Self.airPodsPro(),
                PairedDevice(
                    address: "08:5D:53:A9:D9:3E", name: "Ege AirPods",
                    vendorID: 0x004C, productID: 0x201B
                ),
                PairedDevice(address: "04:41:A5:97:A6:0D", name: "Magic Trackpad"),
            ],
            generation: 1, at: Date()
        )
        #expect(answer.airPodsOwner(ofModel: 0x2420)?.name == "Ege Mert’s AirPods Pro")
        #expect(answer.airPodsOwner(ofModel: 0x1B20)?.name == "Ege AirPods")
        // A stranger's earbuds in the same room: a real Apple model, paired
        // with somebody else's Mac.
        #expect(answer.airPodsOwner(ofModel: 0x0E20) == nil)
    }

    /// A model id is not a serial number, and the cost of pretending otherwise
    /// is one set's battery shown on the other's row.
    @Test("Two paired sets of the same model match nothing rather than one of them")
    func ambiguousModelMatchesNothing() {
        let answer = PairedDeviceRegistry.Answer(
            devices: [
                Self.airPodsPro(address: "60:FD:A6:1D:B3:09", name: "Mine"),
                Self.airPodsPro(address: "60:FD:A6:1D:B3:0A", name: "Also mine"),
            ],
            generation: 1, at: Date()
        )
        #expect(answer.devices.count == 2, "the fixture did not hold two same-model sets")
        #expect(answer.airPodsOwner(ofModel: 0x2420) == nil)
    }

    /// The trap this type exists for: "nobody has asked" and "paired with
    /// nothing" are different answers, and only one of them may delete
    /// anything.
    @Test("An unanswered registry is not an empty one")
    func absenceIsNotEmptiness() {
        let registry = PairedDeviceRegistry()
        #expect(registry.current == nil)

        registry.answer([])
        let answered = registry.current
        #expect(answered != nil, "an empty paired list is still an answer")
        #expect(answered?.devices.isEmpty == true)
    }

    @Test("Each reading is told apart from the one before it")
    func generationsAdvance() {
        let registry = PairedDeviceRegistry()
        registry.answer([Self.airPodsPro()])
        let first = registry.current?.generation
        registry.answer([Self.airPodsPro()])
        #expect(registry.current?.generation == (first ?? 0) + 1)
    }
}
