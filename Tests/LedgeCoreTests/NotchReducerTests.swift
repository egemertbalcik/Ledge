import Foundation
import Testing

@testable import LedgeCore

@Suite("Notch reducer")
struct NotchReducerTests {

    /// Applies a sequence of events and returns the effects from the last one.
    @discardableResult
    private func run(
        _ state: inout NotchState,
        _ events: NotchEvent...
    ) -> [NotchEffect] {
        var effects: [NotchEffect] = []
        for event in events {
            effects = NotchReducer.reduce(&state, event)
        }
        return effects
    }

    // MARK: - Hover

    @Test("Hovering opens, leaving closes")
    func hoverOpensAndCloses() {
        var state = NotchState()
        run(&state, .hoverChanged(true))
        #expect(state.phase == .hover)
        run(&state, .hoverChanged(false))
        #expect(state.phase == .idle)
    }

    @Test("A pinned overlay ignores a peek arriving under it")
    func pinnedSurvivesPeek() {
        var state = NotchState()
        run(&state, .hoverChanged(true), .clicked, .peekRequested(2))
        #expect(state.phase == .expanded, "the card the user opened outranks the news")
        #expect(state.isPinned)
    }

    // MARK: - Click

    @Test("Clicking a pinned overlay closes it")
    func clickTogglesPin() {
        var state = NotchState()
        run(&state, .clicked)
        #expect(state.phase == .expanded)
        run(&state, .clicked)
        #expect(state.phase == .idle)
        #expect(!state.isPinned)
    }

    @Test("Unpinning while still hovering falls back to hover, not idle")
    func unpinFallsBackToHover() {
        var state = NotchState()
        run(&state, .hoverChanged(true), .clicked, .clicked)
        #expect(state.phase == .hover)
    }

    // MARK: - Peek

    @Test("Peek only interrupts an idle overlay")
    func peekOnlyFromIdle() {
        var state = NotchState()
        let effects = run(&state, .peekRequested(2))
        #expect(state.phase == .peek)
        #expect(effects == [.startTimer(.peek, 2)])

        var open = NotchState(phase: .expanded, isPinned: true)
        let ignored = NotchReducer.reduce(&open, .peekRequested(2))
        #expect(open.phase == .expanded)
        #expect(ignored.isEmpty)
    }

    @Test("Peek expires back to idle")
    func peekExpires() {
        var state = NotchState()
        run(&state, .peekRequested(2), .timerFired(.peek))
        #expect(state.phase == .idle)
    }

    @Test("Hovering during a peek promotes it and cancels the timer")
    func hoverDuringPeek() {
        var state = NotchState()
        run(&state, .peekRequested(2))
        let effects = run(&state, .hoverChanged(true))
        #expect(state.phase == .hover)
        #expect(effects.contains(.cancelTimer(.peek)))
    }

    // MARK: - HUD

    @Test("The HUD preempts, remembers, and does not restore a card nobody is on")
    func hudRestoresPreviousPhase() {
        var state = NotchState()
        run(&state, .clicked)
        #expect(state.phase == .expanded)

        run(&state, .hudRequested(1))
        #expect(state.phase == .hud)
        #expect(state.suspended == .expanded, "what to come back to is remembered")

        run(&state, .timerFired(.hud))
        // Nothing restores onto an absent pointer: with the card abandoned,
        // handing it back would leave the overlay open with no way out.
        #expect(state.phase == .idle)
        #expect(state.suspended == nil)
    }

    @Test("Re-firing the HUD extends it without losing the restore target")
    func hudReFireKeepsRestoreTarget() {
        var state = NotchState()
        run(&state, .clicked, .hudRequested(1))
        let effects = run(&state, .hudRequested(1))
        #expect(state.suspended == .expanded)
        #expect(effects.contains(.startTimer(.hud, 1)))
    }

    @Test("The HUD does not restore to hover if the cursor has since left")
    func hudDoesNotRestoreStaleHover() {
        var state = NotchState()
        run(&state, .hoverChanged(true), .hudRequested(1))
        #expect(state.suspended == .hover)

        // Cursor leaves while the readout is up.
        run(&state, .hoverChanged(false))
        run(&state, .timerFired(.hud))
        #expect(state.phase == .idle)
    }

