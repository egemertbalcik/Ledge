import LedgeCore
import SwiftUI

/// The Compact pane: every compact view the island can show, line by line,
/// rendered live against the *draft* values — ear width and the two content
/// nudges — so the effect is visible before anything touches the real notch.
/// Apply writes the preferences in one go; the shell observes the landing.
public struct CompactSettingsTab: View {

    @Bindable var preferences: Preferences
    let geometry: NotchGeometry

    public init(
        preferences: Preferences,
        geometry: NotchGeometry,
        highlighted: String? = nil,
        widthDraft: Binding<CGFloat>,
        leadingDraft: Binding<CGFloat>,
        trailingDraft: Binding<CGFloat>
    ) {
        self.preferences = preferences
        self.geometry = geometry
        self.highlighted = highlighted
        self._widthDraft = widthDraft
        self._leadingDraft = leadingDraft
        self._trailingDraft = trailingDraft
    }

    /// Drafts, owned by whoever shows this pane.
    ///
    /// They used to be `@State` here, seeded on every appearance — so
    /// switching to another Tuning tab and back silently threw away an
    /// unapplied edit, which is the one thing this draft-and-Apply shape
    /// exists to prevent.
    /// A row a search result asked to be shown.
    var highlighted: String?

    @Binding var widthDraft: CGFloat
    @Binding var leadingDraft: CGFloat
    @Binding var trailingDraft: CGFloat

    private var isDirty: Bool {
        widthDraft != preferences.earWidth
            || leadingDraft != preferences.earLeadingOffset
            || trailingDraft != preferences.earTrailingOffset
    }

    /// Whether everything — draft and applied — is already at the default.
    /// Checked on both, or Reset would disable itself while the island was
    /// still at somebody else's width with the sliders back at the default.
    private var isDefault: Bool {
        widthDraft == NotchLayout.defaultEarWidth
            && leadingDraft == 0 && trailingDraft == 0
            && preferences.earWidth == NotchLayout.defaultEarWidth
            && preferences.earLeadingOffset == 0 && preferences.earTrailingOffset == 0
    }

    public var body: some View {
        SettingsPage(scrollTo: highlighted) {
            Section {
                LabeledSlider("Ear width", value: $widthDraft, in: 36...90, format: "%.0f")
                .searchRow("earWidth", highlighted: highlighted)
                LabeledSlider("Leading nudge", value: $leadingDraft, in: -20...20, format: "%.0f")
                .searchRow("earLeadingOffset", highlighted: highlighted)
                LabeledSlider("Trailing nudge", value: $trailingDraft, in: -20...20, format: "%.0f")
                HStack {
                    Spacer()
                    // Resets *and* applies, in one press. It used to put the
                    // sliders back and leave the island exactly as it was,
                    // waiting for a second press on Apply — a button labelled
                    // Reset that reset nothing anybody could see.
                    Button("Reset to Defaults") {
                        widthDraft = NotchLayout.defaultEarWidth
                        leadingDraft = 0
                        trailingDraft = 0
                        apply()
                    }
                    .disabled(isDefault && !isDirty)
                    Button("Apply", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isDirty)
                }
            } header: {
                Text("Adjust")
            } footer: {
                SettingsNote("Positive nudges move content toward the cutout. Width also sets every open card's width; Calendar keeps a wider month grid. Nothing moves in the real notch until you press Apply — the preview below is live.")
            }

            Section {
                ForEach(Self.samples, id: \.title) { sample in
                    HStack(spacing: 10) {
                        Text(sample.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Spacer(minLength: 0)
                        previewRow(sample.activity)
                    }
                }
            } header: {
                Text("Preview")
            } footer: {
                SettingsNote("The hatched block is the hardware notch. Nothing may draw there.")
            }
        }
        // No reseeding on appearance: the drafts belong to the pane that
        // owns this one, and it seeds them once. Copying the applied values
        // back on every appearance is what used to discard an edit the
        // moment somebody looked at another tab.
        
    }

    private func apply() {
        preferences.earWidth = widthDraft
        preferences.earLeadingOffset = leadingDraft
        preferences.earTrailingOffset = trailingDraft
    }

    /// One island at draft dimensions: black body, the real ears view inside,
    /// and the cutout region hatched so the hardware is unmistakable.
    private func previewRow(_ activity: Activity) -> some View {
        // Preview at 2/3 scale so wide drafts still fit the pane. The frame
        // is fixed BEFORE scaling and re-fixed after, so the Form's row
        // cannot stretch the island and unseat the hatch from the cutout.
        let scale: CGFloat = 0.66
        let cutout = geometry.notchSize.width
        let layout = NotchLayout.peek(
            geometry, bottomRadius: preferences.bottomRadius,
            gutterRadius: preferences.gutterRadius, earWidth: widthDraft
        )
        let width = layout.boundingSize.width
        let height = layout.boundingSize.height
        let shape = LedgeShape(
            bottomRadius: layout.bottomRadius,
            gutterRadius: layout.gutterRadius,
            cornerSmoothing: preferences.cornerSmoothing
        )
        return ZStack {
            shape.fill(.black)

            CompactEarsView(
                activity: activity,
                cutoutWidth: cutout,
                inset: preferences.gutterRadius,
                leadingOffset: leadingDraft,
                trailingOffset: trailingDraft
            )
            .environment(\.weatherUnits, preferences.weatherUnits)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay {
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
