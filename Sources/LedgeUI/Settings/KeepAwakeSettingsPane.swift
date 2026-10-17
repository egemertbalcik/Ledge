import LedgeCore
import SwiftUI

/// Keep Awake's own pane.
///
/// It was a page inside Cards, three clicks from the window opening, with the
/// helper underneath Length and Battery. Three things make it a pane of its
/// own instead. It installs a daemon that runs as root, which is the most
/// serious thing anywhere in this window. It has more states than any other
/// page — four for the installation, plus asking, removing, refused, and the
/// one where removal is refused *on purpose*. And the notch card already
/// sends people to "Settings › Keep Awake", a place that did not exist.
///
/// The helper comes first on the pane for the same reason: it is what people
/// arrive for, and what the sentence on the card promised them.
struct KeepAwakeSettingsPane: View {

    @Bindable var preferences: Preferences
    let model: SettingsModel
    let actions: SettingsActions

    /// A row a search result asked to be shown. The window clears it.
    var highlighted: String?

    /// What the last press came to. Kept apart from the installation state,
    /// which is a fact about the Mac; these are facts about a press.
    @State private var setup: KeepAwakeHelperSetupOutcome?
    @State private var removal: KeepAwakeHelperRemoval?

    /// Whether the confirmation for taking the helper out is up.
    @State private var confirmingRemoval = false

    /// Whether the apps Ledge knows about but this Mac does not are shown.
    @State private var showsMissing = false

    private var roster: AgentRoster { preferences.agentRoster }

    /// What Ledge is doing to the helper, from the model rather than from
    /// this view: the pane can be left and reopened while a privileged
    /// operation is still running, and a fresh view with its own flag
    /// offered the same button again.
    private var busy: KeepAwakeOperation? { model.keepAwakeOperation }

