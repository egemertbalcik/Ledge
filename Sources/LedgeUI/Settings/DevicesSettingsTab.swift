import Charts
import LedgeCore
import SwiftUI

/// The Devices pane: what Ledge has seen, what it knows about each one, and
/// when to say something about it.
///
/// Only devices Ledge can actually observe appear here — this Mac, AirPods and
/// Beats seen over the air, Bluetooth accessories it has been told about.
/// There is no row for an iPhone, because there is no source that would ever
/// fill one in.
struct DevicesSettingsTab: View {

    @Bindable var model: DevicesSettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let record = model.selected {
                DeviceDetailPane(model: model, record: record)
            } else {
                list
            }
        }
        .onAppear { model.beginWatching() }
        // A closed pane leaves nothing running: the model cancels its refresh
        // and whatever read it had in flight, rather than letting either
        // finish into a window that has gone. Writes are deliberately not
        // cancelled — a rule the user just changed must still land.
        .onDisappear { model.endWatching() }
    }

    @ViewBuilder
    private var list: some View {
        if model.rows.isEmpty, model.hasLoaded {
            emptyState
        } else {
            // Scrolls: a Mac with a keyboard, a trackpad, a mouse and two sets
            // of earbuds already exceeds the pane, and the window is a fixed
            // size — so the overflow was clipped with no way to reach it.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        Button { model.select(row.id) } label: {
                            DeviceRow(row: row)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows battery history and alerts for \(row.name)")
                        if row.id != model.rows.last?.id { Divider() }
                    }

                    Divider().padding(.top, 8)
                    retentionNote
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No devices yet")
                .font(.headline)
            Text("""
                Ledge fills this in as it sees things: this Mac, AirPods that \
                come within range, and Bluetooth accessories as they connect. \
                Nothing is looked up — it only records what it was already \
                told.
                """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var retentionNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Battery history is kept on this Mac for 90 days, up to 2,000 readings per device. Nothing is sent anywhere.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Delete Device History…", role: .destructive) { confirmingDeleteAll = true }
                .confirmationDialog(
                    "Delete all battery history?",
                    isPresented: $confirmingDeleteAll,
                    titleVisibility: .visible
                ) {
                    Button("Delete History", role: .destructive) { model.deleteAllHistory() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The devices stay in the list. Only the recorded battery readings are removed.")
                }
        }
        .padding(.top, 8)
    }

    @State private var confirmingDeleteAll = false
}

/// One row: who it is, where it stands, and how full.
private struct DeviceRow: View {

    let row: DevicesSettingsModel.Row

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbolName)
                .frame(width: 22)
                .foregroundStyle(row.isApple ? Color.accentColor : Color.primary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(presentation.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let level = presentation.levelText {
                Text(level)
                    .monospacedDigit()
                    // A level we are no longer being told is drawn quieter, so
                    // an old number never looks like a current one — and the
                    // accessibility label says "last known value" in words,
                    // because a colour is not a message.
                    .foregroundStyle(presentation.isLevelHistorical ? .secondary : .primary)
            }
            if row.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.accessibilityLabel)
        .help(presentation.exactTime)
    }

    /// Presence and freshness are separate questions, and the row says both.
    ///
    /// "Connected" with a stale reading is not a contradiction — it is the
    /// honest state of a device that was seen to attach and has not been
    /// heard from since. Calling that "disconnected" would claim an event
    /// nobody observed.
    private var presentation: DeviceRowPresentation {
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return DeviceRowPresentation(
            name: row.name,
            presence: row.presence,
            isStale: row.isStale,
            lowestLevel: row.lowestLevel,
            lastSeen: row.lastSeen,
            now: Date(),
            relativeText: relative.localizedString(for: row.lastSeen, relativeTo: Date()),
            exactTime: row.lastSeen.formatted(date: .abbreviated, time: .shortened)
        )
    }
}
