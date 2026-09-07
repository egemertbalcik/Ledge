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
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    public init(
        volume: VolumeController = VolumeController(),
        brightness: @escaping () -> Double = {
            BrightnessController().level() ?? 0.5
        },
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.volume = volume
        self.brightness = brightness
        self.now = now
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

    public func stop() {
        volume.stopWatching()
        volume.onChange = { _ in }
        continuation?.finish()
        continuation = nil
    }

    private func publish(volume level: Double, isMuted: Bool) {
        continuation?.yield(.publish(Activity(
            id: Self.activityID,
            createdAt: now(),
            // Standing: the card is a control surface, present for as long as
            // the provider runs.
            expiresAfter: nil,
            payload: .levels(LevelsPayload(
                volume: min(max(level, 0), 1),
                brightness: min(max(brightness(), 0), 1),
                isMuted: isMuted
            ))
        )))
    }
}
