import Foundation
import LedgeCore

/// A source of activities.
///
/// `@MainActor` on purpose. Real system sources do their polling and IOKit work
/// on background queues or inside an actor, but they hand results across as
/// `Sendable` values and publish from the main actor. Keeping the *protocol*
/// main-actor-bound means the hub, the queue, and the UI are all on one actor,
/// so there is no place for a data race to hide under Swift 6 checking.
@MainActor
public protocol ActivityProvider: AnyObject {

    /// Stable name, used in logs, to attribute events, and to enable or disable
    /// this provider at runtime.
    var identifier: String { get }

    /// Begins producing. Called once per enable; the stream ends on `stop()`.
    func start() -> AsyncStream<ProviderEvent>

    func stop()
}

/// Merges every provider into one stream and applies it to a queue.
///
/// One consumer, one queue, one actor: providers cannot reorder each other's
/// events or race on the selection.
@MainActor
public final class ProviderHub {

    public private(set) var queue = ActivityQueue()

    private struct Entry {
        let provider: any ActivityProvider
        var task: Task<Void, Never>?
        var generation: UUID?

        /// Ids this provider currently has standing in the queue.
        ///
        /// Maintained here rather than asked of the provider. The consume loop
        /// is the only place that sees both the event and who produced it, so
        /// tracking it here is exact and automatic — whereas making every
        /// provider maintain its own set means every provider can get it wrong,
        /// and one that does leaves cards stranded on screen.
        var published: Set<ActivityID> = []

        var isRunning: Bool { task != nil }
    }

    /// Keyed by identifier rather than held in flat arrays, so an individual
    /// provider can be switched off without disturbing the others.
    private var entries: [String: Entry] = [:]

    /// Registration order, so startup is deterministic.
    private var order: [String] = []

    /// Called after every applied event so the shell can re-render and
    /// reschedule expiry.
    public var onChange: (ActivityQueue) -> Void = { _ in }

    public init() {}

    public var registeredIdentifiers: Set<String> { Set(entries.keys) }
    public var runningIdentifiers: Set<String> { Set(entries.filter(\.value.isRunning).keys) }

    /// Registers a provider, replacing any existing one with the same
    /// identifier — stopping and retracting the old one first, so re-enabling
    /// cannot strand the previous instance in the table.
    public func add(_ provider: any ActivityProvider) {
        if entries[provider.identifier] != nil { remove(provider.identifier) }
        entries[provider.identifier] = Entry(provider: provider)
        order.append(provider.identifier)
    }

    /// Starts every registered provider that is not already running.
    ///
    /// Idempotent per provider, so a provider added after startup — the media
    /// source, which waits on an async capability probe — still gets started
    /// without double-subscribing the ones already going.
    public func start() {
        for identifier in order { start(identifier) }
    }

    /// Starts one provider by identifier, if it is registered and idle.
    public func start(_ identifier: String) {
        guard var entry = entries[identifier], !entry.isRunning else { return }
        let generation = UUID()
        entry.generation = generation
        let stream = entry.provider.start()
        entry.task = Task { @MainActor [weak self] in
            for await event in stream {
                // A yielded value may already have resumed this task before
                // removal or restart cancelled it. Only the current run owns
                // the right to mutate the queue and attribution.
                guard !Task.isCancelled, let self,
                      self.entries[identifier]?.generation == generation else { return }
                self.record(event, from: identifier)
                self.queue.apply(event)
                self.onChange(self.queue)
            }
        }
        entries[identifier] = entry
    }

    /// Stops one provider and takes its activities off screen.
    ///
    /// The retraction is the point. Cancelling the stream only stops *new*
    /// events; without this, a card belonging to a provider the user just
    /// switched off would stay up forever, with nothing able to update or
    /// remove it.
    ///
    /// `retract`, not `dismiss`: a disabled provider's cards must not come back
    /// via undo.
    /// The live instance behind an id, for callers that need to poke a
    /// provider (a weather refresh on wake) without tearing it down — removal
    /// retracts the standing card, which is exactly what a refresh must not do.
    public func provider(for identifier: String) -> (any ActivityProvider)? {
        entries[identifier]?.provider
    }

    public func remove(_ identifier: String) {
        guard let entry = entries[identifier] else { return }

        entry.task?.cancel()
        entry.provider.stop()
        entries[identifier] = nil
        order.removeAll { $0 == identifier }

        // Two providers may legitimately publish the same id — a fixture
        // scenario and the real battery provider both own (power, "internal").
        // Only retract what nobody else is still standing behind.
        let claimedElsewhere = entries.values.reduce(into: Set<ActivityID>()) {
            $0.formUnion($1.published)
        }
        let orphaned = entry.published.subtracting(claimedElsewhere)

        guard !orphaned.isEmpty else { return }
        // One batch, one notification: retracting individually would re-sync
        // the presentation N times and report the queue empty mid-batch.
        for id in orphaned { queue.retract(id) }
        onChange(queue)
    }

    public func stop() {
        for identifier in order {
            entries[identifier]?.task?.cancel()
            entries[identifier]?.task = nil
            entries[identifier]?.generation = nil
            entries[identifier]?.provider.stop()
        }
    }

    private func record(_ event: ProviderEvent, from identifier: String) {
        switch event {
        case .publish(let activity): entries[identifier]?.published.insert(activity.id)
        case .retract(let id): entries[identifier]?.published.remove(id)
        }
    }

    /// Queue mutations that come from the user rather than a provider.
    public func mutate(_ body: (inout ActivityQueue) -> Void) {
        body(&queue)
        onChange(queue)
    }
}
