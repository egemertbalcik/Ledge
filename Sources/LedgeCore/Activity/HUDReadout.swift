import Foundation

/// A level readout: what the volume or brightness just became.
///
/// Not an `Activity`. The HUD is transient and preempts whatever is on screen,
/// which is a phase concern rather than a queue one — putting it in the queue
/// would mean it could be cycled to, dismissed, or left sitting behind two
/// other cards, none of which make sense for something that should flash and go.
public struct HUDReadout: Equatable, Sendable {

    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case volume
        case brightness
        case keyboardBacklight

        /// The label shown beside the icon, matching the macOS HUD's own naming.
        public var label: String {
            switch self {
            case .volume: "Sound"
            case .brightness: "Brightness"
            case .keyboardBacklight: "Keyboard"
            }
        }
    }

    public let kind: Kind

    /// 0...1.
    public let level: Double

    /// Only meaningful for `.volume`.
    public let isMuted: Bool

    /// Where the level applies — the output device's name for volume ("AirPods
    /// Pro", "MacBook Air Speakers"). The panel shows it instead of a generic
    /// "Sound" when known.
    public let deviceName: String?

    public init(kind: Kind, level: Double, isMuted: Bool = false, deviceName: String? = nil) {
        self.kind = kind
        self.deviceName = deviceName
        // `min`/`max` do not clamp NaN — every comparison against NaN is false,
        // so the value passes straight through. `percentage` would then trap
        // converting NaN to `Int`, taking the whole app down over a bad reading
        // from an audio device. Check finiteness explicitly.
        self.level = level.isFinite ? min(max(level, 0), 1) : 0
        self.isMuted = isMuted
    }

    public var percentage: Int {
        Int((level * 100).rounded())
    }

    /// The glyph for this readout, chosen by level so the icon fills up the way
    /// the system's does.
    public var symbolName: String {
        switch kind {
        case .volume:
            return Self.volumeSymbol(level: level, isMuted: isMuted)
        case .brightness:
            return Self.brightnessSymbol(level: level)
        case .keyboardBacklight:
            return level <= 0 ? "keyboard" : "keyboard.fill"
        }
    }

    /// The speaker ladder: silent, then one, two, three waves.
    ///
    /// Shared with the Levels card, which drew the same ladder from its own
    /// copy — two definitions of one idea, free to disagree.
    public static func volumeSymbol(level: Double, isMuted: Bool) -> String {
        if isMuted || level <= 0 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// The sun ladder: short rays, then long rays, both filled.
    ///
    /// Two rungs by the owner's decision — the outlined sun that once held the
    /// dimmest quarter read as a different *kind* of glyph rather than a dimmer
    /// one. Both rungs are solid, so only the rays change, and the bar beside
    /// them carries the precision. The cut is the speaker's own middle, so the
    /// two bars step together.
    public static func brightnessSymbol(level: Double) -> String {
        level < 0.5 ? "sun.min.fill" : "sun.max.fill"
    }
}
