import Foundation

/// The two clocks the daemon needs, and the reason it needs two.
///
/// The deadline is a wall-clock date because it is a promise to a person: "the
/// hold ends at 17:40" has to mean 17:40 however the Mac spent the time. The
/// lease is monotonic because it is a promise about a *process*: it answers
/// "has Ledge spoken to me recently", and a user or an NTP step moving the
/// wall clock must not be able to make the answer yes.
public protocol HelperClock: Sendable {

    var now: Date { get }

    /// A clock that counts through system sleep and ignores wall-clock
    /// changes: `mach_continuous_time`, which is what `ContinuousClock` reads.
    ///
    /// Sleep has to count. A Mac that sleeps with a hold recorded wakes with
    /// the lease already spent, which is the safe direction: Ledge re-holds
    /// with a new generation if it is still there, and nothing holds the Mac
    /// awake if it is not.
    ///
    /// System-wide within one boot, which is what lets the two Ledge daemons
    /// compare each other's lease expiries without talking.
    var continuousNanoseconds: UInt64 { get }
}

/// The real one.
public struct SystemHelperClock: HelperClock {

    public init() {}

    public var now: Date { Date() }

    /// `CLOCK_MONOTONIC` on Darwin is the sleep-inclusive one; `CLOCK_UPTIME_RAW`
    /// is the clock that stops while the Mac is asleep. The names are the wrong
    /// way round from the rest of the world, so the choice is spelled out here
    /// rather than left to whoever reads it next.
    public var continuousNanoseconds: UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
}

/// Where the core asks to be woken.
///
/// One wake-up, not one per reason. Every event the core handles ends with it
/// recomputing the single next instant it has anything to do at — a lease
/// expiry, a deadline, a retry, another try at the lock — so a wall-clock step
/// or a cancelled retry cannot leave an armed timer nobody still wants.
public protocol HelperTimer: AnyObject {
    /// Arms a single wake-up this many nanoseconds from now, replacing any
    /// earlier request. Nil cancels, meaning the core has nothing pending.
    func wake(after nanoseconds: UInt64?)
}

/// Somewhere for the daemon to say what it did.
///
/// A protocol rather than `OSLog` directly because this target links Foundation
/// and Security only, and because the few lines worth logging — a stale
/// completion, a restore done on another build's behalf — are also the lines a
/// test wants to assert on.
public protocol HelperLog: Sendable {
    func note(_ message: String)
}

/// A log that keeps nothing, for callers that do not care.
public struct SilentHelperLog: HelperLog {
    public init() {}
    public func note(_ message: String) {}
}
