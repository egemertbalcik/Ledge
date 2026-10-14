import Foundation

/// Which power source a setting is being written for.
///
/// `pmset` keeps most settings once per source, and Low Power Mode is one of
/// them: System Settings offers Never, Always, Only on Battery and Only on
/// Power Adapter, and those four are two booleans, not one. Writing `-a` for
/// everything would be simpler and would quietly turn "Only on Battery" into
/// "Never" for every user who had chosen it.
public enum PmsetPowerSource: String, Equatable, Sendable, CaseIterable {
    /// `-a`, both at once. The ordinary case, and the only safe one on a Mac
    /// with a single power source.
    case all = "-a"
    case battery = "-b"
    case charger = "-c"
}

/// Low Power Mode as macOS actually stores it: once per power source.
///
/// Nil means this Mac has no such source — a desktop has no battery — and that
/// is a third answer, not a false. It is what stops a restore from running
/// `pmset -b` at a Mac Mini and then failing its own readback forever.
public struct LowPowerSetting: Equatable, Sendable {

    public var battery: Bool?
    public var charger: Bool?

    public init(battery: Bool?, charger: Bool?) {
        self.battery = battery
        self.charger = charger
    }

    /// Whether this Mac has both sources to write to separately.
    public var hasBothSources: Bool { battery != nil && charger != nil }

    /// Low Power Mode is on for at least one source.
    public var isOnAnywhere: Bool { battery == true || charger == true }

    /// Packed into the single `Int` the claim has room for.
    ///
    /// Bit 0 is battery, bit 1 is the charger. `HelperClaim.lowPowerPrior` is
    /// an `Int?` and it is the right place for this, so the per-source answer
    /// is folded into it rather than given a field of its own — the claim
    /// format is read by both builds' daemons and is not a thing to change
    /// lightly.
    public var packed: Int { (battery == true ? 1 : 0) | (charger == true ? 2 : 0) }

    /// What a packed prior meant. Both sources come back non-nil: the reading
    /// taken at restore time is what says which of them this Mac has.
    public static func unpacked(_ value: Int) -> LowPowerSetting {
        LowPowerSetting(battery: value & 1 != 0, charger: value & 2 != 0)
    }

    /// Both sources on, for whichever sources this Mac has.
    public var turnedOn: LowPowerSetting {
        LowPowerSetting(battery: battery.map { _ in true }, charger: charger.map { _ in true })
    }

    /// Whether this reading is already what was wanted.
    ///
    /// Judged only on the sources this Mac has. A wanted value for a source
    /// that is not there is not a disagreement — there is nothing to disagree
    /// with — and treating it as one would mean a desktop could never satisfy
    /// a prior that was recorded as "on for battery".
    public func matches(_ wanted: LowPowerSetting) -> Bool {
        if let mine = battery, let theirs = wanted.battery, mine != theirs { return false }
        if let mine = charger, let theirs = wanted.charger, mine != theirs { return false }
        return true
    }

    /// The writes that take this Mac from here to `wanted`.
    ///
    /// One child wherever one will do. Two only when the two sources genuinely
    /// want different answers, which is the "Only on Battery" case and the
    /// reason any of this is per-source at all.
    public func writes(to wanted: LowPowerSetting) -> [PmsetCommand] {
        guard !matches(wanted) else { return [] }
        guard hasBothSources else {
            // One source, and `-a` is the only way to name it without
            // guessing which flag this Mac would accept.
            let on = (battery != nil ? wanted.battery : wanted.charger) ?? false
            return [.writeLowPowerMode(on: on, source: .all)]
        }
        let onBattery = wanted.battery ?? false
        let onCharger = wanted.charger ?? false
        if onBattery == onCharger {
            return [.writeLowPowerMode(on: onBattery, source: .all)]
        }
        return [.writeLowPowerMode(on: onBattery, source: .battery),
                .writeLowPowerMode(on: onCharger, source: .charger)]
    }

    /// Two priors read off the same Mac, combined.
    ///
    /// On by preference. Two claims disagreeing means two daemons each took a
    /// reading at a different moment and only one of them can have been first,
    /// and nothing on disk says which. Turning Low Power Mode back on for
    /// somebody who had it off is a setting they change in one click; turning
    /// it off for somebody who chose it is Ledge undoing a decision it never
    /// made, which is the failure this record exists to prevent.
    public func merged(with other: LowPowerSetting) -> LowPowerSetting {
        LowPowerSetting(battery: battery == true || other.battery == true,
                        charger: charger == true || other.charger == true)
    }
}

/// A single `/usr/bin/pmset` invocation.
///
/// There is no public API for either setting. IOKit exports
/// `_IOPMSetSystemPowerSetting`, which is undeclared and unsupported, and Low
/// Power Mode lives in `/Library/Preferences/com.apple.PowerManagement.plist`,
/// which is `root:wheel 0644` — so the daemon does what every comparable does
/// and runs the command, with an argument array and no shell.
public enum PmsetCommand: Equatable, Sendable {
    /// `pmset -g` — readable without root, which is what makes a readback
    /// worth doing at all.
    case readSleepDisabled
    /// `pmset -a disablesleep 0|1` — the whole reason a root daemon exists.
    case writeSleepDisabled(Bool)
    /// `pmset -g custom` — both power sources at once, also readable without
    /// root. `pmset -g` alone gives only the source in force, and the value
    /// that has to be put back is the one for the source the Mac is *not* on
    /// as much as the one it is.
    case readLowPowerMode
    /// `pmset -a|-b|-c lowpowermode 0|1`.
    case writeLowPowerMode(on: Bool, source: PmsetPowerSource)

