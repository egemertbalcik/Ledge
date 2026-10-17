import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// What the rail is allowed to say about this Mac.
///
/// Three stops in the order they promise more: Off, Awake, Lid shut. Two
/// numbers decide the drawing and they are deliberately not the same one —
/// where the bead sits is what the user chose, and where the fill stops is
/// what is actually true. Every bug this card has had came from collapsing
/// those two into one.
@Suite("The Keep Awake rail")
@MainActor
struct KeepAwakeRailTests {

    private static let realWidth: CGFloat = 275

    private func drawn(_ view: some View, width: CGFloat = realWidth) -> CGSize? {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 2
        return renderer.nsImage?.size
    }

    private func card(_ payload: KeepAwakePayload) -> KeepAwakeCardView {
        KeepAwakeCardView(payload: payload)
    }

    private func off(lid: KeepAwakeLidState = .off) -> KeepAwakePayload {
        KeepAwakePayload(phase: .ready, lid: lid)
    }

    private func awake() -> KeepAwakePayload {
        KeepAwakePayload(phase: .running, remaining: 0, held: 120,
                         isIndefinite: true, lid: .off)
    }

    private func lidShut(_ lid: KeepAwakeLidState = .holding) -> KeepAwakePayload {
        KeepAwakePayload(phase: .running, remaining: 45 * 60, held: 15 * 60,
                         isIndefinite: false, until: "17:40", minutes: 60,
                         lidHeld: lid == .holding, lidClosed: true, lid: lid)
    }

    // MARK: - Where the bead sits, and where the fill stops

    @Test("The bead is what you chose; the fill is what is true")
    func beadAndFillAreNotTheSameQuestion() {
        #expect(card(off()).chosenStop == 0)
        #expect(card(off()).filledTo == 0)

        #expect(card(awake()).chosenStop == 1)
        #expect(card(awake()).filledTo == 1)

        #expect(card(lidShut()).chosenStop == 2)
        #expect(card(lidShut()).filledTo == 2)

        // The case the whole shape exists for. The user asked for the lid
        // mode, the daemon has not confirmed it, and the Mac is genuinely
        // awake — so the bead is on the third stop and the fill stops at the
        // second. Drawing both from one number is what put a card on screen
        // reading "2h 30m left" above "nothing is being held".
        for lid: KeepAwakeLidState in [.unconfirmed, .unreachable, .refused(.busy)] {
            #expect(card(lidShut(lid)).chosenStop == 2, "\(lid.name) is still what was asked for")
            #expect(card(lidShut(lid)).filledTo == 1, "\(lid.name) is not a held lid")
        }
    }

