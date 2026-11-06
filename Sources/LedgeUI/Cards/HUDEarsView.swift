import LedgeCore
import SwiftUI

/// The level readout: one row under the cutout, the glyph on the left and a
/// long segmented bar beside it. No label and no number.
///
/// Muted is told by the glyph alone: the struck speaker and an empty bar, in
/// plain white, against a plain speaker and an empty bar at a level of zero.
/// Those are different statements and stay different. The level is kept
/// underneath a mute and comes back with it.
///
/// The row is also the control. The pointer changes nothing about how it looks:
/// pressing or dragging on the bar sets the level there, and clicking the
/// speaker mutes.
public struct HUDRowView: View {

    private let readout: HUDReadout
    private let metrics: HUDRowMetrics
    private let glowing: Bool
    private let actions: HUDRowActions?

    /// What a drag is moving, fixed at the first touch. A brightness key
    /// pressed mid-drag retitles the row, and the drag must not follow it.
    @State private var dragging: HUDReadout.Kind?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        readout: HUDReadout,
        metrics: HUDRowMetrics,
        glowing: Bool = false,
        actions: HUDRowActions? = nil
    ) {
        self.readout = readout
        self.metrics = metrics
        self.glowing = glowing
        self.actions = actions
    }

    private var isMuted: Bool { readout.isMuted }

    private var controlName: String {
        switch readout.kind {
        case .volume: "Volume"
        case .brightness: "Brightness"
        case .keyboardBacklight: "Keyboard backlight"
        }
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            glyph
            bar
            if let actions, readout.kind.canBeSetFromTheRow {
                controls(actions)
            }
        }
        .frame(width: metrics.bodyWidth, height: metrics.height, alignment: .topLeading)
        .coordinateSpace(name: Self.rowSpace)
        // Glyph and bar are one readout: a single element beats VoiceOver
        // landing on an unlabelled image and then a bare shape.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controlName)
        .accessibilityValue(isMuted ? "Muted" : "\(Int((readout.level * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard let actions, readout.kind.canBeSetFromTheRow else { return }
            actions.setLevel(readout.kind, Self.stepped(readout.level, direction))
        }
        .accessibilityActions {
            if let actions, readout.kind == .volume {
                Button(isMuted ? "Unmute" : "Mute", action: actions.toggleMute)
            }
        }
    }

    private static let rowSpace = "hudRow"

    /// One VoiceOver step on a bar that is otherwise only dragged: five
    /// percent, clamped.
    nonisolated static func stepped(_ level: Double, _ direction: AccessibilityAdjustmentDirection) -> Double {
        let step: Double = direction == .increment ? 0.05 : -0.05
        return min(max(level + step, 0), 1)
    }

    /// Two invisible targets laid over the drawing, as tall as the row: the bar
    /// is five points high, which is no target at all, and the speaker's glyph
    /// is smaller than the corner it sits in.
    ///
    /// Only the speaker has anything to do in the left one. The sun doesn't,
    /// and a click there or past the bar's end lands on the shape, which
    /// ignores clicks during a readout.
    private func controls(_ actions: HUDRowActions) -> some View {
        HStack(spacing: 0) {
            Group {
                if readout.kind == .volume {
                    // A tap, not a Button. With a Button here, a row arriving
                    // through its transition rendered without its bar in an
                    // off-screen snapshot, for a reason not understood. VoiceOver
                    // gets the same action from the row's own element.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: actions.toggleMute)
                } else {
                    Color.clear
                }
            }
            .frame(width: metrics.barLeading)

            // As wide as the bar and no wider. The margin past its end would
            // otherwise read as full, so a click aimed at something under the
            // notch's corner could turn the sound all the way up. A drag that
            // began on the bar is free to carry on past either end.
            Color.clear
                .contentShape(Rectangle())
                .gesture(levelDrag(actions))
                .frame(width: metrics.barWidth)

            Spacer(minLength: 0)
        }
        .frame(width: metrics.bodyWidth, height: metrics.height)
        // The row can be taken away under a held button: the readout retired,
        // the display unplugged. The gesture never ends then, and a drag left
        // latched swallows every hover exit from there on.
        .onDisappear {
            guard dragging != nil else { return }
            dragging = nil
            actions.setDragging(false)
        }
    }

    /// Measured in the row's own space, so it means the same thing wherever
    /// the press began and carries on past either end of the bar.
    private func levelDrag(_ actions: HUDRowActions) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.rowSpace))
            .onChanged { value in
                let kind = dragging ?? readout.kind
                if dragging == nil {
                    dragging = kind
                    actions.setDragging(true)
                }
                guard let level = metrics.level(atRowX: value.location.x) else { return }
                actions.setLevel(kind, level)
            }
            .onEnded { _ in
                dragging = nil
                actions.setDragging(false)
            }
    }

    /// In a fixed slot and left-aligned, so nothing moves but the waves as the
    /// level climbs. A glyph's own frame is bigger than what it draws and
    /// differs from one to the next, so it is never what positions anything.
    private var glyph: some View {
        // A plain cross-fade between glyphs, not the symbol "replace" effect
        // that shrinks the old icon to a point first.
        Image(systemName: readout.symbolName)
            .font(.system(size: metrics.iconSize, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.opacity)
            .animation(Motion.fast, value: readout.symbolName)
            .frame(width: metrics.iconSlotWidth, height: 0, alignment: .leading)
            .offset(x: metrics.iconLeading, y: metrics.centreY)
    }

    /// Muting drains the bar rather than blanking it, on the same spring as any
    /// other change of level.
    private var bar: some View {
        let shown = isMuted ? 0 : readout.level
        return ZStack(alignment: .topLeading) {
            HUDSegmentsShape(level: 1, gap: metrics.segmentGap, innerRadius: metrics.innerCornerRadius)
                .fill(.white.opacity(contrast == .increased ? 0.5 : 0.34))
            // One shape for all the lit segments, so the glow blooms around
            // them as one rod rather than as sixteen separate lights.
            HUDSegmentsShape(level: shown, gap: metrics.segmentGap, innerRadius: metrics.innerCornerRadius)
                .fill(.white)
                .shadow(color: glowing ? .white.opacity(0.9) : .clear, radius: glowing ? 3.5 : 0)
                .shadow(color: glowing ? .white.opacity(0.55) : .clear, radius: glowing ? 7 : 0)
                .animation(
                    reduceMotion ? Motion.fast : (dragging == nil ? Motion.levelChange : Motion.levelDrag),
                    value: shown
                )
        }
        .frame(width: metrics.barWidth, height: metrics.barHeight)
        .offset(x: metrics.barLeading, y: metrics.barTop)
    }
}

