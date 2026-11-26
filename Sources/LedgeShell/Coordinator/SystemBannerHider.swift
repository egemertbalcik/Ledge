import AppKit
import ApplicationServices
import os

/// Keeps macOS's own headphone banner off the screen, so the notch is the one
/// place a device arrival is told.
///
/// The banner is not a notification anybody can switch off: audioaccessoryd
/// posts it on in-ear with no preference consulted, and Control Center draws
/// it in a system dialog window at the top of the screen. What can be done is
/// to move that window out of sight the moment it exists, which needs the
/// Accessibility grant.
///
/// Control Center draws its own menus in windows of much the same kind, so
/// shape is not enough to tell the banner from them. Three things have to
/// hold before a window is touched:
/// - A device was just heard (`deviceHeard`) and the window was created
///   around that moment. A menu the user opened a while ago, or opens later,
///   is never asked anything.
/// - The notch would tell the arrival itself (`mayHide`). With the device
///   card off, Bluetooth not granted or a Focus keeping the notch quiet, the
///   banner is the only word the user gets and it is left alone.
/// - It looks like the banner: a system dialog, banner-sized, at the top of
///   the right half of the screen.
///
/// A window that was moved is put back once the banner has had time to go,
/// and again when Ledge quits, so nothing of Control Center's is left out of
/// sight.
///
/// `defaults write com.egemert.ledge systemBanner.hideDevice -bool false`
/// turns it off altogether. The banner has only been seen on macOS 26, so on
/// anything older this does nothing.
@MainActor
final class SystemBannerHider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "system-banner")
    private nonisolated static let controlCenterID = "com.apple.controlcenter"
    private static let enabledKey = "systemBanner.hideDevice"

    /// How long any one question to Control Center may take. These calls are
    /// made on the main thread. The default wait is several seconds: a
    /// Control Center that had stopped answering would have stalled the notch.
    private static let messagingTimeout: Float = 0.25

    /// How far back from a device being heard a window may have been created
    /// and still be its banner. The banner can beat Ledge to it: the device is
    /// read before it is reported.
    nonisolated static let lookBack: TimeInterval = 1.5
    /// The same for a change of sound output but shorter: an output is
    /// often chosen from Control Center's own Sound menu, which has been open
    /// for a moment by then and must not be taken for the banner.
    nonisolated static let soundOutputLookBack: TimeInterval = 0.5
    /// How long after a device is heard its banner may still turn up.
    nonisolated static let lookAhead: TimeInterval = 3
    /// How long a moved window stays away. Longer than the banner is shown.
    nonisolated static let awayFor: TimeInterval = 10

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var launchToken: NSObjectProtocol?
    private var quitToken: NSObjectProtocol?

    /// Windows Control Center created lately, oldest first. Only the moment
    /// is kept. Nothing is asked of a window unless a device is heard.
    private var created: [(window: AXUIElement, at: TimeInterval)] = []
    /// When a device was last heard.
    private var heardAt: TimeInterval = -.infinity
    /// Windows moved away, with where they were, so they can be put back.
    private var away: [(window: AXUIElement, origin: CGPoint)] = []

    /// Whether the notch would say a device arrival right now. Asked every
    /// time a device is heard, since the answer changes with Settings, with
    /// permissions and with Focus.
    var mayHide: @MainActor () -> Bool = { true }

    /// The rule behind `mayHide`, apart from the coordinator so it can be
    /// checked without one.
    ///
    /// Without the Bluetooth grant Ledge never hears a connection as it
    /// happens, so it would say nothing while hiding the one banner that did.
    nonisolated static func mayHide(
        deviceCardOn: Bool, bluetoothGranted: Bool, admitsDeviceNews: Bool
    ) -> Bool {
        deviceCardOn && bluetoothGranted && admitsDeviceNews
    }

    /// Whether a window created at `created` belongs to the device heard at
    /// `heard`: shortly before it or within a few seconds after.
    nonisolated static func isDue(
        created: TimeInterval, heard: TimeInterval, lookBack: TimeInterval = SystemBannerHider.lookBack
    ) -> Bool {
        created >= heard - lookBack && created <= heard + lookAhead
    }

    /// The setting alone. Watching Control Center depends on this and not on
    /// `mayHide`, so the watch is already in place when the answer turns yes.
    private var isSwitchedOn: Bool {
        guard #available(macOS 26, *) else { return false }
        return UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private var isEnabled: Bool { isSwitchedOn && mayHide() }

    private func now() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    func start() {
        attach()
        guard launchToken == nil else { return }
        // Control Center restarts (crash, logout helpers); follow it.
        launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.controlCenterID else { return }
            MainActor.assumeIsolated { self?.attach() }
        }
        quitToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.putEverythingBack() }
        }
    }

    func stop() {
        putEverythingBack()
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
        }
        observer = nil
        observedPID = 0
        created.removeAll()
        if let launchToken { NSWorkspace.shared.notificationCenter.removeObserver(launchToken) }
        if let quitToken { NotificationCenter.default.removeObserver(quitToken) }
        launchToken = nil
        quitToken = nil
    }

    /// A device was just heard connecting, or sound just moved: the banner is
    /// on its way or already up.
    ///
    /// Windows created in the last moment are looked at now. Ones created in
    /// the next few seconds are looked at as they appear.
    func deviceHeard(lookBack: TimeInterval = SystemBannerHider.lookBack) {
        guard isEnabled else { return }
        attach()
        let moment = now()
        heardAt = moment
        forgetOld(moment)
        for entry in created where Self.isDue(created: entry.at, heard: moment, lookBack: lookBack) {
            look(at: entry.window, reason: "device heard")
        }
    }

    private func attach() {
        guard isSwitchedOn, AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(
                  withBundleIdentifier: Self.controlCenterID).first
        else { return }
        let pid = app.processIdentifier
        guard pid != observedPID || observer == nil else { return }
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
            observer = nil
        }
        // A new Control Center has none of the old one's windows.
        created.removeAll()
        away.removeAll()

        var made: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let hider = Unmanaged<SystemBannerHider>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { hider.windowCreated(element) }
        }
        guard AXObserverCreate(pid, callback, &made) == .success, let made else {
            Self.log.notice("could not observe Control Center")
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Created only. Moves and resizes arrive many times a second while a
        // menu is open. None of them is a banner turning up.
        AXObserverAddNotification(made, appElement, kAXWindowCreatedNotification as CFString, refcon)
        // Common modes: in the default mode alone, a drag or an open menu in
        // Ledge held the callback back until it ended.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .commonModes)
        observer = made
        observedPID = pid
        Self.log.notice("watching Control Center (pid \(pid, privacy: .public)) for the device banner")
    }

    private func windowCreated(_ window: AXUIElement) {
        let moment = now()
        forgetOld(moment)
        created.append((window, moment))
        // Created after the device was heard, so only the time ahead counts.
        guard isEnabled, Self.isDue(created: moment, heard: heardAt, lookBack: 0) else { return }
        look(at: window, reason: "window created")
    }

    /// Windows older than any device could still claim are let go.
    private func forgetOld(_ moment: TimeInterval) {
        created.removeAll { moment - $0.at > Self.lookBack + Self.lookAhead }
    }

    /// Looks at a window now and a few more times: it is not always its final
    /// size in the instant it is created.
    private func look(at window: AXUIElement, reason: String) {
        for delay in [0.0, 0.08, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.hideIfBanner(window, reason: reason)
            }
        }
    }

    /// Moves the window away if it is the banner. True when it was.
    @discardableResult
    private func hideIfBanner(_ element: AXUIElement, reason: String) -> Bool {
        guard isEnabled else { return false }
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        guard let subrole = Self.string(element, kAXSubroleAttribute), subrole == "AXSystemDialog",
              let frame = Self.frame(element),
              Self.looksLikeBanner(frame, screenWidth: NSScreen.screens.first?.frame.width ?? 0)
        else { return false }
        var out = CGPoint(x: -4000, y: -4000)
        guard let point = AXValueCreate(.cgPoint, &out) else { return false }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, point)
        Self.log.notice("""
            device banner \(result == .success ? "moved away" : "could not be moved", privacy: .public) \
            (\(reason, privacy: .public), \(Int(frame.width), privacy: .public)×\(Int(frame.height), privacy: .public))
            """)
        guard result == .success else { return false }
        away.append((element, frame.origin))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.awayFor) { [weak self] in
            self?.putBack(element)
        }
        return true
    }

    /// Puts a moved window back where it was. By now the banner has gone, so
    /// this shows nothing. It matters only if Control Center keeps the window
    /// for its next card, which would otherwise turn up out of sight.
    private func putBack(_ window: AXUIElement) {
        guard let index = away.firstIndex(where: { CFEqual($0.window, window) }) else { return }
        var origin = away.remove(at: index).origin
        guard let point = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, point)
    }

    private func putEverythingBack() {
        for entry in away { putBack(entry.window) }
    }

    /// Banner-sized, on screen at the top edge and on the right half, which
    /// is where macOS puts it. A window already moved away is not on screen,
    /// so it is not chased again.
    nonisolated static func looksLikeBanner(_ frame: CGRect, screenWidth: CGFloat) -> Bool {
        (250...460).contains(frame.width)
            && (90...200).contains(frame.height)
            && frame.minY >= 0 && frame.minY < 60
            && frame.minX >= 0
            && frame.midX > screenWidth / 2
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        // swiftlint:enable force_cast
        return CGRect(origin: origin, size: extent)
    }
}
