import LedgeCore
import SwiftUI

/// The Keep Awake card: one surface with three faces.
///
/// Ready is a launcher — a length to set and a Start — and it wears the timer
/// card's own instrument for the length, because dragging a number sideways is
/// already how a duration is set in this app and a second way to do it would
/// be a second thing to learn. Running is the Live Activity shape the timer
/// uses: what is left, what time that is, and the one button that stops it.
/// Finished is a sentence and the two things that follow it.
///
/// Nothing here is said in colour alone. The tint marks Keep Awake's identity,
/// never its state: whether a session is running, over, or refused is always
/// written out — which is what makes the card readable with Increase Contrast
/// on, and the only version of it worth shipping anyway.
public struct KeepAwakeCardView: View {

    private let payload: KeepAwakePayload
    private let actions: KeepAwakeActions
    private let isCompactWidth: Bool

    /// The length on the Ready card. Seeded from the payload — which carries
    /// the user's own default — and kept afterwards, so a length chosen and
    /// not yet started is still theirs when the card comes back.
    @State private var minutes: Int
    /// What the three boxes hold while the card is asking. Starts empty: the
    /// question is "how long", and a number already in the boxes is an answer
    /// nobody gave.
    @State private var draft = KeepAwakeSpan(days: 0, hours: 0, minutes: 0)
    /// The value the drag started from, and whether Option is down. Held apart
    /// from `minutes` so the whole drag is one movement from where it began
    /// rather than a chain of relative nudges that drift. Same seam the timer's
    /// scrub has, for the same reason.
    /// The field the keyboard and VoiceOver are on, so the length is settable
    /// without the drag the sighted card is built around.
    @State private var focusedField: KeepAwakeSpan.Field = .minutes
    /// Real focus, not a drawing of it. The border used to follow
    /// `focusedField` alone, which meant the card showed a focus ring for a
    /// keyboard that was never going to be asked.
    @FocusState private var keyboardField: KeepAwakeSpan.Field?
    @State private var hold = CardHold()
    /// Where a vertical drag started, and on which number.
    @State private var dragAnchor: Int?
    @State private var draggingField: KeepAwakeSpan.Field?
    /// The number the user is on: touched or being dragged. Its neighbours are
    /// shown while it is, which is how the column says which way to drag.
    @State private var activeField: KeepAwakeSpan.Field?
    /// Whether Start has been pressed and the card is now asking how long.
    ///
    /// Nothing is held yet. The first press turns the card into the question;
    /// the second answers it. Keeping the length off the resting card is what
    /// makes it one thing to read rather than a form.
    @State private var isAsking = false
    /// Whether the user has reached for the lid-closed mode and been told why
    /// it cannot start. Held on the card rather than in the payload because it
    /// is a fact about this reading of this card — it goes when the card does.
    @State private var lidNote = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// - Parameter startsAsking: opens straight onto the length, which is how
    ///   a rendering test photographs the second face without a press.
    public init(
        payload: KeepAwakePayload,
        actions: KeepAwakeActions = KeepAwakeActions(),
        isCompactWidth: Bool = false,
        startsAsking: Bool = false,
        draft: KeepAwakeSpan = KeepAwakeSpan(days: 0, hours: 0, minutes: 0),
        /// Which number is touched, for a rendering test that photographs the
        /// neighbours without a pointer.
        activeField: KeepAwakeSpan.Field? = nil,
        /// Opens with the lid-closed mode's reason already shown, which is
        /// otherwise a press away.
        lidNote: Bool = false
    ) {
        self.payload = payload
        self.actions = actions
        self.isCompactWidth = isCompactWidth
        _isAsking = State(initialValue: startsAsking)
        _draft = State(initialValue: draft)
        _activeField = State(initialValue: activeField)
        _lidNote = State(initialValue: lidNote)
        _minutes = State(initialValue: KeepAwakeReducer.clamp(minutes: payload.minutes))
    }

