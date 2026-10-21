import LedgeCore
import SwiftUI

/// Cards: everything Ledge can show you, and why one of them is empty.
///
/// One list, grouped by what each card is about, with its switch on the row
/// and its own page a click away. The switch used to live inside that page
/// for the cards that had one, so a user who never opened the page did not
/// know a card could be turned off at all; and the page was reached by a
/// twelve-point chevron rather than by the row, which is a target nobody can
/// hit on purpose.
struct CardsSettingsTab: View {

    @Bindable var preferences: Preferences
    let model: SettingsModel
    let actions: SettingsActions

    /// Which card's page is open. Owned by the window, so a debug launch can
    /// open straight onto one.
    @Binding var path: [String]

    /// A row a search result asked to be shown. The window clears it.
    var highlighted: String?

    /// Leaves for the Keep Awake pane. The window owns the sidebar, so only
    /// it can move the selection.
    var onOpenKeepAwake: () -> Void = {}

    var body: some View {
        NavigationStack(path: $path) {
            SettingsPage(scrollTo: highlighted) {
                if !waiting.isEmpty {
                    Section {
                        ForEach(waiting) { provider in
                            waitingRow(provider)
                        }
                    } header: {
                        Text("Waiting for something")
                    } footer: {
                        SettingsNote("These are switched on and can't show anything yet. Switching one off also clears it from here.")
                    }
                }

                ForEach(Array(groups.enumerated()), id: \.element.group) { index, section in
                    Section {
                        ForEach(section.providers) { row($0) }
                    } header: {
                        Text(section.group.rawValue)
                    } footer: {
                        // Said once, under the first group, where it is read
                        // before any of the switches are reached.
                        if index == 0 {
                            SettingsNote("Turn off anything you do not want. A card that is off does no work, asks for no permission, and never appears.")
                        }
                    }
                }

                Section {
                    Picker("Opens first", selection: $preferences.pinnedCard) {
                        Text("Whatever matters most").tag("")
                        Text("Music").tag("nowPlaying")
                        Text("Calendar").tag("event")
                        Text("Timer").tag("timer")
                        Text("Weather").tag("weather")
                        Text("Shelf").tag("shelf")
                    }
                    .searchRow("pinnedCard", highlighted: highlighted)
                } header: {
                    Text("Order")
                } footer: {
                    SettingsNote("A meeting about to start comes before playing music, which comes before the weather. Choosing a card opens that one every time.")
                }
            }
            .navigationDestination(for: String.self) { id in
                CardDetailPane(
                    id: id,
                    preferences: preferences,
                    model: model,
                    actions: actions,
                    highlighted: highlighted
                )
            }
        }
    }

    /// The cards that are switched on and cannot show anything.
    ///
    /// They come to the top rather than staying scattered through eighteen
    /// rows, each with the one button that fixes it. The sidebar's badge
    /// counts the same list, so the window says how many before it is opened.
    private var waiting: [ProviderDescriptor] {
        model.providers.filter { $0.isEnabled && !$0.isAvailable }
    }

