import Foundation
import Testing

@testable import LedgeCore

@Suite("Battery alert engine")
struct BatteryAlertEngineTests {

    private static let device = DeviceIdentity.bluetooth("aa:bb:cc:dd:ee:ff")
    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func observation(
        _ pairs: [(BatteryComponent, Double)],
        charging: ChargingState = .unknown,
        reliability: ReadingReliability = .fresh,
        at seconds: TimeInterval = 0,
        connected: Bool = true,
        name: String = "AirPods Pro"
    ) -> DeviceObservation {
        let when = t0.addingTimeInterval(seconds)
        return DeviceObservation(
            deviceID: device,
            name: name,
            readings: pairs.map {
                BatteryReading(
                    component: $0.0, level: $0.1, charging: charging,
                    observedAt: when, reliability: reliability
                )
            },
            presence: connected ? .connected : .disconnected,
            observedAt: when
        )
    }

    private static var defaultConfig: DeviceAlertConfiguration { .untouched }

    // MARK: - Baseline

    @Test("The first reading is a quiet baseline, even below the threshold")
    func firstReadingIsQuiet() {
        let (alerts, state) = BatteryAlertEngine.evaluate(
            state: [:], observation: Self.observation([(.left, 0.05)]),
            configuration: Self.defaultConfig
        )
        #expect(alerts.isEmpty, "the first thing we ever saw was announced as a crossing")
        #expect(state[.left]?.lastLevel == 0.05, "the baseline was not remembered")
    }

    // MARK: - Low

