import AppKit
import CoreBluetooth
import CoreLocation
import EventKit
import Foundation
import LedgeCore
import os

/// Checks and requests the permissions this app can need.
///
/// Two rules hold throughout:
///
/// - **Checking never prompts.** Every `status(of:)` path uses an API that
///   reports state without showing a dialog, so it is safe to call on a timer
///   while the settings window is open.
/// - **Requesting only happens from an explicit user action.** Nothing here is
///   called at launch. A permission dialog with no visible cause is worse than
///   a missing feature.
@MainActor
public final class PermissionCenter: NSObject, CLLocationManagerDelegate {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "permissions")

    /// Retained because `CLLocationManager` delivers its answer to a delegate
    /// and stops working the moment it is deallocated.
    private var locationManager: CLLocationManager?

    /// The system's own Focus answer, behind an ordinary prompt.
    private let focusStatus = FocusStatusReader()

    /// The manager created purely to raise the Bluetooth prompt, and the
    /// delegate that resolves it. Retained until the state settles or the
    /// user has had 15 seconds to answer.
    private var bluetoothPrompt: (manager: CBCentralManager, delegate: BluetoothPromptDelegate)?

    private func promptForBluetooth() async {
        guard bluetoothPrompt == nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let delegate = BluetoothPromptDelegate { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.bluetoothPrompt != nil else { return }
                    self.bluetoothPrompt = nil
                    continuation.resume()
                }
            }
            let manager = CBCentralManager(delegate: delegate, queue: .main)
            bluetoothPrompt = (manager, delegate)
            // Failsafe: a dialog left unanswered must not hold the caller
            // forever. The manager keeps prompting on its own timetable; the
            // status is simply re-read whenever the pane refreshes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.bluetoothPrompt != nil else { return }
                    self.bluetoothPrompt = nil
                    continuation.resume()
                }
            }
        }
    }

    public override init() { super.init() }

    /// A location manager with this object as its delegate. macOS will not show
    /// the authorization prompt for a manager that has no delegate set, so every
    /// path that touches location must go through here.
    private func makeLocationManager() -> CLLocationManager {
        if let locationManager { return locationManager }
        let manager = CLLocationManager()
        manager.delegate = self
        locationManager = manager
        return manager
    }

    /// Fired when a permission's answer arrives *after* `request` returned —
    /// Location prompts asynchronously and reports through this delegate.
    /// The shell restarts the providers gated on it.
    public var onAuthorizationChanged: @MainActor (PermissionKind, _ granted: Bool) -> Void = { _, _ in }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Self.permDiag("location delegate: authorization -> \(status.rawValue)")
        Task { @MainActor [weak self] in
            guard let self, status != .notDetermined else { return }
            self.onAuthorizationChanged(.location, status == .authorizedAlways)
        }
    }

    /// Env-gated (`LEDGE_PERM_DIAG=1`) trace of what a permission request actually
    /// did, appended to `~/.ledge-perm-diag`. Calendar/location can fail silently
    /// (no prompt, no TCC row) and this is the only way to see why.
    nonisolated static func permDiag(_ message: String) {
        guard DebugSwitches.isOn("LEDGE_PERM_DIAG") else { return }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".ledge-perm-diag")
        guard let data = (message + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Checking

    public func status(of permission: PermissionKind) -> PermissionStatus {
        switch permission {
        case .accessibility: accessibilityStatus()
        case .automation: automationStatus()
        case .calendars: calendarStatus()
        case .bluetooth: bluetoothStatus()
        case .location: locationStatus()
        case .focusStatus: focusStatusStatus()
        }
    }

    public func snapshot() -> [PermissionRow] {
        PermissionKind.allCases.map { PermissionRow(kind: $0, status: status(of: $0)) }
    }

    private func accessibilityStatus() -> PermissionStatus {
        // Unlike the others this has no "not determined" state — the app either
        // appears in the Accessibility list as trusted or it does not. Untrusted
        // reads as *not requested*, not "Denied": on a fresh Mac nobody refused
        // anything, and the pane must offer the prompt (which is what adds Ledge
        // to the Accessibility list at all) rather than send the user to a
        // list Ledge is not yet in.
        //
        // Asked of the live system, not the process cache: a grant revoked
        // while the app runs never reaches the cache, and this status is what
        // the Permissions pane draws and what the revalidation compares.
        MediaKeyInterceptor.isTrusted ? .granted : .notDetermined
    }

    private func calendarStatus() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        // Write-only is useless here: the whole feature is reading the next
        // event, so it is a denial in everything but name.
        case .denied, .restricted, .writeOnly: .denied
        @unknown default: .notDetermined
        }
    }

    private func bluetoothStatus() -> PermissionStatus {
        // Reading the static authorization does not prompt. *Instantiating* a
        // CBCentralManager and scanning is what prompts, which is why the
        // Bluetooth provider deliberately uses IOBluetooth instead and treats
        // this permission as an optional upgrade rather than a requirement.
        switch CBCentralManager.authorization {
        case .allowedAlways: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .notDetermined
        }
    }

    private func locationStatus() -> PermissionStatus {
        let manager = makeLocationManager()
        // Only `.authorizedAlways` exists on macOS; the `.authorized` and
        // `.authorizedWhenInUse` cases are iOS-only, and naming one here breaks
        // inference for the whole switch.
        switch manager.authorizationStatus {
        case .authorizedAlways: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .notDetermined
        }
    }

    /// Whether Music or Spotify can be scripted.
    ///
    /// The grant is **per controlled application**, not global, so this is an
    /// aggregate: granted if any supported player is granted, denied only if
    /// every running one is denied. A player that is not running reports
    /// `procNotFound`, which must not count as a denial — asking about a
    /// non-running app would launch it.
    /// The last answer the background query gave. Every caller reads this;
    /// nobody waits for the query itself. See `startAutomationQuery`.
    private var automationCache: PermissionStatus = .notDetermined

    /// True while a query is out. Cleared when the query *returns*, not when
    /// anyone stops caring about it: the Apple Event call blocks for as long
    /// as the target app takes to answer, and starting a second one would
    /// only tie up another thread behind the first.
    private var automationQueryInFlight = false

    /// Whether a query has ever come back. Until it has, the deadline may fill
    /// in "not requested"; afterwards the real answer stands.
    private var hasAutomationAnswer = false

    /// Called when a background query changes the cached answer, so whoever
    /// built a snapshot from the stale one can build it again.
    public var onAutomationStatusChanged: (() -> Void)?

    /// Whether this app may talk to Music or Spotify yet.
    ///
    /// Set false until the welcome tour has been through, because the query is
    /// not as silent as its `askUserIfNeeded: false` promises: on macOS 26 the
    /// first one against an undecided app raises the Automation dialog. A
    /// fresh user met that dialog seconds after launch, before anything had
    /// explained what Ledge was — and answering it wrongly is the one mistake
    /// TCC will not let them take back from inside the app.
    public var mayAskAboutPlayers = false

    /// When the last Apple Event query was started. Every other permission is
    /// a local read; this one is an IPC round-trip to another application, and
    /// the settings pane snapshots every two seconds.
    private var lastAutomationQuery: TimeInterval = -.greatestFiniteMagnitude

    /// The shortest gap between two queries. Long enough that an open pane is
    /// not a stream of Apple Events, short enough that a grant made in System
    /// Settings is noticed while the user is still looking at the window.
    private static let automationQueryInterval: TimeInterval = 10

    private func automationStatus() -> PermissionStatus {
        // Reads "not requested" while the gate is shut, which is true of this
        // app's asking and not necessarily of the grant: someone who allowed
        // Automation for a previous install is told it has not been requested
        // until they press the button, which then finds it already granted.
        // The alternative is worse — the query is itself a prompt (see
        // `mayAskAboutPlayers`), so an honest reading here would put a system
        // dialog in front of a first-time user with nothing to explain it.
        guard mayAskAboutPlayers else { return .notDetermined }

        let running = Self.automationTargets.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        // No supported player running is not "unavailable on this Mac" — a
        // fresh user with Music installed but closed read exactly that. It
        // is simply not askable right now.
        guard !running.isEmpty else {
            automationCache = .notApplicableNow
            return automationCache
        }
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastAutomationQuery >= Self.automationQueryInterval {
            lastAutomationQuery = now
            startAutomationQuery(for: running)
        }
        return automationCache
    }

    private static let automationTargets = ["com.apple.Music", "com.spotify.client"]

    /// How long the pane waits for an answer before showing the one it has.
    private static let automationQueryDeadline: TimeInterval = 3

    /// Asks off the main thread, always.
    ///
    /// `AEDeterminePermissionToAutomateTarget` is a synchronous Apple Event to
    /// the target app, and a busy target simply does not reply: called on the
    /// main thread at launch it wedged the whole app before the panel was ever
    /// shown — no notch, no cards, no way to tell the app apart from one that
    /// had failed to start. Nothing may wait on this call.
    private func startAutomationQuery(for bundleIDs: [String]) {
        guard !automationQueryInFlight else { return }
        automationQueryInFlight = true
        Task { [weak self] in
            let answer = await Self.askAutomation(for: bundleIDs)
            await MainActor.run {
                guard let self else { return }
                self.automationQueryInFlight = false
                self.hasAutomationAnswer = true
                guard answer != self.automationCache else { return }
                self.automationCache = answer
                self.onAutomationStatusChanged?()
            }
        }

        // The query has no deadline of its own and has been seen never to
        // return at all. Whatever it eventually says still lands (the task
        // above outlives this), but the pane stops waiting: "not requested"
        // is the honest reading of an answer that did not arrive.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.automationQueryDeadline))
            await MainActor.run {
                guard let self, self.automationQueryInFlight else { return }
                Self.log.notice("automation: permission query did not answer in time")
                // Only ever for the *first* reading. Downgrading an answer we
                // already have was a lie in the other direction, and an
                // expensive one: the query reliably outruns this deadline, so
                // every pass flipped granted -> notDetermined -> granted, which
                // the shell read as a permission lost and regained. Each cycle
                // tore down the now-playing provider and pulled the settings
                // window to the front, a few seconds apart, for as long as the
                // Permissions pane was open.
                guard !self.hasAutomationAnswer else { return }
                guard self.automationCache != .notDetermined else { return }
                self.automationCache = .notDetermined
                self.onAutomationStatusChanged?()
            }
        }
    }

    private nonisolated static func askAutomation(
        for bundleIDs: [String]
    ) async -> PermissionStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<PermissionStatus, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var answer = PermissionStatus.notDetermined
                for bundleID in bundleIDs {
                    switch rawAutomationStatus(forBundleID: bundleID) {
                    case .granted:
                        answer = .granted
                    case .denied:
                        if answer != .granted { answer = .denied }
                    default:
                        break
                    }
                    if answer == .granted { break }
                }
                continuation.resume(returning: answer)
            }
        }
    }

    private nonisolated static func rawAutomationStatus(forBundleID bundleID: String) -> PermissionStatus {
        var address = AEAddressDesc()
        let created = bundleID.withCString { pointer -> OSErr in
            AECreateDesc(
                typeApplicationBundleID,
                pointer,
                strlen(pointer),
                &address
            )
        }
        guard created == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&address) }

        // `askUserIfNeeded: false` is the whole point — this reports the state
        // without ever showing a dialog.
        let status = AEDeterminePermissionToAutomateTarget(
            &address, typeWildCard, typeWildCard, false
        )

        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .unavailable
        default: return .notDetermined
        }
    }

    /// Whether Ledge may ask the system if a Focus is on.
    private func focusStatusStatus() -> PermissionStatus {
        switch focusStatus.authorization {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .denied
        case .notDetermined: return .notDetermined
        }
    }


    // MARK: - Requesting

    /// Prompts, where prompting is possible. Returns the status afterwards.
    @discardableResult
    public func request(_ permission: PermissionKind) async -> PermissionStatus {
        guard permission.isRequestable else {
            // Full Disk Access cannot be asked for at all — the only remedy is
            // System Settings.
            openSettings(for: permission)
            return status(of: permission)
        }

        switch permission {
        case .accessibility:
            // The prompt is a courtesy, not the grant: the switch lives in
            // System Settings either way, and macOS shows this dialog at most
            // once per app — after it has been dismissed, later calls do
            // nothing at all. A button that silently does nothing is how this
            // permission became impossible to turn on from inside the app, so
            // the pane is opened as well, every time.
            MediaKeyInterceptor.requestTrust()
            openSettings(for: .accessibility)

        case .calendars:
            let statusBefore = EKEventStore.authorizationStatus(for: .event).rawValue
            let store = EKEventStore()
            let granted: Bool = await withCheckedContinuation { continuation in
                store.requestFullAccessToEvents { granted, error in
                    Self.permDiag("""
                        calendar completion: statusBefore=\(statusBefore) granted=\(granted) \
                        error=\(error.map { "\($0)" } ?? "nil")
                        """)
                    continuation.resume(returning: granted)
                }
            }
            Self.permDiag("calendar request returned granted=\(granted) (final status=\(EKEventStore.authorizationStatus(for: .event).rawValue))")

        case .location:
            let manager = makeLocationManager()
            Self.permDiag("""
                location: servicesEnabled=\(CLLocationManager.locationServicesEnabled()) \
                statusBefore=\(manager.authorizationStatus.rawValue) — requesting
                """)
            manager.requestWhenInUseAuthorization()

        case .automation:
            // There is no standalone request. The prompt appears when an Apple
            // event is actually sent, so the honest move is to send a harmless
            // one and let macOS ask.
            //
            // Asking is itself consent to ask: until the user pressed this,
            // queries were held back (see `mayAskAboutPlayers`), which also
            // meant the status could only ever read "not requested" — so
            // granting it here could never show up in the row that asked.
            mayAskAboutPlayers = true
            await requestAutomation()
            // The answer arrives on a background query; make sure the next
            // reading actually runs one rather than serving the rate-limited
            // cache from before the grant.
            lastAutomationQuery = -.greatestFiniteMagnitude

        case .bluetooth:
            // Requesting means starting a CBCentralManager — the one thing that
            // raises the system prompt, and the one thing the providers never
            // do on their own (see AirPodsProximityScanner.start). Here it is
            // the user's explicit ask, so a manager is created solely to
            // prompt and kept alive until the state settles. Already decided
            // (denied/restricted) → the only remedy is System Settings.
            switch CBCentralManager.authorization {
            case .notDetermined:
                await promptForBluetooth()
            case .allowedAlways:
                break
            default:
                openSettings(for: permission)
            }

        case .focusStatus:
            await focusStatus.requestAuthorization()
        }

        let result = status(of: permission)
        Self.log.notice("""
            requested \(permission.rawValue, privacy: .public) -> \
            \(result.rawValue, privacy: .public)
            """)
        return result
    }

    /// Launches Music and waits for it to be up enough to answer an event.
    ///
    /// Returns false if it never arrives, so the caller can stop rather than
    /// send an event into nothing.
    private static func openMusic() async -> Bool {
        let id = "com.apple.Music"
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            log.notice("automation: Music is not installed — cannot raise the prompt")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)

        for _ in 0..<20 {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        log.notice("automation: Music did not come up in time")
        return false
    }

    private func requestAutomation() async {
        // Asking is only possible against a running player, and the button
        // that leads here used to be hidden when there was none — leaving
        // someone whose Music was closed with no way to grant this at all.
        // Opening Music *is* the missing step, so it happens here rather than
        // being described in a sentence the user has to act on themselves.
        var bundleID = Self.automationTargets.first {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        if bundleID == nil {
            bundleID = await Self.openMusic() ? "com.apple.Music" : nil
        }
        guard let bundleID else { return }

        let name = bundleID == "com.spotify.client" ? "Spotify" : "Music"
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                // `player state` is a read with no side effect, and the app is
                // already running, so this cannot launch anything.
                process.arguments = ["-e", "tell application \"\(name)\" to player state"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    // MARK: - System Settings

    /// Opens the pane that grants this permission.
    public func openSettings(for permission: PermissionKind) {
        let anchor: String
        switch permission {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .automation: anchor = "Privacy_Automation"
        case .calendars: anchor = "Privacy_Calendars"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        case .location: anchor = "Privacy_LocationServices"
        case .focusStatus: anchor = "Privacy_Focus"
        }

        let url = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        )
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether the process that launched this app is a terminal.
    ///
    /// macOS attributes a permission grant to the *responsible* process, so a
    /// build launched from a shell has its grants credited to the shell — which
    /// looks exactly like a denial and is very hard to diagnose. Worth warning
    /// about in the settings pane rather than letting someone chase it.
    public var isLaunchedFromTerminal: Bool {
        let parent = getppid()
        guard parent > 1 else { return false }
        guard let app = NSRunningApplication(processIdentifier: parent),
              let bundleID = app.bundleIdentifier
        else {
            // No bundle id at all usually means a plain shell process.
            return true
        }
        return ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable"]
            .contains(bundleID)
    }
}

/// Resolves once the manager reports a decided state — the prompt answered.
private final class BluetoothPromptDelegate: NSObject, CBCentralManagerDelegate, Sendable {
    private let onDecided: @Sendable () -> Void

    init(onDecided: @escaping @Sendable () -> Void) {
        self.onDecided = onDecided
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // `.unknown`/`.resetting` precede the decision; anything else means
        // the system has settled (authorised → poweredOn/Off, or unauthorized).
        switch central.state {
        case .unknown, .resetting: break
        default: onDecided()
        }
    }
}
