import Foundation
import Testing
@testable import LedgeCore

@Suite("Keep Awake copy")
struct KeepAwakeCopyTests {

    @Test("Every visible end reason says something different")
    func distinct() {
        // The recipe asks each state to be its own sentence that says what
        // happens next. Two reasons sharing a sentence means one of them is
        // not being explained.
        let visible = KeepAwakeEndReason.allCases.filter(\.isVisible)
        let open = Set(visible.map {
            KeepAwakeCopy.finished($0, at: "17:40", floor: 15, lidClosed: false)
        })
        #expect(open.count == visible.count)
    }

    @Test("Heat is explained differently depending on whether the lid is shut")
    func thermalDiffers() {
        // With the lid closed there is something to do about it, so the
        // sentence says it.
        let closed = KeepAwakeCopy.finished(.thermal, at: "17:40", floor: 15, lidClosed: true)
        let open = KeepAwakeCopy.finished(.thermal, at: "17:40", floor: 15, lidClosed: false)
        #expect(closed != open)
        #expect(closed.contains("Open the lid"))
    }

    @Test("Sentences carry the numbers they are about")
    func carriesFacts() {
        #expect(KeepAwakeCopy.finished(.batteryFloor, at: "17:40", floor: 20, lidClosed: false)
            .contains("20%"))
        #expect(KeepAwakeCopy.finished(.timeUp, at: "17:40", floor: 15, lidClosed: false)
            .contains("17:40"))
        // The resting card is a switch and says no number at all now; the
        // one place a battery floor is still printed is under the lid-closed
        // mode's length boxes, which is what this guards.
        #expect(KeepAwakeCopy.lidEndsAt(floor: 20).contains("20%"))
    }

    @Test("Nothing promises that an ended session never comes back")
    func noOverPromise() {
        // §6.1.1: when the journal and the tombstone both refuse, a relaunch
        // may resume a session the user ended. The copy must not claim
        // otherwise, so the honest sentence is the only one offered.
        let line = KeepAwakeCopy.endNotSaved(until: "17:40")
        #expect(line.contains("may start again"))
        #expect(!line.lowercased().contains("never"))
        #expect(KeepAwakeCopy.continuityPolicy.contains("quit Ledge"))
        #expect(KeepAwakeCopy.continuityPolicy.contains("restart your Mac"))
    }

    @Test("Failures say what changed, which is nothing, and what to do next")
    func failures() {
        for line in [KeepAwakeCopy.assertionRefused, KeepAwakeCopy.startNotSaved] {
            #expect(line.contains("nothing changed"))
            // "Try Start again" while the card had a Start button on it. It
            // is a switch now, and copy that names a control the card does not
            // have is worse than copy that names none.
            #expect(line.contains("Try again"))
            #expect(!line.contains("Start"), "the card has no Start button to try again")
        }
    }

    /// The handover's sentences, and the reinstall's beside them, held to the
    /// voice the rest of the card speaks in. Short sentences, nobody speaking
    /// in the first person, and no comma before "and" or "but" — the proposal
    /// these came from had all three, and was too long for the card besides.
    @Test("The handover says what happened and what to do, in the card's own voice")
    func handoverVoice() {
        let removals = [KeepAwakeLidState.handover(.underWay), .handover(.restartNeeded),
                        .helperMismatch].compactMap(KeepAwakeCopy.helperRemovalUnheard)
        let lines = [KeepAwakeCopy.lidUpdating, KeepAwakeCopy.lidRestartNeeded,
                     KeepAwakeCopy.lidHelperMismatch,
                     KeepAwakeCopy.lidMenuHeadlineUpdating,
                     KeepAwakeCopy.lidMenuHeadlineRestartNeeded,
                     KeepAwakeCopy.lidMenuHeadlineHelperMismatch,
                     KeepAwakeCopy.railUpdating, KeepAwakeCopy.railRestartNeeded,
                     KeepAwakeCopy.railHelperMismatch] + removals
        for line in lines {
            #expect(!line.contains(", and") && !line.contains(", but"), "\(line)")
            let words = Set(line.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { !$0.isEmpty })
            #expect(words.isDisjoint(with: ["i", "we", "our", "us", "me", "my"]),
                    "first person: \(line)")
            // "Held" is not a word the card ever shows, so nothing may tell
            // somebody to wait until it does.
            #expect(!words.contains("held"), "names a state the card never shows: \(line)")
        }
        // What happened, how long, and the one thing to do meanwhile.
        #expect(KeepAwakeCopy.lidUpdating.contains("updated"))
        #expect(KeepAwakeCopy.lidUpdating.contains("two minutes"))
        #expect(KeepAwakeCopy.lidUpdating.contains("Keep the lid open"))
        // The fix, then what matters until then. "The update" once: the
        // second sentence names what the restart does instead.
        #expect(KeepAwakeCopy.lidRestartNeeded ==
                "The helper is still the copy from before the update. "
                    + "Restart your Mac to replace it. Until then, keep the lid open.")
        #expect(KeepAwakeCopy.lidRestartNeeded.components(separatedBy: "the update").count == 2,
                "the restart sentence says \"the update\" more than once")
        // A reinstall, and never "updated" or "restart": nothing here was
        // updated, and a restart starts the same helper again.
        #expect(KeepAwakeCopy.lidHelperMismatch.contains("Reinstall Ledge"))
        #expect(KeepAwakeCopy.lidHelperMismatch.contains("keep the lid open"))
        #expect(!KeepAwakeCopy.lidHelperMismatch.lowercased().contains("update"))
        #expect(!KeepAwakeCopy.lidHelperMismatch.lowercased().contains("restart"))
        // None tells somebody to press the mode again, which is what
        // "Can't tell" said here and what started the wait over.
        for line in [KeepAwakeCopy.lidUpdating, KeepAwakeCopy.lidRestartNeeded,
                     KeepAwakeCopy.lidHelperMismatch] {
            #expect(!line.contains("press"), "\(line)")
            #expect(!line.contains(KeepAwakeCopy.lidClosed), "\(line)")
            #expect(line.count <= 140, "too long for the card: \(line.count) characters")
        }
        // Rail words sit under a stop on a card 275 points wide; the render
        // tests measure them against the middle label.
        for word in [KeepAwakeCopy.railUpdating, KeepAwakeCopy.railRestartNeeded,
                     KeepAwakeCopy.railHelperMismatch] {
            #expect(word.count <= 16, "\(word)")
        }
    }

    /// Settings' Remove refuses while nothing the helper says can be heard,
    /// and it used to say "try again in a moment" whatever the reason. In
    /// these states a moment changes nothing, so each says what does.
    @Test("Remove says what will let it ask, not to try again in a moment")
    func removalSaysWhatWillHelp() {
        let underWay = KeepAwakeCopy.helperRemovalUnheard(.handover(.underWay))
        let stuck = KeepAwakeCopy.helperRemovalUnheard(.handover(.restartNeeded))
        let wrong = KeepAwakeCopy.helperRemovalUnheard(.helperMismatch)
        #expect(underWay?.contains("two minutes") == true)
        #expect(stuck?.contains("Restart your Mac") == true)
        #expect(wrong?.contains("Reinstall Ledge") == true)
        for line in [underWay, stuck, wrong] {
            #expect(line?.contains("setting to put back") == true,
                    "the reason the helper stays is not said")
            #expect(line?.lowercased().contains("in a moment") == false)
        }
        // Everything else keeps the general sentence.
        for state: KeepAwakeLidState in [.off, .holding, .cannotTell, .unreachable,
                                         .refused(.busy), .notInstalled] {
            #expect(KeepAwakeCopy.helperRemovalUnheard(state) == nil, "\(state.name)")
        }
    }
}
