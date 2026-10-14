import Foundation
import Testing

@testable import LedgeHelperKit

/// What happens when two things are true at once.
///
/// Every rule here exists because `pmset` is a child process: between deciding
/// to run one and hearing that it exited, anything a client can send can
/// arrive. The core answers that by never letting a completion decide
/// anything — it only reports; the reconcile that follows is what decides.
@Suite("Two things at once")
struct HelperCoreInterleavingTests {

    @Test("A release that arrives mid-apply ends with the setting put back")
    func releaseDuringApply() {
        let daemon = Daemon()
        daemon.start()
        daemon.mac.hangs = true

        daemon.hold()               // the apply's first read is out
        daemon.answerOne()          // reads 0, journals the claim, starts the write
        #expect(daemon.claim?.sleepDisabledClaimed == true)

        #expect(daemon.release().last == .ok)

        daemon.answerOne()          // the write lands
        daemon.answerOne()          // the readback says 1: the apply did succeed
        daemon.mac.hangs = false
        daemon.drain()

        // The apply was not undone by the release arriving; it finished, and
        // then the reconcile that followed saw that nobody wanted it any more.
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.claim == nil)
        #expect(daemon.status.clean)
    }

    @Test("A hold given up before its write never changes anything")
    func releaseBeforeTheWrite() {
        let daemon = Daemon()
        daemon.start()
        daemon.mac.hangs = true

        daemon.hold()               // the apply's read is out
        daemon.release()
        daemon.mac.hangs = false
        daemon.drain()

        #expect(!daemon.pmset.commands.contains(.writeSleepDisabled(true)))
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.status.clean)
    }

    @Test("A completion for an operation that is over is ignored")
    func staleCompletion() {
        let daemon = Daemon()
        daemon.start()
        daemon.mac.hangs = true
        daemon.hold()                     // the apply's read is outstanding
        let before = daemon.pmset.commands.count

        // A child from an earlier operation, reaped late. Taken as this
        // operation's answer it would read as "the setting is free, take it",
        // and the daemon would act on a reading of a Mac that has moved on.
        daemon.core.childExited(opID: 1, outcome: .read(0))

        #expect(daemon.pmset.commands.count == before, "it started nothing")
        #expect(daemon.log.contains("ignored a completion"))
        #expect(daemon.mac.sleepDisabled == 0)
    }

    @Test("The lease lapses on time even while a pmset child is hung")
    func leaseIsNotBlockedByAHungChild() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(lease: 90)
        #expect(daemon.mac.sleepDisabled == 1)

        // A later read hangs: the kill and reap are the runner's business, and
        // the core hears nothing until they are done.
        daemon.mac.hangs = true
        daemon.advance(30)
        daemon.hold(generation: 2, lease: 90)
        daemon.clock.advance(200)
        daemon.core.tick()

        #expect(daemon.status.cleanupPending, "the hold is already given up")
        #expect(!daemon.status.clean)

        // The child is finally reaped, and the restore that was waiting for it
        // starts at once.
        daemon.mac.hangs = false
        daemon.drain()
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.status.clean)
    }

    @Test("Eight holds may wait; the ninth is told so")
    func queueCap() {
        let daemon = Daemon()
        daemon.start()
        // Somebody else has the lock, so nothing can be settled and every
        // hold waits.
        daemon.store.file.lockedBy = "someone else"

        for generation in 1...HelperLimits.queuedHolds {
            #expect(daemon.hold(generation: generation).count == 0, "it is waiting, not answered")
        }
        #expect(daemon.hold(generation: 9).last == .busy)
    }

    @Test("A release is answered however full the queue is")
    func releaseIsNeverQueued() {
        let daemon = Daemon()
        daemon.start()
        daemon.store.file.lockedBy = "someone else"
        for generation in 1...HelperLimits.queuedHolds { daemon.hold(generation: generation) }

        // Everything about a release moves this Mac towards being allowed to
        // sleep, so there is no state in which refusing one is safer.
        #expect(daemon.release().count == 1)
    }

    @Test("A repeated heartbeat replaces the one already waiting")
    func repeatedHeartbeat() {
        let daemon = Daemon()
        daemon.start()
        daemon.store.file.lockedBy = "someone else"

        let first = daemon.hold(generation: 1)
        let second = daemon.hold(generation: 1)

        #expect(first.last == .busy, "the later ask is the one being served")
        #expect(second.count == 0)

        daemon.store.file.lockedBy = nil
        daemon.advance(1)
        #expect(second.last == .ok)
    }

    @Test("A SIGTERM is taken while the queue is full, and the setting is put back")
    func sigtermWithAFullQueue() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold()
        #expect(daemon.mac.sleepDisabled == 1)

        daemon.store.file.lockedBy = "someone else"
        for generation in 2...9 { daemon.hold(generation: generation) }

        daemon.core.sigterm()
        daemon.store.file.lockedBy = nil
        daemon.advance(1)

        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.status.clean, "launchd may take the daemon down now")
    }

    @Test("A daemon on its way out takes no new holds")
    func noHoldsAfterSigterm() {
        let daemon = Daemon()
        daemon.start()
        daemon.core.sigterm()

        // A hold taken now is one nothing will renew, because the process that
        // would have to is exiting. The client takes one from the daemon that
        // replaces this one.
        #expect(daemon.hold(session: Daemon.sessionB).last == .stale)
        #expect(daemon.mac.sleepDisabled == 0)
        #expect(daemon.status.clean)
    }
}

/// Arguments, which arrive over XPC from a process the daemon cannot see.
@Suite("What a client may ask for")
struct HelperCoreArgumentTests {

    @Test("A session id that is not a UUID is refused")
    func sessionShape() {
        let daemon = Daemon()
        daemon.start()
        #expect(daemon.hold(session: "../../etc/passwd").last == .invalidArgument)
        #expect(daemon.hold(session: "").last == .invalidArgument)
    }

    @Test("A generation that goes backwards is refused")
    func generationsOnlyGoForwards() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(generation: 4)
        #expect(daemon.hold(generation: 3).last == .stale)
        #expect(daemon.hold(generation: 4).last == .ok)
        #expect(daemon.hold(generation: 5).last == .ok)
    }

    @Test("A deadline that has already passed is refused")
    func deadlineInThePast() {
        let daemon = Daemon()
        daemon.start()
        let answer = daemon.hold(deadline: daemon.clock.now.addingTimeInterval(-1))
        #expect(answer.last == .invalidArgument)
        #expect(daemon.mac.sleepDisabled == 0)
    }

    @Test("Releasing a session nobody is holding says so, and changes nothing")
    func releaseOfAStranger() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(session: Daemon.sessionA)

        #expect(daemon.release(session: Daemon.sessionB).last == .notHolder)
        #expect(daemon.mac.sleepDisabled == 1, "the hold that does exist is untouched")

        #expect(daemon.release(session: Daemon.sessionA).last == .ok)
        #expect(daemon.mac.sleepDisabled == 0)
    }

    @Test("A session the daemon has retired needs a new generation to come back")
    func retiredSession() {
        let daemon = Daemon()
        daemon.start()
        daemon.hold(generation: 1)
        daemon.release(generation: 1)

        #expect(daemon.hold(generation: 1).last == .stale, "a release in flight cannot be undone")
        #expect(daemon.hold(generation: 2).last == .ok)
    }
}
