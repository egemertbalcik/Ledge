import LedgeCore
import SwiftUI

/// Things Settings needs the shell to do for it, so `LedgeUI` stays free of
/// AppKit and ServiceManagement.
/// What installing the helper came to, in the words the pane can use.
///
/// Its own type in LedgeUI rather than the shell's, because LedgeUI cannot see
/// ServiceManagement and should not need to: approval pending is not success
/// and not failure, and that distinction is the whole reason this is not a Bool.
public enum KeepAwakeHelperSetupOutcome: Equatable, Sendable {
    case installed
    /// Registered, and now waiting for the user in System Settings. A daemon
    /// awaiting approval holds nothing, so this never reads as set up.
    case needsApproval
    /// macOS will not install a privileged helper out of this build at all.
    case unavailable
    case refused(String)
}

/// What taking the helper back out came to.
public enum KeepAwakeHelperRemoval: Equatable, Sendable {
    case removed
    /// Refused, because the daemon still owes the Mac something.
    ///
    /// A daemon with a setting still to put back is the only thing that can
    /// put it back. Unregistering it there leaves a Mac that cannot sleep and
    /// nothing left able to fix it — which is the failure this whole feature
    /// is built around not causing.
    case stillOwesWork
    case failed(String)
}

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

    /// Installs the lid-closed helper, and says what happened.
    ///
    /// The one action in Ledge that asks macOS to run something as root, so it
    /// is reached only from a press and never from a refresh. The default does
    /// nothing and reports a build that cannot have one, which is what a
    /// preview and a test should both see.
    public var installKeepAwakeHelper: () -> KeepAwakeHelperSetupOutcome = { .unavailable }

    /// Takes the lid-closed helper back out.
    ///
    /// Somebody who installed a thing that runs as root must be able to
    /// uninstall it from the same place, without hunting for a terminal
    /// command. It is also the only way to try the setup again from the
    /// beginning, which is what anybody debugging it needs.
    public var removeKeepAwakeHelper: () async -> KeepAwakeHelperRemoval = { .removed }

    /// Opens the System Settings pane where a registered daemon is approved.
    public var showKeepAwakeHelperApproval: () -> Void = {}

    /// Apps running right now, for picking one onto the agent roster.
    ///
    /// Asked for rather than listed, because the roster is a list of apps
    /// whose preferences Ledge may write and the user should be choosing from
    /// what is actually on their Mac, not typing bundle ids.
    public var runningApps: () -> [(id: String, name: String)] = { [] }

    /// The Chromium-family browsers running now, and whether each was started
    /// with the flags that keep it working behind a shut lid.
    public var runningChromium: () -> [ChromiumBrowser] = { [] }

    /// Whether Accessibility is already granted.
    ///
    /// Kept apart from `SettingsModel.permissions`, which reads the same grant
    /// a different way: this one creates a probe tap, which is what replacing
    /// the system readout actually needs, and the only check that can tell a
    /// grant macOS has not handed over yet from one it has.
    public var isAccessibilityTrusted: () -> Bool

    /// Prompts for a permission. Only ever called from a click.
    ///
    /// There used to be a second closure beside this one for Accessibility
    /// alone, and the shell wired it to exactly this call with exactly that
    /// argument. One seam, so the two cannot drift.
    public var requestPermission: (PermissionKind) -> Void

    /// Opens the System Settings pane that grants it — the only remedy once a
    /// permission has been denied, and the only way in for Accessibility,
    /// whose own prompt macOS shows at most once.
    public var openPermissionSettings: (PermissionKind) -> Void

    /// Re-reads every permission. Cheap, and never prompts.
    public var refreshPermissions: () -> Void

    /// Opens System Settings at Login Items & Extensions.
    ///
    /// Two things live there: the login item macOS may refuse to add, and the
    /// approval a registered daemon waits for.
    public var openLoginItems: () -> Void = {}

    public var setProviderEnabled: (String, Bool) -> Void

    /// Re-opens the first-run tour, and opens the public repository.
    public var showOnboarding: () -> Void
    public var openSource: () -> Void

    /// Asks for the Focus database folder in an open panel. Not a TCC
    /// permission — one folder the user hands over, in place of Full Disk
    /// Access over everything they own. Whether it *is* granted is drawn from
    /// the model, so the row redraws when the answer changes.
    public var chooseFocusFolder: () -> Void

    /// Ends a handoff: cancels the watch, clears the guide and the notch's
    /// lock, and brings Ledge's windows back to floating.
    ///
    /// The one way out of waiting that does not depend on System Settings
    /// doing anything. Without it, a row that was waiting for a switch
    /// somebody decided not to flip waited for four minutes.
    public var stopWaiting: () -> Void = {}

    /// Watches the real notch while a do-it step of the tour is up, and
    /// returns the closure that stops watching.
    ///
    /// The tour teaches two things that cannot be read about — hovering and
    /// dropping — so it watches the thing it is teaching and says when it saw
    /// you. It never blocks on them.
    public var observeNotch: (@escaping @MainActor (TourSignal) -> Void) -> () -> Void = { _ in {} }

    /// Which step of the tour is up, or nil once it is over.
    ///
    /// The shell answers it in the notch: the "This is Ledge" card while
    /// Hover is up, the shelf ears while Drop is, and the step written down
    /// so a tour that Ledge itself ended can be resumed where it stopped.
    public var tourStep: (TourStep?) -> Void = { _ in }

    /// Ledge's own icon, as something draggable.
    ///
    /// `LedgeUI` cannot import AppKit, and a drag source is AppKit all the
    /// way down, so the shell builds the tile and hands it over. Nil where
    /// there is no shell to build one — the preview, the tests — and the
    /// guide then offers only the keyboard path, which is the equal one.
    public var appTile: () -> AnyView? = { nil }

    public init(
        setLaunchAtLogin: @escaping (Bool) -> Bool,
        loginItemStatus: @escaping () -> String,
        copyToClipboard: @escaping (String) -> Void,
        quit: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void = {},
        canCheckForUpdates: @escaping () -> Bool = { true },
        runningApps: @escaping () -> [(id: String, name: String)] = { [] },
        runningChromium: @escaping () -> [ChromiumBrowser] = { [] },
        installKeepAwakeHelper: @escaping () -> KeepAwakeHelperSetupOutcome = { .unavailable },
        showKeepAwakeHelperApproval: @escaping () -> Void = {},
        removeKeepAwakeHelper: @escaping () async -> KeepAwakeHelperRemoval = { .removed },
        isAccessibilityTrusted: @escaping () -> Bool = { false },
        requestPermission: @escaping (PermissionKind) -> Void = { _ in },
        openPermissionSettings: @escaping (PermissionKind) -> Void = { _ in },
        refreshPermissions: @escaping () -> Void = {},
        openLoginItems: @escaping () -> Void = {},
        setProviderEnabled: @escaping (String, Bool) -> Void = { _, _ in },
        showOnboarding: @escaping () -> Void = {},
        openSource: @escaping () -> Void = {},
        chooseFocusFolder: @escaping () -> Void = {},
        stopWaiting: @escaping () -> Void = {},
        observeNotch: @escaping (@escaping @MainActor (TourSignal) -> Void) -> () -> Void = { _ in {} },
        tourStep: @escaping (TourStep?) -> Void = { _ in },
        appTile: @escaping () -> AnyView? = { nil }
    ) {
        self.showOnboarding = showOnboarding
        self.openSource = openSource
        self.setLaunchAtLogin = setLaunchAtLogin
        self.loginItemStatus = loginItemStatus
        self.copyToClipboard = copyToClipboard
        self.quit = quit
        self.checkForUpdates = checkForUpdates
        self.canCheckForUpdates = canCheckForUpdates
        self.runningApps = runningApps
        self.runningChromium = runningChromium
        self.installKeepAwakeHelper = installKeepAwakeHelper
        self.showKeepAwakeHelperApproval = showKeepAwakeHelperApproval
        self.removeKeepAwakeHelper = removeKeepAwakeHelper
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.requestPermission = requestPermission
        self.openPermissionSettings = openPermissionSettings
        self.refreshPermissions = refreshPermissions
        self.openLoginItems = openLoginItems
        self.setProviderEnabled = setProviderEnabled
        self.chooseFocusFolder = chooseFocusFolder
        self.stopWaiting = stopWaiting
        self.observeNotch = observeNotch
        self.tourStep = tourStep
        self.appTile = appTile
    }
}

