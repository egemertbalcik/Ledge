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

    /// A glance: a short code registers instantly, and anything longer left the
    /// card hanging around after the user had already started typing.
    static let lifetime: TimeInterval = 1.0

    private let source: any KeyboardLayoutWatching
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    /// The layout last seen. Nil when the baseline found none.
    private var lastSeen: KeyboardLayoutSnapshot?

    /// Whether `start()` has read its baseline. Kept apart from `lastSeen`,
    /// because the baseline can be *nothing* — TIS not ready yet at login, a
    /// source with no name — and read off `lastSeen == nil`, that launch took
    /// the first real switch for its baseline and never showed it.
    private var hasBaseline = false

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
            hasBaseline = true
            source.startWatching { [weak self] in self?.changed() }
        }
    }

    public func stop() {
        source.stopWatching()
        continuation?.finish()
        continuation = nil
        lastSeen = nil
        hasBaseline = false
    }

    private func changed() {
        // A reading with no baseline to compare against is not a switch.
        guard hasBaseline, let snapshot = source.current() else { return }
        // Only a real switch, which is a different source. The notification
        // can fire for input-source list changes that leave the selection
        // alone, and a list change can move the *code* under the same source —
        // Turkish Q goes from TR to TRQ the moment Turkish F is added — which
        // is not a switch either.
        guard snapshot.name != lastSeen?.name else { return }
        lastSeen = snapshot

        continuation?.yield(.publish(Activity(
            id: ActivityID(kind: .keyboard, source: "input"),
            createdAt: now(),
            expiresAfter: Self.lifetime,
            payload: .keyboard(KeyboardLayoutPayload(name: snapshot.name, code: snapshot.code))
        )))
    }
}
