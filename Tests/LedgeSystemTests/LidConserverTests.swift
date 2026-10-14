import CoreAudio
import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

/// What a closing lid does, and — the part that matters — how it is undone.
///
/// Every device here is a fake. That is not a convenience: a panel at zero on
/// the machine running the suite is a black screen, a muted output is a test
/// that silenced somebody's Mac, and Low Power Mode left on is a Mac that
/// throttles for the rest of the afternoon. Each of those is a test that
/// failed by passing.
@Suite("What a closed lid conserves")
struct LidConserverTests {

    // MARK: - A Mac to close

    struct Mac {
        let journal = MemoryLidJournal()
        let panel = FakeBacklight(name: "panel", level: 0.62)
        let keyboard = FakeBacklight(name: "keyboard", level: 0.3)
        let audio = FakeLidAudio(current: AudioOutputReading(
            uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
            volume: 0.45, muted: false
        ))
        let lowPower = FakeLowPower()
        let clock = Clock()

        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var instant = Date(timeIntervalSince1970: 1_000_000)
            var now: Date { lock.withLock { instant } }
            func advance(_ seconds: TimeInterval) {
                lock.withLock { instant = instant.addingTimeInterval(seconds) }
            }
        }

        func conserver() -> LidConserver {
            LidConserver(journal: journal, panel: panel, keyboard: keyboard,
                         audio: audio, lowPower: lowPower,
                         boot: { "BOOT-TEST" }, now: { clock.now })
        }
    }

    private static let open = LidReading(state: .open, builtInIsOnlyDisplay: true)
    private static let closed = LidReading(state: .closed, builtInIsOnlyDisplay: true)
    private static let clamshell = LidReading(state: .closed, builtInIsOnlyDisplay: false)

    /// A session that has been running with the lid up long enough to have
    /// sampled a brightness, which is the only state a conserve may start from.
    private func settled(_ mac: Mac) async -> LidConserver {
        let conserver = mac.conserver()
        await conserver.sessionBegan()
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        return conserver
    }

    // MARK: - Conserving

    @Test("Closing the lid darkens both backlights and mutes the output")
    func closingConserves() async {
        let mac = Mac()
        let conserver = await settled(mac)
        let outcome = await conserver.update(reading: Self.closed,
                                             sessionRunning: true, sessionID: "S1")

        #expect(outcome.action == .conserve)
        #expect(outcome.isConserving)
        #expect(mac.panel.lastWrite == 0)
        #expect(mac.keyboard.lastWrite == 0)
        #expect(mac.audio.state(uid: "BuiltInSpeakerDevice")?.muted == true)
    }

    /// The whole point of the sampler, seen from the outside: the panel is
    /// already dimmed by the time the close is reported, and what gets
    /// journalled is the value from before — not the one readable now.
    @Test("What is journalled is the level sampled with the lid up")
    func journalsTheSampledLevel() async {
        let mac = Mac()
        let conserver = await settled(mac)
        // Auto-brightness pulls the panel down as the lid comes over the
        // sensor, before macOS says a word about the hinge.
        mac.panel.setReadLevel(0.08)

        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        #expect(mac.journal.onDisk?.panel?.level == 0.62)
        #expect(mac.journal.onDisk?.panel?.level != 0.08)
    }

    /// The entry belongs to the device, not to "the default output" — a
    /// restore aimed at whatever is default when it runs would put one
    /// device's volume onto another.
    @Test("The audio entry carries the device, not the role")
    func audioEntryIsTheDevice() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        let entry = mac.journal.onDisk?.audio
        #expect(entry?.uid == "BuiltInSpeakerDevice")
        #expect(entry?.volume == 0.45)
        #expect(entry?.muted == false)
    }

    /// Shut with an external display is a Mac on a desk with somebody working
    /// at it. Darkening and muting that would be an unpleasant surprise.
    @Test("Clamshell with an external display conserves nothing")
    func clamshellIsLeftAlone() async {
        let mac = Mac()
        let conserver = await settled(mac)
        let outcome = await conserver.update(reading: Self.clamshell,
                                             sessionRunning: true, sessionID: "S1")
        #expect(outcome.action == .none)
        #expect(mac.journal.onDisk == nil)
        #expect(mac.panel.writeLog.isEmpty)
    }

    @Test("No session, nothing conserved, whatever the lid is doing")
    func noSessionNoConserve() async {
        let mac = Mac()
        let conserver = mac.conserver()
        let outcome = await conserver.update(reading: Self.closed, sessionRunning: false)
        #expect(outcome.action == .none)
        #expect(mac.journal.onDisk == nil)
    }

    // MARK: - Never darken what cannot be restored

    /// The rule the whole file is arranged around. A panel at zero with no
    /// restorable record is a black screen the user cannot fix by any means
    /// they would think of — the brightness keys are under the lid.
    @Test("A backlight with no sampled level is never darkened")
    func noSampleNoDarkening() async {
        let mac = Mac()
        let conserver = mac.conserver()
        // A session that began with the lid already shut: nothing was ever
        // sampled, so there is nothing to put back.
        await conserver.sessionBegan()
        let outcome = await conserver.update(reading: Self.closed,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.panel.writeLog.isEmpty, "a panel was darkened with no value to restore")
        #expect(mac.keyboard.writeLog.isEmpty)
        #expect(mac.journal.onDisk?.panel == nil)
        // The output still has a reading of its own, so that half is honest.
        #expect(outcome.isConserving)
    }

    @Test("A backlight whose symbols do not match is skipped, and journals nothing")
    func unavailableBacklightIsSkipped() async {
        let mac = Mac()
        mac.keyboard.setAvailable(false)
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(mac.keyboard.writeLog.isEmpty, "an unreachable backlight was darkened")
        #expect(mac.journal.onDisk?.keyboard == nil)
        // And the panel, which is fine, is unaffected by the keyboard's trouble.
        #expect(mac.panel.lastWrite == 0)
        #expect(mac.journal.onDisk?.panel?.level == 0.62)
    }

    /// The gate that survived the first mutation run, and the case it is
    /// actually for: the backlight answered a moment ago, so there *is* a
    /// sampled level, and by the time the lid comes down it will not answer
    /// any more. A level in hand is not permission — the question is whether
    /// the device can be written to, now, and put back later.
    @Test("A backlight that was readable and is no longer is still not darkened")
    func backlightLostBetweenSampleAndClose() async {
        let mac = Mac()
        let conserver = await settled(mac)
        #expect(await conserver.heldKeyboardBrightness == 0.3, "nothing was sampled to lose")

        // The framework moved under us: the gate refuses from here on.
        mac.keyboard.setAvailable(false)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(mac.keyboard.writeLog.isEmpty,
                "a backlight that can no longer be reached was darkened anyway")
        #expect(mac.journal.onDisk?.keyboard == nil)
        #expect(mac.journal.onDisk?.panel?.level == 0.62, "the panel paid for the keyboard")
    }

    /// Nothing journallable means nothing touched — and, deliberately, not a
    /// sticky state: a backlight that becomes readable later is picked up on
    /// the next pass rather than after the next session.
    @Test("A Mac where nothing can be conserved is left entirely alone")
    func nothingToConserve() async {
        let mac = Mac()
        mac.panel.setAvailable(false)
        mac.keyboard.setAvailable(false)
        mac.audio.detach(uid: "BuiltInSpeakerDevice")
        let conserver = await settled(mac)
        let outcome = await conserver.update(reading: Self.closed,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.journal.onDisk == nil)
        #expect(!outcome.isConserving)
        #expect(mac.panel.writeLog.isEmpty)
    }

    // MARK: - Journal first, always

    /// The order is the whole safety rule: a record of a change that never
    /// happened costs one pointless restore, and a change with no record is a
    /// black screen inside a closed machine.
    @Test("A journal that refuses the write means nothing is changed at all")
    func refusedJournalChangesNothing() async {
        let mac = Mac()
        let conserver = await settled(mac)
        mac.journal.failWrites(true)

        let outcome = await conserver.update(reading: Self.closed,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.panel.writeLog.isEmpty, "the panel was darkened without a record")
        #expect(mac.keyboard.writeLog.isEmpty)
        #expect(mac.audio.mutes.isEmpty, "the output was muted without a record")
        #expect(mac.journal.onDisk == nil)
        #expect(!outcome.isConserving)
    }

    /// And it is not a one-shot failure: the disk coming back means the next
    /// pass conserves, rather than a session that silently never does.
    @Test("A disk that comes back is used on the very next pass")
    func retriesAfterTheDiskRecovers() async {
        let mac = Mac()
        let conserver = await settled(mac)
        mac.journal.failWrites(true)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        mac.journal.failWrites(false)

        let outcome = await conserver.update(reading: Self.closed,
                                             sessionRunning: true, sessionID: "S1")
        #expect(outcome.action == .conserve)
        #expect(mac.panel.lastWrite == 0)
        #expect(mac.journal.onDisk?.panel?.level == 0.62)
    }

    // MARK: - Restoring

    @Test("Opening the lid puts everything back")
    func openingRestores() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        #expect(outcome.action == .restore)
        #expect(!outcome.isConserving)
        #expect(mac.panel.lastWrite == 0.62)
        #expect(mac.keyboard.lastWrite == 0.3)
        #expect(mac.audio.state(uid: "BuiltInSpeakerDevice")?.muted == false)
        #expect(mac.audio.state(uid: "BuiltInSpeakerDevice")?.volume == 0.45)
        #expect(mac.journal.onDisk == nil, "a finished restore left its record behind")
    }

    /// The case a policy keyed only on the lid would miss: the Mac stays shut,
    /// so nothing changes, and the screen stays dark after the hold has gone.
    @Test("A session ending under a shut lid puts everything back")
    func sessionEndRestores() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        let outcome = await conserver.sessionEnded()
        #expect(outcome.action == .restore)
        #expect(mac.panel.lastWrite == 0.62)
        #expect(mac.journal.onDisk == nil)
    }

    @Test("An external display appearing mid-session puts everything back")
    func externalDisplayRestores() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        let outcome = await conserver.update(reading: Self.clamshell,
                                             sessionRunning: true, sessionID: "S1")
        #expect(outcome.action == .restore)
        #expect(mac.panel.lastWrite == 0.62)
    }

    /// A Mac that wakes for Power Nap has a lit panel again, and nobody there
    /// to see it.
    @Test("A wake under a shut lid conserves again")
    func wakeReapplies() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        // Open, restore, shut again — the shape a wake takes from here.
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        mac.clock.advance(60)
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        let outcome = await conserver.update(reading: Self.closed,
                                             sessionRunning: true, sessionID: "S1")

        #expect(outcome.action == .conserve)
        #expect(mac.panel.lastWrite == 0)
    }

    @Test("Nothing happens when nothing has changed")
    func idempotent() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        let writesBefore = mac.journal.writes

        for _ in 0..<5 {
            let outcome = await conserver.update(reading: Self.closed,
                                                 sessionRunning: true, sessionID: "S1")
            #expect(outcome.action == .none)
        }
        #expect(mac.journal.writes == writesBefore, "an idle pass re-journalled")
        #expect(mac.panel.writeLog == [0], "an idle pass darkened the panel again")
    }

    // MARK: - A restore that fails keeps trying

    @Test("A backlight that refuses to come back keeps its entry")
    func failedRestoreKeepsTheRecord() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        mac.panel.setAccepts(false)
        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        #expect(outcome.outstanding?.panel?.level == 0.62)
        #expect(mac.journal.onDisk?.panel?.level == 0.62)
        // And the halves that worked are gone from the record.
        #expect(mac.journal.onDisk?.audio == nil)
        #expect(mac.journal.onDisk?.keyboard == nil)
    }

    @Test("An entry that could not be put back is tried again on the next pass")
    func keepsTrying() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        mac.panel.setAccepts(false)
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")

        mac.panel.setAccepts(true)
        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.panel.lastWrite == 0.62)
        #expect(outcome.outstanding == nil)
        #expect(mac.journal.onDisk == nil)
    }

    /// A panel that came back is not evidence that a headset did.
    @Test("Entries clear one at a time, never all together")
    func entriesClearIndependently() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        mac.audio.setAcceptsMute(false)
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")

        #expect(mac.journal.onDisk?.panel == nil, "a restored panel kept its entry")
        #expect(mac.journal.onDisk?.audio?.uid == "BuiltInSpeakerDevice",
                "an unrestored output lost its entry")
    }

    // MARK: - Audio, which belongs to its device

    /// The user reached for the mute key themselves while the lid was down.
    @Test("A device the user unmuted is left exactly as they left it")
    func userUnmuteWins() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        mac.audio.userSets(muted: false, uid: "BuiltInSpeakerDevice")
        let mutesBefore = mac.audio.mutes.count
        let writesBefore = mac.audio.writeOrder.count

        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.mutes.count == mutesBefore, "a device the user unmuted was written to")
        #expect(mac.audio.writeOrder.count == writesBefore,
                "something was written to a device the user had already freed")
        #expect(mac.journal.onDisk == nil, "the entry outlived the decision it recorded")
    }

    /// macOS remembers a device's volume across unplugging, so a headset
    /// pulled while the lid was down comes back muted unless the entry
    /// survives to meet it.
    @Test("A headset unplugged mid-conserve keeps its entry until it returns")
    func unpluggedDeviceKeepsItsEntry() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "AirPods", name: "AirPods Pro",
                                          volume: 0.8, muted: false), asDefault: true)
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        #expect(mac.audio.state(uid: "AirPods")?.muted == true)

        mac.audio.detach(uid: "AirPods")
        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")
        #expect(outcome.outstanding?.audio?.uid == "AirPods")

        // It comes back the way macOS gives it back: still muted.
        mac.audio.plug(AudioOutputReading(uid: "AirPods", name: "AirPods Pro",
                                          volume: 0.0, muted: true))
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        #expect(mac.audio.state(uid: "AirPods")?.muted == false)
        // And its level is left exactly where it came back. 0.0 is what macOS
        // handed over; Ledge never moved it in either direction, so it has
        // nothing to put back and no business trying.
        #expect(mac.audio.state(uid: "AirPods")?.volume == 0.0,
                "the restore wrote a level it had never changed")
        #expect(mac.journal.onDisk == nil)
    }

    /// A restore aimed at "the default output" would put the speakers' volume
    /// onto a headset the user plugged in while the lid was down.
    @Test("A device that became default meanwhile is never written to")
    func anotherDeviceIsNeverTouched() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        mac.audio.plug(AudioOutputReading(uid: "Headphones", name: "Headphones",
                                          volume: 0.15, muted: false), asDefault: true)
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.state(uid: "Headphones")?.volume == 0.15,
                "another device's volume was overwritten by the restore")
        #expect(mac.audio.state(uid: "Headphones")?.muted == false)
        #expect(mac.audio.mutes.allSatisfy { $0.uid == "BuiltInSpeakerDevice" })
    }

    /// The ordering rule that used to live here — level back first, unmute
    /// only if it landed — existed to stop sound returning at a level nobody
    /// chose. It was right about the danger and wrong about the cause: the
    /// conserve never moves a level, so there is no level to get back.
    ///
    /// What is left is the rule that replaced it. Muting is the only thing
    /// Ledge does to an audio device, so unmuting is the only thing it may
    /// undo, and this fails the moment anything else is written.
    @Test("Nothing but the mute is ever written to an output")
    func onlyTheMuteIsEverWritten() async {
        let mac = Mac()
        mac.audio.setLevels([1: 0.2, 2: 0.8], uid: "BuiltInSpeakerDevice")
        let conserver = await settled(mac)

        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.writeOrder == ["mute", "mute"],
                "the conserve wrote something other than the mute: \(mac.audio.writeOrder)")
        #expect(mac.audio.levels(uid: "BuiltInSpeakerDevice") == [1: 0.2, 2: 0.8],
                "a level the user set was changed by a feature that only mutes")
        #expect(mac.audio.state(uid: "BuiltInSpeakerDevice")?.muted == false)
    }

    // MARK: - Low Power Mode, which is behind a seam

    /// `pmset -a lowpowermode 1` is root, and the preference file is
    /// `root:wheel 0644`. An app that is not root cannot move it, and this one
    /// does not pretend to: it journals nothing, so it restores nothing.
    @Test("An app that cannot set Low Power Mode never claims it")
    func lowPowerIsNotClaimedWhenItCannotBeSet() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(mac.journal.onDisk?.lowPower == nil)
        #expect(mac.lowPower.writeLog.isEmpty)
    }

    /// The seam, exercised: what the privileged version will do once there is
    /// one. Default on, as Insomnia has it.
    @Test("A Low Power Mode that can be set goes on at close and off at open")
    func lowPowerThroughTheSeam() async {
        let mac = Mac()
        let lowPower = FakeLowPower(canWrite: true, on: false)
        let conserver = LidConserver(
            journal: mac.journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        await conserver.sessionBegan()
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(mac.journal.onDisk?.lowPower?.wasOn == false)
        #expect(lowPower.isOn() == true)

        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        #expect(lowPower.isOn() == false)
        #expect(lowPower.writeLog == [true, false])
    }

    /// Turning it off for a user who had it on themselves would be Ledge
    /// undoing a decision it never made.
    @Test("Low Power Mode the user had on is left on")
    func lowPowerAlreadyOnStaysOn() async {
        let mac = Mac()
        let lowPower = FakeLowPower(canWrite: true, on: true)
        let conserver = LidConserver(
            journal: mac.journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        await conserver.sessionBegan()
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")

        #expect(lowPower.isOn() == true)
    }

    /// The daemon journals the prior once per power source, before it writes
    /// and cleared only after a readback. A second, coarser record here would
    /// disagree with it for exactly the user who set Low Power Mode on battery
    /// only — a state a single `wasOn` cannot even express.
    @Test("A control that keeps its own record is not shadowed by a second one")
    func daemonKeepsItsOwnPrior() async {
        let mac = Mac()
        let lowPower = FakeLowPower(canWrite: true, on: true, restoresItself: true)
        let conserver = LidConserver(
            journal: mac.journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        await conserver.sessionBegan()
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        // The entry exists — something has to say Ledge asked and has not
        // taken it back — and it carries no opinion about the prior.
        #expect(mac.journal.onDisk?.lowPower != nil)
        #expect(mac.journal.onDisk?.lowPower?.wasOn == nil,
                "a second, coarser record of the prior was kept")
        #expect(lowPower.writeLog == [true])

        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        // `false` is "Ledge is finished with it", which the daemon turns into
        // "put it back to what I journalled" — not "off".
        #expect(lowPower.writeLog == [true, false])
        #expect(mac.journal.onDisk == nil)
    }

    /// A control that keeps no record of its own needs this one, and the value
    /// in it is what gets written back.
    @Test("A control with no record of its own gets one here")
    func directControlIsJournalledHere() async {
        let mac = Mac()
        let lowPower = FakeLowPower(canWrite: true, on: true, restoresItself: false)
        let conserver = LidConserver(
            journal: mac.journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        await conserver.sessionBegan()
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(mac.journal.onDisk?.lowPower?.wasOn == true)
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        #expect(lowPower.isOn() == true, "a setting the user had on was switched off")
    }

    /// A Mac with no daemon installed still gets every other saving. Low Power
    /// Mode is the only one that needs root, and the only one it loses.
    @Test("No helper costs Low Power Mode and nothing else")
    func noHelperKeepsEverythingElse() async {
        let mac = Mac()
        let conserver = LidConserver(
            journal: mac.journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: UnprivilegedLowPowerMode(),
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        await conserver.sessionBegan()
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(mac.journal.onDisk?.lowPower == nil)
        #expect(mac.panel.lastWrite == 0)
        #expect(mac.keyboard.lastWrite == 0)
        #expect(mac.audio.state(uid: "BuiltInSpeakerDevice")?.muted == true)
    }

    @Test("The real Low Power Mode refuses to write and says so")
    func theRealOneRefuses() {
        let real = UnprivilegedLowPowerMode()
        #expect(!real.canWrite)
        #expect(!real.set(true))
        #expect(!real.set(false))
        // Reading is free, and is the one half that works.
        #expect(real.isOn() != nil)
    }

    // MARK: - Recovery

    /// The app can be force-quit, crash, or be replaced by an update with the
    /// lid shut and the panel at zero. The file is the only thing that knows.
    @Test("A record left by a dead process is put back at launch")
    func recoversAfterACrash() async {
        let journal = MemoryLidJournal(LidConserveRecord(
            boot: "AN-EARLIER-BOOT", sessionID: "S0",
            writtenAt: Date(timeIntervalSince1970: 1),
            panel: .init(level: 0.55), keyboard: .init(level: 0.25),
            audio: .init(uid: "BuiltInSpeakerDevice", volume: 0.3, muted: false,
                         governed: [0])
        ))
        let mac = Mac()
        mac.audio.userSets(muted: true, uid: "BuiltInSpeakerDevice")
        let conserver = LidConserver(
            journal: journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )

        let outcome = await conserver.recover()
        #expect(mac.panel.lastWrite == 0.55)
        #expect(mac.keyboard.lastWrite == 0.25)
        #expect(mac.audio.state(uid: "BuiltInSpeakerDevice")?.muted == false)
        #expect(outcome.outstanding == nil)
        #expect(journal.onDisk == nil)
    }

    @Test("A launch with nothing recorded changes nothing")
    func recoveryWithNoRecord() async {
        let mac = Mac()
        let conserver = mac.conserver()
        let outcome = await conserver.recover()
        #expect(outcome.outstanding == nil)
        #expect(mac.panel.writeLog.isEmpty)
        #expect(mac.audio.mutes.isEmpty)
    }

    /// It is the only account of what may still be dark on this Mac, and Ledge
    /// is not entitled to destroy it just because it cannot parse it.
    @Test("An unreadable record is set aside, not deleted")
    func unreadableRecordIsSetAside() async {
        let mac = Mac()
        mac.journal.failReads(true, as: .unreadable)
        let conserver = mac.conserver()
        await conserver.recover()
        #expect(mac.journal.asides == 1)
    }

    /// The worst outcome this feature has: a black panel and no record of
    /// what it was. A file that cannot be *reached* is almost certainly still
    /// exactly what it was, so nothing may be written over it — and the
    /// values that would be written are read off a Mac that has already been
    /// darkened once.
    @Test("A record nobody could read is never written over")
    func unreachableRecordIsNotOverwritten() async {
        let mac = Mac()
        let original = LidConserveRecord(
            boot: "EARLIER", sessionID: "S0", writtenAt: Date(timeIntervalSince1970: 1),
            panel: .init(level: 0.6)
        )
        let journal = MemoryLidJournal(original)
        journal.failReads(true, as: .unavailable)
        // The panel is already at zero, which is what a conserve would now
        // sample and journal in place of the 0.6 nobody could read.
        mac.panel.setReadLevel(0)
        let conserver = LidConserver(
            journal: journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )

        await conserver.recover()
        #expect(journal.asides == 0, "a file that could not be reached was set aside")

        await conserver.sessionBegan()
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(journal.onDisk?.panel?.level == 0.6,
                "the only account of the user's brightness was replaced with zero")
        #expect(mac.panel.writeLog.isEmpty, "a panel was darkened with no usable record")

        // And once the disk answers again, the original is honoured.
        journal.failReads(false)
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        #expect(mac.panel.level() == 0.6, "the recovered prior was never put back")
    }

    /// The sequence the previous test stopped short of. A recovery that
    /// succeeds is immediately followed by a conserve — and the baseline that
    /// conserve uses was sampled while the journal was unreadable, off a Mac
    /// that was already dark. The restored 0.6 was journalled away as 0 by the
    /// very pass that had just put it back.
    @Test("A recovered prior is not replaced by a sample taken before it")
    func recoveredPriorSurvivesTheNextConserve() async {
        let mac = Mac()
        let journal = MemoryLidJournal(LidConserveRecord(
            boot: "EARLIER", sessionID: "S0", writtenAt: Date(timeIntervalSince1970: 1),
            panel: .init(level: 0.6)
        ))
        journal.failReads(true, as: .unavailable)
        mac.panel.setReadLevel(0)
        let conserver = LidConserver(
            journal: journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )

        await conserver.recover()
        await conserver.sessionBegan()
        // An open pass while the journal is still unreadable. Nothing may be
        // sampled here: the panel in front of us is the conserved one.
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        #expect(await conserver.heldPanelBrightness != 0,
                "a darkened panel became the baseline while the record was unknown")

        // The disk comes back, and the next pass is a close.
        journal.failReads(false)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(journal.onDisk?.panel?.level == 0.6,
                "the recovered prior was journalled away as the level it had been restored from")
        await conserver.sessionEnded()
        #expect(mac.panel.level() == 0.6, "the panel was left dark")
    }

    /// A readable journal whose restore simply *fails* leaves the same
    /// darkened hardware as an unreadable one. Sampling it made zero the
    /// trusted baseline, and the conserve that followed the eventual
    /// successful restore wrote that zero back as the prior — so the original
    /// was lost by the very pass that had just put it back.
    @Test("A failed restore does not poison the next baseline")
    func failedRestoreDoesNotPoisonTheBaseline() async {
        let mac = Mac()
        mac.keyboard.setReadLevel(0.4)
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "A")
        #expect(mac.journal.onDisk?.panel?.level == 0.62)

        // The restore is refused, so both entries stay — and the hardware
        // stays dark.
        mac.panel.setAccepts(false)
        mac.keyboard.setAccepts(false)
        await conserver.sessionEnded()
        #expect(await conserver.outstanding?.panel?.level == 0.62)
        #expect(mac.panel.level() == 0)

        // The lid opens and the sampler comes due over that dark panel.
        mac.clock.advance(31)
        await conserver.update(reading: Self.open, sessionRunning: false)
        #expect(await conserver.heldPanelBrightness == 0.62,
                "a backlight that has not been put back became the user's baseline")

        // The setters start working, a new session begins, and the lid shuts.
        mac.panel.setAccepts(true)
        mac.keyboard.setAccepts(true)
        await conserver.sessionBegan()
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "B")

        #expect(mac.journal.onDisk?.panel?.level == 0.62,
                "the restored prior was journalled away as the level it was restored from")
        #expect(mac.journal.onDisk?.keyboard?.level == 0.4)

        await conserver.sessionEnded()
        #expect(mac.panel.level() == 0.62, "the panel was left dark")
        #expect(mac.keyboard.level() == 0.4)
    }

    /// And a healthy component is not frozen because its neighbour is stuck.
    @Test("One outstanding backlight does not stop the other being sampled")
    func componentsFreezeIndependently() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "A")

        // Only the panel refuses to come back.
        mac.panel.setAccepts(false)
        await conserver.sessionEnded()
        #expect(await conserver.outstanding?.panel != nil)
        #expect(await conserver.outstanding?.keyboard == nil)

        // The keyboard is free, so a genuine new reading of it is adopted.
        mac.keyboard.setReadLevel(0.55)
        mac.clock.advance(31)
        // The lid opening schedules a sample three seconds out, so the pass
        // that takes it is the one after the panel has settled.
        await conserver.update(reading: Self.open, sessionRunning: false)
        mac.clock.advance(4)
        await conserver.update(reading: Self.open, sessionRunning: false)

        #expect(await conserver.heldKeyboardBrightness == 0.55,
                "a healthy backlight was frozen because another one was stuck")
        #expect(await conserver.heldPanelBrightness == 0.62)
    }

    /// Same rule one step along: the file is rubbish *and* cannot be moved.
    /// It still stands, and so does whatever it says.
    @Test("An unreadable record that cannot be set aside is not written over")
    func failedQuarantineBlocksWrites() async {
        let mac = Mac()
        let journal = MemoryLidJournal(LidConserveRecord(
            writtenAt: Date(timeIntervalSince1970: 1), panel: .init(level: 0.6)
        ))
        journal.failReads(true, as: .unreadable)
        journal.failAside(true)
        mac.panel.setReadLevel(0)
        let conserver = LidConserver(
            journal: journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )

        await conserver.recover()
        await conserver.sessionBegan()
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(journal.onDisk?.panel?.level == 0.6,
                "a record that could not even be moved was written over")
        #expect(mac.panel.writeLog.isEmpty)
    }

    /// A conserve on top of an unrestored record must not overwrite the entry.
    ///
    /// The old entry is the truer account. A new one would be read off the
    /// *conserved* Mac — the muted device's own mute, the dark panel's own
    /// zero — so the restore would put back the very state it was meant to
    /// undo, and the user would get silence and a black screen handed to them
    /// as if they had chosen both.
    @Test("A conserve never overwrites an entry that is still outstanding")
    func conserveKeepsTheOlderEntry() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        // The restore cannot land, and goes on not landing: the panel refuses
        // every write and the output refuses every mute.
        mac.panel.setAccepts(false)
        mac.audio.setAcceptsMute(false)
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        #expect(await conserver.outstanding?.panel?.level == 0.62)

        // Time passes with the lid up, and a fresh sample finds the panel
        // where the failed restore left it rather than where the user put it.
        mac.panel.setReadLevel(0.1)
        mac.clock.advance(60)
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        // Frozen, not moved: the panel's entry is still outstanding, so what
        // the panel reads now is the conserved level rather than the user's.
        #expect(await conserver.heldPanelBrightness == 0.62,
                "a backlight that has not been put back was sampled into the baseline")

        // And now the lid comes down again on top of all of it.
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(mac.journal.onDisk?.panel?.level == 0.62,
                "the conserved state was journalled as the state to restore")
        #expect(mac.journal.onDisk?.audio?.muted == false,
                "a muted device's own mute became the thing to put back")
        #expect(mac.journal.onDisk?.audio?.volume == 0.45)
    }

    @Test("Both backlights keep their own level, not each other's")
    func backlightsAreSeparate() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")

        #expect(mac.panel.lastWrite == 0.62)
        #expect(mac.keyboard.lastWrite == 0.3)
    }
}

