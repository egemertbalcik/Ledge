import Foundation
import LedgeCore
import LedgeSystem
import os

/// Publishes the file shelf while it holds anything.
///
/// A standing card, like the weather: it appears when the first file is dropped
/// and is retracted the moment the shelf empties, with no expiry in between —
/// files the user parked should stay parked until they take them out.
@MainActor
public final class ShelfProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "shelf")

    public let identifier = "shelf"

    public static let activityID = ActivityID(kind: .shelf, source: "user")

    private let store: ShelfStore
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var isPublished = false

    public init(
        store: ShelfStore,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.store = store
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            self.store.onChange = { [weak self] in self?.republish() }
            // A file may have been deleted while Ledge was closed.
            self.store.pruneMissing()
            self.republish()
        }
    }

    public func stop() {
        store.onChange = {}
        continuation?.finish()
        continuation = nil
        isPublished = false
    }

    private func republish() {
        guard !store.isEmpty else {
            if isPublished {
                continuation?.yield(.retract(Self.activityID))
                isPublished = false
            }
            return
        }

        isPublished = true
        continuation?.yield(.publish(Activity(
            id: Self.activityID,
            createdAt: now(),
            // No expiry: parked files stay until the user removes them.
            expiresAfter: nil,
            payload: .shelf(ShelfPayload(items: store.items))
        )))
    }
}
