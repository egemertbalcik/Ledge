import Foundation
import Testing

@testable import LedgeHelperKit

/// The lease, which is the whole reason a root daemon is safe to ship.
///
/// A power assertion cannot hold a Mac awake with the lid shut, so this one
/// thing has to run as root — and a root process that disabled sleep and then
/// lost contact with the app that asked for it would leave somebody's Mac
/// unable to sleep in a bag. The lease is the answer: the hold is rented, not
/// given, and the rent is due every 30 s.
@Suite("The lease")
struct HelperCoreLeaseTests {

    @Test("The hold lapses 90 s after the last heartbeat, and the Mac can sleep again")
    func leaseExpiresWhenTheAppIsGone() {
        let daemon = Daemon()
        daemon.start()
        #expect(daemon.hold(lease: 90).last == .ok)
        #expect(daemon.mac.sleepDisabled == 1)

        // Ledge was killed here. Nothing renews.
        daemon.advance(89)
        #expect(daemon.mac.sleepDisabled == 1, "the lease has not run out yet")

        daemon.advance(2)
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.claim == nil)
        #expect(daemon.status.clean)
    }

    @Test("A heartbeat moves the lease along")
    func renewal() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(lease: 90)

        for _ in 0..<5 {
            daemon.advance(30)
            #expect(daemon.hold(lease: 90).last == .ok)
            #expect(daemon.mac.sleepDisabled == 1)
        }

        daemon.advance(91)
        #expect(daemon.mac.sleepDisabled == 0)
    }

    @Test("A heartbeat that arrives after the lapse needs a new generation")
    func heartbeatAfterExpiry() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(generation: 1, lease: 90)
        daemon.advance(91)
        #expect(daemon.mac.sleepDisabled == 0)

        // The app did not notice and heartbeats as if nothing happened. The
        // daemon will not quietly start holding this Mac again on the strength
        // of a message that was in flight when the hold ended.
        #expect(daemon.hold(generation: 1, lease: 90).last == .stale)
        #expect(daemon.mac.sleepDisabled == 0)

        // Noticing and asking again is a different thing, and is allowed.
        #expect(daemon.hold(generation: 2, lease: 90).last == .ok)
        #expect(daemon.mac.sleepDisabled == 1)
    }

    @Test("The wall clock moving does not lengthen or shorten the lease")
    func wallClockSteps() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(lease: 90)

        daemon.clock.stepWallClock(by: -3_600)
        daemon.core.tick()
        daemon.drain()
        #expect(daemon.mac.sleepDisabled == 1, "an hour backwards is not a renewal")

        daemon.clock.stepWallClock(by: 7_200)
        daemon.core.tick()
        daemon.drain()
        #expect(daemon.mac.sleepDisabled == 1, "two hours forwards does not end it either")

        daemon.advance(91)
        #expect(daemon.mac.sleepDisabled == 0, "only real time does")
    }

    @Test("Time asleep counts against the lease")
    func sleepCounts() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(lease: 90)

        // The Mac slept for ten minutes. Nothing in Ledge ran, so nothing
        // renewed, and the clock the lease is measured on kept counting.
        daemon.clock.sleep(600)
        daemon.core.tick()
        daemon.drain()

        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.status.clean)
    }

    @Test("A renewal is on disk before it is answered")
    func renewalPersistedFirst() {
        let daemon = Daemon()
        daemon.start()
        daemon.store.file.saveFailures = 1

        let answer = daemon.hold(lease: 90)

        #expect(answer.last == .persistFailed)
        #expect(daemon.claim == nil, "nothing was written")
        #expect(daemon.mac.sleepDisabled == 0, "and nothing privileged was done")
        #expect(daemon.pmset.commands == [.readSleepDisabled], "only the start's own read")
    }

    @Test("A refused renewal leaves the lease where the disk last had it")
    func refusedRenewalDoesNotExtend() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(lease: 90)          // persisted: expires at t + 90

        daemon.advance(30)
        daemon.store.file.saveFailures = 1
        #expect(daemon.hold(lease: 90).last == .persistFailed)

        // Had the refused renewal counted, the hold would run to t + 120.
        daemon.advance(61)
        #expect(daemon.mac.sleepDisabled == 0)
    }

    @Test("The lease a client asks for is clamped at both ends")
    func leaseClamping() {
        let daemon = Daemon()
        daemon.start()
        let start = daemon.clock.continuousNanoseconds

        daemon.hold(session: Daemon.sessionA, generation: 1, lease: 1)
        #expect(daemon.claim?.leaseExpiryContinuousNs == start + 30_000_000_000,
                "a lease short enough for a hiccup to drop the hold is raised to 30 s")

        daemon.hold(session: Daemon.sessionA, generation: 2, lease: 9_999)
        #expect(daemon.claim?.leaseExpiryContinuousNs == start + 120_000_000_000,
                "and one long enough to strand a Mac is cut to 120 s")
    }
}

