import Foundation

/// What the engine decided should be shown.
public struct BatteryAlert: Hashable, Sendable {
    public var ruleID: UUID
    public var kind: AlertKind
    public var deviceID: DeviceIdentity
    public var deviceName: String
    public var component: BatteryComponent
    public var level: Double
    /// The threshold of the rule that fired.
    ///
    /// Carried so two rules the user deliberately set on one device — "tell me
    /// at 30%, and again at 10%" — can be told apart when a single reading
    /// crosses both. The *level* cannot do it: both alerts carry the same
    /// reading, which is why matching on it swallowed the second.
    public var threshold: Double
    public var delivery: AlertDelivery
    public var firedAt: Date

    /// The device's own styling and full battery picture, so a replacement
    /// card looks like the card it replaced. Filled in by the catalogue,
    /// which is the only thing that knows them.
    public var symbolName: String = "headphones"
    public var isApple: Bool = false
    public var allLevels: [String: Double] = [:]

    public init(
        ruleID: UUID,
        kind: AlertKind,
        deviceID: DeviceIdentity,
        deviceName: String,
        component: BatteryComponent,
        level: Double,
        threshold: Double,
        delivery: AlertDelivery,
        firedAt: Date
    ) {
        self.ruleID = ruleID
        self.kind = kind
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.component = component
        self.level = level
        self.threshold = threshold
        self.delivery = delivery
        self.firedAt = firedAt
    }
}

/// Per-component memory of what has already been said.
///
/// Persisted alongside the catalogue, because the whole point is that a
/// restart, a reconnect or a wake does not say it again.
public struct ComponentAlertState: Hashable, Sendable, Codable {
    /// The last actionable level seen. nil until the first one — which is the
    /// baseline, and is deliberately silent.
    public var lastLevel: Double?
    /// Rules that have fired and have not yet rearmed.
    public var firedRuleIDs: Set<UUID>
    public var lastObservedAt: Date?

    public init(
        lastLevel: Double? = nil,
        firedRuleIDs: Set<UUID> = [],
        lastObservedAt: Date? = nil
    ) {
        self.lastLevel = lastLevel
        self.firedRuleIDs = firedRuleIDs
        self.lastObservedAt = lastObservedAt
    }
}

/// Decides when a battery alert should be shown. Pure, and told the time.
///
/// Everything that could make this fire twice lives here rather than in the
/// delivery: a provider restarting, a device reconnecting, an advertisement
/// repeating, a periodic refresh, a wake from sleep. All of those produce
/// another observation of a level that has not changed, and none of them is
/// news.
///
/// Deliberately knows nothing about the notch, notifications, or permission.
/// It returns decisions; showing them is somebody else's job.
///
/// **Sleep.** The fired-latch is persisted, so a threshold crossed while the
/// Mac was asleep is noticed once at wake and never repeated. A device that
/// had already alerted before sleeping stays quiet. The alternative —
/// re-baselining on wake — would swallow the genuine "your headphones went
/// flat overnight", which is the one case the alert exists for.
public enum BatteryAlertEngine {

    /// How long an identical alert is suppressed across *different* records.
    ///
    /// The same AirPods can enter the catalogue twice: once by Bluetooth
    /// address from the paired list, once by CoreBluetooth UUID from an
    /// advertisement. There is no dependable identifier relating the two, and
    /// merging on a matching name would be exactly the mistake that makes two
    /// identical sets of earbuds one device — so the records stay separate.
    ///
    /// What must not happen twice is the *alert*. This is a delivery guard,
    /// not an identity claim: it says "something with this name and this
    /// battery already raised this, a moment ago", which is true regardless of
    /// whether the two records are one device.
    public static let duplicateAlertWindow: TimeInterval = 5 * 60

    /// Drops an alert that repeats one already delivered for the same name,
    /// component and kind inside the window.
    public static func withoutDuplicates(
        _ alerts: [BatteryAlert],
        recent: [BatteryAlert],
        now: Date
    ) -> [BatteryAlert] {
        let live = recent.filter { now.timeIntervalSince($0.firedAt) <= duplicateAlertWindow }
        // Only what *other records* have already said. Two rules belonging to
        // one record are two things the user asked for — "tell me at 30%, and
        // again at 10%" — and collapsing them threw one away even when their
        // thresholds differed, because the levels were identical. Suppression
        // is for one physical device wearing two records, which is a different
        // record id by definition.
        return alerts.filter { alert in
            !live.contains { other in
                other.deviceID != alert.deviceID && Signature(other) == Signature(alert)
            }
        }
    }

    /// What makes two alerts "the same" for the purpose above. Deliberately
    /// not the device identity — that is the whole point.
    ///
    /// The *threshold* is part of it, and has to be. Two rules on one device
    /// at different thresholds — "tell me at 30%, and again at 10%" — are two
    /// things the user asked for, and one reading crossing both must deliver
    /// both. Matching on name, component and kind alone threw the second away,
    /// and matching on the level cannot help: both alerts carry the same
    /// reading. Two *records* of the same physical device, meanwhile, raise
    /// the same rule at the same threshold, which is what this collapses.
    struct Signature: Hashable {
        let name: String
        let component: BatteryComponent
        let kind: AlertKind
        let threshold: Double

