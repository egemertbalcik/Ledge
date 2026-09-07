import Foundation
import Intents
import LedgeCore
import os

/// Whether *a* Focus is on, straight from the system.
///
/// The Focus database under `~/Library/DoNotDisturb` carries the mode's name
/// and symbol, but it sits behind Full Disk Access — a permission macOS refuses
/// to prompt for, so most people never grant it and the Focus card simply never
/// appeared. `INFocusStatusCenter` answers the smaller question — on or off —
/// behind an ordinary, promptable permission. So the card works for everyone,
/// and Full Disk Access becomes an upgrade that adds the name rather than the
/// price of admission.
///
/// Two things are load-bearing:
///
/// - **Unauthorized reads lie.** `focusStatus.isFocused` answers `false`, not
///   nil, before the grant exists — so every read is gated on the authorization
///   status rather than trusting the value.
/// - **The read is expensive.** Measured at ~21 ms: it is an XPC round trip to
///   the Focus daemon, not a cached flag. It must never sit on a poll fast
///   enough to be felt, and never on the main thread.
public final class FocusStatusReader: Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "focus")

    public enum Authorization: Sendable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    public init() {}

    public var authorization: Authorization {
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    public var isAuthorized: Bool { authorization == .authorized }

    /// Whether a Focus is on right now, or nil when we are not allowed to know.
    ///
    /// Blocking and slow by nature — call it from a background task, on an
    /// event, never in a loop.
    public func isFocused() -> Bool? {
        guard isAuthorized else { return nil }
        return INFocusStatusCenter.default.focusStatus.isFocused
    }

    /// Shows the system prompt. Only ever called from an explicit user action.
    @discardableResult
    public func requestAuthorization() async -> Authorization {
        guard authorization == .notDetermined else { return authorization }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            INFocusStatusCenter.default.requestAuthorization { _ in
                continuation.resume()
            }
        }
        let result = authorization
        Self.log.notice("focus status authorization: \(String(describing: result), privacy: .public)")
        return result
    }
}
