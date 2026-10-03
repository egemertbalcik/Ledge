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
    /// Where observations go. The catalogue decides alerts now; this provider
    /// only reports what its existing reads already saw.
    private let observations: (any DeviceObservationSink)?
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    /// Ids currently on screen, keyed by device address, so a disconnect can
    /// retract the card the connect put up.
    private var published: [String: ActivityID] = [:]

    /// Reads of the paired-device list that are still running.
    ///
    /// `system_profiler` takes seconds, so one of these can land well after
    /// the provider has stopped — repopulating its tables and the catalogue
    /// for a provider nobody is listening to. Tracked so `stop()` can cancel
    /// them, and stamped with the session so a result that slips through is
    /// discarded rather than applied.
    private var reads: Set<Task<Void, Never>> = []
    private var session = 0

    public init(
        source: any BluetoothDeviceSource,
        observations: (any DeviceObservationSink)? = nil,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.observations = observations
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
            let session = self.session
            var read: Task<Void, Never>!
            read = Task { @MainActor [weak self] in
                defer { self?.reads.remove(read) }
                guard let self else { return }
                let already = await self.source.connectedDevices()
                // The read outlived the provider, or a newer run replaced it.
                guard !Task.isCancelled, self.session == session else { return }
                // Reported whether or not they are new to this provider: a
                // device connected before Ledge started produced no connect
                // event, so the catalogue would not have heard of it until the
                // ten-minute refresh came round.
                for device in already { self.report(device, cause: .startupInventory) }
                for device in already
                where self.published[device.address] == nil {
                    self.published[device.address] = ActivityID(kind: .device, source: device.address)
                    self.lastKnownName[device.address] = device.name
                    self.lastKnownSymbol[device.address] = device.symbolName
                    if device.isApple { self.lastKnownApple.insert(device.address) }
                }
            }
            self.reads.insert(read)
        }
    }

    public func stop() {
        // Anything in flight belongs to a run that is over.
        session &+= 1
        for read in reads { read.cancel() }
        reads.removeAll()
        source.stopWatching()
        lowBatteryTimer?.cancel()
        lowBatteryTimer = nil
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
            report(device, cause: .periodicRefresh)
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
        report(device, cause: .connectionEvent)

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
        // An observed detach, reported as the event it is. The catalogue keeps
        // the last known levels; their age is what marks them old.
        if let observations {
            let observation = DeviceObservations.disconnected(
                address: address,
                name: lastKnownName[address] ?? "Device",
                symbolName: lastKnownSymbol[address] ?? "headphones",
                isApple: lastKnownApple.contains(address),
                at: Date(timeIntervalSinceReferenceDate: now())
            )
            // Synchronous: no task per advertisement, per connect or per reading.
        observations.submit(observation)
        }

        // The once-per-dip latch used to be reset here. It now lives with
        // the engine, keyed by component and persisted, so a departure is no
        // longer the thing that rearms it — a recovery above the threshold
        // is, which is the question actually being asked.
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

    private var lowBatteryTimer: DispatchSourceTimer?

    private func startLowBatteryChecks() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.lowBatteryCheckInterval,
            repeating: Self.lowBatteryCheckInterval,
            leeway: .seconds(60)
        )
        let session = self.session
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session == session else { return }
                var read: Task<Void, Never>!
                read = Task { @MainActor [weak self] in
                    defer { self?.reads.remove(read) }
                    guard let self else { return }
                    let devices = await self.source.connectedDevices()
                    // Same race as the startup read: a slow profiler query can
                    // return after the provider stopped.
                    guard !Task.isCancelled, self.session == session else { return }
                    for device in devices { self.report(device, cause: .periodicRefresh) }
                }
                self.reads.insert(read)
            }
        }
        timer.resume()
        lowBatteryTimer = timer
    }

    /// Reports what this read already saw, and lets the catalogue decide.
    ///
    /// This provider used to evaluate the low-battery rule itself, with its
    /// own threshold, its own rearm and its own latch keyed by address. That
    /// decision now lives in `BatteryAlertEngine` behind the catalogue, so
    /// there is exactly one place that decides and one that delivers — the
    /// old pair would have announced the same dip twice the moment both were
    /// live.
    ///
    /// The ten-minute refresh below is *kept*: it is how levels are obtained
    /// at all, not part of the alerting. Only the duplicate decision went.
    /// - Parameter cause: what prompted this sighting. Only a connect
    ///   callback may read as the device attaching; the startup inventory and
    ///   the ten-minute refresh are a baseline, and a low device in that
    ///   baseline must not alert as though it had just been plugged in.
    private func report(_ device: BluetoothDeviceSnapshot, cause: ObservationCause) {
        guard let observations else { return }
        let observation = DeviceObservations.fromBluetooth(
            device, at: Date(timeIntervalSinceReferenceDate: now()), cause: cause
        )
        // Synchronous: no task per advertisement, per connect or per reading.
        observations.submit(observation)
    }


    /// Remembered because a disconnect notification carries only an address —
    /// the device is gone by the time it arrives, so its name has to come from
    /// when it connected.
    private var lastKnownName: [String: String] = [:]
    private var lastKnownSymbol: [String: String] = [:]
    private var lastKnownApple: Set<String> = []
}
