import AppKit
import LedgeCore
import LedgeUI
import SwiftUI

// Stands in for Xcode previews, which are not available without an Xcode
// project. Renders every card and compact state at once, in a normal window, so
// the visual layer can be iterated on without the notch, the panel, or any
// system permission being involved.


/// Stub actions for the harness: every closure is a no-op, so a settings or
/// onboarding window can be opened and looked at without a running shell
/// behind it. Nothing here can prompt for a permission.
@MainActor
private enum PreviewShell {

    static var actions: SettingsActions {
        SettingsActions(
            setLaunchAtLogin: { _ in true },
            loginItemStatus: { "Enabled" },
            copyToClipboard: { _ in },
            quit: {},
            // Enough of a roster for the Keep Awake pane to have rows and a
            // menu with something in it.
            runningApps: {
                [
                    (id: "com.apple.dt.Xcode", name: "Xcode"),
                    (id: "com.google.Chrome", name: "Google Chrome"),
                    (id: "com.figma.Desktop", name: "Figma"),
                ]
            },
            runningChromium: {
                [ChromiumBrowser(bundleID: "com.google.Chrome", name: "Google Chrome", isProtected: false)]
            },
            isAccessibilityTrusted: { true },
            requestPermission: { _ in },
            openPermissionSettings: { _ in },
            refreshPermissions: {},
            setProviderEnabled: { _, _ in },
            showOnboarding: {},
            openSource: {}
        )
    }

