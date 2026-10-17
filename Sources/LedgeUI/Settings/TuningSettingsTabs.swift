import LedgeCore
import SwiftUI

/// Shape & Motion: what the island looks like and how it moves.
///
/// One tab of the Tuning pane rather than a pane of its own. Hidden unless
/// `Prefs.advanced` is on. These are for shaping the app, not for using it.
struct AppearanceSettingsTab: View {

    @Bindable var preferences: Preferences
    let geometry: NotchGeometry

    /// A row a search result asked to be shown.
    var highlighted: String?

    var body: some View {
        SettingsPage(scrollTo: highlighted) {
            Section {
                LabeledSlider("Closed corner radius", value: $preferences.closedBottomRadius, in: 0...20, format: "%.1f")
                LabeledSlider("Open corner radius", value: $preferences.bottomRadius, in: 0...40, format: "%.1f")
                    .searchRow("bottomRadius", highlighted: highlighted)
                LabeledSlider("Gutter radius", value: $preferences.gutterRadius, in: 0...30, format: "%.1f")
                LabeledSlider("Corner smoothing", value: $preferences.cornerSmoothing, in: 0...1, format: "%.2f")
            } header: {
                Text("Shape")
            }

            Section {
                Toggle("Outline", isOn: $preferences.outlineEnabled)
                    .searchRow("outlineEnabled", highlighted: highlighted)
            } header: {
                Text("Edge")
            } footer: {
                SettingsNote("A faint edge along the shape so it never disappears into a dark window. Purely cosmetic — no screen access of any kind.")
            }

            Section {
                LabeledSlider("Side readout position", value: $preferences.satelliteOffset, in: -30...100, format: "%.0f")
                    .searchRow("satelliteOffset", highlighted: highlighted)
            } header: {
                Text("Side readout")
            } footer: {
                SettingsNote("The small readout that sits beside the notch — a timer, a charger, a volume change.")
            }

            Section {
                LabeledSlider(
                    "Height",
                    value: $preferences.expandedHeight,
                    in: geometry.notchSize.height...NotchLayout.maximumExpandedHeight,
                    format: "%.0f"
                )
                .searchRow("expandedHeight", highlighted: highlighted)
            } header: {
                Text("Expanded size")
            } footer: {
                SettingsNote("Card width follows Ear width, on the Compact Ears pane. Calendar keeps a wider layout for its month grid.")
            }

            Section {
                LabeledSlider("Spring response", value: $preferences.springResponse, in: 0.1...1.0, format: "%.2f")
                    .searchRow("springResponse", highlighted: highlighted)
                LabeledSlider("Spring damping", value: $preferences.springDamping, in: 0.3...1.0, format: "%.2f")
            } header: {
                Text("Motion")
            } footer: {
                SettingsNote("Damping below 1 overshoots. That overshoot is what reads as the shape springing out of the notch.")
            }
        }
    }
}

/// Tuning: the numbers behind the feel of the app.
///
/// Hidden unless `Prefs.advanced` is on, because a slider for the close delay
/// is a question nobody using Ledge should have to answer.
struct TuningSettingsTab: View {

    @Bindable var preferences: Preferences
    let geometry: NotchGeometry
    let actions: SettingsActions

    /// A tab a search result asked for. Consumed once, so moving tabs by
    /// hand afterwards is not undone by a stale request.
    var requestedTab: Binding<Tab?> = .constant(nil)

    /// A row a search result asked to be shown. The window clears it.
    var highlighted: String?

    /// Which set of knobs is on show. Three panes became three tabs: which
    /// of them a given slider lived on was not something anybody could guess,
    /// and the sidebar carried three rows that only ever appear together.
    @State private var tab: Tab = .shape

    /// The Ears drafts, held here rather than inside the Ears tab.
    ///
    /// The tab is destroyed when another one is chosen, so a draft living
    /// inside it was thrown away by a glance at Timing — with no Apply and
    /// no question asked. Held here, it survives the tabs and dies with the
    /// window, which is the same lifetime the Apply button promises.
    @State private var earWidthDraft: CGFloat?
    @State private var earLeadingDraft: CGFloat?
    @State private var earTrailingDraft: CGFloat?

    enum Tab: String, CaseIterable, Identifiable {
        case shape = "Shape & Motion"
        case ears = "Ears"
        case timing = "Timing"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 2)

