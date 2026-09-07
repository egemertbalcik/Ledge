import Foundation
import LedgeCore
import LedgeSystem
import os

/// Turns Bluetooth connections into activities.
///
/// Same rule as battery: **publish transitions, not state.** A card per
/// connected device, standing permanently, would bury everything else. A device
/// connecting or disconnecting is news; a device merely being connected is not.
@MainActor
public final class BluetoothProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "bluetooth")

    public let identifier = "bluetooth"

    /// How long a connect or disconnect card stays up.
    static let lifetime: TimeInterval = 4

    /// Below this, a device's battery deserves a word before it dies mid-use.
    static let lowBatteryThreshold: Double = 0.2
    /// Re-arm above this, so a level hovering at the threshold does not nag.
    static let lowBatteryRearm: Double = 0.25
    /// How often connected devices are re-asked for their levels. Battery
    /// data otherwise only arrives at connect time, and AirPods die hours
    /// later.
    static let lowBatteryCheckInterval: TimeInterval = 10 * 60

    /// How long a disconnect is held before it is announced.
    ///
    /// AirPods drop the baseband link whenever they go idle and re-open it on
    /// use, so IOBluetooth reports a connect/disconnect pair for every route
    /// change and case-open. Announcing each one made the card appear
    /// constantly. A disconnect only becomes news if nothing reconnects within
    /// this grace; a reconnect inside it cancels both announcements — the
    /// device never really left.
    static let flapGrace: TimeInterval = 8

    private let source: any BluetoothDeviceSource
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    /// Ids currently on screen, keyed by device address, so a disconnect can
    /// retract the card the connect put up.
    private var published: [String: ActivityID] = [:]

    public init(
        source: any BluetoothDeviceSource,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            self.source.startWatching(
                onConnect: { [weak self] device in self?.connected(device) },
                onDisconnect: { [weak self] address in self?.disconnected(address) }
            )
            self.startLowBatteryChecks()
            // Devices already connected when the provider starts (a login item
            // launching with the AirPods in) never produced a connect event,
            // so their first disconnect found nothing published and said no
            // goodbye. Seed the tables quietly — no hello card, they were
            // there all along — so the departure is announced like any other.
            Task { @MainActor [weak self] in
                guard let self else { return }
                for device in await self.source.connectedDevices()
                where self.published[device.address] == nil {
                    self.published[device.address] = ActivityID(kind: .device, source: device.address)
                    self.lastKnownName[device.address] = device.name
                    self.lastKnownSymbol[device.address] = device.symbolName
                    if device.isApple { self.lastKnownApple.insert(device.address) }
                }
            }
        }
    }

    public func stop() {
        source.stopWatching()
        lowBatteryTimer?.cancel()
        lowBatteryTimer = nil
        lowAnnounced.removeAll()
        for item in pendingGoodbyes.values { item.cancel() }
        pendingGoodbyes.removeAll()
        continuation?.finish()
        continuation = nil
        published.removeAll()
        // The remembered-device tables are state too. Left behind, a restarted
        // provider could announce a goodbye card for a device it never saw
        // connect during this run.
        lastKnownName.removeAll()
        lastKnownSymbol.removeAll()
        lastKnownApple.removeAll()
    }

    /// Goodbyes waiting out the flap grace, keyed by address.
    private var pendingGoodbyes: [String: DispatchWorkItem] = [:]

    private func connected(_ device: BluetoothDeviceSnapshot) {
        if let held = pendingGoodbyes.removeValue(forKey: device.address) {
            held.cancel()
            // A reconnect inside the grace is link churn, not news. Refresh the
            // remembered identity and stay quiet — but re-record the device as
            // published, or the *next* real disconnect would find no entry and
            // never announce its goodbye. Battery still gets checked: a level
            // that crossed the threshold during the flap should not wait for
            // the ten-minute sweep.
            published[device.address] = ActivityID(kind: .device, source: device.address)
            lastKnownName[device.address] = device.name
            lastKnownSymbol[device.address] = device.symbolName
            if device.isApple { lastKnownApple.insert(device.address) }
            checkLowBattery(device)
            Self.log.debug("suppressed flap for \(device.name, privacy: .private(mask: .hash))")
            return
        }
        // The address is the identity, not the name: two sets of the same
        // model of earbuds would otherwise collide into one card.
        let id = ActivityID(kind: .device, source: device.address)
        published[device.address] = id
        lastKnownName[device.address] = device.name
        lastKnownSymbol[device.address] = device.symbolName
        // Remembered too, so a goodbye card keeps the same icon treatment the
        // hello card had rather than flipping colour on the way out.
        if device.isApple { lastKnownApple.insert(device.address) }

        Self.log.debug("""
            connected \(device.name, privacy: .private(mask: .hash)) \
            levels=\(device.batteryLevels.count, privacy: .public)
            """)
        checkLowBattery(device)

        continuation?.yield(.publish(Activity(
            id: id,
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .device(DevicePayload(
                name: device.name,
                symbolName: device.symbolName,
                // Absent battery data is normal, not a failure — the levels are
                // transient and vanish once a device goes idle. The card renders
                // fine without them.
                batteryLevels: device.batteryLevels,
                isConnected: true,
                isApple: device.isApple
            ))
        )))
    }

    private func disconnected(_ address: String) {
        guard let id = published.removeValue(forKey: address) else { return }
        // Retract the "connected" card rather than leaving it to expire; the
        // goodbye itself waits out the flap grace.
        continuation?.yield(.retract(id))

        pendingGoodbyes[address]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingGoodbyes.removeValue(forKey: address)
                self.announceGoodbye(address)
            }
        }
        pendingGoodbyes[address] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flapGrace, execute: item)
    }

    private func announceGoodbye(_ address: String) {
        // The once-per-dip latch resets on a *real* departure, not on the raw
        // disconnect: low AirPods drop their link every time they go idle —
        // the very flaps the grace hides — and clearing the latch there
        // re-announced "low battery" on every reconnect.
        lowAnnounced.remove(address)
        let goodbye = ActivityID(kind: .device, source: address)
        // The entry has served its purpose once the goodbye is out; leaving
        // it made the map grow per paired device forever and let a spurious
        // late disconnect announce a phantom second goodbye.
        published.removeValue(forKey: address)
        continuation?.yield(.publish(Activity(
            id: goodbye,
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .device(DevicePayload(
                name: lastKnownName[address] ?? "Device",
                symbolName: lastKnownSymbol[address] ?? "headphones",
                batteryLevels: [:],
                isConnected: false,
                isApple: lastKnownApple.contains(address)
            ))
        )))
    }

    /// Devices already warned about, so a level sitting under the threshold
    /// announces once, not every check. Cleared when the level recovers or
    /// the device disconnects.
    private var lowAnnounced: Set<String> = []
    private var lowBatteryTimer: DispatchSourceTimer?

    private func startLowBatteryChecks() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.lowBatteryCheckInterval,
            repeating: Self.lowBatteryCheckInterval,
            leeway: .seconds(60)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                for device in await self.source.connectedDevices() {
                    self.checkLowBattery(device)
                }
            }
        }
        timer.resume()
        lowBatteryTimer = timer
    }

    /// Announces a device crossing the low threshold — once per dip.
    ///
    /// The case is left out: the alert is for a device that dies mid-use,
    /// and a case at 15% with the buds at 90% is not that — yet it used to
    /// raise "low battery" on every connect and every ten-minute sweep.
    private func checkLowBattery(_ device: BluetoothDeviceSnapshot) {
        let inUse = device.batteryLevels.filter { $0.key.caseInsensitiveCompare("Case") != .orderedSame }
        guard let lowest = inUse.values.min() else { return }
        if lowest > Self.lowBatteryRearm {
            lowAnnounced.remove(device.address)
            return
        }
        guard lowest <= Self.lowBatteryThreshold,
              !lowAnnounced.contains(device.address)
        else { return }
        lowAnnounced.insert(device.address)

        continuation?.yield(.publish(Activity(
            id: ActivityID(kind: .device, source: device.address + "/low"),
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .device(DevicePayload(
                name: device.name,
                symbolName: device.symbolName,
                batteryLevels: device.batteryLevels,
                isConnected: true,
                isApple: device.isApple
            ))
        )))
    }

    /// Remembered because a disconnect notification carries only an address —
    /// the device is gone by the time it arrives, so its name has to come from
    /// when it connected.
    private var lastKnownName: [String: String] = [:]
    private var lastKnownSymbol: [String: String] = [:]
    private var lastKnownApple: Set<String> = []
}
