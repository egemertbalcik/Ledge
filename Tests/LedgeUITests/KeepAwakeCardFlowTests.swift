import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// Everything the Keep Awake card is in the middle of, and what moves it.
///
/// These exist because the worst bug this card has had was invisible to every
/// other kind of test. The question opened and closed again inside one frame:
/// a rendered card showed the resting face, a height test measured the resting
/// face, the suite was green, and pressing Lid closed did nothing you could
/// see but flicker. Nothing here draws anything.
@Suite("What the Keep Awake card is in the middle of")
struct KeepAwakeCardFlowTests {

    /// Every state the lid reading can be in. Listed rather than derived, so
    /// a new case added to the enum fails to compile here and has to be
    /// thought about rather than silently inheriting someone else's answer.
    private static let everyLidState: [KeepAwakeLidState] = [
        .unsignedBuild, .notInstalled, .needsApproval, .unreachable, .off,
        .holding, .unconfirmed,
        .refused(.foreign), .refused(.inUseByOtherLedge), .refused(.stale),
        .refused(.busy), .refused(.persistFailed), .refused(.pmsetFailed),
        .refused(.notHolder), .refused(.invalidArgument)
    ]

    // MARK: - The flash

    @Test("Swapping faces is not an event, so the question cannot close itself")
    func theQuestionSurvivesTheFaceItWasOpenedFrom() {
        // The bug, stated as the test that would have caught it. Pressing Lid
        // closed replaces the resting face with the question — and the resting
        // face carried the reset. There is deliberately no `faceChanged()` to
        // call here, which is the whole point: the only way to clear this is
        // the card itself going away.
        var flow = KeepAwakeCardFlow()
        flow.pressedLidSwitch(answer: .off)
        #expect(flow.isAsking, "the press must open the question")

        // Whatever else happens short of the card leaving, the question stays.
        flow.pressedLidSwitch(answer: .off)
        #expect(flow.isAsking, "a second press must not toggle the question shut")
    }

    @Test("Only the card going away resets the card")
    func onlyTheCardResets() {
        var flow = KeepAwakeCardFlow()
        flow.pressedLidSwitch(answer: .off)
        flow.pressedLidSwitch(answer: .notInstalled)
        #expect(flow.isAsking)
        #expect(flow.showsLidNote)

        flow.cardWentAway()
        #expect(!flow.isAsking, "a card that comes back must come back resting")
        #expect(!flow.showsLidNote, "and without a sentence from a reading ago")
    }

    // MARK: - The press, against every answer

