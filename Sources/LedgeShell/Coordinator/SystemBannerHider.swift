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
/// Accessibility grant Ledge already holds for the media keys.
///
/// The window is recognised by shape alone — a Control Center system dialog,
/// banner-sized, touching the top edge — so the rule is deliberately narrow.
/// `systemBanner.hideDevice` set to false turns it off.
@MainActor
final class SystemBannerHider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "system-banner")
    private static let controlCenterID = "com.apple.controlcenter"
    private static let enabledKey = "systemBanner.hideDevice"

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var launchToken: NSObjectProtocol?

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

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
    }

    /// A device just came or went: the banner is on its way or already up.
    /// The window notification is the fast path; this is the backstop for a
    /// window Control Center reuses rather than creates.
    func sweepSoon() {
        guard isEnabled else { return }
        attach()
        for delay in [0.0, 0.08, 0.2, 0.45, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sweep(reason: "device event")
            }
        }
    }

    private func attach() {
        guard isEnabled, AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(
                  withBundleIdentifier: Self.controlCenterID).first
        else { return }
        let pid = app.processIdentifier
        guard pid != observedPID || observer == nil else { return }
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
            observer = nil
        }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let hider = Unmanaged<SystemBannerHider>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                if !hider.hideIfBanner(element, reason: "window created") {
                    hider.sweep(reason: "window created")
                }
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else {
            Self.log.notice("could not observe Control Center")
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(created, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedPID = pid
        Self.log.notice("watching Control Center (pid \(pid, privacy: .public)) for the device banner")
    }

    private func sweep(reason: String) {
        guard isEnabled, observedPID != 0 else { return }
        let appElement = AXUIElementCreateApplication(observedPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return }
        for window in windows { _ = hideIfBanner(window, reason: reason) }
    }

    /// Moves the window away if it is the banner. True when it was.
    @discardableResult
    private func hideIfBanner(_ element: AXUIElement, reason: String) -> Bool {
        guard isEnabled,
              let subrole = Self.string(element, kAXSubroleAttribute), subrole == "AXSystemDialog",
              let frame = Self.frame(element),
              Self.looksLikeBanner(frame)
        else { return false }
        var away = CGPoint(x: -4000, y: -4000)
        guard let point = AXValueCreate(.cgPoint, &away) else { return false }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, point)
        Self.log.notice("""
            device banner \(result == .success ? "moved away" : "could not be moved", privacy: .public) \
            (\(reason, privacy: .public), \(Int(frame.width), privacy: .public)×\(Int(frame.height), privacy: .public))
            """)
        return result == .success
    }

    /// Banner-sized and on screen at the top edge. Already moved away is not
    /// on screen, so a window sent off is not chased again.
    nonisolated static func looksLikeBanner(_ frame: CGRect) -> Bool {
        (250...460).contains(frame.width)
            && (90...200).contains(frame.height)
            && frame.minY >= 0 && frame.minY < 60
            && frame.minX >= 0
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