    /// Keep Awake's own tan. Warm rather than alarming: nothing is wrong when
    /// this card is up, the Mac is simply being held open.
    static let tint = Color(red: 0.72, green: 0.56, blue: 0.38)

    public var body: some View {
        content
            // A drag that was still latched when the card went away left the
            // notch held open by a control that no longer exists. The latch is
            // the shell's, so only the shell can let it go — and the card
            // disappearing is the last moment it can say so.
            .onDisappear {
                hold.release()
                actions.setDragging(false)
            }
    }

    @ViewBuilder private var content: some View {
        if isCompactWidth {
            compact
        } else {
            Group {
                switch payload.phase {
                case .ready: ready
                case .running: running
                case .finished(let reason): finished(reason)
                }
            }
            // The same inset the notes and shelf cards use. This card had
            // none, so its content ran to the edges while every one beside it
            // was held off them. The card's own width is set by the island and
            // does not move with this.
            .padding(.horizontal, Self.contentInset)
            .padding(.top, Self.topInset)
            .padding(.bottom, Self.bottomInset)
        }
    }

    /// Shared with the cards either side of this one, so a swipe between them
    /// does not step the content in and out.
    private static let contentInset: CGFloat = 10
    private static let topInset: CGFloat = 8
    /// The dots' own strip is added by the geometry (`dotsBand`), not here —
    /// reserving it in both places counted it twice and left a band of black
    /// under the button.
    private static let bottomInset: CGFloat = 14

    // MARK: - Ready