    @Test("Hovering a HUD holds it open for adjustment; leaving releases it")
    func hoverDuringHudHoldsIt() {
        var state = NotchState()
        run(&state, .hudRequested(1))
        #expect(state.suspended == .idle)
        // Hover holds the readout so the pointer can drag its bar.
        let held = run(&state, .hoverChanged(true))
        #expect(state.phase == .hud)
        #expect(held.contains(.cancelTimer(.hud)))
        // Even a stray timer must not take it away mid-adjustment.
        run(&state, .timerFired(.hud))
        #expect(state.phase == .hud)
        // Leaving arms a short tail, and the tail then opens the hover card
        // only if the cursor came back — here it closes.
        let released = run(&state, .hoverChanged(false))
        #expect(released.contains(.startTimer(.hud, 0.8)))
        run(&state, .timerFired(.hud))
        #expect(state.phase == .idle)
    }

    @Test("A stale timer for a phase that already ended is ignored")
    func staleTimerIgnored() {
        var state = NotchState()
        run(&state, .clicked)
        let effects = NotchReducer.reduce(&state, .timerFired(.hud))
        #expect(state.phase == .expanded)
        #expect(effects.isEmpty)
    }

    // MARK: - Preempting transients

    @Test("A peek takes over a visible HUD, and returns to rest after")
    func peekPreemptsHUD() {
        var state = NotchState()
        run(&state, .hudRequested(1))
        #expect(state.phase == .hud)
        // A Focus arrival mid-HUD must still show, not be dropped.
        let effects = run(&state, .peekRequested(2))
        #expect(state.phase == .peek)
        #expect(effects.contains(.cancelTimer(.hud)))
        #expect(effects.contains(.startTimer(.peek, 2)))
        // And the HUD's owed restore is cleared, so the peek settles to rest.
        run(&state, .timerFired(.peek))
        #expect(state.phase == .idle)
    }

    @Test("A second peek re-triggers even while the first is showing")
    func peekReTriggersOverPeek() {
        var state = NotchState()
        run(&state, .peekRequested(2))
        #expect(state.phase == .peek)
        let effects = run(&state, .peekRequested(2))
        #expect(state.phase == .peek)
        #expect(effects.contains(.startTimer(.peek, 2)))
    }

    @Test("An active card is not yanked away by a peek")
    func peekDoesNotInterruptExpanded() {
        var state = NotchState()
        run(&state, .clicked)               // pinned/expanded
        run(&state, .peekRequested(1))
        #expect(state.phase == .expanded)
    }

    // MARK: - Now Playing companion

    @Test("Music rests in the companion; stopping it closes the notch")
    func companionRestsWhilePlaying() {
        var state = NotchState()
        run(&state, .nowPlayingChanged(true))
        #expect(state.phase == .companion)
        // Hovering the companion opens the full card, leaving returns to it.
        run(&state, .hoverChanged(true))
        #expect(state.phase == .hover)
        run(&state, .hoverChanged(false))
        #expect(state.phase == .companion)
        // Music stops → shut.
        run(&state, .nowPlayingChanged(false))
        #expect(state.phase == .idle)
    }

    @Test("A HUD over the companion restores to the companion")
    func hudRestoresToCompanion() {
        var state = NotchState()
        run(&state, .nowPlayingChanged(true))
        run(&state, .hudRequested(1))
        #expect(state.phase == .hud)
        run(&state, .timerFired(.hud))
        #expect(state.phase == .companion)
    }

    // MARK: - Pin release

    @Test("The pointer leaving a pinned card closes it there and then")
    func pinnedCardClosesOnExit() {
        var state = NotchState()
        run(&state, .hoverChanged(true), .clicked)
        #expect(state.phase == .expanded)
        // The card followed the pointer off the notch for four seconds, which
        // read as the notch being stuck rather than as anything deliberate.
        run(&state, .hoverChanged(false))
        #expect(state.phase == .idle)
        #expect(state.isPinned == false)
    }

    @Test("Music underneath still takes the island back when the card closes")
    func exitFallsBackToTheCompanion() {
        var state = NotchState(hasNowPlaying: true)
        run(&state, .hoverChanged(true), .clicked)
        run(&state, .hoverChanged(false))
        #expect(state.phase == .companion, "closing is not the same as going dark")
    }

