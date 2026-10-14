import Foundation
import Testing

@testable import LedgeHelperKit

/// Low Power Mode, which is the one saving that needs root.
///
/// Ledge throttles a Mac on purpose here, which deserves saying out loud: the
/// agents this feature exists for are network-bound — they sit on a socket,
/// not on a clock — so the throttle costs them almost nothing while the
/// battery saving is real. That trade is the only reason any of this is worth
/// a privileged write.
///
/// Everything below is about the other half: putting it back. A user who had
/// Low Power Mode on themselves, or on for battery only, must have it exactly
/// that way when the session ends, and a daemon that could not tell "we turned
/// this on" from "it was already on" would switch off something they chose.
@Suite("Low Power Mode, and getting it back")
struct HelperCoreLowPowerTests {

    private func holding(_ mac: FakeMac = FakeMac()) -> Daemon {
        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: TestClock(), file: ClaimFile(), mac: mac)
        daemon.start()
        daemon.hold()
        return daemon
    }

    // MARK: - The ordinary round trip

    @Test("A hold that asks for Low Power Mode gets it")
    func turnsItOn() {
        let daemon = holding()
        let answer = daemon.lowPower(true)

        #expect(answer.last == .ok)
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: true, charger: true))
        #expect(daemon.status.lowPowerClaimed)
    }

    /// Journalled before the change, never after — the same order the sleep
    /// setting uses and for the same reason. A change with no record is a Mac
    /// throttled with nothing on disk saying who did it.
    @Test("The prior reaches the disk before the write does")
    func journalsBeforeWriting() {
        let daemon = holding()
        // Children are answered one at a time, so the transaction can be
        // caught between its read and its write — which is the only moment
        // the order is visible.
        daemon.mac.hangs = true
        daemon.lowPower(true)
        daemon.answerOne()

        // The write has been started and not answered. The prior is already
        // down, and it is the value from *before*.
        #expect(daemon.claim?.lowPowerPrior == 0)
        #expect(daemon.pmset.commands.contains { $0.isWrite && $0.isLowPower })
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "the Mac changed before the record of it did")
    }

    @Test("A disk that refuses the prior means nothing is written at all")
    func refusedJournalChangesNothing() {
        let daemon = holding()
        daemon.store.file.saveFailures = 1
        daemon.lowPower(true)

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
        #expect(daemon.claim?.lowPowerPrior == nil)
        #expect(!daemon.pmset.commands.contains { $0.isWrite && $0.isLowPower })
    }

    @Test("Releasing the hold puts Low Power Mode back and clears the claim")
    func releasePutsItBack() {
        let daemon = holding()
        daemon.lowPower(true)
        daemon.release()

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
        #expect(daemon.claim == nil)
        #expect(daemon.core.isClean)
    }

    // MARK: - The prior is the whole point

    /// The headline rule. Ledge did not turn it on, so Ledge does not turn it
    /// off.
    @Test("Low Power Mode the user had on is still on when the session ends")
    func alreadyOnStaysOn() {
        let mac = FakeMac()
        mac.lowPower = LowPowerSetting(battery: true, charger: true)
        let daemon = holding(mac)

        daemon.lowPower(true)
        #expect(daemon.claim?.lowPowerPrior == 3)
        daemon.release()

        #expect(mac.lowPower == LowPowerSetting(battery: true, charger: true),
                "a setting the user chose was switched off")
        #expect(daemon.claim == nil)
    }

    /// System Settings offers Never, Always, Only on Battery and Only on Power
    /// Adapter. Those four are two booleans, and a restore that wrote one `-a`
    /// would quietly turn the two interesting ones into Never.
    @Test("Only on Battery survives the session that turned it on everywhere")
    func perSourceSurvives() {
        let mac = FakeMac()
        mac.lowPower = LowPowerSetting(battery: true, charger: false)
        let daemon = holding(mac)

        daemon.lowPower(true)
        #expect(mac.lowPower == LowPowerSetting(battery: true, charger: true),
                "the hold did not get Low Power Mode everywhere")
        #expect(daemon.claim?.lowPowerPrior == 1)

        daemon.release()
        #expect(mac.lowPower == LowPowerSetting(battery: true, charger: false),
                "Only on Battery came back as something else")
    }

    @Test("Only on Power Adapter survives too")
    func chargerOnlySurvives() {
        let mac = FakeMac()
        mac.lowPower = LowPowerSetting(battery: false, charger: true)
        let daemon = holding(mac)

        daemon.lowPower(true)
        #expect(daemon.claim?.lowPowerPrior == 2)
        daemon.release()
        #expect(mac.lowPower == LowPowerSetting(battery: false, charger: true))
    }

    /// A desktop has no battery, and `pmset -b` aimed at one is a write that
    /// cannot land and a readback that can never agree.
    @Test("A Mac with one power source is never written at the other")
    func desktopIsNeverWrittenAtItsBattery() {
        let mac = FakeMac()
        mac.lowPower = LowPowerSetting(battery: nil, charger: false)
        let daemon = holding(mac)

        daemon.lowPower(true)
        #expect(mac.lowPower == LowPowerSetting(battery: nil, charger: true))
        daemon.release()
        #expect(mac.lowPower == LowPowerSetting(battery: nil, charger: false))

        let aimed = daemon.pmset.commands.compactMap { command -> PmsetPowerSource? in
            guard case .writeLowPowerMode(_, let source) = command else { return nil }
            return source
        }
        #expect(aimed.allSatisfy { $0 == .all }, "a desktop was sent a per-source write")
        #expect(daemon.claim == nil)
    }

    /// A second attempt reads a Mac the first attempt may already have
    /// changed. Recording that would journal Ledge's own change as the user's
    /// choice, and the restore would then put Low Power Mode back *on*.
    @Test("A retry never records the state the first attempt left behind")
    func priorIsNeverOverwritten() {
        let daemon = holding()
        daemon.mac.refuseLowPowerWrites = 1
        daemon.lowPower(true)
        #expect(daemon.claim?.lowPowerPrior == 0)

        // The failed write is retried after the backoff, and by now the Mac
        // could read as anything at all.
        daemon.mac.lowPower = LowPowerSetting(battery: true, charger: true)
        daemon.advance(10)

        #expect(daemon.claim?.lowPowerPrior == 0,
                "the retry journalled the conserved state as the thing to restore")
        daemon.mac.lowPower = LowPowerSetting(battery: true, charger: true)
        daemon.release()
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
    }

    // MARK: - The hold is what it hangs on

    @Test("A session that is not holding this Mac is refused")
    func onlyTheHolderMayAsk() {
        let daemon = holding()
        let answer = daemon.lowPower(true, session: Daemon.sessionB)

        #expect(answer.last == .notHolder)
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
    }

    /// Every heartbeat retires the generation before it, so a request carrying
    /// an old one is a message from before a lapse nobody saw at the time.
    @Test("A generation the daemon has moved past is stale")
    func staleGeneration() {
        let daemon = holding()
        daemon.hold(generation: 2)

        #expect(daemon.lowPower(true, generation: 1).last == .stale)
        #expect(daemon.lowPower(true, generation: 2).last == .ok)
    }

    @Test("A malformed session is a bug on the app's side, and says so")
    func invalidArgument() {
        let daemon = holding()
        #expect(daemon.lowPower(true, session: "not-a-uuid").last == .invalidArgument)
        #expect(daemon.lowPower(true, generation: 0).last == .invalidArgument)
    }

    /// The want goes with the holder, always. A Low Power Mode left on past
    /// the session that wanted it is a Mac quietly running slower than its
    /// owner asked for, with nothing to explain it.
    @Test("A lease that lapses puts Low Power Mode back")
    func lapsedLeaseRestores() {
        let daemon = holding()
        daemon.lowPower(true)
        #expect(daemon.mac.lowPower.isOnAnywhere)

        daemon.advance(200)

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
        #expect(daemon.claim == nil)
    }

    @Test("A deadline that passes puts Low Power Mode back")
    func deadlineRestores() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(deadline: daemon.clock.now.addingTimeInterval(60))
        daemon.lowPower(true)
        #expect(daemon.mac.lowPower.isOnAnywhere)

        daemon.advance(61)

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
    }

    @Test("launchd taking the daemon down puts Low Power Mode back")
    func sigtermRestores() {
        let daemon = holding()
        daemon.lowPower(true)

        daemon.core.sigterm()
        daemon.drain()

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
        #expect(daemon.core.isClean)
    }

    @Test("Asking for it back while the hold continues leaves the hold alone")
    func givingItBackMidSession() {
        let daemon = holding()
        daemon.lowPower(true)
        daemon.lowPower(false)

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
        #expect(daemon.mac.sleepDisabled == 1, "the hold went with it")
        #expect(daemon.claim?.sleepDisabledClaimed == true)
        #expect(daemon.claim?.lowPowerPrior == nil)
    }

    @Test("A daemon being taken down accepts nothing new")
    func terminatingRefuses() {
        let daemon = holding()
        daemon.core.sigterm()
        daemon.drain()

        #expect(daemon.lowPower(true).last == .stale)
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "a daemon on its way out took on something new to put back")
    }

    /// The want belongs to the session that stated it. A new hold inheriting
    /// one would throttle a Mac on behalf of a user who had not asked this
    /// time — and would do it with no record that anybody ever had.
    @Test("A new hold does not inherit the last one's Low Power Mode")
    func wantDoesNotOutliveItsSession() {
        let daemon = holding()
        daemon.lowPower(true)
        daemon.release()
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))

        daemon.hold(session: Daemon.sessionB, generation: 1)

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "Low Power Mode came back on for a session that never asked for it")
        #expect(daemon.claim?.lowPowerPrior == nil)
    }

    /// Same rule one lapse along: the lease ending is not the user asking for
    /// anything, and the hold they take next is a fresh one.
    @Test("A hold taken after a lapse does not inherit the want either")
    func wantDoesNotSurviveALapse() {
        let daemon = holding()
        daemon.lowPower(true)
        daemon.advance(200)
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))

        daemon.hold(session: Daemon.sessionB, generation: 1)

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "a lapsed session's Low Power Mode was handed to the next one")
    }

    // MARK: - The other build

    /// Two Ledge builds share one Mac and one claim file. A live claim of the
    /// other build is theirs, and so is whatever Low Power Mode reads as.
    @Test("A live claim of the other build stops us touching the setting")
    func otherBuildBlocksTheApply() {
        let daemon = holding()
        let theirs = claim(label: "com.egemert.ledge.debug.keepawake",
                           leaseExpiryNs: daemon.clock.continuousNanoseconds + 90_000_000_000)
        daemon.store.file.ledger?.claims["com.egemert.ledge.debug.keepawake"] = theirs

        daemon.lowPower(true)

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "Low Power Mode was taken from under the other build")
        #expect(daemon.claim?.lowPowerPrior == nil)
    }

    /// They took this Mac over while we were not holding it. Writing our prior
    /// over theirs would end their conserve from inside ours.
    @Test("The other build taking over leaves its Low Power Mode alone")
    func otherBuildTakingOverEndsOurClaim() {
        let file = ClaimFile()
        let mac = FakeMac()
        mac.lowPower = LowPowerSetting(battery: true, charger: true)
        let clock = TestClock()
        var ours = claim(label: "com.egemert.ledge.keepawake", leaseExpiryNs: 0,
                         sleepDisabledClaimed: false)
        ours.lowPowerPrior = 0
        var theirs = claim(label: "com.egemert.ledge.debug.keepawake",
                           leaseExpiryNs: clock.continuousNanoseconds + 90_000_000_000)
        theirs.lowPowerPrior = 3
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": ours,
            "com.egemert.ledge.debug.keepawake": theirs,
        ])

        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: clock, file: file, mac: mac)
        daemon.start()

        #expect(mac.lowPower == LowPowerSetting(battery: true, charger: true),
                "the other build's Low Power Mode was undone from inside ours")
        #expect(daemon.claim == nil, "our claim outlived the Mac being taken from us")
        #expect(file.ledger?.claims["com.egemert.ledge.debug.keepawake"]?.lowPowerPrior == 3,
                "the other build's prior was cleared by a daemon that is not theirs")
    }

    /// Nothing of ours is in the file at all — only a claim the other build
    /// left behind when its app stopped speaking. Somebody has to put it back.
    @Test("A lapsed claim of the other build is put back on its behalf")
    func lapsedOtherBuildIsRestored() {
        let file = ClaimFile()
        let mac = FakeMac()
        mac.lowPower = LowPowerSetting(battery: true, charger: true)
        var theirs = claim(label: "com.egemert.ledge.debug.keepawake", leaseExpiryNs: 0,
                           sleepDisabledClaimed: false)
        theirs.lowPowerPrior = 0
        file.ledger = ClaimLedger(claims: ["com.egemert.ledge.debug.keepawake": theirs])

        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: TestClock(), file: file, mac: mac)
        daemon.start()

        #expect(mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "a Low Power Mode nobody is holding was left on")
        #expect(file.ledger?.claims.isEmpty == true)
    }

    // MARK: - The two settings are two promises

    /// A claim makes up to two promises and the sleep restore discharges only
    /// one of them. Deleting the record there would leave the Mac throttled
    /// with nothing on disk saying who did it.
    @Test("Putting the sleep setting back does not throw away the Low Power claim")
    func sleepRestoreKeepsTheLowPowerClaim() {
        let daemon = holding()
        daemon.lowPower(true)
        // The Low Power Mode restore cannot land, so the sleep restore
        // finishes first and on its own.
        daemon.mac.refuseLowPowerWrites = 99
        daemon.release()

        #expect(daemon.mac.sleepDisabled == 0, "the sleep setting was not put back")
        #expect(daemon.claim?.sleepDisabledClaimed == false)
        #expect(daemon.claim?.lowPowerPrior == 0, "the Low Power Mode claim was thrown away")
        #expect(!daemon.core.isClean)
    }

    @Test("A Low Power Mode restore that keeps failing keeps trying")
    func failedRestoreKeepsTrying() {
        let daemon = holding()
        daemon.lowPower(true)
        daemon.mac.refuseLowPowerWrites = 2
        daemon.release()
        #expect(daemon.claim?.lowPowerPrior == 0)

        daemon.advance(10)
        daemon.advance(20)

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
        #expect(daemon.claim == nil)
        #expect(daemon.core.isClean)
    }

    /// `pmset` exiting cleanly is not evidence. The readback is.
    @Test("A write that exits cleanly and changes nothing is not believed")
    func readbackIsTheEvidence() {
        let daemon = holding()
        daemon.mac.ignoreLowPowerWrites = true
        daemon.lowPower(true)

        #expect(!daemon.status.clean)
        #expect(daemon.claim?.lowPowerPrior == 0, "the claim went with the unconfirmed write")

        // And it goes on not being believed: a daemon that took `pmset`
        // exiting cleanly as evidence would stop here and leave a Mac that is
        // not in Low Power Mode with a claim saying it is.
        let attempts = daemon.pmset.commands.filter { $0.isWrite && $0.isLowPower }.count
        daemon.advance(10)
        #expect(daemon.pmset.commands.filter { $0.isWrite && $0.isLowPower }.count > attempts,
                "an unconfirmed write was taken for a finished one")

        daemon.mac.ignoreLowPowerWrites = false
        daemon.advance(20)
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: true, charger: true))
    }

    /// `status` publishes a SleepDisabled, and an answer about a different
    /// setting is not one — however much it looks like a number.
    @Test("An answer of the wrong shape is refused, not filed")
    func wrongShapedAnswerIsRefused() {
        let daemon = holding()
        #expect(daemon.status.sleepDisabled == 1)
        daemon.mac.answersLowPowerReadsWithANumber = true
        daemon.lowPower(true)

        #expect(daemon.status.sleepDisabled == 1,
                "a number about Low Power Mode was published as the sleep setting")
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "a reading nobody could understand was acted on")
        #expect(daemon.claim?.lowPowerPrior == nil)
    }

    /// A claim that says nothing but "Low Power Mode was off" must not send
    /// the sleep restore to write `disablesleep 0` over a 1 that somebody else
    /// — Amphetamine, a Terminal window — had set.
    @Test("A Low Power claim never drags the sleep setting with it")
    func lowPowerClaimLeavesForeignSleepAlone() {
        let file = ClaimFile()
        let mac = FakeMac()
        mac.sleepDisabled = 1
        mac.lowPower = LowPowerSetting(battery: true, charger: true)
        var left = claim(label: "com.egemert.ledge.keepawake", leaseExpiryNs: 0,
                         sleepDisabledClaimed: false)
        left.lowPowerPrior = 0
        file.ledger = ClaimLedger(claims: ["com.egemert.ledge.keepawake": left])

        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: TestClock(), file: file, mac: mac)
        daemon.start()

        #expect(mac.sleepDisabled == 1, "somebody else's SleepDisabled was undone")
        #expect(mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "the Low Power Mode left behind was not put back")
        #expect(daemon.claim == nil)
    }

    /// A claim makes up to two promises, and the sleep *apply* path used to
    /// delete the whole record when it discharged one of them — leaving a Mac
    /// throttled with nothing on disk saying who did it, and `status.clean`
    /// reporting that all was well.
    @Test("Taking the sleep setting does not throw away an outstanding Low Power claim")
    func applyKeepsTheLowPowerClaim() {
        let mac = FakeMac()
        mac.lowPower = LowPowerSetting(battery: true, charger: false)
        let daemon = holding(mac)
        daemon.lowPower(true)
        #expect(daemon.claim?.lowPowerPrior == 1, "Only on Battery was not recorded")

        // From here the Low Power Mode restore can never land.
        mac.refuseLowPowerWrites = 99

        // And the sleep restore writes 0 but cannot read it back, so the
        // setting really is 0 while the claim still says it might be ours.
        mac.hangs = true
        daemon.release()
        daemon.answerOne()              // the read: SleepDisabled is 1
        daemon.answerOne()              // the write: it becomes 0
        mac.refuseReads = 1
        daemon.answerOne()              // the readback, refused
        mac.hangs = false

        #expect(mac.sleepDisabled == 0)
        #expect(daemon.claim?.sleepDisabledClaimed == true)
        #expect(daemon.claim?.lowPowerPrior == 1)

        // Now a new session takes the sleep setting, and finds that claim
        // sitting where its own is going.
        daemon.hold(session: Daemon.sessionB, generation: 1)

        #expect(daemon.claim?.lowPowerPrior == 1,
                "an outstanding Low Power Mode prior was deleted by the sleep apply")
        #expect(!daemon.core.isClean)

        mac.refuseLowPowerWrites = 0
        daemon.release(session: Daemon.sessionB, generation: 1)
        #expect(mac.lowPower == LowPowerSetting(battery: true, charger: false),
                "the user's Only on Battery was lost with the record")
        #expect(daemon.claim == nil)
        #expect(daemon.core.isClean)
    }

    /// The reading a replacement daemon takes is not a baseline when somebody
    /// else's change is still standing in it. Journalling it as the user's
    /// original choice left Low Power Mode on for both sources for good, and
    /// reported the daemon clean while it did.
    @Test("A new daemon does not record the old one's change as the user's choice")
    func baselineIsNotTakenOnTopOfAnotherClaim() {
        let file = ClaimFile()
        let mac = FakeMac()
        // The old build turned Low Power Mode on everywhere; it had been on
        // for battery only before that, and its claim says so.
        mac.lowPower = LowPowerSetting(battery: true, charger: true)
        var old = claim(label: "com.egemert.ledge.debug.keepawake", leaseExpiryNs: 0,
                        sleepDisabledClaimed: false)
        old.lowPowerPrior = 1
        file.ledger = ClaimLedger(claims: ["com.egemert.ledge.debug.keepawake": old])

        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: TestClock(), file: file, mac: mac)
        // Nothing this daemon writes lands, so the old claim is still standing
        // when the new session arrives — which is the whole scenario.
        mac.refuseLowPowerWrites = 99
        daemon.start()
        daemon.hold()
        #expect(file.ledger?.claims["com.egemert.ledge.debug.keepawake"]?.lowPowerPrior == 1,
                "the old claim was already gone, so nothing is being tested")

        daemon.lowPower(true)

        // No baseline may be taken while somebody else's change is standing in
        // the reading. The old claim is put back first; ours records nothing.
        #expect(daemon.claim?.lowPowerPrior == nil,
                "the old daemon's applied state was journalled as the user's choice")

        // Once the writes land, the old claim goes back to what it recorded,
        // and only then does this session take a baseline of its own.
        mac.refuseLowPowerWrites = 0
        daemon.advance(10)
        daemon.advance(10)

        #expect(file.ledger?.claims["com.egemert.ledge.debug.keepawake"] == nil,
                "the old claim was never discharged")
        #expect(daemon.claim?.lowPowerPrior == 1,
                "this session's baseline is not the state the user had chosen")

        daemon.release()
        #expect(mac.lowPower == LowPowerSetting(battery: true, charger: false),
                "Low Power Mode was left on for a source the user never chose")
        #expect(file.ledger?.claims.isEmpty == true)
        #expect(daemon.core.isClean)
    }

    // MARK: - Recovery

    /// The daemon can be killed, updated or restarted with Low Power Mode on.
    /// No hold survives that, and the claim is the only thing that knows.
    @Test("A claim left by a dead daemon is put back at startup")
    func startupRestoresALeftoverClaim() {
        let file = ClaimFile()
        let mac = FakeMac()
        mac.sleepDisabled = 1
        mac.lowPower = LowPowerSetting(battery: true, charger: true)
        var left = claim(label: "com.egemert.ledge.keepawake", leaseExpiryNs: 0)
        left.lowPowerPrior = 1
        file.ledger = ClaimLedger(claims: ["com.egemert.ledge.keepawake": left])

        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: TestClock(), file: file, mac: mac)
        daemon.start()

        #expect(mac.sleepDisabled == 0)
        #expect(mac.lowPower == LowPowerSetting(battery: true, charger: false),
                "the prior the dead daemon recorded was not honoured")
        #expect(daemon.claim == nil)
        #expect(daemon.core.isClean)
    }

    /// A live claim of the other build is theirs. The 1 on this Mac is theirs,
    /// and so is the Low Power Mode behind it.
    @Test("The other build's live claim is left entirely alone")
    func otherLedgeIsLeftAlone() {
        let file = ClaimFile()
        let mac = FakeMac()
        mac.lowPower = LowPowerSetting(battery: true, charger: true)
        let clock = TestClock()
        var theirs = claim(label: "com.egemert.ledge.debug.keepawake",
                           leaseExpiryNs: clock.continuousNanoseconds + 90_000_000_000)
        theirs.lowPowerPrior = 0
        file.ledger = ClaimLedger(claims: ["com.egemert.ledge.debug.keepawake": theirs])
        mac.sleepDisabled = 1

        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: clock, file: file, mac: mac)
        daemon.start()

        #expect(mac.lowPower == LowPowerSetting(battery: true, charger: true),
                "the other build's Low Power Mode was undone from inside ours")
        #expect(mac.sleepDisabled == 1)
        #expect(file.ledger?.claims["com.egemert.ledge.debug.keepawake"] != nil)
    }

    /// Two claims that disagree mean two daemons each read the Mac at a
    /// different moment and nothing says which was first. On wins: a Low Power
    /// Mode somebody did not want is one click away, and one they did want and
    /// lost is Ledge undoing a decision it never made.
    @Test("Two lapsed claims that disagree are restored to whichever wanted it on")
    func disagreeingPriorsRestoreToOn() {
        let file = ClaimFile()
        let mac = FakeMac()
        mac.lowPower = LowPowerSetting(battery: true, charger: true)
        var ours = claim(label: "com.egemert.ledge.keepawake", leaseExpiryNs: 0,
                         sleepDisabledClaimed: false)
        ours.lowPowerPrior = 0
        var theirs = claim(label: "com.egemert.ledge.debug.keepawake", leaseExpiryNs: 0,
                           sleepDisabledClaimed: false)
        theirs.lowPowerPrior = 1
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": ours,
            "com.egemert.ledge.debug.keepawake": theirs,
        ])

        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: TestClock(), file: file, mac: mac)
        daemon.start()

        #expect(mac.lowPower == LowPowerSetting(battery: true, charger: false))
        #expect(file.ledger?.claims.isEmpty == true)
    }

    // MARK: - Reading it

    @Test("A read that fails leaves the setting and the claim where they are")
    func failedReadChangesNothing() {
        let daemon = holding()
        daemon.mac.refuseLowPowerReads = 1
        daemon.lowPower(true)

        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
        #expect(daemon.claim?.lowPowerPrior == nil)

        daemon.advance(10)
        #expect(daemon.mac.lowPower.isOnAnywhere, "the retry never came")
    }

    /// `status` publishes a SleepDisabled, and a Low Power Mode read is a
    /// number about a different setting entirely.
    @Test("A Low Power Mode read is never reported as SleepDisabled")
    func lowPowerReadIsNotSleepDisabled() {
        let daemon = holding()
        #expect(daemon.status.sleepDisabled == 1)
        daemon.lowPower(true)
        #expect(daemon.status.sleepDisabled == 1,
                "a Low Power Mode reading was published as the sleep setting")
    }

    // MARK: - A failed reply is not a stopped writer

    /// Low Power Mode needs the same final-resolution path the sleep setting
    /// has. Its readback is the only evidence the write landed, and a readback
    /// taken before some other writer of this process finished describes a
    /// Mac that has since moved. Believing it caches `lowPowerApplied`, and
    /// nothing looks at the setting again.
    @Test("A Low Power readback taken under a late write is not believed")
    func lowPowerReadbackUnderALateWrite() {
        let daemon = holding()
        daemon.mac.hangs = true
        daemon.lowPower(true)

        // Read, write, and then hold the verification.
        daemon.answerOne()          // the read
        daemon.answerOne()          // the write
        guard daemon.pmset.outstanding != nil else {
            Issue.record("the fixture never reached the Low Power verification")
            return
        }

        // A write this helper had given up on finishes while that readback is
        // still out.
        daemon.core.noticeLateWrite(opID: 4242)
        daemon.answerOne()          // the verification

        // Believed, it would be applied and done with. Fenced, the setting is
        // something to look at again.
        daemon.mac.hangs = false
        let started = daemon.pmset.started.count
        daemon.core.tick()
        daemon.drain()
        #expect(daemon.pmset.started.count > started,
                "a Low Power readback taken under a late write was cached as applied")
    }

    /// And the cached belief itself goes, so the next pass re-applies rather
    /// than skipping the work entirely.
    @Test("A late write makes an applied Low Power Mode something to check again")
    func lateWriteReopensLowPower() {
        let daemon = holding()
        daemon.lowPower(true)
        daemon.drain()
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: true, charger: true))

        let quiet = daemon.pmset.started.count
        daemon.core.tick()
        daemon.drain()
        #expect(daemon.pmset.started.count == quiet,
                "a settled hold was doing work for no reason")

        daemon.core.noticeLateWrite(opID: 4242)
        daemon.drain()

        // Specifically Low Power Mode, not merely "some child ran". The
        // sleep setting re-reads on its own cadence; the thing that was
        // being skipped is this, because the core believed it was applied.
        let after = daemon.pmset.commands.dropFirst(quiet)
        #expect(after.contains { $0.isLowPower },
                "nothing looked at Low Power Mode after a late write landed: \(Array(after))")
    }


    // MARK: - Teardown while a writer can still act

    /// The stronger half of "a reply is not a stopped writer".
    ///
    /// The counters fence a *cache*: they stop a readback taken in the wrong
    /// moment being believed. This is the case they cannot reach — the
    /// reading is genuinely fresh, nothing has changed yet, and it is still
    /// no promise about the next moment. End saw a true off/off, dropped the
    /// prior, and when the old writer landed its on/on there was no holder,
    /// no record and nothing left that knew Low Power Mode had ever been
    /// Ledge's to put back.
    @Test("Low Power Mode's prior survives an End taken while a writer can still act")
    func lowPowerPriorSurvivesLiveWriter() {
        let daemon = holding()
        daemon.lowPower(true)
        daemon.drain()
        #expect(daemon.claim?.lowPowerPrior != nil, "the fixture never recorded a prior")

        // An operation is answered for while its child can still act.
        daemon.core.noticeLiveWriter(opID: 4242)

        daemon.lowPower(false)
        daemon.drain()

        #expect(daemon.claim?.lowPowerPrior != nil,
                "the prior was dropped while a writer could still change the setting")
        #expect(!daemon.core.isClean,
                "the helper was ready to quit with a privileged write still in flight")

        // And once the writer is accounted for, the obligation discharges.
        daemon.core.noticeLateWrite(opID: 4242)
        daemon.drain()
        #expect(daemon.claim?.lowPowerPrior == nil,
                "the prior outlived the writer it was being kept for")
    }

    /// Two helpers, one ledger, and a writer that outlives a lease.
    ///
    /// The live-writer set lives in one `HelperCore`, and the other build's
    /// helper starts with an empty one. It saw a lapsed claim, read Low Power
    /// Mode as already off, and cleared the prior — so when the first
    /// helper's old child finally applied on/on there was no record anywhere
    /// on the Mac of what it had been before, and neither helper put it back.
    ///
    /// The uncertainty has to be on the disk with the thing it is uncertain
    /// about, because the disk is the only thing both helpers can see.
    @Test("Another helper does not clear a prior whose writer can still act")
    func siblingKeepsAPriorWithALiveWriter() {
        let file = ClaimFile()
        let mac = FakeMac()
        let clock = TestClock()
        let a = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        a.start()
        a.hold()
        a.lowPower(true)
        a.drain()
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.lowPowerPrior != nil,
                "the fixture never journalled a prior")

        // One of A's operations is answered for while its child can still
        // act. A keeps its own claim, and says so where B can read it —
        // immediately, with nothing else running in between. B is a separate
        // process and does not wait for A's next heartbeat to look.
        a.core.noticeLiveWriter(opID: 4242)
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false,
                "the uncertainty never reached the disk, where the other helper looks")

        // A's lease lapses. A is still alive, and so is its writer.
        clock.advance(91)

        // The other build's helper starts and takes over the cleanup.
        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        b.start()
        b.drain()

        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.lowPowerPrior != nil,
                "another helper destroyed a prior whose writer had not stopped")

        // And when A's writer is finally accounted for, the disk says so at
        // once — before any further work — and A discharges the record
        // itself, with it still there to discharge.
        a.core.noticeLateWrite(opID: 4242)
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == true,
                "the uncertainty outlived the writer, so nothing could ever clear the record")
        a.drain()
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.lowPowerPrior == nil,
                "the prior outlived the writer it was being kept for")
    }

    /// The sleep half of the same rule: a lapsed claim with an unresolved
    /// writer is still restorable by the other helper — it may write the
    /// setting back — but its record is not theirs to delete.
    @Test("Another helper does not clear a sleep claim whose writer can still act")
    func siblingKeepsASleepClaimWithALiveWriter() {
        let file = ClaimFile()
        let mac = FakeMac()
        let clock = TestClock()
        let a = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        a.start()
        a.hold()
        a.drain()
        #expect(mac.sleepDisabled == 1, "the fixture never took the hold")

        a.core.noticeLiveWriter(opID: 99)
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false,
                "the uncertainty never reached the disk")
        clock.advance(91)

        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        b.start()
        b.drain()

        #expect(mac.sleepDisabled == 0, "the other helper did not put the setting back")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] != nil,
                "another helper deleted a record whose writer had not stopped")

        a.core.noticeLateWrite(opID: 99)
        a.drain()
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] == nil,
                "the record outlived the writer it was being kept for")
    }

    /// The shortcut, not the write: End finds Low Power Mode already where
    /// the prior says it should be — somebody put it back, or it never moved
    /// — and drops the record without writing anything. The reading is true
    /// and still says nothing about the next moment.
    @Test("An already-restored Low Power Mode keeps its prior under a live writer")
    func alreadyRestoredLowPowerKeepsThePrior() {
        let mac = FakeMac()
        let daemon = holding(mac)
        daemon.lowPower(true)
        daemon.drain()
        #expect(daemon.claim?.lowPowerPrior != nil, "the fixture never recorded a prior")

        // Something else has already put it back, so the restore has nothing
        // to write and takes the shortcut.
        mac.lowPower = LowPowerSetting(battery: false, charger: false)
        daemon.core.noticeLiveWriter(opID: 4242)

        daemon.lowPower(false)
        daemon.drain()

        #expect(daemon.claim?.lowPowerPrior != nil,
                "the prior was dropped on a reading that could not speak for the next moment")

        daemon.core.noticeLateWrite(opID: 4242)
        daemon.drain()
        #expect(daemon.claim?.lowPowerPrior == nil,
                "the prior outlived the writer it was being kept for")
    }

    /// The same shape with the readback held: the reply is delivered after
    /// the old writer has landed, so the counter *has* moved. Fencing the
    /// cache was never enough — this branch destroys the record.
    @Test("A held Low Power readback does not discharge the prior under a late write")
    func heldLowPowerReadbackKeepsThePrior() {
        let daemon = holding()
        daemon.lowPower(true)
        daemon.drain()

        daemon.mac.hangs = true
        daemon.lowPower(false)
        daemon.answerOne()      // the read
        daemon.answerOne()      // the write
        guard daemon.pmset.outstanding != nil else {
            Issue.record("the fixture never reached the Low Power verification")
            return
        }

        // The old writer finishes while that readback is still out.
        daemon.core.noticeLateWrite(opID: 4242)
        daemon.answerOne()      // the verification, taken before it landed

        #expect(daemon.claim?.lowPowerPrior != nil,
                "a readback taken under a late write discharged the prior")
    }


    // MARK: - One set of rules for two privileged writes

    /// The admission rule from the sleep path, in the path it had not reached.
    ///
    /// A Low Power child could exist over a prior whose record said nothing
    /// about it — the same window, one setting across.
    @Test("The record that admits a Low Power write already says a writer is outstanding")
    func lowPowerAdmissionIsDurable() {
        let mac = FakeMac()
        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: TestClock(), file: ClaimFile(), mac: mac)
        daemon.start()
        daemon.hold()
        daemon.drain()

        let atAdmission = Recorded()
        daemon.pmset.onStart = {
            if daemon.pmset.started.last?.command.isWrite == true,
               daemon.pmset.started.last?.command.isLowPower == true,
               atAdmission.value == nil {
                atAdmission.set(daemon.store.file.ledger?
                    .claims["com.egemert.ledge.keepawake"])
            }
        }

        daemon.lowPower(true)
        daemon.drain()

        #expect(atAdmission.value != nil, "the fixture never admitted a Low Power write")
        #expect(atAdmission.value??.lowPowerPrior != nil,
                "the prior was not journalled before the write")
        #expect(atAdmission.value??.mayBeRemoved == false,
                "a Low Power write was admitted over a record that did not say so")
        #expect(atAdmission.value??.writers?.isEmpty == false, "the uncertainty did not say whose it was")
    }

    /// And a disk that refuses the record refuses the write with it.
    @Test("A Low Power write is not made when its record cannot be journalled")
    func lowPowerWriteNeedsItsRecord() {
        let mac = FakeMac()
        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: TestClock(), file: ClaimFile(), mac: mac)
        daemon.start()
        daemon.hold()
        daemon.drain()

        daemon.store.file.saveFailures = 1
        daemon.lowPower(true)
        daemon.drain()

        #expect(!daemon.pmset.commands.contains { $0.isWrite && $0.isLowPower },
                "a Low Power write went out over a record the disk had refused")
        #expect(daemon.mac.lowPower == LowPowerSetting(battery: false, charger: false))
    }

    /// The retained cache, keyed per resource.
    ///
    /// Keyed by label alone it answered for settings it had never touched: a
    /// Low Power restore cached the whole label, every completed read then
    /// admitted another Low Power read without end, and End skipped the sleep
    /// restore it still owed.
    @Test("A Low Power toggle neither loops nor suppresses the session's End")
    func lowPowerTogglesDoNotPoisonTheCache() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        // An old run left uncertainty this one may not clear.
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": HelperClaim(
                holderLabel: "com.egemert.ledge.keepawake", boot: "boot-1",
                sessionID: "S0", generation: 1, deadline: nil,
                leaseExpiryContinuousNs: 0, sleepDisabledClaimed: true,
                lowPowerPrior: 0, writers: [WriterMark(run: "a-dead-run", boot: "boot-1")])
        ])
        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: clock, file: file, mac: mac)
        daemon.start()
        daemon.drain()

        daemon.hold()
        daemon.drain()
        #expect(mac.sleepDisabled == 1, "the new session never took its hold")

        daemon.lowPower(true)
        daemon.drain()
        daemon.lowPower(false)
        daemon.drain()

        // Turning it off again must not leave the helper reading the setting
        // on every completed child for the rest of its life.
        let settled = daemon.pmset.started.count
        for _ in 0..<20 { daemon.core.tick(); daemon.drain() }
        #expect(daemon.pmset.started.count == settled,
                "a retained Low Power prior started a fresh read on every pass")

        daemon.lowPower(true)
        daemon.drain()
        #expect(mac.lowPower.battery == true, "the second Low Power apply never took")

        daemon.release()
        daemon.drain()

        #expect(mac.sleepDisabled == 0,
                "End was skipped because a Low Power restore had cached this label")
        #expect(mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "Low Power Mode was left on because an earlier restore had cached this label")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false,
                "the inherited evidence was destroyed on the way out")
    }

    /// A restore is a privileged write too.
    ///
    /// It used to be exempt, on the grounds that it writes a setting *back*.
    /// "Back" is the old transaction's target, not the setting a later
    /// session or user should have — so an undo that arrives late can
    /// overwrite a newer preference, and its record is one a peer can delete
    /// in the meantime.
    @Test("The record that admits a Low Power restore already says a writer is outstanding")
    func lowPowerRestoreAdmissionIsDurable() {
        let mac = FakeMac()
        let file = ClaimFile()
        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: TestClock(), file: file, mac: mac)
        daemon.start()
        daemon.hold()
        daemon.lowPower(true)
        daemon.drain()

        let atAdmission = Recorded()
        daemon.pmset.onStart = {
            if case .writeLowPowerMode(let on, _) = daemon.pmset.started.last?.command,
               on == false, atAdmission.value == nil {
                atAdmission.set(file.ledger?.claims["com.egemert.ledge.keepawake"])
            }
        }

        daemon.lowPower(false)
        daemon.drain()

        #expect(atAdmission.value != nil, "the fixture never admitted a Low Power restore")
        #expect(atAdmission.value??.mayBeRemoved == false,
                "a restore was admitted over a record that said nothing about it")
        #expect(atAdmission.value??.lowPowerPrior != nil,
                "the prior it was restoring to was not there to protect")
    }

    /// A Low Power write waits for a disk that will take its record.
    ///
    /// The sleep setting is the one exception — a Mac waiting to be allowed
    /// to sleep must not be held up by one field — and Low Power Mode is not
    /// that. It is a saving, not a promise the user is relying on second by
    /// second, so it waits rather than putting out a writer no peer can know
    /// to wait for.
    @Test("A Low Power restore waits for a journal that will take it")
    func lowPowerRestoreWaitsForItsRecord() {
        let mac = FakeMac()
        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: TestClock(), file: ClaimFile(), mac: mac)
        daemon.start()
        daemon.hold()
        daemon.lowPower(true)
        daemon.drain()
        #expect(mac.lowPower.battery == true, "the fixture never turned it on")

        daemon.store.file.saveFailures = 99
        daemon.lowPower(false)
        daemon.drain()
        #expect(mac.lowPower.battery == true,
                "a Low Power writer went out with nothing on disk saying so")

        // And it goes through once the disk will take it.
        daemon.store.file.saveFailures = 0
        daemon.advance(60)
        daemon.drain()
        #expect(mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "the restore never happened once the disk recovered")
    }

    /// The other build holding the *sleep* setting says they hold the Mac. It
    /// does not say they have taken on somebody else's Low Power undo — and
    /// the prior is the only thing that knows how to put it back.
    @Test("Another build taking the Mac does not delete a protected Low Power prior")
    func ownershipTransferKeepsAProtectedPrior() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let a = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        a.start()
        a.hold()
        a.lowPower(true)
        a.drain()
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.lowPowerPrior != nil,
                "the fixture never journalled a prior")

        // One of A's writes is answered for while its child can still act.
        a.core.noticeLiveWriter(opID: 8191)
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.mayBeRemoved == false,
                "the fixture never protected the record")

        // The other build takes the Mac.
        clock.advance(91)
        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        b.start()
        b.drain()
        b.hold()
        b.drain()

        // A keeps trying, and meets the other build holding the Mac.
        a.core.tick()
        a.drain()

        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.lowPowerPrior != nil,
                "a protected prior was handed over to a build that never took it on")
    }

    /// A restore made on somebody else's behalf publishes on *their* record.
    ///
    /// The obligation this write is acting on is the foreign one. Attaching
    /// the uncertainty to our own claim — which on this path does not exist —
    /// left the only account of what the user had looking like an ordinary
    /// removable prior to every peer, while the writer that could still move
    /// the setting was ours.
    @Test("Restoring a peer's record says so on the peer's record")
    func foreignRestorePublishesOnTheForeignRecord() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": HelperClaim(
                holderLabel: "com.egemert.ledge.keepawake", boot: "boot-1",
                sessionID: "S0", generation: 1, deadline: nil,
                leaseExpiryContinuousNs: 0, sleepDisabledClaimed: false,
                lowPowerPrior: 0)
        ])
        mac.lowPower = LowPowerSetting(battery: true, charger: true)

        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        let atAdmission = Recorded()
        b.pmset.onStart = {
            if b.pmset.started.last?.command.isWrite == true,
               b.pmset.started.last?.command.isLowPower == true,
               atAdmission.value == nil {
                atAdmission.set(file.ledger?.claims["com.egemert.ledge.keepawake"])
            }
        }
        b.start()
        b.drain()

        #expect(atAdmission.value != nil, "the fixture never restored on anybody's behalf")
        #expect(atAdmission.value??.mayBeRemoved == false,
                "a foreign obligation was acted on with nothing on its record saying so")
        #expect(mac.lowPower == LowPowerSetting(battery: false, charger: false),
                "the peer's prior was never put back")
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"] == nil,
                "the record outlived the restore that discharged it")
    }

    /// Inherited uncertainty, and nothing of this run's own to notice it.
    ///
    /// The transfer branch deleted the prior outright. A record carrying
    /// somebody else's unaccounted-for writer is not this run's to hand over,
    /// whoever has taken the Mac.
    @Test("Ownership transfer does not delete an inherited protected prior")
    func ownershipTransferKeepsAnInheritedPrior() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        file.ledger = ClaimLedger(claims: [
            "com.egemert.ledge.keepawake": HelperClaim(
                holderLabel: "com.egemert.ledge.keepawake", boot: "boot-1",
                sessionID: "S0", generation: 1, deadline: nil,
                leaseExpiryContinuousNs: 0, sleepDisabledClaimed: false,
                lowPowerPrior: 0, writers: [WriterMark(run: "a-dead-run", boot: "boot-1")])
        ])
        mac.lowPower = LowPowerSetting(battery: true, charger: true)

        // The other build already has the Mac when this one starts, so the
        // first thing its Low Power restore meets is the handover.
        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        b.start()
        b.hold()
        b.drain()

        let a = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        a.start()
        a.drain()

        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.lowPowerPrior != nil,
                "a prior protected by somebody else's writer was handed over")
    }

    /// A peer's retained prior must not turn every pump into another read.
    ///
    /// The apply redirects into a restore whenever somebody else's prior is
    /// outstanding. When that prior is one this run has already put back and
    /// may not remove, the restore finishes with nothing to do and the next
    /// pass makes the same decision — a `pmset` read on every pump, while the
    /// setting the user asked for is never applied.
    @Test("A peer's retained Low Power prior does not loop the reads")
    func retainedForeignPriorDoesNotLoop() {
        let clock = TestClock()
        let mac = FakeMac()
        let file = ClaimFile()
        let a = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        a.start()
        a.hold()
        a.lowPower(true)
        a.drain()
        a.core.noticeLiveWriter(opID: 404)
        clock.advance(91)

        let b = Daemon(label: "com.egemert.ledge.keepawake.debug", boot: "boot-1",
                       clock: clock, file: file, mac: mac)
        b.start()
        b.drain()
        b.hold()
        b.drain()
        #expect(file.ledger?.claims["com.egemert.ledge.keepawake"]?.lowPowerPrior != nil,
                "B deleted a prior whose writer had not stopped")

        b.lowPower(true)
        b.drain()

        let settled = b.pmset.started.count
        for _ in 0..<20 { b.core.tick(); b.drain() }
        #expect(b.pmset.started.count == settled,
                "a peer's retained prior started a fresh read on every pass")
    }

    /// A reading taken before a late writer landed is not evidence of
    /// anything — including when it says there is nothing to do.
    ///
    /// The no-write shortcut stamps a *fresh* verification time onto the
    /// reading, so believing a stale one does not merely cache a wrong answer:
    /// it undoes the invalidation this core had already made for itself, and
    /// then stops looking for another half minute.
    @Test("A stale already-on reading does not mark Low Power Mode applied")
    func staleAlreadyOnReadingIsNotBelieved() {
        let mac = FakeMac()
        let clock = TestClock()
        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: clock, file: ClaimFile(), mac: mac)
        daemon.start()
        daemon.hold()
        daemon.lowPower(true)
        daemon.drain()

        // The periodic look comes round, and its answer is held.
        clock.advance(31)
        daemon.mac.hangs = true
        daemon.core.tick()
        // The sleep setting's own periodic look may come first; walk past it.
        var railing = 0
        while daemon.pmset.outstanding != nil,
              daemon.pmset.outstanding?.command.isLowPower != true {
            railing += 1
            if railing > 10 { break }
            daemon.answerOne()
        }
        guard daemon.pmset.outstanding?.command.isLowPower == true else {
            Issue.record("the fixture never issued the periodic Low Power read")
            return
        }

        // While it is out, a writer this helper had given up on finishes — and
        // the setting is not where the held reading says it is.
        daemon.core.noticeLateWrite(opID: 4242)
        mac.lowPower = LowPowerSetting(battery: false, charger: false)

        // The held answer arrives, describing a Mac that has since moved.
        daemon.answerOne()
        daemon.mac.hangs = false
        daemon.drain()

        #expect(mac.lowPower.battery == true,
                "a reading taken before a late write landed was believed and cached")
    }

    /// A hold is only as good as its last look, for both settings.
    ///
    /// The sleep setting re-reads every heartbeat on the reasoning that a
    /// counter in this process cannot see anybody else's writes. Low Power
    /// Mode believed itself applied and never looked again — so another
    /// helper's late writer, the other build, or a Terminal window turned it
    /// off and this hold went on reporting it on for the rest of the session.
    @Test("A Low Power hold looks at the setting again on the same cadence")
    func lowPowerIsReVerified() {
        let mac = FakeMac()
        let clock = TestClock()
        let daemon = Daemon(label: "com.egemert.ledge.keepawake", boot: "boot-1",
                            clock: clock, file: ClaimFile(), mac: mac)
        daemon.start()
        daemon.hold()
        daemon.lowPower(true)
        daemon.drain()
        #expect(mac.lowPower.battery == true, "the fixture never turned it on")

        // Nothing is due yet.
        let settled = daemon.pmset.started.count
        daemon.core.tick()
        daemon.drain()
        #expect(daemon.pmset.started.count == settled,
                "a settled Low Power hold did work for no reason")

        // Somebody else turns it off, and this helper is told nothing.
        mac.lowPower = LowPowerSetting(battery: false, charger: false)
        clock.advance(31)
        daemon.core.tick()
        daemon.drain()

        #expect(mac.lowPower.battery == true,
                "a hold went on believing a setting nobody had looked at")
    }

    /// Somewhere an observer can leave what it saw.
    final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: HelperClaim??
        func set(_ value: HelperClaim?) { lock.withLock { stored = value } }
        var value: HelperClaim?? { lock.withLock { stored } }
    }

}

