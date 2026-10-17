/// One level, as the thing every surface draws.
///
/// The card, the hover panel and the ears each had their own idea of what a
/// level looks like and what exists: the panel listed every output and every
/// display, the card showed one output and whichever display the pointer
/// happened to be on, and the ears showed a glyph and a stub. Three drawings
/// of one number, free to disagree.
///
/// So: a row is a name, a value and a line, and the ears are the row with the
/// words taken off. Built in the shell, which is the only layer that can ask
/// the hardware anything, and drawn in `LedgeUI`, which cannot.
public struct LevelRow: Identifiable, Equatable, Sendable {

    /// What this row is for. The card groups sound apart from light.
    public enum Kind: Equatable, Sendable {
        case sound
        case display
        case keyboard
    }

    /// What the row can do, which is not always "be dragged".
    public enum Control: Equatable, Sendable {
        /// A level that can be set. The value is what the *device* reports.
        case level(Double)
        /// A level the device reports and nothing can change — HDMI and some
        /// USB interfaces have no volume macOS can set. No line to drag, a
        /// dashed rule in its place.
        case fixed
        /// Nothing could be read. A dash rather than a plausible 50%, which
        /// is what the provider used to publish for an unreadable level.
        case unreadable
    }

    public let id: String
    public let kind: Kind
    /// The device's own name, which is what the user recognises. "Sound" only
    /// when there is no device to name.
    public var name: String
    public var control: Control
    /// Muted is a fact about an output, kept apart from a level of zero. The
    /// line stays at the old level as a ghost, so it is clear where unmuting
    /// goes back to.
    public var isMuted: Bool
    /// Whether this row's glyph can toggle mute. Outputs only.
    public var canMute: Bool
    /// Whether pressing the name opens the output list.
    public var canSwap: Bool
    /// The lowest level this row can actually reach, as a fraction.
    ///
    /// Non-zero for an external display, which Ledge dims with a gamma ramp
    /// rather than a backlight: below this the picture is unreadable, so the
    /// controller clamps there. The card draws the unreachable start hatched
    /// and stops the fill at the tick, because a bar that followed the pointer
    /// to zero while the screen sat at 18% was the control lying.
    public var floor: Double
    /// The one thing this row has to say, if anything.
    public var note: Note?

    /// Why a row is not doing what it looks like it should.
    ///
    /// One per row and never card-level, because every fact here is about one
    /// device. Ordered by recency where two could be true: what just happened
    /// first, then what is standing.
    public enum Note: Equatable, Sendable {
        /// The last change was refused outright.
        case refused
        /// Some channels took it and some did not.
        case partial
        /// Software-dimmed, with a floor.
        case gamma(floor: Double)
        /// The volume is set on the device itself.
        case fixedElsewhere
        /// Nothing could be read.
        case unreadable
        /// The screen sets its own brightness: Sidecar, AirPlay.
        case setsItsOwn
        /// The private interface this needs has moved.
        case unavailable
        /// There is no output device at all.
        case noOutput
    }

    public init(
        id: String,
        kind: Kind,
        name: String,
        control: Control,
        isMuted: Bool = false,
        canMute: Bool = false,
        canSwap: Bool = false,
        floor: Double = 0,
        note: Note? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.control = control
        self.isMuted = isMuted
        self.canMute = canMute
        self.canSwap = canSwap
        self.floor = floor
        self.note = note
    }

    /// The level to draw, or nil when there is no line.
    public var drawnLevel: Double? {
        guard case .level(let value) = control else { return nil }
        return value
    }

    /// What the value column shows: a number, a word, or a dash.
    public var valueText: String {
        switch control {
        case .level(let value): "\(Int((value * 100).rounded()))"
        case .fixed: "Fixed"
        case .unreadable: "—"
        }
    }

    /// Whether a drag or a scroll can move this row at all.
    public var isAdjustable: Bool {
        if case .level = control { return true }
        return false
    }

    /// Where a gesture's fraction actually lands, once the row's own floor has
    /// had its say. The number shown is this, never the pointer's.
    public func clamped(_ fraction: Double) -> Double {
        min(1, max(floor, fraction))
    }
}