            switch tab {
            case .shape:
                AppearanceSettingsTab(
                    preferences: preferences,
                    geometry: geometry,
                    highlighted: highlighted
                )
            case .ears:
                CompactSettingsTab(
                    preferences: preferences,
                    geometry: geometry,
                    highlighted: highlighted,
                    widthDraft: draft($earWidthDraft, or: preferences.earWidth),
                    leadingDraft: draft($earLeadingDraft, or: preferences.earLeadingOffset),
                    trailingDraft: draft($earTrailingDraft, or: preferences.earTrailingOffset)
                )
            case .timing: timing
            }
        }
        .task(id: requestedTab.wrappedValue) {
            guard let asked = requestedTab.wrappedValue else { return }
            tab = asked
            requestedTab.wrappedValue = nil
        }
    }

    /// A draft that starts as whatever is applied and then keeps its own
    /// value, whichever tab is on show.
    private func draft(_ stored: Binding<CGFloat?>, or applied: CGFloat) -> Binding<CGFloat> {
        Binding(
            get: { stored.wrappedValue ?? applied },
            set: { stored.wrappedValue = $0 }
        )
    }

    @ViewBuilder
    private var timing: some View {
        SettingsPage(scrollTo: highlighted) {
            Section {
                LabeledSlider("Open delay", value: $preferences.hoverOpenDelay, in: 0...0.6, format: "%.2f")
                    .searchRow("hoverOpenDelay", highlighted: highlighted)
                LabeledSlider("Close delay", value: $preferences.hoverCloseDelay, in: 0...1.0, format: "%.2f")
            } header: {
                Text("Hover timing")
            } footer: {
                SettingsNote("Seconds. A short open delay stops the island flashing open when you reach past it for the menu bar.")
            }

            Section {
                LabeledSlider("Announcement", value: $preferences.peekDuration, in: 0.5...6, format: "%.1f")
                    .searchRow("peekDuration", highlighted: highlighted)
                LabeledSlider("Level readout", value: $preferences.hudDuration, in: 0.4...4, format: "%.1f")
            } header: {
                Text("How long things stay")
            } footer: {
                SettingsNote("Seconds.")
            }

            Section {
                LabeledSlider("Swipe distance", value: $preferences.swipeThreshold, in: 8...80, format: "%.0f")
                    .searchRow("swipeThreshold", highlighted: highlighted)
            } header: {
                Text("Gestures")
            } footer: {
                SettingsNote("Points. How far a swipe has to travel before it counts as one.")
            }

            Section {
                LabeledSlider("Volume", value: $preferences.hudVolumeStep, in: 0.02...0.25, format: "%.3f")
                    .searchRow("hudVolumeStep", highlighted: highlighted)
                LabeledSlider("Brightness", value: $preferences.hudBrightnessStep, in: 0.02...0.25, format: "%.3f")
            } header: {
                Text("Key steps")
            } footer: {
                SettingsNote("How much one key press changes. 0.063 matches macOS.")
            }

            Section {
                Toggle("Glowing bar", isOn: $preferences.hudGlowBar)
                    .searchRow("hudGlowBar", highlighted: highlighted)
                LabeledSlider(
                    "Glyph & bar offset", value: $preferences.hudContentOffset,
                    in: -30...30, format: "%.0f"
                )
            } header: {
                Text("Readout layout")
            } footer: {
                SettingsNote("Nudge the glyph and bar horizontally. Positive moves both inward toward the notch; negative toward the edges.")
            }

            Section {
                LabeledContent("Screen", value: Self.size(geometry.screenSize))
                LabeledContent("Notch", value: Self.size(geometry.notchSize))
                LabeledContent("Source", value: geometry.isHardwareNotch
                    ? "hardware cutout" : "none — this Mac has no notch")
                Toggle("Tint the shape red", isOn: $preferences.debugTint)
                HStack {
                    Button("Copy Tuned Values") {
                        actions.copyToClipboard(preferences.exportedSwift)
                    }
                    // The way back. `general.advanced` had no control at all:
                    // once it was on, the only ways out were another
                    // `defaults write` or Reset All Settings, which takes
                    // every other setting with it.
                    Button("Hide Tuning") { preferences.advanced = false }
                        .searchRow("hideTuning", highlighted: highlighted)
                }
            } header: {
                Text("This Mac")
            } footer: {
                SettingsNote("Copy puts every value on these tabs on the clipboard as Swift. Hide Tuning takes this row out of the sidebar; the same defaults command brings it back.")
            }
        }
    }

    private static func size(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }
}
