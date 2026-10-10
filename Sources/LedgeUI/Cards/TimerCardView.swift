import LedgeCore
import SwiftUI
import os

/// The Clock card: iOS's Clock in one place. A segmented header picks the
/// face — Timer or Stopwatch — and each face speaks its own iOS dialect: the
/// timer's ready card offers duration chips and its running card is the timer
/// Live Activity (session name in the accent, big light rounded countdown,
/// labelled capsule buttons); the stopwatch counts up in the same hero
/// position with laps beneath its name and Start/Stop in Clock's own green
/// and red.
public struct TimerCardView: View {

    private let payload: TimerPayload
    private let actions: TimerActions
    private let isCompactWidth: Bool
    private let fixedNow: Date?

    public init(
        payload: TimerPayload,
        onContentHeight: @escaping (CGFloat) -> Void = { _ in },
        actions: TimerActions = TimerActions(),
        isCompactWidth: Bool = false,
        // The gallery renders the faces that are otherwise only reachable by
        // clicking — a state nobody can review is a state that drifts.
        startsOnFace: Face? = nil,
        startsRulerOpen: Bool = false,
        /// A fixed clock, for the gallery. "Ends at 10:36" is the one piece of
        /// this card that changes with the wall clock, which would make every
        /// exported image differ from the last one for no reason. Same seam
        /// `CalendarExpandedView` already has.
        now: Date? = nil
    ) {
        self.payload = payload
        self.onContentHeight = onContentHeight
        self.actions = actions
        self.isCompactWidth = isCompactWidth
        _face = State(initialValue: startsOnFace)
        // The same seam the media card's output list has: a state reachable
        // only by clicking is a state no export can hold, and synthetic clicks
        // do not reach a non-activating panel.
        _isRulerOpen = State(initialValue: startsRulerOpen
            || ProcessInfo.processInfo.environment["LEDGE_SHOW_RULER"] == "1")
        self.fixedNow = now
    }

    /// Which face is showing. Seeded from the payload's own mode — a card
    /// that arrives wearing the stopwatch face opens on it — and switched by
    /// the header from then on.
    /// Tells the shell how tall this card's content is. See the body.
    private let onContentHeight: (CGFloat) -> Void

    @State private var face: Face?

    /// The length on the ready card. Seeded on first appearance from what this
    /// user reaches for, and kept afterwards: a length chosen and not yet
    /// started is still theirs when the card comes back.
    @State private var minutes = 25
    /// The value the drag started from, and whether Option is down. Held apart
    /// from `minutes` so the whole drag is one continuous movement from where
    /// it began rather than a chain of relative nudges that drift.
    @State private var scrubAnchor: Int?
    @State private var isFineScrubbing = false
    /// Whether the rule is showing under the number. The length survives
    /// closing it, so somebody who opens the rule, dials 40, thinks better of
    /// it and closes finds 40 rather than the default again.
    @State private var isRulerOpen: Bool
    /// Whether this card may hold the notch open at all.
    ///
    /// The rule tells the card when a drag ends, and it says so on the way out
    /// too — tearing down a half-finished drag is the same act as finishing
    /// one. Taken at face value that started a fresh grace *after* the card had
    /// been switched away from, and the notch then stayed open over whatever
    /// card came next. Which of the two disappearances SwiftUI delivers first
    /// is not ordered, so this makes both orders safe.
    @State private var hold = CardHold()
    @State private var isHoveringDuration = false
    @FocusState private var isFocusingDuration: Bool
    @State private var hasSeededDuration = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which face the card is wearing. Public because the gallery names one
    /// directly: a face reachable only by clicking is a face nobody reviews.
    public enum Face: Equatable, Sendable {
        case timer
        case focus
        case stopwatch
    }

    private var tint: Color { payload.isBreak ? .green : .orange }

    /// The face on show: the user's pick, else whichever face owns what is
    /// running.
    private var shownFace: Face { Self.face(for: payload, pick: face) }

    /// Which face a payload belongs to, and which one to show given a pick.
    ///
    /// A focus session is not a timer. It has its own face, its own cycle dots
    /// and its own pair of buttons, and showing its countdown on the Timer face
    /// as well meant the session appeared twice and the quick timer had nowhere
    /// to be started from while one was running.
    nonisolated static func face(for payload: TimerPayload, pick: Face?) -> Face {
        if let pick { return pick }
        return owner(of: payload) ?? .timer
    }

    /// The face something running belongs to, or nil when nothing is.
    nonisolated static func owner(of payload: TimerPayload) -> Face? {
        if payload.mode == .stopwatch { return .stopwatch }
        guard payload.hasCountdown || payload.isFinished else { return nil }
        // A quick timer is the Timer face's own; a pomodoro leg and the break
        // that follows it belong to Focus.
        return payload.isCustom ? .timer : .focus
    }

