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
    /// The island's own resize spring, so a change of face and the shape
    /// growing or shrinking around it move as one.
    private let swapResponse: Double
    private let swapDamping: Double

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
    /// What the card is in the middle of: resting, asking how long, or
    /// explaining why the lid-closed mode cannot start.
    ///
    /// One value rather than two loose flags, and reset in one place rather
    /// than wherever a face happens to disappear. See `KeepAwakeCardFlow` for
    /// what that cost.
    @State private var flow = KeepAwakeCardFlow()

    /// Which stop the keyboard is on. Drives the same preview the pointer
    /// does, so the two never disagree about what a press would do.
    @FocusState private var focusedStop: Int?

    /// Whether the current lid request has gone unanswered long enough for
    /// the card to say so.
    @State private var waitHasLasted = false

    /// One per line of words that can change while the card is up: the
    /// sentence under the rail, the third stop's name, and the two notes.
    @State private var sentenceTurns = TextTurns()
    @State private var thirdLabelTurns = TextTurns()
    @State private var lidLineTurns = TextTurns()
    @State private var problemTurns = TextTurns()

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
        lidNote: Bool = false,
        swapResponse: Double = 0.38,
        swapDamping: Double = 0.68
    ) {
        self.payload = payload
        self.actions = actions
        self.isCompactWidth = isCompactWidth
        self.swapResponse = swapResponse
        self.swapDamping = swapDamping
        _flow = State(initialValue: KeepAwakeCardFlow(isAsking: startsAsking,
                                                      showsLidNote: lidNote))
        _draft = State(initialValue: draft)
        _activeField = State(initialValue: activeField)
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
            // The reading is taken when the *card* appears, not when a face
            // does: a face swap is not an event, and hanging work off one is
            // what made the question vanish in the frame it arrived.
            // Approving the helper happens in System Settings, where Ledge
            // cannot watch, so a card opened afterwards must ask again.
            .task { _ = await actions.refreshLid() }
            // Keyed on the reading, so a new request starts a new wait and an
            // answered one cancels this outright. On the card rather than on
            // a face: how long we have been looking at an answer is a fact
            // about the card being open.
            .task(id: payload.lid) {
                waitHasLasted = false
                guard payload.lid == .applying else { return }
                try? await Task.sleep(for: .seconds(Self.patienceBeforeSaying))
                guard !Task.isCancelled else { return }
                waitHasLasted = true
            }
            .onDisappear {
                hold.release()
                actions.setDragging(false)
                // The one reset, on the one event that means it. It used to
                // sit on the resting face and on the question, each of which
                // disappears when the *other* replaces it — so pressing Lid
                // closed opened the question and immediately closed it again.
                flow.cardWentAway()
            }
    }

    @ViewBuilder private var content: some View {
        if isCompactWidth {
            compact
        } else {
            // A ZStack, not a Group: a Group hands its modifiers to each face
            // separately, so the animation below arrived on the incoming face
            // as something new rather than as a change, and every swap cut.
            ZStack(alignment: .topLeading) {
                // The question first, whatever is running behind it. It used
                // to be reachable only from the resting face, so pressing Lid closed
                // while the Mac was already being held set the flag and drew
                // the switches anyway — the question never appeared, and the
                // two faces rendered byte-identically.
                if flow.isAsking {
                    asking
                } else {
                    // Off and a running hold in one arm. Two arms are two
                    // views even when both draw `switches`, so pressing Coffee
                    // threw the rail away and built a new one with the bead
                    // already on its stop, and the slide it was drawn for
                    // never ran.
                    switch payload.phase {
                    case .ready, .running:
                        switches
                            .transition(Motion.expandedSwap(reduced: reduceMotion))
                    case .finished(let reason):
                        finished(reason)
                            .transition(Motion.expandedSwap(reduced: reduceMotion))
                    }
                }
            }
            // Ending and coming back are a change of face, on the island's own
            // resize spring so the faces and the shape around them are one
            // movement rather than a cut inside a spring.
            .animation(faceMotion, value: isShowingFinished)
            // The same inset the notes and shelf cards use. This card had
            // none, so its content ran to the edges while every one beside it
            // was held off them. The card's own width is set by the island and
            // does not move with this.
            .padding(.horizontal, Self.contentInset)
            .padding(.top, Self.topInset)
            .padding(.bottom, Self.bottomInset)
        }
    }

    /// How the card's own faces change: the spring the island resizes with,
    /// or its short ease under Reduce Motion.
    private var faceMotion: Animation {
        Motion.expand(response: swapResponse, damping: swapDamping, reduced: reduceMotion)
    }

    private var isShowingFinished: Bool {
        if case .finished = payload.phase { return true }
        return false
    }

    /// Shared with the cards either side of this one, so a swipe between them
    /// does not step the content in and out.
    private static let contentInset: CGFloat = 10
    private static let topInset: CGFloat = 8
    /// The dots' own strip is added by the geometry (`dotsBand`), not here —
    /// reserving it in both places counted it twice and left a band of black
    /// under the button.
    private static let bottomInset: CGFloat = 14

    // MARK: - Ready and running

    /// The resting face and a running hold are the same thing: two switches
    /// and whatever they have to say for themselves.
    ///
    /// They were three separate layouts before — one for off, one for a plain
    /// hold, one for a lid-closed hold — and switching between them replaced
    /// the card wholesale, which is why a switch felt like a button that
    /// teleports you somewhere. Worse, the lid-closed mode was a capsule
    /// button that only existed on the resting face: switch the Mac awake and
    /// the one door to the lid-closed mode vanished, with no way back to it
    /// short of switching off again. One face, both switches, always.
    ///
    /// A running hold has no countdown of its own either. The plain mode has
    /// no end to count back from, and a timed one says so in the figure
    /// beside the title.
    private var switches: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rail
            // Always drawn, even when empty, so the card does not jump when a
            // preview appears under the pointer.
            ZStack(alignment: .topLeading) {
                Text(consequenceLine)
                    .font(.cardCaption)
                    .foregroundStyle(flow.hovering != nil
                                     ? Self.previewTint
                                     : .white.opacity(contrast == .increased ? 0.75 : 0.5))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    // Sized to what it holds. Two lines were reserved so that a
                    // sentence wrapping at the duo width could not make the card
                    // grow under the pointer — but at 275, where the card
                    // actually lives, every one of these is a single line, so the
                    // reserve was fourteen points of black on every card to
                    // prevent a jump at the narrowest width alone.
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .id(sentenceTurns.turn(for: consequenceLine))
                    .transition(wordSwap)
            }
            .padding(.top, 6)

            // Anything about the lid-closed hold *now*. Its own slot, so a
            // preview can never take its place: a sentence saying the Mac is
            // not being held must not vanish because somebody moved a pointer.
            if let line = lidLine {
                note(line, opacity: contrast == .increased ? 0.9 : 0.7, turns: lidLineTurns)
            }
            // And a failure left by an earlier session, which is about last
            // time rather than now, so it goes underneath and never competes.
            if let problem = problemLine {
                // Dimmer and further down than the lid sentence: that one is
                // about this Mac now, this one is about last time.
                note(problem, opacity: contrast == .increased ? 0.75 : 0.5, top: 6, turns: problemTurns)
            }
        }
        // A press changes the whole face at once — the bead, the fill, which
        // stop is lit, the caption, the figure, how tall the sentence is — and
        // it all moves on the island's own spring, so the rail and the shape
        // around it are one movement. The bead and the fill keep their own
        // quicker spring underneath this.
        .animation(faceMotion, value: chosenStop)
        .animation(faceMotion, value: beadKind)
    }

    /// The card's identity, and — only when there is one worth showing — the
    /// end of the hold.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                Text(KeepAwakeCopy.title)
                    .font(.cardFigure)
                    .foregroundStyle(Self.tint)
                    .lineLimit(1)
                Text(headerCaption)
                    .font(.cardCaption)
                    .opacity(headerCaption.isEmpty ? 0 : 1)
                    .foregroundStyle(.white.opacity(contrast == .increased ? 0.75 : 0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 6)
            // Only a hold that ends shows a figure. A plain hold runs until it
            // is switched off, and a number counting up beside it reads as a
            // timer somebody started — which is exactly wrong for the people
            // who leave this on all day.
            if let figure = endFigure {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(figure)
                        .font(.cardDisplay)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        // "23h 59m" at 24pt does not fit beside the title at
                        // the 231pt duo width, and a figure cut to "23h…" is
                        // a time that is wrong rather than small.
                        .minimumScaleFactor(0.62)
                        .layoutPriority(1)
                    Text(KeepAwakeCopy.railLeft)
                        .font(.cardCaption)
                        .foregroundStyle(.white.opacity(contrast == .increased ? 0.75 : 0.5))
                }
                .accessibilityHidden(true)
            }
        }
        // Sized to the taller of the glyph and the two lines beside it, not
        // held to a number: at 40 it reserved six points nothing drew into.
        .frame(minHeight: Self.headerHeight, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    // MARK: - The rail

    /// Three stops on one line, in the order they promise more.
    ///
    /// Two switch rows told the eye there were two independent settings, and
    /// there are not: the lid-closed mode is a stronger Awake that ends
    /// differently. The rail says that in its shape — the stops are ordered,
    /// the fill runs through Awake to reach the third, and stepping back one
    /// stop visibly leaves the Mac awake. The one asymmetry the switches hid
    /// is now shown three ways: in the geometry, in the sentence under the
    /// rail, and in a preview before anybody presses.
    private var rail: some View {
        GeometryReader { geo in
            let xs = Self.stopPositions(in: geo.size.width)
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.white.opacity(contrast == .increased ? 0.3 : 0.14))
                    .frame(width: xs[2] - xs[0], height: Self.trackThickness)
                    .offset(x: xs[0], y: Self.trackY)
                // How far the Mac is *really* held, which is not always how
                // far the user asked for.
                Capsule()
                    .fill(Self.tint)
                    .frame(width: max(0, xs[filledTo] - xs[0]), height: Self.trackThickness)
                    .offset(x: xs[0], y: Self.trackY)
                    .animation(reduceMotion ? nil : Motion.levelChange, value: filledTo)
                    // Under Reduce Motion it does not grow along the rail;
                    // the old length fades out as the new one fades in.
                    .id(reduceMotion ? filledTo : -1)
                    .transition(.opacity)
                if lidIsWaiting, lidIsUnsettled {
                    // Requested, not proven, and still being asked. Once
                    // the answer is no — or no answer ever came — the dashes
                    // go: there is nothing in flight for them to stand for,
                    // and the struck bead is the whole of what is left to say.
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: Self.trackThickness / 2))
                        path.addLine(to: CGPoint(x: xs[2] - xs[1], y: Self.trackThickness / 2))
                    }
                    .stroke(Self.tint.opacity(0.75),
                            style: StrokeStyle(lineWidth: Self.trackThickness, dash: [3, 3]))
                        .frame(width: xs[2] - xs[1], height: Self.trackThickness)
                        .offset(x: xs[1], y: Self.trackY)
                }
                ForEach(0 ..< 3, id: \.self) { i in
                    stopMark(i, x: xs[i])
                }
                bead(x: xs[chosenStop])
                railLabels(xs)
                hitTargets
            }
        }
        .frame(height: Self.railHeight)
        .padding(.top, 10)
    }

    private func stopMark(_ i: Int, x: CGFloat) -> some View {
        let lit = i > 0 && i <= filledTo
        return Circle()
            .fill(lit ? Self.tint : .white.opacity(contrast == .increased ? 0.5 : 0.28))
            .frame(width: Self.stopSize, height: Self.stopSize)
            .offset(x: x - Self.stopSize / 2, y: Self.trackY - (Self.stopSize - Self.trackThickness) / 2)
    }

    /// Where the card is, and whether that is proven.
    ///
    /// One view whatever it is saying: the fill, the ring, the halo and the
    /// strike are properties of it, not a view each. With a view per kind, a
    /// bead that changed kind on its way to a new stop — Off to Coffee, Coffee
    /// to Lid shut — left the old one fading where it was and the new one
    /// fading in at the far stop. It never travelled.
    private func bead(x: CGFloat) -> some View {
        let size = chosenStop == 0 ? Self.beadRest : Self.beadSize
        let kind = beadKind
        return Circle()
            .fill(beadFill(kind))
            // A held lid wears a faint halo outside the disc.
            .overlay(
                Circle().strokeBorder(Self.tint.opacity(0.16), lineWidth: 3)
                    .scaleEffect(1.4)
                    .opacity(kind == .held ? 1 : 0)
            )
            // The hollow ring: breathing while a request is in the air, still
            // once nobody is waiting on an answer — "cannot tell" — and white
            // under the strike when the answer was no.
            .overlay(
                Circle().strokeBorder(beadRing(kind), lineWidth: 1.5)
                    .modifier(Breath(active: kind == .checking && !reduceMotion))
                    .opacity(kind == .checking || kind == .cannotTell || kind == .notHeld ? 1 : 0)
            )
            .overlay(
                Rectangle()
                    .fill(.white.opacity(0.7))
                    .frame(width: 1.2, height: size + 4)
                    .rotationEffect(.degrees(45))
                    .opacity(kind == .notHeld ? 1 : 0)
            )
            .frame(width: size, height: size)
            .offset(x: x - size / 2, y: Self.trackY - (size - Self.trackThickness) / 2)
            .animation(reduceMotion ? nil : Motion.levelChange, value: chosenStop)
            // Under Reduce Motion the bead does not travel: it fades out on
            // the stop it left and in on the one it went to.
            .id(reduceMotion ? chosenStop : -1)
            .transition(.opacity)
    }

    private func beadFill(_ kind: BeadKind) -> Color {
        switch kind {
        case .resting: return .white.opacity(contrast == .increased ? 1 : 0.85)
        case .held: return Self.tint
        // Black, so neither the stop mark nor the dashes show through.
        case .checking, .cannotTell, .notHeld: return .black
        }
    }

    private func beadRing(_ kind: BeadKind) -> Color {
        switch kind {
        case .notHeld: return .white.opacity(0.7)
        case .cannotTell: return Self.tint.opacity(0.8)
        default: return Self.tint
        }
    }

    private func railLabels(_ xs: [CGFloat]) -> some View {
        // The outer two sit on the card's own edges, where the first and last
        // stops are; the middle one is centred on its stop rather than left
        // to float between them. Spaced with Spacers it sat twelve points
        // left of the mark it names and *moved* whenever the third word
        // changed length — "Lid shut" to "Checking…" shifted it twenty.
        ZStack(alignment: .top) {
            HStack(spacing: 4) {
                Text(KeepAwakeCopy.railOff)
                    .foregroundStyle(labelTint(0))
                Spacer(minLength: 2)
                ZStack(alignment: .trailing) {
                    Text(thirdStopLabel)
                        .foregroundStyle(labelTint(2))
                        .id(thirdLabelTurns.turn(for: thirdStopLabel))
                        .transition(wordSwap)
                }
            }
            Text(KeepAwakeCopy.railAwake)
                .foregroundStyle(labelTint(1))
        }
        .font(.cardCaption)
        .lineLimit(1)
        .offset(y: Self.labelsY)
        .accessibilityHidden(true)
    }

    /// A third of the width each, and the full height of the rail. The stops
    /// are 7pt across; nobody is being asked to hit 7pt in a notch.
    private var hitTargets: some View {
        HStack(spacing: 0) {
            ForEach(0 ..< 3, id: \.self) { i in
                Button { press(i) } label: {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The reach is taller than the rail it is drawn on. 38pt is
                // the drawing; a pointer arriving at a card that has just
                // opened under it needs more than that.
                .frame(height: Self.hitHeight)
                .disabled(!canPress(i))
                .onHover { inside in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        flow.hovered(inside ? i : nil)
                    }
                }
                // Focus previews too: the preview answers "what does this do
                // before I commit to it", and a keyboard user had an
                // accessibility hint and nothing on the screen.
                //
                // Deliberately *not* `.focusable()`. A Button is focusable
                // already when the user asks for it; adding it unconditionally
                // made something take focus the moment the card was drawn, so
                // every card — including every photograph of one — opened
                // showing a preview of a press nobody had made, in place of
                // the sentence saying what the card is doing now.
                .focused($focusedStop, equals: i)
                .accessibilityLabel(stopName(i))
                // What is true, not what was chosen. A struck or breathing
                // bead read as "On" to a screen reader, which is the one
                // reader with no picture to contradict it.
                .accessibilityValue(spokenValue(for: i))
                .accessibilityHint(previewLine(for: i) ?? "")
            }
        }
        .frame(height: Self.railHeight)
        // Reset whenever the reading moves: a new request starts a new wait,
        // and an answered one has nothing left to be patient about.
        .onChange(of: focusedStop) { _, stop in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                flow.hovered(stop)
            }
        }
    }

    // MARK: - What the rail is saying

    enum BeadKind {
        case resting, held, checking, notHeld
        /// Got through, and nothing can vouch for it. Drawn as a still ring
        /// rather than a breathing one — nobody is waiting on an answer any
        /// more — and never as the struck bead, which is a claim that the
        /// hold is gone.
        case cannotTell
    }

    /// Which stop the user chose. Where the bead sits.
    var chosenStop: Int {
        if !isHolding { return 0 }
        return payload.lidClosed ? 2 : 1
    }

    /// How far the Mac is actually held. Where the fill stops.
    ///
    /// Not the same as `chosenStop`, and that difference is the whole point of
    /// drawing a fill at all: a lid request the daemon has not confirmed is a
    /// bead on the third stop with the fill stopping at the second, because
    /// the second is all that is true.
    var filledTo: Int {
        guard isHolding else { return 0 }
        return isHoldingThroughLid ? 2 : 1
    }

    var beadKind: BeadKind {
        if !isHolding { return .resting }
        if !payload.lidClosed { return .held }
        if isHoldingThroughLid { return .held }
        if payload.lid == .cannotTell { return .cannotTell }
        return lidIsWaiting ? .checking : .notHeld
    }

    /// Whether the request has been in the air long enough to say so.
    ///
    /// Driven by the card rather than the provider: the provider publishes a
    /// reading, and "how long have we been looking at it" is a fact about
    /// this card being open, not about the daemon.
    /// A request still in the air, as against one that was answered with no.
    ///
    /// `applying` is the daemon having accepted a lease and not yet run the
    /// privileged write; `unconfirmed` is a hold it confirmed and has since
    /// gone quiet about. Both are waiting, and both draw the same breathing
    /// bead — what differs is the sentence, because only one of them is
    /// entitled to say the hold probably stands.
    private var lidIsWaiting: Bool {
        payload.lid == .unconfirmed || payload.lid == .applying || payload.lid == .holding
    }

    var thirdStopLabel: String {
        guard lidIsUnsettled else { return KeepAwakeCopy.lidClosed }
        if payload.lid == .cannotTell { return KeepAwakeCopy.railCannotTell }
        return lidIsWaiting ? KeepAwakeCopy.railChecking : KeepAwakeCopy.railNotHeld
    }

    /// What a stop is, read aloud. Selection, a request and a confirmed hold
    /// are three different facts and the rail draws them three different
    /// ways; this says the same three things in words.
    private func spokenValue(for i: Int) -> String {
        guard i == chosenStop else { return "" }
        // Off is not a hold. Sitting on it used to be read aloud as "On",
        // because the value came from being the chosen stop rather than from
        // what the stop means.
        guard i > 0 else { return KeepAwakeCopy.off }
        guard i == 2 else { return KeepAwakeCopy.on }
        switch beadKind {
        case .held: return KeepAwakeCopy.on
        case .checking: return KeepAwakeCopy.railChecking
        case .cannotTell: return KeepAwakeCopy.railCannotTell
        case .notHeld: return KeepAwakeCopy.railNotHeld
        case .resting: return KeepAwakeCopy.off
        }
    }

    private func stopName(_ i: Int) -> String {
        [KeepAwakeCopy.railOff, KeepAwakeCopy.railAwake, KeepAwakeCopy.lidClosed][i]
    }

    private func labelTint(_ i: Int) -> Color {
        if i == 2, payload.lid == .unsignedBuild, !isHolding {
            return .white.opacity(0.24)
        }
        if flow.hovering == i { return .white }
        if i == chosenStop { return .white.opacity(contrast == .increased ? 1 : 0.85) }
        return .white.opacity(contrast == .increased ? 0.7 : 0.4)
    }

    /// The caption beside the title: what this stop means for the end of the
    /// hold, in three words.
    /// Internal so a test can read it: "the card does not say the same word
    /// twice" is a claim about two strings, and a render cannot tell a caption
    /// that is absent from one that is the same colour as the ground.
    var headerCaptionText: String { headerCaption }

    private var headerCaption: String {
        switch payload.phase {
        // Nothing. The rail already says Off, in bold, directly under the
        // bead — a caption repeating it beside the title was the same word
        // twice in fourteen points of space.
        case .ready: return ""
        case .finished: return KeepAwakeCopy.ended
        case .running:
            // A timed hold says everything about its end elsewhere: the
            // figure gives the time, the rail names the mode, the sentence
            // under it says what happens when the time runs out. A caption
            // here could only repeat one of the three.
            return payload.isIndefinite ? KeepAwakeCopy.runningUntilSwitchedOff : ""
        }
    }

    /// The large figure, or nothing.
    ///
    /// Only a hold with an end has one. A plain hold runs until it is switched
    /// off, so there is no end to count back from — and counting *up* instead,
    /// which an earlier version did, turns a switch into a stopwatch nobody
    /// started. Somebody who leaves this on all day is not running a timer.
    /// Internal so a test can read it: "a hold with no end shows no number"
    /// is a claim about a string, and a rendered card is the same height with
    /// the figure and without it.
    var endFigure: String? {
        guard isHolding, !payload.isIndefinite else { return nil }
        return SatelliteContent.keepAwakeLabel(remaining: payload.remaining)
    }

    /// The line under the rail: what the card means, or what a press would do.
    var consequenceLine: String {
        if let i = flow.hovering, let preview = previewLine(for: i) { return preview }
        switch payload.phase {
        case .finished(let reason):
            return KeepAwakeCopy.finished(reason, at: payload.until,
                                          floor: payload.batteryFloor,
                                          lidClosed: payload.lidClosed)
        case .ready: return KeepAwakeCopy.consequenceOff
        case .running:
            return payload.isIndefinite
                ? KeepAwakeCopy.consequenceAwake
                : KeepAwakeCopy.consequenceTimed(until: payload.until)
        }
    }

    /// What pressing a stop would do, or nil when it would do nothing.
    func previewLine(for i: Int) -> String? {
        if i == 2, payload.lid == .unsignedBuild, !isHolding {
            return KeepAwakeCopy.lid(.unsignedBuild)
        }
        if i == chosenStop {
            // The one press on your own stop that does something: asking
            // again for a hold that was refused or never answered, keeping
            // the end time you already chose. Not every refusal, though —
            // somebody else's claim is not ours to take, and offering to ask
            // again there is the press that looks live and changes nothing.
            guard i == 2, canRetryLid else { return nil }
            return KeepAwakeCopy.previewRetryLid(until: payload.until)
        }
        switch (chosenStop, i) {
        case (2, 0): return KeepAwakeCopy.previewToOffFromLid
        case (2, 1): return KeepAwakeCopy.previewDropLid
        case (1, 0): return KeepAwakeCopy.previewToOffFromAwake
        case (_, 1): return KeepAwakeCopy.previewToAwake
        default: return lidPreviewLine
        }
    }

    /// Pressing the third stop from Off or Awake. Usually the invitation; a
    /// standing refusal or a missing helper replaces it with the reason.
    private var lidPreviewLine: String {
        switch payload.lid {
        case .notInstalled, .needsApproval, .unsignedBuild:
            return KeepAwakeCopy.lid(payload.lid) ?? KeepAwakeCopy.lidRowHint
        case .refused(let code) where !code.isWorthRetrying:
            return KeepAwakeCopy.lid(payload.lid) ?? KeepAwakeCopy.lidRowHint
        default:
            return KeepAwakeCopy.lidRowHint
        }
    }

    /// Whether a stop can be pressed at all.
    ///
    /// Only the stop you are already on, and the one mode this build can never
    /// have. Everything else is pressable even when it will refuse: the reason
    /// a press is refused lives outside Ledge — System Settings, another app
    /// holding sleep — and a control that cannot be pressed can never find out
    /// that it changed.
    func canPress(_ i: Int) -> Bool {
        if i == 2, !isHolding, payload.lid == .unsignedBuild { return false }
        if i != chosenStop { return true }
        return i == 2 && canRetryLid
    }

    /// Whether asking the daemon again could change anything.
    ///
    /// A request that was refused for a reason outside Ledge — another app
    /// holding sleep, the other build of Ledge — is not retried: the sentence
    /// tells the user where to go, and a press that says "asking again" and
    /// changes nothing is the dead control this card keeps coming back to.
    private var canRetryLid: Bool {
        guard lidIsUnsettled, !lidIsWaiting else { return false }
        if case .refused(let code) = payload.lid { return code.isWorthRetrying }
        return true
    }

    private func press(_ i: Int) {
        flow.hovered(nil)
        switch i {
        case 0:
            flow.movedToAnotherStop()
            if isHolding { actions.end() }
        case 1:
            flow.movedToAnotherStop()
            if chosenStop == 2 {
                // Stepping back one stop. The Mac stays awake; only the lid
                // half is given up.
                actions.dropLidHold()
            } else if !isHolding {
                actions.switchOn()
            }
        default:
            // Already running the lid mode and it did not take: ask again for
            // the hold this session already has, with no second question.
            if chosenStop == 2, lidIsUnsettled, !lidIsWaiting {
                flow.movedToAnotherStop()
                actions.retryLid()
                return
            }
            askForTheLid()
        }
    }

    /// Where the lid mode is reached from Off or Awake: ask the daemon what it
    /// can do, then put the question up — or say why not.
    private func askForTheLid() {
        let ticket = flow.beganAsking()
        Task { @MainActor in
            let fresh = await actions.refreshLid() ?? payload.lid
            withAnimation(reduceMotion ? nil : Motion.levelChange) {
                flow.pressedLidSwitch(answer: fresh, ticket: ticket)
            }
        }
    }

    /// A sentence under the rail, in its own slot.
    private func note(_ text: String, opacity: Double, top: CGFloat = 8,
                      turns: TextTurns) -> some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                // Medium at 11, not semibold at 10. Three facts set in the same
                // heavy small caps three points apart read as one grey block six
                // lines deep, and nobody could see where "now" ended and "last
                // time" began.
                .font(.cardNote)
                .foregroundStyle(.white.opacity(opacity))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(turns.turn(for: text))
                .transition(wordSwap)
        }
        // Flush left. The indent this used to carry lined the sentence up
        // with a second switch row's text; there is no second row now, and
        // the indent only made the card look like a form.
        .padding(.top, top)
        .transition(.opacity)
    }

    /// Words that change go out before the new ones come in.
    ///
    /// Cross-faded in place, the old sentence and the new one were drawn over
    /// each other for a tenth of a second and read as neither — and worse
    /// while the rail was moving, when the two sat a few points apart. Each
    /// carries its own timing, so it is the same whether the change rides
    /// the island's spring, a hover, or nothing at all, and a burst of
    /// presses only ever has one line on its way in. The calendar's month
    /// name does the same.
    private var wordSwap: AnyTransition {
        let out = reduceMotion ? 0.07 : 0.1
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: reduceMotion ? 0.09 : 0.14).delay(out)),
            removal: .opacity.animation(.easeIn(duration: out))
        )
    }

    // MARK: - Geometry

    static func stopPositions(in width: CGFloat) -> [CGFloat] {
        [stopInset, width / 2, width - stopInset]
    }
    private static let stopInset: CGFloat = 7
    private static let railHeight: CGFloat = 38
    /// How long a request may go unanswered before the card says so.
    private static let patienceBeforeSaying: TimeInterval = 1.5
    private static let hitHeight: CGFloat = 44
    private static let trackY: CGFloat = 8
    private static let trackThickness: CGFloat = 2
    private static let stopSize: CGFloat = 7
    private static let beadSize: CGFloat = 14
    private static let beadRest: CGFloat = 12
    private static let labelsY: CGFloat = 21
    private static let headerHeight: CGFloat = 32

    /// What a press *would* do, as against what is true. Lighter than the tan
    /// so the two never read as the same statement.
    static let previewTint = Color(red: 0.87, green: 0.76, blue: 0.63)

    /// Whether the Mac is being held awake at all.
    private var isHolding: Bool { payload.phase == .running }

    /// Whether this session asked for the lid-closed mode.
    ///
    /// What the user chose, not what the Mac is doing. A request the daemon
    /// refused, or never answered, is still a request.
    private var lidWasAskedFor: Bool { isHolding && payload.lidClosed }

    /// Whether the lid-closed hold is actually standing.
    ///
    /// The switch's position comes from this. Drawing it from the request
    /// instead put a card on the screen with both switches On, "2h 30m left",
    /// and "nothing is being held — shutting the lid will sleep your Mac", all
    /// at once. The ordinary hold can be perfectly real while the lid half of
    /// it is not; they are two promises and the card makes two of them.
    var isHoldingThroughLid: Bool { lidWasAskedFor && payload.lidHeld }

    /// A lid-closed hold that was asked for and is not confirmed.
    ///
    /// Neither On nor Off. The daemon may have taken it and lost the reply, or
    /// never taken it at all, and the card is entitled to neither story.
    var lidIsUnsettled: Bool { lidWasAskedFor && !payload.lidHeld }

    /// The lid-closed mode's question: the three boxes and the two buttons
    /// that answer it. Unchanged — this is the face the resting one leads to.
    private var asking: some View {
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
                    Text(KeepAwakeCopy.howLongLidClosed)
                        .font(.cardCaption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(KeepAwakeCopy.title), ready")
            .accessibilityValue(KeepAwakeCopy.howLongLidClosed)

            // The length on its own line with the whole width to itself —
            // which is what stops a seven-day span from being squeezed
            // against the title and truncated.
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

            HStack(spacing: 8) {
                // A question has to be answerable with "never mind". The
                // quiet seat, the same one Done takes on the finished card.
                CardCapsuleButton(KeepAwakeCopy.cancel, tint: nil) {
                    hold.release()
                    actions.setDragging(false)
                    flow.cancelledQuestion()
                }
                // Nothing to start until a number has been put in. Saying so
                // by disabling the button is quieter than starting a
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
                    flow.answeredQuestion()
                    // The length belongs to this mode alone, so this is the
                    // only button that sends one.
                    actions.startLidClosed(startable)
                }
            }
        }
    }

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

    /// What the lid-closed mode has to say for itself on the resting card, if
    /// anything.
    ///
    /// A refusal, an unconfirmed hold and a hold that was asked for and never
    /// answered say themselves: something happened, and the user is owed the
    /// reason without having to ask. "Not set up", "waiting for approval" and
    /// "this build can't" do not, because they would then be the standing line
    /// on every card for every user who has not set it up — a setup prompt
    /// shouted at somebody who only wanted the switch. Those wait for the
    /// press that reaches for the mode.
    ///
    /// This used to be folded into one line shared with `problemLine`, which
    /// had a bug with the shape of a trapdoor: a standing problem from an
    /// earlier session took the line, the lid sentence was dropped, and
    /// pressing Lid closed did nothing visible at all. The two have separate
    /// slots now, so neither can swallow the other. The other half of that
    /// guarantee is in `KeepAwakeLidState`: every state that cannot arm has a
    /// sentence, which is what makes a press that cannot start something a
    /// press that always says why.
    private var lidLine: String? {
        switch payload.lid {
        // Nothing to explain. A confirmed hold is drawn on the rail and has
        // the menu-bar item — which exists for exactly as long as a hold is
        // live — to say so; a sentence here would be a third telling.
        case .off, .holding: nil
        // A request that has been accepted and not yet applied says so only
        // after a moment. Most answers arrive inside a second, and a warning
        // that flashes and vanishes reads as a fault rather than as progress,
        // so the breathing bead carries the first instant on its own.
        // Said once the wait has lasted long enough to be a wait. Most
        // answers arrive inside a second, and a warning that flashes and
        // vanishes reads as a fault rather than as progress — but this is the
        // sentence that tells somebody to keep the lid open until the hold is
        // confirmed, and it was reachable only through a flag that this state
        // never sets. The one sentence here that protects the user was the
        // one sentence that never showed.
        case .applying: waitHasLasted ? KeepAwakeCopy.lid(.applying) : nil
        // Unreachable is never waited for. The other sentences here are the
        // answer to a press; this one is the answer to a question the user has
        // not thought to ask — their Mac is not being held, and shutting the
        // lid will end whatever they started it for.
        case .unconfirmed, .refused, .unreachable, .cannotTell:
            KeepAwakeCopy.lid(payload.lid)
        // Always, not only after a press. The stop these describe is drawn
        // dashed or faint, and a stop that is drawn as unfinished with no
        // reason beside it is the dead control this card keeps being redrawn
        // to be rid of.
        case .notInstalled, .needsApproval, .unsignedBuild:
            KeepAwakeCopy.lid(payload.lid)
        }
    }

    /// Whatever went wrong last time, if anything did.
    ///
    /// Only the plain switch's own failures. It no longer competes with the
    /// lid-closed mode for one line, so it no longer has to outrank anything.
    private var problemLine: String? {
        switch payload.problem {
        case .assertionRefused: KeepAwakeCopy.assertionRefused
        case .startNotSaved: KeepAwakeCopy.startNotSaved
        case .tooManyUnsaved: KeepAwakeCopy.tooManyUnsaved
        case .journalUnreadable: KeepAwakeCopy.journalUnreadable
        case .partialHold: KeepAwakeCopy.partialHold
        case nil: nil
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
        // Not a length. Half a card used to show "1h" here — the default the
        // old launcher opened on — which is the card promising a duration the
        // plain mode does not have. The switch's own position is the honest
        // thing to show, and it is one character shorter.
        case .ready: KeepAwakeCopy.off
        case .running:
            SatelliteContent.keepAwakeLabel(
                remaining: payload.isIndefinite ? nil : payload.remaining)
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
        case .ready: "\(KeepAwakeCopy.title), \(KeepAwakeCopy.off.lowercased())"
        case .running where payload.isIndefinite:
            "\(KeepAwakeCopy.title), \(KeepAwakeCopy.on.lowercased())"
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
            // 22, not the 40 the switch rows used. At 40 the title started
            // eighteen points right of the rail's first stop and the cup
            // lined up with nothing.
            .frame(width: 22, height: 22)
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

    /// Switches it on, with no end. The resting card's own switch.
    ///
    /// No length, deliberately. A plain hold with the lid open is the
    /// caffeinate case: it runs until somebody switches it off, and asking
    /// how long first is a form in front of a switch.
    public var switchOn: () -> Void
    /// Asks the daemon again for the hold this session already asked for.
    ///
    /// Not a new session and not a new question: the length and the end time
    /// are the ones already chosen. Every refusal sentence on this card ends
    /// with some version of "try again", and until now trying again meant
    /// taking the mode off and putting it back, losing the end time on the way.
    public var retryLid: () -> Void = {}
    /// Gives up the lid-closed hold without giving up the Mac.
    ///
    /// A session cannot change its mind — whether it survives a shut lid is
    /// decided when it starts — so this ends the one that is running and
    /// begins a plain one in its place. Reaching for the smaller of two
    /// settings must not put the Mac to sleep.
    public var dropLidHold: () -> Void = {}
    /// Switches it on for a set length, and asks the helper to hold it through
    /// a shut lid.
    ///
    /// The length is not optional here and never will be. An indefinite
    /// lid-closed hold on battery is how a Mac cooks in a bag, so the mode
    /// that can do it is the one mode that always has an end time.
    public var startLidClosed: (Int) -> Void

    /// Asks what the lid-closed mode can do right now.
    ///
    /// Called on the press rather than only at launch: whether the helper is
    /// allowed is decided in System Settings, where Ledge is not, and a
    /// reading taken before that is simply out of date.
    /// Asks what the lid-closed mode can do right now, and answers with it.
    ///
    /// Async, and it returns the reading, because the press has to decide on
    /// it. Fire-and-forget, the card decided on the value it already had and
    /// the refreshed one landed afterwards — so the first press after
    /// approving the helper in System Settings always acted on the stale
    /// "not set up". Reading `payload` back after an await does not work
    /// either: this view is a value, and the refreshed payload arrives in a
    /// new one.
    public var refreshLid: () async -> KeepAwakeLidState? = { nil }
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
        retryLid: @escaping () -> Void = {},
        dropLidHold: @escaping () -> Void = {},
        startLidClosed: @escaping (Int) -> Void = { _ in },
        refreshLid: @escaping () async -> KeepAwakeLidState? = { nil },
        end: @escaping () -> Void = {},
        dismiss: @escaping () -> Void = {},
        resume: @escaping () -> Void = {},
        haptic: @escaping () -> Void = {},
        setDragging: @escaping (Bool) -> Void = { _ in }
    ) {
        self.switchOn = switchOn
        self.retryLid = retryLid
        self.dropLidHold = dropLidHold
        self.startLidClosed = startLidClosed
        self.refreshLid = refreshLid
        self.end = end
        self.dismiss = dismiss
        self.resume = resume
        self.haptic = haptic
        self.setDragging = setDragging
    }
}

