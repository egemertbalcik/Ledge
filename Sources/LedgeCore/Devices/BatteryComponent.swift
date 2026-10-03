import Foundation

/// Which battery a reading belongs to.
///
/// Sources spell these differently — CoreBluetooth manufacturer data, the
/// system profiler's JSON, and a proximity advertisement all have their own
/// words for the same earbud. Normalising in one place is what lets a rule
/// about "the left bud" mean the same thing whichever source saw it.
///
/// `other` carries the source's own label so an unrecognised component
/// survives a round trip instead of being dropped or crashing a decode. A
/// device with a battery nobody has taught this app about should still appear,
/// still chart, and still be alertable.
public enum BatteryComponent: Hashable, Sendable, Codable {

    /// The one battery a device has, when it has only one.
    case main
    case left
    case right
    case `case`
    /// Something this app does not recognise, kept verbatim.
    case other(String)

    /// The spelling a source used, normalised.
    ///
    /// Deliberately forgiving about case and whitespace and nothing else:
    /// guessing beyond that is how "Case" and "Chassis" end up as one battery.
    public init(label: String) {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "main", "battery", "single", "device": self = .main
        case "left", "l": self = .left
        case "right", "r": self = .right
        case "case", "charging case": self = .case
        default: self = .other(label.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The label this app uses when it has to write one down.
    public var label: String {
        switch self {
        case .main: "Main"
        case .left: "Left"
        case .right: "Right"
        case .case: "Case"
        case .other(let raw): raw
        }
    }

    /// The order components are shown in, so two ears never swap places
    /// between renders.
    public var sortOrder: Int {
        switch self {
        case .main: 0
        case .left: 1
        case .right: 2
        case .case: 3
        case .other: 4
        }
    }

    /// Whether this battery is one the user is *wearing* — the ones whose
    /// dying mid-use is worth interrupting for. A case at 15% while the buds
    /// are full is not that.
    public var isInUse: Bool {
        switch self {
        case .main, .left, .right: true
        case .case, .other: false
        }
    }

    // MARK: - Codable

    /// Encoded as its label, so the stored form is readable and an unknown
    /// component round-trips as itself.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(label: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}
