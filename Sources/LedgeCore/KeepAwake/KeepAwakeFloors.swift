import Foundation

/// How hot the Mac is, as Keep Awake cares about it.
///
/// Its own enum rather than `ProcessInfo.ThermalState` so LedgeCore stays pure
/// and the decision table can be exercised without a Mac that is actually hot.
public enum KeepAwakeThermal: Int, Equatable, Sendable, Codable, CaseIterable, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the battery looks like to the floors.
///
/// `charging` is a three-way answer on purpose. "We could not tell" is not
/// "it is plugged in": treating an unknown charger as charging would let a Mac
/// on battery run to empty, so unknown is handled as if it were on battery.
public struct KeepAwakeBattery: Equatable, Sendable {
    public var percentage: Int?
    public var charging: Bool?
    /// Whether the Mac has a battery at all. A desktop has no floor to hit.
    public var isPresent: Bool

    public init(percentage: Int?, charging: Bool?, isPresent: Bool = true) {
        self.percentage = percentage
        self.charging = charging
        self.isPresent = isPresent
    }
}

/// The conditions that end a running session on their own.
///
/// Pure and table-driven so every combination can be tested: a floor that only
/// runs on real hardware is a floor nobody has checked.
public enum KeepAwakeFloors {

    public enum Decision: Equatable, Sendable {
        case keepGoing
        case end(KeepAwakeEndReason)
    }

    /// How many consecutive unreadable battery readings are tolerated.
    ///
    /// One miss is a hiccup in the power source; two in a row means Ledge no
    /// longer knows how much battery is left, and holding a Mac awake on a
    /// number nobody can read is how a laptop in a bag runs flat.
    public static let unreadableLimit = 2

    /// - Parameters:
    ///   - missCount: consecutive failures to read the battery, including this
    ///     reading.
    ///   - lidClosed: phase 2. A closed Mac cannot shed heat and nobody can see
    ///     it, so the thermal floor is stricter.
    ///   - enforcesUnreadable: the unreadable-battery floor only applies when
    ///     the lid hold was asked for. With the lid open the user can see their
    ///     own battery; ending their session over a failed read would be Ledge
    ///     being jumpy about a number it did not need.
    public static func decide(
        battery: KeepAwakeBattery,
        floor: Int,
        missCount: Int,
        thermal: KeepAwakeThermal,
        lidClosed: Bool,
        enforcesUnreadable: Bool
    ) -> Decision {
        // Heat first: it is the only floor that is about the hardware rather
        // than about running out of something.
        if thermal == .critical { return .end(.thermal) }
        if lidClosed, thermal >= .serious { return .end(.thermal) }

        guard battery.isPresent else { return .keepGoing }

        guard let percentage = battery.percentage else {
            guard enforcesUnreadable, missCount >= unreadableLimit else { return .keepGoing }
            return .end(.batteryUnreadable)
        }

        // Unknown charger counts as battery, per the type's own note.
        let onBattery = battery.charging != true
        if onBattery, percentage <= floor { return .end(.batteryFloor) }
        return .keepGoing
    }
}
