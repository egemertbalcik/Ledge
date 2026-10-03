import Foundation
import LedgeCore
import os

/// The one owner of the device catalogue on disk.
///
/// An actor, so every mutation is serialised through a single place, and so
/// no filesystem work happens on the main actor. Reads hand back values;
/// nothing outside holds a reference to the stored state.
public actor DeviceCatalogueStore {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "devices")

    /// Writes are debounced: a burst of advertisements should cost one write,
    /// not one per advertisement.
    static let writeDebounce: Duration = .seconds(5)

    /// Pruning is maintenance, not something every event pays for.
    static let maintenanceInterval: TimeInterval = 60 * 60

    private let url: URL
    private let now: @Sendable () -> Date

    private var catalogue: DeviceCatalogue
    private var loaded = false
    private var writeTask: Task<Void, Never>?
    private var lastMaintenance: Date?

    /// Alerts decided while nobody was listening. An alert is *either* handed
    /// to the active consumer *or* queued here — never both, which is what an
    /// earlier version did: it appended to this list and also called the
    /// handler, so every delivered alert stayed in memory and was delivered a
    /// second time the next time a provider started.
    private var pendingAlerts: [BatteryAlert] = []

    /// Recently delivered alerts, for the cross-record duplicate guard. Bounded
    /// by the window it is compared against, so it cannot grow.
    private var recentlyDelivered: [BatteryAlert] = []

    /// Who is listening, and under which token. A stopped provider can only
    /// remove its own subscription, so a stop arriving after a newer start
    /// cannot silence the new one.
    private var consumerToken: UUID?
    private var consumer: (@Sendable ([BatteryAlert]) -> Void)?

    /// Installs a consumer and hands over everything queued, in one step.
    ///
    /// Atomic on purpose. Installing and draining separately left a window in
    /// which an alert could be both handed to the new consumer and returned in
    /// the drain — delivered twice.
    /// - Parameter token: the subscriber's own identifier, minted *before*
    ///   registering.
    ///
    ///   The store used to mint it and hand it back, which meant the delivery
    ///   closure had nothing immutable to name itself with — it had to read
    ///   the provider's stored token at rejection time, and by then `stop()`
    ///   had already cleared it. The rejection then arrived anonymous and the
    ///   store could hand the alert straight back to the consumer that had
    ///   just refused it.
    public func subscribeToAlerts(
        token: UUID = UUID(),
        _ handler: @escaping @Sendable ([BatteryAlert]) -> Void
    ) -> (token: UUID, backlog: [BatteryAlert]) {
        consumerToken = token
        consumer = handler
        // Aged here too, not only when another alert arrives. Enabling the
        // provider after an hour of silence used to present whatever had been
        // waiting, however old — nothing had come along to purge it.
        expirePendingAlerts()
        let backlog = pendingAlerts
        pendingAlerts.removeAll()
        return (token, backlog)
    }

    /// Removes a subscription, if it is still the current one.
    ///
    /// - Parameter returning: a backlog the subscriber took but never
    ///   presented — because it had already stopped. Handed back rather than
    ///   lost with it.
    public func unsubscribeFromAlerts(_ token: UUID, returning backlog: [BatteryAlert] = []) {
        let wasCurrent = consumerToken == token
        if wasCurrent {
            consumerToken = nil
            consumer = nil
        }
        // Requeued *after* clearing, so it does not go straight back to the
        // consumer that is going away — and delivered to a newer one if there
        // already is one.
        requeueAlerts(backlog)
    }

    /// - Parameter url: where the catalogue lives. Injected so tests never
    ///   touch the real Application Support directory.
    public init(
        url: URL = DeviceCatalogueStore.defaultURL(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.url = url
        self.now = now
        self.catalogue = DeviceCatalogue()
    }

    /// `~/Library/Application Support/Ledge/devices.json`.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Ledge", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    // MARK: - Loading

    /// Reads the catalogue, once.
    ///
    /// Anything unreadable is quarantined beside itself rather than deleted —
    /// a corrupt file is the only copy of somebody's history, and it costs
    /// nothing to keep in case it can be salvaged. Launch continues on an
    /// empty catalogue either way; there is no failure here that is worth
    /// refusing to start over.
    private func load() {
        guard !loaded else { return }
        loaded = true

        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(DeviceCatalogue.self, from: data)
            guard let migrated = DeviceCatalogue.migrated(decoded) else {
                Self.log.error("""
                    device catalogue is version \(decoded.version, privacy: .public), \
                    newer than this app understands — starting fresh
                    """)
                quarantine(reason: "future-version")
                return
            }
            catalogue = migrated
            // Tidied on the way in, so a catalogue that sat on disk for weeks
            // does not present retired records until something happens to be
            // observed.
            pruneDevices(now: now())
        } catch {
            Self.log.error("device catalogue unreadable: \(error.localizedDescription, privacy: .public)")
            quarantine(reason: "corrupt")
            catalogue = DeviceCatalogue()
        }
    }

    private func quarantine(reason: String) {
        let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("devices-\(reason)-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: target)
        Self.log.notice("quarantined the old catalogue at \(target.lastPathComponent, privacy: .public)")
    }

    public func snapshot() -> DeviceCatalogue {
        load()
        return catalogue
    }

    // MARK: - Observing

    public func record(_ observation: DeviceObservation) async {
        load()
        let at = observation.observedAt
        // A rotating identifier is canonicalised, so one logical device keeps
        // one record — with its history, its latches, its pinning and the
        // user's own rules — across every rotation. Keying on the rotating
        // value meant a fresh default record every few minutes and the old
        // one's configuration orphaned beside it.
        let id = observation.canonicalID

        // Whether this observation *is* the device attaching, rather than a
        // passive sighting or the first reading after launch. Only a genuine
        // attach may alert without a previous level to have crossed.
        let isAttaching: Bool
        var record: DeviceRecord
        if let index = catalogue.index(of: id) {
            record = catalogue.devices[index]
            isAttaching = observation.presence == .connected
                && record.presence != .connected
            // A rename is a rename, not a new device.
            record.name = observation.name
        } else {
            record = DeviceRecord(
                id: id, name: observation.name,
                firstSeen: at, lastSeen: at
            )
            // A device we have never seen, reporting itself connected, has
            // just been attached as far as anything here can tell.
            isAttaching = observation.presence == .connected
        }

        record.lastSeen = at
        record.presence = observation.presence
        // The source is the only thing that knows how the device is drawn.
        record.symbolName = observation.symbolName
        record.isApple = observation.isApple
        if observation.presence == .connected { record.lastConnected = at }
        // An observation carrying no levels — a disconnect, say — must not
        // erase what was last known. The record keeps the old readings and
        // the derived freshness is what says they are old.
        if !observation.readings.isEmpty { record.readings = observation.readings }

        // Decide alerts from the state we already hold, and remember what was
        // said so a reconnect or a restart cannot say it again.
        var canonicalObservation = observation
        canonicalObservation.deviceID = id
        let (decided, alertState) = BatteryAlertEngine.evaluate(
            state: record.alertState,
            observation: canonicalObservation,
            configuration: record.alerts,
            isAttaching: isAttaching
        )
        record.alertState = alertState

        // The same physical AirPods can hold two records — one per source —
        // and there is no dependable way to relate them. The records stay
        // separate; the alert does not fire twice.
        let alerts = BatteryAlertEngine.withoutDuplicates(
            decided, recent: recentlyDelivered, now: at
        ).map { enrich($0, from: record) }

        // The record goes in *before* anything is written or delivered. An
        // earlier version wrote immediately inside the block above, which put
        // the latch on disk from the copy that had not been stored yet — so a
        // crash inside the debounce window lost it and the alert repeated
        // after relaunch.
        if let index = catalogue.index(of: id) {
            catalogue.devices[index] = record
        } else {
            catalogue.devices.append(record)
        }

        if !alerts.isEmpty {
            recentlyDelivered.append(contentsOf: alerts)
            recentlyDelivered.removeAll {
                at.timeIntervalSince($0.firedAt) > BatteryAlertEngine.duplicateAlertWindow
            }
            // A latch is expensive to lose — losing one repeats the alert —
            // so it is written at once rather than waiting out the debounce,
            // and now from a catalogue that actually contains it.
            writeNow()
            // One or the other, never both.
            if let consumer {
                consumer(alerts)
            } else {
                enqueue(alerts)
            }
        }

        appendHistory(for: observation, id: id, connected: observation.presence == .connected)
        runMaintenanceIfDue()
        scheduleWrite()
    }

    private func appendHistory(
        for observation: DeviceObservation,
        id: DeviceIdentity,
        connected: Bool
    ) {
        let key = DeviceCatalogue.historyKey(id)
        var samples = catalogue.history[key] ?? []
        for reading in observation.readings where reading.reliability != .unreliable {
            let candidate = BatterySample(
                component: reading.component, level: reading.level,
                charging: reading.charging, at: reading.observedAt,
                isConnected: connected
            )
            let previous = samples.last { $0.component == reading.component }
            guard BatteryHistory.isWorthKeeping(candidate, after: previous) else { continue }
            samples.append(candidate)
        }
        catalogue.history[key] = samples
    }

    /// Gives an alert the device's own styling and full battery picture.
    ///
    /// Without this the replacement cards were a generic headphones glyph,
    /// `isApple: false` and a single component — so an AirPods low-battery
    /// card lost the tinted icon and the other ear's level that the shipped
    /// card had.
    private func enrich(_ alert: BatteryAlert, from record: DeviceRecord) -> BatteryAlert {
        var enriched = alert
        enriched.symbolName = record.symbolName
        enriched.isApple = record.isApple
        enriched.allLevels = Dictionary(
            record.readings
                .filter { $0.reliability != .unreliable }
                .map { ($0.component.label, $0.level) },
            uniquingKeysWith: { first, _ in first }
        )
        return enriched
    }

    /// Hands alerts back when a consumer could not take them.
    ///
    /// A provider that stops between the store deciding an alert and the main
    /// actor presenting it used to drop it on the floor: the store considered
    /// it delivered, and the session check rejected it.
    ///
    /// If a *newer* consumer is already listening, these go straight to it —
    /// appending unconditionally left them waiting for a restart that might
    /// never come.
    /// - Parameter from: the subscription that could not present these. If it
    ///   is still the registered consumer — because its unsubscribe has not
    ///   landed yet — the alerts are queued rather than handed straight back
    ///   to the thing that just refused them, which would have bounced them
    ///   between the two for as long as the stop took.
    public func requeueAlerts(_ alerts: [BatteryAlert], from token: UUID? = nil) {
        guard !alerts.isEmpty else { return }
        let rejectedByCurrent = token != nil && token == consumerToken
        if let consumer, !rejectedByCurrent {
            consumer(alerts)
            return
        }
        enqueue(alerts)
    }

    /// Queues alerts for a consumer that is not listening yet, bounded.
    ///
    /// With the alerts provider switched off, every decision used to append to
    /// an array that nothing ever drained — so it grew for as long as the app
    /// ran, and switching the provider back on presented a burst of alerts
    /// about levels from hours ago. Capped, deduplicated by rule and
    /// component, and aged out.
    private func enqueue(_ alerts: [BatteryAlert]) {
        for alert in alerts {
            // One pending presentation per device, rule, component and kind.
            //
            // The device is the part that was missing: the built-in low rule
            // has one shared id, so two keyboards going flat — or a mouse and
            // a pair of earbuds — collapsed into a single pending alert and
            // only one was ever shown.
            pendingAlerts.removeAll { pending in
                pending.deviceID == alert.deviceID
                    && pending.ruleID == alert.ruleID
                    && pending.component == alert.component
                    && pending.kind == alert.kind
            }
            pendingAlerts.append(alert)
        }
        expirePendingAlerts()
    }

    /// Drops what is too old or too plentiful.
    private func expirePendingAlerts() {
        let now = self.now()
        pendingAlerts.removeAll { now.timeIntervalSince($0.firedAt) > Self.pendingAlertLifetime }
        if pendingAlerts.count > Self.maximumPendingAlerts {
            pendingAlerts.removeFirst(pendingAlerts.count - Self.maximumPendingAlerts)
        }
    }

    /// Past this, a queued alert describes a level nobody would act on now.
    public static let pendingAlertLifetime: TimeInterval = 30 * 60

    /// A ceiling regardless of age.
    public static let maximumPendingAlerts = 16

    /// Tests: which consumer is registered, if any.
    public func currentConsumerToken() -> UUID? { consumerToken }

    /// Tests: what is queued for a consumer that has not arrived yet.
    public func queuedAlertCount() -> Int { pendingAlerts.count }

    /// Shows what a rule would look like, using made-up numbers.
    ///
    /// Goes to the live consumer — the same path a real alert takes, so a
    /// preview cannot drift from the thing it is previewing. It touches no
    /// record, no latch and no history, so previewing can never consume the
    /// "already said this" state and silence the real alert.
    public func deliverPreview(of rule: BatteryAlertRule, deviceName: String) {
        guard let consumer else { return }
        let alert = BatteryAlert(
            ruleID: rule.id,
            kind: rule.kind,
            deviceID: DeviceIdentity(source: .bluetoothAddress, value: "preview"),
            deviceName: deviceName,
            component: rule.component ?? .main,
            level: rule.threshold,
            delivery: rule.delivery,
            firedAt: now()
        )
        consumer([alert])
    }

    // MARK: - Editing

    /// Pins a device.
    ///
    /// - Parameter id: the identity **as the catalogue holds it** — what
    ///   `snapshot()` returned. A rotating identifier is canonicalised on the
    ///   way in, so a raw one taken straight from an advertisement addresses
    ///   nothing.
    public func setPinned(_ pinned: Bool, for id: DeviceIdentity) {
        load()
        guard let index = catalogue.index(of: id) else { return }
        catalogue.devices[index].isPinned = pinned
        scheduleWrite()
    }

    public func setHidden(_ hidden: Bool, for id: DeviceIdentity) {
        load()
        guard let index = catalogue.index(of: id) else { return }
        catalogue.devices[index].isHidden = hidden
        scheduleWrite()
    }

    public func setAlerts(_ configuration: DeviceAlertConfiguration, for id: DeviceIdentity) {
        load()
        guard let index = catalogue.index(of: id) else { return }
        catalogue.devices[index].alerts = configuration
        scheduleWrite()
    }

    /// Forgets a device. Ledge's record only — the system pairing is
    /// untouched, and nothing here disconnects anything.
    public func forget(_ id: DeviceIdentity, keepingHistory: Bool) {
        load()
        catalogue.devices.removeAll { $0.id == id }
        let key = DeviceCatalogue.historyKey(id)
        if keepingHistory {
            // Maintenance drops history whose device is gone, which would
            // have quietly deleted exactly what the user chose to keep.
            catalogue.retainedHistory.insert(key)
        } else {
            catalogue.history[key] = nil
            catalogue.retainedHistory.remove(key)
        }
        scheduleWrite()
    }

    public func deleteAllHistory() {
        load()
        catalogue.history.removeAll()
        scheduleWrite()
    }

    public func history(for id: DeviceIdentity) -> [BatterySample] {
        load()
        return catalogue.history[DeviceCatalogue.historyKey(id)] ?? []
    }

    // MARK: - Maintenance

    private func runMaintenanceIfDue() {
        let at = now()
        if let last = lastMaintenance, at.timeIntervalSince(last) < Self.maintenanceInterval {
            return
        }
        lastMaintenance = at

        pruneDevices(now: at)

        for (key, samples) in catalogue.history {
            let kept = BatteryHistory.pruned(samples, now: at)
            catalogue.history[key] = kept.isEmpty ? nil : kept
        }
        // History for a device nobody holds a record of any more is history
        // nobody can look at — unless the user asked to keep it when they
        // removed the device, which is what `retainedHistory` records.
        let live = Set(catalogue.devices.map { DeviceCatalogue.historyKey($0.id) })
        catalogue.history = catalogue.history.filter {
            live.contains($0.key) || catalogue.retainedHistory.contains($0.key)
        }
        // A retained key whose samples have all aged out needs remembering no
        // longer.
        catalogue.retainedHistory = catalogue.retainedHistory.filter {
            catalogue.history[$0] != nil
        }
    }

    /// Retires records nobody can use any more.
    ///
    /// The brief that asked for this feature was explicit that device records
    /// must not grow without a retention policy, and a live install proved
    /// why: CoreBluetooth rotates peripheral identifiers, so the same AirPods
    /// produced a new record every few minutes. Bounding history per device
    /// does nothing about the number of devices.
    ///
    /// Three rules, in order:
    ///
    /// - A record under a **rotating** identifier is one appearance of a
    ///   device, not a device. It goes shortly after it stops being seen.
    /// - A record under a stable identifier is kept for as long as its history
    ///   would be.
    /// - Pinned or customised records are never retired: the user said they
    ///   care, and "I removed your pinned device to save space" is not an
    ///   acceptable thing for this to do.
    private func pruneDevices(now: Date) {
        // Decided first, applied after. Mutating `catalogue.history` from
        // inside `catalogue.devices.removeAll` is two exclusive accesses to
        // the same struct, which Swift traps on at runtime.
        func isRetirable(_ record: DeviceRecord) -> Bool {
            // The user said they care about these, and "I removed your pinned
            // device to save space" is not an acceptable thing to do.
            !record.isPinned && !record.alerts.isCustomised
        }

        var doomed: [DeviceIdentity] = catalogue.devices.filter { record in
            guard isRetirable(record) else { return false }
            let limit = record.id.isDurable
                ? BatteryHistory.staleRecordAge
                : BatteryHistory.rotatingRecordGrace
            return now.timeIntervalSince(record.lastSeen) > limit
        }.map(\.id)

        // A ceiling, whatever else happens: oldest-seen first.
        let surviving = catalogue.devices.filter { !doomed.contains($0.id) }
        if surviving.count > BatteryHistory.maximumDevices {
            let excess = surviving.count - BatteryHistory.maximumDevices
            doomed += surviving
                .filter(isRetirable)
                .sorted { $0.lastSeen < $1.lastSeen }
                .prefix(excess)
                .map(\.id)
        }

        guard !doomed.isEmpty else { return }
        let removing = Set(doomed.map { DeviceCatalogue.historyKey($0) })
        catalogue.devices.removeAll { doomed.contains($0.id) }
        for key in removing where !catalogue.retainedHistory.contains(key) {
            catalogue.history[key] = nil
        }
    }

    /// Forces a maintenance pass. For tests and for an explicit tidy.
    public func runMaintenance() {
        load()
        lastMaintenance = nil
        runMaintenanceIfDue()
        scheduleWrite()
    }

    // MARK: - Writing

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: DeviceCatalogueStore.writeDebounce)
            guard !Task.isCancelled else { return }
            await self?.writeNow()
        }
    }

    /// Writes immediately. Called on the way out, and by tests.
    public func flush() async {
        writeTask?.cancel()
        writeTask = nil
        writeNow()
    }

    private func writeNow() {
        load()
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(catalogue)

            // Atomic: a write interrupted by a crash or a power cut leaves the
            // previous catalogue intact rather than a half-written one that
            // would be quarantined on the next launch.
            try data.write(to: url, options: .atomic)
        } catch {
            Self.log.error("could not write the device catalogue: \(error.localizedDescription, privacy: .public)")
        }
    }
}
