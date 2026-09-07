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

    /// Sparkle. The standard controller owns the whole flow — scheduled checks,
    /// the update window, install-on-quit — so the app's only job is to expose
    /// "Check for Updates…" in the menu.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Whether start() ran — the single-instance guard exits before it does.
    private var started = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard enforceSingleInstance() else { return }
        // A second copy asks the running one to show Settings before it
        // exits, so double-clicking Ledge.app again is never a silent no-op.
        observeShowSettingsRequests()
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
        guard rivals.isEmpty else {
            Self.log.error("another instance is already running — handing off and exiting")
            DistributedNotificationCenter.default().postNotificationName(
                Self.showSettingsRequest, object: nil, userInfo: nil, deliverImmediately: true
            )
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    private static let showSettingsRequest = Notification.Name("com.egemert.ledge.showSettings")
    private var showSettingsToken: (any NSObjectProtocol)?

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
        coordinator.showSettings()
        return true
    }

    /// Explicit teardown on quit. Most of it would be reclaimed by the process
    /// exiting anyway — but the event tap and the CoreAudio listeners are
    /// registered with system services, and unwinding them deliberately is the
    /// difference between a clean exit and relying on the kernel to tidy up.
    func applicationWillTerminate(_ notification: Notification) {
        // Only tear down what was actually started. The single-instance exit
        // terminates *before* start(): `coordinator` is lazy, so stopping here
        // would build a fresh coordinator whose HUD teardown writes an empty
        // brightness table over the running instance's saved levels and
        // restores gamma system-wide — launching a second copy un-dimmed the
        // first copy's external display.
        guard started else { return }
        coordinator.stop()
    }
}
