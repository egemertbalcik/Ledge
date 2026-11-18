import Foundation

/// Which Bluetooth devices connected a moment ago, by name.
///
/// A device that connects also becomes the sound output, and both providers
/// would tell it. The Bluetooth hello is the news (it waits for the battery
/// and says "Connected"); the route card for the same name stays quiet for a
/// few seconds after it, rather than racing it to the notch.
@MainActor
enum RecentConnections {

    private static var connectedAt: [String: TimeInterval] = [:]

    static func noteConnected(_ name: String, at moment: TimeInterval) {
        connectedAt[key(name)] = moment
    }

    static func connectedRecently(_ name: String, now: TimeInterval, within window: TimeInterval = 4) -> Bool {
        guard let at = connectedAt[key(name)] else { return false }
        return now - at >= 0 && now - at < window
    }

    /// Case, surrounding space and macOS's curly apostrophe do not make a
    /// different device.
    nonisolated static func key(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }
}
