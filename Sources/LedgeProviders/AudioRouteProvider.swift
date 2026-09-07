import Foundation
import LedgeCore
import LedgeSystem

/// Says where sound has just started going.
///
/// Plugging in headphones, joining a call, waking at a desk with a monitor
/// attached — each moves the output, and macOS says nothing. The answer lives
/// in Control Centre, behind a click, at the moment you are least likely to
/// look. A glance in the notch is the whole feature.
///
/// It borrows the device card rather than inventing a payload: name, glyph,
/// and — with no battery to report — nothing else, which is exactly the shape
/// this needs. Its own source id keeps it clear of the Bluetooth cards that
/// use the same kind, so a route change never replaces a connection.
@MainActor
public final class AudioRouteProvider: ActivityProvider {

    public let identifier = "audioroute"

    /// Long enough to read a device name, short enough to be a glance. The
    /// same beat as an AirPods connection, which this often accompanies.
    static let lifetime: TimeInterval = 2.4

    public static let activityID = ActivityID(kind: .device, source: "audioroute")

    private let source: any AudioRouteWatching
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    public init(
        source: any AudioRouteWatching = AudioRouteSource(),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            self.source.startWatching { [weak self] name in
                self?.announce(name)
            }
        }
    }

    public func stop() {
        source.stopWatching()
        continuation?.finish()
        continuation = nil
    }

    private func announce(_ name: String) {
        continuation?.yield(.publish(Activity(
            id: Self.activityID,
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .device(DevicePayload(
                name: name,
                symbolName: AudioDeviceSymbol.forName(name),
                // No battery: this is about where sound goes, and standing a
                // ring here would imply a reading the route change does not
                // have. The Bluetooth card carries the battery when there is
                // one to carry.
                batteryLevels: [:],
                isApple: Self.readsAsApple(name),
                // The far ear names the destination. A speaker glyph alone
                // says sound moved without saying where, which is the half of
                // the message nobody needed.
                statusText: Self.shortName(name)
            ))
        )))
    }

    /// A device name trimmed to something an ear can hold. "MacBook Pro
    /// Speakers" is the full truth and three times too long; the first word
    /// or two is what anyone reads anyway.
    static func shortName(_ name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("airpods max") { return "AirPods Max" }
        if lowered.contains("airpods pro") { return "AirPods Pro" }
        if lowered.contains("airpods") { return "AirPods" }
        if lowered.contains("macbook") || lowered.contains("built-in") { return "Speakers" }
        let words = name.split(separator: " ")
        return words.count <= 2 ? name : words.prefix(2).joined(separator: " ")
    }

    /// Apple's own gear keeps its tinted glyph, matching the device cards.
    static func readsAsApple(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("airpods") || lowered.contains("beats")
            || lowered.contains("homepod") || lowered.contains("macbook")
            || lowered.contains("studio display") || lowered.contains("imac")
    }
}