/// The ring's slow breath while a lid request is in the air: full to 0.4
/// and back, 1.2 s each way.
///
/// Worked out from the clock rather than with a repeating animation. The ring
/// stays mounted whatever the bead is saying — that is what lets the bead
/// travel — and a repeating animation, once started on a view that stays,
/// cannot be stopped.
private struct Breath: ViewModifier {
    let active: Bool
    /// When this breath began, so it always starts from full rather than
    /// wherever the clock happens to be.
    @State private var since = Date()

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            content.opacity(active ? Self.level(after: context.date.timeIntervalSince(since)) : 1)
        }
        .onChange(of: active) { _, now in
            if now { since = Date() }
        }
    }

    static func level(after seconds: TimeInterval) -> Double {
        0.7 + 0.3 * cos(2 * .pi * seconds / 2.4)
    }
}

/// A new number each time a line of text changes, so the old words and the
/// new are two views that can leave and arrive in turn.
///
/// A number rather than the text itself: keyed on the text, going back to a
/// sentence that was still fading out brought that copy straight back, on top
/// of the one arriving. Counted where the body reads it, so the new words
/// never spend a frame in the old words' view.
@MainActor
final class TextTurns {
    private var last: String?
    private var count = 0

    func turn(for text: String) -> Int {
        if text != last {
            last = text
            count += 1
        }
        return count
    }
}
