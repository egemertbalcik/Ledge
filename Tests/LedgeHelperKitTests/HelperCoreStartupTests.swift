import Foundation
import Testing

@testable import LedgeHelperKit

/// What a daemon does about whatever it finds when it starts.
///
/// This is where the whole safety story is settled for the cases nobody was
/// watching: a Mac that was restarted, a daemon that was killed mid-operation,
/// a user who turned the setting off themselves.
@Suite("The daemon's first look at the Mac")
struct HelperCoreStartupTests {

    private let ours = "com.egemert.ledge.keepawake"
    private let theirs = "com.egemert.ledge.debug.keepawake"

    @Test("A claim from an earlier boot is undone, however live its lease looks")
    func previousBoot() {
        let daemon = Daemon(label: ours, boot: "boot-1")
        daemon.mac.sleepDisabled = 1
        // The other build's label and a lease that has not expired by its own
        // numbers: only the boot id says this is nobody's claim. Continuous
        // time restarted, so the number is not comparable with anything.
        daemon.store.file.ledger = ClaimLedger(claims: [
            theirs: claim(label: theirs, boot: "boot-0", leaseExpiryNs: .max)
        ])

        daemon.start()

        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.store.file.ledger?.claims.isEmpty == true)
        #expect(daemon.status.clean)
        #expect(daemon.log.contains("on behalf of"))
    }

    @Test("Our own hold never survives a restart of our own daemon")
    func ownClaimNeverSurvives() {
        let daemon = Daemon(label: ours)
        daemon.mac.sleepDisabled = 1
        daemon.store.file.ledger = ClaimLedger(claims: [
            ours: claim(label: ours, leaseExpiryNs: .max)
        ])

        daemon.start()

        // The app's next heartbeat takes a new hold with a new generation. An
        // inherited hold would be a hold nobody in this process ever asked for.
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.claim == nil)
        #expect(daemon.status.clean)
    }

    @Test("A claim journalled just before a crash costs nothing to undo")
    func crashedBetweenJournalAndAction() {
        // The daemon wrote the claim, then died before `pmset` ran: the record
        // describes a change that never happened.
        let daemon = Daemon(label: ours)
        daemon.mac.sleepDisabled = 0
        daemon.store.file.ledger = ClaimLedger(claims: [
            ours: claim(label: ours, leaseExpiryNs: .max)
        ])

        daemon.start()

        #expect(daemon.pmset.commands == [.readSleepDisabled],
                "with the setting already at 0 there is nothing to write")
        #expect(daemon.claim == nil)
        #expect(daemon.status.clean)
    }

    @Test("A claim whose write did land is undone")
    func crashedAfterTheWrite() {
        let daemon = Daemon(label: ours)
        daemon.mac.sleepDisabled = 1
        daemon.store.file.ledger = ClaimLedger(claims: [
            ours: claim(label: ours, leaseExpiryNs: .max)
        ])

        daemon.start()

        #expect(daemon.pmset.commands == [.readSleepDisabled, .writeSleepDisabled(false),
                                          .readSleepDisabled])
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.status.clean)
    }

    @Test("A lease with nothing behind it is dropped without running anything")
    func leaseWithoutAChange() {
        let daemon = Daemon(label: ours)
        daemon.store.file.ledger = ClaimLedger(claims: [
            ours: claim(label: ours, boot: "boot-0", leaseExpiryNs: .max,
                        sleepDisabledClaimed: false)
        ])

        daemon.start()

        #expect(daemon.pmset.commands == [.readSleepDisabled])
        #expect(daemon.store.file.ledger?.claims.isEmpty == true)
    }

    @Test("Sleep disabled by somebody else is left exactly as it is")
    func foreignSetting() {
        let daemon = Daemon(label: ours)
        daemon.mac.sleepDisabled = 1   // `sudo pmset -a disablesleep 1`, by hand

        daemon.start()

        #expect(daemon.pmset.commands == [.readSleepDisabled], "nothing is written")
        #expect(daemon.mac.sleepDisabled == 1)
        #expect(daemon.status.ours == false)
        // Clean means no claim of ours, not SleepDisabled == 0. Refusing to be
        // clean here would keep the daemon installed forever over a setting
        // that was never Ledge's.
        #expect(daemon.status.clean)
    }

    @Test("A hold is refused while the setting belongs to somebody else")
    func holdRefusedWhileForeign() {
        let daemon = Daemon(label: ours)
        daemon.mac.sleepDisabled = 1
        daemon.start()

        let answer = daemon.hold()

        #expect(answer.last == .foreign)
        #expect(daemon.mac.sleepDisabled == 1)
        #expect(!daemon.pmset.commands.contains(.writeSleepDisabled(true)))
    }

    @Test("A foreign setting is looked at again, and taken once it is given up")
    func foreignClears() {
        let daemon = Daemon(label: ours)
        daemon.mac.sleepDisabled = 1
        daemon.start()
        daemon.hold()

        // The user ran `sudo pmset -a disablesleep 0` themselves.
        daemon.mac.sleepDisabled = 0
        daemon.advance(5)

        #expect(daemon.mac.sleepDisabled == 1, "the hold the app asked for is taken")
        #expect(daemon.claim?.sleepDisabledClaimed == true)
    }

    @Test("A store that cannot be read is set aside, never deleted")
    func unreadableStore() {
        let daemon = Daemon(label: ours)
        let existing = ClaimLedger(claims: [ours: claim(label: ours, leaseExpiryNs: .max)])
        daemon.store.file.ledger = existing
        daemon.store.file.corrupt = true
        daemon.mac.sleepDisabled = 1

        daemon.start()

        #expect(daemon.store.file.setAside.count == 1)
        #expect(daemon.store.file.setAside.first ?? nil == existing,
                "whatever it said is kept; somebody may want to know")
        // Ownership of the setting is now unknown, and unknown is not ours.
        #expect(daemon.mac.sleepDisabled == 1)
        #expect(daemon.pmset.commands == [.readSleepDisabled])
    }

    @Test("A daemon that cannot read the setting keeps trying rather than guessing")
    func unreadableSetting() {
        let daemon = Daemon(label: ours)
        daemon.mac.sleepDisabled = 1
        daemon.store.file.ledger = ClaimLedger(claims: [
            ours: claim(label: ours, leaseExpiryNs: .max)
        ])
        daemon.mac.refuseReads = 1

        daemon.start()

        #expect(daemon.claim != nil, "the claim stays until a restore is read back")
        #expect(!daemon.status.clean)
        #expect(daemon.status.cleanupPending)
        #expect(daemon.timer.last ?? nil == HelperLimits.retryBackoffNs[0])

        daemon.advance(5)
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.status.clean)
    }
}