    static var model: SettingsModel {
        let m = SettingsModel()
        // Somewhere for the Accessibility guide's tile to point at. Without a
        // location the guide draws "Move Ledge to Applications first", which
        // is a state worth reviewing but not the common one.
        m.appLocation = "/Applications/Ledge.app"

        m.permissions = [
            PermissionRow(kind: .accessibility, status: .granted),
            PermissionRow(kind: .automation, status: .granted),
            PermissionRow(kind: .calendars, status: .notDetermined),
            PermissionRow(kind: .bluetooth, status: .denied),
            PermissionRow(kind: .location, status: .notDetermined),
            PermissionRow(kind: .focusStatus, status: .granted),
        ]
        // LEDGE_ONBOARDING_HANDOFF=accessibility draws the guide instead of
        // the list, which is the state nobody can reach by clicking around a
        // preview: it needs System Settings to be open.
        if let kind = ProcessInfo.processInfo.environment["LEDGE_ONBOARDING_HANDOFF"],
           let permission = PermissionKind(rawValue: kind) {
            m.handoff = PermissionHandoff(
                kind: permission,
                phase: ProcessInfo.processInfo.environment["LEDGE_ONBOARDING_BACK"] == "1"
                    ? .back : .waiting,
                isFirstTime: true
            )
            m.permissions = m.permissions.map {
                $0.kind == permission ? PermissionRow(kind: $0.kind, status: .notDetermined) : $0
            }
            if m.handoff?.phase == .waiting {
                m.beganHandoff(for: permission, isFirstTime: true)
            }
        }
        // Every card the app registers, so the Cards pane is looked at at
        // its real length rather than at four rows. The states that are easy
        // to get wrong are in here on purpose: a card that is on and blocked,
        // a card that is off and blocked, and a card that is simply off.
        m.providers = [
            Self.provider("nowplaying", "Music", .nowPlaying, .automation),
            Self.provider("battery", "Battery", .power, nil),
            Self.provider("bluetooth", "AirPods & Devices", .device, .bluetooth),
            Self.provider("airpods-proximity", "AirPods Case Opens", .device, .bluetooth),
            Self.provider("devicealerts", "Device Battery Alerts", .device, nil),
            Self.provider("audioroute", "Where Sound Goes", .device, nil),
            Self.provider("bluetooth-power", "Bluetooth On & Off", .device, .bluetooth),
            Self.provider("keyboard", "Keyboard Layout", .keyboard, nil),
            // On, and waiting: the one state the row has to say something
            // about.
            Self.provider("capslock", "Caps Lock", .keyboard, .accessibility, available: false),
            Self.provider("calendar", "Calendar", .event, .calendars, enabled: false, available: false),
            Self.provider("focus", "Focus Modes", .focus, .focusStatus),
            Self.provider("weather", "Weather", .weather, .location),
            Self.provider("levels", "Sound & Brightness", .levels, nil),
            Self.provider("timer", "Timer & Stopwatch", .timer, nil),
            Self.provider("keep-awake", "Keep Awake", .keepAwake, nil, enabled: false),
            Self.provider("shelf", "File Shelf", .shelf, nil),
            Self.provider("notes", "Notes", .notes, nil),
            Self.provider("privacy", "Camera & Mic", .privacy, nil),
        ]
        m.mediaSource = .systemWide(host: "MediaRemote")
        m.keepAwakeHelper = .needsApproval
        m.devices = devices
        return m
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

    /// A catalogue with the states the Devices pane has to draw: this Mac
    /// charging, a disconnected mouse, and a pinned set of earbuds nobody has
    /// heard from in a while.
    static var devices: DevicesSettingsModel {
        let now = Date()
        var built = DeviceCatalogue()
        built.devices = [
            DeviceRecord(
                id: .thisMac, name: "MacBook Pro", presence: .connected,
                readings: [BatteryReading(component: .main, level: 0.88, charging: .charging, observedAt: now)],
                firstSeen: now.addingTimeInterval(-86_400),
                lastSeen: now.addingTimeInterval(-30)
            ),
            DeviceRecord(
                id: .bluetooth("airpods"), name: "AirPods Pro", presence: .connected,
                readings: [
                    BatteryReading(component: .left, level: 0.62, observedAt: now),
                    BatteryReading(component: .right, level: 0.58, observedAt: now),
                    BatteryReading(component: .case, level: 0.93, observedAt: now),
                ],
                firstSeen: now.addingTimeInterval(-86_400),
                lastSeen: now.addingTimeInterval(-45), isPinned: true
            ),
            DeviceRecord(
                id: .bluetooth("mouse"), name: "Magic Mouse", presence: .disconnected,
                readings: [BatteryReading(component: .main, level: 0.21, observedAt: now.addingTimeInterval(-7200))],
                firstSeen: now.addingTimeInterval(-864_000), lastSeen: now.addingTimeInterval(-7200)
            ),
        ]
        let catalogue = built
        // A day of readings per earbud, falling slowly, so the chart has a
        // line rather than the "not enough history yet" sentence.
        let samples: [BatterySample] = built.devices[1].readings.flatMap { reading in
            (0..<48).map { step in
                BatterySample(
                    component: reading.component,
                    level: min(1, reading.level + Double(47 - step) * 0.008),
                    charging: .notCharging,
                    at: now.addingTimeInterval(-Double(step) * 1800),
                    isConnected: true
                )
            }
        }
        let model = DevicesSettingsModel(
            actions: .init(load: { catalogue }, history: { _ in samples })
        )
        model.load()
        // LEDGE_SETTINGS_DEVICE=airpods opens one device's page, which is the
        // only way to look at it without clicking — and the pane that had the
        // least looking at.
        if let wanted = ProcessInfo.processInfo.environment["LEDGE_SETTINGS_DEVICE"] {
            model.select(DeviceIdentity.bluetooth(wanted))
        }
        return model
    }

    static var geometry: NotchGeometry {
        NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 180, height: 32),
            notchCenterX: 735,
            isHardwareNotch: true
        )
    }
}

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var tourPage = 0
    private let previewsOnboarding = ProcessInfo.processInfo.environment["LEDGE_GALLERY_ONLY"] == "onboarding"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The parity gallery: one named state, in the production container, at
        // an explicit scale, exported whole. Handled before anything else
        // because it builds its own window and answers on stdout.
        if let name = ProcessInfo.processInfo.environment["LEDGE_GALLERY_STATE"] {
            renderState(named: name)
            return
        }
        let only = ProcessInfo.processInfo.environment["LEDGE_GALLERY_ONLY"]
        let size: NSSize = switch only {
        case "settings": NSSize(width: 700, height: 560)
        case "onboarding": NSSize(
            width: OnboardingView.contentSize.width,
            height: OnboardingView.contentSize.height
        )
        case "layout": NSSize(width: 700, height: 680)
        default: NSSize(width: 560, height: 1000)
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Ledge — Card Gallery"
        switch only {
        case "settings":
            window.contentView = NSHostingView(rootView: SettingsView(
                preferences: Preferences(store: MemoryPreferenceStore()),
                geometry: PreviewShell.geometry,
                actions: PreviewShell.actions,
                model: PreviewShell.model
            ))
        case "onboarding":
            installTour(in: window)
        case "layout":
            window.contentView = NSHostingView(rootView: LayoutGalleryView())
        default:
            window.contentView = NSHostingView(rootView: GalleryView())
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        // LEDGE_GALLERY_SHOT=/path/to.png renders the window once and quits, so
        // a layout question can be answered by looking rather than reasoning.
        if let path = ProcessInfo.processInfo.environment["LEDGE_GALLERY_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Self.snapshot(window, to: path)
                NSApp.terminate(nil)
            }
        }
    }

    /// In-memory progress keeps this harness separate from the real app's
    /// preferences. Click the Dock icon after closing to check resumption.
    private func installTour(in window: NSWindow) {
        let hosting = NSHostingView(rootView: OnboardingView(
            model: PreviewShell.model,
            actions: PreviewShell.actions,
            openSettings: {},
            openSource: {},
            finish: { [weak self] in
                self?.tourPage = 0
                self?.window?.close()
            },
            startStep: TourStep(rawValue: tourPage) ?? .hover
        ))
        hosting.sizingOptions = []
        window.contentView = hosting
        let size = NSSize(
            width: OnboardingView.contentSize.width,
            height: OnboardingView.contentSize.height
        )
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard previewsOnboarding, let window else { return true }
        if !window.isVisible { installTour(in: window) }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    /// Renders one catalogue state and reports what it produced.
    ///
    /// `LEDGE_GALLERY_STATE=list` prints the catalogue instead, so the script
    /// driving this never carries its own copy of the names — a list in two
    /// places is a list that disagrees with itself.
    private func renderState(named name: String) {
        if name == "list" {
            for state in StateGallery.states { print(state.name) }
            NSApp.terminate(nil)
            return
        }
        guard let state = StateGallery.state(named: name) else {
            FileHandle.standardError.write(Data("unknown state: \(name)\n".utf8))
            exit(2)
        }
        let mac = StateGallery.mac(named: ProcessInfo.processInfo.environment["LEDGE_GALLERY_MAC"])
        let size = NotchLayout.panelSize(for: mac.geometry)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        // The app's panel is transparent around the shape; a white window
        // behind it would make every edge test meaningless.
        window.backgroundColor = .clear
        window.isOpaque = false
        let hosting = NSHostingView(rootView: StateGallery.view(for: state, mac: mac))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        self.window = window

        guard let path = ProcessInfo.processInfo.environment["LEDGE_GALLERY_SHOT"] else {
            FileHandle.standardError.write(Data("LEDGE_GALLERY_SHOT is required\n".utf8))
            exit(2)
        }
        // The state's own kind, so the calendar's wider seat is reported as
        // the calendar's rather than as the width every other card gets.
        let probe = NotchPresentation()
        state.apply(probe)
        let kind = probe.selected?.kind

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let report = Self.export(window, to: path, name: state.name, mac: mac, kind: kind)
            print(report)
            NSApp.terminate(nil)
        }
    }

    /// Writes the PNG and says what it contains, as one JSON line.
    ///
    /// The clipping test is the reason this is not just a file write: the
    /// panel reserves room for the tallest card plus a margin, so content
    /// reaching the left, right or bottom edge of that panel means something
    /// was cut off. The top edge is exempt — the shape is *meant* to be flush
    /// with the screen's top, which is where the cutout is.
    private static func export(
        _ window: NSWindow, to path: String, name: String,
        mac: StateGallery.Mac, kind: ActivityKind?
    ) -> String {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return "{\"name\":\"\(name)\",\"error\":\"no view\"}" }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return "{\"name\":\"\(name)\",\"error\":\"no png\"}"
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            return "{\"name\":\"\(name)\",\"error\":\"write failed\"}"
        }
        let clipped = clippedEdges(of: rep)
        let edges = clipped.map { "\"\($0)\"" }.joined(separator: ",")
        let geometry = mac.geometry
        return """
            {"name":"\(name)","mac":"\(mac.rawValue)",\
            "scale":\(geometry.displayScale),\
            "notch":"\(Int(geometry.notchSize.width))x\(Int(geometry.notchSize.height))",\
            "kind":"\(kind?.rawValue ?? "none")",\
            "cardWidth":\(NotchLayout.cardWidth(kind: kind, geometry: geometry)),\
            "width":\(rep.pixelsWide),"height":\(rep.pixelsHigh),\
            "clipped":[\(edges)]}
            """
    }

    /// Which edges of the export have something drawn on them.
    private static func clippedEdges(of rep: NSBitmapImageRep) -> [String] {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard width > 2, height > 2 else { return ["degenerate"] }

        func inked(_ x: Int, _ y: Int) -> Bool {
            // Anything meaningfully opaque. The shape's own edges are
            // antialiased, so a hair of alpha is not content.
            (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.35
        }

        var edges: [String] = []
        if (0..<width).contains(where: { inked($0, height - 1) }) { edges.append("bottom") }
        if (0..<height).contains(where: { inked(0, $0) }) { edges.append("left") }
        if (0..<height).contains(where: { inked(width - 1, $0) }) { edges.append("right") }
        return edges
    }

    private static func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !previewsOnboarding
    }
}

