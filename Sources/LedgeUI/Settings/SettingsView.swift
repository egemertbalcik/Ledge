import LedgeCore
import SwiftUI

/// Things Settings needs the shell to do for it, so `LedgeUI` stays free of
/// AppKit and ServiceManagement.
public struct SettingsActions {
    public var setLaunchAtLogin: (Bool) -> Bool
    public var loginItemStatus: () -> String
    public var copyToClipboard: (String) -> Void
    public var quit: () -> Void

    /// Asks Sparkle to look for a new version. The menu bar used to hold this;
    /// without a menu bar it belongs where the version number already is.
    public var checkForUpdates: () -> Void = {}

    /// Whether an update check is possible right now — Sparkle refuses while
    /// one is already running, and a button that does nothing is worse than a
    /// disabled one.
    public var canCheckForUpdates: () -> Bool = { true }

    /// Whether Accessibility is already granted.
    public var isAccessibilityTrusted: () -> Bool

    /// Shows the system Accessibility prompt. Only ever called from a click.
    public var requestAccessibility: () -> Void

    /// Prompts for a permission. Only ever called from a click.
    public var requestPermission: (PermissionKind) -> Void

    /// Opens the System Settings pane that grants it — the only remedy once a
    /// permission has been denied, since TCC will not prompt twice.
    public var openPermissionSettings: (PermissionKind) -> Void

    /// Re-reads every permission. Cheap, and never prompts.
    public var refreshPermissions: () -> Void

    public var setProviderEnabled: (String, Bool) -> Void

    /// Re-opens the first-run tour, and opens the public repository.
    public var showOnboarding: () -> Void
    public var openSource: () -> Void

    public init(
        setLaunchAtLogin: @escaping (Bool) -> Bool,
        loginItemStatus: @escaping () -> String,
        copyToClipboard: @escaping (String) -> Void,
        quit: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void = {},
        canCheckForUpdates: @escaping () -> Bool = { true },
        isAccessibilityTrusted: @escaping () -> Bool = { false },
        requestAccessibility: @escaping () -> Void = {},
        requestPermission: @escaping (PermissionKind) -> Void = { _ in },
        openPermissionSettings: @escaping (PermissionKind) -> Void = { _ in },
        refreshPermissions: @escaping () -> Void = {},
        setProviderEnabled: @escaping (String, Bool) -> Void = { _, _ in },
        showOnboarding: @escaping () -> Void = {},
        openSource: @escaping () -> Void = {}
    ) {
        self.showOnboarding = showOnboarding
        self.openSource = openSource
        self.setLaunchAtLogin = setLaunchAtLogin
        self.loginItemStatus = loginItemStatus
        self.copyToClipboard = copyToClipboard
        self.quit = quit
        self.checkForUpdates = checkForUpdates
        self.canCheckForUpdates = canCheckForUpdates
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.requestAccessibility = requestAccessibility
        self.requestPermission = requestPermission
        self.openPermissionSettings = openPermissionSettings
        self.refreshPermissions = refreshPermissions
        self.setProviderEnabled = setProviderEnabled
    }
}

/// One selectable page. Fixed pages are enumerated; each activity source is a
/// `.provider(id)`.
enum SettingsPane: Hashable {
    /// The panes anyone needs. Six rows, each with one job.
    case general, cards, hud, permissions, about
    /// Tuning surfaces, shown only when `Prefs.advanced` is on: they exist for
    /// shaping the app, not for using it.
    case advanced, appearance, compact
    case provider(String)
}

/// The icon and tint for a sidebar row, in the macOS System-Settings idiom: a
/// white SF Symbol on a rounded colour tile.
struct SidebarIcon {
    let symbol: String
    let color: Color

    static func forPane(_ pane: SettingsPane) -> SidebarIcon {
        switch pane {
        case .general: SidebarIcon(symbol: "gearshape.fill", color: .gray)
        case .cards: SidebarIcon(symbol: "rectangle.stack.fill", color: .orange)
        case .advanced: SidebarIcon(symbol: "slider.horizontal.3", color: .pink)
        case .appearance: SidebarIcon(symbol: "paintbrush.fill", color: .pink)
        case .compact: SidebarIcon(symbol: "capsule.fill", color: .indigo)
        case .hud: SidebarIcon(symbol: "speaker.wave.2.fill", color: .teal)
        case .permissions: SidebarIcon(symbol: "lock.fill", color: .blue)
        case .about: SidebarIcon(symbol: "info", color: .gray)
        case .provider(let id): SidebarIcon.forProvider(id)
        }
    }

    static func forProvider(_ id: String) -> SidebarIcon {
        switch id {
        case "nowplaying": SidebarIcon(symbol: "play.fill", color: .red)
        case "battery": SidebarIcon(symbol: "bolt.fill", color: .orange)
        case "bluetooth": SidebarIcon(symbol: "headphones", color: .green)
        case "calendar": SidebarIcon(symbol: "calendar", color: .red)
        case "focus": SidebarIcon(symbol: "moon.fill", color: .indigo)
        case "weather": SidebarIcon(symbol: "cloud.fill", color: .blue)
        case "timer": SidebarIcon(symbol: "timer", color: .orange)
        case "shelf": SidebarIcon(symbol: "tray.full.fill", color: .teal)
        case "privacy": SidebarIcon(symbol: "video.fill", color: .green)
        case "airpods-proximity": SidebarIcon(symbol: "airpods.gen3", color: .gray)
        case "keyboard": SidebarIcon(symbol: "keyboard.fill", color: .purple)
        case "capslock": SidebarIcon(symbol: "capslock.fill", color: .purple)
        default: SidebarIcon(symbol: "circle.fill", color: .gray)
        }
    }