    @Test("A downward crossing fires once")
    func downwardCrossingFiresOnce() {
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.30)]),
            configuration: Self.defaultConfig
        )
        let (alerts, next) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.18)], at: 60),
            configuration: Self.defaultConfig
        )
        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .low)
        #expect(alerts.first?.component == .left)

        // Still low, and still not news.
        let (again, _) = BatteryAlertEngine.evaluate(
            state: next, observation: Self.observation([(.left, 0.15)], at: 120),
            configuration: Self.defaultConfig
        )
        #expect(again.isEmpty, "a second reading below the threshold alerted again")
    }

    @Test("An identical reading repeated does not alert again")
    func identicalReadingIsSilent() {
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.30)]),
            configuration: Self.defaultConfig
        )
        var alerts: [BatteryAlert]
        (alerts, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.18)], at: 60),
            configuration: Self.defaultConfig
        )
        #expect(alerts.count == 1)

        // A repeated advertisement, a periodic refresh, a reconnect.
        for tick in 1...50 {
            (alerts, state) = BatteryAlertEngine.evaluate(
                state: state,
                observation: Self.observation([(.left, 0.18)], at: 60 + Double(tick)),
                configuration: Self.defaultConfig
            )
            #expect(alerts.isEmpty, "refresh \(tick) repeated the alert")
        }
    }

    @Test("Hysteresis: recovery above the threshold plus margin rearms")
    func hysteresisRearms() {
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.30)]),
            configuration: Self.defaultConfig
        )
        var alerts: [BatteryAlert]
        (alerts, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.18)], at: 60),
            configuration: Self.defaultConfig
        )
        #expect(alerts.count == 1)

        // Just above the threshold is *not* enough to rearm.
        (alerts, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.22)], at: 120),
            configuration: Self.defaultConfig
        )
        #expect(alerts.isEmpty)
        (alerts, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.19)], at: 180),
            configuration: Self.defaultConfig
        )
        #expect(alerts.isEmpty, "it rearmed inside the hysteresis band and alerted again")

        // Past the margin, it rearms.
        (alerts, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.40)], at: 240),
            configuration: Self.defaultConfig
        )
        #expect(alerts.isEmpty)
        (alerts, _) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.15)], at: 300),
            configuration: Self.defaultConfig
        )
        #expect(alerts.count == 1, "a genuine second dip did not alert")
    }

    // MARK: - Components

    @Test("Each earbud keeps its own state")
    func componentsAreIndependent() {
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.30), (.right, 0.30)]),
            configuration: Self.defaultConfig
        )
        let (alerts, next) = BatteryAlertEngine.evaluate(
            state: state,
            observation: Self.observation([(.left, 0.15), (.right, 0.30)], at: 60),
            configuration: Self.defaultConfig
        )
        #expect(alerts.count == 1)
        #expect(alerts.first?.component == .left)

        let (second, _) = BatteryAlertEngine.evaluate(
            state: next,
            observation: Self.observation([(.left, 0.15), (.right, 0.12)], at: 120),
            configuration: Self.defaultConfig
        )
        #expect(second.count == 1, "the right bud's own dip was swallowed by the left's latch")
        #expect(second.first?.component == .right)
    }

    @Test("The case does not trigger a rule meant for the buds")
    func caseDoesNotTriggerInUseRule() {
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.case, 0.80), (.left, 0.90)]),
            configuration: Self.defaultConfig
        )
        let (alerts, _) = BatteryAlertEngine.evaluate(
            state: state,
            observation: Self.observation([(.case, 0.05), (.left, 0.90)], at: 60),
            configuration: Self.defaultConfig
        )
        #expect(alerts.isEmpty, "a flat case in a drawer raised a low-battery alert")
    }

    @Test("A rule scoped to the case fires for the case only")
    func scopedCaseRuleFires() {
        let config = DeviceAlertConfiguration(
            rules: [BatteryAlertRule(kind: .low, component: .case, threshold: 0.2)],
            isCustomised: true
        )
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.case, 0.80), (.left, 0.10)]),
            configuration: config
        )
        let (alerts, _) = BatteryAlertEngine.evaluate(
            state: state,
            observation: Self.observation([(.case, 0.05), (.left, 0.08)], at: 60),
            configuration: config
        )
        #expect(alerts.count == 1)
        #expect(alerts.first?.component == .case)
    }

    // MARK: - Charged

    @Test("A charged alert needs charging evidence, not just a full battery")
    func chargedRequiresEvidence() {
        let config = DeviceAlertConfiguration(
            rules: [BatteryAlertRule(kind: .charged, component: .main, threshold: 0.8)],
            isCustomised: true
        )
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.main, 0.50)]),
            configuration: config
        )
        // Full, but the source cannot say whether it is charging.
        let (silent, after) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.main, 1.0)], at: 60),
            configuration: config
        )
        #expect(silent.isEmpty, "'charged' was inferred from a full battery alone")

        // Same level, now with evidence — but no upward crossing left to make.
        let (stillSilent, _) = BatteryAlertEngine.evaluate(
            state: after,
            observation: Self.observation([(.main, 1.0)], charging: .charging, at: 120),
            configuration: config
        )
        #expect(stillSilent.isEmpty, "it alerted without ever crossing the threshold")
    }

    @Test("A charged alert fires on an upward crossing while charging")
    func chargedFiresOnCrossing() {
        let config = DeviceAlertConfiguration(
            rules: [BatteryAlertRule(kind: .charged, component: .main, threshold: 0.8)],
            isCustomised: true
        )
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state,
            observation: Self.observation([(.main, 0.50)], charging: .charging),
            configuration: config
        )
        var alerts: [BatteryAlert]
        (alerts, state) = BatteryAlertEngine.evaluate(
            state: state,
            observation: Self.observation([(.main, 0.85)], charging: .charging, at: 60),
            configuration: config
        )
        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .charged)

        // Still on the charger, still full: not news.
        (alerts, _) = BatteryAlertEngine.evaluate(
            state: state,
            observation: Self.observation([(.main, 0.95)], charging: .charging, at: 120),
            configuration: config
        )
        #expect(alerts.isEmpty)
    }

    @Test("Charged support is reported honestly")
    func chargedSupportDetection() {
        let unknown = [BatteryReading(component: .main, level: 0.5, observedAt: Self.t0)]
        #expect(!BatteryAlertEngine.supportsCharged(unknown, for: .main))

        let known = [
            BatteryReading(component: .main, level: 0.5, charging: .notCharging, observedAt: Self.t0)
        ]
        #expect(BatteryAlertEngine.supportsCharged(known, for: .main))
    }

    // MARK: - Bad data

    @Test("Stale and unreliable readings cannot trigger, and cannot become the baseline")
    func badDataIsInert() {
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.30)]),
            configuration: Self.defaultConfig
        )
        let (stale, afterStale) = BatteryAlertEngine.evaluate(
            state: state,
            observation: Self.observation([(.left, 0.10)], reliability: .stale, at: 60),
            configuration: Self.defaultConfig
        )
        #expect(stale.isEmpty, "a stale reading raised an alert")
        #expect(afterStale[.left]?.lastLevel == 0.30, "a stale reading became the baseline")

        let (bad, _) = BatteryAlertEngine.evaluate(
            state: state,
            observation: Self.observation([(.left, 0.10)], reliability: .unreliable, at: 60),
            configuration: Self.defaultConfig
        )
        #expect(bad.isEmpty)
    }

    @Test("A level outside 0...1 is marked unreliable rather than trusted")
    func impossibleLevelsAreRejected() {
        #expect(BatteryReading(component: .main, level: 4.2, observedAt: Self.t0).reliability == .unreliable)
        #expect(BatteryReading(component: .main, level: -1, observedAt: Self.t0).reliability == .unreliable)
        #expect(BatteryReading(component: .main, level: .nan, observedAt: Self.t0).reliability == .unreliable)
        #expect(BatteryReading(component: .main, level: 0.5, observedAt: Self.t0).reliability == .fresh)
    }

    @Test("Thresholds are clamped into a band where they can mean something")
    func thresholdsAreClamped() {
        #expect(BatteryAlertRule(kind: .low, threshold: 40).threshold == 0.5)
        #expect(BatteryAlertRule(kind: .low, threshold: -3).threshold == 0.05)
        #expect(BatteryAlertRule(kind: .charged, threshold: 0.1).threshold == 0.5)
        #expect(BatteryAlertRule(kind: .charged, threshold: 9).threshold == 1.0)
        #expect(BatteryAlertRule(kind: .low, threshold: .nan).threshold == 0.2)
    }

    // MARK: - Restart, reconnect, sleep

    @Test("A provider restart does not repeat an alert it already made")
    func restartDoesNotRepeat() {
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.30)]),
            configuration: Self.defaultConfig
        )
        var alerts: [BatteryAlert]
        (alerts, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.15)], at: 60),
            configuration: Self.defaultConfig
        )
        #expect(alerts.count == 1)

        // The provider stops and starts; the state is what was persisted.
        let restored = state
        (alerts, _) = BatteryAlertEngine.evaluate(
            state: restored,
            observation: Self.observation([(.left, 0.15)], at: 600, connected: true),
            configuration: Self.defaultConfig
        )
        #expect(alerts.isEmpty, "the alert was repeated after a restart")
    }

    /// A threshold crossed while the Mac slept is noticed once on wake, and a
    /// device that had already alerted stays quiet. Re-baselining on wake
    /// would swallow "your headphones went flat overnight", which is the case
    /// the alert exists for.
    @Test("A crossing during sleep is announced once at wake, not repeatedly")
    func sleepCrossingAnnouncedOnce() {
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.60)]),
            configuration: Self.defaultConfig
        )
        // Eight hours later, the first reading after wake.
        var alerts: [BatteryAlert]
        let wake: TimeInterval = 8 * 3600
        (alerts, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.08)], at: wake),
            configuration: Self.defaultConfig
        )
        #expect(alerts.count == 1, "the overnight drop was never announced")

        // The burst that follows a wake — several sources all reporting at once.
        for tick in 1...10 {
            (alerts, state) = BatteryAlertEngine.evaluate(
                state: state,
                observation: Self.observation([(.left, 0.08)], at: wake + Double(tick)),
                configuration: Self.defaultConfig
            )
            #expect(alerts.isEmpty, "wake burst \(tick) repeated the alert")
        }
    }

    // MARK: - Migration and delivery

    @Test("An untouched Bluetooth device keeps Ledge's existing 20% behaviour, once")
    func defaultBehaviourMigrates() {
        let config = DeviceAlertConfiguration.untouched
        let rules = config.effectiveRules(for: Self.device)
        #expect(rules.count == 1, "the default must be exactly one rule")
        #expect(rules.first?.kind == .low)
        #expect(rules.first?.threshold == 0.2)
        #expect(rules.first?.delivery == .notch)
        #expect(
            !rules.contains { $0.kind == .charged },
            "a charged alert was enabled without being asked for"
        )

        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.30), (.right, 0.30)]),
            configuration: config
        )
        let (alerts, _) = BatteryAlertEngine.evaluate(
            state: state,
            observation: Self.observation([(.left, 0.15), (.right, 0.15)], at: 60),
            configuration: config
        )
        // One per component that crossed — not one per rule per component.
        #expect(alerts.count == 2)
        #expect(Set(alerts.map(\.component)) == [.left, .right])
    }

    /// This Mac's battery warnings belong to `BatteryProvider`, which has its
    /// own low *and* critical thresholds and its own startup suppression.
    /// Giving the Mac a catalogue rule as well produced two cards for one dip.
    @Test("This Mac gets no default catalogue rule, so it cannot double-announce")
    func macHasNoDefaultRule() {
        let config = DeviceAlertConfiguration.untouched
        #expect(
            config.effectiveRules(for: .thisMac).isEmpty,
            "This Mac would have alerted twice for one dip"
        )
        #expect(!config.effectiveRules(for: Self.device).isEmpty, "other devices still get the default")
    }

    @Test("This Mac produces no alert even across a crossing")
    func macNeverAlertsFromCatalogue() {
        let mac = DeviceObservation(
            deviceID: .thisMac, name: "This Mac",
            readings: [BatteryReading(
                component: .main, level: 0.30, charging: .notCharging, observedAt: Self.t0
            )],
            presence: .connected, observedAt: Self.t0
        )
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: mac, configuration: .untouched
        )
        let dropped = DeviceObservation(
            deviceID: .thisMac, name: "This Mac",
            readings: [BatteryReading(
                component: .main, level: 0.10, charging: .notCharging,
                observedAt: Self.t0.addingTimeInterval(60)
            )],
            presence: .connected, observedAt: Self.t0.addingTimeInterval(60)
        )
        let (alerts, _) = BatteryAlertEngine.evaluate(
            state: state, observation: dropped, configuration: .untouched
        )
        #expect(alerts.isEmpty, "the catalogue announced the Mac's battery alongside BatteryProvider")
    }

    /// The shipped app warned as soon as a low device connected. A quiet
    /// baseline everywhere would have lost that: connect earbuds at 12% and
    /// nothing is said until they fall further, which may be never.
    @Test("A device attaching below the threshold warns; a passive sighting does not")
    func attachingBelowThresholdWarns() {
        let attaching = DeviceObservation(
            deviceID: Self.device, name: "AirPods",
            readings: [BatteryReading(component: .left, level: 0.12, observedAt: Self.t0)],
            presence: .connected, observedAt: Self.t0
        )
        let (onAttach, _) = BatteryAlertEngine.evaluate(
            state: [:], observation: attaching, configuration: .untouched, isAttaching: true
        )
        #expect(onAttach.count == 1, "a device connected at 12% said nothing")

        // The same reading, seen passively — an advertisement, or the first
        // reading after launch.
        let (passive, _) = BatteryAlertEngine.evaluate(
            state: [:], observation: attaching, configuration: .untouched, isAttaching: false
        )
        #expect(passive.isEmpty, "a passive first sighting announced a level the user can see")
    }

    @Test("Attaching does not re-announce what was already announced")
    func attachingRespectsTheLatch() {
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.30)]),
            configuration: Self.defaultConfig
        )
        var alerts: [BatteryAlert]
        (alerts, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.15)], at: 60),
            configuration: Self.defaultConfig
        )
        #expect(alerts.count == 1)

        // Reconnects, still low. The latch holds even though this is an attach.
        (alerts, _) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.left, 0.15)], at: 600),
            configuration: Self.defaultConfig, isAttaching: true
        )
        #expect(alerts.isEmpty, "reconnecting re-announced an alert that had already been given")
    }

    @Test("Delivery choice is carried through to the decision")
    func deliveryIsCarried() {
        let config = DeviceAlertConfiguration(
            rules: [BatteryAlertRule(kind: .low, component: .main, threshold: 0.2, delivery: .both)],
            isCustomised: true
        )
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.main, 0.30)]),
            configuration: config
        )
        let (alerts, _) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.main, 0.10)], at: 60),
            configuration: config
        )
        #expect(alerts.first?.delivery == .both)
    }

    @Test("A disabled rule never fires")
    func disabledRuleIsInert() {
        let config = DeviceAlertConfiguration(
            rules: [BatteryAlertRule(kind: .low, component: .main, threshold: 0.2, isEnabled: false)],
            isCustomised: true
        )
        var state: [BatteryComponent: ComponentAlertState] = [:]
        (_, state) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.main, 0.30)]),
            configuration: config
        )
        let (alerts, _) = BatteryAlertEngine.evaluate(
            state: state, observation: Self.observation([(.main, 0.10)], at: 60),
            configuration: config
        )
        #expect(alerts.isEmpty)
    }
}

