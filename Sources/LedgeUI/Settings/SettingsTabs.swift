import LedgeCore
import SwiftUI

struct GeneralSettingsTab: View {

    @Bindable var preferences: Preferences
    let geometry: NotchGeometry
    let actions: SettingsActions

    @State private var loginItemFailed = false

    var body: some View {
        Form {
            if !geometry.isHardwareNotch {
                // Ledge draws only in a real notch. Said plainly, up top, so a
                // Mac mini owner — or a MacBook with the lid shut — is not left
                // wondering why nothing ever appears.
                Section {
                    Label("No notched display is connected right now.", systemImage: "rectangle.topthird.inset.filled")
                    Text("Ledge shows its cards only in a MacBook's notch. It draws nothing on external displays or with the lid closed — settings and updates still work.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // First thing in the window, because the commonest thing a new
            // user needs is not a setting: it is being told how the app is
            // driven at all. The tour was reachable only from About, which is
            // the last place anyone looks for instructions.
            Section {
                LabeledContent("New to Ledge?") {
                    Button("Show me how it works…") { actions.showOnboarding() }
                }
            } footer: {
                Text("Hover the notch to open a card. Click to keep it open. Swipe left and right to move between cards. Drag a file onto it to park the file there.")
            }

            Section {
                Toggle("Match my trackpad's scroll direction", isOn: $preferences.naturalSwipe)
            } header: {
                Text("Opening")
            } footer: {
                Text("Click again, or move away from the notch, to close it. Swipe left and right to move between cards.")
            }

            Section {
                Picker("Open first", selection: $preferences.pinnedCard) {
                    Text("Whatever matters most").tag("")
                    Text("Music").tag("nowPlaying")
                    Text("Calendar").tag("event")
                    Text("Timer").tag("timer")
                    Text("Weather").tag("weather")
                    Text("Shelf").tag("shelf")
                }
            } header: {
                Text("Cards")
            } footer: {
                Text("A meeting about to start comes before playing music, which comes before the weather. Choosing a card opens that one every time.")
            }

            Section {
                Toggle("Stay quiet during a Focus", isOn: $preferences.quietDuringFocus)
            } header: {
                Text("Staying out of the way")
            } footer: {
                Text("During a Focus, announcements wait. A low battery, a recording light or your own timer still come through.")
            }

            Section {
                Toggle("Launch Ledge at login", isOn: Binding(
                    get: { preferences.launchAtLogin },
                    set: { requested in
                        // Registration can be refused; reflect what actually
                        // happened rather than what was asked for.
                        let succeeded = actions.setLaunchAtLogin(requested)
                        preferences.launchAtLogin = succeeded ? requested : !requested
                        loginItemFailed = !succeeded
                    }
                ))
                if loginItemFailed {
                    Text(actions.loginItemStatus())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                // Stored as "hide", shown as "show": the setting people look
                // for is the one that puts Ledge *in* the picture, and off is
                // the safe default — nobody wants their music in a screenshot
                // of their work.
                Toggle("Show Ledge in screenshots and recordings", isOn: Binding(
                    get: { !preferences.hideFromScreenCapture },
                    set: { preferences.hideFromScreenCapture = !$0 }
                ))
                Text(preferences.hideFromScreenCapture
                     ? "Ledge stays out of screenshots, screen recordings and shared screens in meetings. Everything else on screen is captured as usual."
                     : "Ledge appears in screenshots, screen recordings and shared screens — useful for showing it to someone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Quit Ledge", action: actions.quit)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct AppearanceSettingsTab: View {

    @Bindable var preferences: Preferences
    let geometry: NotchGeometry

    var body: some View {
        Form {
            Section("Shape") {
                LabeledSlider("Closed corner radius", value: $preferences.closedBottomRadius, in: 0...20, format: "%.1f")
                LabeledSlider("Open corner radius", value: $preferences.bottomRadius, in: 0...40, format: "%.1f")
                LabeledSlider("Gutter radius", value: $preferences.gutterRadius, in: 0...30, format: "%.1f")
                LabeledSlider("Corner smoothing", value: $preferences.cornerSmoothing, in: 0...1, format: "%.2f")
                Toggle("Outline", isOn: $preferences.outlineEnabled)
                Text("A faint edge along the shape so it never disappears into a dark window. Purely cosmetic — no screen access of any kind.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledSlider("Side readout position", value: $preferences.satelliteOffset, in: -30...100, format: "%.0f")
                Text("The small readout that sits beside the notch — a timer, a charger, a volume change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Expanded size") {
                LabeledSlider(
                    "Width",
                    value: $preferences.expandedWidth,
                    in: geometry.notchSize.width...geometry.screenSize.width,
                    format: "%.0f"
                )
                LabeledSlider(
                    "Height",
                    value: $preferences.expandedHeight,
                    in: geometry.notchSize.height...440,
                    format: "%.0f"
                )
            }

            Section("Motion") {
                LabeledSlider("Spring response", value: $preferences.springResponse, in: 0.1...1.0, format: "%.2f")
                LabeledSlider("Spring damping", value: $preferences.springDamping, in: 0.3...1.0, format: "%.2f")
                Text("Damping below 1 overshoots. That overshoot is what reads as the shape springing out of the notch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Every card in one list: what it shows, whether it is on, and its own
/// settings a click away. Eleven sidebar rows became one.
struct CardsSettingsTab: View {

    @Bindable var preferences: Preferences
    let model: SettingsModel
    let actions: SettingsActions
    let openPermissions: () -> Void

    /// One card's row: what it is, and what it shows.
    private func cardRow(_ provider: ProviderDescriptor, trailing: String?) -> some View {
        HStack(spacing: 10) {
            SidebarIcon.forProvider(provider.id).view
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                // A card switched on that still shows nothing is the most
                // confusing state the app has. Said here, on the row, rather
                // than only inside a pane the user has no reason to open.
                if let permission = provider.permission, !provider.isAvailable {
                    Text("Waiting for \(permission.displayName) access")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text(ProviderDetailPane.summary(for: provider.id))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    // Two lines, because the sentence explaining what a card
                    // *is* was being cut off halfway — on the one screen whose
                    // whole job is to explain what the cards are.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let trailing {
                Text(trailing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.providers) { provider in
                        // Every row carries its own switch, whether or not it
                        // has a pane behind it. The switch used to be inside
                        // that pane for the cards that had one, and the row
                        // said "On" — which is a word, not a control. A user
                        // who had never opened the pane did not know a card
                        // could be turned off at all.
                        HStack(spacing: 10) {
                            cardRow(provider, trailing: nil)
                            Toggle("", isOn: Binding(
                                get: { provider.isEnabled },
                                set: { actions.setProviderEnabled(provider.id, $0) }
                            ))
                            .labelsHidden()
                            .accessibilityLabel("Show \(provider.displayName)")
                            if ProviderDetailPane.hasSettings(provider.id) {
                                NavigationLink(value: provider.id) {
                                    EmptyView()
                                }
                                .frame(width: 12)
                                .accessibilityLabel("\(provider.displayName) settings")
                            }
                        }
                    }
                } header: {
                    Text("What Ledge can show you")
                } footer: {
                    Text("Turn off anything you do not want. A card that is off does no work, asks for no permission, and never appears. The ones with an arrow have a little more to set.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationDestination(for: String.self) { id in
                ProviderDetailPane(
                    id: id,
                    preferences: preferences,
                    model: model,
                    actions: actions,
                    openPermissions: openPermissions
                )
                .navigationTitle(model.providers.first { $0.id == id }?.displayName ?? "Card")
            }
        }
    }
}

/// The page for one activity source: its enable switch, what it needs, and any
/// configuration specific to it.
struct ProviderDetailPane: View {

    let id: String
    @Bindable var preferences: Preferences
    let model: SettingsModel
    let actions: SettingsActions
    let openPermissions: () -> Void

    private var descriptor: ProviderDescriptor? {
        model.providers.first { $0.id == id }
    }

    var body: some View {
        Form {
            if let descriptor {
                Section {
                    Toggle("Enable \(descriptor.displayName)", isOn: Binding(
                        get: { descriptor.isEnabled },
                        set: { actions.setProviderEnabled(descriptor.id, $0) }
                    ))
                    Text(Self.summary(for: id))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let permission = descriptor.permission {
                    Section("Permission") {
                        LabeledContent(permission.displayName) {
                            Text(descriptor.isAvailable ? "Granted" : "Not granted")
                                .foregroundStyle(descriptor.isAvailable ? .green : .orange)
                        }
                        if !descriptor.isAvailable {
                            Button("Open Permissions…", action: openPermissions)
                        }
                    }
                }

                if id == "timer" {
                    Section("Durations") {
                        LabeledSlider("Focus", value: $preferences.timerWorkMinutes, in: 1...90, format: "%.0f min")
                        LabeledSlider("Short break", value: $preferences.timerShortBreakMinutes, in: 1...30, format: "%.0f min")
                        LabeledSlider("Long break", value: $preferences.timerLongBreakMinutes, in: 5...60, format: "%.0f min")
                    }
                    Section("Cycle") {
                        Toggle("Start the next session automatically", isOn: $preferences.timerAutoAdvance)
                        Text("A long break replaces the short one after every four focus sessions. Start one from the notch's timer card.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if id == "nowplaying" {
                    Section("What Ledge can see") {
                        HStack {
                            Text(model.mediaSource.headline)
                            Spacer()
                            Image(systemName: model.mediaSource.isFull
                                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(model.mediaSource.isFull ? .green : .orange)
                        }
                        Text(model.mediaSource.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Section("Where it comes from") {
                        Toggle("Keep web pages out of the compact view", isOn: $preferences.appMediaOnly)
                        Text(preferences.appMediaOnly
                             ? "Only players rest in the notch — Music, Spotify, Podcasts and the like. A page's media still has a card; it just does not sit there uninvited."
                             : "Anything playing rests in the notch, including a web page. A browser hands its now-playing slot between tabs, so that can be a video you did not choose.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        // The larger wish, and only offered once the smaller
                        // one has been made: refusing a card to something that
                        // is welcome in the ears is not a state anyone means
                        // to be in.
                        Toggle("Hide their card as well", isOn: $preferences.hideWebMediaCard)
                            .disabled(!preferences.appMediaOnly)
                        Text("A page's media disappears entirely — no card to cycle to, and nothing announced when it starts.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .opacity(preferences.appMediaOnly ? 1 : 0.5)
                    }

                    Section("Video") {
                        Toggle("Show video in the compact view", isOn: $preferences.showVideoInCompact)
                        Text("What you are watching sits in the notch the way a track does. Switch it off to keep the notch still while the screen is busy — the card stays either way, so hovering still reaches the controls. Video shorter than two minutes is not shown at all.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Section("After you pause") {
                        LabeledSlider(
                            "Stays in the notch",
                            value: $preferences.companionLinger, in: 0...300, format: "%.0f"
                        )
                        Text("How long a paused track keeps its place in the ears. The card stays in the cycle for fifteen minutes either way.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                }

                if id == "shelf" {
                    Section("Screenshots") {
                        Toggle("Save screenshots to the Shelf", isOn: $preferences.shelfAutoScreenshots)
                        Text("A screenshot lands in the notch as you take it and stays for a day, then leaves on its own. Files you drop yourself stay until you take them out.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Every screenshot you take is parked on the Shelf, ready to drag into a chat or an email. The file stays wherever macOS saved it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if id == "weather" {
                    Section("City") {
                        TextField("City", text: $preferences.weatherCity, prompt: Text("e.g. Istanbul"))
                            .textFieldStyle(.roundedBorder)
                        Text("Uses your location when granted, otherwise this city. Leave both empty for no weather card.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Picker("Units", selection: $preferences.weatherUnits) {
                            Text("Auto").tag(WeatherUnits.auto.rawValue)
                            Text("°C").tag(WeatherUnits.celsius.rawValue)
                            Text("°F").tag(WeatherUnits.fahrenheit.rawValue)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            } else {
                ContentUnavailableView("Activity unavailable", systemImage: "questionmark")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(descriptor?.displayName ?? "Activity")
    }

    /// One line on what this card shows, from the user's side of the screen.
    /// Shared with the Cards list, which says the same thing beside the name.
    /// Whether this card has anything to say beyond being on or off.
    ///
    /// The ones that do get a pane; the rest wear their switch in the list,
    /// because a row that opens a pane holding a single toggle is a click
    /// asking to be a click.
    static func hasSettings(_ id: String) -> Bool {
        ["timer", "nowplaying", "shelf", "weather"].contains(id)
    }

    static func summary(for id: String) -> String {
        switch id {
        case "nowplaying": "Shows what Music or Spotify is playing, with artwork and controls."
        case "battery": "Charging, unplugging and low-battery warnings."
        case "bluetooth": "A card when AirPods or another device connects, with battery levels."
        case "calendar": "Your next event, and a month view when expanded."
        case "focus": "A card when a Focus mode turns on or off."
        case "weather": "Current conditions for your location, or a city you choose."
        case "timer": "A focus timer and pomodoro cycle, counted down in the notch."
        case "shelf": "Drop files on the notch to park them, then drag them out anywhere."
        case "privacy": "A dot while the camera or microphone is in use, and a word while you are dictating."
        case "levels": "Sliders for sound and brightness, for a keyboard or mouse with no keys for them."
        case "airpods-proximity": "A card when an AirPods case opens nearby."
        case "keyboard": "A brief note when the keyboard layout switches."
        case "capslock": "A flash in the notch when Caps Lock toggles."
        case "audioroute": "A glance at where sound is going when the output changes."
        case "bluetooth-power": "A note when Bluetooth is switched on or off — the reason devices go quiet."
        default: "One of the things Ledge can show."
        }
    }
}