    @ViewBuilder
    private func waitingRow(_ provider: ProviderDescriptor) -> some View {
        let presentation = CardRowPresentation(provider: provider)
        HStack(alignment: .top, spacing: 10) {
            SettingsIcon.forProvider(provider.id).view
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.name)
                if let permission = provider.permission {
                    let face = model.face(of: permission)
                    SettingsStatus(
                        face.tone == .quiet
                            ? face.word
                            : "Needs \(permission.displayName): \(face.word.lowercased())",
                        face.tone.settingsTone
                    )
                    if let note = face.note {
                        SettingsNote(note)
                    }
                    if let remedy = face.remedy {
                        Button(remedy.label) { perform(remedy, for: permission) }
                            .controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    private func perform(_ remedy: PermissionRemedy, for kind: PermissionKind) {
        PermissionPress.perform(remedy, for: kind, model: model, actions: actions)
    }

    /// The groups that have anything in them, in `CardGroup`'s own order, and
    /// each keeping the registry's order inside it — which is the order the
    /// app itself ranks cards in.
    private var groups: [(group: CardGroup, providers: [ProviderDescriptor])] {
        CardGroup.allCases.compactMap { group in
            let providers = model.providers.filter { CardGroup.of($0.id) == group }
            return providers.isEmpty ? nil : (group, providers)
        }
    }

    // MARK: - One row

    @ViewBuilder
    private func row(_ provider: ProviderDescriptor) -> some View {
        let presentation = CardRowPresentation(provider: provider)
        HStack(spacing: 10) {
            if presentation.hasSettings {
                // The whole row opens the page, not a chevron at the end of
                // it: everything but the switch is the target.
                Button { open(provider) } label: { label(presentation) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(presentation.name) settings")
            } else {
                label(presentation)
            }

            Toggle("", isOn: Binding(
                get: { provider.isEnabled },
                set: { actions.setProviderEnabled(provider.id, $0) }
            ))
            .labelsHidden()
            .accessibilityLabel("Show the \(presentation.name) card")

            // The disclosure sits where macOS puts it — last, after the
            // switch — so it cannot be inside the button that spans the rest
            // of the row. It is its own button with the same action, and it
            // stays out of VoiceOver's way, which has already been offered
            // the row.
            //
            // Its *place* is kept on every row, page or no page. Without
            // that, the switches sat in two columns eighteen points apart,
            // alternating down the list.
            Group {
                if presentation.hasSettings {
                    Button { open(provider) } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
        }
        .padding(.vertical, 2)
        // "Notes" in search lands on this row, and the list scrolls to it:
        // eighteen rows in four groups is exactly the list somebody asks a
        // search field about.
        .searchRow("card:\(provider.id)", highlighted: highlighted)
    }

    /// Opens a card's settings.
    ///
    /// Keep Awake's are a pane of their own — it installs a root daemon, and
    /// the notch card's own sentence sends people to "Settings › Keep Awake"
    /// — so its row leaves Cards entirely rather than pushing a page.
    private func open(_ provider: ProviderDescriptor) {
        if provider.id == "keep-awake" {
            onOpenKeepAwake()
        } else {
            path.append(provider.id)
        }
    }

    private func label(_ presentation: CardRowPresentation) -> some View {
        HStack(spacing: 10) {
            SettingsIcon.forProvider(presentation.id).view
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.name)
                // A card switched on that still shows nothing is the most
                // confusing state the app has. Said here, on the row, rather
                // than only inside a page the user has no reason to open —
                // and never about a card that is switched off, which is
                // waiting for nothing.
                if let warning = presentation.warning {
                    SettingsStatus(warning, .attention)
                }
                SettingsNote(presentation.summary)
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

/// One card's page: its switch, what it needs, and anything it has to set.
struct CardDetailPane: View {

    let id: String
    @Bindable var preferences: Preferences
    let model: SettingsModel
    let actions: SettingsActions

    /// A row a search result asked to be shown — "City" lands on Weather's
    /// page, and the page says which line it meant.
    var highlighted: String?

    /// What the last press of Set Up or Remove came to.
    ///
    /// Held in the view rather than the model because it is the answer to one
    /// press, not a fact about the app: reopening Settings should show the
    /// installation state afresh, not the outcome of something the user did
    /// last week.
    private var descriptor: ProviderDescriptor? {
        model.providers.first { $0.id == id }
    }

    var body: some View {
        SettingsPage(scrollTo: highlighted) {
            if let descriptor {
                let presentation = CardRowPresentation(provider: descriptor)

                Section {
                    Toggle("Show the \(presentation.name) card", isOn: Binding(
                        get: { descriptor.isEnabled },
                        set: { actions.setProviderEnabled(descriptor.id, $0) }
                    ))
                    SettingsNote(presentation.summary)
                }

                // Granted here, on the page of the card that is waiting for
                // it. Sending somebody to a different pane to press one
                // button, and back again to see whether it worked, is two
                // journeys for one answer.
                if let permission = descriptor.permission {
                    // "Needs" or "Works better with": a card that is hidden
                    // without the grant and a card that is merely poorer are
                    // two different promises, and "Permission" made them
                    // sound like one.
                    Section(descriptor.permissionIsOptional ? "Works better with" : "Needs") {
                        PermissionGrantRow(
                            kind: permission,
                            model: model,
                            actions: actions,
                            namesItsCards: false
                        )
                    }
                }

                switch id {
                case "timer": timer
                case "nowplaying": nowPlaying
                case "shelf": shelf
                case "weather": weather
                case "levels": levels
                default: EmptyView()
                }
            } else {
                ContentUnavailableView("This card is not available", systemImage: "questionmark")
            }
        }
        .navigationTitle(descriptor?.displayName ?? "Card")
        .refreshingPermissions(actions)
    }

    // MARK: - Timer

    @ViewBuilder
    private var timer: some View {
        Section("Durations") {
            LabeledSlider("Focus", value: $preferences.timerWorkMinutes, in: 1...90, format: "%.0f min")
                .searchRow("timerWorkMinutes", highlighted: highlighted)
            LabeledSlider("Short break", value: $preferences.timerShortBreakMinutes, in: 1...30, format: "%.0f min")
            LabeledSlider("Long break", value: $preferences.timerLongBreakMinutes, in: 5...60, format: "%.0f min")
        }
        Section {
            Toggle("Start the next session automatically", isOn: $preferences.timerAutoAdvance)
                .searchRow("timerAutoAdvance", highlighted: highlighted)
        } header: {
            Text("Cycle")
        } footer: {
            SettingsNote("A long break replaces the short one after every four focus sessions. Start one from the notch's timer card.")
        }
    }

    // MARK: - Sound & brightness

    /// The readout and the card in one place.
    ///
    /// They were a sidebar row and a card row with the same name and
    /// different settings in each, two rows apart. Whichever one somebody
    /// opened, half of what they were looking for was in the other.
    @ViewBuilder
    private var levels: some View {
        Section {
            Toggle("Show a readout when I press a volume key", isOn: $preferences.hudEnabled)
                .searchRow("hudEnabled", highlighted: highlighted)
            Toggle("Show one for brightness too", isOn: $preferences.hudBrightnessEnabled)
                .searchRow("hudBrightnessEnabled", highlighted: highlighted)
                .disabled(!preferences.hudEnabled)
        } header: {
            Text("Pressing a key")
        } footer: {
            SettingsNote("Volume changes are read straight from the audio system, so this needs no permission at all. macOS still shows its own readout alongside — replacing it is the setting below.")
        }

        Section {
            // `accessibilityIsInEffect` is the probe tap's answer, not the
            // permission list's: a grant macOS has not handed over yet reads
            // as granted everywhere and still cannot intercept anything.
            // It is observable state the shell writes, so this redraws when
            // the answer moves — a plain function call here is something
            // nothing can observe, which is why this pane used to re-check
            // the grant every single second.
            let usable = model.status(of: .accessibility) == .granted
                && model.accessibilityIsInEffect
            Toggle("Hide the macOS volume and brightness readout", isOn: $preferences.suppressSystemHUD)
                .searchRow("suppressSystemHUD", highlighted: highlighted)
                .disabled(!preferences.hudEnabled || !usable)

            if !usable {
                // The switch above is on by default, so without this the pane
                // showed a setting that was on and a system readout that was
                // still there, with nothing to connect them. It also covers
                // the state that had no face at all: granted, not handed
                // over, dead switch, nothing to press.
                SettingsNote("Needs Accessibility, below. Your choice is kept until then.")
                PermissionGrantRow(
                    kind: .accessibility,
                    model: model,
                    actions: actions,
                    namesItsCards: false
                )
            }
        } header: {
            Text("Replacing the macOS readout")
        } footer: {
            SettingsNote("This works by intercepting the key press before macOS sees it, so Ledge has to apply the change itself. If anything goes wrong the key press is passed through untouched rather than swallowed, and quitting Ledge always restores normal behaviour.")
        }
    }

    // MARK: - Music

    @ViewBuilder
    private var nowPlaying: some View {
        Section {
            SettingsStatus(model.mediaSource.headline, model.mediaSource.isFull ? .ok : .attention)
            SettingsNote(model.mediaSource.detail)
        } header: {
            Text("What Ledge can see")
        }

        Section {
            Toggle("Show web media cards", isOn: $preferences.showWebMediaCards)
                .searchRow("showWebMediaCards", highlighted: highlighted)
            SettingsNote("Anything playing in a browser gets a card. Off by default: a browser hands its now-playing slot between tabs, so what arrives can be a video you did not choose.")

            // The second switch is the larger wish and depends on the first:
            // the compact view is the part that sits there uninvited, where a
            // card waits to be looked at. Indented and dimmed, so the
            // dependency is visible before it is discovered.
            Toggle("Show web media in the compact view", isOn: $preferences.showWebMediaInCompact)
                .searchRow("showWebMediaInCompact", highlighted: highlighted)
                .disabled(!preferences.showWebMediaCards)
                .padding(.leading, Self.dependentInset)
                .accessibilityHint("Available when Show web media cards is on.")
            SettingsNote("Browser media rests in the notch the way a track does, whatever the video setting below says.")
                .padding(.leading, Self.dependentInset)
                .opacity(preferences.showWebMediaCards ? 1 : 0.5)
        } header: {
            Text("Web media")
        } footer: {
            SettingsNote("Ledge cannot tell which website a browser is playing — macOS does not say — so this is one choice for all of them.")
        }

        Section {
            Toggle("Show video in the compact view", isOn: $preferences.showVideoInCompact)
                .searchRow("showVideoInCompact", highlighted: highlighted)
            SettingsNote("What you are watching sits in the notch the way a track does. Switch it off to keep the notch still while the screen is busy — the card stays either way, so hovering still reaches the controls. Video shorter than two minutes is not shown at all.")
        } header: {
            Text("Video")
        } footer: {
            SettingsNote("Applies to apps. Browser media follows the web media settings above.")
        }

        Section {
            LabeledSlider("Stays in the notch", value: $preferences.companionLinger, in: 0...300, format: "%.0f")
            .searchRow("companionLinger", highlighted: highlighted)
        } header: {
            Text("After you pause")
        } footer: {
            SettingsNote("Seconds. How long a paused track keeps its place in the ears. The card stays in the cycle for fifteen minutes either way.")
        }
    }

    // MARK: - Shelf

    @ViewBuilder
    private var shelf: some View {
        Section {
            Toggle("Save screenshots to the Shelf", isOn: $preferences.shelfAutoScreenshots)
                // Kept, not cleared: with the card off nothing is watched, and
                // the choice is still there when the card comes back.
                .disabled(descriptor?.isEnabled == false)
                .searchRow("shelfAutoScreenshots", highlighted: highlighted)
        } header: {
            Text("Screenshots")
        } footer: {
            if descriptor?.isEnabled == false {
                SettingsNote("While the Shelf card is off, screenshots stay where macOS saved them.")
            } else {
                SettingsNote("A screenshot lands in the notch as you take it, ready to drag into a chat or an email, and leaves on its own after a day. The file stays wherever macOS saved it. Files you drop yourself stay until you take them out.")
            }
        }
    }

    // MARK: - Weather

    @ViewBuilder
    private var weather: some View {
        Section {
            // Committed on Return or on leaving the field, not on every
            // letter. Bound straight to the preference, each keystroke wrote
            // one — and the coordinator restarts the weather provider
            // whenever that value changes, so typing "Istanbul" meant eight
            // restarts and eight lookups, resolving "Ist" and "Istan" on the
            // way.
            TextField("City", text: $cityDraft, prompt: Text("e.g. Istanbul"))
                .searchRow("weatherCity", highlighted: highlighted)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitCity() }
                .onChange(of: cityFocused) { _, focused in
                    if !focused { commitCity() }
                }
                .focused($cityFocused)
                .task(id: preferences.weatherCity) {
                    // Another window, or a reset, may have changed it.
                    if !cityFocused { cityDraft = preferences.weatherCity }
                }
            Picker("Units", selection: $preferences.weatherUnits) {
                Text("Auto").tag(WeatherUnits.auto.rawValue)
                Text("°C").tag(WeatherUnits.celsius.rawValue)
                Text("°F").tag(WeatherUnits.fahrenheit.rawValue)
            }
            .pickerStyle(.segmented)
            .searchRow("weatherUnits", highlighted: highlighted)
        } header: {
            Text("Where")
        } footer: {
            SettingsNote("Uses your location when Location is allowed, otherwise this city. The city is looked up when you press Return or leave the field, not on every letter.")
        }
    }

    // MARK: - Keep Awake

    /// What is in the city field, before it is committed.
    @State private var cityDraft = ""
    @FocusState private var cityFocused: Bool

    private func commitCity() {
        let tidied = cityDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tidied != preferences.weatherCity else { return }
        preferences.weatherCity = tidied
        cityDraft = tidied
    }

    /// How far a switch that depends on the one above it sits in. The system
    /// indent for a dependent checkbox, so the hierarchy is read rather than
    /// explained.
    private static let dependentInset: CGFloat = 20

}
