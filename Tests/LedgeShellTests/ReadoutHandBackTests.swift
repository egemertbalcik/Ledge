import Foundation
import LedgeCore
import Testing

@testable import LedgeShell

/// The watch that hands a card back from under a held readout: the real
/// type, the real reducer, a pointer predicate the test sets. Bounded: a few
/// hundred milliseconds of run loop per test, a 20 ms interval.
@Suite("Handing a card back from under a readout")
@MainActor
struct ReadoutHandBackTests {

    @MainActor
    final class Fixture {
        var state = NotchState()
        var adjusting = false
        var pointerOnCard = false
        var releases = 0
        lazy var watch = ReadoutHandBack(
            interval: 0.02,
            state: { [unowned self] in self.state },
            isAdjusting: { [unowned self] in self.adjusting },
            handsBack: { [unowned self] in self.pointerOnCard },
            release: { [unowned self] in self.releases += 1; self.send(.hudReleased) }
        )

        /// What the coordinator does: reduce, then let the watch follow.
        func send(_ event: NotchEvent) {
            _ = NotchReducer.reduce(&state, event)
            watch.follow(event)
        }

        /// A readout held over a hovered card under the pointer.
        func holdReadoutOverCard() {
            send(.hoverChanged(true))
            send(.hudRequested(1.4))
            send(.timerFired(.hud))
        }
    }

