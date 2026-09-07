import Foundation
import LedgeCore
import LedgeSystem
import os

/// Turns Focus changes into activities.
///
/// Transitions again: switching a Focus on or off is news for a few seconds;
/// being in one all afternoon is not something to occupy the queue with.
@MainActor
public final class FocusProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "focus")

    public let identifier = "focus"

    static let lifetime: TimeInterval = 5

    private let source: any FocusSource
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var previous: FocusSnapshot?

    public init(
        source: any FocusSource,
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
            // Baseline, not news: a Focus already on at launch is something the
            // user did, not something that just happened.
            self.previous = self.source.current()
            self.source.startWatching { [weak self] in self?.changed() }
        }
    }

    public func stop() {
        source.stopWatching()
        continuation?.finish()
        continuation = nil
        previous = nil
    }

    private func changed() {
        let current = source.current()
        // The directory watcher fires for every file in the database, most of
        // which are bookkeeping. Only an actual mode change is worth showing.
        guard current != previous else { return }
        let before = previous
        previous = current

        switch (before, current) {
        case (_, .some(let mode)):
            publish(mode, isActive: true)
        case (.some(let mode), nil):
            publish(mode, isActive: false)
        case (nil, nil):
            break
        }
    }

    private func publish(_ mode: FocusSnapshot, isActive: Bool) {
        Self.log.debug("""
            focus \(isActive ? "on" : "off", privacy: .public): \
            \(mode.identifier, privacy: .public)
            """)
        continuation?.yield(.publish(Activity(
            // One slot for all Focus news: a rapid on→off must replace the
            // card, not stack a second one behind it.
            id: ActivityID(kind: .focus, source: "system"),
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .focus(FocusPayload(
                name: mode.name,
                symbolName: mode.symbolName,
                isActive: isActive
            ))
        )))
    }
}