@Suite("The lid, the clock and the order they arrive in")
struct LidConserveDriverTests {

    @Test("A session begun on a Mac that is already shut conserves at once")
    func alreadyShutAtStart() async {
        let mac = LidConserverTests.Mac()
        // It has been open long enough to have a level worth keeping.
        let conserver = mac.conserver()
        await conserver.sessionBegan()
        await conserver.update(reading: LidReading(state: .open, builtInIsOnlyDisplay: true),
                               sessionRunning: true, sessionID: "S1")

        let sensor = FakeLidSensor(LidReading(state: .closed, builtInIsOnlyDisplay: true))
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)
        driver.begin(sessionID: "S1")
        await driver.settle()

        #expect(mac.panel.lastWrite == 0)
        driver.end()
        await driver.settle()
        #expect(mac.panel.lastWrite == 0.62)
        #expect(sensor.stopCount >= 1)
    }

    /// Two `Task`s on an actor each run to completion, but nothing says which
    /// goes first. A close and an open a few hundred milliseconds apart could
    /// land as open-then-close and leave the Mac conserving with its lid up.
    @Test("Events are acted on in the order they arrived")
    func eventsKeepTheirOrder() async {
        let mac = LidConserverTests.Mac()
        let conserver = mac.conserver()
        await conserver.sessionBegan()
        let sensor = FakeLidSensor(LidReading(state: .open, builtInIsOnlyDisplay: true))
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)
        driver.begin(sessionID: "S1")
        await driver.settle()

        for _ in 0..<20 {
            sensor.move(to: LidReading(state: .closed, builtInIsOnlyDisplay: true))
            sensor.move(to: LidReading(state: .open, builtInIsOnlyDisplay: true))
        }
        await driver.settle()

        // The last thing that happened was an open, so the panel is back.
        #expect(await conserver.isConserving == false)
        #expect(mac.panel.lastWrite == 0.62)
        #expect(await conserver.outstanding == nil)
    }

    /// The sharp version of the same thing: with a device slow enough that a
    /// second event lands while the first is still in the framework, an
    /// unchained queue finishes in whatever order the executor felt like — and
    /// `settle()` would be waiting on only the last task rather than on all of
    /// them.
    @Test("A slow device does not let a later event overtake an earlier one")
    func slowDeviceKeepsTheOrder() async {
        for _ in 0..<12 {
            let mac = LidConserverTests.Mac()
            let conserver = mac.conserver()
            await conserver.sessionBegan()
            let sensor = FakeLidSensor(LidReading(state: .open, builtInIsOnlyDisplay: true))
            let driver = LidConserveDriver(sensor: sensor, conserver: conserver)
            driver.begin(sessionID: "S1")
            await driver.settle()
            mac.panel.setDelay(microseconds: 1500)
            mac.keyboard.setDelay(microseconds: 1500)

            for _ in 0..<6 {
                sensor.move(to: LidReading(state: .closed, builtInIsOnlyDisplay: true))
                sensor.move(to: LidReading(state: .open, builtInIsOnlyDisplay: true))
            }
            // The last event was an open, so a Mac that is still conserving
            // after this is a Mac whose events were acted on out of order.
            await driver.settle()
            #expect(await conserver.isConserving == false)
            #expect(mac.panel.lastWrite == 0.62)
            #expect(await conserver.outstanding == nil)
        }
    }

    @Test("Ending twice is not an error and does not restore twice")
    func endIsIdempotent() async {
        let mac = LidConserverTests.Mac()
        let conserver = mac.conserver()
        let sensor = FakeLidSensor(LidReading(state: .open, builtInIsOnlyDisplay: true))
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)
        driver.begin(sessionID: "S1")
        await driver.settle()
        driver.end()
        driver.end()
        await driver.settle()
        #expect(await conserver.outstanding == nil)
    }
}

