import Foundation
import LedgeCore
import LedgeSystem
import os

/// Publishes an AirPods card when the case is opened (or closed), read from the
/// BLE proximity broadcast rather than a connect event — so it fires even while
/// the AirPods are already connected, matching what iOS shows.
///
/// A *change* in the lid counter is the event; a steady stream of identical
/// advertisements publishes nothing.
@MainActor
public final class AirPodsProximityProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "airpods")

    public let identifier = "airpods-proximity"

    /// How long the card lingers after a lid event before fading.
    static let lifetime: TimeInterval = 22

    /// How strong a reading has to be before a lid event is worth a card.
    ///
    /// A card is a claim about *here*: the case on the desk, the earbuds in
    /// hand. The readings themselves travel further and are worth keeping at
    /// any strength — the battery figures are as true from the other side of
    /// the room — so the scanner no longer throws them away, and this is
    /// where being close starts to matter.
    nonisolated static let closeEnoughForACard = -55

    private let scanner: any ProximityScanning
    /// What the Mac is paired with, read at the moment an advertisement
    /// arrives. Shared with the catalogue and filled in by the Bluetooth
    /// provider; nothing here touches hardware to maintain it.
    private let paired: PairedDeviceRegistry
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    /// The last lid counter seen per *peripheral* (falling back to the model
    /// when the scanner gave none), to tell a real open/close from the steady
    /// advertisement stream. Keyed by model alone, two same-model sets on one
    /// desk interleaved their counters and every alternation popped a card.
    private var lastLid: [String: UInt8] = [:]

    /// Where observations go. Every advertisement this provider already
    /// receives is reported; none is requested, and no scan is started for it.
    private let observations: (any DeviceObservationSink)?

    /// Somewhere to read the paired list, when nothing else has.
    ///
    /// The list is normally answered by the Bluetooth card provider — but
    /// that provider is a card the user can switch off, and this one is a
    /// different card they can leave on. In that configuration nothing ever
    /// answered, and "the list has not been read yet" is the state in which
    /// every advertisement counts as the user's: strangers' cases popped
    /// cards and held the radio open, for as long as the app ran.
    private let inventory: (any BluetoothDeviceSource)?

    /// When this run began, so the exception below can be bounded.
    private var startedAt: TimeInterval = 0

    /// The standing read of the paired list, cancelled with the run.
    private var inventoryTask: Task<Void, Never>?

    /// How long a card trusts an unread paired list.
    ///
    /// The exception is deliberate — a transient card for the user's own
    /// case-open is worth one possible stray in the seconds before the first
    /// reading lands — but it was unbounded, which turned "the first few
    /// seconds" into "for ever" whenever nothing read the list at all.
    nonisolated static let ownershipGrace: TimeInterval = 60

    public init(
        scanner: any ProximityScanning = AirPodsProximityScanner(),
        observations: (any DeviceObservationSink)? = nil,
        paired: PairedDeviceRegistry = PairedDeviceRegistry(),
        inventory: (any BluetoothDeviceSource)? = nil,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.scanner = scanner
        self.observations = observations
        self.paired = paired
        self.inventory = inventory
        self.now = now
    }

    /// Which run is current.
    ///
    /// A stream's termination cleans up asynchronously, so in stop-then-start
    /// the old stream's cleanup can land *after* the new run has begun — and
    /// it stopped the scanner and finished the new stream, leaving a provider
    /// the hub believed was running with nothing behind it. The token says
    /// whose cleanup it is.
    private var run = UUID()

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            let token = UUID()
            self.run = token
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop(token) }
            }
            startedAt = now()
            keepThePairedListAnswered(token)
            scanner.onUpdate = { [weak self] proximity in self?.handle(proximity) }
            // Ownership, strictly, for the radio: holding the most expensive
            // scan mode open is not something to do on a guess. The card's
            // own rule is kinder, and bounded — see `isWorthShowing`.
            scanner.isOurs = { [weak self] proximity in
                guard let self, let paired = self.paired.current else { return false }
                return DeviceObservations.owner(of: proximity, paired: paired) != nil
            }
            scanner.start()
        }
    }

    public func stop() {
        // A new token, so any cleanup still in flight for the run that just
        // ended cannot reach back into whatever starts next.
        run = UUID()
        inventoryTask?.cancel()
        inventoryTask = nil
        scanner.stop()
        continuation?.finish()
        continuation = nil
        lastLid.removeAll()
    }

    /// One run's cleanup, and only if that run is still the current one.
    private func stop(_ token: UUID) {
        guard run == token else { return }
        stop()
    }

    private func report(_ proximity: AirPodsProximity) {
        guard let observations,
              let observation = DeviceObservations.fromProximity(
                  proximity,
                  paired: paired.current,
                  at: Date(timeIntervalSinceReferenceDate: now())
              )
        else { return }
        // Synchronous: no task per advertisement, per connect or per reading.
        observations.submit(observation)
    }

    /// Whether a lid event belongs to the user at all.
    ///
    /// The same ownership question the catalogue asks, about a card instead of
    /// a record: a stranger's case opening at the next table used to pop
    /// "AirPods, 90%" on the user's screen.
    ///
    /// The answer differs in one place, deliberately. With no paired list read
    /// yet, the catalogue records nothing — a stored record is permanent, and
    /// there is no hurry. A card is transient and self-correcting, and
    /// withholding the user's own case-open is a worse failure than showing
    /// one stray card in the seconds before the first paired reading lands.
    /// - Parameter unansweredFor: how long this provider has been running
    ///   without the paired list ever being read. The exception for an
    ///   unanswered list lasts that long and no longer: the list is read by
    ///   the Bluetooth card provider, which the user can switch off while
    ///   leaving this card on, and an exception with no end is not an
    ///   exception.
    nonisolated static func isWorthShowing(
        _ proximity: AirPodsProximity,
        paired: PairedDeviceRegistry.Answer?,
        unansweredFor: TimeInterval = 0
    ) -> Bool {
        guard let paired else { return unansweredFor < ownershipGrace }
        return DeviceObservations.owner(of: proximity, paired: paired) != nil
    }

    /// Keeps the paired list answered for as long as this provider runs.
    ///
    /// Normally it does nothing: the Bluetooth card provider answers at
    /// launch and every ten minutes, and this is the same shared registry.
    /// It matters in the one configuration where that card is switched off —
    /// without it ownership can never be established, and this card has
    /// nothing to tell the user's own earbuds from a stranger's. A single
    /// read was not enough either: one that failed left the feature off for
    /// the rest of the run, and a device paired afterwards was never
    /// recognised.
    private func keepThePairedListAnswered(_ token: UUID) {
        guard inventory != nil else { return }
        inventoryTask?.cancel()
        inventoryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.run == token else { return }
                let wait = await self.readThePairedListIfStale(token)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Reads the list if nothing fresher exists, and says how long to wait
    /// before asking that question again.
    private func readThePairedListIfStale(_ token: UUID) async -> TimeInterval {
        guard let inventory else { return Self.inventoryRefresh }
        let at = Date(timeIntervalSinceReferenceDate: now())
        guard Self.needsAReading(paired.current, now: at) else { return Self.inventoryRefresh }
        let reading = await inventory.pairedDevices()
        // A read that outlived its run must not answer: a stopped provider's
        // stale list would otherwise beat the fresh one its replacement is
        // waiting for, and nothing would ask again.
        guard run == token else { return Self.inventoryRefresh }
        guard let reading else {
            // Nothing answered. Ask again sooner than the refresh cadence:
            // until something does, this card cannot tell the user's earbuds
            // from anybody else's and shows none at all.
            return Self.inventoryRetry
        }
        // Someone answered while this was reading, and no older than ours.
        guard Self.needsAReading(paired.current, now: at) else { return Self.inventoryRefresh }
        // Stamped with when the list was read, not with when this returned:
        // the registry decides between a reading and an event by their times.
        paired.answer(reading.devices.map(\.pairedDevice), at: reading.readAt)
        return Self.inventoryRefresh
    }

    /// Whether the paired list is worth reading again.
    ///
    /// Only when nobody else is keeping it current: with the Bluetooth card
    /// running, every answer here would be a second `system_profiler` for a
    /// list that was read a moment ago.
    nonisolated static func needsAReading(_ answer: PairedDeviceRegistry.Answer?, now: Date) -> Bool {
        guard let answer else { return true }
        return now.timeIntervalSince(answer.at) >= inventoryRefresh
    }

    /// How often the list is worth re-reading when nothing else reads it —
    /// the same cadence the Bluetooth card uses.
    nonisolated static let inventoryRefresh: TimeInterval = 10 * 60

    /// How soon to try again after a read that answered nothing.
    nonisolated static let inventoryRetry: TimeInterval = 60

    /// Whether a reading is close enough to put a card on screen.
    ///
    /// An unknown strength passes: it means the scanner did not stamp one,
    /// which is a test or a fixture rather than a device across the room.
    nonisolated static func isCloseEnough(_ proximity: AirPodsProximity) -> Bool {
        guard let rssi = proximity.rssi else { return true }
        return rssi >= closeEnoughForACard
    }

    private func handle(_ proximity: AirPodsProximity) {
        // Reported on every advertisement this provider was already given.
        // The catalogue coalesces the repeats; nothing here asks for more of
        // them, and the scanner's duty cycle is untouched.
        report(proximity)

        guard Self.isWorthShowing(
            proximity,
            paired: paired.current,
            unansweredFor: now() - startedAt
        ) else { return }

        // Near enough to be about this desk. Checked after the reading has
        // been reported, not before: a distant set still has a battery level
        // worth recording, and only the card depends on being close.
        guard Self.isCloseEnough(proximity) else { return }

        let key = proximity.peripheralID?.uuidString ?? String(proximity.model)
        let previous = lastLid[key]
        lastLid[key] = proximity.lidCounter
        // BLE private addresses rotate (~15 min), minting a fresh key each
        // time; without a bound the table grows for the whole session. A
        // wholesale reset re-baselines a few counters — one potentially
        // swallowed lid event per hour beats unbounded growth.
        if lastLid.count > 32 { lastLid = [key: proximity.lidCounter] }

        // First sighting is only a baseline — publish on a subsequent change, so
        // simply having AirPods nearby does not pop a card at launch.
        guard let previous, previous != proximity.lidCounter else { return }

        // Nothing worth showing if every cell is absent (e.g. an empty closed
        // case reporting disconnected pods).
        let levels = proximity.batteryLevels
        guard !levels.isEmpty else { return }

        Self.log.notice("AirPods lid event: \(proximity.name, privacy: .public)")

        // What the system last said about this device, rather than a literal
        // `true`. An advertisement proves the earbuds are in range and
        // nothing else — a case opening on the desk says nothing about
        // whether its pods are attached to this Mac — and the card prints the
        // word "Connected" either way. The paired list is the only evidence
        // there is; with no owner there is none, and the card does not claim
        // an attachment.
        let owner = DeviceObservations.owner(of: proximity, paired: paired.current)

        let id = ActivityID(kind: .device, source: "airpods-proximity")
        continuation?.yield(.publish(Activity(
            id: id,
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .device(DevicePayload(
                name: proximity.name,
                symbolName: proximity.symbolName,
                batteryLevels: levels,
                isConnected: owner?.isConnected
            ))
        )))
    }
}
