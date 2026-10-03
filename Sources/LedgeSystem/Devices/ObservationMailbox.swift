import Foundation
import LedgeCore
import os

/// What a provider talks to when it has seen a device.
///
/// **Synchronous and non-blocking.** Providers used to wrap every call in a
/// `Task`, which meant one task per Bluetooth advertisement — and an attentive
/// AirPods scan delivers those many times a second. Submitting is now a lock,
/// a comparison and a return.
public protocol DeviceObservationSink: Sendable {
    func submit(_ observation: DeviceObservation)
}

/// Holds the latest observation per device and forwards what is worth
/// forwarding.
///
/// The scanner opens a window every six seconds and the catalogue's write is
/// debounced by five, so an unchanged device in range was producing roughly one
/// full catalogue write per window — for ever, while AirPods sat on the desk.
/// Nothing was wrong with any single step; the rates simply lined up.
///
/// So: at most one drain in flight, coalesced by device identity, forwarded at
/// once when something actually changed and otherwise only at a heartbeat.
public final class ObservationMailbox: DeviceObservationSink, @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "devices")

    /// How often an *unchanged* device is forwarded, so `lastSeen` advances
    /// and a device is not wrongly called stale while it is plainly here.
    /// Well inside the shortest freshness window.
    public static let heartbeat: TimeInterval = 2 * 60

    private struct State {
        /// Latest per device, waiting to be forwarded.
        var pending: [DeviceIdentity: DeviceObservation] = [:]
        /// What was last forwarded, to tell news from noise.
        var forwarded: [DeviceIdentity: DeviceObservation] = [:]
        var lastForwardedAt: [DeviceIdentity: Date] = [:]
        /// Whether a drain owns the queue. Exactly one may, and it keeps
        /// ownership until it finds the queue empty — including across an
        /// `invalidate()`, which is what guarantees that only one delivery is
        /// ever in flight.
        var isDraining = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let deliver: @Sendable (DeviceObservation) async -> Void

    public init(deliver: @escaping @Sendable (DeviceObservation) async -> Void) {
        self.deliver = deliver
    }

    /// Convenience for the real case: forward into the catalogue.
    public convenience init(store: DeviceCatalogueStore) {
        self.init(deliver: { [weak store] observation in
            await store?.record(observation)
        })
    }

    public func submit(_ observation: DeviceObservation) {
        // Keyed by the canonical identity, not the one the observation arrived
        // with. A rotating identifier would otherwise add an entry to both of
        // these maps every few minutes and never remove one — the catalogue
        // was fixed to canonicalise, and this was still indexing by the raw
        // UUID, so the leak simply moved here.
        let key = observation.canonicalID
        let shouldStart: Bool = state.withLock { s in
            let previous = s.forwarded[key]
            let last = s.lastForwardedAt[key]

            guard Self.isWorthForwarding(
                observation, after: previous, lastForwardedAt: last
            ) else {
                // Still the freshest thing we know, so it replaces any older
                // pending value — but it does not start a drain of its own.
                if s.pending[key] != nil {
                    s.pending[key] = observation
                }
                return false
            }

            s.pending[key] = observation
            guard !s.isDraining else { return false }
            s.isDraining = true
            return true
        }

        guard shouldStart else { return }
        Task { [weak self] in await self?.drain() }
    }

    /// Whether this observation says anything the last forwarded one did not.
    static func isWorthForwarding(
        _ candidate: DeviceObservation,
        after previous: DeviceObservation?,
        lastForwardedAt: Date?
    ) -> Bool {
        guard let previous else { return true }
        if candidate.presence != previous.presence { return true }
        if candidate.name != previous.name { return true }

        // Any component appearing, vanishing, moving or changing its charging
        // state is news. Levels are compared exactly: the sources report in
        // coarse steps, and the catalogue coalesces the fine detail anyway.
        let before = Dictionary(
            previous.readings.map { ($0.component, $0) }, uniquingKeysWith: { a, _ in a }
        )
        let after = Dictionary(
            candidate.readings.map { ($0.component, $0) }, uniquingKeysWith: { a, _ in a }
        )
        if before.keys != after.keys { return true }
        for (component, reading) in after {
            guard let old = before[component] else { return true }
            if old.level != reading.level { return true }
            if old.charging != reading.charging { return true }
            if old.reliability != reading.reliability { return true }
        }

        // Nothing new. Forward only occasionally, so `lastSeen` keeps up.
        guard let lastForwardedAt else { return true }
        return candidate.observedAt.timeIntervalSince(lastForwardedAt) >= heartbeat
    }

    /// Forwards whatever is queued, one at a time, until there is nothing
    /// left.
    ///
    /// Deliberately has no generation of its own. An earlier version gave the
    /// drain a generation and had `invalidate()` clear the draining flag —
    /// which released the flag while a delivery was still awaiting, so the
    /// next submit started a second drain alongside it. Measured six running
    /// at once. Ownership of the queue now belongs to this loop until it finds
    /// the queue empty, so there is exactly one delivery in flight whatever
    /// else happens; `invalidate()` empties the queue instead, which is what
    /// actually stops the work.
    private func drain() async {
        while true {
            let next: DeviceObservation? = state.withLock { s in
                guard let entry = s.pending.first else {
                    s.isDraining = false
                    return nil
                }
                s.pending.removeValue(forKey: entry.key)
                // Recorded as forwarded *before* it is delivered, not after.
                //
                // Delivery is async. Recording it afterwards left a window in
                // which an identical observation arriving mid-delivery saw no
                // forwarded value, judged itself news, and was queued and sent
                // again — so a busy moment forwarded the same reading twice.
                s.forwarded[entry.key] = entry.value
                s.lastForwardedAt[entry.key] = entry.value.observedAt
                return entry.value
            }
            guard let next else { return }
            await deliver(next)
        }
    }

    /// Drops everything queued. Called when a provider stops.
    ///
    /// Deliberately leaves `isDraining` alone: a delivery already awaiting is
    /// in the catalogue's hands and is a reading that really was observed, so
    /// letting it land is harmless — whereas releasing the flag under it
    /// allowed a second drain to start in parallel. The draining loop finds
    /// the queue empty on its next turn and retires itself.
    ///
    /// The forwarded history is cleared too, so a provider that starts again
    /// reports its first sighting rather than comparing against what a
    /// previous session had seen.
    public func invalidate() {
        state.withLock { s in
            s.pending.removeAll()
            s.forwarded.removeAll()
            s.lastForwardedAt.removeAll()
        }
    }

    /// Forgets a device entirely — for a record the user removed.
    public func forget(_ id: DeviceIdentity) {
        state.withLock { s in
            s.pending[id] = nil
            s.forwarded[id] = nil
            s.lastForwardedAt[id] = nil
        }
    }

    // MARK: - Tests

    var pendingCount: Int { state.withLock { $0.pending.count } }

    /// How many devices this mailbox is remembering. The number that must not
    /// grow when an identifier rotates.
    var trackedDeviceCount: Int {
        state.withLock { Set($0.forwarded.keys).union($0.lastForwardedAt.keys).count }
    }
    var isDraining: Bool { state.withLock { $0.isDraining } }
}
