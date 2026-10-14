import Foundation
import LedgeCore

@testable import LedgeSystem

// Stand-ins for the four things a lid close actually touches.
//
// Not convenience. Three of the four are irreversible on the Mac running the
// suite the moment they reach the hardware: a panel at zero is a black screen,
// a muted output is a test that silenced somebody's machine, and Low Power
// Mode left on is a Mac that throttles for the rest of the afternoon. A test
// that dims the user's screen is a test that failed.

/// A backlight that remembers what it was asked to do.
final class FakeBacklight: Backlight, @unchecked Sendable {

    let name: String
    private let lock = NSLock()
    private var _available: Bool
    private var _level: Double?
    private var _accepts: Bool
    private(set) var writes: [Double] = []

    /// The write is taken and the device does not move.
    ///
    /// Not a hypothetical. `DisplayServicesSetBrightness` and
    /// `-setBrightness:forKeyboard:` both return an API acknowledgement, not
    /// a reading, and a fake that updated its own readback whenever it said
    /// yes would make every restore look confirmed by construction — which is
    /// exactly how a panel left at zero passed for restored.
    private var _ignoresWrites = false

    init(name: String = "fake", available: Bool = true,
         level: Double? = 0.7, accepts: Bool = true, ignoresWrites: Bool = false) {
        self.name = name
        self._available = available
        self._level = level
        self._accepts = accepts
        self._ignoresWrites = ignoresWrites
    }

    /// Say yes to every write and move for none of them.
    func setIgnoresWrites(_ value: Bool) { lock.withLock { _ignoresWrites = value } }

    var isAvailable: Bool { lock.withLock { _available } }
    func setAvailable(_ value: Bool) { lock.withLock { _available = value } }
    func setAccepts(_ value: Bool) { lock.withLock { _accepts = value } }
    func setReadLevel(_ value: Double?) { lock.withLock { _level = value } }

    func level() -> Double? { lock.withLock { _level } }

    func setLevel(_ level: Double) -> Bool {
        // A real backlight write is a trip into a private framework and takes
        // long enough for a second event to arrive behind it. A fake that
        // returns instantly hides every ordering question there is.
        let pause = lock.withLock { _delayMicroseconds }
        if pause > 0 { usleep(pause) }
        return lock.withLock {
            guard _accepts else { return false }
            writes.append(level)
            // Acknowledgement and effect are separate on purpose.
            if !_ignoresWrites { _level = level }
            return true
        }
    }

    private var _delayMicroseconds: UInt32 = 0
    func setDelay(microseconds: UInt32) { lock.withLock { _delayMicroseconds = microseconds } }

    var writeLog: [Double] { lock.withLock { writes } }
    var lastWrite: Double? { lock.withLock { writes.last } }
}

/// Audio output as a dictionary of devices, keyed the way the real one is.
final class FakeLidAudio: LidAudioOutput, @unchecked Sendable {

    private let lock = NSLock()
    private var devices: [String: AudioOutputReading]
    private var currentUID: String?
    private var _acceptsMute = true
    private(set) var muteWrites: [(uid: String, muted: Bool)] = []
    /// Every write in the order it arrived, across both controls. Volume and
    /// mute are separate properties in CoreAudio and the order they go out in
    /// is audible: sound coming back before the level does is sound at a level
    /// nobody chose.
    private(set) var writeOrder: [String] = []

    init(current: AudioOutputReading?) {
        var map: [String: AudioOutputReading] = [:]
        if let current { map[current.uid] = current }
        self.devices = map
        self.currentUID = current?.uid
    }

    // MARK: - Which controls

    /// What the planner nominates for a device *now*.
    ///
    /// Deliberately separate from the plan a record carries: on real hardware
    /// the two come apart, and the record's plan is the one that means
    /// anything. A master can report settable and then refuse its setter, and
    /// a failed capability query is indistinguishable from an affirmative no.
    private var planByUID: [String: [UInt32]] = [:]
    /// The master, which is what most devices nominate.
    private var defaultPlan: [UInt32] = [0]

