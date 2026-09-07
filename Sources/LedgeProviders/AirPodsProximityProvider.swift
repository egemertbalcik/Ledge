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

    private let scanner: AirPodsProximityScanner
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    /// The last lid counter seen per *peripheral* (falling back to the model
    /// when the scanner gave none), to tell a real open/close from the steady
    /// advertisement stream. Keyed by model alone, two same-model sets on one
    /// desk interleaved their counters and every alternation popped a card.
    private var lastLid: [String: UInt8] = [:]

    public init(
        scanner: AirPodsProximityScanner = AirPodsProximityScanner(),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.scanner = scanner
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            scanner.onUpdate = { [weak self] proximity in self?.handle(proximity) }
            scanner.start()
        }
    }

    public func stop() {
        scanner.stop()
        continuation?.finish()
        continuation = nil
        lastLid.removeAll()
    }

    private func handle(_ proximity: AirPodsProximity) {
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

        let id = ActivityID(kind: .device, source: "airpods-proximity")
        continuation?.yield(.publish(Activity(
            id: id,
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .device(DevicePayload(
                name: proximity.name,
                symbolName: proximity.symbolName,
                batteryLevels: levels,
                isConnected: true
            ))
        )))
    }
}
