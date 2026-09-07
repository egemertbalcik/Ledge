import Foundation

/// The phase transitions, as one pure function.
///
/// Nothing here touches AppKit, timers, or the clock: timing is expressed as
/// `NotchEffect.startTimer` and executed elsewhere. That is what makes the whole
/// interaction model testable without a WindowServer.
public enum NotchReducer {

    public static func reduce(
        _ state: inout NotchState,
        _ event: NotchEvent
    ) -> [NotchEffect] {
        switch event {

        case .hoverChanged(let isHovering):
            state.isHovering = isHovering
            return hoverChanged(&state, isHovering: isHovering)

        case .clicked:
            // Clicking a pinned overlay closes it again — the click is a toggle,
            // so there is always a way back without reaching for a gesture.
            if state.isPinned {
                return dismiss(&state)
            }
            state.isPinned = state.clickPins
            // With pinning off, a click still opens the overlay — under the
            // cursor, and only if the cursor is actually there. A synthetic
            // click without hover (debug hooks) must not strand a hover phase
            // with no exit.
            state.phase = state.clickPins
                ? .expanded
                : (state.isHovering ? .hover : restingPhase(state))
            state.suspended = nil
            // A pin taken without the cursor present (synthetic click, debug
            // hook) will never see the hover-exit that normally arms the
            // release — arm it here or the card sits open forever.
            if state.isPinned && !state.isHovering {
                return [.cancelTimer(.peek), .cancelTimer(.hud), .startTimer(.pinRelease, 4)]
            }
            return [.cancelTimer(.peek), .cancelTimer(.hud)]

        case .peekRequested(let duration):
            // A newly-arrived peek always takes over a transient phase, so a
            // Focus change shows even while a volume HUD or an earlier peek is
            // still on screen — the latest transient wins, immediately. Only a
            // hover or a pinned/expanded card (user-driven) is left alone.
            switch state.phase {
            case .idle, .companion, .peek:
                state.phase = .peek
                return [.startTimer(.peek, duration)]
            case .hud:
                // A HUD over a *pinned* card is still user-driven underneath:
                // taking it over would drop the owed restore and leak the pin
                // into `idle`, where it silently ate every later hover. A
                // *hovered* HUD is just as user-driven — the readout is held
                // open, possibly mid-slider-drag, and yanking it for a peek
                // breaks the very hold-open promise the hover made.
                guard !state.isPinned, !state.isHovering else { return [] }
                // Replace the HUD; a peek returns to the resting phase anyway, so
                // the HUD's pending restore is no longer owed.
                state.suspended = nil
                state.phase = .peek
                return [.cancelTimer(.hud), .startTimer(.peek, duration)]
            case .hover, .expanded:
                return []
            }

        case .nowPlayingChanged(let playing):
            state.hasNowPlaying = playing
            // Only re-settle from a resting phase; never yank the overlay out of
            // hover, expanded, a peek, or a HUD it still owes a restore to.
            if state.phase == .idle || state.phase == .companion {
                state.phase = restingPhase(state)
            }
            return []

        case .hudRequested(let duration, let fromCompanion):
            // Re-firing while a HUD is up extends it rather than stacking, and
            // must not overwrite the phase we still owe a restore to.
            if state.phase != .hud {
                state.suspended = state.phase
                state.phase = .hud
            }
            // A level key arriving over a readout opened from the ear makes it
            // the keys' readout from then on, and it leaves as one.
            state.hudFromCompanion = fromCompanion
            return [.cancelTimer(.peek), .startTimer(.hud, duration)]

        case .timerFired(.peek):
            guard state.phase == .peek else { return [] }
            state.phase = restingPhase(state)
            return []

        case .timerFired(.pinRelease):
            // Only meaningful if the card is still pinned and abandoned.
            guard state.phase == .expanded, !state.isHovering else { return [] }
            return dismiss(&state)

        case .timerFired(.hud):
            guard state.phase == .hud else { return [] }
            // Held open under the pointer for direct adjustment; the unhover
            // path arms a fresh timer when the pointer leaves.
            if state.isHovering { return [] }
            return retireHUD(&state)

        case .hudReleased:
            // The shell overrides the hover hold: a pointer merely parked on
            // the notch when the key was pressed, and unmoved since, was never
            // an adjustment. Same restore rules as the timer, hover or not.
            guard state.phase == .hud else { return [] }
            return retireHUD(&state)

        case .dismissed:
            return dismiss(&state)

        case .forceCollapse:
            // Keep whether music is playing so the overlay settles back into the
            // companion, not fully shut, once the disruption passes — and keep
            // the click-to-pin preference, which is configuration, not phase.
            // Rebuilding from defaults silently re-enabled pinning after every
            // display change until the user next touched a related setting.
            let playing = state.hasNowPlaying
            let pins = state.clickPins
            let hoverOpens = state.expandOnHover
            state = NotchState(hasNowPlaying: playing, clickPins: pins, expandOnHover: hoverOpens)
            state.phase = restingPhase(state)
            return NotchTimer.allCases.map { .cancelTimer($0) }
        }
    }

