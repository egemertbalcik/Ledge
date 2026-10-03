import Foundation
import LedgeCore
import UserNotifications
import os

/// Shows a macOS notification for a battery alert.
///
/// **Never asks for permission on its own.** Authorisation is requested only
/// when the user explicitly chooses notification delivery, or previews it —
/// opening the Devices pane, or receiving an alert whose rule is notch-only,
/// must not produce a system prompt.
public protocol AlertNotifying: Sendable {
    /// Asks for authorisation. Called from the one place the user opted in.
    func requestAuthorization() async -> Bool
    /// Whether the user has already been asked, and said yes.
    func isAuthorized() async -> Bool
    /// Shows one. A no-op when not authorised — a denied prompt must not
    /// become a second prompt on every alert.
    func deliver(title: String, body: String) async
}

public struct SystemAlertNotifier: AlertNotifying {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "devices")

    public init() {}

    public func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            Self.log.notice("notification authorisation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    public func deliver(title: String, body: String) async {
        guard await isAuthorized() else {
            // Deliberately silent. The user either has not opted in or has
            // said no, and an alert is not a reason to ask again.
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// The words an alert is shown with, in one place so the notch and a
/// notification cannot drift apart.
public enum AlertWording {

    public static func title(_ alert: BatteryAlert) -> String {
        switch alert.kind {
        case .low: "\(alert.deviceName) battery low"
        case .charged: "\(alert.deviceName) charged"
        }
    }

    public static func body(_ alert: BatteryAlert) -> String {
        let percent = Int((alert.level * 100).rounded())
        switch alert.component {
        case .main:
            return "\(percent)%"
        default:
            return "\(alert.component.label) at \(percent)%"
        }
    }
}
