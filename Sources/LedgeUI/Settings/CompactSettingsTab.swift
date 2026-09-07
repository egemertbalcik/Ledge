import LedgeCore
import SwiftUI

/// The Compact pane: every compact view the island can show, line by line,
/// rendered live against the *draft* values — ear width and the two content
/// nudges — so the effect is visible before anything touches the real notch.
/// Apply writes the preferences in one go; the shell observes the landing.
public struct CompactSettingsTab: View {

    @Bindable var preferences: Preferences
    let geometry: NotchGeometry

    public init(preferences: Preferences, geometry: NotchGeometry) {
        self.preferences = preferences
        self.geometry = geometry
    }

    /// Drafts, seeded from the live preferences on appear. The sliders edit
    /// these; the island keeps its current look until Apply.
    @State private var widthDraft: CGFloat = NotchLayout.defaultEarWidth
    @State private var leadingDraft: CGFloat = 0
    @State private var trailingDraft: CGFloat = 0

    private var isDirty: Bool {
        widthDraft != preferences.earWidth
            || leadingDraft != preferences.earLeadingOffset
            || trailingDraft != preferences.earTrailingOffset
    }

    private var isDefault: Bool {
        widthDraft == NotchLayout.defaultEarWidth
            && leadingDraft == 0 && trailingDraft == 0
    }

