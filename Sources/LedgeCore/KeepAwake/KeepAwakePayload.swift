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
    public var remaining: TimeInterval
    /// When the session ends, already formatted for the user's locale by the
    /// shell — LedgeUI takes values, never formatters.
    public var until: String
    /// What the length scrub is set to, in Ready.
    public var minutes: Int
    /// The battery level the session would end at, for the Ready line.
    public var batteryFloor: Int
    /// Phase 2: whether the lid-closed hold is in force. Phase 1 is always
    /// false, and the Ready line says so honestly.
    public var lidHeld: Bool
    public var lidClosed: Bool
    /// Finished: what Resume would give back, and whether to offer it.
    public var resumable: TimeInterval?
    /// Finished: the end could not be written down (§6.1.1).
    public var endUnrecorded: Bool
    /// This session came back from the journal rather than being started just
    /// now. A resume nobody asked for has to announce itself, with End one tap
    /// away — so the fact has to reach the card, not just the provider.
    public var resumed: Bool
    /// Ready: the last attempt failed, and why. Nil when nothing is wrong.
    public var problem: Problem?

    public enum Problem: String, Equatable, Sendable, Codable {
        case assertionRefused
        case startNotSaved
        case journalUnreadable
        /// Too many sessions are waiting to be written down for another one to
        /// be started safely.
        case tooManyUnsaved
    }

    public init(
        phase: Phase,
        remaining: TimeInterval = 0,
        until: String = "",
        minutes: Int = 60,
        batteryFloor: Int = 15,
        lidHeld: Bool = false,
        lidClosed: Bool = false,
        resumable: TimeInterval? = nil,
        endUnrecorded: Bool = false,
        resumed: Bool = false,
        problem: Problem? = nil
    ) {
        self.phase = phase
        self.remaining = remaining
        self.until = until
        self.minutes = minutes
        self.batteryFloor = batteryFloor
        self.lidHeld = lidHeld
        self.lidClosed = lidClosed
        self.resumable = resumable
        self.endUnrecorded = endUnrecorded
        self.resumed = resumed
        self.problem = problem
    }

    public var isRunning: Bool { phase == .running }
}