@Suite("Battery component normalisation")
struct BatteryComponentTests {

    @Test("Source spellings normalise to one component")
    func spellingsNormalise() {
        #expect(BatteryComponent(label: "Left") == .left)
        #expect(BatteryComponent(label: "  left ") == .left)
        #expect(BatteryComponent(label: "R") == .right)
        #expect(BatteryComponent(label: "Charging Case") == .case)
        #expect(BatteryComponent(label: "battery") == .main)
    }

    @Test("An unknown component survives a round trip as itself")
    func unknownRoundTrips() throws {
        let odd = BatteryComponent(label: "Transmitter")
        #expect(odd == .other("Transmitter"))

        let data = try JSONEncoder().encode(odd)
        let back = try JSONDecoder().decode(BatteryComponent.self, from: data)
        #expect(back == odd, "an unrecognised battery was lost in storage")
        #expect(back.label == "Transmitter")
    }

    @Test("Only worn components count as in use")
    func inUseClassification() {
        #expect(BatteryComponent.left.isInUse)
        #expect(BatteryComponent.right.isInUse)
        #expect(BatteryComponent.main.isInUse)
        #expect(!BatteryComponent.case.isInUse)
        #expect(!BatteryComponent.other("Transmitter").isInUse)
    }
}

/// A rule with nowhere to deliver is a rule that is off. Settings lets both
/// destinations be unticked, and the engine used to fire anyway: nothing
/// appeared, and the latch was spent — so ticking a destination back on left
/// the user waiting for an alert that had already silently happened.
@Suite("Alerts nobody can see")
struct UndeliverableAlertTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func observation(_ level: Double, at seconds: TimeInterval) -> DeviceObservation {
        DeviceObservation(
            deviceID: .bluetooth("aa:bb"), name: "AirPods",
            readings: [BatteryReading(
                component: .left, level: level, observedAt: t0.addingTimeInterval(seconds)
            )],
            presence: .connected, observedAt: t0.addingTimeInterval(seconds),
            cause: .connectionEvent
        )
    }

    private static func configuration(delivery: AlertDelivery) -> DeviceAlertConfiguration {
        DeviceAlertConfiguration(
            rules: [BatteryAlertRule(
                kind: .low, component: .left, threshold: 0.2, delivery: delivery
            )],
            isCustomised: true
        )
    }

    @Test("A rule with no destination knows it cannot deliver")
    func ruleKnowsItCannotDeliver() {
        #expect(BatteryAlertRule(kind: .low, threshold: 0.2, delivery: []).canDeliver == false)
        #expect(BatteryAlertRule(kind: .low, threshold: 0.2, delivery: .notch).canDeliver)
        #expect(BatteryAlertRule(kind: .low, threshold: 0.2, delivery: .both).canDeliver)
    }

    @Test("It does not fire, and does not spend its latch")
    func undeliverableRuleIsInert() {
        let configuration = Self.configuration(delivery: [])
        let first = BatteryAlertEngine.evaluate(
            state: [:], observation: Self.observation(0.30, at: 0),
            configuration: configuration
        )
        let crossing = BatteryAlertEngine.evaluate(
            state: first.state, observation: Self.observation(0.15, at: 60),
            configuration: configuration
        )
        #expect(crossing.alerts.isEmpty, "an alert nobody could see was raised")
        #expect(
            crossing.state[.left]?.firedRuleIDs.isEmpty == true,
            "and it spent the latch, so enabling delivery would stay silent"
        )
    }

    /// The consequence that mattered: switch a destination back on, and the
    /// next reading below the threshold is announced — the earlier silence did
    /// not consume it.
    @Test("Enabling delivery afterwards still announces")
    func enablingDeliveryAnnounces() {
        let off = Self.configuration(delivery: [])
        let baseline = BatteryAlertEngine.evaluate(
            state: [:], observation: Self.observation(0.30, at: 0), configuration: off
        )
        let whileOff = BatteryAlertEngine.evaluate(
            state: baseline.state, observation: Self.observation(0.15, at: 60),
            configuration: off
        )
        #expect(whileOff.alerts.isEmpty)

        // Same rule id, now with somewhere to go, and the level comes back
        // down after recovering.
        var on = Self.configuration(delivery: .notch)
        on.rules[0] = BatteryAlertRule(
            id: off.rules[0].id, kind: .low, component: .left,
            threshold: 0.2, delivery: .notch
        )
        let recovered = BatteryAlertEngine.evaluate(
            state: whileOff.state, observation: Self.observation(0.40, at: 120),
            configuration: on
        )
        let crossing = BatteryAlertEngine.evaluate(
            state: recovered.state, observation: Self.observation(0.15, at: 180),
            configuration: on
        )
        #expect(crossing.alerts.count == 1, "the alert was swallowed by the earlier silence")
    }
}

