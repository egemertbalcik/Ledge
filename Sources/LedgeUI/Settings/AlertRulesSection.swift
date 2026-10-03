import LedgeCore
import SwiftUI

/// When to say something about this device's batteries.
struct AlertRulesSection: View {

    @Bindable var model: DevicesSettingsModel
    let record: DeviceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alerts").font(.headline)

            if record.id.ownsItsOwnAlerting {
                // The engine refuses to alert for this device, so an editable
                // rule here would be a control that either does nothing or —
                // once edited — announces the same dip twice, alongside the
                // warnings this Mac already gives.
                ownAlertingNote
            } else {
                rulesEditor
            }
        }
    }

    private var ownAlertingNote: some View {
        Text(
            """
            This Mac's battery warnings come from Ledge's own battery card, \
            which has both a low and a critical level. Ledge does not add a \
            second alert for it.
            """
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var rulesEditor: some View {
        VStack(alignment: .leading, spacing: 10) {

            ForEach(Array(configuration.rules.enumerated()), id: \.element.id) { index, rule in
                RuleRow(
                    rule: rule,
                    canCharge: supportsCharged(rule.component),
                    deviceName: record.name,
                    onChange: { updated in replace(updated, at: index) },
                    onDelete: { remove(at: index) },
                    onPreview: {
                        // A notification-only preview with permission not yet
                        // granted would otherwise be a button that silently
                        // does nothing. Previewing is one of the two moments
                        // the user has asked for notifications, so it is one
                        // of the two moments it is right to ask.
                        if rule.delivery.contains(.notification) {
                            Task {
                                _ = await model.requestNotificationAuthorization()
                                model.preview(rule, deviceName: record.name)
                            }
                        } else {
                            model.preview(rule, deviceName: record.name)
                        }
                    },
                    enableNotificationDelivery: {
                        // By id, applied to the configuration as it is when
                        // the answer arrives: the prompt is modal to nothing,
                        // and edits made while it was up must survive.
                        Task {
                            guard await model.requestNotificationAuthorization() else { return }
                            model.enableNotificationDelivery(ruleID: rule.id, for: record.id)
                        }
                    },
                    disableNotifications: { model.notificationDeliveryWasDisabled() }
                )
                Divider()
            }

            HStack {
                Button("Add Low Alert") { add(kind: .low) }
                Button("Add Charged Alert") { add(kind: .charged) }
                    .disabled(!supportsAnyCharging)
                    .help(supportsAnyCharging
                          ? "Tells you when this device finishes charging."
                          : "This device does not report whether it is charging, so a charged alert could never be certain.")
            }
            .padding(.top, 2)

            if !configuration.isCustomised {
                Text("Using Ledge's default: one alert at 20%, in the notch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !supportsAnyCharging {
                Text("This device reports a level but not whether it is charging, so Ledge will not guess when it is full.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The rules as edited. An untouched device shows the built-in default as
    /// a real row, so the first edit starts from what is actually happening
    /// rather than from nothing.
    private var configuration: DeviceAlertConfiguration {
        record.alerts.isCustomised
            ? record.alerts
            : DeviceAlertConfiguration(rules: [.defaultLow()], isCustomised: false)
    }

    private func supportsCharged(_ component: BatteryComponent?) -> Bool {
        guard let component else { return supportsAnyCharging }
        return BatteryAlertEngine.supportsCharged(record.readings, for: component)
    }

    private var supportsAnyCharging: Bool {
        record.readings.contains { $0.charging != .unknown }
    }

    private func commit(_ rules: [BatteryAlertRule]) {
        // The first edit is what makes the configuration the user's own.
        model.setAlerts(
            DeviceAlertConfiguration(rules: rules, isCustomised: true),
            for: record.id
        )
    }

    private func replace(_ rule: BatteryAlertRule, at index: Int) {
        var rules = configuration.rules
        guard rules.indices.contains(index) else { return }
        rules[index] = rule
        commit(rules)
    }

    private func remove(at index: Int) {
        var rules = configuration.rules
        guard rules.indices.contains(index) else { return }
        rules.remove(at: index)
        commit(rules)
    }

    private func add(kind: AlertKind) {
        var rules = configuration.rules
        rules.append(BatteryAlertRule(
            kind: kind,
            component: nil,
            threshold: kind == .low ? 0.2 : 1.0
        ))
        commit(rules)
    }
}

/// One rule, editable.
private struct RuleRow: View {

    let rule: BatteryAlertRule
    let canCharge: Bool
    let deviceName: String
    let onChange: (BatteryAlertRule) -> Void
    let onDelete: () -> Void
    let onPreview: () -> Void
    let enableNotificationDelivery: () -> Void
    let disableNotifications: () -> Void

    /// Which of this row's controls are usable. One decision, in `LedgeCore`,
    /// so the view and its test cannot disagree about what stays repairable.
    private var controls: RuleControls {
        RuleControls(rule: rule, componentReportsCharging: canCharge)
    }

    private var canFire: Bool { controls.canFire }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(
                    get: { rule.isEnabled && canFire },
                    set: { var copy = rule; copy.isEnabled = $0; onChange(copy) }
                )) {
                    Text(rule.kind == .low ? "Low battery" : "Charged")
                }
                .toggleStyle(.switch)
                // A rule that cannot fire cannot be switched on: the control
                // would claim an alert the hardware can never give. Delete and
                // the battery picker stay live, which is how the row is
                // repaired rather than abandoned.
                .disabled(!controls.canEnable)

                Spacer()

                Button("Preview", action: onPreview)
                    .disabled(!controls.canPreview)
                    .help("Shows what this looks like, using made-up numbers. It does not change when the real alert fires.")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove this alert")
            }

            HStack {
                Text("At")
                Slider(
                    value: Binding(
                        get: { rule.threshold },
                        set: { var copy = rule; copy.setThreshold($0); onChange(copy) }
                    ),
                    in: rule.kind == .low ? 0.05...0.5 : 0.5...1.0
                )
                .frame(maxWidth: 200)
                .disabled(!controls.canEditThreshold)
                .accessibilityLabel("\(rule.kind == .low ? "Low" : "Charged") threshold")
                Text("\(Int((rule.threshold * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }

            Picker("Battery", selection: Binding(
                get: { rule.component },
                set: { var copy = rule; copy.component = $0; onChange(copy) }
            )) {
                Text("Any in use").tag(BatteryComponent?.none)
                Text("Left").tag(BatteryComponent?.some(.left))
                Text("Right").tag(BatteryComponent?.some(.right))
                Text("Case").tag(BatteryComponent?.some(.case))
                Text("Main").tag(BatteryComponent?.some(.main))
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260)

            HStack {
                Text("Show in")
                Toggle("Notch", isOn: binding(for: .notch)).toggleStyle(.checkbox)
                Toggle("Notification", isOn: notificationBinding).toggleStyle(.checkbox)
            }
            .disabled(!controls.canChooseDelivery)

            if !canFire {
                Text("This battery does not report a charging state, so this alert cannot fire. Choose another battery, or remove the alert.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if rule.delivery.isEmpty {
                Text("With neither of these ticked the alert is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func binding(for option: AlertDelivery) -> Binding<Bool> {
        Binding(
            get: { rule.delivery.contains(option) },
            set: { on in
                var copy = rule
                if on { copy.delivery.insert(option) } else { copy.delivery.remove(option) }
                onChange(copy)
            }
        )
    }

    /// Turning this on is the moment permission is asked for — not before,
    /// and never merely by opening this pane.
    private var notificationBinding: Binding<Bool> {
        Binding(
            get: { rule.delivery.contains(.notification) },
            set: { on in
                if on {
                    enableNotificationDelivery()
                } else {
                    // Disowns any request still on screen, so answering it
                    // later cannot switch this back on.
                    disableNotifications()
                    var copy = rule
                    copy.delivery.remove(.notification)
                    onChange(copy)
                }
            }
        )
    }
}