    /// Changes what the planner would say, without changing anything the
    /// device actually does. The shape of both R7-1 reproductions.
    func planNow(_ plan: [UInt32], uid: String) { lock.withLock { planByUID[uid] = plan } }

    /// Controls that answer "not muted" whatever the device is doing —
    /// a read-only master beside muted channels, or channels beside a muted
    /// master. Reading one of these is reading a control Ledge never wrote.
    private var detachedByUID: [String: Set<UInt32>] = [:]
    func detach(_ elements: Set<UInt32>, uid: String) {
        lock.withLock { detachedByUID[uid] = elements }
    }

    /// Controls that will not say where they are at all.
    private var silentByUID: [String: Set<UInt32>] = [:]
    func silence(_ elements: Set<UInt32>, uid: String) {
        lock.withLock { silentByUID[uid] = elements }
    }

    /// Controls that report themselves writable and refuse the write.
    private var refusedByUID: [String: Set<UInt32>] = [:]
    func refuse(_ elements: Set<UInt32>, uid: String) {
        lock.withLock { refusedByUID[uid] = elements }
    }

    /// Every plan the conserver handed over, so a test can say whether the
    /// *journalled* one was carried or a fresh one was fetched.
    private(set) var observedPlans: [(uid: String, governed: [UInt32]?)] = []
    private(set) var mutePlans: [(uid: String, muted: Bool, governed: [UInt32]?)] = []

    /// What a reading through these controls says — the fake's whole reason
    /// for modelling elements rather than one flag per device.
    private func elementMuted(_ device: AudioOutputReading, _ element: UInt32) -> Bool? {
        if (silentByUID[device.uid] ?? []).contains(element) { return nil }
        // A detached control reads free whatever the device is doing.
        if (detachedByUID[device.uid] ?? []).contains(element) { return false }
        return device.muted
    }

    private func mutedState(_ device: AudioOutputReading,
                            within governed: [UInt32]?) -> Bool? {
        // No plan is no answer. A record that cannot name its controls has
        // not been shown anything about them.
        guard let governed, !governed.isEmpty else { return nil }
        var unreadable = false
        for element in governed {
            switch elementMuted(device, element) {
            case .some(true): return true
            case .some(false): continue
            case .none: unreadable = true
            }
        }
        return unreadable ? nil : false
    }

    func currentOutput() -> AudioOutputReading? {
        lock.withLock {
            guard let uid = currentUID, var device = devices[uid] else { return nil }
            device.reasons = reasonsByUID[uid] ?? MuteReasons()
            device.intentRevision = revisionByUID[uid] ?? 0
            device.intentIncarnation = _incarnation
            // The planner's answer, taken now — which is right here and only
            // here, because this is the call that writes the record.
            device.governed = device.governed ?? planByUID[uid] ?? defaultPlan
            return device
        }
    }

    func observe(uid: String, governed: [UInt32]?) -> AudioOutputReading? {
        lock.withLock {
            observedPlans.append((uid, governed))
            guard var device = devices[uid] else { return nil }
            device.reasons = reasonsByUID[uid] ?? MuteReasons()
            device.intentRevision = revisionByUID[uid] ?? 0
            device.intentIncarnation = _incarnation
            device.governed = governed
            device.muted = mutedState(device, within: governed)
            return device
        }
    }

    /// Why each device is silent, as the intent ledger keeps it.
    private var reasonsByUID: [String: MuteReasons] = [:]
    private(set) var reasonWrites: [(uid: String, reasons: MuteReasons)] = []

    /// How many times intent has been *declared* for each device.
    ///
    /// The production ledger bumps this on its explicit path — the mute key,
    /// the slider, a restore putting a meaning back — and not when Ledge
    /// merely notices the hardware and adopts it. The fake has to keep the
    /// two apart or it cannot express the case this exists for: a user
    /// muting during a conserve looks exactly like the conserve's own mute
    /// echoing back, in the reasons alone.
    private var revisionByUID: [String: Int] = [:]

    func revision(uid: String) -> Int { lock.withLock { revisionByUID[uid] ?? 0 } }