/// Two rules the user deliberately set on one device — "tell me at 30%, and
/// again at 10%" — are two things they asked for. One reading crossing both
/// must deliver both, while two *records* of the same physical device raising
/// the same alert still collapse to one.
@Suite("Several rules on one device")
struct MultipleRuleTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func alert(
        _ ruleID: UUID,
        level: Double,
        threshold: Double = 0.2,
        name: String = "AirPods",
        component: BatteryComponent = .left
    ) -> BatteryAlert {
        BatteryAlert(
            ruleID: ruleID, kind: .low, deviceID: .bluetooth("aa:bb"),
            deviceName: name, component: component, level: level,
            threshold: threshold, delivery: .notch, firedAt: t0
        )
    }

    /// One reading at 8% crosses a 30% rule and a 10% rule at once. Both
    /// alerts carry the same *level* — the reading — so only the rule's own
    /// threshold can tell the two wishes apart.
    @Test("Two thresholds crossed at once both deliver")
    func twoThresholdsBothDeliver() {
        let shallow = Self.alert(UUID(), level: 0.08, threshold: 0.30)
        let deep = Self.alert(UUID(), level: 0.08, threshold: 0.10)
        let kept = BatteryAlertEngine.withoutDuplicates(
            [shallow, deep], recent: [], now: Self.t0
        )
        #expect(kept.count == 2, "a rule the user added was silently swallowed")
    }

    /// The case the deduplication exists for: one physical device, two
    /// *records* (Bluetooth address and proximity UUID), raising the same alert
    /// a moment apart. Two records, because that is what makes it a duplicate
    /// rather than two wishes — see `SameRecordRuleTests`.
    @Test("The same alert from two records of one device collapses")
    func duplicateAcrossRecordsCollapses() {
        let first = Self.alert(UUID(), level: 0.18, threshold: 0.2)
        var second = Self.alert(UUID(), level: 0.18, threshold: 0.2)
        second.deviceID = DeviceIdentity(source: .proximityName, value: "airpods")
        let kept = BatteryAlertEngine.withoutDuplicates(
            [second], recent: [first], now: Self.t0.addingTimeInterval(30)
        )
        #expect(kept.isEmpty, "the same device said the same thing twice")
    }

}