@Suite("Low Power Mode, per power source")
struct LowPowerSettingTests {

    private let both = LowPowerSetting(battery: false, charger: false)

    @Test("The four states survive a round trip through the claim's one Int")
    func packing() {
        for battery in [false, true] {
            for charger in [false, true] {
                let setting = LowPowerSetting(battery: battery, charger: charger)
                #expect(LowPowerSetting.unpacked(setting.packed) == setting)
            }
        }
    }

    /// Absent is not off. A desktop has no battery, and writing to one is a
    /// write that cannot land.
    @Test("A source this Mac does not have is not a disagreement")
    func absentSourceMatches() {
        let desktop = LowPowerSetting(battery: nil, charger: true)
        #expect(desktop.matches(LowPowerSetting(battery: true, charger: true)))
        #expect(desktop.matches(LowPowerSetting(battery: false, charger: true)))
        #expect(!desktop.matches(LowPowerSetting(battery: false, charger: false)))
    }

    @Test("Already right is no writes at all")
    func noWritesWhenItMatches() {
        #expect(both.writes(to: both).isEmpty)
    }

    @Test("Both sources wanting the same answer is one write, not two")
    func oneWriteWhenTheyAgree() {
        #expect(both.writes(to: LowPowerSetting(battery: true, charger: true))
                == [.writeLowPowerMode(on: true, source: .all)])
    }

    @Test("Only on Battery takes a write each, in a fixed order")
    func twoWritesWhenTheyDiffer() {
        let on = LowPowerSetting(battery: true, charger: true)
        #expect(on.writes(to: LowPowerSetting(battery: true, charger: false))
                == [.writeLowPowerMode(on: true, source: .battery),
                    .writeLowPowerMode(on: false, source: .charger)])
    }

    @Test("A Mac with one source is only ever written with -a")
    func singleSourceUsesAll() {
        let desktop = LowPowerSetting(battery: nil, charger: false)
        #expect(desktop.writes(to: LowPowerSetting(battery: true, charger: true))
                == [.writeLowPowerMode(on: true, source: .all)])
        let noCharger = LowPowerSetting(battery: false, charger: nil)
        #expect(noCharger.writes(to: LowPowerSetting(battery: true, charger: false))
                == [.writeLowPowerMode(on: true, source: .all)])
    }

    @Test("Merging two priors keeps whichever wanted it on")
    func mergingPrefersOn() {
        let off = LowPowerSetting(battery: false, charger: false)
        let batteryOnly = LowPowerSetting(battery: true, charger: false)
        #expect(off.merged(with: batteryOnly) == batteryOnly)
        #expect(batteryOnly.merged(with: off) == batteryOnly)
        #expect(off.merged(with: off) == off)
    }

    @Test("Turning it on names only the sources this Mac has")
    func turnedOnKeepsAbsentSourcesAbsent() {
        #expect(LowPowerSetting(battery: nil, charger: false).turnedOn
                == LowPowerSetting(battery: nil, charger: true))
    }
}