    @Test("A press opens the question exactly when the daemon says it may arm")
    func pressAgainstEveryState() {
        for lid in Self.everyLidState {
            var flow = KeepAwakeCardFlow()
            flow.pressedLidSwitch(answer: lid)
            #expect(flow.isAsking == lid.mayArm,
                    "\(lid.name): asking=\(flow.isAsking) but mayArm=\(lid.mayArm)")
            #expect(flow.showsLidNote == !lid.mayArm,
                    "\(lid.name): a refused press must leave a reason, and an accepted one must not")
        }
    }

    @Test("A refused press never closes a question already open")
    func refusalDoesNotCloseTheQuestion() {
        // Reachable: the question is open, the daemon's answer changes
        // underneath, and something presses again. Closing the question would
        // throw away a length somebody was in the middle of typing.
        for lid in Self.everyLidState where !lid.mayArm {
            var flow = KeepAwakeCardFlow(isAsking: true)
            flow.pressedLidSwitch(answer: lid)
            #expect(flow.isAsking, "\(lid.name) closed a question somebody was answering")
            #expect(flow.showsLidNote)
        }
    }

    @Test("An accepted press clears a reason left by an earlier refusal")
    func acceptanceClearsTheReason() {
        // The sequence after somebody approves the helper in System Settings:
        // press, told no, go and fix it, press again.
        var flow = KeepAwakeCardFlow()
        flow.pressedLidSwitch(answer: .needsApproval)
        #expect(flow.showsLidNote)
        #expect(!flow.isAsking)

        flow.pressedLidSwitch(answer: .off)
        #expect(flow.isAsking, "the second press, after approval, must open the question")
        #expect(!flow.showsLidNote, "and the old reason must go with it")
    }

    // MARK: - Answering it

    @Test("Answering the question closes it")
    func answering() {
        var flow = KeepAwakeCardFlow(isAsking: true, showsLidNote: true)
        flow.answeredQuestion()
        #expect(!flow.isAsking)
        #expect(!flow.showsLidNote)
    }

    @Test("Never mind closes the question and leaves everything else alone")
    func cancelling() {
        var flow = KeepAwakeCardFlow(isAsking: true, showsLidNote: true)
        flow.cancelledQuestion()
        #expect(!flow.isAsking)
        // Not cleared: the sentence is about whether the mode can run at all,
        // which backing out of the length question does not answer.
        #expect(flow.showsLidNote, "backing out of the length is not an answer to why it cannot start")
    }

    // MARK: - The other switch

    @Test("Moving to another stop clears the lid reason and leaves the question alone")
    func anotherStop() {
        var flow = KeepAwakeCardFlow(isAsking: true, showsLidNote: true)
        flow.movedToAnotherStop()
        #expect(!flow.showsLidNote, "the reason was about a press that is no longer the last one")
        #expect(flow.isAsking, "the question belongs to the other switch")
    }

    @Test("Dropping a running lid hold clears the reason and asks nothing")
    func droppingTheHold() {
        var flow = KeepAwakeCardFlow(showsLidNote: true)
        flow.droppedLidHold()
        #expect(!flow.showsLidNote)
        #expect(!flow.isAsking, "switching the lid mode off must never open the length question")
    }

    // MARK: - Answers that come back late

    @Test("A cancelled question is not reopened by the read it was waiting on")
    func lateAnswerAfterCancel() {
        // Press, change your mind, and the daemon answers a moment later.
        // Without a ticket the answer walked back the cancel and the question
        // reappeared on its own.
        var flow = KeepAwakeCardFlow()
        let ticket = flow.beganAsking()
        flow.cancelledQuestion()
        flow.pressedLidSwitch(answer: .off, ticket: ticket)
        #expect(!flow.isAsking, "an answer to a press that was taken back must change nothing")
    }

    @Test("Only the newest press acts on its answer")
    func onlyTheNewestPressWins() {
        var flow = KeepAwakeCardFlow()
        let first = flow.beganAsking()
        let second = flow.beganAsking()
        #expect(!flow.isCurrent(first))
        #expect(flow.isCurrent(second))

        // The older read finishes last, as reads do.
        flow.pressedLidSwitch(answer: .notInstalled, ticket: first)
        #expect(!flow.showsLidNote, "a superseded read must not put its reason on the card")

        flow.pressedLidSwitch(answer: .off, ticket: second)
        #expect(flow.isAsking)
    }

    @Test("A card that went away ignores every answer still in the air")
    func lateAnswerAfterTheCardLeft() {
        var flow = KeepAwakeCardFlow()
        let ticket = flow.beganAsking()
        flow.cardWentAway()
        flow.pressedLidSwitch(answer: .off, ticket: ticket)
        #expect(!flow.isAsking, "a card nobody is looking at must not open a question")
    }

    @Test("An answered question retires the read it came from")
    func answeringRetiresTheTicket() {
        var flow = KeepAwakeCardFlow()
        let ticket = flow.beganAsking()
        flow.pressedLidSwitch(answer: .off, ticket: ticket)
        flow.answeredQuestion()
        // The same read landing twice — a retry, a duplicated continuation —
        // must not reopen a question that was already answered.
        flow.pressedLidSwitch(answer: .off, ticket: ticket)
        #expect(!flow.isAsking)
    }

    @Test("Pressing another stop retires the read the lid press was waiting on")
    func anotherStopRetiresTheTicket() {
        // Press the lid stop, change your mind and press Off, and the daemon
        // answers a second later. The answer must not open a length question
        // over a card the user has already finished with.
        var flow = KeepAwakeCardFlow()
        let ticket = flow.beganAsking()
        flow.movedToAnotherStop()
        flow.pressedLidSwitch(answer: .off, ticket: ticket)
        #expect(!flow.isAsking, "Off was the user's last word; a late read must not undo it")
    }

    @Test("A press with no ticket still works")
    func untickedPressStillWorks() {
        // The gallery and the tests press without going near the daemon.
        var flow = KeepAwakeCardFlow()
        flow.pressedLidSwitch(answer: .off)
        #expect(flow.isAsking)
    }

    // MARK: - Sequences

    @Test("The whole path: press, answer, card closes, card returns")
    func theOrdinaryPath() {
        var flow = KeepAwakeCardFlow()
        #expect(!flow.isAsking)

        flow.pressedLidSwitch(answer: .off)
        #expect(flow.isAsking)

        flow.answeredQuestion()
        #expect(!flow.isAsking, "the hold was asked for; there is nothing left to ask")

        flow.cardWentAway()
        #expect(flow.appearance == KeepAwakeCardFlow().appearance,
                "a card that comes back is a card at rest")
    }

    @Test("A card dismissed mid-question comes back at rest, not half-asked")
    func dismissedMidQuestion() {
        var flow = KeepAwakeCardFlow()
        flow.pressedLidSwitch(answer: .off)
        flow.cardWentAway()
        #expect(!flow.isAsking)

        // And the next press still works — the reset must not have latched
        // anything shut.
        flow.pressedLidSwitch(answer: .off)
        #expect(flow.isAsking)
    }

    @Test("Resting is the only state with nothing to show")
    func restingIsEmpty() {
        let flow = KeepAwakeCardFlow()
        #expect(!flow.isAsking)
        #expect(!flow.showsLidNote)
    }

    @Test("Every transition is idempotent")
    func repeatingAnythingChangesNothingFurther() {
        // Guards against a transition that toggles rather than sets — which is
        // exactly how the question came to close itself.
        func check(_ name: String, _ apply: (inout KeepAwakeCardFlow) -> Void) {
            for seed in [KeepAwakeCardFlow(),
                         KeepAwakeCardFlow(isAsking: true),
                         KeepAwakeCardFlow(showsLidNote: true),
                         KeepAwakeCardFlow(isAsking: true, showsLidNote: true)] {
                var once = seed
                apply(&once)
                var twice = once
                apply(&twice)
                #expect(once.appearance == twice.appearance,
                        "\(name) is not idempotent from \(seed.appearance)")
            }
        }
        check("answeredQuestion") { $0.answeredQuestion() }
        check("cancelledQuestion") { $0.cancelledQuestion() }
        check("droppedLidHold") { $0.droppedLidHold() }
        check("movedToAnotherStop") { $0.movedToAnotherStop() }
        check("cardWentAway") { $0.cardWentAway() }
        for lid in Self.everyLidState {
            check("pressedLidSwitch(\(lid.name))") { $0.pressedLidSwitch(answer: lid) }
        }
    }
}