/// Real overlay geometry at the largest supported display scale and card height.
/// The window crops only the unused sides of the full-width synthetic panel.
@MainActor
private struct LayoutGalleryView: View {
    private static let geometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 180, height: 38),
        notchCenterX: 735, isHardwareNotch: true, displayScale: 1.2
    )
    @State private var preferences: Preferences
    @State private var presentation: NotchPresentation
    @State private var rainy = false
    @State private var routeCount = 3

    init() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.expandedHeight = NotchLayout.maximumExpandedHeight
        let presentation = NotchPresentation()
        presentation.phase = .expanded
        presentation.selected = PreviewFixtures.nowPlaying
        presentation.count = 2
        _preferences = State(initialValue: preferences)
        _presentation = State(initialValue: presentation)
    }

    var body: some View {
        let panelSize = NotchLayout.panelSize(for: Self.geometry)
        VStack(spacing: 10) {
            HStack {
                Picker("Card", selection: $rainy) {
                    Text("Music").tag(false)
                    Text("Rainy Weather").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("Outputs", selection: $routeCount) {
                    ForEach([1, 3, 5], id: \.self) { Text("\($0)").tag($0) }
                }
                .frame(width: 140)
                .disabled(rainy)
            }
            .padding(.horizontal)
            Text("Scale 1.20 · notch 38 pt · Height 440 pt · panel \(panelSize.height, specifier: "%.1f") pt. Open Music’s audio output button to inspect rows.")
                .font(.caption)
                .foregroundStyle(.secondary)
            NotchOverlayView(
                geometry: Self.geometry, preferences: preferences,
                presentation: presentation,
                nowPlayingActions: NowPlayingActions(outputs: {
                    (1...routeCount).map { index in
                        AudioOutputOption(
                            id: UInt32(index), name: "Preview Output \(index)",
                            isCurrent: index == 1, level: 0.6
                        )
                    }
                })
            )
            .id(routeCount)
            .frame(width: panelSize.width, height: panelSize.height)
            .frame(width: 700)
            .background(Color.gray.opacity(0.16))
            .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(.orange).frame(height: 1) }
        }
        .padding(.top, 12)
        .frame(width: 700)
        .onChange(of: rainy) { _, value in
            presentation.routePickerRows = 0
            presentation.selectedIndex = value ? 1 : 0
            presentation.selected = value ? Activity(
                id: ActivityID(kind: .weather, source: "preview.rain"), createdAt: 0,
                payload: .weather(WeatherPayload(
                    temperatureCelsius: 24, symbolName: "cloud.rain.fill",
                    condition: "Rain arriving", city: "Preview City",
                    hourly: PreviewFixtures.previewHours, rainSoonMinutes: 15
                ))
            ) : PreviewFixtures.nowPlaying
        }
        .onChange(of: routeCount) { _, _ in presentation.routePickerRows = 0 }
    }
}

struct GalleryView: View {

    private let cutoutWidth: CGFloat = 179

    /// Separate builder: the gallery's else-if chain is already at the edge
    /// of what the type-checker will chew.
    @ViewBuilder
    private var compactPaneSection: some View {
        // The drafts belong to whoever shows the pane; the preview is that
        // owner here, and it starts them at the defaults.
        CompactSettingsTab(
            preferences: Preferences(store: MemoryPreferenceStore()),
            geometry: NotchGeometry(
                screenSize: CGSize(width: 1470, height: 956),
                notchSize: CGSize(width: 180, height: 32),
                notchCenterX: 735,
                isHardwareNotch: true
            ),
            widthDraft: $earWidthDraft,
            leadingDraft: $earLeadingDraft,
            trailingDraft: $earTrailingDraft
        )
        .frame(width: 560, height: 860)
    }

    @State private var earWidthDraft = NotchLayout.defaultEarWidth
    @State private var earLeadingDraft: CGFloat = 0
    @State private var earTrailingDraft: CGFloat = 0

    /// The timer's ears at several points through a countdown, which is the
    /// only way to see a dial actually move without waiting out a session.
    @ViewBuilder
    private var timerEarsSection: some View {
        section("Timer ears through a countdown") {
            ForEach([1.0, 0.75, 0.45, 0.15, 0.02], id: \.self) { left in
                card {
                    CompactEarsView(
                        activity: PreviewFixtures.timerAt(remaining: left),
                        cutoutWidth: cutoutWidth,
                        inset: 10
                    )
                    .frame(width: PreviewFixtures.cardWidth, height: 34)
                }
            }
            card {
                CompactEarsView(
                    activity: PreviewFixtures.timerBreak,
                    cutoutWidth: cutoutWidth,
                    inset: 10
                )
                .frame(width: PreviewFixtures.cardWidth, height: 34)
            }
        }
    }

    /// The calendar at the heights the shell would now give it, framed so any
    /// clipping or leftover black shows up rather than being absorbed.
    @ViewBuilder
    private var calendarSection: some View {
        section("Calendar months, sized to their depth") {
            ForEach([-1, 0, 1], id: \.self) { offset in
                card {
                    CalendarSized(offset: offset)
                }
            }
        }
    }

    /// The greeting, frame by frame: every beat of the script on the notch's
    /// own black, so the performance can be judged without relaunching.
    @ViewBuilder
    private var eyesSection: some View {
        section("The greeting, beat by beat") {
            ForEach(Array(GreetingState.script().enumerated()), id: \.offset) { _, beat in
                card {
                    HStack(spacing: 0) {
                        NotchGreetingEyes(side: .leading, state: beat.state)
                            .frame(maxWidth: .infinity)
                        Color.clear.frame(width: cutoutWidth)
                        NotchGreetingEyes(side: .trailing, state: beat.state)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 10)
                    .frame(width: 420, height: 34)
                    .background(.black)
                }
            }
        }
    }

    /// The weather and levels cards at the heights the shell gives them, with
    /// the page dots where the overlay draws them — the gap under the content
    /// is what this is for.
    @ViewBuilder
    private var bottomsSection: some View {
        section("Card bottoms against the page dots") {
            card {
                BottomGap(height: NotchLayout.expandedContentSize(
                    kind: .weather, phase: .expanded,
                    base: CGSize(width: PreviewFixtures.cardWidth, height: 0)
                ).height) {
                    WeatherCardView(payload: Self.staleWeather)
                }
            }
            card {
                BottomGap(height: NotchLayout.expandedContentSize(
                    kind: .weather, phase: .expanded,
                    base: CGSize(width: PreviewFixtures.cardWidth, height: 0),
                    payload: .weather(Self.rainWeather)
                ).height) {
                    WeatherCardView(payload: Self.rainWeather)
                }
            }
            card {
                BottomGap(height: NotchLayout.expandedContentSize(
                    kind: .levels, phase: .expanded,
                    base: CGSize(width: PreviewFixtures.cardWidth, height: 0)
                ).height) {
                    LevelsCardView(rows: PreviewFixtures.levelRows())
                }
            }
        }
    }