    private static func hoverChanged(
        _ state: inout NotchState,
        isHovering: Bool
    ) -> [NotchEffect] {
        // A pinned overlay ignores the cursor for phase changes — but not for
        // its own lifetime: the pointer leaving closes it, exactly as it
        // closes every other phase.
        guard !state.isPinned else {
            // A HUD can be up *over* the pin (volume keys while a card is
            // pinned). Its hold-under-the-pointer/restore-on-leave cycle must
            // keep running here too: this guard used to swallow the exit, so
            // the fired-and-consumed hud timer was never re-armed and the
            // readout sat on screen forever. The HUD owns the screen while it
            // is up, so the pin waits its turn rather than closing underneath.
            if state.phase == .hud {
                return isHovering
                    ? [.cancelTimer(.pinRelease), .cancelTimer(.hud)]
                    : [.startTimer(.hud, 0.8)]
            }
            if isHovering { return [.cancelTimer(.pinRelease)] }
            return dismiss(&state)
        }

        if isHovering {
            switch state.phase {
            case .idle, .peek, .companion:
                // With expand-on-hover off the cursor's presence is recorded
                // (clicks and pin-release depend on it) but nothing opens.
                guard state.expandOnHover else { return [] }
                state.phase = .hover
                return [.cancelTimer(.peek)]
            case .hud:
                // Hovering the readout holds it open so the level can be
                // adjusted directly with the pointer — it must not vanish or
                // morph into the card mid-reach.
                state.suspended = nil
                return [.cancelTimer(.hud)]
            case .hover, .expanded:
                // Returning to a pinned card cancels its pending auto-release.
                return [.cancelTimer(.pinRelease)]
            }
        }

        switch state.phase {
        case .hover:
            // Fall back to the companion if music is still playing, else shut.
            state.phase = restingPhase(state)
            return []
        case .hud:
            // A readout that came from the ear goes straight back to it. The
            // tail below would spend those eight hundred milliseconds drawing
            // it across the whole compact view — a shape it never had while
            // the pointer was on it.
            if state.hudFromCompanion { return retireHUD(&state) }
            // The pointer left an adjustable readout: give it a short tail then
            // let the ordinary timer path put things back.
            state.suspended = restingPhase(state)
            return [.startTimer(.hud, 0.8)]
        case .expanded:
            // The pointer left, so the card goes. It used to linger on a
            // four-second grace, which is the worst of both: long enough to
            // read as the notch being stuck, short enough to be no use to
            // anyone. Clicking dead space in a card is not a request for the
            // overlay to follow you across the screen.
            return dismiss(&state)
        case .idle, .peek, .companion:
            return []
        }
    }

    /// Retires the HUD: restores the phase it interrupted if that is still
    /// valid, else recomputes the resting phase. Shared by the HUD timer and
    /// the shell's parked-pointer release.
    private static func retireHUD(_ state: inout NotchState) -> [NotchEffect] {
        let restored = state.suspended ?? restingPhase(state)
        state.suspended = nil
        state.hudFromCompanion = false
        // The world may have moved while the HUD was up, so a restored phase
        // is only used if it is still valid:
        //
        // - `hover` requires the cursor to still be there.
        // - `peek` is timer-driven, and `hudRequested` cancelled that timer.
        //   Restoring it would leave the overlay open with nothing left to
        //   close it — no timer, not pinned, not hovered.
        // - `companion`/`idle` depend on whether music is *still* playing,
        //   which may have flipped while the HUD was up: restoring the
        //   parked value verbatim drew empty companion pills after a track
        //   ended mid-HUD. Recompute instead.
        let isStale = (restored == .hover && !state.isHovering)
            || restored == .peek
            || restored == .companion
            || restored == .idle
        state.phase = isStale ? restingPhase(state) : restored
        // A card restored under a pointer that is somewhere else was already
        // abandoned when the HUD took over — the exit that would have closed
        // it was swallowed while the readout held the phase. Close it now.
        if state.phase == .expanded && !state.isHovering {
            return dismiss(&state)
        }
        return []
    }

    private static func dismiss(_ state: inout NotchState) -> [NotchEffect] {
        state.isPinned = false
        state.suspended = nil
        state.hudFromCompanion = false
        state.phase = restingPhase(state)
        return NotchTimer.allCases.map { .cancelTimer($0) }
    }

    /// Where the overlay settles when nothing is holding it open: open under the
    /// cursor, the persistent companion while music plays, otherwise flush shut.
    private static func restingPhase(_ state: NotchState) -> NotchPhase {
        if state.isHovering && state.expandOnHover { return .hover }
        return state.hasNowPlaying ? .companion : .idle
    }
}
