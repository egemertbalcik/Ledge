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
    /// Which devices have just said hello. Shared with the Bluetooth
    /// provider in the app; a test gives each provider its own.
    var recentConnections = RecentConnections.shared
    /// Runs its argument once the deadline has passed. The real one is a
    /// timer of `lookupDeadline`; a test hands in its own and decides when
    /// the deadline falls, so nothing there depends on how fast the machine
    /// happens to be.
    private let afterDeadline: @MainActor (@escaping @MainActor () -> Void) -> Void
    /// Which route change is being worked on. Every change takes a new
    /// number and so does telling one, so a read or a deadline that belongs
    /// to an older change finds the number moved on and does nothing.
    private var generation = 0
    /// The Bluetooth device behind the current change that had no levels
    /// when it was read, kept for the deadline.
    private var withoutLevels: BluetoothDeviceSnapshot?

    public init(
        source: any AudioRouteWatching = AudioRouteSource(),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        bluetoothDevice: (@MainActor (String) async -> BluetoothDeviceSnapshot?)? = nil,
        afterDeadline: (@MainActor (@escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        self.source = source
        self.now = now
        self.afterDeadline = afterDeadline ?? { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookupDeadline) {
                MainActor.assumeIsolated { work() }
            }
        }
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
        let named = devices.filter { RecentConnections.key($0.name) == wanted }
        // Two connected devices with one name: nothing says which of them
        // sound went to. A bare card is right; the other one's battery
        // under this one's name would be wrong.
        return named.count == 1 ? named.first : nil
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
        generation += 1
        withoutLevels = nil
        lookup?.cancel()
        lookup = nil
        source.stopWatching()
        continuation?.finish()
        continuation = nil
    }

    private func announce(_ name: String) {
        let heardAt = now()
        NotificationCenter.default.post(name: .ledgeSoundOutputHeard, object: nil)
        // Read the matching Bluetooth device first, so the card goes out once
        // and complete instead of bare and then again with rings (~150 ms).
        // Earbuds that stayed connected — out of the case, into the ear — have
        // their levels already. A device that has just connected is told by
        // its Bluetooth hello, so this card stays quiet for it. A route with
        // no Bluetooth device behind it (speakers, a wire) goes out bare; a
        // read that hangs does too, after the deadline.
        generation += 1
        let change = generation
        withoutLevels = nil
        lookup?.cancel()
        lookup = Task { @MainActor [weak self] in
            guard let self else { return }
            let device = await self.bluetoothDevice(name)
            // A newer change has taken over, or the deadline already told this one.
            guard !Task.isCancelled, change == self.generation else { return }
            if let device, device.batteryLevels.isEmpty,
               !self.recentConnections.connectedRecently(name, now: self.now()) {
                // No levels and no hello heard: either it is connecting this
                // instant and its hello is a moment away, or it is a speaker
                // that never reports a battery. The deadline tells them
                // apart. Staying quiet here for good left a switch to a
                // connected speaker with no card at all.
                self.withoutLevels = device
                return
            }
            self.tell(name, heardAt: heardAt, change: change, device: device)
        }
        afterDeadline { [weak self] in
            guard let self else { return }
            self.tell(name, heardAt: heardAt, change: change, device: self.withoutLevels)
        }
    }

    /// Longest a route card waits for the Bluetooth read, or for the hello of
    /// a device that had no levels, before going out with what it has.
    static let lookupDeadline: TimeInterval = 0.6

    /// Tells a route change once, unless a newer one has replaced it.
    ///
    /// The check on `change` is what keeps two quick switches honest: the
    /// first one's deadline used to fire regardless. It published the old
    /// output after the new one and cancelled the newer read on its way.
    private func tell(_ name: String, heardAt: TimeInterval, change: Int, device: BluetoothDeviceSnapshot?) {
        guard change == generation else { return }
        generation += 1
        withoutLevels = nil
        lookup?.cancel()
        lookup = nil
        // The device's own hello is the news. It carries the battery too.
        // Quiet for it once: the next route to the same device is a choice
        // somebody made and gets its card.
        if recentConnections.connectedRecently(name, now: now()) {
            recentConnections.forget(name)
            return
        }
        // Sound has gone somewhere. A route back to a device that connected
        // a moment ago is no longer that connection's echo.
        recentConnections.forgetAll()
        publish(name, at: heardAt, device: device)
    }

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
