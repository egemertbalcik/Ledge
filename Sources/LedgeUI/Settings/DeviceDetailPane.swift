import Charts
import LedgeCore
import SwiftUI

/// One device: what its batteries say now, what they have said, and when to
/// be told about them.
struct DeviceDetailPane: View {

    @Bindable var model: DevicesSettingsModel
    let record: DeviceRecord

    @State private var window: BatteryHistory.Window = .day
    @State private var confirmingRemove = false
    @State private var removeKeepsHistory = true

    var body: some View {
        // Scrolls, because the content does not fit and cannot be made to.
        // Batteries, a chart, a range picker, one row per alert rule and the
        // removal controls exceed the Settings window's height as soon as a
        // device has a couple of rules — and the window is a fixed size, so
        // the overflow was simply clipped away with no way to reach it.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                batteries
                history
                AlertRulesSection(model: model, record: record)
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Whether a reading describes now.
    ///
    /// Derived from when the device was last heard, exactly as the list does
    /// it — not from the stored reliability. A disconnect deliberately keeps
    /// the last known levels, and those keep `reliability == .fresh`, so
    /// trusting that flag made the pane present a two-day-old level as the
    /// current one in the primary style with no "Last known" beside it.
    private func isCurrent(_ reading: BatteryReading) -> Bool {
        record.isCurrent(reading, now: Date())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.clearSelection()
            } label: {
                Label("All Devices", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Toggle("Pinned", isOn: Binding(
                get: { record.isPinned },
                set: { model.setPinned($0, for: record.id) }
            ))
            .toggleStyle(.switch)
            .help("Keeps this device in the list even when it is not around. Pinning never scans for it.")
        }
    }

    // MARK: - Now

    private var batteries: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.name)
                .font(.title3.weight(.semibold))
                .lineLimit(2)

            if record.readings.isEmpty {
                Text("This device has never reported a battery level.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(record.readings.sorted { $0.component.sortOrder < $1.component.sortOrder }, id: \.component) { reading in
                    HStack {
                        Text(reading.component.label)
                            .frame(width: 60, alignment: .leading)
                        Text("\(Int((reading.level * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(isCurrent(reading) ? .primary : .secondary)
                        if reading.charging == .charging {
                            Image(systemName: "bolt.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .accessibilityLabel("Charging")
                        }
                        Spacer()
                        if !isCurrent(reading) {
                            Text("Last known")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .help(reading.observedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Picker("Range", selection: $window) {
                    ForEach(BatteryHistory.Window.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
            }

            let samples = BatteryHistory.samples(model.history, in: window, now: Date())
            if BatteryHistory.hasEnoughHistory(model.history, in: window, now: Date()) {
                Chart(samples, id: \.self) { sample in
                    LineMark(
                        x: .value("When", sample.at),
                        y: .value("Level", sample.level * 100)
                    )
                    .foregroundStyle(by: .value("Battery", sample.component.label))
                    .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("Battery history over the last \(window.title)")
            } else {
                Text("Not enough history yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 60, alignment: .leading)
            }
        }
    }

    // MARK: - Removing

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Button("Remove from Ledge…", role: .destructive) { confirmingRemove = true }
                .confirmationDialog(
                    "Remove \(record.name) from Ledge?",
                    isPresented: $confirmingRemove,
                    titleVisibility: .visible
                ) {
                    Button("Remove, Keep History", role: .destructive) {
                        model.forget(record.id, keepingHistory: true)
                    }
                    Button("Remove and Delete History", role: .destructive) {
                        model.forget(record.id, keepingHistory: false)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("""
                        This only affects Ledge. The device stays paired with \
                        your Mac and nothing is disconnected. It will reappear \
                        here if Ledge sees it again.
                        """)
                }
        }
    }
}