/// What this Mac actually says, as opposed to what the code hopes.
///
/// The encodings in `CoreBrightnessKeyboardBacklight` were measured once, on
/// one machine, on one release. The only thing that keeps them honest is a
/// test that reads them again — so the day Apple changes
/// `-setBrightness:forKeyboard:`, this fails here rather than in somebody's
/// keyboard going dark with no way back.
///
/// Nothing here writes. Reading a backlight is free; setting one in a test
/// would be a test that changed the machine it was run on.
@Suite("The keyboard backlight this Mac actually has")
struct KeyboardBacklightRealityTests {

    @Test("CoreBrightness still encodes the four methods the way they were measured")
    func encodingsHaveNotMoved() throws {
        let found = try #require(
            CoreBrightnessKeyboardBacklight.encodings(),
            "KeyboardBrightnessClient is not on this Mac — the gate refuses, which is correct"
        )
        for (method, expected) in CoreBrightnessKeyboardBacklight.expectedEncodings {
            #expect(found[method] == expected,
                    "\(method) now encodes as \(found[method] ?? "nothing")")
        }
        #expect(CoreBrightnessKeyboardBacklight.verdict() == .ok)
    }

    @Test("A backlight that passes the gate reports a level in range")
    func levelIsPlausible() {
        let backlight = CoreBrightnessKeyboardBacklight()
        guard backlight.isAvailable else { return }
        guard let level = backlight.level() else { return }
        #expect(level >= 0 && level <= 1)
    }

    /// The panel goes through the one brightness path this app already has,
    /// rather than a second one written for the lid.
    @Test("The panel backlight is the DisplayServices path, not a new one")
    @MainActor
    func panelReusesTheController() {
        let controller = BrightnessController()
        let backlight = PanelBacklight(controller: controller)
        #expect(backlight.isAvailable == controller.isSupported
                || !PrivateSymbol.exists("DisplayServicesSetBrightness", in: .displayServices))
        guard backlight.isAvailable, let level = backlight.level() else { return }
        #expect(level >= 0 && level <= 1)
        #expect(level == controller.level())
    }
}

/// What an independent review proved the restore story did not do.
///
/// Every test here began life as a counterexample: a fake-only reproduction
/// that ended with a panel at zero, a record cleared, or sound coming back at
/// a level nobody chose. They are kept in their own suite because that is what
/// they are — the shape of the failure, not a tour of the design.
@Suite("Restores that were believed and had not happened")
struct LidRestoreConfirmationTests {

    private typealias Mac = LidConserverTests.Mac
    private static let open = LidReading(state: .open, builtInIsOnlyDisplay: true)
    private static let closed = LidReading(state: .closed, builtInIsOnlyDisplay: true)

    private func settled(_ mac: Mac) async -> LidConserver {
        let conserver = mac.conserver()
        await conserver.sessionBegan()
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")
        return conserver
    }

    /// `DisplayServicesSetBrightness` and `-setBrightness:forKeyboard:` both
    /// return an API acknowledgement, not a reading. A restore believed on the
    /// strength of that cleared the journal with the panel still at zero —
    /// and the keys that would fix it are under the lid.
    @Test("A backlight that accepts the restore and does not move keeps its entry")
    func acknowledgedButIneffectiveRestoreKeepsItsEntry() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        #expect(mac.panel.lastWrite == 0)

        // From here the panel says yes to everything and moves for nothing.
        mac.panel.setIgnoresWrites(true)
        let outcome = await conserver.sessionEnded()