    private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                glyph
                VStack(alignment: .leading, spacing: 3) {
                    Text(KeepAwakeCopy.title)
                        .font(.cardFigure)
                        .foregroundStyle(Self.tint)
                        .lineLimit(1)
                    // The question names the mode it belongs to. The boxes
                    // below are the lid-closed mode's length and nothing
                    // else's, and this line is the only thing that says so.
                    Text(isAsking ? KeepAwakeCopy.howLongLidClosed : readyLine)
                        .font(.cardCaption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(KeepAwakeCopy.title), ready")
            .accessibilityValue(isAsking ? KeepAwakeCopy.howLongLidClosed : readyLine)

            // The length only once it has been asked for, on its own line
            // with the whole width to itself — which is what stops a seven-day
            // span from being squeezed against the title and truncated.
            if isAsking {
                VStack(spacing: 6) {
                    length
                    // Said, not enforced in silence. The card used to accept
                    // one minute and start five.
                    Text(lengthNote)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                if isAsking {
                    // A question has to be answerable with "never mind". The
                    // quiet seat, the same one Done takes on the finished
                    // card.
                    CardCapsuleButton(KeepAwakeCopy.cancel, tint: nil) {
                        hold.release()
                        actions.setDragging(false)
                        isAsking = false
                    }
                    // Nothing to start until a number has been put in. Saying
                    // so by disabling the button is quieter than starting a
                    // five-minute session nobody asked for.
                    CardCapsuleButton(
                        KeepAwakeCopy.keepAwake, tint: Self.tint, enabled: !draft.isEmpty
                    ) {
                        hold.release()
                        actions.setDragging(false)
                        // Shown before it is started: a card that displays one
                        // minute and starts five has told the user something
                        // untrue, however briefly.
                        let startable = draft.startableMinutes
                        setDraft(KeepAwakeSpan(unclamped: startable))
                        isAsking = false
                        // The length belongs to this mode alone, so this is
                        // the only button that sends one.
                        actions.startLidClosed(startable)
                    }
                } else {
                    CardCapsuleButton(KeepAwakeCopy.start, tint: Self.tint) {
                        // No question to ask: the card is a switch, and this
                        // holds until it is switched off. The length picker
                        // belongs to the lid-closed mode, where a deadline is
                        // what bounds a privileged hold.
                        lidNote = false
                        actions.switchOn()
                    }
                    // The subordinate mode. Narrower, shorter, and untinted:
                    // it is the same feature with a second condition attached,
                    // not a second feature, and two capsules of equal weight
                    // would make the user choose before they know there is a
                    // choice. The tint is this card's primary mark, so Start
                    // keeps it and the width that goes with it.
                    CardCapsuleButton(KeepAwakeCopy.lidClosed, tint: nil, height: 32) {
                        guard payload.lid.mayArm else {
                            // Pressable even when it cannot arm, because a
                            // disabled button explains nothing. The press
                            // puts the reason on the line above, where the
                            // user was already looking.
                            withAnimation(reduceMotion ? nil : Motion.levelChange) {
                                lidNote = true
                            }
                            return
                        }
                        lidNote = false
                        withAnimation(reduceMotion ? nil : Motion.levelChange) {
                            isAsking = true
                        }
                    }
                    .frame(maxWidth: Self.subordinateButtonWidth)
                }
            }
        }
        // A card that goes away mid-question comes back resting rather than
        // half-asked.
        .onDisappear {
            isAsking = false
            lidNote = false
        }
    }

    /// How much of the row the subordinate mode may take.
    ///
    /// A ceiling rather than a fixed width, so a narrower card still fits:
    /// Start takes whatever is left, which is what makes the pair read as a
    /// primary and a secondary rather than as two equal choices.
    private static let subordinateButtonWidth: CGFloat = 110

    /// The small line under the length boxes.
    ///
    /// Three things to say and one line to say them in, in the order the user
    /// meets them: how to work the control, then the floor it will be held to,
    /// then what the session will actually do.
    private var lengthNote: String {
        if draft.isEmpty { return KeepAwakeCopy.boxHint }
        if draft.totalMinutes < KeepAwakeReducer.minimumMinutes {
            return KeepAwakeCopy.minimumLength
        }
        return KeepAwakeCopy.lidEndsAt(floor: payload.batteryFloor)
    }

    /// What the lid-closed mode has to say for itself on the Ready card, if
    /// anything.
    ///
    /// A refusal and an unconfirmed hold say themselves: something happened,
    /// and the user is owed the reason without having to ask. "Not set up" and
    /// "this build can't" do not, because they would then be the standing line
    /// on every card for every user who has not set it up — a setup prompt
    /// shouted at somebody who only wanted the switch. Those wait for the
    /// press that reaches for the mode.
    private var lidLine: String? {
        switch payload.lid {
        case .off, .holding: nil
        case .unconfirmed, .refused: KeepAwakeCopy.lid(payload.lid)
        case .notInstalled, .unsignedBuild: lidNote ? KeepAwakeCopy.lid(payload.lid) : nil
        }
    }

    /// What the Ready card says under the title: whatever went wrong last
    /// time, else whatever the lid-closed mode has to say, else what closing
    /// the lid will do.
    ///
    /// A failure outranks the standing line because it is the answer to the
    /// question the user is about to ask — they pressed Start and nothing
    /// happened. It outranks the lid line for the same reason and in the same
    /// direction: a session that would not start at all is the larger fact,
    /// and in practice the two cannot both be fresh, because the lid is only
    /// ever armed behind a session that has already started.
    private var readyLine: String {
        switch payload.problem {
        case .assertionRefused: KeepAwakeCopy.assertionRefused
        case .startNotSaved: KeepAwakeCopy.startNotSaved
        case .tooManyUnsaved: KeepAwakeCopy.tooManyUnsaved
        case .journalUnreadable: KeepAwakeCopy.journalUnreadable
        case nil:
            lidLine ?? (payload.lidHeld
                ? KeepAwakeCopy.readyLidHeld(floor: payload.batteryFloor)
                : KeepAwakeCopy.readyLidOpen)
        }
    }

    /// The length, as three boxes to fill in.
    ///
    /// One number across the card ran out of room the moment days were added
    /// — the card is 275 points wide, not the 340 it is tempting to design
    /// against, and a seven-day span was being truncated to "3d 02h …m". Three
    /// boxes share that width evenly instead, and each one is small enough to
    /// stay legible at the size the island actually gives it.
    ///
    /// Each box is its own target: drag it sideways, or focus it and use the
    /// arrow keys. They start empty, so what is on screen is always something
    /// the user put there.
    /// The length, as three rows of AppKit's own stepper.
    ///
    /// This was a row of boxes you dragged sideways. Dragging a number is the
    /// gesture the timer card uses and it reads well there, but here it never
    /// reached the user: the only way to find it was to be told, and on this
    /// card it did not respond at all. A stepper is the control macOS already
    /// uses for "a number, up or down" — it is clickable without instruction,
    /// it takes the keyboard for free, and VoiceOver knows what it is.
    /// The length: days, hours and minutes side by side, each set by dragging
    /// it up or down.
    ///
    /// Three rows with their own plus and minus buttons said what to do, but
    /// they said it in six controls where the card has room for three numbers.
    /// This is the shape the value already has — d h m, left to right — and
    /// the gesture is the one the timer's duration uses, turned on its side so
    /// up is more.
    ///
    /// Touching a number shows the one before and the one after it, faintly,
    /// above and below. That is the whole affordance: a column of numbers you
    /// are in the middle of, so which way to drag needs no caption. The space
    /// for them is always reserved, so the card does not change height when
    /// one is touched.
    private var length: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(KeepAwakeSpan.Field.allCases, id: \.self) { unit in
                wheel(unit)
            }
        }
    }

    @ViewBuilder private func wheel(_ field: KeepAwakeSpan.Field) -> some View {
        let value = draft.value(of: field)
        let isActive = activeField == field
        let ceiling = Self.ceiling(for: field)
        VStack(spacing: 0) {
            neighbour(value > 0 ? value - 1 : nil, showing: isActive)
            Text("\(value)")
                .font(.system(size: 28, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Self.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            neighbour(value < ceiling ? value + 1 : nil, showing: isActive)
            Text(Self.unitName(field))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(contrast == .increased ? 0.70 : 0.45))
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isActive ? (contrast == .increased ? 0.14 : 0.08) : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(reduceMotion ? nil : Motion.levelChange) {
            activeField = field
        } }
        .gesture(drag(on: field))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenUnit(field))
        .accessibilityValue("\(value)")
        .accessibilityHint(KeepAwakeCopy.boxHint)
        .accessibilityAdjustableAction { direction in
            step(field, by: direction == .increment ? 1 : -1)
        }
    }

    /// The number above or below the one that is set. Drawn even when it is
    /// not shown, so touching a number does not change the card's height; and
    /// left blank at the ends of the range, because there is nothing there.
    @ViewBuilder private func neighbour(_ value: Int?, showing: Bool) -> some View {
        Text(value.map(String.init) ?? " ")
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Self.tint.opacity(contrast == .increased ? 0.55 : 0.35))
            .lineLimit(1)
            .opacity(showing ? 1 : 0)
    }

    /// Dragging a number up and down to change it.
    ///
    /// Up is more, which is the direction the value goes on screen. One step
    /// every fourteen points — the same distance the timer's own scrub uses,
    /// so a hand that has learnt one has learnt the other — counted from where
    /// the drag began rather than accumulated, so a long drag that comes back
    /// lands where it started.
    ///
    /// The field keeps to its own range instead of carrying into the next: an
    /// hour rolling over because minutes passed 59 moves a number the pointer
    /// is not on.
    private func drag(on field: KeepAwakeSpan.Field) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragAnchor == nil {
                    dragAnchor = draft.value(of: field)
                    draggingField = field
                    focusedField = field
                    activeField = field
                    // Latches the shell's hover so the card cannot close under
                    // a pointer that has wandered off it mid-drag.
                    if hold.hold() { actions.setDragging(true) }
                }
                // Negative height is upwards in SwiftUI's coordinates.
                let steps = Int((-value.translation.height / Self.pointsPerDetent)
                    .rounded(.towardZero))
                let anchored = dragAnchor ?? draft.value(of: field)
                let target = min(max(anchored + steps, 0), Self.ceiling(for: field))
                let delta = target - draft.value(of: field)
                guard delta != 0 else { return }
                setDraft(draft.moving(field, by: delta))
                actions.haptic()
            }
            .onEnded { _ in
                dragAnchor = nil
                draggingField = nil
                hold.release()
                actions.setDragging(false)
            }
    }

    /// How far the pointer travels between two numbers. The timer's own figure.
    private static let pointsPerDetent: CGFloat = 14

    private static func ceiling(for field: KeepAwakeSpan.Field) -> Int {
        switch field {
        case .days: KeepAwakeSpan.maximumDays
        case .hours: 23
        case .minutes: 59
        }
    }

    private static func unitName(_ field: KeepAwakeSpan.Field) -> String {
        switch field {
        case .days: "days"
        case .hours: "hours"
        case .minutes: "mins"
        }
    }

    /// What it is called aloud. "mins" is an abbreviation the caption can
    /// afford and a screen reader should not have to.
    private static func spokenUnit(_ field: KeepAwakeSpan.Field) -> String {
        switch field {
        case .days: "days"
        case .hours: "hours"
        case .minutes: "minutes"
        }
    }

    /// One press: a button, an arrow key, or a VoiceOver adjustment.
    @discardableResult
    private func step(_ field: KeepAwakeSpan.Field, by delta: Int) -> KeyPress.Result {
        focusedField = field
        nudge(by: delta)
        actions.haptic()
        return .handled
    }

    private func setMinutes(_ landed: Int) {
        withAnimation(reduceMotion ? nil : Motion.levelChange) { minutes = landed }
    }

    private func setDraft(_ span: KeepAwakeSpan) {
        withAnimation(reduceMotion ? nil : Motion.levelChange) { draft = span }
    }

    /// VoiceOver and the arrow keys move the field they are on, by one of its
    /// own units — an hour at a time on hours, not sixty minutes.
    private func nudge(by delta: Int) {
        let moved = draft.moving(focusedField, by: delta)
        guard moved != draft else { return }
        setDraft(moved)
    }

    // MARK: - Running

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                glyph
                VStack(alignment: .leading, spacing: 3) {
                    Text(KeepAwakeCopy.title)
                        .font(.cardFigure)
                        .foregroundStyle(Self.tint)
                        .lineLimit(1)
                    // The wall-clock time the hold ends. The countdown alone
                    // says how long, not until when, and "until when" is the
                    // thing somebody checks before walking away from the Mac.
                    Text(payload.isIndefinite
                         ? KeepAwakeCopy.runningUntilSwitchedOff
                         : KeepAwakeCopy.runningUntil(payload.until))
                        .font(.cardCaption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                    // What the lid-closed mode is doing, while it is doing
                    // anything. Its own line rather than a mark beside the
                    // time, because every state it can be in is a sentence —
                    // including the one where the daemon has gone quiet and
                    // the hold is still, almost certainly, standing.
                    if payload.lid.belongsOnARunningCard,
                       let line = KeepAwakeCopy.lid(payload.lid) {
                        Text(line)
                            .font(.cardCaption)
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(KeepAwakeCopy.title), running")
            .accessibilityValue(runningSpoken)

            // On its own row, like the boxes it replaces. Beside the title it
            // had about a hundred points to work with, and "2d 03h 15m" was
            // being cut to "2d 03h…" on a card 275 wide.
            //
            // Nothing sweeps or drains here. A keep-awake has no progress
            // worth watching — it is a condition, not a race — so the label
            // simply changes as the minutes go, which is also the whole of
            // what Reduce Motion would have asked for.
            // Counting up, not down: there is no end to count back from.
            Text(KeepAwakeCopy.remainingLabel(
                payload.isIndefinite ? payload.held : payload.remaining
            ))
                .font(.system(size: 34, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Self.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                CardCapsuleButton(KeepAwakeCopy.end, tint: Self.tint) { actions.end() }
            }
        }
    }

    /// The running card, read aloud. The lid line is part of it: a screen
    /// reader that says only "two hours left" has left out the whole of what
    /// makes this session different from the ordinary one.
    private var runningSpoken: String {
        let base = payload.isIndefinite
            ? "\(KeepAwakeCopy.heldFor(Self.spoken(payload.held))), \(KeepAwakeCopy.runningUntilSwitchedOff.lowercased())"
            : "\(Self.spoken(payload.remaining)) left, \(KeepAwakeCopy.runningUntil(payload.until).lowercased())"
        guard payload.lid.belongsOnARunningCard,
              let line = KeepAwakeCopy.lid(payload.lid)
        else { return base }
        return "\(base). \(line)"
    }

    // MARK: - Finished

    private func finished(_ reason: KeepAwakeEndReason) -> some View {
        let sentence = KeepAwakeCopy.finished(
            reason,
            at: payload.until,
            floor: payload.batteryFloor,
            lidClosed: payload.lidClosed
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                glyph
                VStack(alignment: .leading, spacing: 3) {
                    Text(KeepAwakeCopy.title)
                        .font(.cardFigure)
                        .foregroundStyle(Self.tint)
                        .lineLimit(1)
                    Text(sentence)
                        .font(.cardCaption)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    // Said before it can surprise anyone: a relaunch may bring
                    // this session back, and being told that now is the whole
                    // difference between a quirk and a fault.
                    if payload.endUnrecorded {
                        Text(KeepAwakeCopy.endNotSaved(until: payload.until))
                            .font(.cardCaption)
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(KeepAwakeCopy.title), finished")
            .accessibilityValue(payload.endUnrecorded
                ? "\(sentence) \(KeepAwakeCopy.endNotSaved(until: payload.until))"
                : sentence)

            // Resume never arrives alone. It is offered only after the user's
            // own End, which is exactly the case where they may have meant it
            // — so the card still has to be dismissible, and Done keeps the
            // quieter seat the finished timer gives Repeat.
            HStack(spacing: 8) {
                if let resumable = payload.resumable {
                    CardCapsuleButton(KeepAwakeCopy.done, tint: nil) { actions.dismiss() }
                    CardCapsuleButton(
                        KeepAwakeCopy.resumeButton(
                            remaining: SatelliteContent.keepAwakeLabel(remaining: resumable)
                        ),
                        tint: Self.tint
                    ) { actions.resume() }
                } else {
                    CardCapsuleButton(KeepAwakeCopy.done, tint: Self.tint) { actions.dismiss() }
                }
            }
        }
    }

    // MARK: - Duo

    /// The duo-width card: what it is and what is left, and nothing to press.
    /// Half a card has no room for a control row, and the full card is one
    /// click away.
    private var compact: some View {
        HStack(spacing: 6) {
            Image(systemName: "cup.and.saucer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.tint)
                // 24 rather than 30, and the row's gap 6 rather than 10: ten
                // points back for the text, which was losing the end of the
                // title at duo width.
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(KeepAwakeCopy.title)
                    .font(.cardSmallFigure)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(compactLine)
                    .font(.system(size: 17, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Self.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compactSpoken)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        // The dots are drawn over this strip here too. At 8 the compact face
        // was 51pt tall and the dots sat on its baseline.
        .padding(.bottom, 16)
    }

    private var compactLine: String {
        switch payload.phase {
        case .ready: SatelliteContent.keepAwakeLabel(remaining: TimeInterval(minutes * 60))
        case .running: SatelliteContent.keepAwakeLabel(remaining: payload.remaining)
        // "Ended", not a blank or a zero: half a card is still a card, and a
        // keep-awake that has stopped is the one fact worth the space.
        // Only the word. The whole sentence is what this comment promised and
        // not what it supplied, and at duo width it was cut mid-clause; the
        // reason is still spoken, where there is room for it.
        case .finished: KeepAwakeCopy.ended
        }
    }

    /// What the duo-width face says aloud: the word on screen is short because
    /// the card is, not because the reason stopped mattering.
    private var compactSpoken: String {
        switch payload.phase {
        case .ready: "\(KeepAwakeCopy.title), ready"
        case .running: "\(KeepAwakeCopy.title), \(Self.spoken(payload.remaining)) left"
        case .finished(let reason):
            KeepAwakeCopy.finished(reason, at: payload.until,
                                   floor: payload.batteryFloor,
                                   lidClosed: payload.lidClosed)
        }
    }

    // MARK: - Pieces

    /// The cup, in the slot every full card's glyph sits in.
    private var glyph: some View {
        Image(systemName: "cup.and.saucer")
            .font(.cardTitle)
            .foregroundStyle(Self.tint)
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }

    /// "1 hour 12 minutes", for VoiceOver.
    ///
    /// Spelled out rather than read off the card: "1h 12m" is a label sized
    /// for a glance, and a screen reader saying "one h twelve m" is not the
    /// same sentence the card is showing.
    ///
    /// Not `DurationDial.spoken`, which says "1 hr 12 min" and clamps at three
    /// hours — the dial's own range. A keep-awake runs to a day, and a label
    /// that stops at three hours would read every longer session wrong.
    static func spoken(_ seconds: TimeInterval) -> String {
        let sane = seconds.isFinite ? min(max(seconds, 0), 359_940) : 0
        let total = Int(sane.rounded())
        if total < 60 {
            return total == 1 ? "1 second" : "\(total) seconds"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let hourPart = hours == 1 ? "1 hour" : "\(hours) hours"
        let minutePart = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        if hours == 0 { return minutePart }
        return minutes == 0 ? hourPart : "\(hourPart) \(minutePart)"
    }
}

/// What the Keep Awake card can ask the shell to do.
///
/// Closures with empty defaults, like every other card's actions: the gallery
/// and the tests build the card without a provider behind it.
public struct KeepAwakeActions {

    /// Start a session of the given minutes — the Ready card's own Start.
    /// Switches it on, with no end. The card's own button.
    public var switchOn: () -> Void
    /// Switches it on for a set length, with the lid open. Kept for anything
    /// that wants a plain timed hold; the card's own buttons do not call it.
    public var start: (Int) -> Void
    /// Switches it on for a set length, and asks the helper to hold it through
    /// a shut lid.
    ///
    /// The length is not optional here and never will be. An indefinite
    /// lid-closed hold on battery is how a Mac cooks in a bag, so the mode
    /// that can do it is the one mode that always has an end time.
    public var startLidClosed: (Int) -> Void
    /// The End button. The only ending a session can be resumed from.
    public var end: () -> Void
    /// Takes the Finished card away, so it ends when the user says so.
    public var dismiss: () -> Void
    /// Picks the ended session back up, to its original deadline.
    public var resume: () -> Void
    /// One tick of the trackpad as the length crosses a detent. The card
    /// cannot do this itself: feedback is the shell's to give, and LedgeUI
    /// never imports AppKit.
    public var haptic: () -> Void
    /// Latches a drag in flight so the card stays open while the pointer
    /// wanders off it — the same latch the timer's length and the volume
    /// sliders use.
    public var setDragging: (Bool) -> Void

    public init(
        switchOn: @escaping () -> Void = {},
        start: @escaping (Int) -> Void = { _ in },
        startLidClosed: @escaping (Int) -> Void = { _ in },
        end: @escaping () -> Void = {},
        dismiss: @escaping () -> Void = {},
        resume: @escaping () -> Void = {},
        haptic: @escaping () -> Void = {},
        setDragging: @escaping (Bool) -> Void = { _ in }
    ) {
        self.switchOn = switchOn
        self.start = start
        self.startLidClosed = startLidClosed
        self.end = end
        self.dismiss = dismiss
        self.resume = resume
        self.haptic = haptic
        self.setDragging = setDragging
    }
}