    private static func pump(until limit: Double = 2, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(limit)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private static func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test("On the card, off the readout: the card comes back")
    func handsBack() async throws {
        let f = Fixture()
        f.holdReadoutOverCard()
        try #require(ReadoutHandBack.isHeldOverCard(f.state))
        try #require(f.watch.isWatching)
        f.pointerOnCard = true
        await Self.pump { f.releases > 0 }
        #expect(f.releases == 1)
        #expect(f.state.phase == .hover)
        #expect(!f.watch.isWatching)
    }

    /// Found by review (R2): a look queued for the old readout retired the
    /// new one a quarter of a second after the key that asked for it.
    @Test("A new key press keeps its readout for its own duration")
    func newRequestIsNotRetiredByTheOldWatch() async throws {
        let f = Fixture()
        f.holdReadoutOverCard()
        await Self.pump { f.watch.looks >= 1 }
        try #require(f.watch.looks >= 1, "the watch really ran for the first readout")
        try #require(f.state.phase == .hud)

        // A second key, with the pointer now down on the card.
        f.send(.hudRequested(1.4))
        f.pointerOnCard = true
        try #require(f.state.phase == .hud)
        await Self.pump(0.3)
        #expect(f.releases == 0, "retired before its own timeout")
        #expect(f.state.phase == .hud)
        #expect(!f.watch.isWatching)

        // Its own timeout, under the pointer: held, then handed back.
        f.send(.timerFired(.hud))
        await Self.pump { f.releases > 0 }
        #expect(f.releases == 1)
        #expect(f.state.phase == .hover)
    }

    /// Found by review (R4): with the screens dark nothing tracks the
    /// pointer, so nothing would have ended the watch.
    @Test("Dark screens stop the watch; waking brings it back only if still held")
    func dormancy() async throws {
        let f = Fixture()
        f.holdReadoutOverCard()
        await Self.pump { f.watch.looks >= 1 }
        try #require(f.watch.isWatching)

        f.watch.setDormant(true)
        #expect(!f.watch.isWatching)
        let atDark = f.watch.looks
        await Self.pump(0.15)
        #expect(f.watch.looks == atDark, "no looks while dark")
        // Nothing the reducer sees while dark can restart it either.
        f.send(.timerFired(.hud))
        #expect(!f.watch.isWatching)

        f.watch.setDormant(false)
        #expect(f.watch.isWatching, "still held over the card, so watched again")
        f.pointerOnCard = true
        await Self.pump { f.releases > 0 }
        #expect(f.state.phase == .hover)

        // Woken with nothing held: nothing to watch.
        f.watch.setDormant(true)
        f.watch.setDormant(false)
        #expect(!f.watch.isWatching)
    }

    /// Found by review (R2a): the timeout came while the slider was being
    /// dragged, the watch refused to start, and after the drag nothing was
    /// left to hand the card back.
    @Test("A timeout during a drag is watched, and hands back once the drag ends")
    func timeoutDuringDrag() async throws {
        let f = Fixture()
        f.send(.hoverChanged(true))
        f.send(.hudRequested(1.4))
        f.adjusting = true
        f.send(.timerFired(.hud))
        try #require(f.state.phase == .hud && f.state.isHovering, "held under the pointer, mid-drag")
        f.pointerOnCard = true
        await Self.pump { f.watch.looks >= 2 }
        try #require(f.watch.looks >= 2, "looks ran during the drag")
        #expect(f.releases == 0, "nothing is handed back while the slider is held")

        // The drag ends with the pointer on the card: no hover event comes.
        f.adjusting = false
        await Self.pump { f.releases > 0 }
        #expect(f.releases == 1)
        #expect(f.state.phase == .hover)
    }

    /// Found by review (R2b): a readout still inside its own duration looks
    /// like a held one, and waking handed it back at once.
    @Test("Waking does not cut short a readout that has not reached its hold")
    func wakeKeepsAFreshReadout() async throws {
        let f = Fixture()
        f.send(.hoverChanged(true))
        f.send(.hudRequested(1.4))
        f.pointerOnCard = true
        try #require(ReadoutHandBack.isHeldOverCard(f.state), "over the card, under the pointer")
        try #require(!f.watch.isWatching, "and no timeout yet")

        f.watch.setDormant(true)
        f.watch.setDormant(false)
        #expect(!f.watch.isWatching)
        await Self.pump(0.15)
        #expect(f.releases == 0, "handed back before its own timeout")
        #expect(f.state.phase == .hud)

        // Its own timeout, then dark and back: an established hold resumes.
        f.send(.timerFired(.hud))
        f.watch.setDormant(true)
        f.watch.setDormant(false)
        #expect(f.watch.isWatching)
        await Self.pump { f.releases > 0 }
        #expect(f.state.phase == .hover)

        // A new request forgets the old hold, even across a dark spell.
        f.send(.hudRequested(1.4))
        try #require(f.state.phase == .hud)
        f.watch.setDormant(true)
        f.watch.setDormant(false)
        #expect(!f.watch.isWatching)
    }

    /// A second key while the first readout is still held: the new readout
    /// has its own duration, and a dark spell inside it must not cut it short.
    @Test("A repeat key over a held readout starts a fresh duration, kept through a wake")
    func repeatKeyOverAHeldReadout() async throws {
        let f = Fixture()
        f.holdReadoutOverCard()
        try #require(f.watch.isWatching, "the first readout is held and watched")
        f.send(.hudRequested(1.4))
        try #require(f.state.phase == .hud, "still a readout: the second key extended it")
        f.pointerOnCard = true
        f.watch.setDormant(true)
        f.watch.setDormant(false)
        #expect(!f.watch.isWatching)
        await Self.pump(0.15)
        #expect(f.releases == 0)
        #expect(f.state.phase == .hud)
    }

    @Test("Cancelled, it never looks again; adjusting, it never releases")
    func cancelAndAdjust() async throws {
        let f = Fixture()
        f.holdReadoutOverCard()
        try #require(f.watch.isWatching)
        f.watch.cancel()
        f.pointerOnCard = true
        await Self.pump(0.1)
        #expect(f.releases == 0)
        #expect(f.watch.looks == 0)

        let g = Fixture()
        g.holdReadoutOverCard()
        g.adjusting = true
        g.pointerOnCard = true
        await Self.pump { g.watch.looks >= 3 }
        try #require(g.watch.looks >= 3, "it kept looking through the drag")
        #expect(g.releases == 0, "a slider being dragged is never handed back")
        g.watch.cancel()
    }
}
