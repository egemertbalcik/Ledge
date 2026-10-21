import Foundation
import LedgeCore
import LedgeSystem
import Testing

@testable import LedgeProviders

/// A scanner that reports exactly what a test hands it.
@MainActor
private final class InertScanner: ProximityScanning {
    var onUpdate: (AirPodsProximity) -> Void = { _ in }
    var isOurs: (AirPodsProximity) -> Bool = { _ in true }
    private(set) var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
}

/// What the lid card claims.
///
/// An advertisement proves a pair of earbuds is in range. It says nothing
/// about whether they are attached to this Mac — a case opening on the desk
/// is the same broadcast whether its pods are connected to the Mac, to a
/// phone, or to nothing — and the card prints that claim in a word under the
/// name.
@MainActor
@Suite("The lid card's connection claim")
struct ProximityCardTests {

    private static let ownPods = PairedDevice(
        address: "60:FD:A6:1D:B3:09", name: "Ege Mert’s AirPods Pro",
        isConnected: false, vendorID: 0x004C, productID: 0x2024
    )

    /// One peripheral for the whole test: lid state is kept per device, and
    /// a fresh identifier reads as a device nobody has a baseline for.
    private static let peripheral = UUID()

    private static func advert(lid: UInt8) -> AirPodsProximity {
        var proximity = AirPodsProximity(
            model: 0x2420,
            leftBattery: 0.7, rightBattery: 0.8, caseBattery: 0.5,
            isChargingLeft: false, isChargingRight: false, isChargingCase: true,
            lidCounter: lid
        )
        proximity.peripheralID = peripheral
        proximity.rssi = -40
        return proximity
    }

    /// Drives the provider the way the scanner does, and hands back the first
    /// card it published.
    ///
    /// No clock in it. The card is yielded inside the scanner's callback, so
    /// it is already in the stream when the second advertisement has been
    /// handed over; stopping finishes the stream, and reading it to the end
    /// collects what was published. This used to wait for a reader task
    /// against a five-second wall-clock deadline, which the full suite beat
    /// whenever it kept the reader from being scheduled for longer than that —
    /// the main-actor loop ran out of time while the card sat unread.
    private func card(paired devices: [PairedDevice]?) async -> DevicePayload? {
        let registry = PairedDeviceRegistry()
        if let devices { registry.answer(devices) }
        // A scanner that never touches the radio. The real one only stays
        // inert when the machine running the test has no Bluetooth grant,
        // which is not something a test may depend on.
        let scanner = InertScanner()
        let provider = AirPodsProximityProvider(scanner: scanner, paired: registry, now: { 0 })
        let stream = provider.start()

        // The first sighting is a baseline; the second is the lid event.
        scanner.onUpdate(Self.advert(lid: 1))
        scanner.onUpdate(Self.advert(lid: 2))
        provider.stop()

        for await event in stream {
            if case .publish(let activity) = event, case .device(let payload) = activity.payload {
                return payload
            }
        }
        return nil
    }

    @Test("It says connected when the system says the device is connected")
    func connected() async {
        var pods = Self.ownPods
        pods.isConnected = true
        let payload = await card(paired: [pods])
        #expect(payload?.isConnected == true)
    }

    @Test("It says disconnected when the system says it is not")
    func disconnected() async {
        let payload = await card(paired: [Self.ownPods])
        #expect(payload?.isConnected == false)
    }

    @Test("It says nothing when nobody knows")
    func unknown() async {
        // No paired list has been read, so nothing can say whether these
        // earbuds are attached to anything. The card used to print
        // "Connected" here, from a literal `true`.
        let payload = await card(paired: nil)
        #expect(payload != nil, "the card inside the ownership grace was withheld")
        #expect(payload?.isConnected == nil)
    }
}
