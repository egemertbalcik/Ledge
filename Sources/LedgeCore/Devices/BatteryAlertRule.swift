import Foundation

/// Where an alert is shown.
public struct AlertDelivery: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let notch = AlertDelivery(rawValue: 1 << 0)
    /// A macOS notification. Choosing this is what asks for permission —
    /// never before, and never merely by opening this pane.
    public static let notification = AlertDelivery(rawValue: 1 << 1)

    public static let both: AlertDelivery = [.notch, .notification]
}

/// What a rule watches for.
public enum AlertKind: String, Hashable, Sendable, Codable {
    /// Falling to or below a threshold.
    case low
    /// Rising to or above a threshold, while charging.
    case charged
}

/// One user-configured rule for one device, optionally one component.
public struct BatteryAlertRule: Hashable, Sendable, Codable, Identifiable {

    public var id: UUID
    public var kind: AlertKind
    /// nil means "any battery the user is wearing" — the in-use components,
    /// which is what the default low alert has always meant.
    public var component: BatteryComponent?
    public var isEnabled: Bool
    public var delivery: AlertDelivery

    /// 0...1. Stored values are clamped on the way in: a preference file that
    /// has been hand-edited, or migrated from a future version, must not be
    /// able to arm a rule at 4000%.
    public private(set) var threshold: Double

    public init(
        id: UUID = UUID(),
        kind: AlertKind,
        component: BatteryComponent? = nil,
        threshold: Double,
        isEnabled: Bool = true,
        delivery: AlertDelivery = .notch
    ) {
        self.id = id
        self.kind = kind
        self.component = component
        self.isEnabled = isEnabled
        self.delivery = delivery
        self.threshold = Self.clamp(threshold, kind: kind)
    }

    public mutating func setThreshold(_ value: Double) {
        threshold = Self.clamp(value, kind: kind)
    }

    /// Thresholds are clamped into the band where they can mean something.
    /// A "low" alert at 100% would fire forever; a "charged" alert at 5%
    /// would fire the moment anything is plugged in.
    static func clamp(_ value: Double, kind: AlertKind) -> Double {
        guard value.isFinite else { return kind == .low ? 0.2 : 1.0 }
        switch kind {
        case .low: return min(max(value, 0.05), 0.5)
        case .charged: return min(max(value, 0.5), 1.0)
        }
    }

    /// How far a level must recover before a fired low alert can fire again.
    /// Without it a device hovering on the threshold alerts on every reading.
    public static let hysteresis: Double = 0.05

    /// The identity of the built-in rule.
    ///
    /// Fixed, and that is the whole point. The "have I already said this"
    /// latch is keyed by rule, so a default rule that minted a fresh UUID each
    /// time it was asked for would never match its own latch — and the alert
    /// it exists for would fire again on every single reading below the
    /// threshold. Caught by the hysteresis test, which is the only one that
    /// looks at the same rule across four observations.
    public static let defaultLowID = UUID(uuidString: "8E2F5C10-0000-4000-A000-000000000001")!

    /// What Ledge has always done, for anyone who has never opened this pane:
    /// one low alert at 20%, in the notch, across the batteries being worn.
    public static func defaultLow() -> BatteryAlertRule {
        BatteryAlertRule(
            id: defaultLowID, kind: .low, component: nil,
            threshold: 0.2, delivery: .notch
        )
    }
}

/// Every rule for one device.
public struct DeviceAlertConfiguration: Hashable, Sendable, Codable {

    public var rules: [BatteryAlertRule]
    /// True once the user has touched this device's rules. Until then the
    /// device is running on the built-in default and must migrate silently.
    public var isCustomised: Bool

    public init(rules: [BatteryAlertRule] = [], isCustomised: Bool = false) {
        self.rules = rules
        self.isCustomised = isCustomised
    }

    /// The rules actually in force for a device.
    ///
    /// The built-in 20% rule stands in for what `BluetoothProvider` used to do
    /// itself, so it applies to the devices whose alerting that provider
    /// owned — and to nothing else.
    ///
    /// **This Mac is deliberately excluded.** Its battery warnings belong to
    /// `BatteryProvider`, which has its own low *and* critical thresholds,
    /// its own charging transitions and its own startup suppression. Handing
    /// the Mac a catalogue rule as well produced two cards for one dip.
    public func effectiveRules(for id: DeviceIdentity) -> [BatteryAlertRule] {
        guard isCustomised else {
            return id.ownsItsOwnAlerting ? [] : [BatteryAlertRule.defaultLow()]
        }
        return rules.filter(\.isEnabled)
    }

    /// Charged alerts are never on unless the user turned one on.
    public static let untouched = DeviceAlertConfiguration()
}