    /// Each Clock face at the height the shell would now give it, with the
    /// page dots where the overlay puts them.
    @ViewBuilder
    private var timerHeightsSection: some View {
        section("Clock faces, sized to their content") {
            card { TimerSized(payload: PreviewFixtures.timerIdlePayload, label: "launcher") }
            card { TimerSized(payload: PreviewFixtures.timerRunningPayload, label: "countdown") }
            card { TimerSized(payload: PreviewFixtures.stopwatchPayload, label: "stopwatch") }
        }
    }

    /// The media card at full width. Run with `LEDGE_SHOW_OUTPUTS=1` to get
    /// the route menu instead of the player, which is how the two are compared
    /// for the margins they keep.
    @ViewBuilder
    private var mediaSection: some View {
        section("Media card") {
            card {
                NowPlayingCardView(
                    payload: PreviewFixtures.nowPlayingPayload,
                    actions: NowPlayingActions(outputs: {
                        [
                            AudioOutputOption(
                                id: 1, name: "MacBook Pro Speakers", isCurrent: true, level: 0.55
                            ),
                            AudioOutputOption(
                                id: 2, name: "AirPods Pro", isCurrent: false, level: 0.4
                            ),
                        ]
                    })
                )
                .frame(width: PreviewFixtures.cardWidth, height: 164)
                .border(.red.opacity(0.6))
            }
        }
    }

    /// Separate builder for the same reason as the compact pane: the chain
    /// below is already at the type-checker's limit.
    @ViewBuilder
    private var weatherSection: some View {
        section("Weather states") {
            card { WeatherCardView(payload: Self.staleWeather).frame(width: PreviewFixtures.cardWidth, height: 186) }
            // Rain due, in the shape the overlay actually gives it: the
            // 32pt cutout reserved at the top and the page dots sitting over
            // the bottom. Rendered at the old height and the new one, so the
            // overlap and its fix are visible side by side rather than argued
            // about.
            card { Self.rainInShape(height: 186) }
            card { Self.rainInShape(height: Self.rainCardHeight) }
            card { Self.inShape(Self.staleWeather, height: 186) }
            // Fresh reading: no freshness line expected.
            card { WeatherCardView(payload: Self.freshWeather).frame(width: PreviewFixtures.cardWidth, height: 90) }
        }
    }

    /// A long name with a device fix behind it: the arrow shows, and the
    /// freshness line must survive the squeeze intact.
    private static let staleWeather = WeatherPayload(
        temperatureCelsius: 24,
        symbolName: "sun.max.fill",
        condition: "Clear",
        city: "San Cristóbal de La Laguna",
        highCelsius: 27,
        lowCelsius: 18,
        hourly: PreviewFixtures.previewHours,
        // 40 minutes stale, so the freshness line shows.
        fetchedAt: Date().timeIntervalSinceReferenceDate - 2_400,
        usesDeviceLocation: true
    )

    private static let rainWeather = WeatherPayload(
        temperatureCelsius: 24,
        symbolName: "cloud.sun.fill",
        condition: "Partly Cloudy",
        city: "Lisbon",
        highCelsius: 27,
        lowCelsius: 18,
        hourly: PreviewFixtures.previewHours,
        fetchedAt: Date().timeIntervalSinceReferenceDate - 2_400,
        rainSoonMinutes: 60
    )

    private static let freshWeather = WeatherPayload(
        temperatureCelsius: 24,
        symbolName: "sun.max.fill",
        condition: "Clear",
        city: "Lisbon",
        fetchedAt: Date().timeIntervalSinceReferenceDate - 30
    )

    /// The rain card as the overlay draws it — cutout allowance above, dots
    /// over the bottom edge.
    private static func rainInShape(height: CGFloat) -> some View {
        inShape(rainWeather, height: height)
    }

    private static func inShape(_ payload: WeatherPayload, height: CGFloat) -> some View {
        WeatherCardView(payload: payload)
            .padding(.top, 32)
            .frame(width: PreviewFixtures.cardWidth, height: height, alignment: .top)
            .overlay(alignment: .bottom) {
                PageDots(count: 3, selectedIndex: 1).padding(.bottom, 7)
            }
            .border(.red.opacity(0.6))
    }

    private static let rainCardHeight = NotchLayout.expandedContentSize(
        kind: .weather,
        phase: .expanded,
        base: CGSize(width: PreviewFixtures.cardWidth, height: 0),
        payload: .weather(rainWeather)
    ).height

