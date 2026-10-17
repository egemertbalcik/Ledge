import Foundation
import LedgeCore
import Testing

/// How long a reading describes *now*.
///
/// It follows the thing that reported it, not the key the record is filed
/// under. Proximity readings are attached to the paired device's own record —
/// which is re-read every ten minutes and allowed thirty — and an
/// advertisement is stale after five minutes of silence wherever it landed.
@Suite("A reading's freshness")
struct ReadingFreshnessTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func record(_ reading: BatteryReading) -> DeviceRecord {
        DeviceRecord(
            id: .bluetooth("60:fd:a6:1d:b3:09"),
            name: "Ege’s AirPods Pro",
            presence: .unknown,
            readings: [reading],
            firstSeen: t0,
            lastSeen: t0
        )
    }

    private static func reading(origin: DeviceIdentity.Source?) -> BatteryReading {
        BatteryReading(
            component: .left, level: 0.7, charging: .notCharging,
            observedAt: t0, origin: origin
        )
    }

    @Test("An advertisement goes stale on the air's clock, not the list's")
    func advertisementFreshness() {
        let record = Self.record(Self.reading(origin: .proximityName))
        let six = Self.t0.addingTimeInterval(6 * 60)
        #expect(!record.isCurrent(record.readings[0], now: six))
        let four = Self.t0.addingTimeInterval(4 * 60)
        #expect(record.isCurrent(record.readings[0], now: four))
    }

    @Test("A reading from the paired list keeps the list's longer allowance")
    func listFreshness() {
        // Unstamped: it came from the same place the record's identity did.
        let record = Self.record(Self.reading(origin: nil))
        let six = Self.t0.addingTimeInterval(6 * 60)
        #expect(record.isCurrent(record.readings[0], now: six))
        let twentyNine = Self.t0.addingTimeInterval(29 * 60)
        #expect(record.isCurrent(record.readings[0], now: twentyNine))
        let thirtyOne = Self.t0.addingTimeInterval(31 * 60)
        #expect(!record.isCurrent(record.readings[0], now: thirtyOne))
    }

    @Test("One advertisement and then silence is not current half an hour later")
    func theRegression() {
        // What this was written for: a lone advertisement, attached to a
        // Bluetooth identity, still presented as the device's current battery
        // at 29 minutes.
        let record = Self.record(Self.reading(origin: .proximityName))
        let twentyNine = Self.t0.addingTimeInterval(29 * 60)
        #expect(!record.isCurrent(record.readings[0], now: twentyNine))
    }
}
