import LedgeCore
import SwiftUI

/// The numbers behind the feel of the app. Hidden unless `Prefs.advanced` is
/// on, because a slider for the close delay is a question nobody using Ledge
/// should have to answer.
struct AdvancedSettingsTab: View {

    @Bindable var preferences: Preferences
    let geometry: NotchGeometry
    let actions: SettingsActions

    var body: some View {
        Form {
            Section("Hover timing") {
                LabeledSlider("Open delay", value: $preferences.hoverOpenDelay, in: 0...0.6, format: "%.2f")
                LabeledSlider("Close delay", value: $preferences.hoverCloseDelay, in: 0...1.0, format: "%.2f")
                Text("A short open delay stops the island flashing open when you reach past it for the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("How long things stay") {
                LabeledSlider("Announcement", value: $preferences.peekDuration, in: 0.5...6, format: "%.1f")
                LabeledSlider("Level readout", value: $preferences.hudDuration, in: 0.4...4, format: "%.1f")
                Text("Seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Gestures") {
                LabeledSlider("Swipe distance", value: $preferences.swipeThreshold, in: 8...80, format: "%.0f")
            }

            Section("Key steps") {
                LabeledSlider("Volume", value: $preferences.hudVolumeStep, in: 0.02...0.25, format: "%.3f")
                LabeledSlider("Brightness", value: $preferences.hudBrightnessStep, in: 0.02...0.25, format: "%.3f")
                Text("How much one key press changes. 0.063 matches macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Readout layout") {
                Toggle("Glowing bar", isOn: $preferences.hudGlowBar)
                LabeledSlider(
                    "Glyph & bar offset", value: $preferences.hudContentOffset,
                    in: -30...30, format: "%.0f"
                )
                Text("Nudge the glyph and bar horizontally. Positive moves both inward toward the notch; negative toward the edges.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("This Mac") {
                LabeledContent("Screen", value: Self.size(geometry.screenSize))
                LabeledContent("Notch", value: Self.size(geometry.notchSize))
                LabeledContent("Source", value: geometry.isHardwareNotch ? "hardware cutout" : "none — this Mac has no notch")
                Toggle("Tint the shape red", isOn: $preferences.debugTint)
                Button("Copy tuned values") {
                    actions.copyToClipboard(preferences.exportedSwift)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private static func size(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }
}

struct HUDSettingsTab: View {

    @Bindable var preferences: Preferences
    let actions: SettingsActions

    @State private var isTrusted = false

    var body: some View {
        Form {
            Section {
                Toggle("Show a volume readout in the notch", isOn: $preferences.hudEnabled)
                Toggle("Show a brightness readout", isOn: $preferences.hudBrightnessEnabled)
                    .disabled(!preferences.hudEnabled)
                Text("""
                    Volume changes are read straight from the audio system, so this \
                    needs no permission at all. macOS still shows its own readout \
                    alongside — replacing it is the separate setting below.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Replace the macOS readout") {
                Toggle("Hide the macOS volume and brightness readout", isOn: $preferences.suppressSystemHUD)
                    .disabled(!preferences.hudEnabled || !isTrusted)

                if !isTrusted {
                    Button("Grant Accessibility access…") {
                        actions.requestAccessibility()
                    }
                }

                Text("""
                    This works by intercepting the key press before macOS sees it, \
                    so Ledge has to apply the change itself. That needs Accessibility \
                    access. If anything goes wrong the key press is passed through \
                    untouched rather than swallowed, and quitting Ledge always \
                    restores normal behaviour.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { refreshTrust() }
        // The permission is granted in System Settings, outside this window, so
        // the state has to be re-read rather than assumed after the prompt.
        .task { await pollTrust() }
    }

    private func refreshTrust() {
        // Read-only: this runs on a passive view appearance, and writing the
        // preference here silently cancelled the coordinator's grant-wait —
        // effective behavior ended up depending on whether the user ever
        // opened this pane. The toggle stays on while untrusted; the grant
        // hint below it explains what is missing, and the coordinator begins
        // suppressing the moment the grant lands.
        isTrusted = actions.isAccessibilityTrusted()
    }

    private func pollTrust() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            refreshTrust()
        }
    }
}

struct DeveloperSettingsTab: View {

    @Bindable var preferences: Preferences
    let geometry: NotchGeometry
    let actions: SettingsActions

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.orange)
                    Text("Ledge")
                        .font(.system(size: 20, weight: .bold))
                    Text("A live status surface for your Mac's notch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Version \(version)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 10) {
                        Button("Check for Updates…") { actions.checkForUpdates() }
                            .disabled(!actions.canCheckForUpdates())
                        Button("Welcome Tour…") { actions.showOnboarding() }
                        Button("Source on GitHub") { actions.openSource() }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section {
                Button("Reset all settings", role: .destructive) {
                    preferences.resetToDefaults()
                    // The login item lives in SMAppService, not in defaults:
                    // without this the toggle showed Off while the
                    // registration survived, and the next launch's reconcile
                    // flipped it back On — a reset that visibly didn't stick.
                    _ = actions.setLaunchAtLogin(false)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func size(_ value: CGSize) -> String {
        String(format: "%.0f × %.0f", value.width, value.height)
    }
}

/// Live permission state, with the one action each row can actually take.
struct PermissionsSettingsTab: View {

    let model: SettingsModel
    let actions: SettingsActions

    var body: some View {
        Form {
            if model.isLaunchedFromTerminal {
                Section {
                    Label("Ledge was launched from a terminal.", systemImage: "exclamationmark.triangle")
                    Text("""
                        macOS credits a permission to the process that launched \
                        the app, so anything granted now attaches to your \
                        terminal instead of to Ledge — which looks exactly like a \
                        denial. Quit and open Ledge from Finder before granting.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(model.permissions) { row in
                Section(row.kind.displayName) {
                    LabeledContent("Status") {
                        Text(row.status.summary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint(for: row.status))
                    }
                    Text(row.kind.rationale)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    action(for: row)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { actions.refreshPermissions() }
        // Granting happens in System Settings, outside this window, so the
        // state has to be re-read rather than assumed.
        .task { await poll() }
    }

    @ViewBuilder
    private func action(for row: PermissionRow) -> some View {
        switch row.status {
        case .notApplicableNow where row.kind.isRequestable:
            // See the onboarding pane: with no player running this row used to
            // show nothing at all, so Automation could never be granted from
            // here. The button opens Music and asks.
            Button("Open Music…") { actions.requestPermission(row.kind) }
        case .granted, .unavailable, .notApplicableNow:
            EmptyView()
        case .notDetermined where row.kind.isRequestable:
            Button("Allow…") { actions.requestPermission(row.kind) }
        case .notDetermined, .denied:
            // Once denied, TCC will not prompt again — System Settings is the
            // only way back. Same for anything that cannot be prompted at all.
            Button("Open System Settings…") { actions.openPermissionSettings(row.kind) }
        }
    }

    private func tint(for status: PermissionStatus) -> Color {
        switch status {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .orange
        case .unavailable, .notApplicableNow: .secondary
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            actions.refreshPermissions()
        }
    }
}