    var body: some View {
        // LEDGE_GALLERY_ONLY=calendar renders just that section, so a snapshot
        // harness does not have to fight the scroll position.
        let only = ProcessInfo.processInfo.environment["LEDGE_GALLERY_ONLY"]
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if only == "split" {
                    section("Companion, resting vs split") {
                        card { SplitPreview(satellite: nil) }
                        card { SplitPreview(satellite: .level(HUDReadout(kind: .brightness, level: 0.62))) }
                        card { SplitPreview(satellite: .timer(remaining: 754, total: 1500, isBreak: false, isRunning: true)) }
                        card { SplitPreview(satellite: .timer(remaining: 5400, total: 7200, isBreak: false, isRunning: true)) }
                        card { SplitPreview(satellite: .privacy(camera: true, microphone: true)) }
                        card { SplitPreview(satellite: .device(symbolName: "airpods.gen3", tint: .neutral)) }
                        card { SplitPreview(satellite: nil, timerIsland: true) }
                        card { SplitPreview(
                            satellite: .level(HUDReadout(kind: .volume, level: 0.4)),
                            timerIsland: true
                        ) }
                    }
                } else if only == "empty" {
                    section("Empty card") {
                        card {
                            EmptyHintsView(onStartTimer: {})
                                .frame(width: PreviewFixtures.cardWidth)
                                .padding(.vertical, 12)
                        }
                    }
                } else if only == "weather" {
                    weatherSection
                } else if only == "timerears" {
                    timerEarsSection
                } else if only == "ears" {
                    section("Compact ears") {
                        ForEach([
                            PreviewFixtures.weather, PreviewFixtures.event,
                            PreviewFixtures.capsOn, PreviewFixtures.capsOff,
                        ], id: \.id) { activity in
                            card {
                                CompactEarsView(
                                    activity: activity,
                                    cutoutWidth: cutoutWidth,
                                    inset: 10
                                )
                                .frame(width: PreviewFixtures.cardWidth, height: 34)
                            }
                        }
                    }
                } else if only == "compact" {
                    compactPaneSection
                } else if only == "levels" {
                    section("Levels card") {
                        card {
                            LevelsCardView(rows: PreviewFixtures.levelRows())
                            .frame(width: PreviewFixtures.cardWidth)
                        }
                    }
                } else if only == "eyes" {
                    eyesSection
                } else if only == "bottoms" {
                    bottomsSection
                } else if only == "timerheights" {
                    timerHeightsSection
                } else if only == "timer" {
                    section("Timer states") {
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.timerIdle))
                                .frame(width: PreviewFixtures.cardWidth)
                        }
                        // The ready card at duo width: the number and the one
                        // button, with no room for the recent lengths.
                        card {
                            TimerCardView(
                                payload: PreviewFixtures.payload(of: PreviewFixtures.timerIdle),
                                isCompactWidth: true
                            )
                            .frame(width: 190)
                        }
                        // Shut and open, at one digit, two and three. The
                        // control keeps its width and its place across all six
                        // — it is dragged, and a control that resizes under the
                        // hand dragging it is the bug this slot exists to
                        // catch — and the number stays over the marker.
                        ForEach([5, 45, 180], id: \.self) { minutes in
                            card {
                                TimerCardView(payload: PreviewFixtures.timerIdlePayload(minutes: minutes))
                                    .frame(width: PreviewFixtures.cardWidth)
                            }
                            card {
                                TimerCardView(
                                    payload: PreviewFixtures.timerIdlePayload(minutes: minutes),
                                    startsRulerOpen: true
                                )
                                .frame(width: PreviewFixtures.cardWidth)
                            }
                        }
                        // Paused and finished are states nobody can click their
                        // way to on demand, so the gallery holds them.
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.timerFinished))
                                .frame(width: PreviewFixtures.cardWidth)
                        }
                        card {
                            TimerCardView(
                                payload: PreviewFixtures.payload(of: PreviewFixtures.timerIdle),
                                startsOnFace: .focus
                            )
                            .frame(width: PreviewFixtures.cardWidth)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.timer))
                                .frame(width: PreviewFixtures.cardWidth)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.timerBreak))
                                .frame(width: PreviewFixtures.cardWidth)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.timerCustom))
                                .frame(width: PreviewFixtures.cardWidth)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.stopwatchRunning))
                                .frame(width: PreviewFixtures.cardWidth)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.stopwatchStopped))
                                .frame(width: PreviewFixtures.cardWidth)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.timerIdleRecents))
                                .frame(width: PreviewFixtures.cardWidth)
                        }
                    }
                } else if only == "media" {
                    mediaSection
                } else if only == "calendar" {
                    calendarSection
                } else {
                // The calendar has its own card, reached only from the overlay
                // at full width — the generic row below is what the *narrow*
                // layout falls back to, so the grid never appeared here.
                section("Calendar") {
                    card {
                        CalendarExpandedView(payload: PreviewFixtures.eventPayload)
                            .frame(width: PreviewFixtures.calendarCardWidth)
                    }
                    // Day 6 has four events, so this also shows the overflow
                    // line the three-row cap produces.
                    card {
                        CalendarExpandedView(
                            payload: PreviewFixtures.eventPayload,
                            selectedDay: 6
                        )
                        .frame(width: PreviewFixtures.calendarCardWidth)
                    }
                    card {
                        CalendarExpandedView(
                            payload: PreviewFixtures.eventPayload,
                            selectedDay: 13
                        )
                        .frame(width: PreviewFixtures.cardWidth)
                    }
                }

                section("Expanded cards") {
                    ForEach(PreviewFixtures.all, id: \.id) { activity in
                        card {
                            // Mirror the overlay's routing: the calendar has
                            // its own full-width card the generic view never
                            // reaches, and skipping it here would review a
                            // layout the app doesn't show.
                            if case .event(let payload) = activity.payload {
                                CalendarExpandedView(payload: payload)
                                    .frame(width: PreviewFixtures.cardWidth)
                            } else {
                                ActivityCardView(activity: activity)
                            }
                        }
                    }
                }

                section("Duo pair") {
                    card {
                        HStack(spacing: 0) {
                            ActivityCardView(activity: PreviewFixtures.nowPlaying, isCompactWidth: true)
                            Divider().overlay(.white.opacity(0.12))
                            ActivityCardView(activity: PreviewFixtures.event, isCompactWidth: true)
                        }
                    }
                }

                section("Compact ears") {
                    ForEach(PreviewFixtures.all, id: \.id) { activity in
                        card {
                            CompactEarsView(
                                activity: activity,
                                cutoutWidth: cutoutWidth,
                                inset: 10
                            )
                            .frame(height: 36)
                        }
                    }
                }

                section("Page dots") {
                    card {
                        VStack(spacing: 10) {
                            PageDots(count: 4, selectedIndex: 0)
                            PageDots(count: 4, selectedIndex: 2)
                            PageDots(count: 1, selectedIndex: 0)
                        }
                        .padding(10)
                    }
                }
                }
            }
            .padding(20)
        }
        .background(Color(white: 0.13))
    }

    @ViewBuilder
    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func card(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black)
            )
    }
}

/// The hour every preview and every export is drawn at.
///
/// 2026-09-14 09:41:00 UTC — the hour Apple puts on every device it ships.
/// Nonisolated on purpose: both the gallery, which is main-actor, and the
/// fixtures, which are not, have to agree about what day it is, and the day
/// they disagreed about put a Join capsule beside "No events".
enum PreviewClock {
    static let fixed = Date(timeIntervalSince1970: 1_789_378_860)
}

/// Invented sample data. Deliberately generic so nothing here is mistaken for
/// real content.
enum PreviewFixtures {