/// Deduplication is for one physical device wearing two records — one from the
/// paired list, one from a proximity advertisement. It is not for two rules the
/// user deliberately set on the same device, even at the same threshold.
@Suite("Two rules, one record")
struct SameRecordRuleTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private static let airpods = DeviceIdentity.bluetooth("aa:bb")
    private static let proximity = DeviceIdentity(source: .proximityName, value: "airpods")

    private static func alert(
        rule: UUID,
        device: DeviceIdentity,
        level: Double = 0.18,
        threshold: Double = 0.2,
        component: BatteryComponent = .left
    ) -> BatteryAlert {
        BatteryAlert(
            ruleID: rule, kind: .low, deviceID: device, deviceName: "AirPods",
            component: component, level: level, threshold: threshold,
            delivery: .notch, firedAt: t0
        )
    }

    /// Two rules, same device, same component, same kind, *same threshold* —
    /// a reachable configuration, and both were being collapsed into one.
    @Test("Two rules at the same threshold on one record both deliver")
    func sameThresholdTwoRulesBothDeliver() {
        // One of them has already been delivered a moment ago — which is what
        // the suppression looks at. The other belongs to the same record, so
        // it is a second thing the user asked for, not a duplicate.
        let alreadyDelivered = Self.alert(rule: UUID(), device: Self.airpods)
        let second = Self.alert(rule: UUID(), device: Self.airpods)
        let kept = BatteryAlertEngine.withoutDuplicates(
            [second], recent: [alreadyDelivered], now: Self.t0.addingTimeInterval(30)
        )
        #expect(kept.count == 1, "a rule the user added was silently swallowed")

        // And both crossing in the same pass survive together.
        let bothAtOnce = BatteryAlertEngine.withoutDuplicates(
            [alreadyDelivered, second], recent: [], now: Self.t0
        )
        #expect(bothAtOnce.count == 2)
    }

    /// And the suppression it exists for still works: the same alert about one
    /// physical device, arriving through two records.
    @Test("The same alert from two records still collapses")
    func twoRecordsStillCollapse() {
        let viaPairedList = Self.alert(rule: UUID(), device: Self.airpods)
        let viaProximity = Self.alert(rule: UUID(), device: Self.proximity)
        let kept = BatteryAlertEngine.withoutDuplicates(
            [viaProximity], recent: [viaPairedList], now: Self.t0.addingTimeInterval(30)
        )
        #expect(kept.isEmpty, "one device said the same thing twice")
    }

    /// A record repeating itself is the latch's job, not this one's: the same
    /// record's own earlier alert must not suppress a later decision here.
    @Test("One record's own earlier alert does not suppress it")
    func sameRecordDoesNotSuppressItself() {
        let rule = UUID()
        let earlier = Self.alert(rule: rule, device: Self.airpods)
        let again = Self.alert(rule: rule, device: Self.airpods)
        let kept = BatteryAlertEngine.withoutDuplicates(
            [again], recent: [earlier], now: Self.t0.addingTimeInterval(30)
        )
        #expect(kept.count == 1)
    }

}

