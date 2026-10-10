import Foundation
import Testing
@testable import LedgeCore

@Suite("Keep Awake state machine")
struct KeepAwakeReducerTests {

    private let boot = "boot-A"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func running(minutes: Int = 60, id: String = "s1", from: Date? = nil) -> KeepAwakeState {
        KeepAwakeReducer.start(from: .ready, minutes: minutes, now: from ?? t0,
                               id: id, bootID: boot)!
    }

    @Test("Start takes the length asked for, within bounds")
    func startClamps() {
        #expect(KeepAwakeReducer.clamp(minutes: 1) == 5)
        #expect(KeepAwakeReducer.clamp(minutes: 60) == 60)
        #expect(KeepAwakeReducer.clamp(minutes: 10_000) == 24 * 60)

        let state = running(minutes: 90)
        #expect(state.session?.total == TimeInterval(90 * 60))
        #expect(state.session?.deadline == t0.addingTimeInterval(90 * 60))
        #expect(state.session?.bootID == boot)
    }

    @Test("Start is refused while a session is already running")
    func noDoubleStart() {
        // Otherwise the button would silently move the deadline, which is not
        // what it says it does.
        #expect(KeepAwakeReducer.start(from: running(), minutes: 30, now: t0,
                                       id: "s2", bootID: boot) == nil)
    }

    @Test("The deadline ends the session, dated to the deadline itself")
    func deadline() {
        let state = running(minutes: 60)
        #expect(KeepAwakeReducer.tick(state, now: t0.addingTimeInterval(3_599)) == nil)

        // Dated to the deadline, not to when the tick happened: a tick that
        // arrives late (asleep, busy, clock moved) must not claim the session
        // ran longer than it did.
        let late = t0.addingTimeInterval(9_999)
        guard case .finished(let finish)? = KeepAwakeReducer.tick(state, now: late) else {
            return #expect(Bool(false), "it should have ended")
        }
        #expect(finish.reason == .timeUp)
        #expect(finish.endedAt == t0.addingTimeInterval(3_600))
        #expect(finish.remaining == 0)
    }

    @Test("Ticking does nothing when nothing is running")
    func tickIdle() {
        #expect(KeepAwakeReducer.tick(.ready, now: t0) == nil)
    }

    @Test("Every end reason produces a Finished card that remembers the session")
    func ends() {
        for reason in KeepAwakeEndReason.allCases {
            let state = running(minutes: 60)
            let now = t0.addingTimeInterval(600)
            guard case .finished(let finish)? =
                    KeepAwakeReducer.end(from: state, reason: reason, now: now) else {
                return #expect(Bool(false), "\(reason) did not end it")
            }
            #expect(finish.reason == reason)
            #expect(finish.ran == 600)
            #expect(finish.remaining == 3_000)
            #expect(finish.sessionID == "s1")
        }
    }

    @Test("Ending what is not running invents nothing")
    func endIdle() {
        // Quitting and switching the card off both end defensively, and must
        // not manufacture a Finished card out of a session nobody started.
        #expect(KeepAwakeReducer.end(from: .ready, reason: .quit, now: t0) == nil)
    }

    @Test("Resume is offered only for the user's own End, and only in time")
    func resumeRules() {
        let ended = KeepAwakeReducer.end(from: running(), reason: .endedByYou,
                                         now: t0.addingTimeInterval(600))!
        let soon = t0.addingTimeInterval(700)
        #expect(KeepAwakeReducer.resume(from: ended, now: soon, id: "s2", bootID: boot) != nil)

        // Past the original deadline there is nothing to resume to: it would
        // start a session that ends in the same breath.
        #expect(KeepAwakeReducer.resume(from: ended, now: t0.addingTimeInterval(4_000),
                                        id: "s2", bootID: boot) == nil)

        for reason in KeepAwakeEndReason.allCases where reason != .endedByYou {
            let other = KeepAwakeReducer.end(from: running(), reason: reason,
                                             now: t0.addingTimeInterval(600))!
            #expect(KeepAwakeReducer.resume(from: other, now: soon, id: "s2", bootID: boot) == nil,
                    "\(reason) should not be resumable")
        }
    }

    @Test("Resume keeps the original deadline and takes a new identity")
    func resumeKeepsDeadline() {
        let ended = KeepAwakeReducer.end(from: running(minutes: 60), reason: .endedByYou,
                                         now: t0.addingTimeInterval(600))!
        let at = t0.addingTimeInterval(700)
        guard case .running(let session)? =
                KeepAwakeReducer.resume(from: ended, now: at, id: "s2", bootID: boot) else {
            return #expect(Bool(false), "it should have resumed")
        }
        #expect(session.deadline == t0.addingTimeInterval(3_600))
        #expect(session.remaining(at: at) == 2_900)
        // A new id, so the journal record of the ended session is not
        // overwritten by its successor.
        #expect(session.id == "s2")
    }

    @Test("Dismiss clears a Finished card and nothing else")
    func dismiss() {
        let ended = KeepAwakeReducer.end(from: running(), reason: .timeUp,
                                         now: t0.addingTimeInterval(3_600))!
        #expect(KeepAwakeReducer.dismiss(ended) == .ready)
        #expect(KeepAwakeReducer.dismiss(.ready) == nil)
        #expect(KeepAwakeReducer.dismiss(running()) == nil)
    }

    // MARK: - Continuity

    @Test("A session from this boot with time left is resumed")
    func recoverResumes() {
        let session = running().session!
        let recovery = KeepAwakeReducer.recover(session, bootID: boot,
                                                now: t0.addingTimeInterval(600),
                                                tombstoned: false)
        #expect(recovery == .resume(session))
    }

    @Test("A session from another boot ended when the Mac restarted")
    func recoverRestart() {
        let session = running().session!
        guard case .ended(let finish) = KeepAwakeReducer.recover(
            session, bootID: "boot-B", now: t0.addingTimeInterval(60), tombstoned: false
        ) else { return #expect(Bool(false), "it should have ended") }
        #expect(finish.reason == .macRestarted)
    }

    @Test("A deadline that passed while Ledge was away is dated to the deadline")
    func recoverMissed() {
        let session = running(minutes: 60).session!
        guard case .ended(let finish) = KeepAwakeReducer.recover(
            session, bootID: boot, now: t0.addingTimeInterval(7_200), tombstoned: false
        ) else { return #expect(Bool(false), "it should have ended") }
        #expect(finish.reason == .ledgeNotRunning)
        // The Mac was free to sleep from the deadline, and the sentence says
        // so; dating it to launch would claim hours of keep-awake that never
        // happened.
        #expect(finish.endedAt == t0.addingTimeInterval(3_600))
    }

    @Test("A tombstone beats the journal: an ended session is not resurrected")
    func recoverTombstone() {
        // The user pressed End and only the write failed. Believing the
        // journal here would start a session they already stopped.
        let session = running().session!
        guard case .ended(let finish) = KeepAwakeReducer.recover(
            session, bootID: boot, now: t0.addingTimeInterval(600), tombstoned: true
        ) else { return #expect(Bool(false), "it should have ended") }
        #expect(finish.reason == .endedByYou)
        #expect(finish.endUnrecorded)
    }

    @Test("A tombstone wins even when the Mac restarted as well")
    func tombstoneBeatsBoot() {
        let session = running().session!
        guard case .ended(let finish) = KeepAwakeReducer.recover(
            session, bootID: "boot-B", now: t0.addingTimeInterval(60), tombstoned: true
        ) else { return #expect(Bool(false), "it should have ended") }
        #expect(finish.reason == .endedByYou)
    }
}
