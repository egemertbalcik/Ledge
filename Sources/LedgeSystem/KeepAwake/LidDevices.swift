import Foundation
import LedgeCore
import os

// Everything the lid-closed conserve actually touches, behind protocols.
//
// Not for tidiness. Three of the four actions are irreversible in a test the
// moment they reach the hardware: a panel at zero on the machine running the
// suite is a black screen, a muted output is a test that silenced somebody's
// Mac, and Low Power Mode left on is a Mac that throttles for the rest of the
// afternoon. Each of those is a test that failed by passing, and the only way
// a suite proves the ordering rules — journal first, clear only after the undo
// — is against fakes that remember what they were asked to do.

// MARK: - Backlights

/// A thing with a brightness, 0...1, that can be read and set.
///
/// One protocol for both backlights because the panel and the keyboard have
/// exactly the same shape of problem: a private framework, no ABI contract, a
/// value worth saving and a value that must be restorable before it is ever
/// changed.
public protocol Backlight: Sendable {
    /// A short name for the log.
    var name: String { get }
    /// Whether this build may touch it on this Mac at all. False is the answer
    /// that keeps it dark-free: an unavailable backlight is never darkened and
    /// never journalled.
    var isAvailable: Bool { get }
    /// Nil when the device will not say, which is ordinary for a panel in
    /// clamshell.
    func level() -> Double?
    /// - Returns: whether the write was taken. A false here keeps the journal
    ///   entry, which is what makes the next pass try again.
    func setLevel(_ level: Double) -> Bool
}

/// The built-in panel, through the `BrightnessController` that already owns
/// this path.
///
/// Deliberately a wrapper and not a second implementation. There is one place
/// in Ledge that knows which display the brightness keys act on, that a
/// clamshell panel reports nothing, and that every DisplayServices symbol is
/// looked up rather than linked; a second copy of that knowledge would be a
/// second copy to get wrong.
public struct PanelBacklight: Backlight {

    public let name = "panel"
    private let controller: BrightnessController

    public init(controller: BrightnessController) {
        self.controller = controller
    }

    public var isAvailable: Bool {
        controller.isSupported
            && PrivateSymbol.exists("DisplayServicesSetBrightness", in: .displayServices)
    }

    public func level() -> Double? { controller.level() }

    public func setLevel(_ level: Double) -> Bool { controller.setLevel(level) }
}

/// A backlight this Mac does not have, or this build may not touch.
///
/// The shipping stand-in wherever a device is optional, so nothing above is
/// written against an optional and every caller gets the one safe answer: no
/// level to save, and nothing that can be darkened.
public struct AbsentBacklight: Backlight {
    public let name: String
    public init(name: String) { self.name = name }
    public var isAvailable: Bool { false }
    public func level() -> Double? { nil }
    public func setLevel(_ level: Double) -> Bool { false }
}

// MARK: - Audio

/// One output device, as the conserve cares about it.
public struct AudioOutputReading: Equatable, Sendable {
    public var uid: String
    public var name: String?
    /// The level, for the log. **Nothing restores it** — see
    /// `LidConserveRecord.Audio.volume`.
    public var volume: Double?
    /// Nil when nothing would say — a failed query, or a device muted on some
    /// channels and not others. Collapsing that into `false` made an
    /// unreadable device look like one the user had just unmuted, and the
    /// whole undo record was dropped on the strength of it.
    public var muted: Bool?
    /// The mute controls that answer `muted` — and the only ones Ledge may
    /// write on this device. See `LidConserveRecord.Audio.governed`.
    public var governed: [UInt32]?
    /// Why Ledge believes it is silent, which a physical flag cannot say.
    public var reasons: MuteReasons
    /// How many times intent has been declared for this output. Compared with
    /// the entry's own earlier reading, and meaningless otherwise.
    public var intentRevision: Int
    /// Which ledger issued it. A number from another incarnation is not
    /// comparable with this one at all.
    public var intentIncarnation: String

    public init(uid: String, name: String? = nil, volume: Double? = nil, muted: Bool?,
                governed: [UInt32]? = nil, reasons: MuteReasons = MuteReasons(),
                intentRevision: Int = 0, intentIncarnation: String = "") {
        self.uid = uid
        self.name = name
        self.volume = volume
        self.muted = muted
        self.governed = governed
        self.reasons = reasons
        self.intentRevision = intentRevision
        self.intentIncarnation = intentIncarnation
    }

    /// The journal entry for this device, or nil when its state could not be
    /// read. Nothing is silenced that cannot be written down first.
    ///
    /// *Which controls* is part of being written down. A record that names a
    /// prior but not the controls it belongs to cannot tell, later, whether
    /// the device was freed or whether the question was put to the wrong
    /// control — so a device with no plan is a device nothing is done to.
    public var entry: LidConserveRecord.Audio? {
        guard let muted, let governed, !governed.isEmpty else { return nil }
        return LidConserveRecord.Audio(uid: uid, name: name, volume: volume, muted: muted,
                                       userMuted: reasons.userMuted,
                                       zeroSilence: reasons.zeroSilence,
                                       governed: governed, intentRevision: intentRevision,
                                       intentIncarnation: intentIncarnation)
    }
}

