import Foundation
import Testing

@testable import LedgeSystem

@Suite("AirPods proximity decode")
struct AirPodsProximityTests {

    /// Company id `4C 00`, then proximity payload: type 07, len 19, paired 01,
    /// model 0E20 (AirPods Pro), status 20 (not flipped), pods 87, charge/case
    /// 05, lid 01.
    private func packet(_ tail: [UInt8]) -> Data {
        Data([0x4C, 0x00] + tail)
    }

    @Test("Decodes model, batteries, and lid without a flip")
    func decodesUnflipped() {
        let data = packet([0x07, 0x19, 0x01, 0x0E, 0x20, 0x20, 0x87, 0x05, 0x01])
        let prox = AirPodsProximityDecoder.decode(manufacturerData: data)
        #expect(prox?.model == 0x0E20)
        #expect(prox?.name == "AirPods Pro")
        #expect(prox?.leftBattery == 0.7)
        #expect(prox?.rightBattery == 0.8)
        #expect(prox?.caseBattery == 0.5)
        #expect(prox?.lidCounter == 1)
        #expect(prox?.isChargingLeft == false)
    }

    @Test("The flip bit swaps left and right")
    func flipSwapsSides() {
        // status 0x00 → high nibble 0 → flipped.
        let data = packet([0x07, 0x19, 0x01, 0x0E, 0x20, 0x00, 0x87, 0x05, 0x01])
        let prox = AirPodsProximityDecoder.decode(manufacturerData: data)
        // Flipped: left takes the high nibble (8), right the low (7).
        #expect(prox?.leftBattery == 0.8)
        #expect(prox?.rightBattery == 0.7)
    }

    @Test("A nibble of 15 means the cell is absent")
    func fifteenIsAbsent() {
        // Pods byte F7: high nibble 15 (right, unflipped) → nil; low 7 → 70%.
        let data = packet([0x07, 0x19, 0x01, 0x0E, 0x20, 0x20, 0xF7, 0x05, 0x01])
        let prox = AirPodsProximityDecoder.decode(manufacturerData: data)
        #expect(prox?.leftBattery == 0.7)
        #expect(prox?.rightBattery == nil)
    }

    @Test("Charging bits are read")
    func chargingBits() {
        // charge/case 0x35 → charge bits 3 (0b011), case 5. Unflipped: left mask
        // 0b001, right mask 0b010 → both charging.
        let data = packet([0x07, 0x19, 0x01, 0x0E, 0x20, 0x20, 0x87, 0x35, 0x01])
        let prox = AirPodsProximityDecoder.decode(manufacturerData: data)
        #expect(prox?.isChargingLeft == true)
        #expect(prox?.isChargingRight == true)
        #expect(prox?.isChargingCase == false)
    }

    @Test("Non-Apple or non-proximity data is rejected")
    func rejectsOther() {
        // Wrong company id.
        #expect(AirPodsProximityDecoder.decode(manufacturerData: Data([0x99, 0x00, 0x07, 0x19])) == nil)
        // Apple, but not a proximity message.
        #expect(AirPodsProximityDecoder.decode(manufacturerData: Data([0x4C, 0x00, 0x10, 0x02])) == nil)
        // Too short.
        #expect(AirPodsProximityDecoder.decode(manufacturerData: Data([0x4C, 0x00])) == nil)
    }
}
