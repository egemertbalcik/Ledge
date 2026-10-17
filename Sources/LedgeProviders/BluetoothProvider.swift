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
    /// Where the paired list is published.
    ///
    /// This provider is the only thing that reads that list, and two others
    /// need the answer: the catalogue, to know whose devices it is keeping,
    /// and the proximity provider, to know whose earbuds it is hearing. It is
    /// filled from the reads already being made — the startup inventory and
    /// the ten-minute refresh — so ownership costs no extra query, no extra
    /// process and no extra scan.
    private let paired: PairedDeviceRegistry
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
        paired: PairedDeviceRegistry = PairedDeviceRegistry(),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.observations = observations
        self.paired = paired
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
                let reading = await self.source.pairedDevices()
                // The read outlived the provider, or a newer run replaced it.
                guard !Task.isCancelled, self.session == session else { return }
                // Nothing answered — a profiler that timed out, or a Mac that
                // would not say. Publishing an empty list here would tell the
                // catalogue this Mac is paired with nothing, and it prunes
                // against that: one slow process used to delete every record
                // and its battery history.
                guard let all = reading else {
                    Self.log.notice("paired list unavailable — keeping the last answer")
                    return
                }
                // Published before anything is reported: the catalogue refuses
                // devices it cannot place, so the answer has to be in hand
                // before the observations that depend on it arrive.
                let acceptance = self.answerPairedList(all.devices, readAt: all.readAt)
                // A reading older than the one already in hand is not acted
                // on at all. Its battery levels are exactly as old as its
                // membership, and reporting them stamped with now overwrote
                // newer readings with stale ones.
                guard acceptance.wasAccepted else {
                    Self.log.notice("paired list older than the one in hand — ignored")
                    return
                }
                let already = Self.stillConnected(in: all.devices, by: acceptance.answer)
                // Reported whether or not they are new to this provider: a
                // device connected before Ledge started produced no connect
                // event, so the catalogue would not have heard of it until the
                // ten-minute refresh came round.
                for device in already { self.report(device, cause: .startupInventory, at: all.readAt) }
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
        // Told at once, before anything else here decides whether this is
        // news. The paired list is read at startup and every ten minutes, so
        // anything asking it "is this connected now" — the proximity card
        // does — was answering from a reading up to ten minutes old.
        paired.connectionChanged(
            address: device.address,
            isConnected: true,
            at: Date(timeIntervalSinceReferenceDate: now())
        )
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
        // Before the grace period below, and whether or not this provider
        // ever published a card for it: the fact is the fact.
        paired.connectionChanged(
            address: address,
            isConnected: false,
            at: Date(timeIntervalSinceReferenceDate: now())
        )
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
                    let reading = await self.source.pairedDevices()
                    // Same race as the startup read: a slow profiler query can
                    // return after the provider stopped.
                    guard !Task.isCancelled, self.session == session else { return }
                    // And the same refusal to invent an answer: see the
                    // startup read.
                    guard let all = reading else {
                        Self.log.notice("paired list unavailable — keeping the last answer")
                        return
                    }
                    // Re-answered on every refresh, not only at launch: a
                    // device paired or unpaired since is news, and a record
                    // still claiming to be connected is corrected against this
                    // reading.
                    let acceptance = self.answerPairedList(all.devices, readAt: all.readAt)
                    // As at startup: an older reading is not acted on.
                    guard acceptance.wasAccepted else {
                        Self.log.notice("paired list older than the one in hand — ignored")
                        return
                    }
                    for device in Self.stillConnected(in: all.devices, by: acceptance.answer) {
                        self.report(device, cause: .periodicRefresh, at: all.readAt)
                    }
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
    /// - Parameter at: when this was seen. Defaults to now, which is right
    ///   for a connect or a disconnect — they *are* now. A reading of the
    ///   paired list is not: it was taken when the read ran, and stamping its
    ///   battery levels with the moment they arrived made a slow read look
    ///   like the freshest thing the catalogue had.
    private func report(
        _ device: BluetoothDeviceSnapshot,
        cause: ObservationCause,
        at: Date? = nil
    ) {
        guard let observations else { return }
        let observation = DeviceObservations.fromBluetooth(
            device,
            at: at ?? Date(timeIntervalSinceReferenceDate: now()),
            cause: cause
        )
        // Synchronous: no task per advertisement, per connect or per reading.
        observations.submit(observation)
    }


    /// Publishes a complete reading of the paired list.
    ///
    /// Complete is the point. Anything partial — the connected subset, say —
    /// would read as "the Mac is not paired with the rest", and the catalogue
    /// prunes against this answer.
    /// - Parameter readAt: when the read began. Stamped from there rather
    ///   than from here, because `system_profiler` takes seconds to answer
    ///   and what it says is true of when it ran: a connect that happened
    ///   while it was running is newer than the list it hands back.
    @discardableResult
    private func answerPairedList(
        _ devices: [BluetoothDeviceSnapshot],
        readAt: Date
    ) -> PairedDeviceRegistry.Acceptance {
        paired.answer(devices.map(\.pairedDevice), at: readAt)
    }

    /// The devices this reading says are connected, as the registry sees them
    /// after the reading has been reconciled with everything seen since.
    ///
    /// Not the raw snapshot, in either direction: a device that disconnected
    /// while the read was running is still "connected" in what the read hands
    /// back, and one that connected while it was running is still
    /// "disconnected" in it. Both reach the catalogue as a presence the
    /// system has already contradicted, so the answer decides which devices
    /// are reported *and* what each of them says.
    ///
    /// A device the answer does not hold at all is not reported: the
    /// authoritative list not holding it is itself the answer.
    static func stillConnected(
        in devices: [BluetoothDeviceSnapshot],
        by answer: PairedDeviceRegistry.Answer
    ) -> [BluetoothDeviceSnapshot] {
        devices.compactMap { device in
            guard let known = answer.device(for: device.pairedDevice.identity),
                  known.isConnected
            else { return nil }
            guard !device.isConnected else { return device }
            var repaired = device
            repaired.isConnected = true
            return repaired
        }
    }

    /// Remembered because a disconnect notification carries only an address —
    /// the device is gone by the time it arrives, so its name has to come from
    /// when it connected.
    private var lastKnownName: [String: String] = [:]
    private var lastKnownSymbol: [String: String] = [:]
    private var lastKnownApple: Set<String> = []
}
