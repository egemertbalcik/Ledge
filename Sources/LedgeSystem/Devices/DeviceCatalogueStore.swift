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

    /// What the Mac is paired with, as last read from the Bluetooth stack.
    ///
    /// The catalogue's test of ownership, and deliberately a *shared, nullable*
    /// answer rather than a set this actor keeps for itself: the question is
    /// "has anything asked the system yet", and a store holding its own empty
    /// set could not tell that apart from "paired with nothing".
    private let paired: PairedDeviceRegistry

    /// The paired reading this store has already acted on, so an unchanged
    /// answer costs a comparison and nothing else.
    private var appliedPairedGeneration: Int?

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
    /// - Parameter paired: the shared paired-device answer. Defaults to one
    ///   nobody has answered, which is the honest state for a store built
    ///   without a Bluetooth stack behind it: it judges nothing until it is
    ///   told something.
    public init(
        url: URL = DeviceCatalogueStore.defaultURL(),
        now: @escaping @Sendable () -> Date = Date.init,
        paired: PairedDeviceRegistry = PairedDeviceRegistry()
    ) {
        self.url = url
        self.now = now
        self.paired = paired
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
            for index in catalogue.devices.indices {
                Self.seedSystemWitness(&catalogue.devices[index])
            }
            // Tidied on the way in, so a catalogue that sat on disk for weeks
            // does not present retired records until something happens to be
            // observed.
            pruneDevices(now: now())
            // A record written as `connected` describes the moment the app was
            // last killed, not now. Corrected before anything can read it.
            decayStalePresence(now: now())
            applyPairedAnswer()
        } catch {
            Self.log.error("device catalogue unreadable: \(error.localizedDescription, privacy: .public)")
            quarantine(reason: "corrupt")
            catalogue = DeviceCatalogue()
        }
    }

    /// Gives a record from a catalogue written before `systemReportedAt` was
    /// kept the witness its own readings already prove.
    ///
    /// Without it the first launch after the upgrade read every battery as
    /// unwitnessed, while the low alert's latch on disk was still spent, and a
    /// neighbour's charging set released it before the first new system
    /// sample arrived. Only what the record can vouch for: a battery the
    /// system itself read — never one heard over the air — dated when it was
    /// read, so a stale one expires at once, and the presence check where the
    /// witness is used still applies. Per component: a reading of the buds
    /// says nothing about the case.
    static func seedSystemWitness(_ record: inout DeviceRecord) {
        guard record.systemReportedAt == nil, record.id.source == .bluetoothAddress else { return }
        var witness: [BatteryComponent: Date] = [:]
        for reading in record.readings
        where reading.origin != .proximityName && reading.reliability == .fresh {
            witness[reading.component] = reading.observedAt
        }
        if !witness.isEmpty { record.systemReportedAt = witness }
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
        // The paired list can be answered long after launch — the Bluetooth
        // provider has to start, and `system_profiler` takes a second or two.
        // Checked here as well as on the way in so the settings pane shows the
        // swept catalogue the moment the answer lands, rather than whenever a
        // device next happens to be observed.
        applyPairedAnswer()
        return catalogue
    }

    /// Records whether the provider behind a kind of source is running.
    ///
    /// Session state: never written to disk, and nothing polls to maintain it.
    /// It is what lets a source that reports only on change — this Mac's
    /// battery — be current while its provider runs and doubtful once it stops.
    public func setSource(_ source: DeviceIdentity.Source, live: Bool) {
        load()
        if live {
            catalogue.liveSources.insert(source)
        } else {
            catalogue.liveSources.remove(source)
        }
    }

    // MARK: - Observing

    public func record(_ observation: DeviceObservation) async {
        load()
        applyPairedAnswer()
        let at = observation.observedAt
        // A rotating identifier is canonicalised, so one logical device keeps
        // one record — with its history, its latches, its pinning and the
        // user's own rules — across every rotation. Keying on the rotating
        // value meant a fresh default record every few minutes and the old
        // one's configuration orphaned beside it.
        let id = observation.canonicalID

        // Whether this observation *is* the device attaching, rather than a
        // passive sighting or the first reading after launch. Only a genuine
        // attach may alert without a previous level to have crossed — and only
        // a connection callback is evidence of one.
        //
        // The inventory of what was already connected looks identical to an
        // attachment from here: presence connected, no prior record, a low
        // level. Launching with low AirPods in your ears would then alert
        // immediately, every launch, about a state the user already knows.
        // `ObservationCause` is what tells the two apart.
        let couldAttach = observation.cause.isAttachmentEvidence
        let isAttaching: Bool
        var record: DeviceRecord
        if let index = catalogue.index(of: id) {
            record = catalogue.devices[index]
            isAttaching = couldAttach
                && observation.presence == .connected
                && record.presence != .connected
            // A rename is a rename, not a new device.
            record.name = observation.name
        } else {
            // Nothing is admitted to the catalogue that the Mac is not paired
            // with. This is where the strangers got in: a connect notification
            // for a randomised LE address, or an advertisement from a pair of
            // earbuds two tables away, created a record that then lived for
            // ever.
            guard mayCreate(id) else {
                Self.log.debug("ignored an unowned device observation")
                return
            }
            record = DeviceRecord(
                id: id, name: observation.name,
                firstSeen: at, lastSeen: at
            )
            // A device we have never seen before. Attaching only if something
            // actually saw it attach; an inventory or an advertisement
            // establishes the baseline quietly instead.
            isAttaching = couldAttach && observation.presence == .connected
        }

        // Never backwards. A reading of the paired list takes seconds, so one
        // sampled before an advertisement can arrive after it — and moving
        // the record's clock back made the newer evidence look like the older
        // one everywhere that asks how fresh this device is.
        record.lastSeen = max(record.lastSeen, at)
        // An observation that says `unknown` is one that did not look: an
        // advertisement says "in range" and nothing about attachment. Letting
        // it overwrite a presence something actually observed turned a device
        // known to be connected into a device nothing can say anything about,
        // every time its case was opened nearby. The record's freshness is
        // what qualifies the old answer; see `DeviceRecord.status(now:)`.
        if observation.presence != .unknown || record.presence == .unknown {
            record.presence = observation.presence
        }
        // The source is the only thing that knows how the device is drawn.
        record.symbolName = observation.symbolName
        record.isApple = observation.isApple
        if observation.presence == .connected { record.lastConnected = at }
        // An observation carrying no levels — a disconnect, say — must not
        // erase what was last known. The record keeps the old readings and
        // the derived freshness is what says they are old.
        //
        // Per component, and by when each was *observed*: a complete reading
        // of the paired list is legitimately accepted for its membership
        // while its battery levels are older than an advertisement that
        // arrived in the meantime. Replacing the lot put a stale level back
        // on screen — and into the history and the alert decision — stamped
        // with its honest old time, which nothing downstream was comparing.
        //
        // And while the system is reporting this device, an advertisement
        // that does not look like it is left out of the display, the history
        // and the alert alike. See `yieldingToTheSystem`.
        if observation.presence == .connected {
            for reading in observation.readings where reading.origin != .proximityName {
                let held = record.systemReportedAt?[reading.component] ?? .distantPast
                record.systemReportedAt = (record.systemReportedAt ?? [:])
                    .merging([reading.component: max(held, reading.observedAt)]) { _, new in new }
            }
        }
        let reported = Self.reportedBySystem(record, at: at)
        var observation = observation
        observation.readings = Self.yieldingToTheSystem(
            observation.readings, on: record, reportedBySystem: reported
        )
        let previousReadings = record.readings
        if !observation.readings.isEmpty {
            record.readings = Self.freshest(record.readings, observation.readings)
        }
        // From what was held as well as what arrived: a catalogue written
        // before this was remembered has its only evidence in the readings
        // about to be replaced, and the first system refresh threw it away.
        let saidCharging = (previousReadings + observation.readings)
            .filter { $0.charging != .unknown && $0.reliability != .unreliable }
            .map(\.component)
        if !saidCharging.isEmpty {
            record.chargingReported = (record.chargingReported ?? []).union(saidCharging)
        }

        // Decide alerts from the state we already hold, and remember what was
        // said so a reconnect or a restart cannot say it again.
        var canonicalObservation = observation
        canonicalObservation.deviceID = id
        // From the readings that are actually news, for the same reason the
        // display takes them: an older sample is not a crossing, and feeding
        // one to the engine released a latch and let the *next* advertisement
        // announce the same low battery a second time.
        canonicalObservation.readings = Self.newsOnly(
            observation.readings, against: previousReadings
        )
        let (decided, alertState) = BatteryAlertEngine.evaluate(
            state: record.alertState,
            observation: canonicalObservation,
            configuration: record.alerts,
            isAttaching: isAttaching,
            reportedBySystem: reported
        )
        record.alertState = alertState

        // The same physical AirPods can hold two records — one per source —
        // and there is no dependable way to relate them. The records stay
        // separate; the alert does not fire twice.
        let surviving = BatteryAlertEngine.withoutDuplicates(
            decided, recent: recentlyDelivered, now: at
        )
        // The latch of a suppressed decision *stays*. Everything dropped here
        // is a cross-record duplicate — the same alert about one physical
        // device, already shown or queued through its other record — so the
        // user has seen it. Releasing the latch meant the second record said
        // the same thing again on a later reconnect, once the five-minute
        // duplicate window had passed.
        let alerts = surviving.map { enrich($0, from: record) }

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

        appendHistory(for: observation, id: id, lastKnown: record.readings)
        runMaintenanceIfDue()
        scheduleWrite()
    }

    private func appendHistory(
        for observation: DeviceObservation,
        id: DeviceIdentity,
        lastKnown: [BatteryReading]
    ) {
        let key = DeviceCatalogue.historyKey(id)
        var samples = catalogue.history[key] ?? []

        // A disconnect carries no levels, so it used to add nothing at all —
        // and the chart then drew a straight line from the last reading
        // before the device left to the first one after it came back, through
        // hours nobody observed. The boundary is recorded instead, carrying
        // the last known level and saying the device was gone.
        if observation.presence == .disconnected, observation.readings.isEmpty {
            for reading in lastKnown where reading.reliability != .unreliable {
                let boundary = BatterySample(
                    component: reading.component, level: reading.level,
                    charging: reading.charging, at: observation.observedAt,
                    isConnected: false
                )
                let previous = samples.last { $0.component == reading.component }
                // Always kept: a boundary is the one sample whose whole job is
                // to mark where the line stops.
                guard previous?.isConnected != false else { continue }
                samples.append(boundary)
            }
            catalogue.history[key] = samples
            return
        }

        for reading in observation.readings where reading.reliability != .unreliable {
            let previous = samples.last { $0.component == reading.component }
            let candidate = BatterySample(
                component: reading.component, level: reading.level,
                charging: reading.charging, at: reading.observedAt,
                // A proximity advertisement says "in range" and nothing about
                // attachment: `unknown` is not a disconnection, and recording
                // it as one drew a gap through a device that never left.
                isConnected: Self.connectivity(observation.presence, after: previous)
            )
            guard BatteryHistory.isWorthKeeping(candidate, after: previous) else { continue }
            samples.append(candidate)
        }
        catalogue.history[key] = samples
    }

    /// Whether a sample should say the device was connected.
    ///
    /// Only a definite presence changes the answer. An unknown one keeps
    /// whatever the last sample said, and a first sample with nothing to go on
    /// counts as connected: something is reporting its battery.
    private static func connectivity(
        _ presence: DevicePresence,
        after previous: BatterySample?
    ) -> Bool {
        switch presence {
        case .connected: return true
        case .disconnected: return false
        case .unknown: return previous?.isConnected ?? true
        }
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

    /// Tests: empties the pending queue without delivering it, so a later
    /// count measures only what happened afterwards.
    func drainQueuedAlertsForTesting() {
        pendingAlerts.removeAll()
    }

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
            threshold: rule.threshold,
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
        // A deleted rule's latch has nothing left to suppress, and would sit
        // in the persisted state for the life of the record. The default
        // rule's id is kept whatever the configuration says: an uncustomised
        // device has no rules listed and still alerts through it, so dropping
        // that latch would let the default alert repeat.
        var live = Set(configuration.rules.map(\.id))
        live.insert(BatteryAlertRule.defaultLowID)
        for component in catalogue.devices[index].alertState.keys {
            catalogue.devices[index].alertState[component]?.firedRuleIDs.formIntersection(live)
        }
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

    // MARK: - Ownership

    /// Whether a device may *enter* the catalogue.
    ///
    /// A device belongs here if the Mac is paired with it, or if it is this
    /// Mac. Everything else is a passer-by: the radio hears every device in
    /// the room, and hearing one is not evidence of whose it is.
    ///
    /// The one concession is to not-knowing. Until something has read the
    /// paired list there is no paired set to be absent from, and refusing
    /// everything in that window would mean a connect arriving before the
    /// first `system_profiler` returns went unrecorded. So an address gets the
    /// benefit of the doubt *only* while the question is unanswerable — and
    /// the sweep that runs on the first real answer removes anything that got
    /// in on that basis and should not have.
    ///
    /// An over-the-air identity gets no such benefit even then. A proximity
    /// advertisement cannot establish ownership however long one waits, so
    /// there is no doubt to give it the benefit of; the only reason it is
    /// allowed through with no answer at all is that `DeviceObservations`
    /// refuses to produce one in that state, and this is the backstop rather
    /// than the gate.
    private func mayCreate(_ id: DeviceIdentity) -> Bool {
        guard let answer = paired.current else { return true }
        switch id.source {
        case .thisMac:
            return true
        case .bluetoothAddress:
            return answer.contains(id)
        case .peripheralUUID, .proximityName:
            // Keyed on something heard over the air. Nothing the Mac is
            // paired with is ever filed under one of these — a paired device
            // has an address — so there is nothing to match against.
            return false
        }
    }

    /// Acts on a paired-list reading, once per reading.
    ///
    /// Everything that depends on knowing what the Mac owns happens here, and
    /// nothing happens at all until `current` is non-nil: a store that has not
    /// been told must change nothing, or launch would delete the catalogue
    /// before the Bluetooth stack had finished starting up.
    private func applyPairedAnswer() {
        guard let answer = paired.current,
              answer.generation != appliedPairedGeneration
        else { return }
        appliedPairedGeneration = answer.generation

        reconcilePresence(with: answer)
        sweepUnownedRecords(with: answer)
    }

    /// Brings stored attachment back in line with what macOS says.
    ///
    /// A full paired reading is the only thing that can retire a stale
    /// `connected`: the catalogue held five devices claiming to be attached
    /// while the system reported one. Presence is only ever *lowered* here —
    /// an upgrade belongs to an observation, which carries the readings and
    /// the alert evaluation a connection deserves.
    private func reconcilePresence(with answer: PairedDeviceRegistry.Answer) {
        for index in catalogue.devices.indices {
            let record = catalogue.devices[index]
            guard record.id.source == .bluetoothAddress, record.presence == .connected
            else { continue }

            if let device = answer.device(for: record.id) {
                // macOS lists it and says it is not connected. That is an
                // observation, not an inference, so `disconnected` is honest.
                if !device.isConnected { catalogue.devices[index].presence = .disconnected }
                // The paired list is the authority on the name. A record
                // showing "AirPods 4 (ANC)" for earbuds the user renamed
                // "Ege AirPods" is showing a name from the air, not from the
                // Mac.
                if !device.name.isEmpty { catalogue.devices[index].name = device.name }
            } else {
                // Not in the paired list at all — a pinned ghost, or a record
                // from before this rule. Nothing can be claimed about a device
                // the system does not list, and `connected` is a claim.
                catalogue.devices[index].presence = .unknown
            }
        }
    }

    /// The arriving readings, less any advertisement that is probably not
    /// this device's.
    ///
    /// An advertisement is filed under the paired device by model id, which
    /// cannot tell the user's set from any same-model set in range. While the
    /// device is connected the system is reporting its battery — by address,
    /// about this exact device — and letting every advertisement in beside it
    /// cost the user twice over: Settings and the chart flipped between their
    /// 20% and a neighbour's 70%, and every 70% released the low alert to
    /// announce the same 20% again.
    ///
    /// So while the system is reporting, an advertisement has to look like the
    /// set already on the record: within `sameSetTolerance` of the level held
    /// for that cell. A neighbour's set is usually far off and is dropped.
    ///
    /// And it has to be about charging — saying it is, or arriving while the
    /// cell is charging, which is how the end of a charge is heard. That is the
    /// one thing the system cannot say, and the only reason to listen: the pods
    /// charging in the open case are still connected, and without it a charged
    /// alert could never fire. A plain discharging advertisement adds nothing
    /// the system is not already saying, and taking its level was not safe
    /// even from the user's own set: the air speaks in tens and the system in
    /// ones, and a system 26% between two advertised 20%s rearmed the low
    /// alert and fired it a second time.
    ///
    /// Per component, and only for a component the system is reporting now
    /// (`reportedBySystem`). With the device gone to the phone, a battery the
    /// system has not mentioned — a case it never listed — or nothing heard
    /// from it for longer than its reading is believed, the advertisement is
    /// all there is and is kept: the level it would be measured against is
    /// not the system's, or no longer describes now.
    public static func yieldingToTheSystem(
        _ arriving: [BatteryReading],
        on record: DeviceRecord,
        reportedBySystem: Set<BatteryComponent>
    ) -> [BatteryReading] {
        arriving.filter { reading in
            guard reading.origin == .proximityName,
                  reportedBySystem.contains(reading.component),
                  let held = record.readings.first(where: { $0.component == reading.component })
            else { return true }
            return abs(reading.level - held.level) <= sameSetTolerance
                && (reading.charging == .charging || held.charging == .charging)
        }
    }

    /// The components the system is reporting for this device right now.
    ///
    /// Connected, and reported within the freshness the system's own reading
    /// is given. A device-wide "connected recently" was not enough: the buds
    /// being reported kept yesterday's case level as the baseline, and every
    /// case advertisement measured against it was refused for the whole
    /// connection.
    static func reportedBySystem(_ record: DeviceRecord, at now: Date) -> Set<BatteryComponent> {
        guard record.presence == .connected, let reports = record.systemReportedAt else { return [] }
        let interval = DeviceIdentity.Source.bluetoothAddress.freshnessInterval
        return Set(reports.filter { now.timeIntervalSince($0.value) <= interval }.keys)
    }

    /// How far an advertisement may sit from the level held for its cell and
    /// still be taken for the same set.
    ///
    /// From the owner's own evening with another AirPods 4 in range: the
    /// air's 10% steps put their own set up to 12 points from the system's
    /// reading (an advertised 40% against a measured 52%), and the other set
    /// never came closer than 23. A charge climbs one step at a time, and each
    /// accepted step becomes the level the next is measured from.
    public static let sameSetTolerance = 0.15

    /// The readings that say something the record did not already know.
    ///
    /// Anything whose component is already held with a *newer* sample is
    /// dropped: it is not a crossing, a recovery, or a change — it is an
    /// older look at the same cell, arriving late.
    public static func newsOnly(
        _ arriving: [BatteryReading],
        against held: [BatteryReading]
    ) -> [BatteryReading] {
        var byComponent: [BatteryComponent: BatteryReading] = [:]
        for reading in held { byComponent[reading.component] = reading }
        return arriving.filter { reading in
            guard let previous = byComponent[reading.component] else { return true }
            return reading.observedAt >= previous.observedAt
        }
    }

    /// The newest reading of each component.
    ///
    /// A component the arriving observation does not mention keeps what was
    /// known; one it mentions with an older sample time keeps the newer
    /// value. Equal times take the arriving one, which is the same source
    /// re-reporting.
    public static func freshest(
        _ existing: [BatteryReading],
        _ arriving: [BatteryReading]
    ) -> [BatteryReading] {
        var byComponent: [BatteryComponent: BatteryReading] = [:]
        for reading in existing { byComponent[reading.component] = reading }
        for reading in arriving {
            if let held = byComponent[reading.component], held.observedAt > reading.observedAt {
                continue
            }
            byComponent[reading.component] = reading
        }
        // Stable, so a record's cells do not shuffle between writes.
        return byComponent.values.sorted {
            ($0.component.sortOrder, $0.component.label) < ($1.component.sortOrder, $1.component.label)
        }
    }

    /// Drops the records the Mac is not paired with. The one-off cleanup, and
    /// the standing rule, in one pass.
    ///
    /// Two exemptions, both the user's own doing: a pinned record and one with
    /// customised alerts were deliberately configured, and silently deleting
    /// somebody's configuration is worse than leaving a row they can remove
    /// themselves.
    private func sweepUnownedRecords(with answer: PairedDeviceRegistry.Answer) {
        let before = catalogue.devices.count
        var dropped: [DeviceIdentity] = []
        catalogue.devices.removeAll { record in
            guard !record.isPinned, !record.alerts.isCustomised else { return false }
            guard record.id != .thisMac else { return false }
            // A record a shipped version of Ledge keyed by model id goes
            // like any other record the Mac is not paired with: it never
            // could be in that list, since it was never a Bluetooth address.
            //
            // Decided rather than overlooked. Those records hold a battery
            // history and a hidden flag that nothing carries forward, and
            // the owner chose to let them go — the device itself comes back
            // the moment it connects, under the identity it should have had
            // all along, and a record somebody pinned or gave their own
            // alert rules is already exempt two lines above. What goes is an
            // old chart and a hidden flag, for a feature that had barely
            // shipped when the identity changed.
            guard !answer.contains(record.id) else { return false }
            dropped.append(record.id)
            return true
        }
        guard !dropped.isEmpty || catalogue.needsOwnershipSweep else { return }

        for id in dropped {
            let key = DeviceCatalogue.historyKey(id)
            guard !catalogue.retainedHistory.contains(key) else { continue }
            catalogue.history[key] = nil
        }
        if !dropped.isEmpty {
            Self.log.notice("""
                device catalogue: dropped \(dropped.count, privacy: .public) of \
                \(before, privacy: .public) records the Mac is not paired with
                """)
        }
        // Recorded on disk, so the file says it has been through this.
        catalogue.version = DeviceCatalogue.currentVersion
        scheduleWrite()
    }

    /// Stops a stored `connected` from outliving the evidence for it.
    ///
    /// The paired reading above is the real correction; this is the backstop
    /// for when there is none — Bluetooth switched off, the provider disabled,
    /// a catalogue reloaded hours after the app was killed. A record nothing
    /// has spoken for in longer than its source's freshness window cannot
    /// honestly still claim an attachment, so it becomes `unknown` — never
    /// `disconnected`, which would be an event nobody saw.
    private func decayStalePresence(now: Date) {
        for index in catalogue.devices.indices {
            let record = catalogue.devices[index]
            guard record.presence == .connected,
                  record.isStale(now: now, sourceIsLive: catalogue.sourceIsLive(record.id))
            else { continue }
            catalogue.devices[index].presence = .unknown
        }
    }

    // MARK: - Maintenance

    private func runMaintenanceIfDue() {
        let at = now()
        if let last = lastMaintenance, at.timeIntervalSince(last) < Self.maintenanceInterval {
            return
        }
        lastMaintenance = at

        pruneDevices(now: at)
        decayStalePresence(now: at)

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
        applyPairedAnswer()
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