    /// Which ledger these numbers came from. A relaunch gets a new one, and a
    /// number from another incarnation is not comparable at all.
    private var _incarnation = "run-1"
    var incarnation: String { lock.withLock { _incarnation } }

    /// The app restarting: a fresh ledger, counting from nothing.
    func relaunch(as incarnation: String = "run-2") {
        lock.withLock {
            _incarnation = incarnation
            revisionByUID.removeAll()
        }
    }

    /// Somebody asking for something the hardware refused. The description is
    /// recorded; nobody established anything, so the clock does not move.
    func userAttempts(_ reasons: MuteReasons, uid: String) {
        lock.withLock { reasonsByUID[uid] = reasons }
    }

    func restoreReasons(_ reasons: MuteReasons, uid: String) {
        lock.withLock {
            reasonsByUID[uid] = reasons
            revisionByUID[uid, default: 0] += 1
            reasonWrites.append((uid, reasons))
        }
    }

    func reasons(uid: String) -> MuteReasons { lock.withLock { reasonsByUID[uid] ?? MuteReasons() } }

    /// The ledger drifting without anybody deciding anything — Ledge's own
    /// mute echoing back through the volume watcher, which is what the
    /// restore exists to correct.
    func setReasons(_ reasons: MuteReasons, uid: String) {
        lock.withLock { reasonsByUID[uid] = reasons }
    }

    /// Somebody reaching for the mute key, or the slider: the same ledger
    /// change as an echo, and the opposite meaning.
    func userDeclares(_ reasons: MuteReasons, uid: String) {
        lock.withLock {
            reasonsByUID[uid] = reasons
            revisionByUID[uid, default: 0] += 1
        }
    }

    func setMuted(_ muted: Bool, uid: String, governed: [UInt32]?) -> LidRestoreOutcome {
        lock.withLock {
            mutePlans.append((uid, muted, governed))
            // A record that cannot name its controls does not get to guess at
            // them: an unrecorded change is the one thing the journal exists
            // to prevent.
            guard let governed, !governed.isEmpty else { return .incomplete }
            guard _acceptsMute, var device = devices[uid] else { return .incomplete }
            let refused = refusedByUID[uid] ?? []
            // The plan is refused as a whole rather than wandering onto
            // controls nothing wrote down.
            guard !governed.contains(where: { refused.contains($0) }) else { return .incomplete }
            // Nothing to do is settled, not failed: the device is in the state
            // that was asked for, and keeping an entry outstanding over a
            // write nobody needed meant it never cleared.
            if device.muted == muted { return .alreadySettled }
            device.muted = muted
            devices[uid] = device
            muteWrites.append((uid, muted))
            writeOrder.append("mute")
            return .complete
        }
    }

    /// Each scalar control's own level.
    ///
    /// Nothing here writes one, and that is the point: `LidAudioOutput` no
    /// longer has any way to change a level, so a test can hold these up at
    /// the end of a whole conserve-and-restore cycle and show they are
    /// exactly where the user left them. One `volume` per device could not
    /// express that — a stereo output trimmed to 0.2 left and 0.8 right reads
    /// 0.5 as an aggregate, and an average written back to both channels
    /// looks right from every angle except the user's.
    private var levelsByUID: [String: [UInt32: Double]] = [:]

    /// Sets a device's levels up. The *test* moves these; the conserve cannot.
    func setLevels(_ levels: [UInt32: Double], uid: String) {
        lock.withLock { levelsByUID[uid] = levels }
    }

    /// What each control reads now.
    func levels(uid: String) -> [UInt32: Double] { lock.withLock { levelsByUID[uid] ?? [:] } }

    // Things only a test does to a Mac's audio.

    /// Unplugs the device: it is no longer anywhere, as a pulled headset is.
    func detach(uid: String) {
        lock.withLock {
            devices[uid] = nil
            if currentUID == uid { currentUID = nil }
        }
    }

    /// Somebody reaches for the mute key themselves.
    func userSets(muted: Bool, uid: String) {
        lock.withLock {
            guard var device = devices[uid] else { return }
            device.muted = muted
            devices[uid] = device
        }
    }

