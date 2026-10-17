import Foundation
import LedgeCore
import LedgeSystem

/// Publishes the standing "Levels" card: sound and brightness sliders in the
/// cycle, so both can be adjusted with nothing but the mouse.
///
/// The card pulls live values through its actions when it opens; the payload
/// is only the compact ear's snapshot. Volume changes republish (CoreAudio
/// tells us for free); brightness is re-read on those same beats rather than
/// polled on its own clock — the ear shows a glyph and the volume percent, so
/// a stale brightness snapshot costs nothing visible.
@MainActor
public final class LevelsProvider: ActivityProvider {

    public let identifier = "levels"

    public static let activityID = ActivityID(kind: .levels, source: "levels")

    private let volume: VolumeController
    private let brightness: () -> Double
    private let now: () -> TimeInterval
    /// Every level there is, as rows.
    ///
    /// Supplied by the shell, which is the only layer that can ask the
    /// hardware anything. Empty by default so a provider built without one is
    /// still the provider it was — the two scalars are what the ears and the
    /// satellite read, and they do not need a list.
    private let rows: () -> [LevelRow]
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    public init(
        volume: VolumeController = VolumeController(),
        brightness: @escaping () -> Double = {
            BrightnessController().level() ?? 0.5
        },
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        rows: @escaping () -> [LevelRow] = { [] }
    ) {
        self.volume = volume
        self.brightness = brightness
        self.now = now
        self.rows = rows
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            volume.onChange = { [weak self] readout in
                // The readout carries the mute state; muting does not move the
                // scalar, so it is the only thing that says the Mac went quiet.
                self?.publish(volume: readout.level, isMuted: readout.isMuted)
            }
            volume.startWatching()
            let readout = volume.readout()
            publish(volume: readout?.level ?? 0.5, isMuted: readout?.isMuted ?? false)
        }
    }

    /// Publishes again with whatever the hardware now says.
    ///
    /// CoreAudio tells this provider when the volume moves; nothing tells it
    /// when the *brightness* does, because brightness has no change
    /// notification and is polled by the surface that needs it. So the shell
    /// asks, and only while the card is actually open — which is the one case
    /// where a brightness key has to move a bar that is already on screen.
    public func republish() {
        let readout = volume.readout()
        publish(volume: readout?.level ?? lastVolume, isMuted: readout?.isMuted ?? lastMuted)
    }

    private var lastVolume: Double = 0.5
    private var lastMuted = false

    public func stop() {
        volume.stopWatching()
        volume.onChange = { _ in }
        continuation?.finish()
        continuation = nil
    }

    private func publish(volume level: Double, isMuted: Bool) {
        lastVolume = level
        lastMuted = isMuted
        // The rows travel with the publish, so the card's *first* frame is
        // already right. Pulled on open instead, the card drew with no rows
        // at all, the island sized itself to that, and the fill a moment later
        // made it jump — an opening animation that landed in the wrong place
        // and then corrected itself, every single time.
        let rows = rows()
        continuation?.yield(.publish(Activity(
            id: Self.activityID,
            createdAt: now(),
            // Standing: the card is a control surface, present for as long as
            // the provider runs.
            expiresAfter: nil,
            payload: .levels(LevelsPayload(
                volume: min(max(level, 0), 1),
                brightness: min(max(brightness(), 0), 1),
                isMuted: isMuted,
                rows: rows
            ))
        )))
    }
}
