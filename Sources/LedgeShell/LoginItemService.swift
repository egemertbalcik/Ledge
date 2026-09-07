import Foundation
import ServiceManagement
import os

/// Launch-at-login, via `SMAppService`.
///
/// Registration fails for a bundle in an unusual location or with a signature
/// macOS will not vouch for, so every call reports back rather than assuming.
@MainActor
public enum LoginItemService {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "loginitem")

    /// `.requiresApproval` counts as enabled.
    ///
    /// A first-time `register()` commonly leaves the service awaiting approval
    /// in System Settings. Treating that as failure made the Settings toggle
    /// snap back and the stored preference get overwritten at every launch,
    /// while the status text alongside it correctly said "waiting for approval".
    public static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Returns whether the requested state was actually reached.
    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            log.notice("launch at login set to \(enabled, privacy: .public)")
            return isEnabled == enabled
        } catch {
            log.error("""
                launch at login \(enabled ? "register" : "unregister", privacy: .public) \
                failed: \(error.localizedDescription, privacy: .public)
                """)
            return false
        }
    }

    /// Why the toggle may be refusing to stick, in words a settings pane can show.
    public static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "Enabled"
        case .notRegistered: "Not enabled"
        case .notFound: "Unavailable — move Ledge to ~/Applications and try again"
        case .requiresApproval: "Waiting for approval in System Settings › General › Login Items"
        @unknown default: "Unknown"
        }
    }
}
