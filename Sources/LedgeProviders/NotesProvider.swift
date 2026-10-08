import Foundation
import LedgeCore
import LedgeSystem
import os

/// Publishes the notes card.
///
/// A standing card, and the quietest one in the app. Unlike the shelf it does
/// **not** retract when it is empty: the card is how a note gets made, so
/// withdrawing it when there are no notes would take away the only way to
/// write the first one.
@MainActor
public final class NotesProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "notes")

    public let identifier = "notes"

    public static let activityID = ActivityID(kind: .notes, source: "user")

    private let store: NotesStore
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    /// Which note the editor window has open, so the card can mark it.
    private var openNoteID: String?

    public init(
        store: NotesStore,
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.store.setOnChange { [weak self] in
                    Task { @MainActor [weak self] in self?.republish() }
                }
                self.republish()
            }
        }
    }

    public func stop() {
        let store = self.store
        Task { await store.setOnChange(nil) }
        continuation?.finish()
        continuation = nil
        openNoteID = nil
    }

    /// Told by the shell which note is being written, so the card can show it.
    public func setOpenNote(_ id: String?) {
        guard openNoteID != id else { return }
        openNoteID = id
        republish()
    }

    private func republish() {
        let store = self.store
        let open = openNoteID
        Task { @MainActor [weak self] in
            let notes = await store.list()
            guard let self, self.continuation != nil else { return }
            self.continuation?.yield(.publish(Activity(
                id: Self.activityID,
                createdAt: self.now(),
                // No expiry: a container, not news.
                expiresAfter: nil,
                payload: .notes(NotesPayload(notes: notes, openNoteID: open))
            )))
        }
    }
}
