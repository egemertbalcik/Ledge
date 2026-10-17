import Foundation
import Testing

@testable import LedgeSystem

@Suite("AirPods proximity decode")
struct AirPodsProximityTests {

    /// Company id `4C 00`, then proximity payload: type 07, len 19, paired 01,
    /// model 0E20 (AirPods Pro), status 20 (not flipped), pods 87, charge/case
    /// 05, lid 01.
    ///
    /// Padded out to the 25 bytes the length byte declares, the way the air
    /// carries it: the seven plaintext fields, then the encrypted remainder
    /// this decoder never reads. The fixtures used to stop after the seventh
    /// byte while still claiming 25, which is exactly the shape the decoder
    /// now refuses.
    private func packet(_ tail: [UInt8]) -> Data {
        var bytes = tail
        if bytes.count >= 2 {
            let declared = Int(bytes[1])
            let payload = bytes.count - 2
            if payload < declared {
                bytes += [UInt8](repeating: 0, count: declared - payload)
            }
        }
        return Data([0x4C, 0x00] + bytes)
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

    @Test("A record that claims more than it carries is refused")
    func refusesATruncatedRecord() {
        // Declares 25 payload bytes, carries seven. This is what a mangled or
        // chopped record looks like, and reading it meant every field after
        // the break came from whatever followed in the buffer — which is how
        // the catalogue filled up with models no AirPods has ever advertised.
        let truncated = Data([0x4C, 0x00] + [0x07, 0x19, 0x01, 0x0E, 0x20, 0x20, 0x87, 0x05, 0x01])
        #expect(AirPodsProximityDecoder.decode(manufacturerData: truncated) == nil)
        // The same bytes, with the record telling the truth about its length,
        // are read.
        let honest = Data([0x4C, 0x00] + [0x07, 0x07, 0x01, 0x0E, 0x20, 0x20, 0x87, 0x05, 0x01])
        #expect(AirPodsProximityDecoder.decode(manufacturerData: honest)?.model == 0x0E20)
    }

    @Test("A record that declares less than the fields it holds is refused")
    func refusesAnImpossibleLength() {
        // Zero, and six: both say this is not the message whose seven fields
        // the decoder is about to read.
        for declared: UInt8 in [0x00, 0x06] {
            let data = Data(
                [0x4C, 0x00] + [0x07, declared, 0x01, 0x0E, 0x20, 0x20, 0x87, 0x05, 0x01]
            )
            #expect(
                AirPodsProximityDecoder.decode(manufacturerData: data) == nil,
                "a payload of \(declared) bytes cannot hold seven"
            )
        }
    }

    @Test("Signal strength is not part of what makes a reading news")
    func strengthIsNotNews() {
        // The scanner holds its listening window open on change. Strength
        // wobbles by a few dB between otherwise identical advertisements, and
        // counting that as news held the most expensive scan mode open for as
        // long as AirPods sat on the desk.
        let data = packet([0x07, 0x19, 0x01, 0x0E, 0x20, 0x20, 0x87, 0x05, 0x01])
        var a = AirPodsProximityDecoder.decode(manufacturerData: data)
        var b = a
        a?.rssi = -44
        b?.rssi = -61
        #expect(a == b)

        // Anything the record actually says is still news, at any strength.
        var moved = AirPodsProximityDecoder.decode(
            manufacturerData: packet([0x07, 0x19, 0x01, 0x0E, 0x20, 0x20, 0x87, 0x05, 0x02])
        )
        moved?.rssi = -44
        #expect(moved != a)
    }
}
