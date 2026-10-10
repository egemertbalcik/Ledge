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
}

/// The real one.
///
/// `IOPMAssertionCreateWithDescription` takes the timeout and its action
/// directly, so there is no properties dictionary to assemble and no second
/// call to set them — one call, and the backstop is in place before the
/// function returns.
///
/// `PreventUserIdleSystemSleep` is the strongest thing a process without root
/// can ask for, and it is honest about its limits: `IOPMLib.h` says the system
/// "may still sleep for lid close, Apple menu, low battery". Closing the lid of
/// a MacBook on battery will still sleep it. The card says so rather than
/// letting the user find out.
@MainActor
public final class IOPMSleepAssertion: SleepAssertion {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake")

    private var identifier: IOPMAssertionID = IOPMAssertionID(0)
    public private(set) var isHeld = false

    public init() {}

    public func acquire(name: String, details: String, timeout: TimeInterval) -> Bool {
        guard !isHeld else { return rearm(timeout: timeout) }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            name as CFString,
            details as CFString,
            nil,
            nil,
            timeout,
            kIOPMAssertionTimeoutActionRelease as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            Self.log.error("keep awake: powerd refused the assertion (\(result, privacy: .public))")
            return false
        }
        identifier = id
        isHeld = true
        return true
    }

    /// Re-takes the assertion with a fresh backstop.
    ///
    /// Done by taking the new one *before* dropping the old one, so there is no
    /// instant in between where nothing is held and the Mac could slip away.
    public func rearm(timeout: TimeInterval) -> Bool {
        guard isHeld else { return false }
        let previous = identifier
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            Self.assertionName as CFString,
            "re-armed" as CFString,
            nil,
            nil,
            timeout,
            kIOPMAssertionTimeoutActionRelease as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            Self.log.error("keep awake: could not re-arm (\(result, privacy: .public))")
            return false
        }
        identifier = id
        IOPMAssertionRelease(previous)
        return true
    }

    public func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(identifier)
        identifier = IOPMAssertionID(0)
        isHeld = false
    }

    /// What `pmset -g assertions` shows while a session runs.
    public static let assertionName = "Ledge Keep Awake"
}