/// The settings window: five rows for the five questions anybody arrives
/// with, and the tuning panes underneath for whoever is shaping the app.
///
/// Five rather than nine, because the old sidebar was grouped by which
/// subsystem owned the code. "Sound & Brightness" was a pane *and* a card in
/// the list below it, with different settings in each; a card blocked on a
/// permission sent the user to a different pane to grant it; and the readout
/// settings sat two rows away from the card they belong to. A card's own page
/// now holds everything about that card, including the permission it is
/// waiting for and the button that grants it.
public struct SettingsView: View {

    @Bindable private var preferences: Preferences
    private let geometry: NotchGeometry
    private let actions: SettingsActions
    private let model: SettingsModel

    @State private var selection: SettingsPane

    /// Which card's page is open inside Cards. Held here rather than in the
    /// pane so a debug launch can open straight onto one.
    @State private var openCards: [String]

    /// What is in the search field.
    @State private var query = ""

    /// Which row a search result asked to be shown, so the pane it lands on
    /// can point at it for a moment. Cleared by the pane that consumes it.
    @State private var highlighted: String?

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Which Tuning tab a search result asked for, if it asked for one.
    @State private var tuningTab: TuningSettingsTab.Tab?

    /// Goes where a search result says, and leaves the field empty behind it.
    private func open(_ hit: SettingsSearchHit) {
        query = ""
        selection = hit.pane
        openCards = hit.card.map { [$0] } ?? []
        tuningTab = hit.tuningTab
        highlighted = hit.row
    }

