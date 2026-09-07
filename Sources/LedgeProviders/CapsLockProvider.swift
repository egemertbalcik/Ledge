import Foundation
import LedgeCore
import LedgeSystem

/// Announces Caps Lock toggles as a micro-peek.
///
/// The keyboard-layout payload carries it: a name and a symbol are exactly
/// what the toggle needs, and the compact ear already knows how to draw them.
@MainActor
public final class CapsLockProvider: ActivityProvider {

    public let identifier = "capslock"

    /// A glance, not an announcement — shorter than the layout switch's card.
    static let lifetime: TimeInterval = 1.6

    private let source: any CapsLockWatching
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    public init(
        source: any CapsLockWatching = CapsLockSource(),
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
            self.source.startWatching { [weak self] isOn in
                self?.announce(isOn)
            }
        }
    }

    public func stop() {
        source.stopWatching()
        continuation?.finish()
        continuation = nil
    }

    private func announce(_ isOn: Bool) {
        continuation?.yield(.publish(Activity(
            id: ActivityID(kind: .keyboard, source: "capslock"),
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .keyboard(KeyboardLayoutPayload(
                name: isOn ? "Caps Lock On" : "Caps Lock Off",
                code: "⇪",
                // Two different silhouettes, not two weights of one: filled
                // and hollow caps arrows were barely tellable apart in the
                // ear. Off shows lowercase letters — "you are typing small
                // again" — which cannot be mistaken for the arrow.
                symbolName: isOn ? "capslock.fill" : "textformat.abc"
            ))
        )))
    }
}
