import Foundation
import Testing

@testable import LedgeHelperKit

/// Two daemons, one Mac.
///
/// The debug and release builds of Ledge each install their own daemon, and
/// both change the same machine-wide setting. The store they share is the only
/// way either can know that, and the lease in it is the only way to tell a
/// daemon that is holding from one that has died holding.
@Suite("The debug build and the release build at the same time")
struct HelperCoreSharedMacTests {

    private let release = "com.egemert.ledge.keepawake"
    private let debug = "com.egemert.ledge.debug.keepawake"

    private func pair() -> (Daemon, Daemon, TestClock, FakeMac) {
        let clock = TestClock()
        let file = ClaimFile()
        let mac = FakeMac()
        let first = Daemon(label: release, boot: "boot-1", clock: clock, file: file, mac: mac)
        let second = Daemon(label: debug, boot: "boot-1", clock: clock, file: file, mac: mac)
        return (first, second, clock, mac)
    }

    @Test("A live claim by the other build is respected, not taken over")
    func liveClaimRespected() {
        let (first, second, _, mac) = pair()
        first.start()
        second.start()

        #expect(first.hold(session: Daemon.sessionA).last == .ok)
        #expect(mac.sleepDisabled == 1)

        let answer = second.hold(session: Daemon.sessionB)

        #expect(answer.last == .inUseByOtherLedge)
        #expect(second.status.otherLedgeHolds)
        #expect(!second.pmset.commands.contains(.writeSleepDisabled(true)))
        #expect(!second.pmset.commands.contains(.writeSleepDisabled(false)),
                "and above all it does not put back a setting somebody is using")
        #expect(mac.sleepDisabled == 1)
    }

    @Test("A daemon starting up leaves the other build's live hold alone")
    func startupRespectsALiveClaim() {
        let (first, second, _, mac) = pair()
        first.start()
        first.hold()
        #expect(mac.sleepDisabled == 1)

        second.start()

        #expect(mac.sleepDisabled == 1)
        #expect(second.status.otherLedgeHolds)
        #expect(second.pmset.commands == [.readSleepDisabled])
    }

    @Test("The second build can arm once the first has let go")
    func takesOverAfterARelease() {
        let (first, second, _, mac) = pair()
        first.start()
        second.start()
        first.hold(session: Daemon.sessionA)
        #expect(second.hold(session: Daemon.sessionB).last == .inUseByOtherLedge)

        first.release(session: Daemon.sessionA)
        #expect(mac.sleepDisabled == 0)

        #expect(second.hold(session: Daemon.sessionB, generation: 2).last == .ok)
        #expect(mac.sleepDisabled == 1)
    }

    @Test("Over several heartbeats the other build never mistakes a live lease for a dead one")
    func leaseIsReadableAcrossDaemons() {
        let (first, second, clock, mac) = pair()
        first.start()
        second.start()
        first.hold(session: Daemon.sessionA, generation: 1, lease: 90)

        for beat in 1...6 {
            clock.advance(30)
            first.core.tick()
            first.drain()
            #expect(first.hold(session: Daemon.sessionA, generation: 1, lease: 90).last == .ok)

            second.core.tick()
            second.drain()
            #expect(second.hold(session: Daemon.sessionB, generation: beat).last
                    == .inUseByOtherLedge, "beat \(beat)")
            #expect(mac.sleepDisabled == 1, "beat \(beat)")
        }
    }

    @Test("The other build's lapsed claim is put back on its behalf")
    func restoresOnBehalfOfALapsedDaemon() {
        let (first, second, clock, mac) = pair()
        first.start()
        second.start()
        first.hold(session: Daemon.sessionA, lease: 90)
        #expect(mac.sleepDisabled == 1)

        // The first daemon is killed here: it renews nothing and never runs
        // again. Nothing it holds can be undone by it.
        clock.advance(91)

        // The second one is asked for a hold of its own. It finds a claim
        // whose lease ran out, puts the setting back for its owner, and only
        // then takes it.
        #expect(second.hold(session: Daemon.sessionB).last == .ok)
        #expect(second.log.contains("lapsed claim"))
        #expect(mac.sleepDisabled == 1)
        #expect(second.claim?.sleepDisabledClaimed == true)
        #expect(second.store.file.ledger?.claims[release] == nil,
                "the dead daemon's claim is gone, not written over")
    }

    @Test("A daemon starting next to a lapsed claim puts the setting back")
    func startupRestoresALapsedClaim() {
        let clock = TestClock()
        let file = ClaimFile()
        let mac = FakeMac()
        mac.sleepDisabled = 1
        file.ledger = ClaimLedger(claims: [
            release: claim(label: release, leaseExpiryNs: clock.continuousNanoseconds - 1)
        ])

        let second = Daemon(label: debug, boot: "boot-1", clock: clock, file: file, mac: mac)
        second.start()

        #expect(mac.sleepDisabled == 0)
        #expect(file.ledger?.claims.isEmpty == true)
        #expect(second.log.contains("on behalf of"))
        #expect(second.status.clean)
    }

    @Test("The lock is held across the child, so the other daemon cannot act in between")
    func lockCoversTheWholeTransaction() {
        let (first, second, _, mac) = pair()
        first.start()
        second.start()

        first.mac.hangs = true
        first.hold(session: Daemon.sessionA)     // the apply's read is out, lock held
        #expect(first.store.file.lockedBy == first.label)

        // The second daemon wants the store and cannot have it. It waits
        // rather than acting on a half-finished transaction, and it does not
        // block doing so.
        let waiting = second.hold(session: Daemon.sessionB)
        #expect(waiting.count == 0)
        #expect(second.pmset.commands == [.readSleepDisabled], "only its own start's read")

        first.mac.hangs = false
        first.drain()
        #expect(first.store.file.lockedBy == nil)
        #expect(mac.sleepDisabled == 1)

        second.core.tick()
        second.drain()
        #expect(waiting.last == .inUseByOtherLedge)
    }

    @Test("A renewal that finds the lock held tries again, and still lands in time")
    func renewalRetriesTheLock() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(generation: 1, lease: 90)

        daemon.advance(30)
        // The other build's daemon is mid-transaction: it has the lock, and it
        // keeps it until its `pmset` child has exited.
        daemon.store.file.lockedBy = "the other daemon"

        let renewal = daemon.hold(generation: 1, lease: 90)
        #expect(renewal.count == 0, "it is waiting for the lock, not failing")
        #expect(daemon.timer.last ?? nil == HelperLimits.lockBackoffNs[0])

        // Waiting is a timer, not a blocked queue: everything else the daemon
        // has to do carries on in between.
        daemon.clock.advance(0.25)
        daemon.core.tick()
        #expect(renewal.count == 0)
        #expect(daemon.timer.last ?? nil == HelperLimits.lockBackoffNs[1])

        daemon.store.file.lockedBy = nil
        daemon.advance(1)
        #expect(renewal.last == .ok)

        // The renewal landed late but in time: 90 s from when it was written,
        // not from when it was asked for.
        daemon.advance(89)
        #expect(daemon.mac.sleepDisabled == 1)
        daemon.advance(2)
        #expect(daemon.mac.sleepDisabled == 0)
    }
}
