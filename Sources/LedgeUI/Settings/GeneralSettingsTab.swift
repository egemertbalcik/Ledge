import LedgeCore
import SwiftUI

/// General: which Ledge this is, how it behaves, and how to be rid of it.
///
/// Ordered by when a question arrives rather than by when the setting was
/// written — what is this and how is it driven, then whether it starts with
/// the Mac, then how it behaves while it is running, then what it keeps to
/// itself, then the way out.
///
/// About folded in here, where macOS keeps its own: it held a version number,
/// an update button, a link, a second copy of this pane's tour button, and
/// the reset. Four buttons in one row at a 464pt pane is also why two of them
/// were drawn as "Check for Update…" and "Show Me How It…".
struct GeneralSettingsTab: View {

    @Bindable var preferences: Preferences
    let geometry: NotchGeometry
    let model: SettingsModel
    let actions: SettingsActions

    /// A row a search result asked to be shown. The window clears it.
    let highlighted: String?

    @State private var loginItemFailed = false
    @State private var confirmingReset = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsPage(scrollTo: highlighted) {
            if !geometry.isHardwareNotch {
                // Ledge draws only in a real notch. Said plainly, up top, so a
                // Mac mini owner — or a MacBook with the lid shut — is not left
                // wondering why nothing ever appears.
                Section {
                    Label("No notched display is connected right now.",
                          systemImage: "rectangle.topthird.inset.filled")
                    SettingsNote("Ledge shows its cards only in a MacBook's notch. It draws nothing on external displays or with the lid closed — settings and updates still work.")
                }
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.orange)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ledge").font(.system(size: 15, weight: .semibold))
                        SettingsNote("Version \(version)")
                    }
                    Spacer(minLength: 8)
                    // One button on this row rather than three. Checking is
                    // disabled while Sparkle says a check is running, and
                    // `isCheckingForUpdates` is observable state the shell
                    // writes — a closure called during `body` is something
                    // nothing can watch, so the button kept whatever it was
                    // last drawn with.
                    Button(model.isCheckingForUpdates ? "Checking…" : "Check for Updates…") {
                        actions.checkForUpdates()
                    }
                    .disabled(model.isCheckingForUpdates)
                }
                .padding(.vertical, 2)
                .searchRow("version", highlighted: highlighted)

                LabeledContent("Source code") {
                    Button("View Source on GitHub") { actions.openSource() }
                }
                .searchRow("source", highlighted: highlighted)
            } footer: {
                SettingsNote("Ledge is open source.")
            }

            // The commonest thing a new user needs is not a setting: it is
            // being told how the app is driven at all. It was reachable only
            // from About, which is the last place anyone looks for
            // instructions.
            Section {
                LabeledContent("The tour") {
                    Button("Show Me How It Works…") { actions.showOnboarding() }
                }
                .searchRow("tour", highlighted: highlighted)
            } header: {
                Text("New to Ledge?")
            } footer: {
                // Said once. It used to be here *and*, half of it, under
                // Gestures two sections below.
                SettingsNote("Hover the notch to open a card. Click to keep it open. Swipe left and right to move between cards. Drag a file onto it to park the file there.")
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
                .searchRow("launchAtLogin", highlighted: highlighted)
                if loginItemFailed {
                    // The status string alone was a dead end: it says macOS
                    // refused and nothing says what to do about it. The
                    // approval, when there is one to give, is in Login Items
                    // & Extensions.
                    SettingsStatus(actions.loginItemStatus(), .attention)
                    Button("Open Login Items…") { actions.openLoginItems() }
                        .controlSize(.small)
                }
            } header: {
                Text("Starting up")
            }

            Section {
                Toggle("Match my trackpad's scroll direction", isOn: $preferences.naturalSwipe)
                    .searchRow("naturalSwipe", highlighted: highlighted)
                SettingsNote("Swiping the notch moves between cards the way your trackpad scrolls.")
                Toggle("Stay quiet during a Focus", isOn: $preferences.quietDuringFocus)
                    .searchRow("quietDuringFocus", highlighted: highlighted)
                SettingsNote("Announcements wait. A low battery, a recording light or your own timer still come through.")
            } header: {
                Text("While it runs")
            }

            Section {
                // Stored as "hide", shown as "show": the setting people look
                // for is the one that puts Ledge *in* the picture, and off is
                // the safe default — nobody wants their music in a screenshot
                // of their work.
                Toggle("Show Ledge in screenshots and recordings", isOn: Binding(
                    get: { !preferences.hideFromScreenCapture },
                    set: { preferences.hideFromScreenCapture = !$0 }
                ))
                .searchRow("hideFromScreenCapture", highlighted: highlighted)
                SettingsNote(preferences.hideFromScreenCapture
                    ? "Ledge stays out of screenshots, screen recordings and shared screens in meetings. Everything else on screen is captured as usual."
                    : "Ledge appears in screenshots, screen recordings and shared screens — useful for showing it to someone.")
            } header: {
                Text("Privacy")
            }

            Section {
                LabeledContent("Quit Ledge") {
                    Button("Quit Ledge", action: actions.quit)
                }
                .searchRow("quit", highlighted: highlighted)
                SettingsNote("Opening Ledge again brings this window back.")

                // The one button in the window that cannot be undone by
                // pressing it again. It used to live in About and to promise
                // less than it does.
                LabeledContent("Reset all settings") {
                    Button("Reset All Settings…", role: .destructive) { confirmingReset = true }
                }
                .searchRow("reset", highlighted: highlighted)
                SettingsNote("Asks first. Devices and their history are kept.")
            } header: {
                Text("Leaving")
            }
        }
        .confirmationDialog(
            "Reset every setting to its default?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset All Settings", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // What it actually does. `Prefs.allNames` carries the Shelf's
            // parked files, the quick-timer recents and the external display
            // levels, so reset empties the Shelf — which the old sentence
            // said nothing about.
            Text("""
                Every switch, slider and choice goes back to how Ledge shipped, and \
                the Shelf is emptied (the files themselves stay where they are). \
                Devices, their battery history and their alerts are kept, the \
                \(KeepAwakeCopy.lidClosed) helper stays installed, and Launch at login \
                is switched off.
                """)
        }
        // The same two-second re-read the other panes use. General shows the
        // update check's state and the login item's, and both move without
        // anything in this pane touching them.
        .refreshingPermissions(actions)
    }

    private func reset() {
        preferences.resetToDefaults()
        // The login item lives in SMAppService, not in defaults: without this
        // the toggle showed Off while the registration survived, and the next
        // launch's reconcile flipped it back On — a reset that visibly didn't
        // stick.
        _ = actions.setLaunchAtLogin(false)
    }
}

extension View {
    /// Points at a row for as long as something is pointing at it.
    ///
    /// Used by search: a result lands on its pane and says which row it meant,
    /// because "Cards › Weather" is a place, not a line in a list of twelve.
    @ViewBuilder
    func highlighted(_ isOn: Bool) -> some View {
        if isOn {
            self.padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                )
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
        } else {
            self
        }
    }

    /// Names a row so search can reach it: lights it when it is the one
    /// being pointed at, and gives it an identity the page can scroll to.
    ///
    /// Both halves matter. A highlight on a row three screens below the fold
    /// is a highlight nobody sees, which is what the first version of this
    /// shipped as.
    func searchRow(_ name: String, highlighted current: String?) -> some View {
        highlighted(current == name).id(name)
    }
}