        #expect(outcome.outstanding?.panel?.level == 0.62,
                "a restore nobody confirmed cleared the record")
        #expect(mac.journal.onDisk?.panel?.level == 0.62)
        #expect(mac.panel.level() == 0, "the test did not reproduce the failure")
    }

    @Test("A backlight that comes back for real clears its entry")
    func confirmedRestoreClearsItsEntry() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        let outcome = await conserver.sessionEnded()

        #expect(outcome.outstanding == nil)
        #expect(mac.panel.level() == 0.62)
    }

    /// Hardware quantises. A panel asked for 0.62 can honestly settle on its
    /// own ladder a step away, and an obligation that can never be discharged
    /// is a record that never clears and a watch that never stops.
    @Test("A backlight that lands a hardware step away still counts as restored")
    func quantisationIsNotAFailure() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        // It takes the write and settles on the nearest step it has.
        mac.panel.setIgnoresWrites(true)
        mac.panel.setReadLevel(0.5625)
        let outcome = await conserver.sessionEnded()

        #expect(outcome.outstanding?.panel == nil,
                "one hardware step was treated as a failed restore")
    }

    /// The flat allowance was wrong in the one direction that matters. 0.08
    /// accepted *zero* for every saved level at or below it, so a panel the
    /// user had left near the bottom — darkened, then never actually restored
    /// — read back as 0 and cleared its own record. A positive prior must
    /// never be discharged by a dark panel, whatever the allowance is.
    @Test("A dark panel never passes for a low brightness that was on")
    func darkPanelNeverPassesALowLevel() async {
        // 0.002 is the one the allowance alone cannot catch: half of it is
        // below the floor, so the floor is wider than the distance from the
        // saved level to zero. Only the rule that a positive prior is never
        // discharged by a dark panel covers it.
        for saved in [0.0625, 0.03, 0.01, 0.005, 0.002] {
            let mac = Mac()
            mac.panel.setReadLevel(saved)
            let conserver = await settled(mac)
            await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
            #expect(mac.journal.onDisk?.panel?.level == saved)

            // The restore is taken and the panel does not move off zero.
            mac.panel.setIgnoresWrites(true)
            mac.panel.setReadLevel(0)
            let outcome = await conserver.sessionEnded()

            #expect(outcome.outstanding?.panel?.level == saved,
                    "a panel at zero cleared the only record of \(saved)")
        }
    }

    /// And the allowance has to *narrow* with the value, or it is no
    /// allowance at all down there: a flat 0.08 accepted a panel sitting
    /// anywhere below 0.08 as a restore of anything below 0.08.
    @Test("A low brightness restored to the wrong low brightness is not restored")
    func lowLevelRestoredToTheWrongValue() async {
        let mac = Mac()
        mac.panel.setReadLevel(0.0625)
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        // It moves, but to a third of where it was — far more than one step
        // at this level, and well inside a flat allowance.
        mac.panel.setIgnoresWrites(true)
        mac.panel.setReadLevel(0.02)
        let outcome = await conserver.sessionEnded()

        #expect(outcome.outstanding?.panel?.level == 0.0625,
                "a panel left at a third of its level passed for restored")
    }

    /// And the allowance still has to let real hardware through at those
    /// levels, or the entry could never be discharged at all.
    @Test("A low brightness that comes back is still accepted")
    func lowLevelRestoreStillClears() async {
        let mac = Mac()
        mac.panel.setReadLevel(0.0625)
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        // It lands on the nearest step its ladder has.
        mac.panel.setIgnoresWrites(true)
        mac.panel.setReadLevel(0.05)
        let outcome = await conserver.sessionEnded()

        #expect(outcome.outstanding?.panel == nil,
                "a low level that came back was treated as a failed restore")
    }

    @Test("A backlight that will not say what it reads keeps its entry")
    func unreadableBacklightKeepsItsEntry() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        mac.panel.setIgnoresWrites(true)
        mac.panel.setReadLevel(nil)
        let outcome = await conserver.sessionEnded()

        #expect(outcome.outstanding?.panel?.level == 0.62)
    }

    /// The other half of the same gap. A mute that needed no write at all was
    /// reported as a failure, because nothing had been accepted — so the entry
    /// never cleared and the watch never stopped.
    @Test("A device already in the state asked for is settled, not failed")
    func alreadySettledIsSuccess() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Quiet", name: "Quiet", volume: 0.3, muted: true),
                       asDefault: true)
        let conserver = await settled(mac)
        // It was already muted when the lid came down, so muting it again is
        // a write nobody needs — and so is unmuting it back to muted.
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        #expect(outcome.outstanding == nil,
                "a device that needed no write kept its entry for ever")
        #expect(mac.audio.state(uid: "Quiet")?.muted == true,
                "a device the user had muted was unmuted")
    }

    /// A device sitting at a clamped logical zero is silent with no user mute
    /// in force. Conserving through the user-mute path, and restoring through
    /// it again, handed the user back the red pill they never pressed.
    @Test("A device silent only because of its level does not come back muted by the user")
    func zeroSilenceIsNotUserMute() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.0, muted: true), asDefault: true)
        mac.audio.setReasons(MuteReasons(userMuted: false, zeroSilence: true), uid: "Speakers")
        let conserver = await settled(mac)

        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        // Ledge's own mute, echoing back through the volume watcher and
        // adopted as though somebody had meant it. Nobody declared anything —
        // the ledger simply drifted — and the record is what says which of
        // the two reasons was actually true.
        mac.audio.setReasons(MuteReasons(userMuted: true, zeroSilence: false), uid: "Speakers")
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")

        let after = mac.audio.reasons(uid: "Speakers")
        #expect(!after.userMuted, "a silence the user never asked for came back as their mute")
        #expect(after.zeroSilence, "the reason it was actually silent was lost")
    }

    /// The other side of the same ledger change, and the opposite answer.
    ///
    /// The user presses the mute key *during* the conserve. The reasons move
    /// exactly as an echo would, so comparing them cannot tell the two apart
    /// — and the restore put the saved ones back over the top, taking away a
    /// silence they had just asked for and unmuting the device to prove it.
    @Test("A user who mutes during a conserve keeps their mute")
    func explicitMuteDuringConserveWins() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.4, muted: false), asDefault: true)
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        #expect(mac.audio.state(uid: "Speakers")?.muted == true, "the conserve muted nothing")

        // Pressing the mute key on a device that is already silent changes no
        // hardware and declares an intent, which is precisely the case.
        mac.audio.userDeclares(MuteReasons(userMuted: true, zeroSilence: false), uid: "Speakers")
        let mutesBefore = mac.audio.mutes.count

        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        // The hardware and the meaning together, because either one alone
        // leaves the user somewhere they did not ask to be.
        #expect(mac.audio.state(uid: "Speakers")?.muted == true,
                "a mute the user had just asked for was taken away")
        #expect(mac.audio.reasons(uid: "Speakers").userMuted,
                "the user's own mute was overwritten by a saved meaning")
        #expect(mac.audio.mutes.count == mutesBefore,
                "the restore wrote a device the user had taken over")
        #expect(outcome.outstanding?.audio == nil,
                "the entry outlived the decision that superseded it")
    }

    /// And a decision in the other direction is just as much theirs: an
    /// explicit unmute during the conserve is not something to put back.
    @Test("A user who unmutes during a conserve is not re-muted or rewritten")
    func explicitUnmuteDuringConserveWins() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.4, muted: true), asDefault: true)
        mac.audio.setReasons(MuteReasons(userMuted: true, zeroSilence: false), uid: "Speakers")
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        mac.audio.userSets(muted: false, uid: "Speakers")
        mac.audio.userDeclares(MuteReasons(userMuted: false, zeroSilence: false), uid: "Speakers")

        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.state(uid: "Speakers")?.muted == false)
        #expect(!mac.audio.reasons(uid: "Speakers").userMuted,
                "a mute the user had just cleared was written back")
        #expect(outcome.outstanding?.audio == nil)
    }

    /// The relaunch, through the real disk.
    ///
    /// A revision counts declarations and a count means nothing outside the
    /// ledger that issued it. Persisting the number alone was worse than not
    /// persisting it at all: a fresh process counts from zero, so a saved
    /// number could never match, every recovered entry read as a user
    /// decision, and every one was discharged with the device still muted —
    /// the exact failure the comparison was built to prevent.
    @Test("A record recovered after a relaunch is not a user decision")
    func recoveryAcrossARelaunchIsNotADecision() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // A real conserve, through the real journal, with a real non-zero
        // revision behind it: the user adjusted this output before the lid
        // came down.
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.4, muted: false), asDefault: true)
        mac.audio.userDeclares(MuteReasons(userMuted: false, zeroSilence: false),
                               uid: "Speakers")
        let first = LidConserver(
            journal: FileLidConserveJournal(directory: home),
            panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        _ = await first.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        #expect(mac.audio.state(uid: "Speakers")?.muted == true, "the conserve muted nothing")

        let saved = try FileLidConserveJournal(directory: home).read()
        #expect((saved?.audio?.intentRevision ?? 0) > 0,
                "the fixture never recorded a real revision")
        #expect(saved?.audio?.intentIncarnation != nil,
                "the record did not say which ledger counted it")

        // The app dies without an End, and comes back. The output is still
        // muted; the new ledger has counted nothing.
        mac.audio.relaunch()
        let second = LidConserver(
            journal: FileLidConserveJournal(directory: home),
            panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        let outcome = await second.recover()

        #expect(mac.audio.state(uid: "Speakers")?.muted == false,
                "a device left muted by a dead process stayed muted")
        #expect(outcome.outstanding?.audio == nil,
                "the entry outlived the restore that discharged it")
        #expect(try FileLidConserveJournal(directory: home).read() == nil)
    }

    /// The pure version of the same rule, so every way of being incomparable
    /// is pinned rather than only the one the disk produces.
    @Test("Only a later declaration from the same ledger counts")
    func onlyALaterDeclarationFromTheSameLedgerCounts() {
        func entry(_ revision: Int?, _ incarnation: String?) -> LidConserveRecord.Audio {
            .init(uid: "u", muted: false, governed: [0],
                  intentRevision: revision, intentIncarnation: incarnation)
        }
        func now(_ revision: Int, _ incarnation: String) -> AudioOutputReading {
            .init(uid: "u", muted: true, governed: [0],
                  intentRevision: revision, intentIncarnation: incarnation)
        }

        #expect(LidConserver.intentChanged(entry(1, "run-1"), since: now(2, "run-1")),
                "a later declaration in the same ledger was missed")
        #expect(!LidConserver.intentChanged(entry(1, "run-1"), since: now(1, "run-1")),
                "nothing happening read as something happening")
        #expect(!LidConserver.intentChanged(entry(1, "run-1"), since: now(9, "run-2")),
                "a number from another ledger was compared anyway")
        #expect(!LidConserver.intentChanged(entry(1, "run-1"), since: now(0, "run-1")),
                "an output that was forgotten read as one somebody had acted on")
        #expect(!LidConserver.intentChanged(entry(nil, "run-1"), since: now(2, "run-1")))
        #expect(!LidConserver.intentChanged(entry(1, nil), since: now(2, "run-1")))
        #expect(!LidConserver.intentChanged(entry(1, "run-1"), since: nil))
    }

    /// R10-4: an attempt is not an achievement.
    ///
    /// The user asks to unmute and the hardware refuses. The device is still
    /// exactly as Ledge silenced it — but the attempt moved the ledger, End
    /// read that as a takeover, and the entry went with the output still
    /// muted and nothing left that knew how to free it.
    @Test("A user's request the hardware refused does not release the entry")
    func refusedUserRequestKeepsTheEntry() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.4, muted: false), asDefault: true)
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        // Asked for, refused: the description is recorded, nothing was
        // established, and the device is still Ledge's silence.
        mac.audio.userAttempts(MuteReasons(userMuted: false, zeroSilence: false),
                               uid: "Speakers")
        #expect(mac.audio.state(uid: "Speakers")?.muted == true,
                "the fixture let the refused request through")

        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.state(uid: "Speakers")?.muted == false,
                "the output stayed silenced after a request that failed")
        #expect(outcome.outstanding?.audio == nil)
    }

    /// A record from another process cannot answer the question, and an
    /// unanswerable question is not evidence that anybody acted — so the
    /// restore goes ahead rather than abandoning the device.
    @Test("A record that cannot say whether anybody acted still restores")
    func unknownIntentRevisionStillRestores() async {
        let journal = MemoryLidJournal(LidConserveRecord(
            boot: "AN-EARLIER-BOOT", sessionID: "S0",
            writtenAt: Date(timeIntervalSince1970: 1),
            audio: .init(uid: "Speakers", volume: 0.4, muted: false, governed: [0],
                         intentRevision: nil)
        ))
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.4, muted: true), asDefault: true)
        let conserver = LidConserver(
            journal: journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        let outcome = await conserver.recover()

        #expect(mac.audio.state(uid: "Speakers")?.muted == false,
                "a device left muted by a dead process stayed muted")
        #expect(outcome.outstanding?.audio == nil)
    }

    @Test("A device the user really had muted comes back muted by the user")
    func userMuteSurvives() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.4, muted: true), asDefault: true)
        mac.audio.setReasons(MuteReasons(userMuted: true, zeroSilence: false), uid: "Speakers")
        let conserver = await settled(mac)

        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        mac.audio.setReasons(MuteReasons(userMuted: false, zeroSilence: true), uid: "Speakers")
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.reasons(uid: "Speakers").userMuted,
                "the user's own mute was forgotten by the restore")
    }

    @Test("A level that goes back is followed by the unmute, as before")
    func successfulVolumeRestoreUnmutes() async {
        let mac = Mac()
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.state(uid: "BuiltInSpeakerDevice")?.muted == false)
        #expect(mac.audio.state(uid: "BuiltInSpeakerDevice")?.volume == 0.45)
        #expect(outcome.outstanding == nil)
    }

    /// A device with no level to report is a mute that can still go back: the
    /// refusal above is about a level that *failed*, not one that was never
    /// there.
    @Test("A device that reports no level is still unmuted")
    func noVolumeStillUnmutes() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Digital", name: "Digital Out",
                                          volume: nil, muted: false), asDefault: true)
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.state(uid: "Digital")?.muted == false)
        #expect(outcome.outstanding == nil)
    }

    // MARK: - The plan travels with the record

    /// The whole lifecycle version of R7-1's second shape. Conserve plans the
    /// master and mutes through it. While the lid is down the planner changes
    /// its mind — a genuine topology change, or a capability query that
    /// failed, which CoreAudio cannot tell apart — and now nominates the
    /// channels, which Ledge never wrote and which read free.
    ///
    /// Asking the planner again at the lid coming up reads those channels,
    /// sees nothing muted, calls it the user's doing and deletes the record
    /// with the device still silent. Carrying the journalled plan asks the
    /// master instead.
    @Test("The plan the record carries is the one the restore uses")
    func theJournalledPlanIsCarried() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.4, muted: false), asDefault: true)
        let conserver = await settled(mac)

        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        #expect(mac.audio.state(uid: "Speakers")?.muted == true, "the conserve muted nothing")

        // The planner changes its mind, and the controls it now nominates are
        // ones nothing ever wrote — so they read free.
        mac.audio.planNow([1, 2], uid: "Speakers")
        mac.audio.detach([1, 2], uid: "Speakers")

        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.observedPlans.last?.governed == [0],
                "the restore went back to the planner instead of the record")
        #expect(mac.audio.state(uid: "Speakers")?.muted == false,
                "the record was dropped with the device still muted")
        #expect(outcome.outstanding == nil)
    }

    /// And the same carrying across a crash: the plan is in the file, so the
    /// process that finds it has everything it needs without asking the
    /// hardware what it thinks today.
    @Test("A recovered record restores through the plan it was written with")
    func recoveryCarriesThePlan() async {
        let journal = MemoryLidJournal(LidConserveRecord(
            boot: "AN-EARLIER-BOOT", sessionID: "S0",
            writtenAt: Date(timeIntervalSince1970: 1),
            audio: .init(uid: "Speakers", volume: 0.3, muted: false, governed: [0])
        ))
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.0, muted: true), asDefault: true)
        // The hardware this process finds nominates something else entirely.
        mac.audio.planNow([1, 2], uid: "Speakers")
        mac.audio.detach([1, 2], uid: "Speakers")

        let conserver = LidConserver(
            journal: journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        let outcome = await conserver.recover()

        #expect(mac.audio.observedPlans.last?.governed == [0],
                "recovery asked the hardware instead of reading the record")
        #expect(mac.audio.state(uid: "Speakers")?.muted == false,
                "a device left muted by a dead process stayed muted")
        #expect(outcome.outstanding == nil)
    }

    /// A conserve that cannot say which controls it would be writing does not
    /// write any. "We could read the device" is not a record of what to undo.
    @Test("A device whose controls cannot be planned is not silenced")
    func unplannableDeviceIsNotSilenced() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Mystery", name: "Mystery",
                                          volume: 0.4, muted: false, governed: []),
                       asDefault: true)
        let conserver = await settled(mac)

        let outcome = await conserver.update(reading: Self.closed,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.state(uid: "Mystery")?.muted == false,
                "a device with no recordable plan was muted anyway")
        #expect(outcome.outstanding?.audio == nil,
                "an entry was journalled for a device with no plan")
    }

    // MARK: - A record with no plan changes nothing at all

    /// The guard that refuses a planless mute sat *behind* the level write.
    ///
    /// So a record that could not say which controls it owned — and was
    /// therefore kept, correctly, rather than discarded — still pushed its
    /// saved level onto a live, unmuted output on every single pass. An
    /// audible change made on the strength of a record already known to be
    /// unusable. The refusal has to come before any hardware is touched.
    @Test("A recovered record with no plan writes neither control", arguments: [[UInt32]?.none, []])
    func planlessRecoveryWritesNothing(plan: [UInt32]?) async {
        let journal = MemoryLidJournal(LidConserveRecord(
            boot: "AN-EARLIER-BOOT", sessionID: "S0",
            writtenAt: Date(timeIntervalSince1970: 1),
            audio: .init(uid: "Speakers", volume: 0.9, muted: false, governed: plan)
        ))
        let mac = Mac()
        // Live, audible, and nowhere near the saved level.
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.1, muted: false), asDefault: true)

        let conserver = LidConserver(
            journal: journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        let outcome = await conserver.recover()

        #expect(mac.audio.writeOrder.isEmpty,
                "a record with no plan wrote \(mac.audio.writeOrder)")
        #expect(mac.audio.state(uid: "Speakers")?.volume == 0.1,
                "the user's level was overwritten from a record nothing could act on")
        #expect(mac.audio.state(uid: "Speakers")?.muted == false)
        #expect(outcome.outstanding?.audio != nil, "the obligation was discarded instead of kept")
    }

    /// And it keeps writing nothing. The entry is retained, so every
    /// subsequent pass meets it again — which is how one audible change
    /// became one on each lid, for ever.
    @Test("A kept planless entry is still not acted on by later passes",
          arguments: [[UInt32]?.none, []])
    func planlessEntryStaysUnacted(plan: [UInt32]?) async {
        let journal = MemoryLidJournal(LidConserveRecord(
            boot: "AN-EARLIER-BOOT", sessionID: "S0",
            writtenAt: Date(timeIntervalSince1970: 1),
            audio: .init(uid: "Speakers", volume: 0.9, muted: false, governed: plan)
        ))
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.1, muted: false), asDefault: true)
        let conserver = LidConserver(
            journal: journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        _ = await conserver.recover()

        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.writeOrder.isEmpty,
                "a planless entry wrote \(mac.audio.writeOrder) on a later pass")
        #expect(mac.audio.state(uid: "Speakers")?.volume == 0.1)
        #expect(outcome.outstanding?.audio != nil)
    }

    // MARK: - A device is not one number

    /// A channel-only output with its channels at different levels.
    ///
    /// This used to be about *how* the levels went back — the aggregate a bar
    /// on screen shows is their average, and writing 0.5 to both channels
    /// verifies perfectly while 0.2 left and 0.8 right is gone for good.
    /// Fixing that made the behaviour correct and left the real question
    /// standing: the conserve had never touched these levels. So now it is
    /// about the levels not moving at all.
    @Test("An asymmetric output comes through the whole cycle untouched")
    func asymmetricChannelsAreNeverTouched() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Interface", name: "Interface",
                                          volume: 0.5, muted: false), asDefault: true)
        mac.audio.setLevels([1: 0.2, 2: 0.8], uid: "Interface")
        mac.audio.planNow([1, 2], uid: "Interface")
        let conserver = await settled(mac)

        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")
        #expect(mac.audio.state(uid: "Interface")?.muted == true, "the conserve muted nothing")
        #expect(mac.audio.levels(uid: "Interface") == [1: 0.2, 2: 0.8],
                "the conserve moved a level it had no business touching")

        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")

        let after = mac.audio.levels(uid: "Interface")
        #expect(after == [1: 0.2, 2: 0.8],
                "the restore wrote a level it had never changed: \(after)")
        #expect(mac.audio.state(uid: "Interface")?.muted == false)
        #expect(outcome.outstanding == nil)
    }

    /// And the record does not even carry a level to be tempted by.
    @Test("The journal keeps no level to put back")
    func journalKeepsNoLevelToRestore() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Interface", name: "Interface",
                                          volume: 0.5, muted: false), asDefault: true)
        let conserver = await settled(mac)
        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        // The aggregate is kept for the log, and nothing acts on it.
        #expect(mac.journal.onDisk?.audio?.volume == 0.5)
        #expect(mac.journal.onDisk?.audio?.muted == false)
    }

    /// A control that reports itself writable and then refuses is where the
    /// unconfined write falls back onto the channels — a change with no undo
    /// entry naming it. The conserve would rather leave the device making
    /// sound than silence it in a way it cannot undo.
    @Test("A refused plan leaves the device alone rather than writing elsewhere")
    func refusedPlanDoesNotWanderOff() async {
        let mac = Mac()
        mac.audio.plug(AudioOutputReading(uid: "Speakers", name: "Speakers",
                                          volume: 0.4, muted: false), asDefault: true)
        mac.audio.refuse([0], uid: "Speakers")
        let conserver = await settled(mac)

        await conserver.update(reading: Self.closed, sessionRunning: true, sessionID: "S1")

        #expect(mac.audio.state(uid: "Speakers")?.muted == false,
                "the mute landed somewhere the record does not name")
        #expect(mac.audio.mutePlans.allSatisfy { $0.governed == [0] },
                "a write went out against controls the record never named")

        // The entry stays — it is the account of a device Ledge believes it
        // has silenced — and the lid coming up clears it once the device is
        // confirmed free.
        let outcome = await conserver.update(reading: Self.open,
                                             sessionRunning: true, sessionID: "S1")
        #expect(outcome.outstanding?.audio == nil)
    }
}

