import Foundation
import LedgeCore
import os

/// What the lid closing actually does, and how it is undone.
///
/// `LidPolicy` decides *when*; this is *what*. The split is deliberate — the
/// decision is a pure function with a test for every combination, and the
/// actions are four irreversible-looking things that are only reversible
/// because of what is written down before each of them.
///
/// ## The order, which is the whole of it
///
/// Every entry is journalled **before** the change it describes, and cleared
/// only **after** its undo has been confirmed. The two failures are not
/// symmetric and the order follows from that:
///
/// - A record of a change that never happened costs one pointless restore.
/// - A change with no record is a black panel inside a closed machine. The
///   brightness keys are under the lid; the screen they would light is the one
///   at zero; and no amount of pressing anything fixes it because nothing in
///   the Mac believes the brightness is wrong.
///
/// So a journal write that fails means **nothing is applied at all**, and an
/// undo that fails **keeps its entry and tries again** — on the next lid
/// event, on the next cadence, and on the next launch. A record is never
/// dropped because something looked finished.
///
/// An actor, and every method runs to completion without suspending inside
/// itself. The lid can flap, a session can end mid-restore, and a wake can
/// arrive during a conserve; none of those may interleave with a half-applied
/// journal.
public actor LidConserver {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "lid")

    // MARK: - What it owns

    private let journal: any LidConserveJournal
    private let panel: any Backlight
    private let keyboard: any Backlight
    private let audio: any LidAudioOutput
    private let lowPower: any LowPowerModeControl
    private let boot: @Sendable () -> String?
    private let now: @Sendable () -> Date

    /// The brightness the user chose, sampled only with the lid up. One per
    /// backlight, kept in lockstep: both are pulled down by ambient light and
    /// both are unreadable for the user's purposes once the lid is over the
    /// sensor.
    private var panelSample = LidBrightnessSampler()
    private var keyboardSample = LidBrightnessSampler()

    /// What the disk is meant to hold. Nil means the file is gone, which is
    /// the only state in which this Mac owes nothing.
    private var record: LidConserveRecord?

    /// Whether the savings are in place. What `LidPolicy` is asked with, and
    /// never the same question as "is anything outstanding" — a restore that
    /// half worked leaves nothing conserved and something outstanding.
    public private(set) var isConserving = false

    private var lastReading: LidReading = .unknown

    /// The journal said something this conserver could not resolve: a read it
    /// could not perform, or a file it could not set aside.
    ///
    /// Until it is resolved, **nothing new is written**. The file that could
    /// not be read is very likely still the only account of what the user's
    /// panel was set to, and conserving over it would replace that with the
    /// brightness of a Mac that has already been darkened — which is a black
    /// screen with no record of anything else, the single worst outcome this
    /// whole file is arranged around.
    private var unresolved = false

    public init(
        journal: any LidConserveJournal,
        panel: any Backlight,
        keyboard: any Backlight,
        audio: any LidAudioOutput,
        lowPower: any LowPowerModeControl = UnprivilegedLowPowerMode(),
        boot: @escaping @Sendable () -> String? = BootSession.identifier,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.journal = journal
        self.panel = panel
        self.keyboard = keyboard
        self.audio = audio
        self.lowPower = lowPower
        self.boot = boot
        self.now = now
    }

    // MARK: - What a caller sees

    public struct Outcome: Equatable, Sendable {
        /// What the policy asked for this pass.
        public var action: LidAction
        /// Whether the savings are in place now.
        public var isConserving: Bool
        /// What is still journalled — nil when this Mac owes nothing.
        public var outstanding: LidConserveRecord?
        /// The journal said something that could not be resolved, so what
        /// this Mac owes is *unknown*.
        ///
        /// Its own answer, because nil-outstanding is what "owes nothing"
        /// looks like, and the driver retires its watch on that. An unresolved
        /// journal retiring the watch meant nothing was left to notice the
        /// disk coming back: the retry happened on passes that never came.
        public var isUnresolved: Bool

        public init(action: LidAction, isConserving: Bool,
                    outstanding: LidConserveRecord?, isUnresolved: Bool = false) {
            self.action = action
            self.isConserving = isConserving
            self.outstanding = outstanding
            self.isUnresolved = isUnresolved
        }

        /// Whether anything is still owed, known or unknown.
        public var owesSomething: Bool { outstanding != nil || isUnresolved }
    }

    /// The last brightness sampled with the lid up, for a test or a log line.
    public var heldPanelBrightness: Double? { panelSample.held }
    public var heldKeyboardBrightness: Double? { keyboardSample.held }
    public var outstanding: LidConserveRecord? { record }

    // MARK: - Launch

    /// Puts back anything a previous run left behind.
    ///
    /// The app can be force-quit, crash, or be replaced by an update with the
    /// lid shut and the panel at zero, and the only thing that knows about it
    /// afterwards is this file. Called before anything else, and before any
    /// session exists: a record found here belongs to nobody, which is exactly
    /// why it is restored.
    @discardableResult
    public func recover() -> Outcome {
        do {
            record = try journal.read()
            unresolved = false
        } catch LidJournalTrouble.unavailable {
            // The file is there and could not be reached. It is almost
            // certainly still exactly what it was, so nothing is set aside and
            // nothing new may be written over it. Tried again on every pass.
            unresolved = true
            record = nil
            Self.log.error("lid: the conserve record could not be read; nothing will be written over it")
            return Outcome(action: .none, isConserving: false, outstanding: nil,
                           isUnresolved: true)
        } catch {
            // Rubbish, not unreachable. Set aside rather than deleted: it is
            // the only account of what may still be dark, and Ledge is not
            // entitled to destroy it just because it cannot parse it.
            do {
                try journal.moveAside()
                unresolved = false
                record = nil
                Self.log.error("lid: the conserve record could not be read and was set aside")
            } catch {
                // It could not even be moved. The file stands, and so does
                // whatever it says; writing a fresh one over it is the one
                // thing that must not happen.
                unresolved = true
                record = nil
                Self.log.error("lid: an unreadable conserve record could not be set aside; nothing will be written over it")
                return Outcome(action: .none, isConserving: false, outstanding: nil,
                               isUnresolved: true)
            }
            return Outcome(action: .restore, isConserving: false, outstanding: nil)
        }

        guard let found = record else {
            return Outcome(action: .none, isConserving: false, outstanding: nil)
        }

        // A recovered prior is better evidence than anything sampled while the
        // journal was unreadable — and better than nothing at all when the lid
        // is already shut and sampling is forbidden. Adopted as the baseline
        // so the conserve that follows journals the user's level rather than
        // the darkened one it can see.
        if let level = found.panel?.level { panelSample.adopt(level) }
        if let level = found.keyboard?.level { keyboardSample.adopt(level) }

        let sameBoot = found.boot != nil && found.boot == boot()
        Self.log.notice("""
            lid: a conserve record from \(sameBoot ? "this boot" : "an earlier run", privacy: .public) \
            is being put back
            """)
        isConserving = false
        drain(floorWantsLowPower: false)
        return Outcome(action: .restore, isConserving: false, outstanding: record,
                       isUnresolved: unresolved)
    }

    // MARK: - The session

    /// A session started: sample at once, before anything is conserved.
    public func sessionBegan() {
        let stamp = now()
        panelSample.sessionBegan(at: stamp)
        keyboardSample.sessionBegan(at: stamp)
    }

    /// A session ended. Everything goes back, whatever the lid is doing.
    @discardableResult
    public func sessionEnded() -> Outcome {
        let outcome = update(reading: lastReading, sessionRunning: false)
        panelSample.sessionEnded()
        keyboardSample.sessionEnded()
        return outcome
    }

    // MARK: - The one entry point

    /// Called on every lid reading and on the sampling cadence.
    ///
    /// - Parameters:
    ///   - reading: the lid and the displays, now.
    ///   - sessionRunning: whether a lid-closed hold is live.
    ///   - sessionID: for the record, so a log line can say which session a
    ///     leftover belongs to.
    ///   - floorWantsLowPower: something other than the lid wants Low Power
    ///     Mode left on. Nothing does yet; it is a parameter rather than a
    ///     `false` buried in the body because the floor is the only reason a
    ///     restore is ever allowed to leave a setting where it found it.
    @discardableResult
    public func update(reading: LidReading,
                       sessionRunning: Bool,
                       sessionID: String? = nil,
                       floorWantsLowPower: Bool = false) -> Outcome {
        let stamp = now()
        lastReading = reading

        // Anything a previous pass could not undo is tried again first, every
        // time, regardless of what the policy is about to say. This is what
        // "keeps trying" means: not a retry timer, but the fact that no pass
        // ever walks past an outstanding entry.
        if !isConserving, record != nil {
            drain(floorWantsLowPower: floorWantsLowPower)
        }
        // A journal nobody could read is tried again on every pass: it is the
        // only thing standing between the user and a panel at zero with no
        // record of what it was.
        if unresolved { _ = recover() }

        panelSample.observed(reading, at: stamp)
        keyboardSample.observed(reading, at: stamp)
        // Each sampler asked on its own, because each is frozen on its own.
        if panelSample.isDue(reading, at: stamp) || keyboardSample.isDue(reading, at: stamp) {
            // Per component, and never off hardware that is still conserved.
            // A level read from a backlight whose entry is still outstanding
            // is the *darkened* level — the entry exists precisely because it
            // has not been put back — and adopting it as the user's baseline
            // is how an original 0.6 came to be journalled away as 0.
            //
            // An unreadable journal is the same situation one step further
            // out: what is owed is unknown, so nothing about the hardware can
            // be trusted either.
            //
            // `took(nil)` keeps the cadence moving without touching the held
            // value, so a component that is frozen does not re-fire on every
            // pass and a healthy one is not blocked by its neighbour.
            let mayTrustPanel = !unresolved && record?.panel == nil && panel.isAvailable
            let mayTrustKeyboard = !unresolved && record?.keyboard == nil && keyboard.isAvailable
            if !mayTrustPanel || !mayTrustKeyboard {
                Self.log.notice("lid: not sampling a backlight that has not been put back yet")
            }
            if panelSample.isDue(reading, at: stamp) {
                panelSample.took(mayTrustPanel ? panel.level() : nil, at: stamp)
            }
            if keyboardSample.isDue(reading, at: stamp) {
                keyboardSample.took(mayTrustKeyboard ? keyboard.level() : nil, at: stamp)
            }
        }

        let action = LidPolicy.action(for: reading, sessionRunning: sessionRunning,
                                      conserving: isConserving)
        switch action {
        case .conserve: conserve(sessionID: sessionID, at: stamp)
        case .restore:
            isConserving = false
            drain(floorWantsLowPower: floorWantsLowPower)
        case .none: break
        }

        return Outcome(action: action, isConserving: isConserving, outstanding: record,
                       isUnresolved: unresolved)
    }

    // MARK: - Conserving

    /// Writes down what is about to change, and only then changes it.
    private func conserve(sessionID: String?, at stamp: Date) {
        var entry = LidConserveRecord(
            boot: boot(), sessionID: sessionID, writtenAt: stamp,
            // An entry already outstanding is the older and truer account of
            // what was there, and is kept. Overwriting it would journal the
            // *conserved* state as the thing to restore — a muted device's
            // mute, a dark panel's zero — which is how a restore puts back
            // the very state it was meant to undo.
            panel: record?.panel, keyboard: record?.keyboard,
            audio: record?.audio, lowPower: record?.lowPower
        )

        // The panel, and the keyboard with it. Nothing is darkened without a
        // sampled level to put back: a backlight at zero with no restorable
        // record is the failure this whole file is arranged around, and "we
        // could read it a moment ago" is not a record.
        if entry.panel == nil, panel.isAvailable, let held = panelSample.held {
            entry.panel = LidConserveRecord.Level(level: held)
        }
        if entry.keyboard == nil, keyboard.isAvailable, let held = keyboardSample.held {
            entry.keyboard = LidConserveRecord.Level(level: held)
        }

        // The device, not "the default output". A restore aimed at whatever
        // is default when it runs would put one device's volume onto another.
        if entry.audio == nil, let output = audio.currentOutput() {
            // Nil when the device's state could not be read. Nothing is
            // silenced that cannot be written down first.
            entry.audio = output.entry
        }

        // Low Power Mode. The entry exists whenever the setting can be moved
        // at all, because something has to record that Ledge asked for it;
        // what the entry *carries* depends on who keeps the prior. The daemon
        // keeps its own, per power source, so this records nothing but the
        // request — see `LidConserveRecord.LowPower.wasOn`.
        if entry.lowPower == nil, lowPower.canWrite {
            entry.lowPower = LidConserveRecord.LowPower(
                wasOn: lowPower.restoresItself ? nil : lowPower.isOn()
            )
        }

        // Never over a journal whose contents are unknown. The file that
        // could not be read may be the only account of this user's
        // brightness, and the values being written here were read off a Mac
        // that has already been conserved once.
        guard !unresolved else {
            Self.log.notice("lid: nothing is conserved while the record cannot be read")
            return
        }

        guard !entry.isEmpty else {
            // Nothing could be journalled, so nothing may be touched. Not an
            // error state and not a sticky one: `isConserving` stays false, so
            // a backlight that becomes readable later is picked up on the very
            // next pass rather than after the next session.
            Self.log.notice("lid: nothing could be conserved — no device had a restorable value")
            return
        }

        do {
            try journal.write(entry)
        } catch {
            // The disk refused, so the Mac is left exactly as it was. This is
            // the rule the order exists for, and it is the one branch that
            // must never be softened into "do it anyway and write later".
            Self.log.error("lid: the conserve record could not be written — nothing was changed")
            return
        }
        record = entry

        if entry.panel != nil, !panel.setLevel(0) {
            Self.log.notice("lid: the panel refused to darken")
        }
        if entry.keyboard != nil, !keyboard.setLevel(0) {
            Self.log.notice("lid: the keyboard backlight refused to darken")
        }
        if let output = entry.audio,
           !audio.setMuted(true, uid: output.uid, governed: output.governed).isSettled {
            Self.log.notice("lid: the output refused to mute")
        }
        if entry.lowPower != nil, !lowPower.set(true) {
            Self.log.notice("lid: Low Power Mode refused to come on")
        }

        isConserving = true
    }

    // MARK: - Restoring

    /// Undoes every entry it can, and keeps the ones it cannot.
    ///
    /// Entry by entry, because a panel that came back is not evidence that a
    /// headset did. Clearing the whole record on the first success would be an
    /// opinion dressed as a fact, and the fact it would be dressing up is that
    /// somebody's audio is still muted.
    private func drain(floorWantsLowPower: Bool) {
        guard var left = record else { return }

        // Adopted *before* the entry is cleared. The entry is the last
        // trustworthy account of what the user had, and the moment it goes the
        // only thing left to sample is the hardware it was protecting. A
        // restore that cleared its entry without handing the value back left
        // the next conserve journalling the level it had just restored from.
        if let entry = left.panel, restored(entry, on: panel) {
            panelSample.adopt(entry.level)
            left.panel = nil
        }
        if let entry = left.keyboard, restored(entry, on: keyboard) {
            keyboardSample.adopt(entry.level)
            left.keyboard = nil
        }
        if let entry = left.audio, restored(entry) {
            left.audio = nil
        }
        if let entry = left.lowPower {
            let wanted = LidRestore.lowPower(entry, floorWantsIt: floorWantsLowPower)
            if lowPower.set(wanted) { left.lowPower = nil }
        }

        if !left.isEmpty {
            Self.log.notice("lid: part of the conserve could not be put back and is still recorded")
        }
        persist(left)
    }

    /// One manual brightness key step, which is the coarsest the hardware is
    /// known to quantise to.
    ///
    /// Derived from the keyboard's own 1/16 ladder, **not measured on a
    /// panel**. It is the width of the allowance, not evidence about any
    /// particular display.
    static let backlightStep = 0.0625

    /// How far a restored backlight may sit from the value asked for and
    /// still count as restored.
    ///
    /// A flat allowance was wrong, and wrong in the one direction that
    /// matters: 0.08 accepted *zero* for every saved level at or below it, so
    /// a panel the user had left at 0.0625, darkened and then never actually
    /// restored, read back as 0 and cleared its own record. The allowance has
    /// to shrink with the value it is allowing against.
    ///
    /// Half the saved level, capped at one step and floored just above float
    /// noise. At 0.62 that is a full step; at 0.0625 it is 0.03; at 0.01 it is
    /// 0.005. None of them can reach zero from a positive value.
    static func backlightTolerance(for level: Double) -> Double {
        min(backlightStep, max(level / 2, 0.004))
    }

    /// One backlight, put back and then *read* to see whether it went.
    ///
    /// `setLevel` returns an API acknowledgement. Neither DisplayServices nor
    /// CoreBrightness promises that the panel moved, and a restore believed on
    /// the strength of that return value cleared the journal with the screen
    /// still at zero — the one state the user cannot fix, because the keys
    /// that would fix it are under the lid.
    ///
    /// An unreadable level keeps the entry. An obligation nobody can discharge
    /// is an obligation that stays.
    private func restored(_ entry: LidConserveRecord.Level, on backlight: any Backlight) -> Bool {
        guard backlight.isAvailable else { return false }
        guard backlight.setLevel(entry.level) else { return false }
        guard let seen = backlight.level(), seen.isFinite else {
            Self.log.notice("lid: \(backlight.name, privacy: .public) would not say what it reads after the restore — its entry is kept")
            return false
        }
        // The rule the allowance exists for, stated on its own so no width of
        // allowance can ever swallow it: a backlight the user had *on* is
        // never discharged by a reading of off. A dark panel is the failure
        // the readback was added to catch, and at low saved levels a flat
        // allowance caught nothing at all.
        if entry.level > 0, seen <= 0 {
            Self.log.notice("lid: \(backlight.name, privacy: .public) reads as off after a restore to a level that was on — its entry is kept")
            return false
        }
        guard abs(seen - entry.level) <= Self.backlightTolerance(for: entry.level) else {
            Self.log.notice("lid: \(backlight.name, privacy: .public) took the restore and did not move — its entry is kept")
            return false
        }
        return true
    }

    /// One output device, put back the way it was.
    private func restored(_ entry: LidConserveRecord.Audio) -> Bool {
        // Before anything is read or written: a record that cannot say which
        // controls it owns owns none of them.
        //
        // The guard used to sit on the mute alone, which left the *level*
        // write in front of it — so a planless record could not establish
        // silence and still pushed a saved level onto a live, unmuted output.
        // An audible change made on the strength of a record already known to
        // be unusable, repeated on every pass.
        guard let governed = entry.governed, !governed.isEmpty else {
            Self.log.notice(
                """
                lid: the output's entry names no controls — nothing is written \
                and it is kept
                """
            )
            return false
        }

        // Read through the plan the entry carries, not through whatever the
        // hardware nominates as its mute control today.
        let present = audio.observe(uid: entry.uid, governed: governed)
        // Whether anybody has decided anything about this output since the
        // entry was written. A record is an account of what things used to
        // be; a decision taken since outranks it.
        //
        // Nil in the entry means the question cannot be answered — another
        // process wrote the record — and an unanswerable question is not
        // evidence that anybody acted, so the restore goes ahead.
        let intentChanged = Self.intentChanged(entry, since: present)
        switch LidRestore.audio(entry, isPresent: present != nil,
                                isMutedNow: present?.muted ?? nil,
                                intentChanged: intentChanged) {
        case .deviceAbsent:
            // macOS remembers a device's volume across unplugging, so a headset
            // that was pulled while the lid was down comes back muted unless
            // this entry survives to meet it.
            Self.log.notice("lid: the muted output is not attached — its entry is kept")
            return false
        case .leaveAlone:
            // Either the user reached for the mute key themselves and the
            // silence Ledge made is already gone, or they decided something
            // about this output while the lid was down. Both end the same
            // way: whatever state it is in now is theirs, including the
            // reasons — a saved meaning written back over a newer one is a
            // mute they asked for being quietly taken away.
            return true
        case .put(let muted):
            // The mute, and only the mute.
            //
            // The level used to go back first, on the rule that sound must
            // never return at a level nobody chose. The rule is right and the
            // premise was wrong: the conserve never changes a level. Muting
            // is the one thing it does to an audio device, so the level the
            // user had when the lid came down is the level that is still
            // there when it comes up, and writing a remembered one over it is
            // changing a control Ledge never moved — the same mistake as
            // every other one this file guards against, only deliberate.
            //
            // So the ordering question goes away with it. There is no level
            // to get back before the sound does.
            guard audio.setMuted(muted, uid: entry.uid,
                                 governed: entry.governed).isSettled else { return false }
            // And why it was silent, which the mute control cannot say. A
            // device at a clamped logical zero is silent with no user mute in
            // force, and leaving Ledge's conserve-time reasons in place would
            // hand the user back a red pill they never pressed.
            if let userMuted = entry.userMuted, let zeroSilence = entry.zeroSilence {
                audio.restoreReasons(
                    MuteReasons(userMuted: userMuted, zeroSilence: zeroSilence),
                    uid: entry.uid
                )
            }
            return true
        }
    }

    /// Whether somebody has declared something about this output since the
    /// entry was written.
    ///
    /// Three ways the answer is *no*, and only one is "nothing happened". The
    /// record may name a ledger that no longer exists — another launch of the
    /// app, which counts from zero, so a saved number could never match and
    /// every recovered record read as a user decision. The output may have
    /// been forgotten and come back at zero, which is not later than anything.
    /// Or nothing may have been declared at all. None of those is evidence
    /// that the silence Ledge made has become somebody else's, and treating
    /// them as such throws away the only account of how to undo it.
    ///
    /// Later, never different: the comparison is one-directional on purpose.
    static func intentChanged(_ entry: LidConserveRecord.Audio,
                              since present: AudioOutputReading?) -> Bool {
        guard let present,
              let incarnation = entry.intentIncarnation,
              incarnation == present.intentIncarnation,
              let seen = entry.intentRevision
        else { return false }
        return present.intentRevision > seen
    }

    /// Writes down what is left, or removes the file when nothing is.
    ///
    /// A disk that refuses here leaves the *older*, larger record on it. That
    /// is the harmless direction: the next pass restores something that is
    /// already restored, which is a write of a value to the value it already
    /// has. The other direction would forget a device that is still muted.
    private func persist(_ left: LidConserveRecord) {
        do {
            if left.isEmpty {
                try journal.clear()
                record = nil
            } else {
                try journal.write(left)
                record = left
            }
        } catch {
            Self.log.error("lid: what is left of the conserve record could not be written")
            record = left
        }
    }
}