/// How completely a restore landed.
///
/// A `Bool` was not enough, and the gap it hid was the dangerous one: the
/// shipping adapter was reporting CoreAudio's *partial* success as success, so
/// one stereo channel refusing its level still unmuted the device — with that
/// channel still at the old loud level, which is the blast the whole ordering
/// rule exists to prevent. The other half of the same gap: a mute that needed
/// no write at all was reported as a failure, because nothing had been
/// accepted.
public enum LidRestoreOutcome: Equatable, Sendable {
    /// Confirmed, on every element the device reports.
    case complete
    /// Nothing needed doing — the device was already as asked.
    case alreadySettled
    /// Partly, or not at all. The entry stays and the next pass tries again.
    case incomplete

    /// Whether the device is now in the state that was asked for, however it
    /// got there.
    public var isSettled: Bool { self == .complete || self == .alreadySettled }

    /// What a mute write means for a restore.
    ///
    /// The mirror of the same mistake. `accepted` excludes `alreadySettled`,
    /// so a device that needed no write at all — already muted, already not —
    /// was reported as a failure and kept its entry outstanding for ever.
    /// Being in the state asked for is the whole question; whether anything
    /// had to be written to get there is not.
    public init(mute outcome: MuteOutcome) {
        guard outcome.isComplete else { self = .incomplete; return }
        self = outcome == .alreadySettled ? .alreadySettled : .complete
    }
}

/// Audio output, addressed by device uid rather than by "the default".
///
/// The uid is the whole of the design. A restore aimed at whatever is default
/// at the moment it runs would put the speakers' volume onto a headset that
/// was plugged in while the lid was down — a number from nowhere, on a device
/// the user never touched.
public protocol LidAudioOutput: Sendable {
    /// Where sound is going now, or nil when nothing could be read. Decides
    /// the mute plan, which is what makes this the conserve-time call.
    func currentOutput() -> AudioOutputReading?
    /// That device again, by uid, read **through the plan the record carries**.
    /// Nil when it is no longer attached.
    ///
    /// The plan travels with the entry rather than being asked for again,
    /// because the second answer is not reliably the first: a master can
    /// report settable and then refuse its setter, and a failed capability
    /// query is indistinguishable from an affirmative no. A reading taken
    /// through a control Ledge never wrote says nothing about Ledge's
    /// silence — and saying it anyway deleted the undo record.
    func observe(uid: String, governed: [UInt32]?) -> AudioOutputReading?
    /// Silences the device, or lets it speak again, touching only the
    /// controls in `governed`. A write that would have to fall back outside
    /// the plan is refused: an unrecorded change is worse than no change.
    func setMuted(_ muted: Bool, uid: String, governed: [UInt32]?) -> LidRestoreOutcome
    /// Puts back why the device was silent, which the mute control alone
    /// cannot carry. Called only after the mute itself is settled.
    func restoreReasons(_ reasons: MuteReasons, uid: String)
}

/// A Mac whose audio is not to be touched. Reads nothing, writes nothing.
public struct NoAudioOutput: LidAudioOutput {
    public init() {}
    public func currentOutput() -> AudioOutputReading? { nil }
    public func observe(uid: String, governed: [UInt32]?) -> AudioOutputReading? { nil }
    public func setMuted(_ muted: Bool, uid: String,
                         governed: [UInt32]?) -> LidRestoreOutcome { .incomplete }
    public func restoreReasons(_ reasons: MuteReasons, uid: String) {}
}

// MARK: - Low Power Mode

/// Low Power Mode, as a setting that can be read and — one day — written.
///
/// Reading is free: `ProcessInfo` publishes it. Writing is root, and there is
/// no way around that. `/Library/Preferences/com.apple.PowerManagement.plist`
/// is `root:wheel 0644`, `pmset -a lowpowermode 1` refuses for anybody else,
/// and IOKit exports nothing that sets it. So this is a seam, not a feature:
/// the protocol is the shape the privileged version will have, and the
/// shipping implementation says no and says why.
public protocol LowPowerModeControl: Sendable {
    /// Whether a write could land. False for an app with no helper installed,
    /// which is a Mac that still gets every other saving.
    var canWrite: Bool { get }
    /// Whether the control keeps its own record of what the setting was and
    /// puts it back without being asked twice.
    ///
    /// True for the daemon: its claim records the prior per power source,
    /// journalled before the write and cleared only after a readback, and its
    /// lease puts the setting back even if this app is killed outright. The
    /// conserver journals nothing of its own for a control like that — two
    /// records of one setting would disagree for exactly the user who set Low
    /// Power Mode on battery only, which the coarser of the two cannot even
    /// express.
    var restoresItself: Bool { get }
    /// Nil when it cannot be read.
    func isOn() -> Bool?
    /// Asks for Low Power Mode, or says Ledge is finished with it.
    ///
    /// `false` is "finished with it", not "off": a control that keeps its own
    /// record puts the setting back to what it journalled, which for a user
    /// who had Low Power Mode on is not off at all.
    ///
    /// - Returns: whether the request was taken. For a control that restores
    ///   itself that is acceptance, not confirmation — the confirmation is a
    ///   readback the daemon does on its own side, and `false` here keeps the
    ///   conserver's entry so the next pass asks again.
    func set(_ on: Bool) -> Bool
}