/// The driver, after the same review.
@Suite("Events that arrived for a session that was over")
struct LidConserveDriverFencingTests {

    private typealias Mac = LidConserverTests.Mac
    private static let open = LidReading(state: .open, builtInIsOnlyDisplay: true)
    private static let closed = LidReading(state: .closed, builtInIsOnlyDisplay: true)

    /// `stop()` unregisters a sensor. It does not reach into a callback
    /// already on its way, and such a callback carrying a hard-coded
    /// `sessionRunning: true` darkened the panel again after the session had
    /// ended — with nobody left to put it back.
    @Test("A sensor callback delivered after the session ends changes nothing")
    func lateCallbackIsIgnored() async {
        let mac = Mac()
        let conserver = mac.conserver()
        await conserver.sessionBegan()
        let sensor = CapturingLidSensor(Self.open)
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)

        driver.begin(sessionID: "one")
        await driver.settle()
        driver.end()
        await driver.settle()

        // The callback the sensor handed out before `stop`, arriving now.
        sensor.deliverToTheCallbackItGaveOut(Self.closed)
        await driver.settle()

        #expect(await conserver.isConserving == false,
                "a session that was over went on conserving")
        #expect(mac.panel.writeLog.isEmpty, "a panel was darkened for a dead session")
        #expect(mac.journal.onDisk == nil)
    }

    /// The case the fence is actually for. A dead session's callback arriving
    /// while a *new* session is running would be acted on with the new
    /// session's `running: true` and an old session's reading — conserving,
    /// or un-conserving, on evidence that belongs to nobody.
    @Test("A dead session's callback does not drive the session that replaced it")
    func staleCallbackDoesNotDriveTheNewSession() async {
        let mac = Mac()
        let conserver = mac.conserver()
        await conserver.sessionBegan()
        let sensor = CapturingLidSensor(Self.open)
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)

        driver.begin(sessionID: "one")
        await driver.settle()
        driver.end()
        await driver.settle()

        // A second session, with the lid up and nothing conserved.
        driver.begin(sessionID: "two")
        await driver.settle()
        #expect(sensor.registrations == 2, "the second session did not register its own watch")
        #expect(await conserver.isConserving == false)

        // And now the first session's callback finally fires, carrying a
        // reading from a Mac that was shut a long time ago.
        sensor.deliverToTheCallbackItGaveOut(Self.closed, registration: 0)
        await driver.settle()

        #expect(await conserver.isConserving == false,
                "a dead session's event conserved on behalf of a live one")
        #expect(mac.panel.writeLog.isEmpty, "a panel was darkened by an event nobody sent")
        #expect(mac.journal.onDisk == nil)

        driver.end()
        await driver.settle()
    }

    /// Deciding to stop and stopping were two steps with the lock dropped in
    /// between, and a session beginning in that gap reused the watch that was
    /// already registered — so the old completion unregistered the new
    /// session's only source of events. It then ran with neither the hinge nor
    /// the clock feeding it.
    @Test("A completion from a finished session does not stop the next one's watch")
    func oldCompletionDoesNotStopTheNewWatch() async {
        let mac = Mac()
        let conserver = mac.conserver()
        await conserver.sessionBegan()
        let sensor = FakeLidSensor(Self.open)
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)

        driver.begin(sessionID: "one")
        await driver.settle()

        // The end's restore is slow, as a trip into a private framework is.
        mac.panel.setDelay(microseconds: 30_000)
        driver.end()
        // And a new session starts while that completion is still coming.
        driver.begin(sessionID: "two")
        await driver.settle()

        #expect(driver.isWatching,
                "a finished session's completion unregistered the next session's watch")
        #expect(driver.currentSessionID == "two")

        // And the new session still works.
        mac.panel.setDelay(microseconds: 0)
        sensor.move(to: Self.closed)
        await driver.settle()
        #expect(await conserver.isConserving, "the new session had no events reaching it")

        driver.end()
        await driver.settle()
    }

    /// The in-memory decision was made atomic; the physical teardown was not.
    /// A sets watching=false under the lock, drops it, and pauses before
    /// `sensor.stop()`. B sees watching=false, registers its own watch and
    /// starts its timer. A resumes and unregisters B's sensor — so B runs with
    /// the hinge no longer reaching it.
    @Test("An old stop does not unregister the watch that replaced it")
    func oldStopDoesNotUnregisterTheNewSensor() async {
        let mac = Mac()
        let conserver = mac.conserver()
        await conserver.sessionBegan()
        let sensor = CountingLidSensor(Self.open)
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)

        driver.begin(sessionID: "A")
        await driver.settle()
        driver.end()
        driver.begin(sessionID: "B")
        await driver.settle()

        #expect(driver.isWatching)
        #expect(sensor.isRegistered,
                "an old stop unregistered the sensor the new session had just registered")

        // And the hinge still reaches B.
        sensor.report(Self.closed)
        await driver.settle()
        #expect(await conserver.isConserving, "the new session never heard the lid close")

        driver.end()
        await driver.settle()
    }

    /// A restore that could not land while the lid was shut can only be
    /// repaired by another pass, and cancelling the sensor at `end` is exactly
    /// what takes the events that would cause one away.
    @Test("A failed restore keeps watching, and the lid opening repairs it")
    func failedRestoreKeepsWatching() async {
        let mac = Mac()
        let conserver = mac.conserver()
        await conserver.sessionBegan()
        let sensor = FakeLidSensor(Self.open)
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)

        driver.begin(sessionID: "retry")
        await driver.settle()
        sensor.move(to: Self.closed)
        await driver.settle()
        #expect(mac.panel.lastWrite == 0)

        // The restore is refused, and the session ends anyway.
        mac.panel.setAccepts(false)
        driver.end()
        await driver.settle()
        #expect(await conserver.outstanding?.panel != nil)
        #expect(driver.isWatching, "nothing is left watching for the lid that would repair this")

        // The lid comes up and the panel starts answering again.
        mac.panel.setAccepts(true)
        sensor.move(to: Self.open)
        await driver.settle()

        #expect(mac.panel.level() == 0.62, "the panel was never put back")
        #expect(await conserver.outstanding == nil)
        #expect(!driver.isWatching, "the watch outlived the work it was for")
    }

    @Test("A session that ends cleanly stops watching")
    func cleanEndStopsWatching() async {
        let mac = Mac()
        let conserver = mac.conserver()
        await conserver.sessionBegan()
        let sensor = FakeLidSensor(Self.open)
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)

        driver.begin(sessionID: "s")
        await driver.settle()
        sensor.move(to: Self.closed)
        await driver.settle()
        driver.end()
        await driver.settle()

        #expect(!driver.isWatching)
        #expect(sensor.stopCount >= 1)
    }

    /// The guard was a `return` inside `lock.withLock`, which returns from the
    /// closure and carries straight on into the body below it — so a second
    /// `begin` registered a second sensor callback and a second timer.
    /// One session at a time. A second `begin` while one is running is not a
    /// fresh start, and quietly re-pointing the driver at another session id
    /// would have its events journalled under a name nothing was conserved
    /// for — so a recovery would be putting back a session that never ran.
    @Test("Beginning twice keeps the session that is running")
    func beginIsIdempotent() async {
        let mac = Mac()
        let conserver = mac.conserver()
        let sensor = CountingLidSensor(Self.open)
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)

        await conserver.sessionBegan()
        await conserver.update(reading: Self.open, sessionRunning: true, sessionID: "one")
        driver.begin(sessionID: "one")
        driver.begin(sessionID: "two")
        driver.begin(sessionID: "three")
        await driver.settle()

        #expect(driver.currentSessionID == "one",
                "a later begin took the running session over")
        #expect(sensor.observeCount == 1, "a second begin registered a second callback")

        // And the record carries the session that was actually conserved for.
        sensor.report(Self.closed)
        await driver.settle()
        #expect(await conserver.outstanding?.sessionID == "one")

        driver.end()
        await driver.settle()
        #expect(!driver.isWatching)
        #expect(driver.currentSessionID == nil)
    }

    /// Recovery at launch finds a record left by a process that is gone. If it
    /// cannot put it back, the lid opening is the thing that will — and
    /// nothing would hear it otherwise.
    @Test("A recovery that cannot finish starts watching for the lid")
    func recoveryThatFailsWatches() async {
        let mac = Mac()
        let journal = MemoryLidJournal(LidConserveRecord(
            boot: "EARLIER", sessionID: "S0", writtenAt: Date(timeIntervalSince1970: 1),
            panel: .init(level: 0.5)
        ))
        mac.panel.setAccepts(false)
        let conserver = LidConserver(
            journal: journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        let sensor = FakeLidSensor(LidReading(state: .closed, builtInIsOnlyDisplay: true))
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)

        driver.recover()
        await driver.settle()
        #expect(driver.isWatching, "a record nobody could put back was left with nothing watching")

        mac.panel.setAccepts(true)
        sensor.move(to: LidReading(state: .open, builtInIsOnlyDisplay: true))
        await driver.settle()

        #expect(mac.panel.level() == 0.5)
        #expect(!driver.isWatching)
    }

    /// "Retried on every pass" has to mean passes that happen. An unresolved
    /// journal retiring the watch left nothing registered to notice the disk
    /// coming back — no sensor, no cadence, and no second read.
    @Test("A recovery that could not read the journal keeps watching")
    func unresolvedRecoveryKeepsWatching() async {
        let mac = Mac()
        let journal = MemoryLidJournal(LidConserveRecord(
            writtenAt: Date(timeIntervalSince1970: 1), panel: .init(level: 0.6)
        ))
        journal.failReads(true, as: .unavailable)
        mac.panel.setReadLevel(0)
        let conserver = LidConserver(
            journal: journal, panel: mac.panel, keyboard: mac.keyboard,
            audio: mac.audio, lowPower: mac.lowPower,
            boot: { "BOOT-TEST" }, now: { mac.clock.now }
        )
        let sensor = FakeLidSensor(LidReading(state: .closed, builtInIsOnlyDisplay: true))
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)

        driver.recover()
        await driver.settle()
        #expect(driver.isWatching,
                "a journal nobody could read was left with nothing watching for the disk")

        // The disk comes back, and an ordinary lid event is enough.
        journal.failReads(false)
        sensor.move(to: LidReading(state: .open, builtInIsOnlyDisplay: true))
        await driver.settle()

        #expect(mac.panel.level() == 0.6, "the prior was never recovered once it could be read")
        #expect(!driver.isWatching, "the watch outlived the work it was for")
    }

    @Test("A recovery with nothing to do watches nothing")
    func cleanRecoveryDoesNotWatch() async {
        let mac = Mac()
        let conserver = mac.conserver()
        let sensor = FakeLidSensor(Self.open)
        let driver = LidConserveDriver(sensor: sensor, conserver: conserver)
        driver.recover()
        await driver.settle()
        #expect(!driver.isWatching)
    }
}