    public var body: some View {
        if isCompactWidth {
            // Duo mode gives no room for a header: the card wears the face
            // the payload does.
            if payload.mode == .stopwatch {
                stopwatchCompact
            } else if payload.isIdle {
                idle
            } else {
                compact
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SegmentPicker(selection: Binding(
                    get: { shownFace },
                    set: { face = $0 }
                ))
                switch shownFace {
                case .timer:
                    // Only this face's own work: a quick timer. A focus leg
                    // running elsewhere leaves the ready card here, so another
                    // timer can be set while a session is going.
                    if payload.isFinished && payload.isCustom {
                        finished
                    } else if payload.hasCountdown && payload.isCustom {
                        full
                    } else {
                        idle
                    }
                case .focus:
                    if payload.isFinished && !payload.isCustom {
                        finished
                    } else if payload.hasCountdown && !payload.isCustom {
                        full
                    } else {
                        focusReady
                    }
                case .stopwatch:
                    stopwatch
                }
            }
            .padding(.horizontal, 8)
            // Closer to the cutout than the other cards sit. The overlay
            // already holds every card clear of the physical notch by its full
            // height, so this padding is breathing room on top of a gap that
            // is guaranteed — and on the Clock card, with a segmented header
            // above two rows, that left an obvious band of nothing between the
            // hardware and the first thing worth reading.
            .padding(.top, 6)
            // Two. The card is measured *including* this, and the sizing then
            // holds the dots' own 12pt footprint underneath, so anything here
            // is added on top of a gap that already exists. The buttons end
            // just above the dots' band and the band does the separating.
            .padding(.bottom, 2)
            // The card is three faces of different heights and the header lets
            // the user move between them, so the shell cannot know how tall it
            // needs to be. It measures itself and says. Safe from feeding back
            // on itself: the open card keeps its natural height inside the
            // shape, with a spacer taking up whatever is left.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                onContentHeight(height)
            }
            // Whatever starts takes the card to its own face. A stale pick
            // must not leave a ready card showing over a live session — the
            // rule that used to be written for the stopwatch alone, and is
            // just as true of a focus leg begun from the menu.
            .onChange(of: Self.owner(of: payload)) { _, owner in
                if let owner { face = owner }
            }
            // Leaving the timer face ends any drag in flight and hands the
            // card back: a gesture nobody can see must not go on holding the
            // card open from behind another face.
            .onChange(of: shownFace) { _, _ in
                guard isRulerOpen || isAdjusting else { return }
                isRulerOpen = false
                hold.release()
                scrubAnchor = nil
                releaseCard()
            }
            .animation(Motion.medium, value: shownFace)
        }
    }

    // MARK: - Timer face

    /// The ready card: a length, the lengths this user actually starts, and one
    /// way to begin.
    ///
    /// Everything that was ever a *second* control for the length has come off
    /// — preset chips that also started the timer, a labelled "Change duration"
    /// button, a text field with a caret in it, a ruler that opened underneath.
    /// The value is the control: put the pointer on it and drag sideways.
    /// Nothing opens, nothing closes, and the card is exactly as tall while you
    /// are using it as it was before you touched it.
    private var idle: some View {
        // Spacing by hand rather than by the stack, because the rule's slot has
        // to collapse to nothing — the gap above it included — when it is shut.
        VStack(spacing: 0) {
            durationControl

            // No room for it beside the ears; the duo card is the number and
            // the one button, and the number still drags.
            if !isCompactWidth { rulerReveal }

            Spacer().frame(height: isCompactWidth ? 6 : 8)

            capsuleButton("Start", tint: tint, height: 34) { start(minutes) }
        }
        // Full width regardless of what is in it, so the number sits in the
        // middle of the card rather than in the middle of its own widest
        // sibling.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, isCompactWidth ? 12 : 0)
        .padding(.vertical, isCompactWidth ? 9 : 0)
        // Seeded once, from what this user reaches for. Not on every
        // appearance: a length chosen and not yet started is still theirs when
        // the card comes back.
        .onAppear {
            hold.appeared()
            guard !hasSeededDuration else { return }
            hasSeededDuration = true
            minutes = readyMinutes
        }
        // Escape shuts the rule and keeps the length, the way Escape closes
        // anything that opened.
        .onExitCommand {
            guard isRulerOpen else { return }
            setRuler(open: false)
        }
        .onDisappear {
            isRulerOpen = false
            scrubAnchor = nil
            // Marks the card gone *before* releasing, so a teardown from the
            // rule arriving afterwards is refused rather than re-latching.
            hold.disappeared()
            releaseCard(caller: "idle onDisappear")
        }
    }

    /// The rule, revealed by the card growing rather than by sliding in.
    ///
    /// A `.move` transition draws the rule *over* whatever is above it while it
    /// travels, so for a quarter of a second the ruler was on top of the
    /// duration it belongs to. This is a window that grows from nothing to the
    /// rule's own height, with the rule pinned to its top and everything
    /// outside it clipped: nothing is ever drawn where it does not belong, and
    /// the card's height is the window's height, so the panel grows with it.
    private var rulerReveal: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 8)
            DurationDialView(
                minutes: Binding(
                    get: { minutes },
                    set: { setMinutes(DurationDial.clamp($0)) }
                ),
                tint: tint,
                // The drag ending must not hand the card back while the rule is
                // still open: the pointer lifts between two drags of one
                // adjustment, and the card used to close underneath. The dial
                // guarantees this callback is balanced: `false` follows a real
                // `true`, never a collapsed view merely disappearing.
                setDragging: { dragging in
                    setRulerDragging(dragging)
                },
                haptic: actions.haptic
            )
        }
        .frame(height: isRulerOpen ? DurationDialView.height + 8 : 0, alignment: .top)
        .opacity(isRulerOpen ? 1 : 0)
        .clipped()
        .allowsHitTesting(isRulerOpen)
    }

    /// The duration, and the way to change it: one control, dragged sideways.
    ///
    /// There is no chevron. A disclosure arrow beside a number is an admission
    /// that the number does not look like a control, and the fix for that is to
    /// make it look like one: a filled shape it always wears, the left-right
    /// resize pointer over it, and the number moving under the hand the moment
    /// it does.
    private var durationControl: some View {
        HStack(spacing: 10) {
            // The button sits to one side, so the number would read off-centre
            // from the ruler's marker directly beneath it. A spacer of the
            // button's own width on the other side puts it back.
            if !isCompactWidth {
                Color.clear.frame(width: Self.chevronSize, height: Self.chevronSize)
            }

            duration

            if !isCompactWidth { rulerToggle }
        }
        // No background. The number is the biggest thing on the card and the
        // only white one; a filled slab behind it was competing with it for
        // the same job. The height is still spent here — a generous target to
        // drag, and what keeps the card at the 182pt it has always measured.
        .frame(height: isCompactWidth ? 38 : 50)
    }

    /// The length itself, which is also the coarse way to change it: drag it
    /// sideways.
    private var duration: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(minutes)")
                .font(.system(size: numberSize, weight: numberWeight, design: .rounded))
                .monospacedDigit()
                // Digits roll to their new value — up as the length grows, down
                // as it shrinks — instead of being swapped out underneath the
                // hand. It needs the change to happen inside an animation to
                // know which way it is going, which is why every place that
                // sets `minutes` wraps it.
                .contentTransition(.numericText(value: Double(minutes)))
                .foregroundStyle(.white)
                .lineLimit(1)
                // A fixed slot, wide enough for three digits. Without it the
                // number shifts as it crosses 9 and 99, and a thing that moves
                // under the hand dragging it is the one thing a scrubber must
                // never do.
                .frame(width: numberSize * 2, alignment: .trailing)
            Text("min")
                .font(.system(size: isCompactWidth ? 11 : 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 6)
        .frame(height: isCompactWidth ? 38 : 50)
        .contentShape(Rectangle())
        // macOS's own "this drags sideways" cursor, so the affordance is the
        // system's rather than a glyph this card invented.
        .pointerStyle(.columnResize)
        .gesture(scrub)
        // Option swaps the detents for one a minute, which is how the values
        // between them are reached. Read here rather than from the drag, so
        // holding it part-way through a drag changes the rate immediately.
        .onModifierKeysChanged(mask: .option) { _, held in
            isFineScrubbing = held.contains(.option)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timer length")
        .accessibilityValue(DurationDial.spoken(minutes))
        .accessibilityHint("Drag sideways to change")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(by: 1)
            case .decrement: nudge(by: -1)
            @unknown default: break
            }
        }
    }

    /// One button, for the one thing it does: show the rule and hide it again.
    ///
    /// It is also where the keyboard lives — focus it and the arrow keys move
    /// the length a minute at a time, which is the fine control the detents
    /// give up.
    private var rulerToggle: some View {
        Button { setRuler(open: !isRulerOpen) } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: Self.chevronSize, height: Self.chevronSize)
                .background(Circle().fill(.white.opacity(toggleFill)))
                .rotationEffect(.degrees(isRulerOpen ? 180 : 0))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isRulerOpen)
                .contentShape(Circle())
        }
        .buttonStyle(PressableCircleStyle())
        .onHover { isHoveringDuration = $0 }
        .animation(Motion.medium, value: isHoveringDuration)
        .focusable()
        // The system ring is drawn as a rectangle around the button and reads
        // as an error state on a black card; the fill says it instead.
        .focusEffectDisabled()
        .focused($isFocusingDuration)
        .onKeyPress(.leftArrow) { nudge(by: -1); return .handled }
        .onKeyPress(.rightArrow) { nudge(by: 1); return .handled }
        .onKeyPress(keys: [.upArrow]) { _ in nudge(by: 5); return .handled }
        .onKeyPress(keys: [.downArrow]) { _ in nudge(by: -5); return .handled }
        .accessibilityLabel(isRulerOpen ? "Hide the length rule" : "Change the length")
        .accessibilityValue(DurationDial.spoken(minutes))
    }

    /// Resting, hovered or open, focused. One button getting gradually more
    /// present, with no new colour introduced at any step — an accent ring
    /// around it would read as a warning, which is the opposite of focus.
    private var toggleFill: Double {
        if isFocusingDuration { return 0.24 }
        if isRulerOpen || isHoveringDuration { return 0.18 }
        return 0.12
    }

    private static let chevronSize: CGFloat = 22

    /// Whether an adjustment is in flight right now. The pointer lifts between
    /// two drags of one adjustment, so this is not the same question as
    /// whether the card may go.
    private var isAdjusting: Bool { hold.isAdjusting || scrubAnchor != nil }

    /// Accepts only balanced drag edges from the ruler.
    ///
    /// `DurationDialView` already promises that contract, but the timer is the
    /// component that turns an edge into a shell-wide hover latch. Enforcing it
    /// here too prevents any child teardown from turning a stray `false` into a
    /// fresh 2.5-second hold over the next card.
    private func setRulerDragging(_ dragging: Bool) {
        // Only a real edge counts. A teardown reports `false` without this card
        // ever having seen `true`, and that is cleanup, not a gesture ending.
        guard hold.adjustmentChanged(to: dragging) else { return }
        if dragging {
            holdCard(caller: "ruler drag began")
        } else {
            releaseCard(caller: "ruler drag ended")
        }
    }

    /// Keeps the card only while something is happening to the length.
    ///
    /// The open rule is deliberately *not* a reason to hold: a rule somebody
    /// opened and then left alone is not a conversation, and a card that can
    /// never be dismissed while it is showing is a trap.
    private static let holdLog = Logger(subsystem: "com.egemert.ledge", category: "hold")

    /// Says who is holding the notch and why, behind
    /// `defaults write com.egemert.ledge developer.trace.hold -bool true`.
    private func traceHold(_ what: String, caller: String) {
        guard DebugSwitches.tracing("hold") else { return }
        Self.holdLog.notice(
            """
            timer: \(what, privacy: .public) via \(caller, privacy: .public) \
            held=\(self.hold.isHeld, privacy: .public) \
            ruler=\(self.isRulerOpen, privacy: .public) \
            adjusting=\(self.isAdjusting, privacy: .public)
            """
        )
    }

    /// Holds the notch for the length of a gesture, and not a moment longer.
    ///
    /// There used to be a grace here — two and a half seconds after the last
    /// change, so the card survived the pointer lifting between two drags of
    /// one adjustment. It had to go, because it could not tell two situations
    /// apart:
    ///
    /// - While the pointer is **inside** the notch, hover already holds the
    ///   card open. The grace adds nothing and nobody can see it.
    /// - While the pointer is **outside**, the grace is the only thing holding
    ///   the notch — and it holds it over whatever card comes next, seconds
    ///   after the user has walked away.
    ///
    /// The only situation in which it was observable was the one in which it
    /// was wrong. So a hold now begins when a gesture begins and ends when the
    /// gesture ends. Nothing is scheduled, so nothing can outlive what it was
    /// scheduled for.
    private func holdCard(caller: String = #function) {
        traceHold("holdCard", caller: caller)
        guard hold.hold() else {
            traceHold("holdCard REFUSED (card is gone)", caller: caller)
            return
        }
        actions.setDragging(true)
    }

    /// Drops the hold, immediately.
    private func releaseCard(caller: String = #function) {
        traceHold("releaseCard", caller: caller)
        hold.release()
        actions.setDragging(false)
    }

    /// Opens or shuts the rule, with the motion that explains it: the card
    /// grows downward from a number that stays where it was.
    private func setRuler(open: Bool) {
        guard open != isRulerOpen else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { isRulerOpen = open }
        if !open { releaseCard(caller: "rule closed") }
        // Deliberately no hold. Opening the rule happens under the pointer, and
        // a pointer on the card is already what keeps the card open — a latch
        // here would add nothing except something able to outlive the gesture.
    }

    private var numberSize: CGFloat { isCompactWidth ? 22 : 34 }

    /// Light at size, the way every large figure on this card is set — the
    /// countdown hero included. Weight is how a number says how big it is, and
    /// a semibold 34 was shouting.
    private var numberWeight: Font.Weight { isCompactWidth ? .medium : .regular }

    // MARK: - Changing the length

    /// The whole adjustment: press, drag sideways, let go.
    private var scrub: some Gesture {
        // Zero minimum distance so the control answers the movement itself
        // rather than the movement plus a few points — a number that ignores
        // the first of a drag feels stuck rather than precise.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if scrubAnchor == nil {
                    scrubAnchor = minutes
                    // Latches the shell's hover, so the card cannot close under
                    // a pointer that has wandered off it mid-drag. The same
                    // latch the volume sliders use — and released the moment
                    // the hand lifts, in `endScrub`.
                    holdCard(caller: "scrub began")
                }
                let landed = DurationScrub.minutes(
                    anchor: scrubAnchor ?? minutes,
                    translation: value.translation.width,
                    fine: isFineScrubbing
                )
                guard landed != minutes else { return }
                setMinutes(landed)
                // One tick per detent, which is what makes a scrubbed number
                // feel like a dial with stops rather than a value sliding.
                actions.haptic()
            }
            .onEnded { _ in endScrub() }
    }

    /// The one place the length changes, so the digits roll the same way
    /// whichever control asked for it. A spring rather than an ease: a held
    /// key or a fast drag retargets it from wherever it already is, so a run of
    /// changes reads as one continuous movement instead of a queue of little
    /// ones.
    private func setMinutes(_ landed: Int) {
        withAnimation(reduceMotion ? nil : Motion.levelChange) { minutes = landed }
    }

    private func endScrub() {
        scrubAnchor = nil
        // The gesture is over, so the hold is over. If the pointer is still on
        // the card, hover keeps it open by itself; if it has left, the card
        // should go, and that is the whole point.
        releaseCard(caller: "scrub ended")
    }

    private func nudge(by delta: Int) {
        let landed = DurationDial.clamp(minutes + delta)
        guard landed != minutes else { return }
        setMinutes(landed)
        // No hold: a key press is not a gesture with an end, so a latch taken
        // here would have nothing to take it off again.
    }

    /// Starting is the same act however it was asked for, so it is one place:
    /// release the latch, then start.
    private func start(_ length: Int) {
        releaseCard()
        actions.startCustom(length)
    }

    /// What the card opens on before anything has been chosen: the length this
    /// user actually reaches for.
    private var readyMinutes: Int {
        TimerReadout.openingLength(
            recents: payload.recents,
            focusMinutes: Int(payload.total / 60)
        )
    }


    /// Focus sessions: the pomodoro pair, kept whole rather than scattered
    /// among quick timers. The cycle's own progress belongs here too.
    private var focusReady: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.orange.opacity(0.22)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Focus session")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(Int(payload.total / 60)) minutes, then a break")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
                if payload.completedSessions > 0 {
                    CycleDots(completed: payload.completedSessions, tint: .orange)
                }
            }

            HStack(spacing: 7) {
                capsuleButton("Start focus", tint: .orange, height: 34) { actions.startFocus() }
                capsuleButton("Break", tint: .green, height: 34) { actions.startBreak() }
            }
        }
    }

    private var compact: some View {
        HStack(spacing: 10) {
            TimerRing(progress: payload.progress, tint: tint, lineWidth: 3)
                .frame(width: 30, height: 30)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Timer")
                .accessibilityValue("\(TimerCardView.clock(payload.remaining)) remaining")
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.label)
                    .font(.cardSmallFigure)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Text(TimerCardView.clock(payload.remaining))
                    .font(.system(size: 17, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(payload.isRunning ? tint : tint.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    TimerRing(progress: payload.progress, tint: tint, lineWidth: 3.5)
                    Image(systemName: payload.isBreak ? "cup.and.saucer.fill" : "timer")
                        .font(.cardTitle)
                        .foregroundStyle(tint)
                }
                .frame(width: 40, height: 40)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Timer")
                .accessibilityValue("\(TimerCardView.clock(payload.remaining)) remaining")

                VStack(alignment: .leading, spacing: 3) {
                    Text(payload.label)
                        .font(.cardFigure)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    // Paused is said, not implied. The dimmed accent alone was
                    // the only sign, and a countdown that has simply stopped
                    // moving reads as a frozen app rather than a paused timer.
                    if !payload.isRunning {
                        Text("Paused")
                            .font(.cardCaption)
                            .foregroundStyle(.white.opacity(0.6))
                    } else if let ends = endsAtText {
                        // What the countdown means in the clock on the wall.
                        Text(ends)
                            .font(.cardCaption)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .accessibilityLabel("Ends at")
                            .accessibilityValue(ends)
                    }
                    if payload.completedSessions > 0 {
                        CycleDots(completed: payload.completedSessions, tint: tint)
                    }
                }

                Spacer(minLength: 10)

                // The hero: big, light, rounded, monospaced — the accent
                // fades when paused, exactly the cue iOS gives.
                Text(TimerCardView.clock(payload.remaining))
                    .font(.system(size: 42, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(payload.isRunning || payload.isFinished ? tint : tint.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityLabel("Time remaining")
                    .accessibilityValue(TimerCardView.clock(payload.remaining))
            }

            // The lock-screen Live Activity's own control row: labelled
            // capsules spanning the card, Cancel in the neutral wash, the
            // pause carrying the accent. Skip exists only inside a pomodoro
            // cycle — a one-off countdown has nowhere to skip to.
            // Pause is what this card is for; Cancel throws the timer away and
            // is drawn as the quieter thing it is, rather than as an equal
            // sharing the row with it.
            HStack(spacing: 8) {
                capsuleButton(payload.isRunning ? "Pause" : "Resume", tint: tint) {
                    actions.toggle()
                }
                if !payload.isCustom {
                    capsuleButton("Skip", tint: nil) { actions.skip() }
                }
                quietButton("Cancel") { actions.cancel() }
            }
        }
    }

    /// When the running countdown reaches zero, as a clock time.
    private var endsAtText: String? {
        guard payload.isRunning,
              TimerReadout.showsEndTime(remaining: payload.remaining),
              let end = TimerReadout.endsAt(remaining: payload.remaining, now: fixedNow ?? Date())
        else { return nil }
        return "Ends at \(Self.clockTime.string(from: end))"
    }

    /// The user's own clock format — a 24-hour region must not be shown 3:42 PM.
    private static let clockTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()

    /// A finished timer, and the two things worth doing about it.
    ///
    /// It used to wear the running card's controls — Cancel, Pause, Skip — for
    /// something with nothing left to pause or skip, and it cleared itself
    /// after twelve seconds whether or not anyone had looked. Finishing is its
    /// own state: say so, and offer the two things that follow it.
    private var finished: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(payload.label) done")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(Self.lengthSentence(payload.total))
                        .font(.cardCaption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                capsuleButton("Repeat", tint: nil) {
                    actions.startCustom(max(1, Int(payload.total / 60)))
                }
                capsuleButton("Done", tint: tint) { actions.dismissFinished() }
            }
        }
    }

    /// "25 minutes", for the line under a finished timer.
    static func lengthSentence(_ total: TimeInterval) -> String {
        let minutes = max(1, Int((total / 60).rounded()))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// A button that does not compete: the same target, without the wash
    /// behind it. For the action a card offers but does not recommend.
    private func quietButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .frame(height: 36)
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableCircleStyle())
    }

    /// The stopwatch's capsules, six points shorter than the timer's, and its
    /// hero six points smaller.
    ///
    /// The card's spare height is shared evenly above and below its content,
    /// so only half of anything taken out shows up as clearance at the bottom.
    /// Thirteen points come out between the two, which lifts the buttons about
    /// six clear of the page dots.
    private static let stopwatchButtonHeight: CGFloat = 30
    private static let stopwatchHeroSize: CGFloat = 36

    // MARK: - Stopwatch face

    /// iOS's Stopwatch in the Live-Activity frame: the name and the current
    /// lap on the leading side, the elapsed time as the hero — big, light,
    /// rounded, its centiseconds a size down — and Clock's own buttons: Lap
    /// or Reset in the neutral wash, Start in green, Stop in red.
    private var stopwatch: some View {
        let watch = payload.stopwatch
        return VStack(alignment: .leading, spacing: 10) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !watch.isRunning)) { context in
                let now = context.date.timeIntervalSinceReferenceDate
                let elapsed = watch.elapsed(at: now)
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Stopwatch")
                            .font(.cardFigure)
                            .foregroundStyle(watch.isRunning ? .white : .white.opacity(0.75))
                        if !watch.laps.isEmpty {
                            let lapDigits = Self.stopwatchClock(watch.currentLap(at: now))
                            Text("Lap \(watch.laps.count + 1) · \(lapDigits.main)\(lapDigits.fraction)")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 10)

                    let digits = Self.stopwatchClock(elapsed)
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text(digits.main)
                            .font(.system(size: Self.stopwatchHeroSize, weight: .light, design: .rounded))
                        Text(digits.fraction)
                            .font(.system(size: 19, weight: .light, design: .rounded))
                    }
                    .monospacedDigit()
                    .foregroundStyle(watch.isRunning || !watch.isActive ? .white : .white.opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Elapsed")
                    .accessibilityValue(digits.main + digits.fraction)
                }
            }

            HStack(spacing: 8) {
                if watch.isRunning {
                    capsuleButton("Lap", tint: nil, height: Self.stopwatchButtonHeight) {
                        actions.stopwatchLap()
                    }
                    capsuleButton("Stop", tint: .red, height: Self.stopwatchButtonHeight) {
                        actions.stopwatchToggle()
                    }
                } else {
                    capsuleButton(
                        "Reset", tint: nil, enabled: watch.isActive,
                        height: Self.stopwatchButtonHeight
                    ) {
                        actions.stopwatchReset()
                    }
                    capsuleButton("Start", tint: .green, height: Self.stopwatchButtonHeight) {
                        actions.stopwatchToggle()
                    }
                }
            }
        }
    }

    /// The duo-width stopwatch: name and elapsed, nothing else.
    private var stopwatchCompact: some View {
        let watch = payload.stopwatch
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !watch.isRunning)) { context in
            let digits = Self.stopwatchClock(watch.elapsed(at: context.date.timeIntervalSinceReferenceDate))
            HStack(spacing: 10) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stopwatch")
                        .font(.cardSmallFigure)
                        .foregroundStyle(.white.opacity(0.75))
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text(digits.main)
                            .font(.system(size: 17, weight: .light, design: .rounded))
                        Text(digits.fraction)
                            .font(.system(size: 11, weight: .light, design: .rounded))
                    }
                    .monospacedDigit()
                    .foregroundStyle(watch.isRunning ? .white : .white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// `m:ss` (or `h:mm:ss`) and the `.cc` centiseconds, split so the
    /// fraction can sit a size down beside the hero digits.
    static func stopwatchClock(_ seconds: TimeInterval) -> (main: String, fraction: String) {
        let sane = seconds.isFinite ? min(max(0, seconds), 359_999) : 0
        let whole = Int(sane)
        let cents = Int((sane - Double(whole)) * 100)
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        let main = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
        return (main, String(format: ".%02d", cents))
    }

    /// A labelled capsule spanning its share of the row — the lock-screen
    /// Live Activity's button shape.
    /// - Parameter height: the stopwatch asks for a shorter capsule than the
    ///   timer. Its row is two wide buttons where the timer's is three narrow
    ///   ones, and the wider pair read as crowding the page dots below even
    ///   though both rows end on the same pixel. Taking height out of the
    ///   capsule lifts its bottom edge without moving anything above it.
    private func capsuleButton(
        _ label: String,
        tint: Color?,
        enabled: Bool = true,
        height: CGFloat = 36,
        action: @escaping () -> Void
    ) -> some View {
        CardCapsuleButton(label, tint: tint, enabled: enabled, height: height, action: action)
    }

/// `m:ss`, or `h:mm:ss` past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        // Same clamp as ActivityCardView.clock: a hand-edited duration
        // preference must not trap the Int conversion.
        let sane = seconds.isFinite ? min(max(0, seconds), 31_536_000) : 0
        let total = Int(sane.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// The Live Activity's button, extracted so a second card can wear the same
/// one rather than redraw it.
///
/// Lifted out of `TimerCardView` unchanged — same font, same wash, same
/// target — when Keep Awake needed Start, End, Done and Resume. Two hand-kept
/// copies of a control is how two cards end up a point apart from each other.
struct CardCapsuleButton: View {

    private let label: String
    private let tint: Color?
    private let enabled: Bool
    private let height: CGFloat
    private let action: () -> Void

    init(
        _ label: String,
        tint: Color?,
        enabled: Bool = true,
        height: CGFloat = 36,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.tint = tint
        self.enabled = enabled
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.cardFigure)
                .foregroundStyle(tint ?? .white.opacity(0.9))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Capsule().fill((tint ?? .white).opacity(tint == nil ? 0.13 : 0.24)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableCircleStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// Press feedback for the round buttons: a quick sink, the way the Live
/// Activity's own circles respond, instead of the plain style's nothing.
struct PressableCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// What the timer card can ask the shell to do.
public struct TimerActions {
    public var toggle: () -> Void
    public var cancel: () -> Void
    public var skip: () -> Void
    public var startFocus: () -> Void
    public var startBreak: () -> Void
    /// A one-off countdown of the given minutes — the ready card's own Start,
    /// and its one-tap recent lengths.
    public var startCustom: (Int) -> Void

    /// One tick of the trackpad, as the duration crosses a detent. The card
    /// cannot do this itself: feedback is the shell's to give, and LedgeUI
    /// never imports AppKit.
    public var haptic: () -> Void
    /// Takes the completion card away — the "Done" a finished timer offers,
    /// so the card ends when the user says so rather than when it times out.
    public var dismissFinished: () -> Void

    /// Latches a drag in flight, so the card stays open while the pointer
    /// wanders off it — the same latch the volume sliders use. Without it,
    /// dialling a length is a race between the drag and the card closing under
    /// the pointer.
    public var setDragging: (Bool) -> Void

    /// The stopwatch face: start/stop, lap (while running), reset (while stopped).
    public var stopwatchToggle: () -> Void
    public var stopwatchLap: () -> Void
    public var stopwatchReset: () -> Void

    public init(
        toggle: @escaping () -> Void = {},
        cancel: @escaping () -> Void = {},
        skip: @escaping () -> Void = {},
        startFocus: @escaping () -> Void = {},
        startBreak: @escaping () -> Void = {},
        startCustom: @escaping (Int) -> Void = { _ in },
        haptic: @escaping () -> Void = {},
        setDragging: @escaping (Bool) -> Void = { _ in },
        dismissFinished: @escaping () -> Void = {},
        stopwatchToggle: @escaping () -> Void = {},
        stopwatchLap: @escaping () -> Void = {},
        stopwatchReset: @escaping () -> Void = {}
    ) {
        self.setDragging = setDragging
        self.dismissFinished = dismissFinished
        self.stopwatchToggle = stopwatchToggle
        self.stopwatchLap = stopwatchLap
        self.stopwatchReset = stopwatchReset
        self.toggle = toggle
        self.cancel = cancel
        self.skip = skip
        self.startFocus = startFocus
        self.startBreak = startBreak
        self.startCustom = startCustom
        self.haptic = haptic
    }
}

/// The countdown ring: a dim track with the elapsed portion drawn over it,
/// same weight and cap as `BatteryRing` so the compact language stays uniform.
struct TimerRing: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.slow, value: progress)
        }
    }
}

