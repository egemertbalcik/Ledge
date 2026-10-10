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
        #expect(KeepAwakeCopy.readyLidHeld(floor: 20).contains("20%"))
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
            #expect(line.contains("Try Start again"))
        }
    }
}