/// A sensor that keeps the callback it handed out, the way a real notification
/// source does: `stop` unregisters, and a call already in flight still lands.
final class CapturingLidSensor: LidSensing, @unchecked Sendable {

    private let lock = NSLock()
    private var reading: LidReading
    private var registered: (@Sendable (LidReading) -> Void)?
    private var handedOut: [(@Sendable (LidReading) -> Void)] = []

    init(_ reading: LidReading) { self.reading = reading }

    var registrations: Int { lock.withLock { handedOut.count } }

    func read() -> LidReading { lock.withLock { reading } }

    func observe(_ onChange: @escaping @Sendable (LidReading) -> Void) {
        lock.withLock {
            registered = onChange
            handedOut.append(onChange)
        }
        onChange(read())
    }

    func stop() { lock.withLock { registered = nil } }

    /// What a notification already dispatched looks like when it arrives after
    /// the source has been torn down.
    ///
    /// - Parameter registration: which of the callbacks handed out over this
    ///   sensor's life is delivering. Zero is the first — the one a session
    ///   that has since ended registered, and the one a real notification
    ///   source would still be holding.
    func deliverToTheCallbackItGaveOut(_ reading: LidReading, registration: Int = 0) {
        let late: (@Sendable (LidReading) -> Void)? = lock.withLock {
            guard registration < handedOut.count else { return nil }
            return handedOut[registration]
        }
        late?(reading)
    }
}

/// Counts registrations, which is the only way to see a second watch.
final class CountingLidSensor: LidSensing, @unchecked Sendable {

    private let lock = NSLock()
    private var reading: LidReading
    private var registrations = 0
    private var handler: (@Sendable (LidReading) -> Void)?

    init(_ reading: LidReading) { self.reading = reading }

    var observeCount: Int { lock.withLock { registrations } }

    func read() -> LidReading { lock.withLock { reading } }

    func observe(_ onChange: @escaping @Sendable (LidReading) -> Void) {
        lock.withLock {
            registrations += 1
            handler = onChange
        }
        onChange(read())
    }

    func stop() { lock.withLock { handler = nil } }

    /// Whether anything is listening. The physical half of the watch, which
    /// the state lock cannot speak for.
    var isRegistered: Bool { lock.withLock { handler != nil } }

    /// Moves the lid, through whichever callback is currently registered.
    func report(_ reading: LidReading) {
        let announce: (@Sendable (LidReading) -> Void)? = lock.withLock {
            self.reading = reading
            return handler
        }
        announce?(reading)
    }
}

/// What a write to a real device means, as opposed to what a fake says.
///
/// Both halves of this were wrong in the shipping adapter and right in the
/// fake, which is the worst place for a disagreement to live: the tests passed
/// and the Mac was the thing that would have gone wrong.
@Suite("What CoreAudio's answers mean for a restore")
struct LidRestoreOutcomeTests {

    /// Being in the state asked for is the whole question. Whether anything
    /// had to be written to get there is not, and treating "nothing to do" as
    /// failure kept an entry outstanding for ever.
    @Test("A mute that needed no write is settled, not failed")
    func alreadySettledMute() {
        #expect(LidRestoreOutcome(mute: .alreadySettled) == .alreadySettled)
        #expect(LidRestoreOutcome(mute: .alreadySettled).isSettled)
        #expect(!MuteOutcome.alreadySettled.accepted,
                "the test is not describing the real contract")
    }

    @Test("A half-muted device is not a muted device")
    func partialMute() {
        #expect(LidRestoreOutcome(mute: .partial) == .incomplete)
        #expect(MuteOutcome.partial.accepted, "the test is not describing the real contract")
    }

    @Test("A mute that landed everywhere is settled")
    func completeMute() {
        #expect(LidRestoreOutcome(mute: .master) == .complete)
        #expect(LidRestoreOutcome(mute: .everyChannel) == .complete)
        #expect(LidRestoreOutcome(mute: .refused) == .incomplete)
        #expect(LidRestoreOutcome(mute: .unsupported) == .incomplete)
    }
}

/// The level restore has to be a level restore.
///
/// `apply(level:to:reasons:)` is the slider, and the slider keeps the device's
/// mute consistent with the level it sets. Putting a level back underneath a
/// mute that has to stay went through it and unmuted on the way past, making
/// sound at the old level before the mute was put back.
@Suite("Restoring a level without touching the silence")
struct ScalarOnlyRestoreTests {

    /// Just enough of a device to ask the one question. The full contract is
    /// pinned in `VolumeWriteTests`; this is about what the *lid* needs from
    /// it, which is a level write that is not also a mute write.
    private final class Device: VolumeHardware, @unchecked Sendable {
        var channels: [UInt32] = [1, 2]
        var scalarElements: Set<UInt32> = [1, 2]
        var refusedScalarWrites: Set<UInt32> = []
        var level: Double = 0.9
        var muted = true
        private(set) var muteWrites = 0

        func canWriteScalar(_ device: AudioObjectID, element: UInt32) -> Bool {
            scalarElements.contains(element)
        }
        /// What each element was actually written, which one `level` could
        /// not express — and could not express the loss it was hiding: a
        /// device is not one number, and a restore that puts an average on
        /// every channel verifies perfectly while the balance is gone.
        private(set) var writtenLevels: [UInt32: Double] = [:]
        func writeScalar(_ value: Double, _ device: AudioObjectID, element: UInt32) -> Bool {
            guard scalarElements.contains(element), !refusedScalarWrites.contains(element)
            else { return false }
            if !ignoresWrites {
                level = value
                writtenLevels[element] = value
            }
            return true
        }
        /// Whether the master can be *written*, which real devices decouple
        /// from whether it exists: a read-only master sits beside writable
        /// channel controls, and a verifier that picked its topology from
        /// presence alone checked the one element the write never touched.
        var masterIsWritable = true
        var writableChannels = true

