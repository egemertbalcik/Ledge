import Foundation
import IOKit.pwr_mgt
import OSLog

/// Something that can ask macOS not to idle-sleep.
///
/// Behind a protocol because the real one talks to powerd, which no test can
/// inspect: the ordering rules that matter (nothing is acquired before the
/// journal says so, everything is released whatever the journal says) are only
/// checkable against a fake that records what happened and when.
@MainActor
public protocol SleepAssertion: AnyObject {
    /// Takes the assertion, or says it could not.
    ///
    /// - Parameter timeout: how long powerd itself should hold it before
    ///   letting go. This is the backstop: if Ledge hangs or is killed without
    ///   releasing, the Mac is still free to sleep after this.
    func acquire(name: String, details: String, timeout: TimeInterval) -> Bool
    /// Replaces the timeout without dropping the hold, used on wake and when
    /// the clock moves.
    func rearm(timeout: TimeInterval) -> Bool
    func release()
    var isHeld: Bool { get }
    /// Whether everything the hold promises is held, not just the part it
    /// cannot do without. A hold can be up while macOS has refused some of it.
    var isComplete: Bool { get }
    /// Whether something should be asked for again soon: a part that is
    /// missing, or one whose last renewal was refused while the old one
    /// still covers it.
    var needsRetry: Bool { get }
}

extension SleepAssertion {
    /// An assertion with only one part to it is complete whenever it is held.
    public var isComplete: Bool { isHeld }
    public var needsRetry: Bool { isHeld && !isComplete }
}

/// The real one.
///
/// Coffee holds what Raycast's Coffee holds. Raycast runs
/// `caffeinate -u -dmi` with its defaults, so this takes the same three
/// assertions for as long as a session runs, plus the same one-off nudge of
/// user activity when it starts:
///
/// - `-i` `PreventUserIdleSystemSleep` — the Mac keeps running.
/// - `-d` `PreventUserIdleDisplaySleep` — the screen stays on.
/// - `-m` `PreventDiskIdle` — the disk does not spin down mid-task.
/// - `-u` user activity, once — a screen that had already gone dark comes on.
///
/// The display assertion is the one that was missing, and its absence is
/// what made coffee look broken: the Mac was held awake exactly as asked, the
/// screen went dark on its own timer anyway, and a dark screen is what a
/// sleeping Mac looks like.
///
/// `PreventUserIdleSystemSleep` is still the strongest thing a process without
/// root can ask for, and it is honest about its limits: `IOPMLib.h` says the
/// system "may still sleep for lid close, Apple menu, low battery". Closing
/// the lid of a MacBook on battery will still sleep it. The card says so.
@MainActor
public final class IOPMSleepAssertion: SleepAssertion {

    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake")

    /// The assertions a session holds, in the order they are taken. The
    /// first is the one coffee cannot do without; the others make it what a
    /// person expects coffee to be, and are taken on a best-effort basis so
    /// that a refused display assertion never leaves the Mac free to sleep.
    static let kinds: [String] = [
        kIOPMAssertPreventUserIdleSystemSleep,
        kIOPMAssertPreventUserIdleDisplaySleep,
        kIOPMAssertPreventDiskIdle,
    ]

    /// Talking to powerd, behind closures so the bookkeeping above it — which
    /// assertions are held, the order a re-arm swaps them in, what a partial
    /// failure leaves standing — can be checked without powerd.
    struct Power {
        var create: (_ kind: String, _ name: String, _ details: String, _ timeout: TimeInterval) -> IOPMAssertionID?
        var release: (IOPMAssertionID) -> Void
        var declareUserActivity: (_ name: String) -> IOPMAssertionID?
        /// Runs work later on the main actor; injected so a test can decide
        /// when "later" is.
        var after: (_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void
        /// Seconds on a clock that only moves forward, which is what powerd
        /// measures its timeouts on — not the wall clock, which the user can
        /// set back or forward. This one keeps counting through sleep, so if
        /// anything it says a lease is up early, never late. Injected so a
        /// test can let a kept assertion run out.
        var elapsed: () -> TimeInterval = {
            TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        }

        static var system: Power { Power(
            create: { kind, name, details, timeout in
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionCreateWithDescription(
                    kind as CFString,
                    name as CFString,
                    details as CFString,
                    nil,
                    nil,
                    timeout,
                    kIOPMAssertionTimeoutActionRelease as CFString,
                    &id
                )
                guard result == kIOReturnSuccess else {
                    log.error("keep awake: powerd refused \(kind, privacy: .public) (\(result, privacy: .public))")
                    return nil
                }
                return id
            },
            release: { IOPMAssertionRelease($0) },
            declareUserActivity: { name in
                var id = IOPMAssertionID(0)
                let result = IOPMAssertionDeclareUserActivity(name as CFString, kIOPMUserActiveLocal, &id)
                return result == kIOReturnSuccess ? id : nil
            },
            after: { seconds, work in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    work()
                }
            }
        ) }
    }

