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
    /// The connected Bluetooth device that goes by a route's name, if any —
    /// where the battery comes from when sound moves to earbuds that never
    /// left the Mac (taken out of the case, put back in the ear).
    private let bluetoothDevice: @MainActor (String) async -> BluetoothDeviceSnapshot?
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var lookup: Task<Void, Never>?

    public init(
        source: any AudioRouteWatching = AudioRouteSource(),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        bluetoothDevice: (@MainActor (String) async -> BluetoothDeviceSnapshot?)? = nil
    ) {
        self.source = source
        self.now = now
        if let bluetoothDevice {
            self.bluetoothDevice = bluetoothDevice
        } else {
            let devices = IOBluetoothDeviceSource()
            self.bluetoothDevice = { name in
                await Self.match(name, in: devices.connectedDevices())
            }
        }
    }

    /// The device whose name is the route's, ignoring case and the curly
    /// apostrophe macOS puts in "Someone's AirPods".
    nonisolated static func match(
        _ name: String, in devices: [BluetoothDeviceSnapshot]
    ) -> BluetoothDeviceSnapshot? {
        let wanted = RecentConnections.key(name)
        return devices.first { RecentConnections.key($0.name) == wanted }
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
        lookup?.cancel()
        lookup = nil
        source.stopWatching()
        continuation?.finish()
        continuation = nil
    }

    private func announce(_ name: String) {
        let heardAt = now()
        // Read the matching Bluetooth device first, so the card goes out once
        // and complete instead of bare and then again with rings (~150 ms).
        // Earbuds that stayed connected — out of the case, into the ear — have
        // their levels already. Ones that are connecting this instant have
        // none yet: their Bluetooth hello is the news and waits for the levels
        // itself, so this card stays quiet rather than racing it. A route with
        // no Bluetooth device behind it (speakers, a wire) goes out bare; a
        // read that hangs does too, after `lookupDeadline`.
        lookup?.cancel()
        var settled = false
        let finish: @MainActor (BluetoothDeviceSnapshot?, Bool) -> Void = { [weak self] device, silent in
            guard let self, !settled else { return }
            settled = true
            self.lookup?.cancel()
            if !silent { self.publish(name, at: heardAt, device: device) }
        }
        lookup = Task { @MainActor [weak self] in
            guard let self else { return }
            let device = await self.bluetoothDevice(name)
            guard !Task.isCancelled else { return }
            if RecentConnections.connectedRecently(name, now: self.now()) {
                finish(nil, true)
            } else if let device, device.batteryLevels.isEmpty {
                finish(nil, true)
            } else {
                finish(device, false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookupDeadline) {
            MainActor.assumeIsolated { finish(nil, false) }
        }
    }

    /// Longest a route card waits for the Bluetooth read before going out bare.
    static let lookupDeadline: TimeInterval = 0.6

    private func publish(_ name: String, at createdAt: TimeInterval, device: BluetoothDeviceSnapshot?) {
        continuation?.yield(.publish(Activity(
            id: Self.activityID,
            createdAt: createdAt,
            expiresAfter: Self.lifetime,
            payload: .device(DevicePayload(
                name: name,
                symbolName: device?.symbolName ?? AudioDeviceSymbol.forName(name),
                // Only a connected Bluetooth device of the same name lends its
                // levels; a wired or built-in output has none to show.
                batteryLevels: device?.batteryLevels ?? [:],
                isApple: device?.isApple ?? Self.readsAsApple(name),
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