        func canWriteMute(_ device: AudioObjectID, element: UInt32) -> Bool {
            if element == 0 { return hasMuteMaster && masterIsWritable }
            return writableChannels && channels.contains(element)
        }
        /// Says yes and does nothing, which is what an acknowledgement is.
        var ignoresMuteWrites = false
        var ignoresWrites = false
        /// Elements that report a control and refuse the write.
        var refusedMuteElements: Set<UInt32> = []
        /// Elements that accept the write and do not move — the shape an
        /// acknowledgement cannot tell you about.
        var ignoredMuteElements: Set<UInt32> = []
        /// Which elements a mute write actually reached.
        ///
        /// Counting writes is not enough: a write that lands on a control the
        /// record does not name is the whole of R7-1, and it can be a write
        /// of the value the control already held — invisible in the state,
        /// and still a change Ledge had no entry for.
        private(set) var muteWriteElements: [UInt32] = []
        func writeMute(_ value: Bool, _ device: AudioObjectID, element: UInt32) -> Bool {
            muteWrites += 1
            muteWriteElements.append(element)
            guard !refusedMuteElements.contains(element) else { return false }
            guard !ignoresMuteWrites, !ignoredMuteElements.contains(element) else { return true }
            muted = value
            muteByElement[element] = value
            return true
        }
        func readScalar(_ device: AudioObjectID) -> Double? { level }

        /// What each element reports, so a channel can stay where it was
        /// while the others move — which is the state an acknowledgement
        /// cannot tell you about.
        var levelByElement: [UInt32: Double] = [:]
        /// Elements that answer nothing at all. A device can acknowledge a
        /// write and then go quiet about that very channel.
        var silentElements: Set<UInt32> = []
        func readScalar(_ device: AudioObjectID, element: UInt32) -> Double? {
            if silentElements.contains(element) { return nil }
            // A stuck or independent element answers for itself first: that
            // is the shape an acknowledgement cannot tell you about.
            if let stuck = levelByElement[element] { return stuck }
            // A device that will not report answers nothing, whatever was
            // written to it — an acknowledgement is not a reading.
            guard reportsLevel else { return nil }
            return writtenLevels[element] ?? level
        }
        var reportsLevel = true

        /// Mute per element, so half-muted and unknown are expressible.
        var muteByElement: [UInt32: Bool] = [:]
        var silentMuteElements: Set<UInt32> = []
        var hasMuteMaster = true
        /// Whether the element has a control at all — which is a different
        /// question from whether it will answer right now.
        func hasMute(_ device: AudioObjectID, element: UInt32) -> Bool {
            element == 0 ? hasMuteMaster : channels.contains(element)
        }

        func readMute(_ device: AudioObjectID, element: UInt32) -> Bool? {
            if silentMuteElements.contains(element) { return nil }
            if let value = muteByElement[element] { return value }
            if element == 0 { return hasMuteMaster ? muted : nil }
            return hasMuteMaster ? nil : muted
        }
        func outputChannels(_ device: AudioObjectID) -> [UInt32]? { channels }
    }

    /// The plan a conserve would have journalled for this device, taken from
    /// the production planner rather than written out by hand — so a test
    /// cannot quietly hand the restore a set of controls the conserve would
    /// never have chosen.
    private static func plan(_ hardware: Device) -> [UInt32] {
        CoreAudioLidOutput.plan(1, hardware: hardware).governed
    }

    // MARK: - The mute, and why it was silent

    /// `setMuted` kept only the write's topology and threw away what the
    /// device actually read as. An acknowledged but ineffective unmute has
    /// `.master` and `isMuted == true`, and the conserver discarded the only
    /// undo record while the output stayed silent.
    @Test("An acknowledged unmute that did not take is not settled")
    func acknowledgedButStillMuted() {
        let hardware = Device()
        hardware.ignoresMuteWrites = true
        let outcome = CoreAudioLidOutput.restoreMute(false, on: 1,
                                                     within: Self.plan(hardware),
                                                     using: VolumeWriter(hardware: hardware))
        #expect(outcome == .incomplete, "a device that is still muted reported itself unmuted")
    }

