import Foundation

/// What the Keep Awake card and ears draw.
///
/// Values only, like every other payload: the view layer never sees the
/// session machinery, and the gallery can build any state without a provider.
public struct KeepAwakePayload: Equatable, Sendable, Codable {

    public enum Phase: Equatable, Sendable, Codable {
        case ready
        case running
        case finished(KeepAwakeEndReason)
    }

    public var phase: Phase
    /// Seconds left, in Running. Drawn as "1h 12m", or m:ss in the last minute.
    /// Zero for a hold that runs until it is switched off — `held` is the
    /// number that card shows instead.
    public var remaining: TimeInterval
    /// How long an open-ended hold has been running, in Running.
    public var held: TimeInterval
    /// Whether this hold runs until it is switched off. The card draws a
    /// different sentence and a different number for the two, so it has to
    /// know which it is looking at rather than inferring it from a zero.
    public var isIndefinite: Bool
    /// When the session ends, already formatted for the user's locale by the
    /// shell — LedgeUI takes values, never formatters.
    public var until: String
    /// What the length scrub is set to, in Ready.
    public var minutes: Int
    /// The battery level the session would end at, for the Ready line.
    public var batteryFloor: Int
    /// Whether the lid-closed hold is in force. Derived from `lid` by the
    /// provider rather than tracked beside it, so the two cannot disagree.
    public var lidHeld: Bool
    public var lidClosed: Bool
    /// What the lid-closed mode is doing, and why it is not doing more.
    ///
    /// The card draws a sentence from this and nothing else: every refusal the
    /// daemon can give has one, and the two states that are neither on nor
    /// broken — off, and held-but-unconfirmable — have their own.
    public var lid: KeepAwakeLidState
    /// Finished: what Resume would give back, and whether to offer it.
    public var resumable: TimeInterval?
    /// Finished: the end could not be written down (§6.1.1).
    public var endUnrecorded: Bool
    /// This session came back from the journal rather than being started just
    /// now. A resume nobody asked for has to announce itself, with End one tap
    /// away — so the fact has to reach the card, not just the provider.
    public var resumed: Bool
    /// Ready: the last attempt failed, and why. Running: only `partialHold`.
    /// Nil when nothing is wrong.
    public var problem: Problem?

    public enum Problem: String, Equatable, Sendable, Codable, CaseIterable {
        case assertionRefused
        case startNotSaved
        case journalUnreadable
        /// Too many sessions are waiting to be written down for another one to
        /// be started safely.
        case tooManyUnsaved
        /// Running: the Mac is held, but macOS refused the screen or disk
        /// part of it. Ledge keeps asking, and clears this once it has all of it.
        case partialHold
    }

    public init(
        phase: Phase,
        remaining: TimeInterval = 0,
        held: TimeInterval = 0,
        isIndefinite: Bool = false,
        until: String = "",
        minutes: Int = 60,
        batteryFloor: Int = 15,
        lidHeld: Bool = false,
        lidClosed: Bool = false,
        lid: KeepAwakeLidState = .notInstalled,
        resumable: TimeInterval? = nil,
        endUnrecorded: Bool = false,
        resumed: Bool = false,
        problem: Problem? = nil
    ) {
        self.phase = phase
        self.remaining = remaining
        self.held = held
        self.isIndefinite = isIndefinite
        self.until = until
        self.minutes = minutes
        self.batteryFloor = batteryFloor
        self.lidHeld = lidHeld
        self.lidClosed = lidClosed
        self.lid = lid
        self.resumable = resumable
        self.endUnrecorded = endUnrecorded
        self.resumed = resumed
        self.problem = problem
    }

    public var isRunning: Bool { phase == .running }
}