/// What the row asks of the shell when the pointer uses it.
public struct HUDRowActions {
    public var setLevel: (HUDReadout.Kind, Double) -> Void
    public var toggleMute: () -> Void
    public var setDragging: (Bool) -> Void

    public init(
        setLevel: @escaping (HUDReadout.Kind, Double) -> Void,
        toggleMute: @escaping () -> Void,
        setDragging: @escaping (Bool) -> Void
    ) {
        self.setLevel = setLevel
        self.toggleMute = toggleMute
        self.setDragging = setDragging
    }
}

/// The bar's segments, lit up to a level.
///
/// All of them in one shape, because that is what lets the level animate as a
/// single number with a spring that keeps its velocity through a held key. The
/// rectangles come from `HUDSegments`, which snaps them to pixels and clamps the
/// spring's overshoot.
struct HUDSegmentsShape: Shape {

    var level: Double
    let gap: CGFloat
    let innerRadius: CGFloat

    nonisolated var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let whole = HUDSegments.rects(in: rect.size, gap: gap)
        let lit = HUDSegments.lit(level: level, in: whole)
        let outer = rect.height / 2
        for (index, part) in lit.enumerated() {
            // The bar's two ends are fully round, and every other corner barely
            // is. A cut through a segment is an inner corner, whichever one.
            let isCut = part.width < whole[index].width
            let leading = min(index == 0 ? outer : innerRadius, part.width / 2)
            let trailing = min(index == whole.count - 1 && !isCut ? outer : innerRadius, part.width / 2)
            path.addRoundedRect(
                in: part.offsetBy(dx: rect.minX, dy: rect.minY),
                cornerRadii: RectangleCornerRadii(
                    topLeading: leading,
                    bottomLeading: leading,
                    bottomTrailing: trailing,
                    topTrailing: trailing
                )
            )
        }
        return path
    }
}

/// The detached satellite: the circle (or, for the timer, a small capsule)
/// beside the resting island. One seat, several tenants — a level ring, the
/// running timer, the recording indicator, a device announcement.
public struct SatelliteView: View {

    private let content: SatelliteContent
    private let diameter: CGFloat

    public init(content: SatelliteContent, diameter: CGFloat) {
        self.content = content
        self.diameter = diameter
    }