    private let power: Power
    /// What is held now, by kind.
    private var held: [String: IOPMAssertionID] = [:]
    /// When powerd lets go of each, by its own timeout, on `Power.elapsed`.
    /// A kind that could not be re-taken keeps its old assertion, but only
    /// until this — after it, powerd has released it and holding the ID
    /// proves nothing.
    private var expiry: [String: TimeInterval] = [:]
    /// Kinds whose last renewal was refused. Still covered, perhaps, by the
    /// assertion they had — but asked for again soon rather than at the next
    /// half-hour, which would be the moment the old one runs out.
    private var refused: Set<String> = []

    /// The start-of-session nudge of user activity, while it lasts.
    ///
    /// It does not lapse on its own — measured: still held two minutes on,
    /// and it would have outlived the session, keeping the screen awake after
    /// coffee had been switched off. `caffeinate -u` without `-t` gives it five
    /// seconds; so does this, and switching coffee off ends it sooner.
    private var userActivity: IOPMAssertionID?
    static let userActivityLifetime: TimeInterval = 5

    public var isHeld: Bool { held[Self.kinds[0]] != nil }

    /// All three, each still inside its timeout. Coffee is screen and disk as
    /// well as the Mac, and a hold missing one of them is not what the card
    /// says it is.
    public var isComplete: Bool {
        let now = power.elapsed()
        return Self.kinds.allSatisfy { kind in
            held[kind] != nil && (expiry[kind].map { $0 > now } ?? true)
        }
    }

    public var needsRetry: Bool { isHeld && (!refused.isEmpty || !isComplete) }

    public convenience init() { self.init(power: .system) }

    init(power: Power) { self.power = power }

    public func acquire(name: String, details: String, timeout: TimeInterval) -> Bool {
        guard !isHeld else { return rearm(timeout: timeout) }
        for kind in Self.kinds {
            if let id = power.create(kind, name, details, timeout) {
                held[kind] = id
                expiry[kind] = power.elapsed() + timeout
                refused.remove(kind)
            } else if kind == Self.kinds[0] {
                // Without the system assertion there is no session to speak
                // of. Give back anything taken on the way so nothing lingers.
                release()
                return false
            }
        }
        declareUserActivity(name)
        return true
    }

    private func declareUserActivity(_ name: String) {
        if let previous = userActivity { power.release(previous) }
        guard let id = power.declareUserActivity(name) else { return }
        userActivity = id
        power.after(Self.userActivityLifetime) { [weak self] in
            // Only the declaration this timer was set for: a session stopped
            // and started inside five seconds has a newer one of its own.
            guard let self, self.userActivity == id else { return }
            self.power.release(id)
            self.userActivity = nil
        }
    }

    /// Re-takes each assertion with a fresh backstop.
    ///
    /// Each new one is taken *before* its predecessor is dropped, so there is
    /// no instant in which nothing is held and the Mac — or the screen — could
    /// slip away. A kind that cannot be re-taken keeps the one it had, for as
    /// long as powerd still honours it; a kind that was missing is asked for
    /// again, so a refusal is retried rather than accepted for good.
    ///
    /// The kept one is never let go early. Whether it has run out is only
    /// Ledge's reckoning of powerd's clock, and giving up a lease that turned
    /// out to have time left would end protection a guess said was over.
    public func rearm(timeout: TimeInterval) -> Bool {
        guard isHeld else { return false }
        var systemRearmed = false
        let now = power.elapsed()
        for kind in Self.kinds {
            guard let replacement = power.create(kind, Self.assertionName, "re-armed", timeout) else {
                if kind == Self.kinds[0] {
                    Self.log.error("keep awake: could not re-arm")
                } else {
                    refused.insert(kind)
                }
                continue
            }
            if let previous = held[kind] { power.release(previous) }
            held[kind] = replacement
            expiry[kind] = now + timeout
            refused.remove(kind)
            if kind == Self.kinds[0] { systemRearmed = true }
        }
        return systemRearmed
    }

    public func release() {
        for id in held.values { power.release(id) }
        held.removeAll()
        expiry.removeAll()
        refused.removeAll()
        if let id = userActivity {
            power.release(id)
            userActivity = nil
        }
    }

    /// What `pmset -g assertions` shows while a session runs.
    public static let assertionName = "Ledge Keep Awake"
}