    /// The Mac the section gallery is pretending to be: the reference one,
    /// always.
    ///
    /// Deliberately not scaled. Production lays a card out in reference units
    /// and then applies `scaleEffect(displayScale)` to the whole thing, so a
    /// bare card drawn at a *scaled* width is a layout no Mac performs — wider
    /// in the same type. Scale belongs to the state gallery, which renders
    /// through the production container and gets the scaling with it.
    static let galleryGeometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 179, height: 32),
        notchCenterX: 735,
        isHardwareNotch: true
    )

    /// What an open card is actually this wide in the app — asked of the same
    /// function the shell asks, rather than a literal that drifted to 348 and
    /// made every review 16% too generous.
    static let cardWidth = NotchLayout.cardWidth(kind: nil, geometry: galleryGeometry)

    /// The calendar keeps its own fixed seat.
    static let calendarCardWidth = NotchLayout.cardWidth(kind: .event, geometry: galleryGeometry)


    static let nowPlaying = Activity(
        id: ActivityID(kind: .nowPlaying, source: "preview"),
        createdAt: 0,
        payload: .nowPlaying(NowPlayingPayload(
            title: "Sample Track",
            artist: "Placeholder Artist",
            album: "Preview Album",
            isPlaying: true,
            elapsed: 74,
            duration: 208,
            sourceName: "Preview Player",
            accent: AccentColor(red: 0.85, green: 0.36, blue: 0.28)
        ))
    )

    static let nowPlayingPayload = NowPlayingPayload(
        title: "Sample Track",
        artist: "Placeholder Artist",
        album: "Preview Album",
        isPlaying: true,
        elapsed: 74,
        duration: 208,
        sourceName: "Preview Player",
        accent: AccentColor(red: 0.85, green: 0.36, blue: 0.28),
        // An app's card, so the gallery exercises the doorway behind it.
        ownerIsApp: true
    )

    /// The longest thing a card ever carries: a title that cannot fit at any
    /// width, so the row either marquees it or pushes its neighbours out.
    static let longTitleNowPlaying = Activity(
        id: ActivityID(kind: .nowPlaying, source: "preview.long"),
        createdAt: 0,
        payload: .nowPlaying(NowPlayingPayload(
            title: "Everything In Its Right Place (Live at the Royal Albert Hall, Remastered)",
            artist: "An Artist With A Considerably Longer Name Than Usual",
            album: "Preview Album",
            isPlaying: true,
            elapsed: 74,
            duration: 208,
            sourceName: "Preview Player",
            accent: AccentColor(red: 0.85, green: 0.36, blue: 0.28),
            ownerIsApp: true
        ))
    )

    static let device = Activity(
        id: ActivityID(kind: .device, source: "preview"),
        createdAt: 0,
        payload: .device(DevicePayload(
            name: "Sample Earbuds",
            symbolName: "airpods.gen3",
            batteryLevels: ["Case": 0.92, "Left": 0.81, "Right": 0.78]
        ))
    )

    static let power = Activity(
        id: ActivityID(kind: .power, source: "preview"),
        createdAt: 0,
        payload: .power(PowerPayload(
            percentage: 0.17,
            isCharging: false,
            isLowPower: true,
            timeRemaining: 2400
        ))
    )

    static let focus = Activity(
        id: ActivityID(kind: .focus, source: "preview"),
        createdAt: 0,
        payload: .focus(FocusPayload(name: "Deep Work"))
    )

    static let event = Activity(
        id: ActivityID(kind: .event, source: "preview"),
        createdAt: 0,
        payload: .event(eventPayload)
    )

    /// The day these fixtures call "today".
    ///
    /// The gallery's own fixed clock, not the wall clock. Read from `Date()`,
    /// today's two events were filed under the real day number while the card
    /// was drawn at 14 September — so the one exported calendar card showed a
    /// green Join capsule beside "No events / This day is clear", which is a
    /// state the app cannot produce. It also made the export differ from
    /// yesterday's for no reason anyone could act on, which is exactly what
    /// `gallery.sh` fails the build over.
    static let todayDay = Calendar.current.component(.day, from: PreviewClock.fixed)

    static let timerFinished = Activity(
        id: ActivityID(kind: .timer, source: "finished"),
        createdAt: 0,
        payload: .timer(TimerPayload(
            label: "Timer",
            remaining: 0,
            total: 25 * 60,
            isRunning: false,
            isFinished: true,
            isBreak: false,
            completedSessions: 0,
            isCustom: true,
            isIdle: false,
            mode: .countdown,
            stopwatch: StopwatchState(),
            recents: [25, 5]
        ))
    )

    static let eventPayload = EventPayload(
            title: "Design review",
            location: "Room 2",
            startsIn: 240,
            endsIn: 240 + 45 * 60,
            accent: AccentColor(red: 0.36, green: 0.55, blue: 0.9),
            hasEvent: true,
            meetingURL: "https://zoom.us/j/123456",

            // Enough days to exercise the dot row and the tap-a-day detail,
            // which is otherwise only reachable with a real calendar grant.
            monthEventDays: [Self.todayDay, 4, 6, 11, 18, 25].sorted(),
            monthEvents: [
                // Today, which is what the card opens on: two events *and* a
                // meeting to join. That pair used to be unshowable — the Join
                // capsule took the list's room and the column counted the
                // events instead of naming them.
                MonthDayEvents(day: Self.todayDay, entries: [
                    MonthDayEntry(title: "Standup", time: "09:30"),
                    MonthDayEntry(title: "Design review", time: "11:00"),
                ]),
                MonthDayEvents(day: 4, entries: [
                    MonthDayEntry(title: "Design review", time: "10:00"),
                    MonthDayEntry(title: "Standup", time: "14:30"),
                ]),
                // An all-day event first, then long titles: the two cases the
                // single-line, time-gutter layout could not show.
                MonthDayEvents(day: 6, entries: [
                    MonthDayEntry(title: "Quarterly planning offsite", time: ""),
                    MonthDayEntry(title: "Dentist appointment downtown", time: "09:15"),
                    MonthDayEntry(title: "Lunch with Sam", time: "12:00"),
                    MonthDayEntry(title: "Retro", time: "16:00"),
                ]),
                MonthDayEvents(day: 11, entries: [
                    MonthDayEntry(title: "Flight to Berlin", time: "07:40"),
                ]),
                // The worst case for the day column: every visible title long
                // enough to wrap, and more of them than can be shown. This is
                // what used to run under the page dots.
                MonthDayEvents(day: 18, entries: [
                    MonthDayEntry(title: "Quarterly planning offsite with the whole team", time: "09:00"),
                    MonthDayEntry(title: "Dentist appointment downtown near the station", time: "11:30"),
                    MonthDayEntry(title: "Interview with the new platform candidate", time: "14:00"),
                    MonthDayEntry(title: "Retro and roadmap review", time: "16:00"),
                    MonthDayEntry(title: "Dinner with the visiting team", time: "19:30"),
                ]),
            ],
            monthWindows: [
                MonthWindow(year: 2026, month: 7, eventDays: [14, 22], events: [
                    MonthDayEvents(day: 14, entries: [
                        MonthDayEntry(title: "July retro", time: "15:00"),
                    ]),
                ]),
                MonthWindow(year: 2026, month: 8, eventDays: [4, 6, 11, 18, 25], events: [
                    MonthDayEvents(day: 4, entries: [
                        MonthDayEntry(title: "Design review", time: "10:00"),
                        MonthDayEntry(title: "Standup", time: "14:30"),
                    ]),
                    MonthDayEvents(day: 6, entries: [
                        MonthDayEntry(title: "Quarterly planning offsite", time: ""),
                        MonthDayEntry(title: "Dentist appointment downtown", time: "09:15"),
                        MonthDayEntry(title: "Lunch with Sam", time: "12:00"),
                        MonthDayEntry(title: "Retro", time: "16:00"),
                    ]),
                    MonthDayEvents(day: 11, entries: [
                        MonthDayEntry(title: "Flight to Berlin", time: "07:40"),
                    ]),
                    // The worst case for the day column: every visible title
                    // long enough to wrap, and more of them than fit. This is
                    // what used to run under the page dots.
                    MonthDayEvents(day: 18, entries: [
                        MonthDayEntry(title: "Quarterly planning offsite with the whole team", time: "09:00"),
                        MonthDayEntry(title: "Dentist appointment downtown near the station", time: "11:30"),
                        MonthDayEntry(title: "Interview with the new platform candidate", time: "14:00"),
                        MonthDayEntry(title: "Retro and roadmap review", time: "16:00"),
                        MonthDayEntry(title: "Dinner with the visiting team", time: "19:30"),
                    ]),
                ]),
                // Today lives in this window, not only in the flat fields
                // above: the card reads the window whenever there is one, and
                // the flat list is a fallback for payloads written before
                // windows existed. With today missing from here, the one
                // exported calendar card showed a Join capsule beside "No
                // events" — a state the app itself cannot produce.
                MonthWindow(
                    year: 2026,
                    month: 9,
                    eventDays: [2, Self.todayDay].sorted(),
                    events: [
                        MonthDayEvents(day: 2, entries: [
                            MonthDayEntry(title: "September kickoff", time: "09:00"),
                        ]),
                        MonthDayEvents(day: Self.todayDay, entries: [
                            MonthDayEntry(title: "Standup", time: "09:30"),
                            MonthDayEntry(title: "Design review", time: "11:00"),
                        ]),
                    ]
                ),
            ]
    )

    static let message = Activity(
        id: ActivityID(kind: .message, source: "preview"),
        createdAt: 0,
        payload: .message(MessagePayload(
            title: "Build finished",
            body: "27 tests passed"
        ))
    )


    static let timer = Activity(
        id: ActivityID(kind: .timer, source: "preview"),
        createdAt: 0,
        payload: .timer(TimerPayload(
            label: "Focus",
            remaining: 17 * 60 + 32,
            total: 25 * 60,
            isRunning: true,
            completedSessions: 2
        ))
    )

    /// A 25-minute session with a given fraction of it left.
    static func timerAt(remaining: Double) -> Activity {
        let total: TimeInterval = 25 * 60
        return Activity(
            id: ActivityID(kind: .timer, source: "preview"),
            createdAt: 0,
            payload: .timer(TimerPayload(
                label: "Focus",
                remaining: total * remaining,
                total: total,
                isRunning: true,
                completedSessions: 2
            ))
        )
    }

    static let timerIdlePayload = TimerPayload(
        label: "Focus", remaining: 0, total: 0, isRunning: false, isIdle: true, recents: [15, 45]
    )

    static let timerRunningPayload = TimerPayload(
        label: "Focus", remaining: 754, total: 1500, isRunning: true, completedSessions: 2
    )

    static let stopwatchPayload = TimerPayload(
        label: "Stopwatch", remaining: 1234, total: 0, isRunning: true, mode: .stopwatch
    )

    static let timerBreak = Activity(
        id: ActivityID(kind: .timer, source: "preview-break"),
        createdAt: 0,
        payload: .timer(TimerPayload(
            label: "Break",
            remaining: 90,
            total: 5 * 60,
            isRunning: false,
            isBreak: true,
            completedSessions: 3
        ))
    )

    /// Real Finder icons, so the tiles look like they will in the app.
    private static func shelfItem(_ path: String) -> ShelfItem {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 64, height: 64)
        let data = icon.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }
            .flatMap { $0.representation(using: .png, properties: [:]) }
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return ShelfItem(
            path: path,
            name: (path as NSString).lastPathComponent,
            isDirectory: isDirectory.boolValue,
            iconData: data
        )
    }

    static let shelf = Activity(
        id: ActivityID(kind: .shelf, source: "preview"),
        createdAt: 0,
        payload: .shelf(ShelfPayload(items: [
            shelfItem("/System/Applications/Notes.app"),
            shelfItem("/Users/Shared"),
            shelfItem("/usr/bin/perl"),
        ]))
    )

    static let weather = Activity(
        id: ActivityID(kind: .weather, source: "preview"),
        createdAt: 0,
        payload: .weather(WeatherPayload(
            temperatureCelsius: 24,
            symbolName: "sun.max.fill",
            condition: "Clear",
            city: "Lisbon",
            highCelsius: 27,
            lowCelsius: 18,
            hourly: previewHours,
            fetchedAt: Date().timeIntervalSinceReferenceDate - 2_400
        ))
    )

    static let previewHours: [WeatherHourPayload] = (0..<6).map { (index: Int) in
        WeatherHourPayload(
            hour: (14 + index) % 24,
            temperatureCelsius: 24 - Double(index),
            symbolName: index < 3 ? "sun.max.fill" : "cloud.sun.fill",
            isNow: index == 0
        )
    }

    static let privacy = Activity(
        id: ActivityID(kind: .privacy, source: "preview"),
        createdAt: 0,
        payload: .privacy(PrivacyPayload(cameraActive: true, micActive: true))
    )

    static let keyboard = Activity(
        id: ActivityID(kind: .keyboard, source: "preview"),
        createdAt: 0,
        payload: .keyboard(KeyboardLayoutPayload(name: "Turkish Q", code: "TR"))
    )

    /// Every kind, once, so the gallery is a complete review surface — a card
    /// missing here is a card that never gets looked at.
    static let timerIdle = Activity(
        id: ActivityID(kind: .timer, source: "preview-idle"),
        createdAt: 0,
        payload: .timer(TimerPayload(
            label: "Timer",
            remaining: 25 * 60,
            total: 25 * 60,
            isRunning: false,
            isIdle: true
        ))
    )

    /// The ready card at a given length, for checking that the number stays
    /// over the ruler's marker as it grows: one digit, two, three.
    static func timerIdlePayload(minutes: Int) -> TimerPayload {
        TimerPayload(
            label: "Timer",
            remaining: TimeInterval(minutes * 60),
            total: TimeInterval(minutes * 60),
            isRunning: false,
            isIdle: true,
            recents: [minutes]
        )
    }

    /// The timer payload out of a fixture, for the section that renders the
    /// card directly.
    static func payload(of activity: Activity) -> TimerPayload {
        if case .timer(let payload) = activity.payload { return payload }
        return TimerPayload(label: "Timer", remaining: 0, total: 0)
    }

    static let levels = levelsCard()

    /// The card, with rows. It used to be photographed with none, so every
    /// picture of it was two empty bars over a fixture that said 55% and 80%.
    static func levelsCard(
        volume: Double? = 0.55,
        muted: Bool = false,
        external: Bool = false,
        note: LevelRow.Note? = nil,
        brightness: Double? = 0.8,
        tag: String = "preview"
    ) -> Activity {
        Activity(
            id: ActivityID(kind: .levels, source: tag),
            createdAt: 0,
            payload: .levels(LevelsPayload(
                volume: volume ?? 0, brightness: brightness ?? 0, isMuted: muted,
                rows: levelRows(volume: volume, muted: muted, external: external,
                                note: note, brightness: brightness)
            ))
        )
    }

    /// The stopwatch face, running with two laps — the fixture's clock is
    /// the wall clock, so it counts up live in the gallery.
    static let stopwatchRunning = Activity(
        id: ActivityID(kind: .timer, source: "preview-stopwatch"),
        createdAt: 0,
        payload: .timer(TimerPayload(
            label: "Stopwatch", remaining: 95, total: 0, isRunning: true,
            mode: .stopwatch,
            stopwatch: StopwatchState(
                elapsedBase: 0,
                runningSince: Date().timeIntervalSinceReferenceDate - 95.4,
                laps: [31.2, 64.8]
            )
        ))
    )

    static let stopwatchStopped = Activity(
        id: ActivityID(kind: .timer, source: "preview-stopwatch-stopped"),
        createdAt: 0,
        payload: .timer(TimerPayload(
            label: "Stopwatch", remaining: 754.2, total: 0, isRunning: false,
            mode: .stopwatch,
            stopwatch: StopwatchState(elapsedBase: 754.2, laps: [200, 410])
        ))
    )

    static let timerIdleRecents = Activity(
        id: ActivityID(kind: .timer, source: "preview-idle-recents"),
        createdAt: 0,
        payload: .timer(TimerPayload(
            label: "Timer", remaining: 25 * 60, total: 25 * 60,
            isRunning: false, isIdle: true, recents: [20, 90]
        ))
    )

    static let timerCustom = Activity(
        id: ActivityID(kind: .timer, source: "preview-custom"),
        createdAt: 0,
        payload: .timer(TimerPayload(
            label: "Timer",
            remaining: 41 * 60 + 12,
            total: 45 * 60,
            isRunning: true,
            isCustom: true
        ))
    )

    static let capsOn = Activity(
        id: ActivityID(kind: .keyboard, source: "preview-caps-on"),
        createdAt: 0,
        payload: .keyboard(KeyboardLayoutPayload(
            name: "Caps Lock On", code: "⇪", symbolName: "capslock.fill"
        ))
    )

    static let capsOff = Activity(
        id: ActivityID(kind: .keyboard, source: "preview-caps-off"),
        createdAt: 0,
        payload: .keyboard(KeyboardLayoutPayload(
            name: "Caps Lock Off", code: "⇪", symbolName: "textformat.abc"
        ))
    )

    static let all: [Activity] = [
        nowPlaying, weather, event, timerIdle, timer, timerBreak,
        device, power, focus, shelf, message, privacy, keyboard, levels,
    ]
}

