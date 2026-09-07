import Foundation
import LedgeCore
import LedgeSystem

/// Announces keyboard-layout switches.
///
/// macOS marks a switch with a small flag in the menu bar, which is easy to miss
/// and easy to misread — the common failure is typing a whole sentence before
/// noticing the layout changed. This puts the new layout where the eyes already
/// are, briefly, and then gets out of the way.
///
/// The first reading after `start()` is deliberately *not* published: at launch
/// there has been no switch, and announcing the layout you were already using
/// would be noise on every login.
@MainActor
public final class KeyboardLayoutProvider: ActivityProvider {

    public let identifier = "keyboard"

    /// A glance: two letters register instantly, and anything longer left the
    /// card hanging around after the user had already started typing.
    static let lifetime: TimeInterval = 1.0

    private let source: any KeyboardLayoutWatching
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    /// The layout last seen. Starts unset so the first observation only
    /// establishes a baseline.
    private var lastSeen: KeyboardLayoutSnapshot?

    public init(
        source: any KeyboardLayoutWatching = KeyboardLayoutSource(),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            lastSeen = source.current()
            source.startWatching { [weak self] in self?.changed() }
        }
    }

    public func stop() {
        source.stopWatching()
        continuation?.finish()
        continuation = nil
        lastSeen = nil
    }

    private func changed() {
        guard let snapshot = source.current() else { return }
        // Only a real switch. The notification can fire for input-source list
        // changes that leave the selection alone.
        guard snapshot != lastSeen else { return }
        let isFirstObservation = lastSeen == nil
        lastSeen = snapshot
        guard !isFirstObservation else { return }

        continuation?.yield(.publish(Activity(
            id: ActivityID(kind: .keyboard, source: "input"),
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .keyboard(KeyboardLayoutPayload(name: snapshot.name, code: snapshot.code))
        )))
    }
}
