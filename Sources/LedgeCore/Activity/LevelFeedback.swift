import Foundation

/// What the hardware says a level write actually produced.
///
/// Returned to the views that set a level so they draw the device's answer
/// rather than the gesture's. A device is free to clamp a scalar to its
/// nearest supported step or to refuse it outright; a bar that moves when
/// nothing moved is the control lying, and the lie lasts until the next poll
/// corrects it.
///
/// In `LedgeCore` so `LedgeUI` can take it without seeing the audio layer.
public struct LevelFeedback: Equatable, Sendable {

    /// The level the device now reports, 0...1.
    public let level: Double

    /// Whether it should be drawn as muted — the user's own mute, not silence
    /// at a level of zero. See `MuteIntent`.
    public let isMuted: Bool

    public init(level: Double, isMuted: Bool) {
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        self.isMuted = isMuted
    }
}
