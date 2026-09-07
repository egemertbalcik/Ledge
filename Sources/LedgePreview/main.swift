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
            isAccessibilityTrusted: { true },
            requestAccessibility: {},
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
        m.permissions = [
            PermissionRow(kind: .accessibility, status: .granted),
            PermissionRow(kind: .automation, status: .granted),
            PermissionRow(kind: .calendars, status: .notDetermined),
            PermissionRow(kind: .bluetooth, status: .denied),
            PermissionRow(kind: .location, status: .notDetermined),
            PermissionRow(kind: .focusStatus, status: .granted),
            PermissionRow(kind: .fullDiskAccess, status: .notDetermined),
        ]
        m.providers = [
            ProviderDescriptor(id: "nowplaying", displayName: "Now Playing", kind: .nowPlaying,
                               permission: .automation, isEnabled: true, isAvailable: true),
            ProviderDescriptor(id: "timer", displayName: "Timer", kind: .timer,
                               permission: nil, isEnabled: true, isAvailable: true),
            ProviderDescriptor(id: "weather", displayName: "Weather", kind: .weather,
                               permission: .location, isEnabled: true, isAvailable: false),
            ProviderDescriptor(id: "calendar", displayName: "Calendar", kind: .event,
                               permission: .calendars, isEnabled: false, isAvailable: false),
        ]
        return m
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let only = ProcessInfo.processInfo.environment["LEDGE_GALLERY_ONLY"]
        let size: NSSize = switch only {
        case "settings": NSSize(width: 700, height: 560)
        case "onboarding": NSSize(width: 480, height: 596)
        default: NSSize(width: 560, height: 1000)
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
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
            window.contentView = NSHostingView(rootView: OnboardingView(
                model: PreviewShell.model,
                actions: PreviewShell.actions,
                openSettings: {},
                openSource: {},
                finish: {}
            ))
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

    private static func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct GalleryView: View {

    private let cutoutWidth: CGFloat = 179

    /// Separate builder: the gallery's else-if chain is already at the edge
    /// of what the type-checker will chew.
    @ViewBuilder
    private var compactPaneSection: some View {
        CompactSettingsTab(
            preferences: Preferences(store: MemoryPreferenceStore()),
            geometry: NotchGeometry(
                screenSize: CGSize(width: 1470, height: 956),
                notchSize: CGSize(width: 180, height: 32),
                notchCenterX: 735,
                isHardwareNotch: true
            )
        )
        .frame(width: 560, height: 860)
    }

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
                    .frame(width: 348, height: 34)
                }
            }
            card {
                CompactEarsView(
                    activity: PreviewFixtures.timerBreak,
                    cutoutWidth: cutoutWidth,
                    inset: 10
                )
                .frame(width: 348, height: 34)
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
                    base: CGSize(width: 348, height: 0)
                ).height) {
                    WeatherCardView(payload: Self.staleWeather)
                }
            }
            card {
                BottomGap(height: NotchLayout.expandedContentSize(
                    kind: .weather, phase: .expanded,
                    base: CGSize(width: 348, height: 0),
                    payload: .weather(Self.rainWeather)
                ).height) {
                    WeatherCardView(payload: Self.rainWeather)
                }
            }
            card {
                BottomGap(height: NotchLayout.expandedContentSize(
                    kind: .levels, phase: .expanded,
                    base: CGSize(width: 348, height: 0)
                ).height) {
                    LevelsCardView(actions: LevelsActions(
                        outputs: { [AudioOutputOption(
                            id: 1, name: "MacBook Pro Speakers", isCurrent: true, level: 0.55
                        )] },
                        displays: { [DisplayLevelOption(
                            id: 1, name: "Built-in Display", isCurrent: true, isBuiltIn: true, level: 0.8
                        )] }
                    ))
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
                .frame(width: 348, height: 164)
                .border(.red.opacity(0.6))
            }
        }
    }

    /// Separate builder for the same reason as the compact pane: the chain
    /// below is already at the type-checker's limit.
    @ViewBuilder
    private var weatherSection: some View {
        section("Weather states") {
            card { WeatherCardView(payload: Self.staleWeather).frame(width: 348, height: 186) }
            // Rain due, in the shape the overlay actually gives it: the
            // 32pt cutout reserved at the top and the page dots sitting over
            // the bottom. Rendered at the old height and the new one, so the
            // overlap and its fix are visible side by side rather than argued
            // about.
            card { Self.rainInShape(height: 186) }
            card { Self.rainInShape(height: Self.rainCardHeight) }
            card { Self.inShape(Self.staleWeather, height: 186) }
            // Fresh reading: no freshness line expected.
            card { WeatherCardView(payload: Self.freshWeather).frame(width: 348, height: 90) }
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
            .frame(width: 348, height: height, alignment: .top)
            .overlay(alignment: .bottom) {
                PageDots(count: 3, selectedIndex: 1).padding(.bottom, 7)
            }
            .border(.red.opacity(0.6))
    }

    private static let rainCardHeight = NotchLayout.expandedContentSize(
        kind: .weather,
        phase: .expanded,
        base: CGSize(width: 348, height: 0),
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
                                .frame(width: 348)
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
                                .frame(width: 348, height: 34)
                            }
                        }
                    }
                } else if only == "compact" {
                    compactPaneSection
                } else if only == "levels" {
                    section("Levels card") {
                        card {
                            LevelsCardView(actions: LevelsActions(
                                outputs: { [AudioOutputOption(
                                    id: 1, name: "MacBook Pro Speakers",
                                    isCurrent: true, level: 0.55
                                )] },
                                displays: { [DisplayLevelOption(
                                    id: 1, name: "Built-in Display",
                                    isCurrent: true, isBuiltIn: true, level: 0.8
                                )] }
                            ))
                            .frame(width: 348)
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
                                .frame(width: 348)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.timer))
                                .frame(width: 348)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.timerBreak))
                                .frame(width: 348)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.timerCustom))
                                .frame(width: 348)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.stopwatchRunning))
                                .frame(width: 348)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.stopwatchStopped))
                                .frame(width: 348)
                        }
                        card {
                            TimerCardView(payload: PreviewFixtures.payload(of: PreviewFixtures.timerIdleRecents))
                                .frame(width: 348)
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
                            .frame(width: 348)
                    }
                    // Day 6 has four events, so this also shows the overflow
                    // line the three-row cap produces.
                    card {
                        CalendarExpandedView(
                            payload: PreviewFixtures.eventPayload,
                            selectedDay: 6
                        )
                        .frame(width: 348)
                    }
                    card {
                        CalendarExpandedView(
                            payload: PreviewFixtures.eventPayload,
                            selectedDay: 13
                        )
                        .frame(width: 348)
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
                                    .frame(width: 348)
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

/// Invented sample data. Deliberately generic so nothing here is mistaken for
/// real content.
enum PreviewFixtures {

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

    static let eventPayload = EventPayload(
            title: "Design review",
            location: "Room 2",
            startsIn: 240,
            accent: AccentColor(red: 0.36, green: 0.55, blue: 0.9),
            hasEvent: true,
            meetingURL: "https://zoom.us/j/123456",

            // Enough days to exercise the dot row and the tap-a-day detail,
            // which is otherwise only reachable with a real calendar grant.
            monthEventDays: [4, 6, 11, 18, 25],
            monthEvents: [
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
                MonthWindow(year: 2026, month: 9, eventDays: [2], events: [
                    MonthDayEvents(day: 2, entries: [
                        MonthDayEntry(title: "September kickoff", time: "09:00"),
                    ]),
                ]),
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

    /// The timer payload out of a fixture, for the section that renders the
    /// card directly.
    static func payload(of activity: Activity) -> TimerPayload {
        if case .timer(let payload) = activity.payload { return payload }
        return TimerPayload(label: "Timer", remaining: 0, total: 0)
    }

    static let levels = Activity(
        id: ActivityID(kind: .levels, source: "preview"),
        createdAt: 0,
        payload: .levels(LevelsPayload(volume: 0.55, brightness: 0.8))
    )

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
        .frame(width: 348, height: height, alignment: .top)
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
        .frame(width: 348, height: height, alignment: .top)
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