        init(_ alert: BatteryAlert) {
            name = alert.deviceName
            component = alert.component
            kind = alert.kind
            threshold = alert.threshold
        }
    }

    /// - Parameters:
    ///   - state: what has already been said about each component.
    ///   - observation: the reading that just arrived.
    ///   - configuration: the rules in force for this device.
    /// - Returns: the alerts to show, and the state to remember.
    /// - Parameter isAttaching: true when this observation *is* the device
    ///   attaching — a connect event, rather than a passive sighting or the
    ///   first reading after launch. A device that connects already below the
    ///   threshold is news even though there is no previous level to have
    ///   crossed: putting in earbuds at 12% is exactly when a warning earns
    ///   its keep, and the shipped app warned there. A passive first sighting
    ///   stays silent, so launching with a low device connected does not
    ///   announce a level the user can already see.
    public static func evaluate(
        state: [BatteryComponent: ComponentAlertState],
        observation: DeviceObservation,
        configuration: DeviceAlertConfiguration,
        isAttaching: Bool = false
    ) -> (alerts: [BatteryAlert], state: [BatteryComponent: ComponentAlertState]) {

        var state = state
        var alerts: [BatteryAlert] = []
        let rules = configuration.effectiveRules(for: observation.deviceID)

        for reading in observation.readings.sorted(by: { $0.component.sortOrder < $1.component.sortOrder }) {
            // Stale, unreliable or malformed readings update nothing and
            // trigger nothing. A value nobody should act on must not become
            // the baseline a later crossing is measured against either.
            guard reading.isActionable else { continue }

            var componentState = state[reading.component] ?? ComponentAlertState()
            let previous = componentState.lastLevel

            for rule in rules where applies(rule, to: reading.component) {
                switch rule.kind {
                case .low:
                    // Recovery first, so a rule can rearm and fire in the same
                    // pass only if the level genuinely went up and back down
                    // between two observations — which it cannot.
                    if reading.level > rule.threshold + BatteryAlertRule.hysteresis {
                        componentState.firedRuleIDs.remove(rule.id)
                        continue
                    }
                    guard reading.level <= rule.threshold else { continue }
                    if isAttaching {
                        // An attach is an event in its own right: putting
                        // earbuds in at 12% is worth saying whether or not
                        // there was a previous reading to cross from. The
                        // fired latch below is what stops it being said again
                        // on the next reconnection.
                    } else if let previous {
                        // Ordinarily a crossing: it must have been above.
                        guard previous > rule.threshold else { continue }
                    } else {
                        // A passive first sighting — a startup inventory, a
                        // refresh, an advertisement — is the quiet baseline.
                        continue
                    }
                    guard !componentState.firedRuleIDs.contains(rule.id) else { continue }

                    componentState.firedRuleIDs.insert(rule.id)
                    alerts.append(alert(rule: rule, observation: observation, reading: reading))

                case .charged:
                    // Charging evidence is required, not inferred. A source
                    // that only reports a level cannot tell a full battery
                    // from one that has been sitting at full since yesterday.
                    guard reading.charging == .charging else {
                        // No longer charging: the next charge may alert again.
                        if reading.charging == .notCharging {
                            componentState.firedRuleIDs.remove(rule.id)
                        }
                        continue
                    }
                    guard let previous else { continue }          // baseline is silent
                    guard previous < rule.threshold else { continue }  // must be a crossing
                    guard reading.level >= rule.threshold else { continue }
                    guard !componentState.firedRuleIDs.contains(rule.id) else { continue }

                    componentState.firedRuleIDs.insert(rule.id)
                    alerts.append(alert(rule: rule, observation: observation, reading: reading))
                }
            }

            componentState.lastLevel = reading.level
            componentState.lastObservedAt = reading.observedAt
            state[reading.component] = componentState
        }

        return (alerts, state)
    }

    /// Whether a device/component can support a charged alert at all.
    ///
    /// A source that has never reported a charging state cannot, and the UI
    /// says so rather than offering a switch that would never fire.
    public static func supportsCharged(_ readings: [BatteryReading], for component: BatteryComponent) -> Bool {
        readings.contains { $0.component == component && $0.charging != .unknown }
    }

    private static func applies(_ rule: BatteryAlertRule, to component: BatteryComponent) -> Bool {
        if let scoped = rule.component { return scoped == component }
        // An unscoped rule means the batteries being worn. A case going flat
        // in a drawer is not the emergency a low alert is for.
        return component.isInUse
    }

    private static func alert(
        rule: BatteryAlertRule,
        observation: DeviceObservation,
        reading: BatteryReading
    ) -> BatteryAlert {
        BatteryAlert(
            ruleID: rule.id,
            kind: rule.kind,
            deviceID: observation.deviceID,
            deviceName: observation.name,
            component: reading.component,
            level: reading.level,
            threshold: rule.threshold,
            delivery: rule.delivery,
            firedAt: reading.observedAt
        )
    }
}