let application = NSApplication.shared
let delegate = PreviewDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()


/// The real overlay, forced into the companion phase — resting and split — so
/// the satellite geometry can be eyeballed without chasing live playback.
/// One month, in a frame the size the shell would draw for it.
/// A card at its shell height, with the cutout above and the dots below.
struct BottomGap<Content: View>: View {
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 32)
            content
        }
        .frame(width: PreviewFixtures.cardWidth, height: height, alignment: .top)
        .border(.red.opacity(0.6))
        .overlay(alignment: .bottom) {
            PageDots(count: 3, selectedIndex: 1).padding(.bottom, 7)
        }
    }
}

/// One Clock face, framed the way the shell would frame it.
struct TimerSized: View {
    let payload: TimerPayload
    let label: String
    @State private var content: CGFloat = 0

    var body: some View {
        let height = NotchLayout.timerHeight(contentHeight: content)
        VStack(spacing: 0) {
            Color.clear.frame(height: 32)          // the cutout allowance
            TimerCardView(payload: payload, onContentHeight: { content = $0 })
        }
        .frame(width: PreviewFixtures.cardWidth, height: height, alignment: .top)
        .border(.red.opacity(0.6))
        .overlay(alignment: .bottom) {
            PageDots(count: 3, selectedIndex: 1).padding(.bottom, 7)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(label) · content \(Int(content))pt · card \(Int(height))pt")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
        }
    }
}