    /// Whether this changes the Mac. Reads are cheap and unprivileged; writes
    /// are the whole reason there is a daemon.
    public var isWrite: Bool {
        switch self {
        case .writeSleepDisabled, .writeLowPowerMode: true
        case .readSleepDisabled, .readLowPowerMode: false
        }
    }

    /// Whether this is about Low Power Mode rather than the sleep setting.
    public var isLowPower: Bool {
        switch self {
        case .readLowPowerMode, .writeLowPowerMode: true
        case .readSleepDisabled, .writeSleepDisabled: false
        }
    }
}

/// How one ended.
public enum PmsetOutcome: Equatable, Sendable {
    /// `pmset` exited cleanly on a write. It says nothing about the setting:
    /// only a readback says that, which is why every write is followed by one.
    case wrote
    /// What SleepDisabled reads as, or -1 when pmset would not say.
    case read(Int)
    /// What Low Power Mode reads as, per power source.
    case lowPower(LowPowerSetting)
    /// Refused, timed out, or killed. The message is for the log.
    ///
    /// Not a promise that nothing happened: a write can have applied the
    /// setting and *then* timed out or been killed, and the pipe-timeout path
    /// reports failure for a child whose write landed long before.
    case failed(String)

    /// Whether this outcome is a reading rather than the result of a write.
    ///
    /// The only outcomes that can promise no privileged write occurred. Used
    /// by the fail-safe to decide whether a terminal answer has to invalidate
    /// everything anybody believed about the setting.
    public var isReading: Bool {
        switch self {
        case .read, .lowPower: true
        case .wrote, .failed: false
        }
    }
}

/// Runs one, somewhere else.
///
/// Fire and forget on purpose. The core runs on one serial queue and never
/// blocks on a child: it starts an operation and goes back to handling events,
/// so a lease expiry or a SIGTERM arriving while `pmset` hangs is still seen
/// immediately. The host posts the result back as `childExited(opID:outcome:)`
/// on that same queue, and the core matches it against the operation it is
/// waiting for.
public protocol PmsetRunner: AnyObject {
    /// Never blocks, never throws. A child that cannot be started reports
    /// `.failed` like any other failure.
    func start(_ command: PmsetCommand, opID: Int)

    /// Where results go.
    ///
    /// Set once, during composition, because the thing that wants the results
    /// has to be built with the runner already in hand. On the protocol rather
    /// than on the concrete runner because there are two of these now — the
    /// core's and the fail-safe's — and they must not be able to receive each
    /// other's children.
    func report(to receiver: @escaping @Sendable (Int, PmsetOutcome) -> Void)

    /// Where the news goes that a write already answered for has *finished*.
    ///
    /// A reply is not the end of a writer. An operation is answered when its
    /// pipes time out or when the bounded collection poll gives up, and in
    /// both cases the child can still be alive with a privileged write ahead
    /// of it. When it finally stops, this is how anything that cached a
    /// reading taken in between gets to hear about it.
    ///
    /// Separate from `report` on purpose. The ordinary reply has already been
    /// delivered and its identity retired — the watchdog has let go of the
    /// stage, the core has finished the transaction — so a second reply with
    /// the same op id lands in the "nobody is waiting on this" branch and
    /// changes nothing. This one is not a reply; it is the fact that a writer
    /// stopped, and it carries the op id so the thing that reserved it can
    /// find its own.
    ///
    /// Reads are not sent here. A read changes nothing, however late.
    func reportSettled(to receiver: @escaping @Sendable (Int, PmsetCommand) -> Void)

    /// Where the news goes that an operation is about to be answered while
    /// its writer can still act.
    ///
    /// Delivered *before* the reply, on the same queue, so nothing downstream
    /// can see the failure without also knowing what it does not mean. The
    /// pair with `reportSettled`: this one opens the window, that one closes
    /// it.
    ///
    /// The distinction the rest of the system cannot make for itself. A
    /// `.failed` reply covers a spawn that never happened, a non-zero exit, a
    /// child killed and collected — all of them finished — and also the two
    /// cases where the child is abandoned or uncollectable and is very
    /// possibly still running with a privileged write ahead of it. Only the
    /// runner knows which it just sent.
    ///
    /// Why it matters is not the cache: it is the undo record. A reading
    /// taken in this window is perfectly fresh and still cannot say that the
    /// setting will not move in a moment — so anything that would *destroy*
    /// the evidence of what Ledge changed, on the strength of such a reading,
    /// has to wait.
    ///
    /// Reads are not sent here either.
    func reportUnsettled(to receiver: @escaping @Sendable (Int, PmsetCommand) -> Void)
}
