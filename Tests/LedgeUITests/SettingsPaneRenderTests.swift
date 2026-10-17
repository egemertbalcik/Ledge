import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// Every settings pane, drawn in the states that are awkward to reach by
/// clicking: a Mac with no notch, a card blocked on a permission, a permission
/// that has been refused, each of the Keep Awake helper's four states, and a
/// window with no device catalogue behind it.
///
/// Rendering is not a look at the design. It does prove the states compose,
/// lay out, and produce a bitmap rather than collapsing — which is what the
/// panes stopped doing every time one of them grew a section.
@Suite("Settings pane rendering", .serialized)
@MainActor
struct SettingsPaneRenderTests {

    /// The detail column's own widths: its minimum, the window's ideal, and a
    /// stretched window.
    private static let widths: [CGFloat] = [440, 464, 620]

    private static func preferences() -> Preferences {
        Preferences(store: MemoryPreferenceStore())
    }

    private static func geometry(notched: Bool = true) -> NotchGeometry {
        NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: notched ? CGSize(width: 180, height: 32) : .zero,
            notchCenterX: 735,
            isHardwareNotch: notched
        )
    }

    private static func provider(
        _ id: String, _ name: String, _ kind: ActivityKind, _ permission: PermissionKind?,
        enabled: Bool = true, available: Bool = true
    ) -> ProviderDescriptor {
        ProviderDescriptor(
            id: id, displayName: name, kind: kind, permission: permission,
            isEnabled: enabled, isAvailable: available
        )
    }

    /// A model with one card of every shape the list has to draw.
    private static func model() -> SettingsModel {
        let model = SettingsModel()
        model.permissions = PermissionKind.allCases.enumerated().map { index, kind in
            let statuses: [PermissionStatus] =
                [.granted, .denied, .notDetermined, .unavailable, .notApplicableNow]
            return PermissionRow(kind: kind, status: statuses[index % statuses.count])
        }
        model.providers = [
            provider("nowplaying", "Music", .nowPlaying, .automation),
            provider("levels", "Sound & Brightness", .levels, nil),
            provider("weather", "Weather", .weather, .location),
            provider("timer", "Timer & Stopwatch", .timer, nil),
            provider("shelf", "File Shelf", .shelf, nil),
            provider("keep-awake", "Keep Awake", .keepAwake, nil, enabled: false),
            // On and blocked — the row that has to say what it is waiting for.
            provider("capslock", "Caps Lock", .keyboard, .accessibility, available: false),
            // Off and blocked — the row that must say nothing at all.
            provider("calendar", "Calendar", .event, .calendars, enabled: false, available: false),
            // Not in any group, so the "More" section is drawn too.
            provider("something-new", "Something New", .device, nil),
        ]
        return model
    }

    private func render(_ view: some View, width: CGFloat) -> CGSize? {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 2
        return renderer.nsImage?.size
    }

    private func checkRenders(
        _ view: some View,
        _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for width in Self.widths {
            let size = render(view, width: width)
            #expect(size != nil, "\(what) produced no image at \(width)pt", sourceLocation: sourceLocation)
            if let size {
                #expect(
                    size.height > 0,
                    "\(what) collapsed to zero height at \(width)pt",
                    sourceLocation: sourceLocation
                )
            }
        }
    }

    @Test("General renders, with and without a notch to draw in")
    func general() {
        for notched in [true, false] {
            checkRenders(
                GeneralSettingsTab(
                    preferences: Self.preferences(),
                    geometry: Self.geometry(notched: notched),
                    model: Self.model(),
                    actions: SettingsActions.preview,
                    highlighted: nil
                ),
                notched ? "general" : "general on a Mac with no notch"
            )
        }
    }

    @Test("The whole card list renders, blocked rows and all")
    func cards() {
        checkRenders(
            CardsSettingsTab(
                preferences: Self.preferences(),
                model: Self.model(),
                actions: SettingsActions.preview,
                path: .constant([])
            ),
            "card list"
        )
    }

    @Test("Every card that has a page renders it")
    func cardPages() {
        let model = Self.model()
        for provider in model.providers where CardRowPresentation.hasSettings(provider.id) {
            checkRenders(
                CardDetailPane(
                    id: provider.id,
                    preferences: Self.preferences(),
                    model: model,
                    actions: SettingsActions.preview
                ),
                "the \(provider.displayName) page"
            )
        }
    }

    /// A card id with no descriptor behind it — which is what a page opened by
    /// the debug switch gets when the provider is not registered at all.
    @Test("A card that does not exist says so instead of drawing nothing")
    func unknownCardPage() {
        checkRenders(
            CardDetailPane(
                id: "not-a-card",
                preferences: Self.preferences(),
                model: Self.model(),
                actions: SettingsActions.preview
            ),
            "an unknown card"
        )
    }

    @Test("The Keep Awake page renders in every state its helper can be in")
    func keepAwakeHelperStates() {
        for state in [KeepAwakeHelperInstallation.unsignedBuild, .notInstalled, .needsApproval, .installed] {
            let model = Self.model()
            model.keepAwakeHelper = state
            checkRenders(
                CardDetailPane(
                    id: "keep-awake",
                    preferences: Self.preferences(),
                    model: model,
                    actions: SettingsActions.preview
                ),
                "Keep Awake with the helper \(state.rawValue)"
            )
        }
    }

    @Test("Music renders whatever Ledge can currently see")
    func mediaSourceStates() {
        for source in [MediaSourceStatus.systemWide(host: "MediaRemote"), .degraded(retryingInSeconds: 90), .playersOnly] {
            let model = Self.model()
            model.mediaSource = source
            checkRenders(
                CardDetailPane(
                    id: "nowplaying",
                    preferences: Self.preferences(),
                    model: model,
                    actions: SettingsActions.preview
                ),
                "Music with \(source.headline)"
            )
        }
    }

    @Test("Permissions renders every status, and the terminal warning")
    func permissions() {
        for fromTerminal in [false, true] {
            let model = Self.model()
            model.isLaunchedFromTerminal = fromTerminal
            checkRenders(
                PermissionsSettingsTab(model: model, actions: SettingsActions.preview),
                fromTerminal ? "permissions, launched from a terminal" : "permissions"
            )
        }
    }

    /// The preview and any test without a catalogue land here, and so does a
    /// shell that could not open the file. It used to be a bare sentence with
    /// no pane around it.
    @Test("Devices says so when there is no catalogue behind it")
    func devicesWithoutACatalogue() {
        checkRenders(DevicesSettingsTab(model: nil), "devices with no catalogue")
    }

    /// About folded into General, so its own rows are checked there. What is
    /// checked here is the pane that replaced the rest of it.
    @Test("Keep Awake's own pane renders in every state the helper has")
    func keepAwake() {
        for state in [KeepAwakeHelperInstallation.notInstalled, .needsApproval, .installed, .unsignedBuild] {
            let model = Self.model()
            model.keepAwakeHelper = state
            checkRenders(
                KeepAwakeSettingsPane(
                    preferences: Self.preferences(),
                    model: model,
                    actions: SettingsActions.preview
                ),
                "keep awake, helper \(state)"
            )
        }
    }

    @Test("Search renders, with results and without")
    func search() {
        for query in ["lid", "city", "nothing matches this"] {
            checkRenders(
                SettingsSearchResults(
                    query: query,
                    model: Self.model(),
                    advanced: true,
                    onOpen: { _ in }
                ),
                "search for \(query)"
            )
        }
    }

    @Test("The tuning panes render")
    func tuningPanes() {
        checkRenders(
            AppearanceSettingsTab(preferences: Self.preferences(), geometry: Self.geometry()),
            "shape & motion"
        )
        checkRenders(
            TuningSettingsTab(
                preferences: Self.preferences(),
                geometry: Self.geometry(),
                actions: SettingsActions.preview
            ),
            "tuning"
        )
        checkRenders(
            CompactSettingsTab(
                preferences: Self.preferences(),
                geometry: Self.geometry(),
                widthDraft: .constant(NotchLayout.defaultEarWidth),
                leadingDraft: .constant(0),
                trailingDraft: .constant(0)
            ),
            "compact ears"
        )
    }
}

extension SettingsActions {
    /// Every closure a no-op, so a pane can be drawn without a shell behind
    /// it. Nothing here can prompt for a permission.
    static var preview: SettingsActions {
        SettingsActions(
            setLaunchAtLogin: { _ in true },
            loginItemStatus: { "Enabled" },
            copyToClipboard: { _ in },
            quit: {},
            runningApps: { [(id: "com.apple.dt.Xcode", name: "Xcode")] },
            runningChromium: {
                [ChromiumBrowser(bundleID: "com.google.Chrome", name: "Google Chrome", isProtected: false)]
            },
            isAccessibilityTrusted: { true }
        )
    }
}
