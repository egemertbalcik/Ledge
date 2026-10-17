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

    /// Whether the last reading was of a camera Ledge was sharing. Part of
    /// what counts as a change: it moves while the hardware reading does not.
    private var lastShared = false
    /// Whether a card is actually on screen. Without this, an idle machine
    /// retracts an activity that was never published — harmless in the queue,
    /// but it is a lie in the event stream and it fires on every safety poll.
    private var isPublished = false

    /// How many of the running cameras are somebody else's.
    ///
    /// The rule itself is `CameraCover`, which is pure and tested; this is
    /// only where it is kept.
    ///
    /// macOS's own green dot still shows throughout, as it must.
    private var cover = CameraCover()

    /// The wait for one honest reading after Ledge's own session stops.
    private var uncovering: Task<Void, Never>?

    /// How long the fresh reading is given before the watcher is believed
    /// anyway. A capture session takes a moment to let go, and the watcher
    /// has a window of its own on top of that. Injectable so a test need not
    /// wait out a real second.
    private let uncoverGrace: TimeInterval

    /// Whether another application is also reading the camera Ledge has
    /// open. Asked on every reading while the self-view is up, because the
    /// answer changes when a meeting app starts — which is the moment the
    /// card must stop being quiet.
    private let sharedWithAnotherApp: () -> Bool

    public init(
        source: any RecordingSource,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        uncoverGrace: TimeInterval = 1,
        sharedWithAnotherApp: @escaping () -> Bool = { false }
    ) {
        self.source = source
        self.now = now
        self.uncoverGrace = uncoverGrace
        self.sharedWithAnotherApp = sharedWithAnotherApp
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
        uncovering?.cancel()
        uncovering = nil
        cover.closed()
        source.stopWatching()
        continuation?.finish()
        continuation = nil
        lastSeen = nil
        lastShared = false
        isPublished = false
    }

    /// Ledge's self-view went on screen, or left it.
    ///
    /// Three rules keep the quiet honest, and they are all here:
    ///
    /// - It covers exactly one camera: Ledge's. A camera that was already
    ///   running when the self-view opened, or one that starts while it is
    ///   open, is somebody else's, and the card goes on saying so.
    /// - It ends when the picture leaves the screen — but not on the same
    ///   breath. Ledge's own session takes a moment to stop, and the watcher
    ///   has a window on top of that, so the cover is held until one fresh
    ///   reading comes back without a camera, or a second has passed. That is
    ///   what makes a meeting app taking the camera at Join read correctly as
    ///   "Camera in use" rather than as Ledge's own leftovers.
    /// - The microphone is never covered. It is not what the picture shows.
    /// - Parameter device: the unique ID of the camera Ledge opened, when it
    ///   is on screen. Nil means Ledge cannot name what it has, in which case
    ///   nothing is covered — an unnameable camera is one Ledge cannot claim.
    public func selfViewChanged(_ onScreen: Bool, device: String? = nil) {
        uncovering?.cancel()
        uncovering = nil
        guard onScreen else {
            uncovering = Task { @MainActor [weak self] in
                guard let self else { return }
                // Counted in polls rather than measured against `now`: the
                // clock here is injectable and a fixed one never reaches a
                // deadline, which would hold the cover open forever — the
                // exact failure that would silence a real camera handover.
                let polls = max(1, Int((self.uncoverGrace / 0.1).rounded()))
                for _ in 0..<polls {
                    if Task.isCancelled { return }
                    if !self.source.current().camera { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { return }
                self.cover.closed()
                self.uncovering = nil
                // Re-read rather than wait for the next event: the camera may
                // have changed hands while Ledge held it, and nothing else
                // will say so.
                self.lastSeen = nil
                self.lastShared = false
                self.changed()
            }
            return
        }
        cover.opened(ours: device)
        // Something may already have been running, in which case what the
        // card should say has just changed.
        lastSeen = nil
        lastShared = false
        changed()
    }

    /// Waits for the fresh reading the cover is holding out for.
    ///
    /// For tests, and for them alone: nothing in the app waits on this. It
    /// exists because the alternative — a test that sleeps for longer than
    /// the grace and hopes — passes alone and fails in a loaded suite, which
    /// is the kind of test that teaches people to ignore a red run.
    func settleCover() async {
        await uncovering?.value
    }

    /// Takes a fresh reading now.
    ///
    /// The watcher's own safety poll does this every few seconds; this is the
    /// same door, for a caller that knows something has moved — a test, and
    /// the uncover above.
    public func recheck() {
        changed()
    }

    private func changed() {
        let reading = source.current()
        // Whether somebody else is on Ledge's own camera is asked *before*
        // the dedupe below, and counted as part of what changed.
        //
        // It is a fact about the same running device, so the hardware
        // reading is identical either way: asked afterwards, a meeting app
        // taking the camera Ledge is showing would have been skipped by a
        // guard that saw no change, and the card would have gone on hiding
        // it for as long as the preview lasted.
        let shared = cover.isCovering && sharedWithAnotherApp()
        // The safety poll fires every few seconds; only a real change publishes.
        guard reading != lastSeen || shared != lastShared else { return }
        lastSeen = reading
        lastShared = shared

        // What the card is allowed to say. The microphone passes through
        // untouched; the camera Ledge opened is accounted for by name, and
        // nobody else's is.
        let others = cover.reportable(running: reading.cameraIDs, oursIsShared: shared)
        let state = RecordingState(
            camera: !others.isEmpty,
            microphone: reading.microphone,
            cameraIDs: others
        )

        guard state.isActive else {
            if isPublished {
                continuation?.yield(.retract(Self.activityID))
                isPublished = false
            }
            return
        }
        isPublished = true

        // Who holds the microphone is logged by the watcher, from the one
        // enumeration it already does. Naming them here meant a second sweep
        // of every audio process — milliseconds of main-thread work — purely
        // to write a log line.
        Self.log.notice("""
            recording: camera=\(state.camera, privacy: .public) \
            mic=\(state.microphone, privacy: .public)
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