/// The deadline: the other bound, and the one the user chose.
@Suite("The deadline")
struct HelperCoreDeadlineTests {

    @Test("The hold ends at the deadline even while the heartbeats keep coming")
    func deadlineEndsItFirst() {
        let daemon = Daemon()
        daemon.start()
        let deadline = daemon.clock.now.addingTimeInterval(60)
        #expect(daemon.hold(deadline: deadline, lease: 90).last == .ok)

        daemon.advance(30)
        daemon.hold(deadline: deadline, lease: 90)   // the lease now runs to t + 120
        #expect(daemon.mac.sleepDisabled == 1)

        daemon.advance(31)
        #expect(daemon.mac.sleepDisabled == 0, "the deadline is the earlier of the two bounds")
        #expect(daemon.status.clean)
    }

    @Test("The lease ends a hold whose deadline is further away")
    func leaseEndsItFirst() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(deadline: daemon.clock.now.addingTimeInterval(3_600), lease: 90)

        daemon.advance(91)
        #expect(daemon.mac.sleepDisabled == 0, "an hour was asked for; nobody stayed to ask again")
    }

    @Test("A session's deadline is fixed by its first hold and cannot be pushed out")
    func deadlineCannotBeExtended() {
        let daemon = Daemon()
        daemon.start()
        let deadline = daemon.clock.now.addingTimeInterval(60)
        daemon.hold(generation: 1, deadline: deadline, lease: 90)

        // The case this exists for is a heartbeat bug that keeps moving the
        // end of a session the user already fixed. The lease cannot catch
        // that, because the heartbeats are arriving.
        let answer = daemon.hold(generation: 2, deadline: deadline.addingTimeInterval(600),
                                 lease: 90)
        #expect(answer.last == .invalidArgument)
        #expect(daemon.claim?.deadline == deadline)
    }

    @Test("Turning a deadline into an indefinite hold is refused too")
    func indefiniteIsAnExtension() {
        let daemon = Daemon()
        daemon.start()
        let deadline = daemon.clock.now.addingTimeInterval(60)
        daemon.hold(generation: 1, deadline: deadline, lease: 90)

        #expect(daemon.hold(generation: 2, deadline: nil, lease: 90).last == .invalidArgument)
        #expect(daemon.claim?.deadline == deadline)
    }

    @Test("A deadline may be brought forward")
    func deadlineMayShrink() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(generation: 1, deadline: daemon.clock.now.addingTimeInterval(600), lease: 90)

        let sooner = daemon.clock.now.addingTimeInterval(30)
        #expect(daemon.hold(generation: 2, deadline: sooner, lease: 90).last == .ok)

        daemon.advance(31)
        #expect(daemon.mac.sleepDisabled == 0)
    }

    @Test("A hold with no deadline runs on the lease alone")
    func indefiniteHold() {
        let daemon = Daemon()
        daemon.start()
        #expect(daemon.hold(deadline: nil, lease: 90).last == .ok)
        #expect(daemon.claim?.deadline == nil)

        for _ in 0..<10 {
            daemon.advance(30)
            daemon.hold(deadline: nil, lease: 90)
        }
        #expect(daemon.mac.sleepDisabled == 1, "a switch holds until it is switched off")

        daemon.advance(91)
        #expect(daemon.mac.sleepDisabled == 0)
    }

    @Test("An indefinite hold may later be given a deadline")
    func indefiniteThenBounded() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(generation: 1, deadline: nil, lease: 90)

        let deadline = daemon.clock.now.addingTimeInterval(30)
        #expect(daemon.hold(generation: 2, deadline: deadline, lease: 90).last == .ok)

        daemon.advance(31)
        #expect(daemon.mac.sleepDisabled == 0)
    }

    @Test("A deadline past the horizon is cut back to it")
    func deadlineHorizon() {
        let daemon = Daemon()
        daemon.start()
        let now = daemon.clock.now
        daemon.hold(deadline: now.addingTimeInterval(400 * 3_600), lease: 90)

        #expect(daemon.claim?.deadline == now.addingTimeInterval(HelperLimits.deadlineHorizon))
    }
}

/// How long a hold may run for, and the rule that outranks the number.
///
/// **An acknowledged hold must never reject its own unchanged renewal.** The
/// app offers seven days and a user can pick one; a daemon with a lower
/// horizon fixed the first hold at its own number, then refused the renewal
/// carrying the same deadline it had always been sent, and the hold died at
/// ninety-one seconds with the card still saying it was on.
@Suite("Durations the app can ask for")
struct HelperDurationTests {

