import LedgeCore
import SwiftUI

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

    public init(
        payload: TimerPayload,
        onContentHeight: @escaping (CGFloat) -> Void = { _ in },
        actions: TimerActions = TimerActions(),
        isCompactWidth: Bool = false,
        // The gallery renders the dial face, which is otherwise only reachable
        // by clicking — a state nobody can review is a state that drifts.
        startsDialling: Bool = false
    ) {
        self.payload = payload
        self.onContentHeight = onContentHeight
        self.actions = actions
        self.isCompactWidth = isCompactWidth
        _isDialling = State(initialValue: startsDialling)
    }

    /// Which face is showing. Seeded from the payload's own mode — a card
    /// that arrives wearing the stopwatch face opens on it — and switched by
    /// the header from then on.
    /// Tells the shell how tall this card's content is. See the body.
    private let onContentHeight: (CGFloat) -> Void

    @State private var face: Face?

    /// Whether the dial is showing, and what it is showing. The length
    /// survives closing the dial, so a user who dials 40 minutes, thinks
    /// better of it and comes back finds 40 rather than the default again.
    @State private var isDialling = false
    @State private var dialledMinutes = 25

    enum Face: Equatable {
        case timer
        case stopwatch
    }

    private var tint: Color { payload.isBreak ? .green : .orange }

    /// The face on show: the user's pick, else whatever the payload wears.
    private var shownFace: Face {
        face ?? (payload.mode == .stopwatch ? .stopwatch : .timer)
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
                    if payload.hasCountdown { full } else { idle }
                case .stopwatch:
                    stopwatch
                }
            }
            .padding(.horizontal, 12)
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
            // A countdown that ends while the stopwatch is going leaves the
            // card wearing the stopwatch face; a stale user pick must not
            // keep showing empty timer chips over a live stopwatch.
            .onChange(of: payload.mode) { _, mode in
                if mode == .stopwatch { face = .stopwatch }
            }
            .animation(Motion.medium, value: shownFace)
        }
    }

    // MARK: - Timer face

    /// The ready card, in the language of iOS's quick timer: the identity on
    /// top, then a full-width row of duration chips — the pomodoro pair in
    /// their accents, one-off countdowns beside them. Recently used lengths
    /// take the neutral chips first, the way iOS's Timer offers Recents.
    private var idle: some View {
        VStack(alignment: .leading, spacing: isCompactWidth ? 8 : 10) {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.system(size: isCompactWidth ? 12 : 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(
                        width: isCompactWidth ? 26 : 36,
                        height: isCompactWidth ? 26 : 36
                    )
                    .background(Circle().fill(.orange.opacity(0.22)))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Timer")
                        .font(.system(size: isCompactWidth ? 12 : 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(payload.recents.isEmpty ? "Pomodoro & quick timers" : "Recents & quick timers")
                        .font(.system(size: isCompactWidth ? 9 : 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }

            if isDialling {
                dial
            } else {
                HStack(spacing: 7) {
                    presetChip("Focus", subtitle: "\(Int(payload.total / 60))m", tint: .orange) {
                        actions.startFocus()
                    }
                    presetChip("Break", subtitle: nil, tint: .green) {
                        actions.startBreak()
                    }
                    ForEach(quickMinutes, id: \.self) { minutes in
                        presetChip(Self.minutesLabel(minutes), subtitle: nil, tint: nil) {
                            actions.startCustom(minutes)
                        }
                    }
                    // Not a length: the way to any length. A dial glyph rather
                    // than a number, so it does not read as one more preset.
                    if !isCompactWidth {
                        presetChip(nil, symbol: "dial.medium", subtitle: nil, tint: nil) {
                            isDialling = true
                        }
                        .accessibilityLabel("Choose a length")
                    }
                }
            }
        }
        .padding(.horizontal, isCompactWidth ? 12 : 0)
        .padding(.vertical, isCompactWidth ? 9 : 0)
    }

    /// The dial face: the length you are choosing, the rule you choose it on,
    /// and the two things you can do about it.
    ///
    /// The number is the hero and everything else is quiet — the rule fades at
    /// its ends, the buttons are the card's ordinary capsules. One bright
    /// thing, the marker, says where the value is read.
    private var dial: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(dialledMinutes)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    // The unit sits on the number's baseline, quiet and small:
                    // the value is what changes as you drag, and the unit is
                    // only there so the number means something.
                    .contentTransition(.numericText())
                Text(dialledMinutes < 60 ? "min" : DurationDial.spoken(dialledMinutes))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .animation(Motion.medium, value: dialledMinutes)

            DurationDialView(
                minutes: $dialledMinutes,
                tint: tint,
                setDragging: actions.setDragging
            )

            HStack(spacing: 7) {
                capsuleButton("Back", tint: nil) { isDialling = false }
                capsuleButton("Start", tint: tint) {
                    actions.startCustom(dialledMinutes)
                    isDialling = false
                }
            }
        }
        .transition(.opacity)
    }

    /// The neutral chips: recents first, the defaults filling what is left.
    private var quickMinutes: [Int] {
        let slots = isCompactWidth ? 2 : 3
        var minutes = payload.recents
        for fallback in [15, 45, 60] where minutes.count < slots && !minutes.contains(fallback) {
            minutes.append(fallback)
        }
        return Array(minutes.prefix(slots))
    }

    /// "15m", "1h", "1h 30m" — a chip label for a length in minutes.
    static func minutesLabel(_ minutes: Int) -> String {
        let sane = max(1, minutes)
        if sane < 60 { return "\(sane)m" }
        let hours = sane / 60, rest = sane % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// One duration chip: equal-width capsules filling the row, the way the
    /// Control Centre timer offers its durations.
    private func presetChip(
        _ label: String?,
        symbol: String? = nil,
        subtitle: String?,
        tint: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                } else if let label {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(tint ?? .white)
            .frame(maxWidth: .infinity)
            .frame(height: isCompactWidth ? 30 : 38)
            .background(
                Capsule().fill((tint ?? .white).opacity(tint == nil ? 0.13 : 0.22))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PressableCircleStyle())
        .accessibilityLabel(label.map { "Start \($0) timer" } ?? "")
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
                    Text(payload.isFinished ? "\(payload.label) done" : payload.label)
                        .font(.cardFigure)
                        .foregroundStyle(tint)
                        .lineLimit(1)
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
            HStack(spacing: 8) {
                capsuleButton("Cancel", tint: nil) { actions.cancel() }
                capsuleButton(payload.isRunning ? "Pause" : "Resume", tint: tint) {
                    actions.toggle()
                }
                if !payload.isCustom {
                    capsuleButton("Skip", tint: nil) { actions.skip() }
                }
            }
        }
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
    /// A one-off countdown of the given minutes — the quick-timer chips.
    public var startCustom: (Int) -> Void
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
        setDragging: @escaping (Bool) -> Void = { _ in },
        stopwatchToggle: @escaping () -> Void = {},
        stopwatchLap: @escaping () -> Void = {},
        stopwatchReset: @escaping () -> Void = {}
    ) {
        self.setDragging = setDragging
        self.stopwatchToggle = stopwatchToggle
        self.stopwatchLap = stopwatchLap
        self.stopwatchReset = stopwatchReset
        self.toggle = toggle
        self.cancel = cancel
        self.skip = skip
        self.startFocus = startFocus
        self.startBreak = startBreak
        self.startCustom = startCustom
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
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.cardCaption)
                Text(title)
                    .font(.cardSmallFigure)
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