    public init(
        preferences: Preferences,
        geometry: NotchGeometry,
        actions: SettingsActions,
        model: SettingsModel = SettingsModel(),
        startPane: String? = nil
    ) {
        self.preferences = preferences
        self.geometry = geometry
        self.actions = actions
        self.model = model
        // A debug launch can open straight onto a pane, or onto one card's
        // page inside Cards: LEDGE_SETTINGS_TAB=card:weather. A caller can
        // ask for one too — the tour's "Choose Cards…" means the Cards list
        // and not wherever the window happens to open.
        let requested = DebugSwitches.value("LEDGE_SETTINGS_TAB")
        _selection = State(
            initialValue: SettingsPane.named(requested) ?? SettingsPane.named(startPane) ?? .general
        )
        _openCards = State(initialValue: SettingsPane.card(named: requested).map { [$0] } ?? [])
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .scrollContentBackground(.hidden)
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
                // The sidebar is the whole navigation; collapsing it leaves a
                // window with no way back to the other panes.
                .toolbar(removing: .sidebarToggle)
                // Where System Settings puts it, and the only thing in this
                // window that answers "I know what it is called but not
                // which pane it is on".
                .searchable(
                    text: $query,
                    placement: .sidebar,
                    prompt: "Search"
                )
        } detail: {
            Group {
                if searching {
                    SettingsSearchResults(
                        query: query,
                        model: model,
                        advanced: preferences.advanced,
                        onOpen: open
                    )
                    .navigationTitle("Search")
                } else {
                    detail
                        // The pane's name belongs in the title bar, which is
                        // where System Settings puts it. An in-content header
                        // with a tinted icon beside it is not a thing macOS
                        // does.
                        .navigationTitle(selection.title)
                }
            }
            .frame(minWidth: 490)
        }
        .navigationSplitViewStyle(.balanced)
        // A result from search points at its row for a moment and then stops:
        // a highlight that stayed would be a selection nobody made. Held by
        // the window rather than by each pane, so moving between panes while
        // one is lit does not leave it lit.
        .task(id: highlighted) {
            guard let mine = highlighted else { return }
            try? await Task.sleep(for: .seconds(1.5))
            // Two guards, and both are needed. A second result cancels this
            // task, and `try?` swallows the cancellation — so without them
            // the older task went on to clear the newer result's highlight
            // the instant it appeared.
            guard !Task.isCancelled, highlighted == mine else { return }
            highlighted = nil
        }
        // A sidebar row lands on the thing it names. Leaving Cards with a
        // card's page open and coming back to that page instead of the list
        // is the window disagreeing with its own sidebar.
        .onChange(of: selection) { _, now in
            if now != .cards { openCards.removeAll() }
        }
        // The whole window sits on a behind-window material, so the wallpaper
        // tints the settings the way macOS Tahoe's own panes are tinted.
        .background(VibrantBackground())
        // Wider and taller than it was by a little: the identity row needs
        // the width at the minimum, and Keep Awake's helper and its length
        // both fit without scrolling at the ideal.
        .frame(minWidth: 690, idealWidth: 720, minHeight: 520, idealHeight: 600)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(SettingsPane.everyday, id: \.self) { row($0) }
            }

            // Only for whoever is tuning the app. See `Prefs.advanced`.
            if preferences.advanced {
                Section("For tuning") {
                    ForEach(SettingsPane.tuningPanes, id: \.self) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ pane: SettingsPane) -> some View {
        HStack(spacing: 6) {
            Label {
                // Two lines rather than an ellipsis: a hidden word tells a
                // new user nothing at all.
                Text(pane.title)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                SettingsIcon.forPane(pane).view
            }
            if pane == .cards, waitingCards > 0 {
                Spacer(minLength: 4)
                // What is stuck, said before the pane is opened. The same
                // count the Cards pane pulls to its top.
                Text("\(waitingCards)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange, in: Capsule())
                    .accessibilityLabel(
                        waitingCards == 1
                            ? "1 card waiting"
                            : "\(waitingCards) cards waiting"
                    )
            }
        }
        .tag(pane)
    }

    private var waitingCards: Int { SettingsBadge.waitingCards(model.providers) }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralSettingsTab(
                preferences: preferences,
                geometry: geometry,
                model: model,
                actions: actions,
                highlighted: highlighted
            )
        case .cards:
            CardsSettingsTab(
                preferences: preferences,
                model: model,
                actions: actions,
                path: $openCards,
                highlighted: highlighted,
                onOpenKeepAwake: { selection = .keepAwake }
            )
        case .keepAwake:
            KeepAwakeSettingsPane(
                preferences: preferences,
                model: model,
                actions: actions,
                highlighted: highlighted
            )
        case .devices:
            DevicesSettingsTab(model: model.devices, highlighted: highlighted)
        case .permissions:
            PermissionsSettingsTab(model: model, actions: actions, highlighted: highlighted)
        case .tuning:
            TuningSettingsTab(
                preferences: preferences,
                geometry: geometry,
                actions: actions,
                requestedTab: $tuningTab,
                highlighted: highlighted
            )
        }
    }
}