    @Test("Accepted-but-not-applied and gone-quiet draw alike and say different things")
    func theTwoSilencesAreNotOneSilence() {
        // The daemon answers a hold once its lease is on disk and *before* it
        // runs the privileged write, so an acceptance is not a hold. Both of
        // these used to be `.unconfirmed` and therefore shared its sentence —
        // "it almost certainly still stands" — which is true of a hold that
        // was established and has gone quiet, and false of one that has never
        // been established. One sentence invites you to shut the lid; the
        // other must not.
        let applying = card(lidShut(.applying))
        let quiet = card(lidShut(.unconfirmed))

        #expect(applying.beadKind == .checking, "both are waiting")
        #expect(quiet.beadKind == .checking)
        #expect(applying.filledTo == 1, "neither is proven")
        #expect(quiet.filledTo == 1)
        #expect(applying.thirdStopLabel == KeepAwakeCopy.railChecking)
        #expect(quiet.thirdStopLabel == KeepAwakeCopy.railChecking)

        #expect(KeepAwakeCopy.lid(.applying) != KeepAwakeCopy.lid(.unconfirmed),
                "the same sentence for both is the overclaim this split exists to end")
        #expect(KeepAwakeCopy.lid(.applying) == KeepAwakeCopy.lidPending)
        #expect(!KeepAwakeLidState.applying.isConfirmed, "an acceptance is not a hold")
        #expect(KeepAwakeLidState.applying.isLive, "but the lease is taken")
    }

    @Test("The bead says whether the stop it sits on is proven")
    func beadKind() {
        #expect(card(off()).beadKind == .resting)
        #expect(card(awake()).beadKind == .held)
        #expect(card(lidShut()).beadKind == .held)
        // Asked for and still in the air: neither yes nor no.
        #expect(card(lidShut(.unconfirmed)).beadKind == .checking)
        // Answered with no, or never answered at all.
        #expect(card(lidShut(.unreachable)).beadKind == .notHeld)
        #expect(card(lidShut(.refused(.busy))).beadKind == .notHeld)
    }

    @Test("The third label says what the daemon last said")
    func thirdLabel() {
        #expect(card(off()).thirdStopLabel == KeepAwakeCopy.lidClosed)
        #expect(card(lidShut()).thirdStopLabel == KeepAwakeCopy.lidClosed)
        #expect(card(lidShut(.unconfirmed)).thirdStopLabel == KeepAwakeCopy.railChecking)
        #expect(card(lidShut(.unreachable)).thirdStopLabel == KeepAwakeCopy.railNotHeld)
    }

    // MARK: - The figure

    @Test("A hold with no end shows no figure")
    func noFigureForAnEndlessHold() {
        // The owner's own words: some people leave this on all day, and a
        // number counting up beside it reads as a timer they started. An
        // earlier version drew a 34pt stopwatch here.
        #expect(card(awake()).endFigure == nil)
        #expect(card(off()).endFigure == nil)
    }

    @Test("A hold that ends shows what is left of it")
    func figureForATimedHold() {
        let figure = card(lidShut()).endFigure
        #expect(figure?.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil)
        // And it keeps saying so while the daemon is quiet: the end time
        // belongs to the session, which is really running, not to the lid
        // half, which is the uncertain part. The rail carries that
        // uncertainty on its own.
        #expect(card(lidShut(.unconfirmed)).endFigure != nil)
        #expect(card(lidShut(.unreachable)).endFigure != nil)
    }

    // MARK: - What the line under the rail says

    @Test("The resting card says what the card is for, not what the bead says")
    func theRestingLineTeaches() {
        // It used to read "Your Mac sleeps as usual." — true, and a
        // description of a state somebody can already see. Nothing on the
        // resting card named the one thing nobody can guess: that the far stop
        // holds the Mac awake through a shut lid. Same length; now it teaches.
        let line = card(off()).consequenceLine
        #expect(line.contains(KeepAwakeCopy.lidClosed), "the far stop is not named")
        #expect(line.lowercased().contains("lid"), "the mechanism is nowhere on the card")
        #expect(line.count <= 52, "the owner asked for this not to get longer")
    }

    @Test("The rail does not say the same word twice")
    func noWordTwice() {
        // The header caption said "Off" beside the title while the rail said
        // Off in bold directly under the bead: the same word twice in fourteen
        // points of space.
        #expect(card(off()).headerCaptionText.isEmpty)
        // A running plain hold does have something of its own to say there.
        #expect(!card(awake()).headerCaptionText.isEmpty)
    }

    @Test("Every stop states what it means for this Mac")
    func consequences() {
        #expect(card(off()).consequenceLine == KeepAwakeCopy.consequenceOff)
        #expect(card(awake()).consequenceLine == KeepAwakeCopy.consequenceAwake)
        #expect(card(lidShut()).consequenceLine.contains("17:40"),
                "a hold that ends must say when")
    }

    @Test("The two ways out of the lid mode read differently")
    func theAsymmetryIsSaidOutLoud() {
        // The criticism neither switch design could answer: the clock running
        // out ends everything, stepping back one stop does not. Both are
        // previewed before anybody presses.
        let running = card(lidShut())
        #expect(running.previewLine(for: 0) == KeepAwakeCopy.previewToOffFromLid)
        #expect(running.previewLine(for: 1) == KeepAwakeCopy.previewDropLid)
        #expect(running.previewLine(for: 0) != running.previewLine(for: 1),
                "the two ways out must not read as the same thing")
        // And the consequence line says what the clock will do, unprompted.
        #expect(running.consequenceLine.contains("sleep again"))
    }

    @Test("A card nobody is pointing at shows what it is doing, not a preview")
    func atRestTheCardStatesItself() {
        // Adding `.focusable()` to the stops made something take focus the
        // instant a card was drawn, so every card — and every photograph of
        // one — opened showing "Ends now. Your Mac can sleep again.", the
        // preview of a press nobody had made, in place of the sentence saying
        // what the card was actually doing.
        for payload in [off(), awake(), lidShut(), lidShut(.unreachable)] {
            let drawn = card(payload)
            let preview = (0 ..< 3).compactMap { drawn.previewLine(for: $0) }
            #expect(!preview.contains(drawn.consequenceLine),
                    "a card at rest is showing a preview of a press nobody made")
        }
        #expect(card(off()).consequenceLine == KeepAwakeCopy.consequenceOff)
        #expect(card(lidShut()).consequenceLine == KeepAwakeCopy.consequenceTimed(until: "17:40"))
    }

    @Test("A press that would do nothing previews nothing")
    func noPreviewForYourOwnStop() {
        #expect(card(off()).previewLine(for: 0) == nil)
        #expect(card(awake()).previewLine(for: 1) == nil)
        #expect(card(lidShut()).previewLine(for: 2) == nil)
        // Except the one that does: asking again, keeping the end time.
        #expect(card(lidShut(.unreachable)).previewLine(for: 2)?.contains("17:40") == true)
    }

    // MARK: - What can be pressed

    @Test("Only your own stop and a build with no helper refuse a press")
    func whatCanBePressed() {
        // Everything else is pressable even when it will refuse. The reasons
        // a press is refused live outside Ledge — System Settings, another app
        // holding sleep — and a control that cannot be pressed can never find
        // out that they changed. That was the dead button.
        for lid: KeepAwakeLidState in [.off, .notInstalled, .needsApproval, .unreachable,
                                       .refused(.foreign), .refused(.inUseByOtherLedge),
                                       .refused(.busy)] {
            #expect(card(off(lid: lid)).canPress(2),
                    "\(lid.name) changes outside Ledge — the card must be able to re-ask")
        }
        #expect(!card(off(lid: .unsignedBuild)).canPress(2),
                "no press will give an unsigned build a privileged daemon")

        // Your own stop.
        #expect(!card(off()).canPress(0))
        #expect(!card(awake()).canPress(1))
        #expect(!card(lidShut()).canPress(2))
        // Unless it did not take, in which case pressing it asks again.
        #expect(card(lidShut(.unreachable)).canPress(2))
        #expect(card(lidShut(.refused(.busy))).canPress(2))
        // But not while the answer is still in the air.
        #expect(!card(lidShut(.unconfirmed)).canPress(2))
    }

    @Test("A stop that cannot be pressed still says why")
    func theUnpressableStopExplainsItself() {
        let unsigned = card(off(lid: .unsignedBuild))
        #expect(!unsigned.canPress(2))
        #expect(unsigned.previewLine(for: 2)?.isEmpty == false,
                "a control nobody can press and nothing explains is the dead button again")
    }

    // MARK: - Drawing

    @Test("Every state draws at the width a hardware notch gives it")
    func drawsAtTheRealWidth() {
        let states: [KeepAwakePayload] = [
            off(), off(lid: .notInstalled), off(lid: .refused(.foreign)),
            awake(), lidShut(), lidShut(.unconfirmed), lidShut(.unreachable),
            KeepAwakePayload(phase: .running, remaining: 45 * 60, isIndefinite: false,
                             until: "17:40", lidClosed: true, lid: .unreachable,
                             problem: .tooManyUnsaved)
        ]
        for payload in states {
            for width in [231, 260, 275, 283, 320] as [CGFloat] {
                guard let size = drawn(card(payload), width: width) else {
                    Issue.record("a state of this card would not draw at \(width)")
                    continue
                }
                #expect(size.height > 0)
                #expect(size.height <= 300 * 2, "the card must stay under the 300pt cap")
            }
        }
    }

    @Test("A hold with no end draws no taller than the card it was switched on from")
    func switchingOnDoesNotGrowTheCard() {
        guard let resting = drawn(card(off())), let held = drawn(card(awake()))
        else { Issue.record("both faces must draw"); return }
        #expect(held.height <= resting.height,
                "on is the same card as off, with the bead in another place")
    }
}