    // MARK: - Collapse

    @Test("Force collapse resets everything and cancels every timer")
    func forceCollapseResets() {
        var state = NotchState()
        run(&state, .hoverChanged(true), .clicked, .hudRequested(1))
        let effects = run(&state, .forceCollapse)
        #expect(state == NotchState())
        #expect(effects.contains(.cancelTimer(.peek)))
        #expect(effects.contains(.cancelTimer(.hud)))
    }
}

/// Round-one hunt pins: the hovered HUD's hold-open promise, and
/// expand-on-hover living in the reducer rather than as an event-stream gate.
@Suite("Reducer hunt regressions")
struct ReducerHuntRegressionTests {

    @Test("A parked-pointer release retires a held HUD to the resting phase")
    func hudReleasedRetiresHeldHUD() {
        // Expand-on-hover off: the parked pointer opened nothing, so the HUD
        // has only the resting phase to go back to.
        var state = NotchState(expandOnHover: false)
        _ = NotchReducer.reduce(&state, .hoverChanged(true))   // pointer already parked
        _ = NotchReducer.reduce(&state, .hudRequested(1.5))
        #expect(NotchReducer.reduce(&state, .timerFired(.hud)).isEmpty)
        #expect(state.phase == .hud, "the timer alone yields to the hover")
        _ = NotchReducer.reduce(&state, .hudReleased)
        #expect(state.phase == .idle, "the shell's release overrides the hold")
        #expect(state.isHovering, "the pointer is still physically there")
    }

    @Test("A release restores an interrupted hovered card, and is a no-op outside the HUD")
    func hudReleasedRestoresAndNoOps() {
        var state = NotchState()
        _ = NotchReducer.reduce(&state, .hoverChanged(true))
        #expect(state.phase == .hover)
        _ = NotchReducer.reduce(&state, .hudRequested(1.5))
        _ = NotchReducer.reduce(&state, .hudReleased)
        #expect(state.phase == .hover, "the card the key interrupted comes back")
        let effects = NotchReducer.reduce(&state, .hudReleased)
        #expect(effects.isEmpty)
        #expect(state.phase == .hover)
    }

    @Test("A HUD over a pinned card hands the card back when it goes")
    func hudOverPinHandsBack() {
        var state = NotchState()
        _ = NotchReducer.reduce(&state, .hoverChanged(true))
        _ = NotchReducer.reduce(&state, .clicked)
        _ = NotchReducer.reduce(&state, .hudRequested(1.5))
        #expect(state.phase == .hud)
        _ = NotchReducer.reduce(&state, .hudReleased)
        #expect(state.phase == .expanded, "the pointer never left; the card is still wanted")
        #expect(state.isPinned)
    }

    /// The readout owns the screen while it is up, so a pointer that leaves
    /// mid-HUD does not pull the card out from under it — but once the HUD
    /// retires there is nothing left to hold the card open either.
    @Test("A pointer that leaves during a HUD closes the card behind it")
    func hudDefersTheClose() {
        var state = NotchState()
        _ = NotchReducer.reduce(&state, .hoverChanged(true))
        _ = NotchReducer.reduce(&state, .clicked)
        _ = NotchReducer.reduce(&state, .hudRequested(1.5))
        _ = NotchReducer.reduce(&state, .hoverChanged(false))
        #expect(state.phase == .hud)
        _ = NotchReducer.reduce(&state, .hudReleased)
        #expect(state.phase == .idle)
        #expect(state.isPinned == false)
    }

    @Test("A hovered HUD is not yanked away by a peek")
    func hoveredHUDKeepsTheStage() {
        var state = NotchState()
        _ = NotchReducer.reduce(&state, .hudRequested(1.5))
        _ = NotchReducer.reduce(&state, .hoverChanged(true))
        let effects = NotchReducer.reduce(&state, .peekRequested(2))
        #expect(state.phase == .hud, "mid-adjustment the readout must hold")
        #expect(effects.isEmpty)
    }

    @Test("With expand-on-hover off, hovering records but does not open")
    func hoverOffStillTracksCursor() {
        var state = NotchState(expandOnHover: false)
        _ = NotchReducer.reduce(&state, .hoverChanged(true))
        #expect(state.phase == .idle, "nothing opens")
        #expect(state.isHovering, "but the cursor's presence is truth, not preference")
    }