/// Low Power Mode from an app that is not root.
///
/// It can see the setting and it cannot move it, which is exactly what it
/// reports. Returning true from `set` and quietly doing nothing would be the
/// worst available answer: the conserve would journal a Low Power claim it
/// never made, and the restore would turn Low Power Mode *off* for a user who
/// had turned it on themselves.
public struct UnprivilegedLowPowerMode: LowPowerModeControl {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "lid")

    public init() {}

    public var canWrite: Bool { false }
    public var restoresItself: Bool { false }

    public func isOn() -> Bool? { ProcessInfo.processInfo.isLowPowerModeEnabled }

    public func set(_ on: Bool) -> Bool {
        Self.log.notice(
            "lid: Low Power Mode cannot be set from the app — pmset -a lowpowermode is root"
        )
        return false
    }
}

/// Low Power Mode through the root daemon.
///
/// ## Why Ledge throttles a Mac on purpose
///
/// Low Power Mode slows the CPU, and slowing the CPU is the last thing you
/// would want for a machine left running work. The agents this feature exists
/// for are the exception that makes it worth doing: Claude Code, Codex, a long
/// sync — they are network-bound, and spend almost all of their time waiting on
/// a socket rather than on a clock. The throttle costs them close to nothing
/// and the battery saving is real, which is the entire argument for being
/// allowed to do this to a Mac nobody is watching.
///
/// ## What it does and does not promise
///
/// The write is root — `/Library/Preferences/com.apple.PowerManagement.plist`
/// is `root:wheel 0644` and `pmset -a lowpowermode` refuses anybody else — so
/// this is a request posted to the daemon, not a change made here. The daemon
/// journals what the setting was, per power source, before it touches it, and
/// its lease puts that back even if this app is killed without another word.
/// That is why `restoresItself` is true and why the conserver keeps no record
/// of its own: the daemon's is finer and outlives the app.
///
/// Asking is deliberately fire-and-forget. `LidConserver` is an actor whose
/// methods run to completion without suspending — the lid can flap mid-journal
/// and nothing may interleave with that — so this cannot await. It hands the
/// request to the client and says it was taken. "Taken" is the honest word:
/// the client re-sends the standing want with every heartbeat, so a daemon
/// that was busy, restarted, or not listening gets asked again within thirty
/// seconds without anybody here having to remember.
public final class HelperLowPowerMode: LowPowerModeControl, @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "lid")

    private let client: KeepAwakeHelperClient
    private let lock = NSLock()
    /// What Ledge wants Low Power Mode to be, and nothing about how it got
    /// there.
    ///
    /// A queue of requests was the first fix and only half of one: it made
    /// them arrive in order, and left every one of them waiting its turn to
    /// act on whatever session happened to be current when it finally ran. An
    /// old request queued behind a slow one could turn Low Power Mode on for
    /// a session that had replaced the one that asked.
    ///
    /// There is no queue now, because there is nothing a queue could be
    /// carrying: `setLowPowerMode` states a standing want, so only the latest
    /// one means anything and every older one is already wrong. One worker
    /// consumes the latest value and stops when there is none.
    private var latest: Bool?
    private var worker: Task<Void, Never>?

    public init(client: KeepAwakeHelperClient) {
        self.client = client
    }

    public var canWrite: Bool { true }
    public var restoresItself: Bool { true }

    /// What this process can see, which is the value in force rather than the
    /// per-source truth the daemon keeps. Only ever used for a log line: the
    /// value that matters is the one the daemon journalled.
    public func isOn() -> Bool? { ProcessInfo.processInfo.isLowPowerModeEnabled }

    public func set(_ on: Bool) -> Bool {
        lock.withLock {
            latest = on
            guard worker == nil else { return }
            worker = Task { [weak self] in await self?.drain() }
        }
        Self.log.notice("lid: asked the daemon for Low Power Mode \(on ? "on" : "back", privacy: .public)")
        return true
    }

    /// Sends the latest want, and keeps going while a newer one arrives.
    private func drain() async {
        while true {
            let next: Bool? = lock.withLock {
                let value = latest
                latest = nil
                if value == nil { worker = nil }
                return value
            }
            guard let next else { return }
            await client.setLowPowerMode(next)
        }
    }

    /// Waits for every request already made. Joined by a quit, so the app does
    /// not exit with the daemon still holding a Low Power Mode it was told to
    /// give back.
    public func settle() async {
        // Twice, because the worker can retire and a request arriving in the
        // same breath starts another.
        for _ in 0..<2 {
            let running = lock.withLock { worker }
            await running?.value
        }
    }
}