    @Test("A mute that took is settled")
    func muteThatTook() {
        let hardware = Device()
        #expect(CoreAudioLidOutput.restoreMute(false, on: 1,
                                               within: Self.plan(hardware),
                                               using: VolumeWriter(hardware: hardware)).isSettled)
        #expect(!hardware.muted)
    }

    /// The aggregate answers "is it muted everywhere", and false is also what
    /// a half-muted device says. It could show that a mute took and never
    /// that an unmute did.
    @Test("A half-unmuted device is not an unmuted device")
    func halfUnmuteIsNotSettled() {
        let hardware = Device()
        hardware.hasMuteMaster = false
        hardware.channels = [1, 2, 3, 4]
        hardware.muted = true
        hardware.muteByElement = [1: true, 2: true, 3: true, 4: true]
        // Three channels come back; the fourth refuses outright.
        hardware.refusedMuteElements = [4]
        let outcome = CoreAudioLidOutput.restoreMute(false, on: 1,
                                                     within: Self.plan(hardware),
                                                     using: VolumeWriter(hardware: hardware))
        #expect(outcome == .incomplete, "a device still muted on one channel reported itself free")
    }

    /// A read-only master beside writable channels is a shape real devices
    /// have, and `settle` already handles it: it skips the master and writes
    /// the channels. Verifying the master then certifies channels that never
    /// moved.
    @Test("A read-only master does not certify the channels that were written")
    func readOnlyMasterDoesNotCertifyChannels() {
        let hardware = Device()
        hardware.hasMuteMaster = true
        hardware.masterIsWritable = false
        hardware.channels = [1, 2, 3, 4]
        hardware.muteByElement = [0: false, 1: true, 2: true, 3: true, 4: true]
        // Three channels come back; the fourth acknowledges and does not move.
        hardware.ignoresMuteWrites = false

        // Every channel accepts the unmute; channel four does not move. The
        // write therefore reports `everyChannel`, and only reading the
        // channels can tell that one of them is still silent.
        hardware.ignoredMuteElements = [4]
        let outcome = CoreAudioLidOutput.restoreMute(
            false, on: 1, within: Self.plan(hardware), using: VolumeWriter(hardware: hardware)
        )

        #expect(outcome == .incomplete,
                "an unchanged read-only master certified channels that are still muted")
        #expect(hardware.muteByElement[4] == true, "the fixture did not leave a channel muted")
        #expect(hardware.muteByElement[0] == false, "the master was supposed to stay false")
    }

    /// The lifecycle version, which needs no ineffective setter at all: an
    /// independent read-only master reads false throughout while Ledge mutes
    /// the channels. Reading only that master at the end looked exactly like
    /// the user having freed the device, and the undo record was dropped with
    /// every channel still silent.
    @Test("A read-only master does not look like the user unmuting the device")
    func readOnlyMasterIsNotUserIntervention() {
        let hardware = Device()
        hardware.hasMuteMaster = true
        hardware.masterIsWritable = false
        hardware.channels = [1, 2]
        hardware.muteByElement = [0: false, 1: true, 2: true]

        let governed = Self.plan(hardware)
        #expect(governed == [1, 2], "the conserve planned a control it cannot write")
        let now = CoreAudioLidOutput.mutedState(1, within: governed, hardware: hardware)
        #expect(now == true, "a device Ledge had silenced reported itself free")
        #expect(LidRestore.audio(LidConserveRecord.Audio(uid: "u", volume: 0.4, muted: false,
                                                        governed: governed),
                                 isPresent: true, isMutedNow: now)
                != .leaveAlone,
                "the undo record was dropped while every channel was still muted")
    }

    /// Topology discovered *after* the write, from whether a master readback
    /// happened to work, verified an accepted master against channels it had
    /// never written. The channels read false, so a master still muted
    /// reported itself free.
    @Test("An unreadable governing master is not verified against its channels")
    func unreadableMasterIsNotVerifiedByChannels() {
        let hardware = Device()
        hardware.hasMuteMaster = true
        hardware.channels = [1, 2]
        hardware.muted = true
        hardware.ignoresMuteWrites = true     // acknowledges, stays muted
        hardware.silentMuteElements = [0]     // and will not say so
        hardware.muteByElement = [1: false, 2: false]

        let outcome = CoreAudioLidOutput.restoreMute(false, on: 1,
                                                     within: Self.plan(hardware),
                                                     using: VolumeWriter(hardware: hardware))
        #expect(outcome == .incomplete,
                "a master that was still muted was verified against channels it never wrote")
    }

    /// And the same ambiguity before any restore: a master that exists and
    /// will not answer is unknown, not absent. Falling through to the channels
    /// made it an affirmative "not muted", which `LidRestore.audio` reads as
    /// the user having freed the device.
    @Test("An unreadable master is unknown, not a reason to read the channels")
    func unreadableMasterReadsAsUnknown() {
        let hardware = Device()
        hardware.hasMuteMaster = true
        hardware.silentMuteElements = [0]
        hardware.muteByElement = [1: false, 2: false]
        #expect(CoreAudioLidOutput.plan(1, hardware: hardware).muted == nil,
                "an unreadable master borrowed an answer from the channels")
    }

    @Test("A device with no master at all still reads its channels")
    func absentMasterFallsBackToChannels() {
        let hardware = Device()
        hardware.hasMuteMaster = false
        hardware.channels = [1, 2]
        hardware.muteByElement = [1: true, 2: true]
        #expect(CoreAudioLidOutput.plan(1, hardware: hardware).muted == true)
    }

    @Test("A mute nothing will report on is not settled")
    func unreadableMuteIsNotSettled() {
        let hardware = Device()
        hardware.silentMuteElements = [0, 1, 2]
        let outcome = CoreAudioLidOutput.restoreMute(false, on: 1,
                                                     within: Self.plan(hardware),
                                                     using: VolumeWriter(hardware: hardware))
        #expect(outcome == .incomplete, "an acknowledgement nobody could check passed for settled")
    }

    /// `VolumeController.isMuted` collapses "no" and "could not tell" into
    /// false, which is right for a bar on screen and wrong for a record
    /// somebody's audio depends on: a failed query looked exactly like a user
    /// who had just unmuted the device.
    @Test("A device that will not say whether it is muted reports unknown")
    func unreadableMuteReadsAsUnknown() {
        let hardware = Device()
        hardware.silentMuteElements = [0, 1, 2]
        #expect(CoreAudioLidOutput.plan(1, hardware: hardware).muted == nil,
                "a device nobody could read reported a definite answer")
    }

    @Test("A half-muted device reports unknown, not unmuted")
    func halfMutedReadsAsUnknown() {
        let hardware = Device()
        hardware.hasMuteMaster = false
        hardware.channels = [1, 2]
        hardware.muteByElement = [1: true, 2: false]
        #expect(CoreAudioLidOutput.plan(1, hardware: hardware).muted == nil)
    }

    @Test("A device that answers plainly is reported plainly")
    func readableMuteReadsThrough() {
        let hardware = Device()
        hardware.muted = true
        #expect(CoreAudioLidOutput.plan(1, hardware: hardware).muted == true)
        hardware.muted = false
        #expect(CoreAudioLidOutput.plan(1, hardware: hardware).muted == false)
    }

    /// A reading nobody could take is not "the user unmuted it". Collapsing
    /// the two dropped the whole undo record before any restore ran.
    @Test("An unreadable mute is not taken for the user having unmuted it")
    func unknownMuteIsNotUserIntervention() {
        let entry = LidConserveRecord.Audio(uid: "u", volume: 0.4, muted: true)
        #expect(LidRestore.audio(entry, isPresent: true, isMutedNow: nil)
                != .leaveAlone,
                "a device nobody could read was treated as one the user had freed")
        #expect(LidRestore.audio(entry, isPresent: true, isMutedNow: false) == .leaveAlone)
    }

    @Test("A scalar-only restore leaves a muted device muted")
    func doesNotUnmute() {
        let hardware = Device()
        let outcome = VolumeWriter(hardware: hardware).applyScalarOnly(0.1, to: 1)

        #expect(outcome.isComplete)
        #expect(hardware.muted, "the level restore unmuted the device on its way past")
        #expect(hardware.muteWrites == 0, "a level restore wrote the mute control")
        #expect(hardware.level == 0.1)
    }

    /// And it reports the lopsided case honestly. Nothing in the lid path
    /// consumes this any more — the conserve does not write levels — but the
    /// slider does, and a device left at a level nobody asked for must say so.
    @Test("One channel refusing is partial, not success")
    func oneChannelRefusing() {
        let hardware = Device()
        hardware.refusedScalarWrites = [2]
        let outcome = VolumeWriter(hardware: hardware).applyScalarOnly(0.1, to: 1)

        #expect(outcome == .partial)
        #expect(!outcome.isComplete)
        #expect(hardware.muted)
    }

    // MARK: - The plan is carried, not asked for again

    /// A master that reports settable and then refuses its setter is a shape
    /// the unconfined write already handles: it falls back to the channels.
    /// That fallback is a change to controls the journal does not name — and
    /// the record it would need in order to be undone was written before the
    /// refusal, naming the master. At the lid coming up the master is read,
    /// has never moved, and the whole entry goes while every channel is still
    /// silent.
    ///
    /// So the fallback is refused. A mute that did not happen is silence
    /// nobody asked for; an unrecorded mute is silence nobody can undo.
    @Test("A refused master does not fall back onto controls the record does not name")
    func refusedMasterDoesNotWanderOffPlan() {
        let hardware = Device()
        hardware.hasMuteMaster = true
        hardware.masterIsWritable = true          // and says so, truthfully or not
        hardware.channels = [1, 2]
        hardware.writableChannels = true          // the channels would take it
        hardware.muteByElement = [0: false, 1: false, 2: false]
        hardware.refusedMuteElements = [0]        // the setter says no

        let governed = Self.plan(hardware)
        #expect(governed == [0], "the conserve planned something other than the master")

        let outcome = CoreAudioLidOutput.restoreMute(true, on: 1, within: governed,
                                                     using: VolumeWriter(hardware: hardware))

        #expect(outcome == .incomplete, "a refused master reported itself silenced")
        #expect(hardware.muteByElement[1] == false && hardware.muteByElement[2] == false,
                "the write fell back onto channels the journal never named")
        // The elements, not the resulting state: a fallback that writes a
        // control the value it already held leaves no trace in the state and
        // is still a change nothing recorded.
        #expect(hardware.muteWriteElements.allSatisfy { governed.contains($0) },
                "a write reached \(hardware.muteWriteElements), outside the plan \(governed)")

        // And the lid coming up agrees with what actually happened: nothing
        // was silenced, so there is nothing to put back.
        let now = CoreAudioLidOutput.mutedState(1, within: governed, hardware: hardware)
        #expect(now == false, "a device nothing had touched read as still silenced")
        #expect(LidRestore.audio(LidConserveRecord.Audio(uid: "u", muted: false,
                                                        governed: governed),
                                 isPresent: true, isMutedNow: now) == .leaveAlone)
    }

    /// The second shape, which needs no refusal at all. The master takes the
    /// mute and is journalled. Then the capability query stops saying the
    /// master is settable — a genuine topology change, or equally a *failed*
    /// query, which `AudioObjectIsPropertySettable` cannot distinguish from
    /// an affirmative no.
    ///
    /// Asking again hands the question to the channels, which Ledge never
    /// wrote and which read free, and the record is deleted with the device
    /// still muted. Carrying the plan asks the master, which is still muted,
    /// and keeps the obligation.
    @Test("A master that stops reporting settable does not hand the device to the channels")
    func changedCapabilityKeepsTheObligation() {
        let hardware = Device()
        hardware.hasMuteMaster = true
        hardware.channels = [1, 2]
        hardware.muteByElement = [0: false, 1: false, 2: false]

        // Conserve: the master is the plan, and it takes the mute.
        let governed = Self.plan(hardware)
        #expect(governed == [0])
        #expect(CoreAudioLidOutput.restoreMute(true, on: 1, within: governed,
                                               using: VolumeWriter(hardware: hardware)).isSettled)
        #expect(hardware.muteByElement[0] == true, "the fixture never muted anything")

        // And now the query changes its mind.
        hardware.masterIsWritable = false

        let now = CoreAudioLidOutput.mutedState(1, within: governed, hardware: hardware)
        #expect(now == true, "a device still muted at its master reported itself free")
        let entry = LidConserveRecord.Audio(uid: "u", volume: 0.4, muted: false,
                                            governed: governed)
        #expect(LidRestore.audio(entry, isPresent: true, isMutedNow: now) != .leaveAlone,
                "the undo record was dropped with the master still muted")

        // The restore cannot reach the master either, and that keeps the
        // entry rather than moving the write somewhere unrecorded.
        let writtenBefore = hardware.muteWriteElements.count
        let outcome = CoreAudioLidOutput.restoreMute(false, on: 1, within: governed,
                                                     using: VolumeWriter(hardware: hardware))
        #expect(outcome == .incomplete, "an unreachable plan reported itself restored")
        let strayWrites = Array(hardware.muteWriteElements.dropFirst(writtenBefore))
        #expect(strayWrites.isEmpty,
                "an unreachable plan was answered by writing \(strayWrites)")
        #expect(hardware.muteByElement[1] == false && hardware.muteByElement[2] == false,
                "the restore wrote channels the journal never named")
        #expect(hardware.muteByElement[0] == true, "the master was supposed to stay muted")

        // When the master can be written again, the entry is dischargeable.
        hardware.masterIsWritable = true
        #expect(CoreAudioLidOutput.restoreMute(false, on: 1, within: governed,
                                               using: VolumeWriter(hardware: hardware)) == .complete)
        #expect(hardware.muteByElement[0] == false)
    }

    /// One silent control among several is Ledge's silence still in force.
    /// "Is this device muted everywhere" is a different question, and false is
    /// its answer for a half-muted device — which would have freed the record.
    @Test("One governed control still muted is not a device the user freed")
    func oneGovernedControlStillMutedKeepsTheEntry() {
        let hardware = Device()
        hardware.hasMuteMaster = false
        hardware.channels = [1, 2, 3, 4]
        hardware.muteByElement = [1: false, 2: false, 3: false, 4: true]
        #expect(CoreAudioLidOutput.mutedState(1, within: [1, 2, 3, 4], hardware: hardware) == true,
                "a channel Ledge had silenced was written off as the user's doing")
    }

    /// An empty plan is not an empty device. Nothing was read, so nothing is
    /// known — and "nothing is known" must not arrive at the policy as "the
    /// user freed it", which is the answer that deletes the record.
    @Test("A plan with no controls in it answers nothing, not free")
    func emptyPlanIsUnknown() {
        let hardware = Device()
        hardware.muteByElement = [0: true, 1: true, 2: true]
        #expect(CoreAudioLidOutput.mutedState(1, within: [], hardware: hardware) == nil,
                "a device nobody looked at was reported free")
    }

    /// And unknown is still the third answer: nothing reads muted, but one
    /// control will not say, so nobody can claim the device was freed.
    @Test("A governed control that will not answer is unknown, not free")
    func unreadableGovernedControlIsUnknown() {
        let hardware = Device()
        hardware.hasMuteMaster = false
        hardware.channels = [1, 2]
        hardware.muteByElement = [1: false]
        hardware.silentMuteElements = [2]
        #expect(CoreAudioLidOutput.mutedState(1, within: [1, 2], hardware: hardware) == nil,
                "a control nobody could read was counted as free")
    }

    /// A record that cannot say which controls it owns does not get to guess.
    /// Writing anything at all would be a change with no undo entry behind it.
    @Test("A record with no plan writes nothing")
    func planlessRecordWritesNothing() {
        let hardware = Device()
        hardware.muteByElement = [0: true, 1: true, 2: true]
        let outcome = CoreAudioLidOutput.restoreMute(false, on: 1, within: nil,
                                                     using: VolumeWriter(hardware: hardware))
        #expect(outcome == .incomplete, "a plan nobody recorded was acted on anyway")
        #expect(hardware.muteWrites == 0, "a control the record does not name was written")
        #expect(hardware.muteByElement[0] == true)
    }

    /// Nor is a planless record evidence that the user freed anything, so the
    /// entry stays and the restore keeps being attempted.
    @Test("A record with no plan is never certified free")
    func planlessRecordIsNeverFree() {
        let entry = LidConserveRecord.Audio(uid: "u", muted: false, governed: nil)
        #expect(LidRestore.audio(entry, isPresent: true, isMutedNow: nil) != .leaveAlone)
    }

    /// Nothing is silenced that cannot be written down first, and *which
    /// controls* is part of being written down.
    @Test("A reading with no plan produces no journal entry")
    func readingWithoutAPlanIsNotJournalled() {
        #expect(AudioOutputReading(uid: "u", muted: false, governed: nil).entry == nil)
        #expect(AudioOutputReading(uid: "u", muted: false, governed: []).entry == nil)
        #expect(AudioOutputReading(uid: "u", muted: false, governed: [0]).entry?.governed == [0])
    }
}

/// What the real journal does with a file it cannot use.
///
/// Two different troubles with two different answers, and the fake cannot
/// establish which one the shipping reader reports: a file that cannot be
/// *parsed* is rubbish and may be set aside, while one that cannot be
/// *reached* is almost certainly still exactly what it was. Quarantining the
/// second, or carrying on as though the journal were empty, replaces a real
/// prior with whatever an already-darkened Mac happens to read.
@Suite("Reading the lid journal off a real disk")
struct FileLidConserveJournalTests {

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledge-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A record written here reads back the same")
    func roundTrip() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        let journal = FileLidConserveJournal(directory: home)
        let record = LidConserveRecord(writtenAt: Date(timeIntervalSince1970: 1),
                                       panel: .init(level: 0.6))
        try journal.write(record)
        #expect(try journal.read() == record)
    }

    @Test("No file at all is not a trouble")
    func absentIsNotATrouble() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try FileLidConserveJournal(directory: home).read() == nil)
    }

    @Test("Bytes that are not a record are unreadable")
    func garbageIsUnreadable() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("not json".utf8).write(to: home.appendingPathComponent("lid-conserve.json"))

        do {
            _ = try FileLidConserveJournal(directory: home).read()
            Issue.record("rubbish was read as a record")
        } catch {
            #expect(error as? LidJournalTrouble == .unreadable)
        }
    }

    /// The one `fileExists` cannot see: the file is there and its *parent*
    /// cannot be searched. The Boolean answers false, which is the one answer
    /// that authorises writing a new journal over the top.
    ///
    /// The same long-lived journal carries on afterwards, because that is
    /// where the loss happens — a fresh instance would just re-read the
    /// restored directory and look fine.
    @Test("A file behind an unreadable parent is not called absent")
    func deniedParentIsNotAbsence() throws {
        let home = try directory()
        let journal = FileLidConserveJournal(directory: home)
        try journal.write(LidConserveRecord(writtenAt: Date(timeIntervalSince1970: 1),
                                            panel: .init(level: 0.6)))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: home.path)
            try? FileManager.default.removeItem(at: home)
        }

        // No search permission on the directory holding it.
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: home.path)

        do {
            let answer = try journal.read()
            Issue.record("an unreachable record was reported as \(String(describing: answer))")
        } catch {
            #expect(error as? LidJournalTrouble == .unavailable,
                    "a file behind a denied parent was called absent, which authorises replacing it")
        }

        // And the same instance, once the parent is readable again, still has
        // the original.
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: home.path)
        #expect(try journal.read()?.panel?.level == 0.6)
    }

    /// Clearing has the same rule: a removal that failed because the path
    /// could not be reached is not a successful clear, and reporting one has
    /// the conserver believe this Mac owes nothing.
    @Test("A clear that could not happen is not reported as a clear")
    func deniedClearThrows() throws {
        let home = try directory()
        let journal = FileLidConserveJournal(directory: home)
        try journal.write(LidConserveRecord(writtenAt: Date(timeIntervalSince1970: 1),
                                            panel: .init(level: 0.6)))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: home.path)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: home.path)

        #expect(throws: (any Error).self) { try journal.clear() }

        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: home.path)
        #expect(try journal.read()?.panel?.level == 0.6, "the record went after a failed clear")
    }

    @Test("Clearing a journal that was never there is not a failure")
    func clearingNothingIsFine() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileLidConserveJournal(directory: home).clear()
        try FileLidConserveJournal(directory: home).moveAside()
    }

    /// A directory where the file should be: it exists, and it cannot be
    /// read. Nothing about its contents is in question, so nothing about them
    /// may be assumed — and it must never be quarantined.
    @Test("A file that cannot be reached is unavailable, not unreadable")
    func unreachableIsNotUnreadable() throws {
        let home = try directory()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("lid-conserve.json"),
            withIntermediateDirectories: false
        )

        do {
            _ = try FileLidConserveJournal(directory: home).read()
            Issue.record("something unreachable was read as a record")
        } catch {
            #expect(error as? LidJournalTrouble == .unavailable,
                    "a file that could not be reached was called rubbish, and would be set aside")
        }
    }
}