    /// The two limits are one limit. A daemon that will not go as far as the
    /// app offers is a feature with a silent ceiling nobody is told about.
    @Test("The daemon's horizon reaches as far as the app's longest session")
    func horizonCoversTheApp() {
        #expect(HelperLimits.deadlineHorizon >= 7 * 24 * 60 * 60,
                "the app offers a session the daemon will not fix a deadline for")
    }

    @Test("A seven-day hold is taken, and renews unchanged for as long as it runs")
    func sevenDaysRenews() {
        let daemon = Daemon()
        daemon.start()
        let wanted = daemon.clock.now.addingTimeInterval(7 * 24 * 60 * 60)

        #expect(daemon.hold(generation: 1, deadline: wanted).last == .ok)
        #expect(daemon.mac.sleepDisabled == 1)

        // Thirty seconds later, the heartbeat sends the same deadline again.
        daemon.advance(30)
        #expect(daemon.hold(generation: 2, deadline: wanted).last == .ok,
                "a hold that was accepted refused its own renewal")
        daemon.advance(30)
        #expect(daemon.hold(generation: 3, deadline: wanted).last == .ok)

        // And past the lease it would have died at.
        daemon.advance(31)
        #expect(daemon.mac.sleepDisabled == 1, "the hold lapsed while it was being renewed")
    }

    /// Belt and braces for whatever the horizon is: even a deadline the daemon
    /// *did* clamp must still accept the renewal that repeats it.
    @Test("A clamped deadline does not refuse the request that was clamped")
    func clampedDeadlineRenews() {
        let daemon = Daemon()
        daemon.start()
        // Further out than any horizon this daemon will ever have.
        let absurd = daemon.clock.now.addingTimeInterval(HelperLimits.deadlineHorizon * 10)

        #expect(daemon.hold(generation: 1, deadline: absurd).last == .ok)
        daemon.advance(30)
        #expect(daemon.hold(generation: 2, deadline: absurd).last == .ok,
                "the daemon refused the very request it had just acknowledged")
        #expect(daemon.mac.sleepDisabled == 1)
    }

    /// The effective deadline still never moves. Accepting the renewal is not
    /// accepting a longer session.
    @Test("A clamped hold still ends when the clamp said it would")
    func clampStillBinds() {
        let daemon = Daemon()
        daemon.start()
        let absurd = daemon.clock.now.addingTimeInterval(HelperLimits.deadlineHorizon * 10)
        daemon.hold(generation: 1, deadline: absurd)

        daemon.advance(HelperLimits.deadlineHorizon + 1)

        #expect(daemon.mac.sleepDisabled == 0, "a clamped deadline stopped binding")
        #expect(daemon.claim == nil)
    }

    @Test("Asking for longer than the first hold is still refused")
    func lengtheningIsStillRefused() {
        let daemon = Daemon()
        daemon.start()
        let first = daemon.clock.now.addingTimeInterval(600)
        daemon.hold(generation: 1, deadline: first)

        let longer = first.addingTimeInterval(600)
        #expect(daemon.hold(generation: 2, deadline: longer).last == .invalidArgument)
    }

    @Test("Asking for less than the first hold shortens it")
    func shorteningIsAccepted() {
        let daemon = Daemon()
        daemon.start()
        let first = daemon.clock.now.addingTimeInterval(600)
        daemon.hold(generation: 1, deadline: first)

        let sooner = daemon.clock.now.addingTimeInterval(120)
        #expect(daemon.hold(generation: 2, deadline: sooner).last == .ok)

        daemon.advance(121)
        #expect(daemon.mac.sleepDisabled == 0, "the shortened deadline was ignored")
    }
}

/// What `ok` means, from the daemon's side.
///
/// It means the lease is on disk. It does not mean the Mac is held: the
/// privileged write comes afterwards and can be refused, and a client that
/// read `ok` as "held" told the user their Mac was being kept awake while the
/// setting read 0 and the daemon was still retrying.
@Suite("What an accepted hold has actually promised")
struct HelperAcceptanceTests {

    @Test("The reply goes out before the privileged write is even started")
    func replyPrecedesTheApply() {
        let daemon = Daemon()
        daemon.start()
        let childrenBefore = daemon.pmset.started.count

        let answer = daemon.holdWithoutDraining()

        #expect(answer.last == .ok)
        #expect(answer.childrenStartedAtEachReply == [childrenBefore],
                "the reply waited for work it is not supposed to wait for")
        #expect(daemon.mac.sleepDisabled == 0,
                "the setting was in force before anything had been written")
    }

    /// And the state it leaves behind says so: a claim exists, because it is
    /// journalled before the write, and the setting does not agree with it yet.
    @Test("An accepted hold whose apply is refused still reports a claim")
    func refusedApplyStillClaims() {
        let daemon = Daemon()
        daemon.start()
        daemon.mac.refuseWrites = 99

        #expect(daemon.hold().last == .ok, "the lease was refused over a write")
        #expect(daemon.status.ours, "the claim that says we may have changed it is missing")
        #expect(daemon.status.sleepDisabled == 0)
        #expect(!daemon.status.clean)
    }

    @Test("A hold whose apply landed agrees with itself")
    func appliedHoldAgrees() {
        let daemon = Daemon()
        daemon.start()
        #expect(daemon.hold().last == .ok)
        #expect(daemon.status.ours)
        #expect(daemon.status.sleepDisabled == 1)
    }
}
