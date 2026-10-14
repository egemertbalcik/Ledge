import Foundation
import Testing

@testable import LedgeHelperKit

/// What the daemon does when the parts it depends on say no.
///
/// The asymmetry is deliberate and is the safety rule of the whole feature:
/// taking the setting is conditional on everything working, and putting it
/// back is conditional on nothing.
@Suite("When pmset or the disk says no")
struct HelperCoreFailureTests {

    @Test("A restore that fails keeps the claim and keeps trying")
    func restoreRetries() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(lease: 90)
        #expect(daemon.mac.sleepDisabled == 1)

        daemon.mac.refuseWrites = 3
        daemon.advance(91)          // the lease lapses and the restore begins

        #expect(daemon.mac.sleepDisabled == 1, "pmset refused")
        #expect(daemon.claim?.sleepDisabledClaimed == true, "so the claim stays")
        #expect(!daemon.status.clean, "and the helper may not be unregistered")
        #expect(daemon.status.cleanupPending)
        #expect(daemon.timer.last ?? nil == HelperLimits.retryBackoffNs[0])

        daemon.advance(5)
        #expect(daemon.timer.last ?? nil == HelperLimits.retryBackoffNs[1])
        daemon.advance(15)
        #expect(daemon.timer.last ?? nil == HelperLimits.retryBackoffNs[2])

        daemon.advance(60)          // this one is allowed through
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.claim == nil)
        #expect(daemon.status.clean)
    }

    @Test("The backoff settles at five minutes rather than growing without end")
    func backoffCeiling() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(lease: 90)
        daemon.mac.refuseWrites = 99
        daemon.advance(91)

        for _ in 0..<6 { daemon.advance(301) }

        #expect(daemon.timer.last ?? nil == HelperLimits.retryBackoffNs.last)
        #expect(!daemon.status.clean)
    }

    @Test("A readback that disagrees is treated as a failure, not as success")
    func readbackDisagrees() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(lease: 90)

        // `pmset` exits 0 and nothing changes. Without the readback this is
        // indistinguishable from the setting having been put back.
        daemon.mac.ignoreWrites = true
        daemon.advance(91)

        #expect(daemon.mac.sleepDisabled == 1)
        #expect(daemon.claim?.sleepDisabledClaimed == true)
        #expect(!daemon.status.clean)

        daemon.mac.ignoreWrites = false
        daemon.advance(5)
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.status.clean)
    }

    @Test("A claim that cannot be journalled is a claim that is not acted on")
    func journalFailureStopsTheApply() {
        let daemon = Daemon()
        daemon.start()
        daemon.mac.hangs = true
        daemon.hold(lease: 90)              // the renewal lands; the apply's read is out

        // The disk refuses the claim that has to be written before `pmset`
        // runs. This is the asymmetry the whole design rests on: the record
        // comes first, so a Mac can never be left unable to sleep with nothing
        // on disk saying who did it.
        daemon.store.file.saveFailures = 1
        daemon.answerOne()                  // the read says 0

        #expect(!daemon.pmset.commands.contains(.writeSleepDisabled(true)))
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.claim?.sleepDisabledClaimed != true)
    }

    @Test("A renewal the disk refuses is answered as such, and acted on not at all")
    func renewalFailureChangesNothing() {
        let daemon = Daemon()
        daemon.start()
        daemon.store.file.saveFailures = 1

        #expect(daemon.hold(lease: 90).last == .persistFailed)
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.claim == nil)
    }

    @Test("An apply whose write fails leaves a claim behind, and the claim is honoured")
    func applyFailureLeavesAClaim() {
        let daemon = Daemon()
        daemon.start()
        daemon.mac.refuseWrites = 1

        daemon.hold(lease: 90)

        // Whether the write landed is not knowable from here, so the claim
        // written before it is what the next pass goes on.
        #expect(daemon.claim?.sleepDisabledClaimed == true)
        #expect(!daemon.status.clean)

        daemon.release()
        daemon.advance(1)
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.claim == nil)
        #expect(daemon.status.clean)
    }

    @Test("A release is not delayed by a backoff the apply was serving")
    func releaseJumpsTheBackoff() {
        let daemon = Daemon()
        daemon.start()
        daemon.mac.refuseWrites = 1
        daemon.hold(lease: 90)       // fails, and schedules a 5 s retry

        daemon.release()
        daemon.advance(1)            // well inside the retry's own backoff

        #expect(daemon.status.clean, "the user let go; the Mac must be free to sleep now")
    }

    @Test("The store refusing to record a restore is retried, not forgotten")
    func clearFailureRetries() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(lease: 90)

        // Every save refused, rather than a counted one: a restore journals
        // that a writer of its own is outstanding before it writes anything,
        // so counting which refusal lands where would be a test of the
        // sequence rather than of the rule. The rule is that the setting goes
        // back whatever the disk says and the record does not.
        daemon.core.tick()
        daemon.drain()
        daemon.store.file.saveFailures = 99
        daemon.advance(91)

        #expect(daemon.mac.sleepDisabled == 0, "the setting is put back whatever the disk says")
        #expect(!daemon.status.clean, "but the record of it has not been cleared")

        daemon.store.file.saveFailures = 0
        daemon.advance(5)
        #expect(daemon.claim == nil)
        #expect(daemon.status.clean)
    }
}