    public var body: some View {
        Form {
            Section("Adjust") {
                LabeledSlider("Ear width", value: $widthDraft, in: 36...90, format: "%.0f")
                LabeledSlider("Leading nudge", value: $leadingDraft, in: -20...20, format: "%.0f")
                LabeledSlider("Trailing nudge", value: $trailingDraft, in: -20...20, format: "%.0f")
                HStack {
                    Text("Positive nudges move content toward the cutout. Width also sets every open card under the one-width rule.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        widthDraft = NotchLayout.defaultEarWidth
                        leadingDraft = 0
                        trailingDraft = 0
                    }
                    .disabled(isDefault)
                    Button("Apply") {
                        preferences.earWidth = widthDraft
                        preferences.earLeadingOffset = leadingDraft
                        preferences.earTrailingOffset = trailingDraft
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty)
                }
            }

            Section("Preview — the hatched block is the hardware notch") {
                ForEach(Self.samples, id: \.title) { sample in
                    HStack(spacing: 10) {
                        Text(sample.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Spacer(minLength: 0)
                        previewRow(sample.activity)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            widthDraft = preferences.earWidth
            leadingDraft = preferences.earLeadingOffset
            trailingDraft = preferences.earTrailingOffset
        }
    }

    /// One island at draft dimensions: black body, the real ears view inside,
    /// and the cutout region hatched so the hardware is unmistakable.
    private func previewRow(_ activity: Activity) -> some View {
        // Preview at 2/3 scale so wide drafts still fit the pane. The frame
        // is fixed BEFORE scaling and re-fixed after, so the Form's row
        // cannot stretch the island and unseat the hatch from the cutout.
        let scale: CGFloat = 0.66
        let cutout = geometry.notchSize.width
        let width = cutout + widthDraft * 2
        let height = geometry.notchSize.height + 1
        return ZStack {
            UnevenRoundedRectangle(
                cornerRadii: .init(bottomLeading: 10, bottomTrailing: 10),
                style: .continuous
            )
            .fill(.black)

            CompactEarsView(
                activity: activity,
                cutoutWidth: cutout,
                inset: preferences.gutterRadius,
                leadingOffset: leadingDraft,
                trailingOffset: trailingDraft
            )
            .environment(\.weatherUnits, preferences.weatherUnits)

            // The hardware notch, hatched and seated exactly over the centre
            // cutout: content may never draw here, and the preview says so
            // instead of leaving a black void.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HatchedBlock()
                    .frame(width: cutout, height: height)
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .scaleEffect(scale)
        .frame(width: width * scale, height: height * scale)
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// Diagonal hatching over the cutout region.
    private struct HatchedBlock: View {
        var body: some View {
            Canvas { context, size in
                context.stroke(
                    Path { path in
                        var x: CGFloat = -size.height
                        while x < size.width {
                            path.move(to: CGPoint(x: x, y: size.height))
                            path.addLine(to: CGPoint(x: x + size.height, y: 0))
                            x += 7
                        }
                    },
                    with: .color(.white.opacity(0.18)),
                    lineWidth: 1
                )
            }
            .overlay(
                Rectangle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
            .clipped()
        }
    }

    // MARK: - Samples

    private struct Sample {
        let title: String
        let activity: Activity
    }

    /// Every compact view the ears can draw, one line each.
    private static let samples: [Sample] = [
        Sample(title: "Music, playing", activity: activity(.nowPlaying(NowPlayingPayload(
            title: "Track", artist: "Artist", isPlaying: true,
            accent: AccentColor(red: 0.85, green: 0.4, blue: 0.3)
        )), kind: .nowPlaying)),
        Sample(title: "Music, paused", activity: activity(.nowPlaying(NowPlayingPayload(
            title: "Track", artist: "Artist", isPlaying: false,
            accent: AccentColor(red: 0.4, green: 0.5, blue: 0.9)
        )), kind: .nowPlaying)),
        Sample(title: "Weather", activity: activity(.weather(WeatherPayload(
            temperatureCelsius: 24, symbolName: "sun.max.fill",
            condition: "Clear", city: "Boston", isDay: true
        )), kind: .weather)),
        Sample(title: "Calendar", activity: activity(.event(EventPayload(
            title: "Standup", location: "", startsIn: 240,
            accent: AccentColor(red: 0.9, green: 0.3, blue: 0.3), hasEvent: true
        )), kind: .event)),
        Sample(title: "Timer", activity: activity(.timer(TimerPayload(
            label: "Focus", remaining: 1052, total: 1500, isRunning: true
        )), kind: .timer)),
        Sample(title: "AirPods", activity: activity(.device(DevicePayload(
            name: "AirPods Pro", symbolName: "airpods.pro",
            batteryLevels: ["Case": 0.8], isConnected: true, isApple: true
        )), kind: .device)),
        Sample(title: "Charging", activity: activity(.power(PowerPayload(
            percentage: 0.72, isCharging: true
        )), kind: .power)),
        Sample(title: "Focus on", activity: activity(.focus(FocusPayload(
            name: "Work", symbolName: "moon.fill", isActive: true
        )), kind: .focus)),
        Sample(title: "Caps lock on", activity: activity(.keyboard(KeyboardLayoutPayload(
            name: "Caps Lock On", code: "⇪", symbolName: "capslock.fill"
        )), kind: .keyboard)),
        Sample(title: "Caps lock off", activity: activity(.keyboard(KeyboardLayoutPayload(
            name: "Caps Lock Off", code: "⇪", symbolName: "textformat.abc"
        )), kind: .keyboard)),
        Sample(title: "Layout switch", activity: activity(.keyboard(KeyboardLayoutPayload(
            name: "ABC", code: "EN", symbolName: "keyboard"
        )), kind: .keyboard)),
        Sample(title: "Recording", activity: activity(.privacy(PrivacyPayload(
            cameraActive: true, micActive: true
        )), kind: .privacy)),
        Sample(title: "Shelf", activity: activity(.shelf(ShelfPayload(items: [
            ShelfItem(path: "/tmp/a", name: "a"),
            ShelfItem(path: "/tmp/b", name: "b"),
            ShelfItem(path: "/tmp/c", name: "c"),
        ])), kind: .shelf)),
        Sample(title: "Levels", activity: activity(.levels(LevelsPayload(
            volume: 0.55, brightness: 0.8
        )), kind: .levels)),
    ]

    private static var sampleCounter = 0

    private static func activity(_ payload: ActivityPayload, kind: ActivityKind) -> Activity {
        sampleCounter += 1
        return Activity(
            id: ActivityID(kind: kind, source: "compact-preview-\(sampleCounter)"),
            createdAt: 0,
            payload: payload
        )
    }
}
