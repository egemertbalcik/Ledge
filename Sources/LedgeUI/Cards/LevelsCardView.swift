import LedgeCore
import SwiftUI

/// What the levels card can ask the shell to do.
///
/// Rows are *pulled* when the card opens — the same one-shot rule the HUD's
/// hover panel uses — so no device enumeration ever runs while the card is
/// closed. Every setter answers with the row as the device now reports it,
/// because a bar that moves when nothing moved is the control lying.
public struct LevelsActions {
    public var rows: () -> [LevelRow]
    /// Sets a level and answers with what the device says it now is. The
    /// number on screen is always this answer, never the gesture's.
    public var setLevel: (String, Double) -> LevelRow?
    /// Toggles mute on an output. New: the card had no mute at all, so mute
    /// was reachable only from the key.
    public var toggleMute: (String) -> LevelRow?
    /// Opens the output list in place.
    public var swapOutput: (String) -> Void
    /// Latches a drag in flight, so the overlay stays open while the pointer
    /// wanders off the row being dragged.
    public var setDragging: (Bool) -> Void

    public init(
        rows: @escaping () -> [LevelRow] = { [] },
        setLevel: @escaping (String, Double) -> LevelRow? = { _, _ in nil },
        toggleMute: @escaping (String) -> LevelRow? = { _ in nil },
        swapOutput: @escaping (String) -> Void = { _ in },
        setDragging: @escaping (Bool) -> Void = { _ in }
    ) {
        self.rows = rows
        self.setLevel = setLevel
        self.toggleMute = toggleMute
        self.swapOutput = swapOutput
        self.setDragging = setDragging
    }
}

/// Sound and light, drawn once.
///
/// Two thick Control Centre pills were borrowed from iOS, where they sit on a
/// frosted sheet a thumb's width from the eye. In a notch they are the
/// brightest objects on the screen — two slabs of white at the top of a dark
/// desk at night, on the card whose job is to make the screen dimmer. A name,
/// a number and a 3pt line say the same thing with a fraction of the light,
/// and the number is the part a person actually wanted: 31, not about a third.
public struct LevelsCardView: View {

    /// What the provider last published.
    ///
    /// The rows are pulled, but *when* to pull them is a question only the
    /// provider can answer: a volume key changes the level without anything on
    /// this card being touched, and with nothing watching, an open card went
    /// on showing the number from the moment it opened.
    private let payload: LevelsPayload
    private let actions: LevelsActions
    private let isCompactWidth: Bool

    /// The rows, as the devices last reported them.
    @State private var rows: [LevelRow]
    /// Which row a drag owns, held for the whole gesture so a route changing
    /// underneath cannot move the drag to another device.
    @State private var dragging: String?
    /// Which row the pointer is on. The others rest at 38%, so the level being
    /// changed is the one being looked at.
    @State private var hovering: String?
    @FocusState private var focused: String?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        payload: LevelsPayload = LevelsPayload(),
        actions: LevelsActions = LevelsActions(),
        isCompactWidth: Bool = false,
        /// Seeded for a test or the gallery, which have no hardware to pull
        /// from. The card used to ignore its payload and read devices through
        /// its actions, so the preview supplied none and every photograph of
        /// it showed two empty bars.
        rows: [LevelRow] = []
    ) {
        self.payload = payload
        self.actions = actions
        self.isCompactWidth = isCompactWidth
        _rows = State(initialValue: rows.isEmpty ? payload.rows : rows)
    }

    /// 1% a notch, 5% with Shift. The same step the keys use.
    static let step = 0.01
    static let coarseStep = 0.05
    /// The reach, not the drawing. The line is 3pt; nobody is being asked to
    /// hit 3pt on a card that opens under a moving pointer.
    static let rowHeight: CGFloat = 36

    public var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 14)
            // The rows arrive with the payload, so the first frame is already
            // right. This is the refresh for a card that is *already* open
            // when something changes underneath it.
            .task {
                pull()
                // One frame's grace. Anything after this is a change somebody
                // can see happen; anything before it is the card arriving.
                try? await Task.sleep(for: .milliseconds(250))
                hasSettled = true
            }
            .onChange(of: payload.volume) { _, _ in pull() }
            .onChange(of: payload.brightness) { _, _ in pull() }
            .onChange(of: payload.isMuted) { _, _ in pull() }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                // A gap between the sound group and the light group, and
                // nothing else between rows. Two groups under one hairline of
                // space read as two groups without needing a label.
                if index > 0, rows[index - 1].kind == .sound, row.kind != .sound {
                    Color.clear.frame(height: 8)
                }
                LevelRowView(
                    row: row,
                    isDimmed: isDimmed(row),
                    contrast: contrast,
                    onSet: { set(row, to: $0) },
                    onMute: { mute(row) },
                    onSwap: { actions.swapOutput(row.id) },
                    onDragging: { began in
                        dragging = began ? row.id : nil
                        actions.setDragging(began)
                    },
                    onHover: { inside in hovering = inside ? row.id : nil }
                )
                .focused($focused, equals: row.id)
            }
        }
    }

    /// Re-reads every level from the hardware.
    ///
    /// Not while a drag is in flight: the gesture owns the number then, and a
    /// poll landing mid-drag would fight the hand.
    private func pull() {
        guard dragging == nil else { return }
        let pulled = actions.rows()
        guard !pulled.isEmpty, pulled != rows else { return }
        // Not animated when the card is still finding its feet: the very
        // first pull after opening used to fade and resize a card that had
        // only just appeared, which read as the opening animation going wrong.
        guard hasSettled else {
            rows = pulled
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            rows = pulled
        }
    }

    /// Whether this card has been on screen long enough that a change in it is
    /// a change rather than part of its arrival.
    @State private var hasSettled = false

    /// Everything but the row being touched rests back, so the level being
    /// changed is the one being read. Nothing is dimmed when nothing is
    /// touched: a card at rest is not a card with a selection.
    private func isDimmed(_ row: LevelRow) -> Bool {
        guard let focus = dragging ?? hovering ?? focused else { return false }
        return row.id != focus
    }

    private func set(_ row: LevelRow, to fraction: Double) {
        guard row.isAdjustable else { return }
        // Clamped before it is sent and before it is drawn. A gesture that
        // runs past a row's floor used to draw an empty bar over a screen
        // sitting at 18%.
        let wanted = row.clamped(fraction)
        guard let answered = actions.setLevel(row.id, wanted) else { return }
        replace(answered)
    }

    private func mute(_ row: LevelRow) {
        guard let answered = actions.toggleMute(row.id) else { return }
        replace(answered)
    }

    /// The device's answer, in place of what the gesture asked for.
    private func replace(_ answered: LevelRow) {
        guard let index = rows.firstIndex(where: { $0.id == answered.id }) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            rows[index] = answered
        }
    }
}

