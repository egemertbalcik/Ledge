import LedgeCore
import SwiftUI

/// Devices: what Ledge has seen, what it knows about each one, and when to
/// say something about it.
///
/// Only devices Ledge can actually observe appear here — this Mac, AirPods and
/// Beats seen over the air, Bluetooth accessories it has been told about.
/// There is no row for an iPhone, because there is no source that would ever
/// fill one in.
struct DevicesSettingsTab: View {

    /// Nil when the shell has no catalogue behind the pane — in a preview, or
    /// in a test that does not exercise devices. The pane says so rather than
    /// rendering an empty list as if it were an answer.
    let model: DevicesSettingsModel?

    /// A row a search result asked to be shown. The window clears it.
    var highlighted: String?

    @State private var confirmingDeleteAll = false

    var body: some View {
        Group {
            if let model {
                pane(model)
            } else {
                SettingsPage {
                    Section {
                        Label("No device catalogue", systemImage: "questionmark.folder")
                        SettingsNote("Ledge could not open the file it keeps devices in, so this pane has nothing to show. Quitting and opening Ledge again is the usual fix.")
                    }
                }
            }
        }
        .onAppear { model?.beginWatching() }
        // A closed pane leaves nothing running: the model cancels its refresh
        // and whatever read it had in flight, rather than letting either
        // finish into a window that has gone. Writes are deliberately not
        // cancelled — a rule the user just changed must still land.
        .onDisappear {
            model?.endWatching()
            // Same rule as Cards: the row says Devices, so coming back to it
            // shows the devices rather than whichever one was last open.
            model?.clearSelection()
        }
    }

    /// The list, and the device that is open on top of it.
    ///
    /// A real navigation stack rather than a hand-made "All Devices" button:
    /// the Cards pane pushes a page and gets the window's own back control,
    /// and there is no reason for this pane to push one differently. The path
    /// is the model's selection, so opening and closing a device still go
    /// through `select` and `clearSelection` — including the close that
    /// `forget` does for itself.
    private func pane(_ model: DevicesSettingsModel) -> some View {
        NavigationStack(path: Binding(
            get: { model.selected.map { [$0.id] } ?? [] },
            set: { path in if path.isEmpty { model.clearSelection() } }
        )) {
            list(model)
                .navigationDestination(for: DeviceIdentity.self) { id in
                    if let record = model.selected, record.id == id {
                        DeviceDetailPane(model: model, record: record)
                    }
                }
        }
    }

    @ViewBuilder
    private func list(_ model: DevicesSettingsModel) -> some View {
        SettingsPage(scrollTo: highlighted) {
            if !model.hasLoaded, model.isLoading {
                // The first read goes to disk. A blank pane for that moment
                // reads as "no devices", which is a different claim entirely.
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for devices…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Looking for devices")
                }
            } else if model.rows.isEmpty, model.hasLoaded {
                Section {
                    Label("No devices yet", systemImage: "airpods.pro")
                    SettingsNote("""
                        Ledge fills this in as it sees things: this Mac, AirPods that \
                        come within range, and Bluetooth accessories as they connect. \
                        Nothing is looked up — it only records what it was already told.
                        """)
                }
            } else {
                Section {
                    ForEach(model.rows) { row in
                        Button { model.select(row.id) } label: {
                            DeviceRow(row: row)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows battery history and alerts for \(row.name)")
                    }
                } header: {
                    Text("Seen by Ledge")
                }
                // "Battery alerts" in search lands on the list: the alerts
                // themselves are inside a device, and the list is the way in.
                .searchRow("alerts", highlighted: highlighted)

                Section {
                    Button("Delete Device History…", role: .destructive) {
                        confirmingDeleteAll = true
                    }
                    .searchRow("history", highlighted: highlighted)
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
                } header: {
                    Text("History")
                } footer: {
                    SettingsNote("Battery history is kept on this Mac for 90 days, up to 2,000 readings per device. Nothing is sent anywhere.")
                }
            }
        }
    }
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
                    .font(.callout)
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
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
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
