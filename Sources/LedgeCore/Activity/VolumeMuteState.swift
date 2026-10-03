import Foundation

/// Why an output is silent, which is two different questions wearing one
/// CoreAudio property.
///
/// A scalar of zero is not silence — it is the quietest *gain* a device has.
/// Measured on this Mac's speakers: scalar 0.0625 is −47.6 dB and scalar
/// 0.0000 is −63.5 dB, which is quiet and still playing. So reaching zero has
/// to set the mute property, or "all the way down" is not down.
///
/// But the red muted state is an answer to the mute key, not to the volume
/// keys. Somebody who turned the sound down to nothing has not muted their
/// Mac, and must not be told they did; somebody who pressed mute has, and must
/// see it — including while the level sits at zero, where the device was
/// already silent for the other reason.
///
/// Two intents, then, and the device property is derived from them rather than
/// used as the state:
///
/// | level | user pressed mute | device muted | shows red |
/// |---|---|---|---|
/// | 0     | no  | yes | no  |
/// | 0     | yes | yes | yes |
/// | > 0   | no  | no  | no  |
/// | > 0   | yes | yes | yes |
public struct VolumeMuteState: Equatable, Sendable {

    /// Whether the user has asked for mute, by the key or the menu.
    public let userMuted: Bool

    /// The level the output is at, 0...1.
    public let level: Double

    public init(userMuted: Bool, level: Double) {
        self.userMuted = userMuted
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
    }

    /// What the device's mute property should be: silence at zero, and
    /// whatever the user asked for above it.
    public var deviceMuted: Bool { userMuted || level <= 0 }

    /// What the interface shows. Only the user's own mute is red.
    public var showsMuted: Bool { userMuted }
}
