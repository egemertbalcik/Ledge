import Foundation

/// Keeps the last brightness the *user* chose, which is not the one readable
/// when it is needed.
///
/// The value read at the moment the lid closes is nobody's choice. The lid
/// covers the ambient light sensor on its way down, so auto-brightness has
/// already pulled the panel towards nothing before macOS reports the close,
/// and Low Power Mode rescales what is left. Restoring that number hands the
/// user back a panel darker than the one they put down, every single time, and
/// the error compounds over a day of opening and closing.
///
/// So the value is sampled while the lid is up and held: every 30 s, once at
/// session start, and 3 s after each open — the three moments Insomnia samples,
/// and the delay after an open is there because the panel is still on its way
/// back up at the instant the hinge reports it.
///
/// Pure, and a value type: the cadence is the whole of the behaviour and a
/// cadence that can only be checked by waiting half a minute is a cadence
/// nobody checks.
public struct LidBrightnessSampler: Equatable, Sendable {

    /// The resting cadence.
    public static let cadence: TimeInterval = 30
    /// How long after an open the panel is left to come back up.
    public static let settleAfterOpen: TimeInterval = 3

    /// The last level sampled with the lid up, 0...1, or nil if none has been.
    ///
    /// The only value a restore may use. Nothing is ever darkened without one.
    public private(set) var held: Double?

    /// When the next sample is due, or nil when none is.
    private var dueAt: Date?
    /// The lid position of the last reading, so an open can be told from the
    /// steady stream of readings that follow one. The registry notification
    /// this is fed from fires for every power event, not only for the hinge.
    private var lastState: LidState?

    public init(held: Double? = nil) {
        self.held = held
    }

    /// A session started: sample at once, before anything is conserved.
    ///
    /// Without this a session begun 29 s into a cadence would conserve against
    /// a value half a minute stale, and a session begun before the first
    /// sample of all would have nothing to conserve against at all.
    public mutating func sessionBegan(at now: Date) {
        dueAt = now
    }

    /// A reading arrived.
    ///
    /// The first one schedules a sample immediately — there is no open to wait
    /// out, the lid is simply where it is. A later one that moves the lid *to*
    /// open schedules one three seconds out. A lid that closes cancels the
    /// schedule, because a reading taken under a closed lid is the reading
    /// this whole type exists to refuse.
    public mutating func observed(_ reading: LidReading, at now: Date) {
        defer { lastState = reading.state }
        guard let lastState else {
            dueAt = reading.canSampleBrightness ? now : nil
            return
        }
        guard lastState != reading.state else { return }
        dueAt = reading.canSampleBrightness ? now.addingTimeInterval(Self.settleAfterOpen) : nil
    }

    /// Whether a sample should be taken now.
    public func isDue(_ reading: LidReading, at now: Date) -> Bool {
        guard reading.canSampleBrightness, let dueAt else { return false }
        return now >= dueAt
    }

    /// Records a sample, and sets the next one a cadence away.
    ///
    /// A nil level — DisplayServices refusing, which it does for a panel it
    /// has nothing to say about — leaves the held value alone. The last thing
    /// the user actually chose beats nothing at all, and nothing at all is a
    /// panel that gets darkened with no way back.
    public mutating func took(_ level: Double?, at now: Date) {
        if let level, level.isFinite {
            held = min(max(level, 0), 1)
        }
        dueAt = now.addingTimeInterval(Self.cadence)
    }

    /// Takes a value from somewhere more trustworthy than a reading.
    ///
    /// A prior recovered from the journal is the level the *user* chose, which
    /// is exactly what this type exists to hold and exactly what cannot be
    /// read off a Mac that has already been darkened. It outranks anything
    /// sampled while the record was unreadable, and it is the only baseline
    /// available at all when the lid is shut.
    public mutating func adopt(_ level: Double) {
        guard level.isFinite else { return }
        held = min(max(level, 0), 1)
    }

    /// Forgets the schedule without forgetting the value. For a session ending:
    /// the held level is still the best account of what the user chose, and the
    /// next session should not have to wait a cadence to learn it again.
    public mutating func sessionEnded() {
        dueAt = nil
    }
}
