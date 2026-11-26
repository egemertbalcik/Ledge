import Foundation
import LedgeCore

/// Which Bluetooth devices connected a moment ago, by name.
///
/// A device that connects also becomes the sound output, and both providers
/// would tell it. The Bluetooth hello is the news (it waits for the battery
/// and says "Connected"); the route card for the same name stays quiet for a
/// few seconds after it, rather than racing it to the notch.
///
/// It stays quiet once. The memory is used up by the route it silences and
/// cleared by sound going anywhere else, so a deliberate switch away and
/// back inside those seconds is still told.
@MainActor
final class RecentConnections {

    /// The one the app's providers share. A test makes its own.
    static let shared = RecentConnections()

    private var connectedAt: [String: TimeInterval] = [:]

    func noteConnected(_ name: String, at moment: TimeInterval) {
        connectedAt[Self.key(name)] = moment
    }

    func connectedRecently(_ name: String, now: TimeInterval, within window: TimeInterval = 4) -> Bool {
        guard let at = connectedAt[Self.key(name)] else { return false }
        return now - at >= 0 && now - at < window
    }

    /// The route this connection brought with it has been heard and kept
    /// quiet. The next route to the same device is the user's doing.
    func forget(_ name: String) {
        connectedAt[Self.key(name)] = nil
    }

    /// Sound has gone somewhere. Whatever comes after it is a change in its
    /// own right, not the echo of an earlier connection.
    func forgetAll() {
        connectedAt.removeAll()
    }

    nonisolated static func key(_ name: String) -> String {
        DeviceNameKey.of(name)
    }
}
