import Foundation
import LedgeCore
import LedgeSystem
import os

/// Shows a dot while the camera or microphone is live.
///
/// A standing card, not a transient one: it appears the moment something starts
/// recording and stays for as long as it does, because "is my camera on right
/// now?" is a question you want answered continuously, not for five seconds.
///
/// macOS draws its own indicator in the menu bar and that cannot be suppressed —
/// this is additive, sitting in the notch where the eye already is.
@MainActor
public final class PrivacyProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "privacy")

    public let identifier = "privacy"

    static let activityID = ActivityID(kind: .privacy, source: "system")

    private let source: any RecordingSource
    private let now: () -> TimeInterval
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var lastSeen: RecordingState?
    /// Whether a card is actually on screen. Without this, an idle machine
    /// retracts an activity that was never published — harmless in the queue,
    /// but it is a lie in the event stream and it fires on every safety poll.
    private var isPublished = false

    public init(
        source: any RecordingSource,
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
            // The source delivers on the main actor, through its mailbox.
            self.source.startWatching { [weak self] in
                MainActor.assumeIsolated { self?.changed() }
            }
            // Something already recording at launch is still worth showing —
            // unlike a Focus mode, an active camera is not a settled fact the
            // user chose and forgot.
            self.changed()
        }
    }

    public func stop() {
        source.stopWatching()
        continuation?.finish()
        continuation = nil
        lastSeen = nil
        isPublished = false
    }

    private func changed() {
        let state = source.current()
        // The safety poll fires every few seconds; only a real change publishes.
        guard state != lastSeen else { return }
        lastSeen = state

        guard state.isActive else {
            if isPublished {
                continuation?.yield(.retract(Self.activityID))
                isPublished = false
            }
            return
        }
        isPublished = true

        // The holders are named because the indicator is only as trustworthy
        // as the thing it points at, and a wrong one is worth being able to
        // diagnose from a log rather than a guess.
        Self.log.notice("""
            recording: camera=\(state.camera, privacy: .public) \
            mic=\(state.microphone, privacy: .public) \
            holders=[\(SystemRecordingSource.inputHolders().joined(separator: ", "), privacy: .public)]
            """)
        continuation?.yield(.publish(Activity(
            id: Self.activityID,
            createdAt: now(),
            // Standing: it must not time out while the camera is still on.
            expiresAfter: nil,
            payload: .privacy(PrivacyPayload(
                cameraActive: state.camera,
                micActive: state.microphone
            ))
        )))
    }
}