    var body: some View {
        SettingsPage(scrollTo: highlighted) {
            Section {
                if let descriptor = model.providers.first(where: { $0.id == "keep-awake" }) {
                    Toggle("Show the Keep Awake card", isOn: Binding(
                        get: { descriptor.isEnabled },
                        set: { actions.setProviderEnabled("keep-awake", $0) }
                    ))
                }
                SettingsNote(KeepAwakeCopy.settingsSummary)
            }
            // Searching "keep awake" lands here rather than on the Cards
            // list: this is where the switch lives.
            .searchRow("card:keep-awake", highlighted: highlighted)

            helper
            length
            battery
            apps
            browsers

            Section {
                // Stated rather than discovered. The alternative is learning
                // the policy by losing a session to it.
                SettingsNote(KeepAwakeCopy.continuityPolicy)
            } header: {
                Text("If Ledge restarts")
            }
        }
        .navigationTitle("Keep Awake")
        .confirmationDialog(
            "Remove the \(KeepAwakeCopy.lidClosed) helper?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Helper", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                Ledge will no longer be able to keep your Mac awake with the lid shut. \
                \(KeepAwakeCopy.railAwake) still works. You can set the helper up again \
                here at any time.
                """)
        }
    }

    // MARK: - The helper

    @ViewBuilder
    private var helper: some View {
        let state = model.keepAwakeHelper
        let presentation = KeepAwakeSetupPresentation(state)
        Section {
            switch busy {
            case .some(let operation):
                SettingsStatus(operation.headline, .quiet)
                SettingsNote(operation.detail)
            case nil:
                SettingsStatus(presentation.headline, presentation.tone)
                if state != .unsignedBuild {
                    KeepAwakeSetupSteps(state: state)
                }
                SettingsNote(presentation.detail)
            }

            if busy == nil {
                buttons(presentation)
                aftermath
            }

            if state != .unsignedBuild {
                SettingsNote(KeepAwakeCopy.lidNeedsALength)
            }
        } header: {
            Text("\(KeepAwakeCopy.lidClosed) helper")
        }
        .searchRow("helper", highlighted: highlighted)
    }

    @ViewBuilder
    private func buttons(_ presentation: KeepAwakeSetupPresentation) -> some View {
        if presentation.offersSetUp {
            Button("Set Up…") {
                removal = nil
                // The shell holds the operation while it runs, so a pane
                // rebuilt mid-press cannot offer this again.
                setup = actions.installKeepAwakeHelper()
            }
        }
        if presentation.offersApproval {
            Button("Open Login Items…", action: actions.showKeepAwakeHelperApproval)
        }
        if presentation.offersRemoval {
            Button("Remove Helper…", role: .destructive) { confirmingRemoval = true }
        }
    }

    /// What the last press came to, said where the press was.
    @ViewBuilder
    private var aftermath: some View {
        switch removal {
        case .stillOwesWork:
            // A reason, not a failure: refusing here is the helper doing its
            // job. The Mac still has a setting out on loan.
            SettingsStatus(
                "The helper still has a setting to put back, so it is staying. "
                    + "End the session, let it finish, and try again.",
                .attention
            )
        case .failed(let why) where !why.isEmpty:
            SettingsStatus(
                "Couldn't remove the helper: \(why) Nothing was changed. "
                    + "Try again, or remove it in Login Items & Extensions.",
                .problem
            )
        case .failed, .removed, nil:
            EmptyView()
        }
        if case .refused(let reason) = setup, !reason.isEmpty {
            SettingsStatus("macOS refused the setup: \(reason) Nothing was installed.", .problem)
        }
    }

    private func remove() {
        Task {
            let answer = await actions.removeKeepAwakeHelper()
            removal = answer
            if answer == .removed { setup = nil }
        }
    }

    // MARK: - Length and battery

    @ViewBuilder
    private var length: some View {
        Section {
            LabeledSlider("\(KeepAwakeCopy.lidClosed) opens on",
                          value: $preferences.keepAwakeDefaultMinutes,
                          in: 5...180, format: "%.0f min")
        .searchRow("keepAwakeDefaultMinutes", highlighted: highlighted)
        } header: {
            Text("Length")
        } footer: {
            SettingsNote("\(KeepAwakeCopy.railAwake) holds the Mac until you switch it off, so it has no length. The length is still set on the card itself, by dragging the number sideways.")
        }
    }

    @ViewBuilder
    private var battery: some View {
        Section {
            LabeledSlider("End at", value: $preferences.keepAwakeBatteryFloor,
                          in: 5...50, format: "%.0f%%")
        .searchRow("keepAwakeBatteryFloor", highlighted: highlighted)
        } header: {
            Text("Battery")
        } footer: {
            SettingsNote("On battery, a session ends here so your Mac can sleep before it runs out. Plugged in, it runs to the end.")
        }
    }

    // MARK: - The apps

    @ViewBuilder
    private var apps: some View {
        let running = actions.runningApps()
        let installed = roster.bundleIDs.filter { id in running.contains { $0.id == id } }
        let absent = roster.bundleIDs.filter { id in !running.contains { $0.id == id } }
        Section {
            Toggle("Keep these apps at full speed", isOn: $preferences.keepAwakeDisableAppNap)
                .searchRow("keepAwakeDisableAppNap", highlighted: highlighted)
            SettingsNote("Changes a setting inside each app, and puts it back when the session ends. Off unless you ask for it.")

            ForEach(installed, id: \.self) { appRow($0, running: running) }

            if !absent.isEmpty {
                // Folded, not hidden: on a typical Mac most of this list is
                // apps that aren't installed, and seventeen rows of them
                // buried the three that matter.
                DisclosureGroup(isExpanded: $showsMissing) {
                    ForEach(absent, id: \.self) { appRow($0, running: running) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not running now")
                        SettingsNote("\(absent.count) on Ledge's list that aren't open. They're skipped while they're closed.")
                    }
                }
            }

            Menu("Add an App…") {
                // Only what is running, and only what is not on the list
                // already. Typing a bundle id is how you end up with an entry
                // that names nothing and fails silently.
                let addable = running
                    .filter { !roster.carries($0.id) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if addable.isEmpty {
                    Text("Nothing else is running")
                }
                ForEach(addable, id: \.id) { app in
                    Button(app.name) {
                        var next = roster
                        next.add(app.id)
                        preferences.agentRoster = next
                    }
                }
            }
        } header: {
            Text("Apps that must keep working")
        } footer: {
            // The other half of the mode, and the half worth explaining:
            // everything else about a shut lid is about spending less, and
            // this is the list of things that must keep spending.
            SettingsNote("With the lid shut, macOS winds down anything it thinks nobody is watching — which is everything. These apps are the exception.")
        }
    }

    private func appRow(_ bundleID: String, running: [(id: String, name: String)]) -> some View {
        let name = Self.name(of: bundleID, running: running)
        return HStack {
            Text(name)
            Spacer()
            Button {
                var next = roster
                next.remove(bundleID)
                preferences.agentRoster = next
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Take \(name) off the list")
            .accessibilityLabel("Take \(name) off the list")
        }
    }

    /// What to call an app on the list.
    ///
    /// macOS knows the name of a running app. For a closed one the shipped
    /// list carries its own names, because the last component of a bundle id
    /// is not a name: it showed Cursor as "230313mzl4w4u92" and Claude as
    /// "claudefordesktop". Anything else keeps its whole id, which at least
    /// does not pretend to be a name.
    static func name(of bundleID: String, running: [(id: String, name: String)]) -> String {
        running.first { $0.id == bundleID }?.name
            ?? AgentRoster.shippedName(of: bundleID)
            ?? bundleID
    }

    // MARK: - Browsers

    @ViewBuilder
    private var browsers: some View {
        // The same rule the Keep Awake session uses, not a guess from here:
        // only a browser on the roster can stall a session, and only one
        // started without the flags.
        let stalling = ChromiumAdvice.stalling(actions.runningChromium(), roster: roster)
        if !stalling.isEmpty {
            Section {
                ForEach(stalling, id: \.bundleID) { browser in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(browser.name)
                            SettingsNote("Started without the flags that keep it working behind a shut lid.")
                        }
                        Spacer()
                        // Copied, not done. The flags only take effect at
                        // launch, so the fix is a restart, and restarting
                        // somebody's browser out from under them is the worse
                        // surprise.
                        Button("Copy Command") {
                            actions.copyToClipboard(ChromiumAdvice.launchCommand(for: browser))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                SettingsNote("Quit the browser and run that command to start it again with the work kept alive.")
                .searchRow("browsers", highlighted: highlighted)
            } header: {
                Text("Browsers")
            } footer: {
                // A browser-driving agent behind a shut lid fails silently:
                // the page is still there, the agent is still waiting, and
                // nothing happens.
                SettingsNote("Chromium slows every window macOS reports as hidden, and a shut lid hides all of them. An agent driving one of these will stall.")
            }
        }
    }
}

/// Where the setup has got to: set up, allowed, ready.
///
/// It is a sequence, and it was drawn as a sentence. Somebody who pressed Set
/// Up and landed in "Waiting for your OK" could not tell whether that was the
/// end of it, a problem, or the middle of something.
struct KeepAwakeSetupSteps: View {

    let state: KeepAwakeHelperInstallation

    /// Which step is current. Installed is past all three.
    private var reached: Int {
        switch state {
        case .notInstalled: 0
        case .needsApproval: 1
        case .installed: 3
        case .unsignedBuild: -1
        }
    }

    private static let names = ["Set up", "Allow in System Settings", "Ready"]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ForEach(Array(Self.names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: 5) {
                    marker(index)
                    Text(name)
                        .font(.cardCaption)
                        .foregroundStyle(index == reached ? .primary : .secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken(reached))
    }

    @ViewBuilder
    private func marker(_ index: Int) -> some View {
        let done = index < reached || reached == Self.names.count
        Image(systemName: done ? "checkmark.circle.fill" : "\(index + 1).circle\(index == reached ? ".fill" : "")")
            .font(.cardCaption)
            .foregroundStyle(done ? Color.green : (index == reached ? Color.accentColor : Color.secondary))
    }

    /// What VoiceOver says instead of three glyphs.
    static func spoken(_ reached: Int) -> String {
        guard reached >= 0 else { return "Setup is unavailable in this build." }
        guard reached < names.count else { return "Setup finished: the helper is ready." }
        return "Step \(reached + 1) of \(names.count): \(names[reached])."
    }
}
