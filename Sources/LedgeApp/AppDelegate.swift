import AppKit
import LedgeCore
import LedgeShell
import LedgeSystem
import Sparkle
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "app")

    private let preferences = Preferences(store: UserDefaultsPreferenceStore())
    private lazy var coordinator = LedgeCoordinator(preferences: preferences)

    /// Tells the coordinator when a termination is Sparkle relaunching us.
    ///
    /// Its own object rather than the delegate on this class: `AppDelegate` is
    /// created before the coordinator is, and the only thing Sparkle is asked
    /// for here is that one fact.
    private lazy var updaterDelegate = UpdateRelaunchWatcher { [weak self] in
        self?.coordinator.willRelaunchForUpdate()
    }

    /// Sparkle. The standard controller owns the whole flow — scheduled checks,
    /// the update window, install-on-quit — so the app's only job is to build
    /// it at launch and expose "Check for Updates…" in Settings.
    ///
    /// Lazy only so it can capture `updaterDelegate`. Being lazy is also how it
    /// stopped existing: from 1.1.0 to 1.2.3 nothing touched it but that
    /// button, so Sparkle never started and no automatic check ever ran.
    /// `startNormally()` builds it now, on every normal launch.
    private lazy var updater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: updaterDelegate,
        userDriverDelegate: nil
    )

    /// Whether start() ran — the single-instance guard exits before it does.
    private var started = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard enforceSingleInstance() else { return }
        continueLaunching()
    }

    /// The rest of a launch once no other copy stands in the way. Split out
    /// so a copy that waited for an older one to quit can carry on from here.
    private func continueLaunching() {
        // A second copy asks the running one to show Settings before it
        // exits, so double-clicking Ledge.app again is never a silent no-op.
        observeShowSettingsRequests()
        observeReplacement()
        guard offerMoveToApplicationsIfNeeded() else { return }
        startNormally()
    }

    /// Everything a normal launch does after the guards — split out so a
    /// failed hand-off to /Applications can fall back to it.
    private func startNormally() {
        guard !started else { return }
        #if DEBUG
        logIdentity()
        #endif
        Self.log.notice("\(SystemCapabilities.probe().summary, privacy: .public)")

        // A new install starts at login, once. Before the reconcile below, so
        // the switch in General shows what this launch did.
        if LoginItemService.shouldTurnOnForNewInstall(
            alreadyOffered: preferences.launchAtLoginOffered,
            hasStoredLaunchAtLogin: preferences.hasStoredValue(Prefs.launchAtLogin.name),
            hasCompletedOnboarding: preferences.hasCompletedOnboarding,
            bundleURL: Bundle.main.bundleURL,
            isReleaseBuild: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        ) {
            preferences.launchAtLoginOffered = true
            LoginItemService.setEnabled(true)
        }

        // The login item can be revoked in System Settings without telling us,
        // so the stored preference is reconciled with reality at every launch.
        preferences.launchAtLogin = LoginItemService.isEnabled

        // Follow the system's "natural scrolling" direction for swipes — but
        // only as a first-run seed. Re-seeding every launch silently reverted
        // the Behavior toggle, making it a control that only worked until the
        // next restart.
        if !preferences.hasStoredValue(Prefs.naturalSwipe.name) {
            preferences.naturalSwipe = Self.systemNaturalScroll
        }

        // Sparkle's updater lives here, beside the bundle it updates, and
        // Settings is the only place that offers a manual check now.
        //
        // Built here, not on first use: `startingUpdater: true` is what starts
        // the scheduled checks, and it only runs when the controller is made.
        // After the single-instance and move-to-Applications guards, so a
        // copy that is about to exit never starts a second updater.
        //
        // Only in a bundle with a feed. `bundle.sh` takes the feed out of a
        // development build so it can never update itself into the real app;
        // started there, Sparkle would ask about automatic checks it then
        // could not run. A press of the button still builds it, as before.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            _ = updater
        }
        coordinator.onCheckForUpdates = { [weak self] in self?.updater.checkForUpdates(nil) }
        coordinator.canCheckForUpdates = { [weak self] in
            self?.updater.updater.canCheckForUpdates ?? false
        }
        coordinator.start()
        started = true

        #if DEBUG
        if ProcessInfo.processInfo.environment["LEDGE_DEBUG"] == "1" {
            coordinator.showSettings()
        }

        // Debug-only: start a focus session shortly after launch, so the card
        // can be exercised without reaching for the menu bar.
        if ProcessInfo.processInfo.environment["LEDGE_START_TIMER"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.coordinator.startTimer()
            }
        }
        #endif

    }

    /// macOS "natural scrolling" — content follows the fingers. Read from the
    /// global domain, defaulting to on (the macOS default) when unset. The swipe
    /// recogniser uses it so up/down match the user's system direction.
    private static var systemNaturalScroll: Bool {
        let value = CFPreferencesCopyValue(
            "com.apple.swipescrolldirection" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        return (value as? Bool) ?? true
    }

    /// A second copy would fight the first for the same screen region. It
    /// hands the running instance a "show Settings" request first: a
    /// stranger who launched Ledge from the disk image and then double-clicks
    /// the copy in /Applications must see *something* happen, not nothing.
    private func enforceSingleInstance() -> Bool {
        let identifier = Bundle.main.bundleIdentifier ?? "com.egemert.ledge"
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        // A copy still running from the disk image (or a translocated path)
        // is the one *handing over* to us — it launched this process from
        // /Applications and is on its way out. It is not a rival, and treating
        // it as one had both processes terminate: "clicked Move, Ledge vanished".
        let rivals = others.filter { other in
            guard let url = other.bundleURL else { return true }
            let path = url.path
            return !(path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/"))
        }
        let decision = RunningCopy.decide(
            rivals: rivals.map { rival in
                let url = rival.bundleURL
                return RunningCopy.Rival(bundleURL: url) {
                    url.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                }
            },
            own: Bundle.main.bundleURL,
            ownBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
        switch decision {
        case .proceed:
            return true
        case .ask where askToReplace(rivals):
            replace(rivals)
        case .ask, .handOff:
            handOff()
        }
        return false
    }

    /// The old answer to a second copy: show the running one's Settings and go.
    private func handOff() {
        Self.log.error("another instance is already running — handing off and exiting")
        DistributedNotificationCenter.default().postNotificationName(
            Self.showSettingsRequest, object: nil, userInfo: nil, deliverImmediately: true
        )
        NSApp.terminate(nil)
    }

    /// Asked only when the running copy is an older build, or this bundle was
    /// replaced underneath it. Not Now is the old hand-off, unchanged.
    private func askToReplace(_ rivals: [NSRunningApplication]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Another copy of Ledge is already open"
        let ours = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        // Only a copy at another path can say which version it is: at this
        // path the plist on disk is already ours.
        let theirs = rivals.count == 1
            ? rivals[0].bundleURL
                .flatMap { $0.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path ? nil : $0 }
                .flatMap { Bundle(url: $0) }?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            : nil
        switch (theirs, ours) {
        case let (theirs?, ours?):
            alert.informativeText = "Ledge \(theirs) is running. Quit it and open Ledge \(ours)?"
        case let (nil, ours?):
            alert.informativeText = "Quit it and open Ledge \(ours)?"
        default:
            alert.informativeText = "Quit it and open this one?"
        }
        if !keepAwakeCarriesOn(rivals) {
            alert.informativeText += " If Keep Awake is running there, it will stop."
        }
        alert.addButton(withTitle: "Quit and Open")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func keepAwakeCarriesOn(_ rivals: [NSRunningApplication]) -> Bool {
        rivals.allSatisfy { rival in
            RunningCopy.keepsKeepAwake(
                running: rival.bundleURL,
                runningBuild: Self.build(of: rival),
                own: Bundle.main.bundleURL
            )
        }
    }

    private static func build(of rival: NSRunningApplication) -> String? {
        rival.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// Asks the older copies to go, then carries on launching. They quit the
    /// ordinary way, so whatever they owe the disk is written first.
    ///
    /// Never hands off to a copy that has agreed to quit: it would show
    /// Settings on its way out, and then nothing would be running at all. A
    /// refusal gets the hand-off at once, to the copy that refused and is
    /// staying. One that is slow gets asked about, as many times as the user
    /// wants to keep waiting.
    private func replace(_ rivals: [NSRunningApplication]) {
        Self.log.notice("an older instance is running — asking it to quit")
        let replacement = CopyReplacement(names: Self.replacementNames, channel: .distributed)
        let copies = rivals.map { rival in
            CopyReplacement.Rival(
                pid: rival.processIdentifier,
                running: rival.bundleURL,
                runningBuild: Self.build(of: rival),
                own: Bundle.main.bundleURL,
                quit: { rival.terminate() },
                isGone: { rival.isTerminated }
            )
        }
        let warned = !keepAwakeCarriesOn(rivals)
        Task { @MainActor in
            let outcome = await replacement.run(
                rivals: copies,
                alreadyWarned: warned,
                askAnyway: { self.askToQuitWithoutAnAnswer(isSettled: $0) }
            )
            guard outcome == .waitForExit else {
                Self.log.error("the older instance would not quit")
                self.handOff()
                return
            }
            while !(await RunningCopy.waitForExit(
                allTerminated: { rivals.allSatisfy(\.isTerminated) },
                sleep: { try? await Task.sleep(for: $0) }
            )) {
                Self.log.error("the older instance is still quitting")
                guard self.askToKeepWaiting(rivals) else {
                    NSApp.terminate(nil)
                    return
                }
            }
            self.continueLaunching()
        }
    }

    /// The older copy can keep Keep Awake going but hasn't answered. Its main
    /// thread is stuck, so a quit from outside would end the session.
    ///
    /// Takes itself down if the answer comes after all: the question is over.
    private func askToQuitWithoutAnAnswer(isSettled: @escaping @MainActor () -> Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "The other copy of Ledge is not answering"
        alert.informativeText = "Quit it anyway and open this one? If Keep Awake is running there, it will stop."
        alert.addButton(withTitle: "Quit and Open")
        alert.addButton(withTitle: "Not Now")
        let watch = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                if isSettled() { NSApp.abortModal() }
            }
        }
        RunLoop.main.add(watch, forMode: .modalPanel)
        defer { watch.invalidate() }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The older copy agreed to quit and has not yet. Stop leaves it to finish
    /// on its own; Ledge can be opened again once it has.
    ///
    /// Takes itself down when the old copy goes while it is up, and that
    /// counts as Keep Waiting: the wait that follows ends at once.
    private func askToKeepWaiting(_ rivals: [NSRunningApplication]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "The other copy of Ledge is still closing"
        alert.informativeText = "It is finishing what it was doing. Keep waiting, or stop and open Ledge again in a moment."
        alert.addButton(withTitle: "Keep Waiting")
        alert.addButton(withTitle: "Stop Opening")
        let watch = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                if rivals.allSatisfy(\.isTerminated) { NSApp.abortModal() }
            }
        }
        RunLoop.main.add(watch, forMode: .modalPanel)
        defer { watch.invalidate() }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() != .alertSecondButtonReturn
    }

    /// Named after *this* bundle, so a development build and the installed app
    /// cannot answer each other's requests. They used to share one name, and
    /// opening either would pop the other one's settings window.
    private static let showSettingsRequest = Notification.Name(
        "\(Bundle.main.bundleIdentifier ?? "com.egemert.ledge").showSettings"
    )
    private var showSettingsToken: (any NSObjectProtocol)?

    private static let replacementNames = ReplacementNames(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.egemert.ledge"
    )
    private var replacementListener: ReplacementListener?

    /// A newer copy asks this one to go. A copy that hasn't started has nothing
    /// to carry over, so it only goes.
    private func observeReplacement() {
        let listener = ReplacementListener(
            names: Self.replacementNames,
            channel: .distributed,
            markSession: { [weak self] in
                guard let self, self.started else { return }
                self.coordinator.beingReplacedByNewerCopy()
            },
            quit: { NSApp.terminate(nil) }
        )
        listener.start()
        replacementListener = listener
    }

    private func observeShowSettingsRequests() {
        showSettingsToken = DistributedNotificationCenter.default().addObserver(
            forName: Self.showSettingsRequest, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator.showSettings() }
        }
    }

    /// Running from the mounted disk image or an App Translocation path is a
    /// trap: TCC grants bind to a throwaway location, Sparkle cannot update a
    /// read-only volume, and a login item would point at the DMG. Offer to
    /// move to /Applications and relaunch from there before anything else
    /// starts. Returns false when this process is handing over.
    private func offerMoveToApplicationsIfNeeded() -> Bool {
        let path = Bundle.main.bundlePath
        let onImage = path.hasPrefix("/Volumes/")
        let translocated = path.contains("/AppTranslocation/")
        guard onImage || translocated else { return true }
        let destination = "/Applications/Ledge.app"

        let alert = NSAlert()
        alert.messageText = "Move Ledge to the Applications folder?"
        alert.informativeText = onImage
            ? "Ledge is running from the disk image. Move it to Applications so it can remember its permissions and update itself."
            : "Ledge was opened from a temporary location. Move it to Applications so it can remember its permissions and update itself."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return true }

        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: destination) {
                try manager.removeItem(atPath: destination)
            }
            try manager.copyItem(atPath: path, toPath: destination)
            // Launch the copy and step aside. The new process's single-instance
            // check knows to ignore a copy still running from the image (see
            // enforceSingleInstance), so the order of the two exits no longer
            // matters — but we still terminate only once the launch request
            // has been accepted, so a refused launch leaves this copy usable.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: destination), configuration: configuration
            ) { app, error in
                DispatchQueue.main.async {
                    if app != nil {
                        NSApp.terminate(nil)
                        return
                    }
                    // The copy would not launch: carry on from here rather
                    // than leave a process with nothing running in it.
                    Self.log.error("relaunch from Applications failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                    MainActor.assumeIsolated { self.startNormally() }
                }
            }
            return false
        } catch {
            Self.log.error("move to Applications failed: \(error.localizedDescription, privacy: .public)")
            let failure = NSAlert()
            failure.messageText = "Ledge couldn't move itself"
            failure.informativeText = "Drag Ledge to the Applications folder in Finder, then open it from there. (\(error.localizedDescription))"
            failure.runModal()
            return true
        }
    }

    /// TCC keys grants to the code signature. If this ever prints an ad-hoc
    /// identity, every permission will re-prompt on the next rebuild — which is
    /// the failure you would otherwise spend an afternoon misdiagnosing.
    private func logIdentity() {
        let bundleID = Bundle.main.bundleIdentifier ?? "<none>"
        let path = Bundle.main.bundlePath
        Self.log.notice("bundle: \(bundleID, privacy: .public) at \(path, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvvv", path]
        let pipe = Pipe()
        process.standardError = pipe
        // Discarded, not piped: stdout is never read, and waitUntilExit with
        // a full, undrained pipe would deadlock the launch.
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let interesting = text
                .split(separator: "\n")
                .filter { $0.hasPrefix("Authority=") || $0.hasPrefix("Identifier=") }
                .joined(separator: " | ")
            Self.log.notice("signature: \(interesting.isEmpty ? text : interesting, privacy: .public)")
        } catch {
            Self.log.error("codesign check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Re-opening the app — double-clicking it in Finder, or `open`-ing it while
    /// it already runs — shows Settings. Without this, a menu-bar-only app is
    /// unreachable once its status item is pushed off a full menu bar (or under
    /// the notch), with no other way in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Not before the launch has started anything. A copy waiting for an
        // older one to quit has no coordinator yet, and building one here
        // would start a second Ledge's worth of state beside the first.
        guard started else { return false }
        coordinator.showSettings()
        return true
    }

    /// Explicit teardown on quit. Most of it would be reclaimed by the process
    /// exiting anyway — but the event tap and the CoreAudio listeners are
    /// registered with system services, and unwinding them deliberately is the
    /// difference between a clean exit and relying on the kernel to tidy up.
    /// Holds the quit open while what is owed to the disk is written.
    ///
    /// `applicationWillTerminate` is the wrong place for this: a detached task
    /// started there is not guaranteed to finish before the process goes, and
    /// waiting for it on the main thread stalls the quit. AppKit's own answer
    /// is the asynchronous reply — say "not yet", do the work, then say yes.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Nothing was started, so nothing is owed. Touching `coordinator` here
        // would build one in a secondary instance, whose teardown writes an
        // empty brightness table over the running instance's saved levels.
        guard started else { return .terminateNow }
        // A second request while the first flush is still running must wait
        // for it too — answering `.terminateNow` here would exit underneath
        // the write it was waiting for.
        guard !isFlushing else { return .terminateLater }
        isFlushing = true

        Task { @MainActor in
            await coordinator.flushPendingWork()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private var isFlushing = false

    func applicationWillTerminate(_ notification: Notification) {
        // Only tear down what was actually started. The single-instance exit
        // terminates *before* start(): `coordinator` is lazy, so touching it
        // here would build a fresh coordinator whose HUD teardown writes an
        // empty brightness table over the running instance's saved levels and
        // restores gamma system-wide — launching a second copy un-dimmed the
        // first copy's external display.
        guard started else { return }
        coordinator.stop()
    }
}


/// Notices that the next termination is an update relaunch, not a quit.
///
/// Without this they are the same event from inside `applicationShouldTerminate`,
/// and Keep Awake would end a session every time Ledge updated itself — which
/// is the one case where the user has not asked for anything to stop.
private final class UpdateRelaunchWatcher: NSObject, SPUUpdaterDelegate {

    private let willRelaunch: @MainActor () -> Void

    init(willRelaunch: @escaping @MainActor () -> Void) {
        self.willRelaunch = willRelaunch
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { willRelaunch() }
    }
}