    public var body: some View {
        switch content {
        case .level(let readout):
            // Muted reads the way it does in the readout: the struck speaker
            // and nothing lit, no colour. One ring for both states, so muting
            // *drains* the arc to zero instead of snapping, and the ring's own
            // level animation carries it. Unmuting plays it backwards.
            let muted = readout.kind == .volume && readout.isMuted
            circle {
                ring(level: muted ? 0 : readout.level, tint: .white.opacity(0.92))
                Image(systemName: readout.symbolName)
                    .font(.system(size: diameter * 0.32, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
            }
            .animation(Motion.medium, value: readout.symbolName)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(readout.kind.label)
            .accessibilityValue(muted ? "Muted" : "\(Int((readout.level * 100).rounded())) percent")

        case .timer(let remaining, let total, let isBreak, let isRunning):
            // The countdown inside the disc, the progress as the disc's own
            // rim — the remaining arc drains as the session runs.
            // A zero total is the stopwatch counting up: no arc to drain, so
            // the rim stays a full quiet ring around the climbing digits.
            circle {
                ring(
                    level: total > 0
                        ? min(max(remaining / total, 0), 1) : 1,
                    tint: total > 0
                        ? (isBreak ? Color.green : Color.orange)
                        : Color.white.opacity(0.35)
                )
                Text(SatelliteContent.timerLabel(remaining: remaining))
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    // Low enough for the *longest* label the clamp allows:
                    // "99h 59m" needs ≈0.5 of the disc's 23pt, and a floor
                    // above what a label needs makes SwiftUI abandon scaling
                    // and truncate at full size — a truncated countdown is
                    // worse than a small one. m:ss labels still render near
                    // full size; only hand-edited marathon timers shrink.
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                    .foregroundStyle(isRunning ? .white : .white.opacity(0.55))
                    .padding(.horizontal, 5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(total > 0 ? (isBreak ? "Break timer" : "Focus timer") : "Stopwatch")
            .accessibilityValue(
                total > 0
                    ? "\(SatelliteContent.timerLabel(remaining: remaining)) remaining"
                    : "\(SatelliteContent.timerLabel(remaining: remaining)) elapsed"
            )

        case .keepAwake(let remaining):
            // The cup, not the number.
            //
            // This seat is only ever taken while something *else* is holding
            // the island — the hold has already had its few seconds in the
            // ears and stepped back. What is wanted here is the reminder that
            // the Mac is being held awake, which the glyph says at a glance;
            // the figure beside it asked to be read, and read as a stray
            // number with no units next to someone's music. The time left is
            // still on the card, a swipe away, where there is room to say
            // what it is a time left *of*.
            circle {
                ring(level: 1, tint: Color.white.opacity(0.35))
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: diameter * 0.34, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(KeepAwakeCopy.title)
            // "On remaining" is not a sentence. A hold with no end is read as
            // the state it is in; only a hold with a deadline has a remainder.
            .accessibilityValue(remaining == nil
                ? KeepAwakeCopy.on
                : "\(SatelliteContent.keepAwakeLabel(remaining: remaining)) remaining")

        case .privacy(let camera, let microphone):
            circle {
                // Apple's own colour language: green for camera, amber for mic.
                HStack(spacing: 2.5) {
                    if camera { Circle().fill(.green).frame(width: 6, height: 6) }
                    if microphone { Circle().fill(.orange).frame(width: 6, height: 6) }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                camera && microphone ? "Camera and microphone in use"
                    : camera ? "Camera in use" : "Microphone in use"
            )

        case .charging(let level):
            circle {
                ring(
                    level: level.isFinite ? min(max(level, 0), 1) : 0,
                    tint: Color.green
                )
                Text("\(Int((min(max(level, 0), 1) * 100).rounded()))")
                    .font(.cardBadge)
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Charging")
            .accessibilityValue("\(Int((min(max(level, 0), 1) * 100).rounded())) percent")

        case .device(let symbolName, let tint):
            circle {
                Image(systemName: symbolName)
                    .font(.system(size: diameter * 0.34, weight: .medium))
                    .foregroundStyle(tint == .charging ? .green : .white)
            }
            // The satellite only knows the glyph, not the device's name — the
            // ears beside it carry that — so it says what it is, not who.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tint == .charging ? "Charging" : "Device connected")
        }
    }

    private func circle(@ViewBuilder _ inner: () -> some View) -> some View {
        ZStack {
            Circle().fill(.black)
            inner()
        }
        .frame(width: diameter, height: diameter)
    }

    private func ring(level: Double, tint: some ShapeStyle) -> some View {
        Group {
            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 2.5)
                .padding(3)
            Circle()
                .trim(from: 0, to: max(0.001, level))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(3)
                .animation(Motion.fast, value: level)
        }
    }
}