    func plug(_ device: AudioOutputReading, asDefault: Bool = false) {
        lock.withLock {
            devices[device.uid] = device
            if asDefault { currentUID = device.uid }
        }
    }

    func setAcceptsMute(_ value: Bool) { lock.withLock { _acceptsMute = value } }

    func state(uid: String) -> AudioOutputReading? { lock.withLock { devices[uid] } }
    var mutes: [(uid: String, muted: Bool)] { lock.withLock { muteWrites } }
    var order: [String] { lock.withLock { writeOrder } }
}

/// Low Power Mode that can be allowed to work, which the real one never is.
final class FakeLowPower: LowPowerModeControl, @unchecked Sendable {

    private let lock = NSLock()
    private var _canWrite: Bool
    private var _restoresItself: Bool
    private var _on: Bool?
    private(set) var writes: [Bool] = []

    init(canWrite: Bool = false, on: Bool? = false, restoresItself: Bool = false) {
        self._canWrite = canWrite
        self._restoresItself = restoresItself
        self._on = on
    }

    var canWrite: Bool { lock.withLock { _canWrite } }
    var restoresItself: Bool { lock.withLock { _restoresItself } }
    func isOn() -> Bool? { lock.withLock { _on } }

    func set(_ on: Bool) -> Bool {
        lock.withLock {
            guard _canWrite else { return false }
            writes.append(on)
            _on = on
            return true
        }
    }

    var writeLog: [Bool] { lock.withLock { writes } }
}

/// The journal, in memory, with a disk that can be told to say no.
final class MemoryLidJournal: LidConserveJournal, @unchecked Sendable {

    enum Fault: Error { case refused }

    private let lock = NSLock()
    private var stored: LidConserveRecord?
    private var _failsWrites = false
    private var _failsClear = false
    private var _failsReads = false
    private var _readTrouble: LidJournalTrouble = .unreadable
    private var _failsAside = false
    private(set) var asideCount = 0
    private(set) var writeCount = 0

    init(_ record: LidConserveRecord? = nil) { stored = record }

    func read() throws -> LidConserveRecord? {
        try lock.withLock {
            if _failsReads { throw _readTrouble }
            return stored
        }
    }

    func write(_ record: LidConserveRecord) throws {
        try lock.withLock {
            if _failsWrites { throw Fault.refused }
            stored = record
            writeCount += 1
        }
    }

    func clear() throws {
        try lock.withLock {
            if _failsClear { throw Fault.refused }
            stored = nil
        }
    }

    func moveAside() throws {
        try lock.withLock {
            if _failsAside { throw Fault.refused }
            stored = nil
            asideCount += 1
        }
    }

    var onDisk: LidConserveRecord? { lock.withLock { stored } }
    func failWrites(_ value: Bool) { lock.withLock { _failsWrites = value } }
    func failClear(_ value: Bool) { lock.withLock { _failsClear = value } }
    func failReads(_ value: Bool, as trouble: LidJournalTrouble = .unreadable) {
        lock.withLock {
            _failsReads = value
            _readTrouble = trouble
        }
    }
    func failAside(_ value: Bool) { lock.withLock { _failsAside = value } }
    var asides: Int { lock.withLock { asideCount } }
    var writes: Int { lock.withLock { writeCount } }
}

/// A lid that is wherever a test puts it.
final class FakeLidSensor: LidSensing, @unchecked Sendable {

    private let lock = NSLock()
    private var reading: LidReading
    private var handler: (@Sendable (LidReading) -> Void)?
    private(set) var stops = 0

    init(_ reading: LidReading = .unknown) { self.reading = reading }

    func read() -> LidReading { lock.withLock { reading } }

    func observe(_ onChange: @escaping @Sendable (LidReading) -> Void) {
        let now: LidReading = lock.withLock {
            handler = onChange
            return reading
        }
        onChange(now)
    }

    func stop() {
        lock.withLock {
            handler = nil
            stops += 1
        }
    }

    func move(to reading: LidReading) {
        let announce: (@Sendable (LidReading) -> Void)? = lock.withLock {
            self.reading = reading
            return handler
        }
        announce?(reading)
    }

    var stopCount: Int { lock.withLock { stops } }
}