    var view: some View {
        Image(systemName: symbol)
            .font(.cardLabel)
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

public struct SettingsView: View {

    @Bindable private var preferences: Preferences
    private let geometry: NotchGeometry
    private let actions: SettingsActions
    private let model: SettingsModel

    @State private var selection: SettingsPane

    public init(
        preferences: Preferences,
        geometry: NotchGeometry,
        actions: SettingsActions,
        model: SettingsModel = SettingsModel()
    ) {
        self.preferences = preferences
        self.geometry = geometry
        self.actions = actions
        self.model = model
        // A debug launch can open straight onto a page.
        let initial = ProcessInfo.processInfo.environment["LEDGE_SETTINGS_TAB"]
        self._selection = State(initialValue: Self.pane(named: initial) ?? .general)
    }

    private static func pane(named name: String?) -> SettingsPane? {
        switch name {
        case "general": .general
        case "cards": .cards
        case "advanced": .advanced
        case "appearance": .appearance
        case "compact": .compact
        case "hud": .hud
        case "permissions": .permissions
        case "about": .about
        default: nil
        }
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .scrollContentBackground(.hidden)
                .navigationSplitViewColumnWidth(min: 236, ideal: 236, max: 236)
                // The sidebar is the whole navigation; collapsing it leaves a
                // window with no way back to the other panes.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(minWidth: 420)
                // The pane's name belongs in the title bar, which is where
                // System Settings puts it. An in-content header with a tinted
                // icon beside it is not a thing macOS does.
                .navigationTitle(paneTitle)
        }
        .navigationSplitViewStyle(.balanced)
        // The whole window sits on a behind-window material, so the wallpaper
        // tints the settings the way macOS Tahoe's own panes are tinted.
        .background(VibrantBackground())
        .frame(minWidth: 700, idealWidth: 700, minHeight: 560, idealHeight: 560)
    }

    private var paneTitle: String {
        switch selection {
        case .general: "General"
        case .cards: "Cards"
        case .advanced: "Advanced"
        case .appearance: "Shape & Motion"
        case .compact: "Compact Ears"
        case .hud: "Levels"
        case .permissions: "Permissions"
        case .about: "About"
        case .provider(let id):
            model.providers.first { $0.id == id }?.displayName ?? "Source"
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                row(.general, "General")
                row(.cards, "Cards")
                row(.hud, "Sound & Brightness")
            }

            Section {
                row(.permissions, "Permissions")
                row(.about, "About")
            }

            // Only for whoever is tuning the app. See `Prefs.advanced`.
            if preferences.advanced {
                Section {
                    row(.advanced, "Advanced")
                    row(.appearance, "Shape & Motion")
                    row(.compact, "Compact Ears")
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ pane: SettingsPane, _ title: String) -> some View {
        Label {
            // Two lines rather than an ellipsis: "Sound & Brig…" tells a new
            // user less than the words it is hiding.
            Text(title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            SidebarIcon.forPane(pane).view
        }
        .tag(pane)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralSettingsTab(preferences: preferences, geometry: geometry, actions: actions)
        case .cards:
            CardsSettingsTab(
                preferences: preferences,
                model: model,
                actions: actions,
                openPermissions: { selection = .permissions }
            )
        case .advanced:
            AdvancedSettingsTab(preferences: preferences, geometry: geometry, actions: actions)
        case .appearance:
            AppearanceSettingsTab(preferences: preferences, geometry: geometry)
        case .compact:
            CompactSettingsTab(preferences: preferences, geometry: geometry)
        case .hud:
            HUDSettingsTab(preferences: preferences, actions: actions, model: model)
        case .permissions:
            PermissionsSettingsTab(model: model, actions: actions)
        case .about:
            DeveloperSettingsTab(preferences: preferences, geometry: geometry, actions: actions)
        case .provider(let id):
            ProviderDetailPane(
                id: id,
                preferences: preferences,
                model: model,
                actions: actions,
                openPermissions: { selection = .permissions }
            )
        }
    }
}

/// The pane's identity row: its sidebar tile, larger, beside the pane name —
/// the way each System Settings pane repeats its icon at the top.
/// A behind-window material, so the desktop tints the whole settings window the
/// way Tahoe's own panes are tinted by the wallpaper.
struct VibrantBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// A slider in the Tahoe idiom: title on the left, the live value in a rounded
/// badge on the right, and the slider running the row's full width beneath.
struct LabeledSlider<Value: BinaryFloatingPoint>: View
where Value.Stride: BinaryFloatingPoint {

    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let format: String

    init(_ title: String, value: Binding<Value>, in range: ClosedRange<Value>, format: String) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(String(format: format, Double(value)))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Slider(value: $value, in: range)
                // The row's title is a sibling, not the slider's label, so
                // VoiceOver otherwise announces every one of these as "slider".
                .accessibilityLabel(title)
        }
        .padding(.vertical, 2)
    }
}
