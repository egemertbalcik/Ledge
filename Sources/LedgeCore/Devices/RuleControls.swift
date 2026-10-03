import Foundation

/// Which controls on an alert row are usable.
///
/// A charged alert for a battery that never reports whether it is charging can
/// never fire. The row still has to be *repairable* — the user chose another
/// battery, or removes the rule — so only the controls whose action is
/// impossible are dimmed. Disabling the whole row took Delete and the battery
/// picker with it, which left some decoded rules impossible to fix.
public struct RuleControls: Equatable, Sendable {

    /// Whether this rule could ever fire as configured.
    public let canFire: Bool

    public init(rule: BatteryAlertRule, componentReportsCharging: Bool) {
        canFire = rule.kind != .charged || componentReportsCharging
    }

    /// Switching a rule on that cannot fire would claim an alert the hardware
    /// can never give.
    public var canEnable: Bool { canFire }

    /// A threshold for an alert that cannot fire is a number with no meaning.
    public var canEditThreshold: Bool { canFire }

    /// Delivery destinations, likewise.
    public var canChooseDelivery: Bool { canFire }

    /// Previewing shows what an alert would look like; for one that cannot
    /// happen it is a button that promises something untrue.
    public var canPreview: Bool { canFire }

    /// Always: choosing a battery that *does* report charging is how the rule
    /// is repaired.
    public var canChooseBattery: Bool { true }

    /// Always: removing it is the other way out.
    public var canDelete: Bool { true }
}