/// One dot per completed work session in the current cycle.
struct CycleDots: View {
    let completed: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(index < completed % 4 || (completed > 0 && completed % 4 == 0)
                          ? AnyShapeStyle(tint)
                          : AnyShapeStyle(.white.opacity(0.25)))
                    .frame(width: 5, height: 5)
            }
        }
    }
}

/// The Clock card's header: a two-segment capsule control in the dark
/// idiom — a faint track, a brighter capsule sliding under the chosen face,
/// glyph and name on each side. iOS's segmented control, tuned for the notch.
struct SegmentPicker: View {
    @Binding var selection: TimerCardView.Face
    @Namespace private var slot

    var body: some View {
        HStack(spacing: 2) {
            segment(.timer, symbol: "timer", title: "Timer")
            segment(.focus, symbol: "brain.head.profile", title: "Focus")
            segment(.stopwatch, symbol: "stopwatch", title: "Stopwatch")
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.09)))
        .frame(height: 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clock face")
    }

    private func segment(_ face: TimerCardView.Face, symbol: String, title: String) -> some View {
        let selected = selection == face
        return Button {
            guard selection != face else { return }
            withAnimation(Motion.medium) { selection = face }
        } label: {
            // The glyph goes before the word does.
            //
            // Three equal segments split whatever the card is, and the card is
            // narrower on a *bigger* Mac than on the reference one — the cutout
            // grows faster than the scale compensates, so 16-inch content is
            // laid out in 273 reference points where a 13-inch gets 283. At
            // that width "Stopwatch" came out "Stopwat…". Dropping the symbol
            // buys 17pt a segment, which is more than the word needs, and a
            // label nobody can read is worth less than a decoration nobody
            // misses.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.cardCaption)
                    Text(title)
                        .font(.cardSmallFigure)
                        .fixedSize()
                }
                Text(title)
                    .font(.cardSmallFigure)
                    .fixedSize()
            }
            .foregroundStyle(selected ? .white : .white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background {
                if selected {
                    Capsule()
                        .fill(.white.opacity(0.18))
                        .matchedGeometryEffect(id: "selected", in: slot)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