/// One level: a glyph, a name, a number and a line.
private struct LevelRowView: View {
    let row: LevelRow
    let isDimmed: Bool
    let contrast: ColorSchemeContrast
    let onSet: (Double) -> Void
    let onMute: () -> Void
    let onSwap: () -> Void
    let onDragging: (Bool) -> Void
    let onHover: (Bool) -> Void

    @State private var isDragging = false

    /// One thickness for every row, floor or no floor.
    static let lineThickness: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                glyph
                name
                Spacer(minLength: 4)
                value
            }
            line
            // Under the line it belongs to, never at card level: every fact
            // here is about one device, and a message floating above three
            // rows cannot say which one it means.
            if let note = row.note {
                Text(LevelCopy.note(note))
                    // A step down from the card's other prose. These are
                    // footnotes about one device, not things to read, and at
                    // 11pt the longest of them wanted two lines.
                    .font(.cardCaption)
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(isUrgent(note)
                                                    ? (contrast == .increased ? 0.9 : 0.75)
                                                    : (contrast == .increased ? 0.7 : 0.5)))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        // The reach is taller than the drawing, and the row has to be *at
        // least* this tall without being held *to* it: a row with a sentence
        // under it is taller, and clamping it to 36 drew the next row on top
        // of this one's line.
        .padding(.vertical, 4)
        .frame(minHeight: LevelsCardView.rowHeight, alignment: .top)
        .opacity(isDimmed ? 0.38 : 1)
        // Its own short fade, so it never inherits one. The rows rest at 38%
        // while the pointer is on one of them, and the pointer leaves this
        // card on its way out of the island — so the brightening landed in
        // whatever transaction the island's closing was running, and three
        // rows came back up over the length of that spring, while the card
        // was shrinking. A twelfth of a second, finished before anything else
        // starts.
        .animation(.easeOut(duration: 0.08), value: isDimmed)
        .contentShape(Rectangle())
        .gesture(drag)
        .onHover(perform: onHover)
        // Deliberately no scroll. Scrolling over the island already means
        // "move between cards", and a per-row scroll would fight the gesture
        // the whole app is navigated with. Arrow keys do the same job for the
        // people a scroll gesture was meant to serve.
        // Deliberately not `.focusable()`. Saying so unconditionally made
        // something take focus the instant the card was drawn, so every other
        // row rested back at 38% in a card nobody had touched — and every
        // photograph of it showed one bright row and the rest dimmed.
        .onKeyPress(.leftArrow) { nudge(-1) }
        .onKeyPress(.rightArrow) { nudge(1) }
        .onKeyPress(.downArrow) { nudge(-1) }
        .onKeyPress(.upArrow) { nudge(1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(row.isMuted ? LevelCopy.muted : row.valueText)
        .accessibilityAdjustableAction { direction in
            guard let level = row.drawnLevel else { return }
            switch direction {
            case .increment: onSet(level + LevelsCardView.step)
            case .decrement: onSet(level - LevelsCardView.step)
            @unknown default: break
            }
        }
    }

    /// Pressing anywhere on the row sets the level there; dragging adjusts it.
    /// The whole row is the target, which is why the gesture lives here rather
    /// than on the three points of line.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard row.isAdjustable else { return }
                if !isDragging {
                    isDragging = true
                    onDragging(true)
                }
                onSet(fraction(at: value.location.x))
            }
            .onEnded { _ in
                isDragging = false
                onDragging(false)
            }
    }

    /// Whether this is the answer to something the user just did, as against
    /// a standing fact about the device. The first is brighter, because they
    /// are looking at the thing they just pressed.
    private func isUrgent(_ note: LevelRow.Note) -> Bool {
        note == .refused || note == .partial
    }

    /// One percent a press. Shift is read from the press itself rather than
    /// from a global modifier flag, which `LedgeUI` has no way to see.
    private func nudge(_ direction: Double) -> KeyPress.Result {
        guard let level = row.drawnLevel else { return .ignored }
        onSet(level + LevelsCardView.step * direction)
        return .handled
    }

    /// Measured against the row's own width, which the line spans.
    @State private var width: CGFloat = 1
    private func fraction(at x: CGFloat) -> Double {
        Double(max(0, min(width, x)) / max(width, 1))
    }

    private var glyph: some View {
        Group {
            if row.canMute {
                Button(action: onMute) {
                    glyphImage
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isMuted ? "Unmute" : "Mute")
                .accessibilityAddTraits(.isToggle)
            } else {
                glyphImage
            }
        }
        .frame(width: 20, height: 20)
    }

    private var glyphImage: some View {
        Image(systemName: symbolName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(row.isMuted ? Color.white : .white.opacity(contrast == .increased ? 1 : 0.85))
            .padding(.horizontal, row.isMuted ? 5 : 0)
            .padding(.vertical, row.isMuted ? 1 : 0)
            .background(
                Capsule().fill(row.isMuted ? Color(red: 1, green: 0.27, blue: 0.23) : .clear)
            )
    }

    private var symbolName: String {
        switch row.kind {
        case .sound: HUDReadout.volumeSymbol(level: row.drawnLevel ?? 0, isMuted: row.isMuted)
        case .display: HUDReadout.brightnessSymbol(level: row.drawnLevel ?? 0)
        case .keyboard: "keyboard"
        }
    }

    @ViewBuilder private var name: some View {
        if row.canSwap {
            Button(action: onSwap) {
                HStack(spacing: 3) {
                    nameText
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(contrast == .increased ? 0.7 : 0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the list of outputs.")
        } else {
            nameText
        }
    }

    private var nameText: some View {
        Text(row.name)
            .font(.cardControl)
            .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.85))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Muted shows the word, not the number: unmuting goes back to a level the
    /// ghost line is already showing, so the figure would be saying it twice.
    @ViewBuilder private var value: some View {
        if row.isMuted {
            Text(LevelCopy.muted)
                .font(.cardBadge)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .background(Capsule().fill(Color(red: 1, green: 0.27, blue: 0.23)))
        } else {
            Text(row.valueText)
                .font(.levelValue)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(contrast == .increased ? 1 : 0.92))
                .fixedSize()
        }
    }

    @ViewBuilder private var line: some View {
        if let level = row.drawnLevel {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(contrast == .increased ? 0.3 : 0.14))
                    // The unreachable start of an external display, hatched,
                    // with a tick where the floor is. The fill stops at the
                    // tick whatever the pointer did.
                    if row.floor > 0 {
                        // A dimmer segment and a tick, not a hatch: at three
                        // points tall a diagonal hatch is a grey smudge, and
                        // what this has to say — the line starts here, below
                        // it the picture cannot go — is said by the tick.
                        Capsule()
                            .fill(.white.opacity(contrast == .increased ? 0.22 : 0.08))
                            .frame(width: geo.size.width * row.floor)
                        // Inside the line, not through it. At 7pt in a 3pt
                        // row this stuck out above and below, and the one row
                        // that had a floor read as a thicker bar than the
                        // others — a difference that says nothing and that
                        // the owner noticed straight away.
                        Rectangle()
                            .fill(.white.opacity(contrast == .increased ? 0.85 : 0.65))
                            .frame(width: 1, height: Self.lineThickness)
                            .offset(x: geo.size.width * row.floor)
                    }
                    Capsule()
                        .fill(row.isMuted ? .white.opacity(0.24) : .white)
                        .frame(width: geo.size.width * level)
                }
                .onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { _, new in width = new }
            }
            .frame(height: Self.lineThickness)
        } else {
            // No line to drag. A dashed rule says the row exists and cannot be
            // moved, which is a different thing from an empty bar.
            Rectangle()
                .fill(.clear)
                .frame(height: Self.lineThickness)
                .overlay(alignment: .top) {
                    Path { $0.addLines([.zero, CGPoint(x: 1000, y: 0)]) }
                        .stroke(.white.opacity(contrast == .increased ? 0.4 : 0.2),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(height: 1)
                }
        }
    }
}