struct CalendarSized: View {
    let offset: Int
    @State private var rows = 0

    var body: some View {
        let height = NotchLayout.calendarHeight(weekRows: rows)
        CalendarExpandedView(
            payload: PreviewFixtures.eventPayload,
            selectedDay: 18,
            monthOffset: offset,
            onWeekRows: { rows = $0 }
        )
        .padding(.top, 32)   // the cutout allowance the overlay adds
        .frame(width: NotchLayout.calendarWidth, height: height, alignment: .top)
        .border(.red.opacity(0.6))
        .overlay(alignment: .bottom) {
            // Where the overlay puts them, so a grid growing into them shows.
            PageDots(count: 3, selectedIndex: 1).padding(.bottom, 7)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(rows) rows · \(Int(height))pt")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
        }
    }
}

struct SplitPreview: View {
    let satellite: SatelliteContent?
    var timerIsland = false

    var body: some View {
        let geometry = NotchGeometry(
            screenSize: CGSize(width: 900, height: 500),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: 450,
            isHardwareNotch: true
        )
        let presentation = NotchPresentation()
        presentation.phase = .companion
        if timerIsland {
            let session = Activity(
                id: ActivityID(kind: .timer, source: "session"),
                createdAt: 0,
                payload: .timer(TimerPayload(
                    label: "Focus", remaining: 812, total: 1500, isRunning: true
                ))
            )
            presentation.selected = session
            presentation.timerSession = session
        } else {
            let playing = Activity(
                id: ActivityID(kind: .nowPlaying, source: "preview"),
                createdAt: 0,
                payload: .nowPlaying(NowPlayingPayload(
                    title: "Track", artist: "Artist", isPlaying: true,
                    accent: AccentColor(red: 0.85, green: 0.4, blue: 0.3)
                ))
            )
            presentation.selected = playing
            presentation.nowPlaying = playing
        }
        presentation.count = 1
        presentation.hudSatellite = satellite
        return NotchOverlayView(
            geometry: geometry,
            preferences: Preferences(store: MemoryPreferenceStore()),
            presentation: presentation
        )
        .frame(width: 900, height: 70, alignment: .top)
        .background(Color(white: 0.75))
        .clipped()
    }
}