    @Test("With expand-on-hover off, a click still opens and leaving still closes")
    func hoverOffClickStillWorks() {
        var state = NotchState(expandOnHover: false)
        _ = NotchReducer.reduce(&state, .hoverChanged(true))
        _ = NotchReducer.reduce(&state, .clicked)
        #expect(state.phase == .expanded)
        #expect(state.isPinned)
        _ = NotchReducer.reduce(&state, .hoverChanged(false))
        #expect(state.phase == .idle, "the only way in is a click; the way out is walking away")
    }

    /// The one card that still needs a timer: opened with no cursor on the
    /// notch at all, there is no exit event coming to close it.
    @Test("A pin taken without hover arms its own release")
    func syntheticPinArmsRelease() {
        var state = NotchState()
        let effects = NotchReducer.reduce(&state, .clicked)
        #expect(state.phase == .expanded)
        #expect(effects.contains(.startTimer(.pinRelease, 4)),
                "no cursor means no hover-exit will ever arm it later")
    }

    @Test("Timers never restore a hover the preference forbids")
    func restingPhaseRespectsPreference() {
        var state = NotchState(hasNowPlaying: false, expandOnHover: false)
        _ = NotchReducer.reduce(&state, .hoverChanged(true))
        _ = NotchReducer.reduce(&state, .peekRequested(2))
        _ = NotchReducer.reduce(&state, .timerFired(.peek))
        #expect(state.phase == .idle, "a retired peek must not strand an open hover")
    }
}

@Suite("A readout opened from the ear leaves the way it arrived")
struct CompanionHUDTests {

    private func run(_ state: inout NotchState, _ events: NotchEvent...) {
        for event in events { _ = NotchReducer.reduce(&state, event) }
    }

    /// Hovering the readout beside the music opens its panel; walking away
    /// used to hold it across the whole compact view for eight hundred
    /// milliseconds on the way out — a shape it never had on the way in.
    @Test("Leaving hands the island straight back to the companion")
    func companionHUDDoesNotTakeTheBarOnExit() {
        var state = NotchState(hasNowPlaying: true)
        run(&state, .hoverChanged(true))
        let effects = NotchReducer.reduce(&state, .hudRequested(1.4, fromCompanion: true))
        #expect(state.phase == .hud)
        #expect(state.hudFromCompanion)
        #expect(effects.contains(.startTimer(.hud, 1.4)))

        let leaving = NotchReducer.reduce(&state, .hoverChanged(false))
        #expect(state.phase == .companion, "no tail: the music has the island back at once")
        #expect(state.hudFromCompanion == false)
        #expect(!leaving.contains(.startTimer(.hud, 0.8)))
    }

    @Test("A readout raised by the keys still gets its tail")
    func keyHUDKeepsItsTail() {
        var state = NotchState(hasNowPlaying: true)
        run(&state, .hudRequested(1.4), .hoverChanged(true))
        #expect(state.hudFromCompanion == false)
        let leaving = NotchReducer.reduce(&state, .hoverChanged(false))
        #expect(state.phase == .hud, "you may be coming back to it")
        #expect(leaving.contains(.startTimer(.hud, 0.8)))
    }

    /// Pressing a level key over a readout opened from the ear makes it the
    /// keys' readout, and it leaves as one.
    @Test("A key press promotes it to a full readout")
    func keyPressPromotes() {
        var state = NotchState(hasNowPlaying: true)
        run(&state, .hoverChanged(true), .hudRequested(1.4, fromCompanion: true))
        run(&state, .hudRequested(1.4))
        #expect(state.hudFromCompanion == false)
        let leaving = NotchReducer.reduce(&state, .hoverChanged(false))
        #expect(leaving.contains(.startTimer(.hud, 0.8)))
    }

    @Test("Dismissing forgets where the readout came from")
    func dismissClearsTheOrigin() {
        var state = NotchState(hasNowPlaying: true)
        run(&state, .hoverChanged(true), .hudRequested(1.4, fromCompanion: true), .dismissed)
        #expect(state.hudFromCompanion == false)
    }
}
