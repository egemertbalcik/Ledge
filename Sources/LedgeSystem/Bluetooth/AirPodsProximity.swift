import Foundation

/// A decoded AirPods proximity-pairing advertisement (Apple Continuity message
/// type `0x07`). Only the plaintext prefix is read — battery, charging, and the
/// lid counter; the trailing bytes are encrypted and ignored.
///
/// This is the message AirPods broadcast for the "nearby" pop-up, and it keeps
/// broadcasting on lid open/close even while connected — which is how the case
/// opening can be shown when the ordinary connect/disconnect path sees nothing.
public struct AirPodsProximity: Equatable, Sendable {
    /// Two-byte model id, big-endian (e.g. `0x0E20` = AirPods Pro).
    public let model: UInt16
    /// 0...1, or nil when the cell is absent/undetermined.
    public let leftBattery: Double?
    public let rightBattery: Double?
    public let caseBattery: Double?
    public let isChargingLeft: Bool
    public let isChargingRight: Bool
    public let isChargingCase: Bool
    /// Rolling counter that advances on each lid open/close. A *change* is the
    /// event; the absolute value carries no state.
    public let lidCounter: UInt8

    /// Which physical peripheral advertised this, stamped by the scanner.
    /// The model id alone cannot key lid state: two same-model sets on one
    /// desk interleave their counters and every alternation reads as a lid
    /// event carrying the other set's battery levels.
    public var peripheralID: UUID?

    public init(
        model: UInt16,
        leftBattery: Double?,
        rightBattery: Double?,
        caseBattery: Double?,
        isChargingLeft: Bool,
        isChargingRight: Bool,
        isChargingCase: Bool,
        lidCounter: UInt8
    ) {
        self.model = model
        self.leftBattery = leftBattery
        self.rightBattery = rightBattery
        self.caseBattery = caseBattery
        self.isChargingLeft = isChargingLeft
        self.isChargingRight = isChargingRight
        self.isChargingCase = isChargingCase
        self.lidCounter = lidCounter
    }

    /// A human name for the model, best-effort.
    public var name: String {
        switch model {
        case 0x0220: return "AirPods"
        case 0x0F20: return "AirPods (2nd gen)"
        case 0x1320: return "AirPods (3rd gen)"
        case 0x1920, 0x1B20: return "AirPods (4th gen)"
        case 0x0E20: return "AirPods Pro"
        case 0x1420, 0x2420: return "AirPods Pro (2nd gen)"
        case 0x2720: return "AirPods Pro (3rd gen)"
        case 0x0A20, 0x1F20: return "AirPods Max"
        default: return "AirPods"
        }
    }

    /// The SF Symbol matching the model, for the fallback glyph.
    public var symbolName: String {
        switch model {
        case 0x0A20, 0x1F20: return "airpodsmax"
        case 0x0E20, 0x1420, 0x2420, 0x2720: return "airpods.pro"
        default: return "airpods.gen3"
        }
    }

    /// Battery levels keyed the way `DevicePayload` renders them. Absent cells are
    /// dropped rather than shown as empty.
    public var batteryLevels: [String: Double] {
        var levels: [String: Double] = [:]
        if let leftBattery { levels["Left"] = leftBattery }
        if let rightBattery { levels["Right"] = rightBattery }
        if let caseBattery { levels["Case"] = caseBattery }
        return levels
    }
}

/// Decodes the Apple manufacturer-data blob from a BLE advertisement. Pure and
/// positional, so it is unit-tested against captured byte fixtures without any
/// Bluetooth hardware.
///
/// Layout (after the 2-byte company id `4C 00`), byte 0 = `0x07`:
///  0 type(0x07) · 1 length · 2 prefix · 3–4 model(BE) · 5 status(flip/in-ear)
///  6 pod batteries · 7 charge flags + case battery · 8 lid counter …
public enum AirPodsProximityDecoder {

    /// Apple's Bluetooth SIG company identifier.
    public static let appleCompanyID: UInt16 = 0x004C

    public static func decode(manufacturerData data: Data) -> AirPodsProximity? {
        let bytes = [UInt8](data)
        // Company id (little-endian) + at least the plaintext prefix we read.
        guard bytes.count >= 2 else { return nil }
        let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard company == appleCompanyID else { return nil }

        // Skip the company id; `p[0]` is now the message type.
        let p = Array(bytes[2...])
        guard p.count >= 9, p[0] == 0x07 else { return nil }

        let model = (UInt16(p[3]) << 8) | UInt16(p[4])

        // Flip bit lives in the high nibble of the status byte; when clear the
        // left/right assignments are swapped.
        let statusHigh = (p[5] >> 4)
        let flipped = (statusHigh & 0x02) == 0

        let podByte = p[6]
        let podHigh = Double(podByte >> 4)
        let podLow = Double(podByte & 0x0F)
        let leftNibble = flipped ? podHigh : podLow
        let rightNibble = flipped ? podLow : podHigh

        let chargeByte = p[7]
        let chargeBits = chargeByte >> 4
        let caseNibble = Double(chargeByte & 0x0F)

        // A nibble of 0...10 maps to 0...100%; 15 means the cell is absent. 11–14
        // are treated as full (a rare over-report).
        func level(_ nibble: Double) -> Double? {
            if nibble >= 15 { return nil }
            return min(nibble, 10) / 10.0
        }

        let chargeLeftMask: UInt8 = flipped ? 0b010 : 0b001
        let chargeRightMask: UInt8 = flipped ? 0b001 : 0b010

        return AirPodsProximity(
            model: model,
            leftBattery: level(leftNibble),
            rightBattery: level(rightNibble),
            caseBattery: level(caseNibble),
            isChargingLeft: (chargeBits & chargeLeftMask) != 0,
            isChargingRight: (chargeBits & chargeRightMask) != 0,
            isChargingCase: (chargeBits & 0b100) != 0,
            lidCounter: p[8]
        )
    }
}
