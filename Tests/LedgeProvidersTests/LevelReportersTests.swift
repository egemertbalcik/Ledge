import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders

/// Which devices are worth holding a hello for is remembered across launches
/// by asking the catalogue what it has already seen. Nothing new is read.
@Suite("Which devices have ever reported a battery")
struct LevelReportersTests {

    private let then = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func record(_ id: DeviceIdentity, levels: [Double]) -> DeviceRecord {
        DeviceRecord(
            id: id, name: "Device",
            readings: levels.map {
                BatteryReading(component: BatteryComponent(label: "Battery"), level: $0, observedAt: then)
            },
            firstSeen: then, lastSeen: then
        )
    }

    @Test("Only Bluetooth devices that have a reading")
    func onlyBluetoothWithReadings() {
        let catalogue = DeviceCatalogue(devices: [
            record(.bluetooth("AA:BB:CC:00:00:01"), levels: [0.6]),
            record(.bluetooth("AA:BB:CC:00:00:02"), levels: []),
            record(.peripheral(UUID()), levels: [0.9]),
            record(.thisMac, levels: [0.5]),
        ])
        #expect(DeviceObservations.bluetoothAddressesWithLevels(in: catalogue) == ["aa:bb:cc:00:00:01"])
    }

    @Test("An empty catalogue remembers nobody")
    func emptyCatalogue() {
        #expect(DeviceObservations.bluetoothAddressesWithLevels(in: DeviceCatalogue()).isEmpty)
    }
}
