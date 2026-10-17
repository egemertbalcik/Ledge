import Foundation
import LedgeCore

/// The notch's half of a permission granted in another application.
///
/// While somebody is in System Settings on Ledge's behalf, the notch rests a
/// lock in its ears and says what it is waiting for. That matters more here
/// than it would in any ordinary app: Ledge is an accessory with no Dock icon
/// and no Cmd-Tab entry, so the window that sent them there cannot be found
/// again by the usual means — and the notch is the one piece of Ledge that is
/// always in the same place. When the grant lands, the notch says so, where it
/// is seen even with System Settings still in front.
///
/// A provider rather than a card published from the coordinator, because the
/// queue's rules are the whole point: the message rests in the ears (nothing
/// with no expiry leaves on its own), the arrival announces itself like any
/// other news, and a provider that goes away takes its cards with it.
@MainActor
public final class HandoffProvider: ActivityProvider {

    public static let identifierValue = "handoff"
    public let identifier = HandoffProvider.identifierValue

    /// The one card this ever has up. Its source, so the shell can recognise
    /// it in `presentation.selected` — a click on it brings the window back
    /// instead of opening a card with nothing to press.
    public static let waitingSource = "handoff-waiting"
    public static let arrivedSource = "handoff-arrived"

    public static let waitingID = ActivityID(kind: .message, source: waitingSource)
    public static let arrivedID = ActivityID(kind: .message, source: arrivedSource)

    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private let now: () -> TimeInterval

    public init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
        }
    }

    public func stop() {
        continuation?.finish()
        continuation = nil
    }

    /// Rests the lock in the ears. No expiry: it stays until the grant
    /// arrives, until Stop Waiting, or until the watch ends — all three of
    /// which call `clear()`.
    public func waiting(for name: String) {
        publish(
            id: Self.waitingID,
            MessagePayload(
                title: PermissionGuideCopy.waitingTitle(name),
                body: PermissionGuideCopy.waitingDetail,
                symbolName: "lock"
            ),
            expiresAfter: nil
        )
    }

    /// Says the grant landed, then goes.
    ///
    /// - Parameter detail: what it changed, in the words of the thing that
    ///   changed. Only Accessibility has anything to show for itself the
    ///   moment it is granted.
    public func arrived(_ name: String, detail: String, holding seconds: TimeInterval) {
        continuation?.yield(.retract(Self.waitingID))
        publish(
            id: Self.arrivedID,
            MessagePayload(
                title: PermissionGuideCopy.arrivedTitle(name),
                body: detail,
                symbolName: "checkmark.circle"
            ),
            expiresAfter: seconds
        )
    }

    /// Takes the lock out of the ears.
    ///
    /// The arrival card is deliberately left alone: it has an expiry, it is
    /// news that happens to be true, and every ending that calls this runs
    /// *after* a grant has been announced. Retracting it here made the card
    /// depend on the order two things happened in, which is not a thing to
    /// rest a sentence on.
    public func clear() {
        continuation?.yield(.retract(Self.waitingID))
    }

    private func publish(id: ActivityID, _ message: MessagePayload, expiresAfter: TimeInterval?) {
        continuation?.yield(.publish(Activity(
            id: id,
            createdAt: now(),
            expiresAfter: expiresAfter,
            payload: .message(message)
        )))
    }
}
