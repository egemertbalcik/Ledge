import LedgeCore
import SwiftUI

/// The first-run tour: what Ledge is, how to drive it, what it may ask for
/// and why, and what it never does.
///
/// Four pages under one hero — a live miniature of the island, drawn with the
/// real shape and the real ears, cycling through the states the text is
/// describing: the bare notch, an announcement, music resting, a timer, the
/// weather. Nothing is a mock-up; what the tour shows is what the notch does.
///
/// The permissions page is live too — every row shows its real state and
/// carries the one button that can change it — so a new user can turn on
/// Calendar or Location right there, with the reason in front of them.
/// Nothing is requested without a click; the tour only offers.
public struct OnboardingView: View {

    private let model: SettingsModel
    private let actions: SettingsActions
    private let openSettings: () -> Void
    private let openSource: () -> Void
    private let finish: () -> Void
    private let deferTour: () -> Void

    // A debug launch can open straight onto a page (LEDGE_ONBOARDING_PAGE=2),
    // so each page can be reviewed without clicking through the tour.
    private static let pageCount = 5
    // Clamped to the last page, not to a number that was the last page once.
    @State private var page: Int

    /// Told the page number whenever it changes, so the tour can be resumed
    /// where it stopped. It can stop without being finished: granting Full
    /// Disk Access from page four makes macOS quit Ledge on the spot.
    private let onPage: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: SettingsModel,
        actions: SettingsActions,
        openSettings: @escaping () -> Void,
        openSource: @escaping () -> Void,
        finish: @escaping () -> Void,
        deferTour: @escaping () -> Void = {},
        startPage: Int = 0,
        onPage: @escaping (Int) -> Void = { _ in }
    ) {
        let debugPage = Int(DebugSwitches.value("LEDGE_ONBOARDING_PAGE") ?? "")
        _page = State(initialValue: min(max(debugPage ?? startPage, 0), Self.pageCount - 1))
        self.onPage = onPage
        self.model = model
        self.actions = actions
        self.openSettings = openSettings
        self.openSource = openSource
        self.finish = finish
        self.deferTour = deferTour
    }

    public var body: some View {
        VStack(spacing: 0) {
            IslandDemo(reduceMotion: reduceMotion, captioned: page == 0)
                .frame(height: 72)

            // Every page gets the *same* box, whatever it holds. Sized by a
            // spacer before, which meant a long page pushed the footer down
            // and a short one let it float up — the buttons moved under the
            // pointer between steps, which is the one thing a wizard must
            // never do. The scroll view is what makes the box hold: a plain
            // frame cannot squeeze a child below the height it insists on, so
            // the permissions page — the tallest, and taller still on a Mac
            // with more permission rows — went on pushing the footer off the
            // bottom edge. Content that does not fit scrolls; the footer never
            // moves.
            ScrollView(.vertical) {
                Group {
                    switch page {
                    case 0: welcome
                    case 1: gestures
                    case 2: cards
                    case 3: permissions
                    default: privacy
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(.bar)
        }
        .frame(width: 480, height: 596)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: page)
        // Keep the observer outside the conditional pages so every step is
        // saved, including those reached before Permissions first appears.
        .onChange(of: page) { _, now in onPage(now) }
    }

    // MARK: - Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Ledge lives in the notch")

            VStack(alignment: .leading, spacing: 14) {
                row("sparkles", "Small news, briefly",
                    "When something happens — AirPods connect, Caps Lock, a charger, a Focus change — the notch widens for a moment, then closes.")
                row("music.note", "Music and timers stay",
                    "While a track plays or a timer runs, it rests at the edges of the notch. Everything else leaves.")
                row("cursorarrow.motionlines", "Hover to open",
                    "Move the cursor onto the notch for the full card. Swipe sideways for the next one.")
                row("rectangle.stack", "Cards, in order of what matters",
                    "Music, calendar, weather, timer, sound and brightness, shelf. A finishing timer comes before a meeting in an hour, which comes before the weather — and nothing reorders while you are looking.")
            }

            Text("You can switch each one off in this tour or in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Two columns of switches and nothing else.
    ///
    /// The point of the page is one fact — *these are yours to turn off* — and
    /// a paragraph making that point would be read by nobody. The switches
    /// make it themselves, and a user who wants none of this can be rid of it
    /// before the app has shown them a single card.
    private var cards: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Yours to switch off")

            let columns = [
                GridItem(.flexible(), spacing: 10, alignment: .leading),
                GridItem(.flexible(), spacing: 10, alignment: .leading),
            ]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(model.providers) { provider in
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        // Pushed to the column's edge so the switches line up
                        // in two straight rails; hung off the end of each
                        // label they read as fifteen unrelated controls.
                        Spacer(minLength: 4)
                        Toggle("", isOn: Binding(
                            get: { provider.isEnabled },
                            set: { actions.setProviderEnabled(provider.id, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("Show \(provider.displayName)")
                    }
                }
            }

            Text("Change your mind any time in Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var gestures: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("How to drive it")

            VStack(alignment: .leading, spacing: 12) {
                gesture("Hover", "Opens the card under the notch. Leave, and it closes.")
                gesture("Click", "Opens the full card. Click again, or move away from the notch, to close it.")
                gesture("Swipe left or right", "Next or previous card. Middle-click does the same.")
                gesture("Volume and brightness keys", "Show a readout in the notch. Hover it for a slider.")
                gesture("Drag files onto the notch", "Keeps them on the shelf until you drag them out. New screenshots land there too.")
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Permissions")
            Text("Every one of these is optional, and each says what it is for. Turn on what you want — nothing is asked for on its own, and you can change any of it later in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                // Full Disk Access is deliberately not offered here. It is the
                // broadest permission macOS has, granting it makes the system
                // quit the app on the spot, and all it buys Ledge is the
                // *name* of the Focus you turned on instead of the word
                // "Focus". That is not a trade to put in front of somebody in
                // their first two minutes. It stays in Settings for anyone who
                // wants the label.
                ForEach(model.permissions) { row in
                    permissionRow(row)
                }
            }

            Text("Works without asking: battery, timers, sound and brightness levels, the shelf, and weather for a city you type in.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { actions.refreshPermissions() }
        // Granting happens in a system dialog outside this window, so the
        // state is re-read rather than assumed.
        .task { await poll() }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Privacy")

            VStack(alignment: .leading, spacing: 14) {
                row("eye.slash", "No screen or audio capture",
                    "There is no capture code in Ledge. The equalizer is generated from the track, not recorded.")
                row("network", "What goes over the network",
                    "Weather (Open-Meteo, coordinates rounded to about a kilometre), the place name (Apple), cover art from the player, and update checks (GitHub). Nothing else.")
                row("internaldrive", "What stays on this Mac",
                    "Settings and shelf paths. Nothing else, and nothing in your keychain.")
                row("chevron.left.forwardslash.chevron.right", "Open source",
                    "The whole app, including every line that touches a permission.")
            }

            Button {
                openSource()
            } label: {
                Label("Read the source on GitHub", systemImage: "arrow.up.right.square")
            }
        }
    }

    // MARK: - Pieces

    /// A footer label carries the width, not the button: a frame on the button
    /// leaves the drawn pill at its natural size, centred in the slot, so
    /// "Done" still looked narrower than the "Continue" it replaced. Widening
    /// the label widens the pill itself.
    private func footerLabel(_ text: String, width: CGFloat) -> some View {
        Text(text).frame(width: width)
    }

    /// The label width, not the pill width: measured at 13pt (the large
    /// control size) "Settings…" is 60.5pt and "Continue" 54.5pt, the widest
    /// each slot ever holds, so the pills stay the size they already were and
    /// only the shorter words — "Back", "Done" — stop shrinking them.
    private static let secondaryButtonWidth: CGFloat = 62
    private static let primaryButtonWidth: CGFloat = 56

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(page + 1) of \(Self.pageCount)")

            Spacer()

            Button("Finish later", action: deferTour)
                .help("Close the tour and resume from this page next time.")

            // Fixed widths, because the words change and the positions must
            // not: "Settings…" is wider than "Back" and "Continue" wider than
            // "Done", so without this every step nudged both buttons sideways
            // and the pointer ended up over a different one than it was over a
            // moment ago. The inner maxWidth makes the drawn pill fill the
            // slot as well — a fixed slot alone leaves a narrower "Done"
            // centred inside it, so its edges still moved.
            if page == 0 {
                Button { openSettings() } label: { footerLabel("Settings…", width: Self.secondaryButtonWidth) }
            } else {
                Button { page -= 1 } label: { footerLabel("Back", width: Self.secondaryButtonWidth) }
            }

            if page < Self.pageCount - 1 {
                Button { page += 1 } label: { footerLabel("Continue", width: Self.primaryButtonWidth) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button { finish() } label: { footerLabel("Done", width: Self.primaryButtonWidth) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ symbol: String, _ heading: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 24, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(.cardTitle)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Gesture on the left in the accent, result on the right — a glossary,
    /// not a feature list.
    private func gesture(_ action: String, _ result: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(action)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange)
                .frame(width: 150, alignment: .leading)
            Text(result)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One permission: name and what it turns on, live status, and the single
    /// useful action.
    private func permissionRow(_ row: PermissionRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: Self.symbol(for: row.kind))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.kind.displayName).font(.cardControl)
                    Text(row.status.summary)
                        .font(.cardCaption)
                        .foregroundStyle(tint(for: row.status))
                }
                Text(Self.unlocks(row.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action(for: row)
                .controlSize(.small)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func action(for row: PermissionRow) -> some View {
        switch row.status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Granted")
        case .notApplicableNow where row.kind.isRequestable:
            // Automation can only be granted against a running player. Hiding
            // the button when none was open left this permission with no way
            // to be granted at all; the button opens Music itself and then
            // asks.
            Button("Open Music…") { actions.requestPermission(row.kind) }
        case .unavailable, .notApplicableNow:
            EmptyView()
        case .notDetermined where row.kind.isRequestable:
            Button("Turn On…") { actions.requestPermission(row.kind) }
        case .notDetermined, .denied:
            Button("System Settings…") { actions.openPermissionSettings(row.kind) }
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

    /// What Ledge does with it, and what it does *not* — because a permission
    /// prompt with no stated reason is a request to be trusted blindly, and the
    /// answer to that should be no.
    private static func unlocks(_ kind: PermissionKind) -> String {
        switch kind {
        case .calendars:
            "Reads your events so the notch can show the next one. Titles and times only, and only to draw them."
        case .location:
            "Asks the weather service what it is like where you are. Your position is rounded to about a kilometre first."
        case .bluetooth:
            "Notices device connections and AirPods case openings as they happen. Occasional battery checks still work without it."
        case .automation:
            "Asks Music and Spotify what is playing, for the cover art and to let you scrub. Nothing else is sent to them."
        case .accessibility:
            "Lets Ledge catch the volume and brightness keys, so its readout replaces the system's grey square instead of appearing under it."
        case .focusStatus:
            "Sees whether a Focus is on, so the notch can say so and stay quiet during one."
        }
    }

    private static func symbol(for kind: PermissionKind) -> String {
        switch kind {
        case .calendars: "calendar"
        case .location: "location.fill"
        case .bluetooth: "airpods"
        case .automation: "music.note"
        case .accessibility: "speaker.wave.2.fill"
        case .focusStatus: "moon.fill"
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

// MARK: - The hero

/// The top of a screen with the island in it, cycling through the states the
/// tour describes. Drawn with the app's own shape and ears, so it is a small
/// truth rather than an illustration.
private struct IslandDemo: View {

    let reduceMotion: Bool
    /// Whether to say what the miniature is, under it — the first page only;
    /// by the second the reader knows.
    let captioned: Bool

    /// The scene: bare notch, then each resting or announced state in turn.
    private enum Scene: Int, CaseIterable {
        case notch, airpods, music, timer, weather
    }

    @State private var scene: Scene = .notch
    @State private var levels: [Double] = []

    private static let cutout = CGSize(width: 180, height: 32)
    private static let earWidth: CGFloat = 53
    private static let gutter: CGFloat = 10

    var body: some View {
        ZStack(alignment: .top) {
            // The screen: a quiet grey with a hairline top edge, so the black
            // reads as hanging from the bezel and not as a floating pill.
            Rectangle()
                .fill(Color.primary.opacity(0.06))
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)

            let open = scene != .notch
            let width = Self.cutout.width + (open ? Self.earWidth * 2 : 0)
            let height = Self.cutout.height + (open ? 0.5 : 0)
            ZStack {
                LedgeShape(bottomRadius: open ? 13 : 9, gutterRadius: Self.gutter, cornerSmoothing: 0.6)
                    .fill(.black)
                if let activity = Self.activity(for: scene) {
                    CompactEarsView(
                        activity: activity,
                        cutoutWidth: Self.cutout.width,
                        inset: Self.gutter,
                        audioLevels: { levels }
                    )
                    .transition(.opacity)
                }
            }
            .frame(width: width + Self.gutter * 2, height: height)
            .clipShape(LedgeShape(bottomRadius: open ? 13 : 9, gutterRadius: Self.gutter, cornerSmoothing: 0.6))
            .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.92), value: scene)

            if captioned {
                VStack {
                    Spacer()
                    Text("Your notch, showing each thing Ledge can put in it")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
                .transition(.opacity)
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The notch, showing an example of each state Ledge draws")
        .task { await run() }
    }

    /// Advances the scene on a slow beat, and feeds the equalizer while the
    /// music scene is up — the same synthesized levels the app uses.
    private func run() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            tick += 1
            if scene == .music {
                levels = LevelSimulator.levels(
                    at: Date().timeIntervalSinceReferenceDate,
                    seed: LevelSimulator.seed(for: "welcome")
                )
            }
            // 2.6 s per scene; the bare notch a touch longer, so the change
            // from "nothing" to "something" is the beat the eye catches.
            let dwell = scene == .notch ? 40 : 33
            if tick >= dwell {
                tick = 0
                let next = Scene(rawValue: (scene.rawValue + 1) % Scene.allCases.count) ?? .notch
                if reduceMotion { scene = next } else {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) { scene = next }
                }
            }
        }
    }

    private static func activity(for scene: Scene) -> Activity? {
        func make(_ payload: ActivityPayload, _ kind: ActivityKind, _ source: String) -> Activity {
            Activity(id: ActivityID(kind: kind, source: "onboarding-\(source)"), createdAt: 0, payload: payload)
        }
        switch scene {
        case .notch:
            return nil
        case .airpods:
            return make(.device(DevicePayload(
                name: "AirPods Pro", symbolName: "airpods.pro",
                batteryLevels: ["Left": 0.8, "Right": 0.8], isConnected: true, isApple: true
            )), .device, "airpods")
        case .music:
            return make(.nowPlaying(NowPlayingPayload(
                title: "Track", artist: "Artist", isPlaying: true,
                accent: AccentColor(red: 0.85, green: 0.45, blue: 0.3)
            )), .nowPlaying, "music")
        case .timer:
            return make(.timer(TimerPayload(
                label: "Focus", remaining: 1052, total: 1500, isRunning: true
            )), .timer, "timer")
        case .weather:
            return make(.weather(WeatherPayload(
                temperatureCelsius: 21, symbolName: "sun.max.fill",
                condition: "Clear", city: "Here", isDay: true
            )), .weather, "weather")
        }
    }
}
