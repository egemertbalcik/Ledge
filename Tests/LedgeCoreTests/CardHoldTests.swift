import Foundation
import Testing

@testable import LedgeCore

@Suite("Card hold")
struct CardHoldTests {

    @Test("A card on screen may hold the notch")
    func onscreenHolds() {
        var hold = CardHold()
        let first = hold.hold()
        #expect(first)
        #expect(hold.isHeld)
    }

    @Test("A card that has gone may not take a new hold")
    func goneCardCannotHold() {
        var hold = CardHold()
        hold.disappeared()
        let took = hold.hold()
        #expect(took == false, "a card that is gone took a hold on the notch")
        #expect(!hold.isHeld)
    }

    /// The order the two disappearances arrive in is SwiftUI's business, so
    /// both have to be safe. This is the one that caused the bug: the rule's
    /// teardown reached the card *after* the card knew it had gone.
    @Test("A teardown arriving after the card has gone cannot re-latch it")
    func teardownAfterDisappearIsRefused() {
        var hold = CardHold()
        _ = hold.hold()                       // an adjustment was under way
        let wasHeld = hold.disappeared()
        #expect(wasHeld, "the standing hold should be reported for dropping")
        #expect(!hold.isHeld)

        // The rule's own teardown, arriving second.
        let late = hold.hold()
        #expect(late == false, "the notch was re-latched by a card that had gone")
        #expect(!hold.isHeld)
    }

    /// And the other order: the rule tears down first, the card follows.
    @Test("A hold taken just before the card goes is dropped when it does")
    func holdTakenBeforeDisappearIsDropped() {
        var hold = CardHold()
        _ = hold.hold()
        #expect(hold.isHeld)
        let reported = hold.disappeared()
        #expect(reported, "the hold was left standing after the card went")
        #expect(!hold.isHeld)
    }

    @Test("Coming back makes the card holdable again")
    func reappearingRestoresHolding() {
        var hold = CardHold()
        hold.disappeared()
        let whileGone = hold.hold()
        #expect(whileGone == false)
        hold.appeared()
        let back = hold.hold()
        #expect(back, "the card could not hold the notch after coming back")
    }

    @Test("Releasing drops the hold but keeps the card holdable")
    func releaseKeepsCardUsable() {
        var hold = CardHold()
        _ = hold.hold()
        hold.release()
        #expect(!hold.isHeld)
        let again = hold.hold()
        #expect(again, "a released card should still be able to hold again")
    }

    @Test("An unmatched adjustment end is cleanup, not an interaction")
    func unmatchedAdjustmentEndIsIgnored() {
        var hold = CardHold()
        let accepted = hold.adjustmentChanged(to: false)
        #expect(!accepted)
        #expect(!hold.isAdjusting)
        #expect(!hold.isHeld)
    }

    @Test("Adjustment edges are balanced and duplicates are ignored")
    func adjustmentEdgesAreBalanced() {
        var hold = CardHold()
        let began = hold.adjustmentChanged(to: true)
        #expect(began)
        #expect(hold.isAdjusting)
        let duplicateBegin = hold.adjustmentChanged(to: true)
        #expect(!duplicateBegin)
        let ended = hold.adjustmentChanged(to: false)
        #expect(ended)
        #expect(!hold.isAdjusting)
        let duplicateEnd = hold.adjustmentChanged(to: false)
        #expect(!duplicateEnd)
    }

    @Test("Disappearance invalidates a late adjustment end")
    func disappearanceInvalidatesAdjustment() {
        var hold = CardHold()
        let began = hold.adjustmentChanged(to: true)
        #expect(began)
        hold.disappeared()
        #expect(!hold.isAdjusting)
        let lateEnd = hold.adjustmentChanged(to: false)
        #expect(!lateEnd)
    }
}