/// A charged alert for a battery that never reports charging can never fire.
/// The row must stay repairable: disabling all of it took Delete and the
/// battery picker with it, which left decoded rules impossible to fix.
@Suite("Which alert-row controls are usable")
struct RuleControlsTests {

    private static func charged(component: BatteryComponent? = .case) -> BatteryAlertRule {
        BatteryAlertRule(kind: .charged, component: component, threshold: 1.0)
    }

    private static func low() -> BatteryAlertRule {
        BatteryAlertRule(kind: .low, component: .left, threshold: 0.2)
    }

    @Test("A charged rule on a battery with no charging evidence cannot fire")
    func impossibleRuleCannotFire() {
        let controls = RuleControls(rule: Self.charged(), componentReportsCharging: false)
        #expect(controls.canFire == false)
        #expect(controls.canEnable == false, "it could be switched on and promise nothing")
        #expect(controls.canEditThreshold == false)
        #expect(controls.canChooseDelivery == false)
        #expect(controls.canPreview == false)
    }

    @Test("And it stays repairable")
    func impossibleRuleIsRepairable() {
        let controls = RuleControls(rule: Self.charged(), componentReportsCharging: false)
        #expect(controls.canChooseBattery, "choosing another battery is the repair")
        #expect(controls.canDelete, "and removing it is the other way out")
    }

    @Test("A charged rule on a battery that does report charging is fully usable")
    func possibleChargedRule() {
        let controls = RuleControls(rule: Self.charged(), componentReportsCharging: true)
        #expect(controls.canFire)
        #expect(controls.canEnable)
        #expect(controls.canEditThreshold)
    }

    /// A low alert needs no charging evidence at all, so nothing is ever
    /// dimmed for it.
    @Test("A low rule is never limited by charging evidence")
    func lowRuleUnaffected() {
        let controls = RuleControls(rule: Self.low(), componentReportsCharging: false)
        #expect(controls.canFire)
        #expect(controls.canEnable)
    }
}
