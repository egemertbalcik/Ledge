import Foundation
import Testing

@testable import LedgeCore

/// Keep Awake as a switch: it holds until it is switched off.
///
/// The timed form is still here and is what the lid-closed mode will use, so
/// these are about the difference between the two rather than about one
/// replacing the other.
@Suite("A hold that runs until it is switched off")
struct KeepAwakeSwitchTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func switched() -> KeepAwakeSession {
        guard case .running(let session)? = KeepAwakeReducer.start(
            from: .ready, now: t0, id: "A", bootID: "boot"
        ) else {
            Issue.record("the switch did not start")
            return KeepAwakeSession(id: "A", startedAt: t0, bootID: "boot")
        }
        return session
    }

    @Test("It starts with no deadline at all")
    func startsWithoutADeadline() {
        let session = switched()
        #expect(session.deadline == nil)
        #expect(session.isIndefinite)
        #expect(session.total == 0, "nothing was asked for, so nothing is owed")
    }

    @Test("Nothing is left, because nothing is counting down")
    func remainingIsNothing() {
        let session = switched()
        #expect(session.remaining(at: t0.addingTimeInterval(3600)) == nil)
    }

    @Test("It counts up instead")
    func countsUp() {
        let session = switched()
        #expect(session.elapsed(at: t0.addingTimeInterval(3600)) == 3600)
    }

    @Test("It never expires on its own, however long it runs")
    func neverExpires() {
        let session = switched()
        let aWeekOn = t0.addingTimeInterval(7 * 24 * 3600)
        #expect(!session.hasExpired(at: aWeekOn))
        #expect(KeepAwakeReducer.tick(.running(session), now: aWeekOn) == nil,
                "a switch has no deadline to fire")
    }

    @Test("A timed hold still expires, because the lid-closed mode needs one")
    func timedStillExpires() {
        guard case .running(let session)? = KeepAwakeReducer.start(
            from: .ready, minutes: 30, now: t0, id: "B", bootID: "boot"
        ) else { return #expect(Bool(false), "the timed form did not start") }

        #expect(session.deadline == t0.addingTimeInterval(30 * 60))
        #expect(!session.isIndefinite)
        #expect(session.hasExpired(at: t0.addingTimeInterval(31 * 60)))
    }

    @Test("Switching it off by mistake can always be undone")
    func alwaysResumable() {
        // A timed session can only be resumed while its deadline is ahead. A
        // switch has no deadline to be past, so Resume is always honest.
        let session = switched()
        let finish = KeepAwakeReducer.finish(session, reason: .endedByYou,
                                             at: t0.addingTimeInterval(3600))
        #expect(finish.deadline == nil)
        #expect(finish.remaining == nil)
        #expect(finish.canResume(at: t0.addingTimeInterval(7 * 24 * 3600)))
    }

    @Test("Resuming it gives back a hold with no deadline, not a zero-length one")
    func resumesAsASwitch() {
        let session = switched()
        let ended = KeepAwakeState.finished(
            KeepAwakeReducer.finish(session, reason: .endedByYou, at: t0.addingTimeInterval(60))
        )
        guard case .running(let again)? = KeepAwakeReducer.resume(
            from: ended, now: t0.addingTimeInterval(120), id: "C", bootID: "boot"
        ) else { return #expect(Bool(false), "a switch must be resumable") }

        #expect(again.isIndefinite)
        #expect(again.id == "C", "a resumed hold is its own session")
    }

    @Test("A switch left running comes back after a relaunch")
    func survivesARelaunch() {
        // The user's choice: an indefinite hold is a setting, not a task. An
        // update or a relaunch should not quietly switch it off.
        let session = switched()
        let recovery = KeepAwakeReducer.recover(
            session, bootID: "boot", now: t0.addingTimeInterval(4 * 3600), tombstoned: false
        )
        guard case .resume(let back) = recovery else {
            return #expect(Bool(false), "an indefinite hold must survive a relaunch")
        }
        #expect(back.isIndefinite)
    }

    @Test("A switch does not come back across a restart")
    func doesNotSurviveARestart() {
        // A session belongs to one boot, deadline or not: the Mac that was
        // being held awake is gone.
        let session = switched()
        let recovery = KeepAwakeReducer.recover(
            session, bootID: "a different boot", now: t0.addingTimeInterval(60), tombstoned: false
        )
        guard case .ended(let finish) = recovery else {
            return #expect(Bool(false), "a restart ends it")
        }
        #expect(finish.reason == .macRestarted)
    }
}
