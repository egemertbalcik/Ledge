import LedgeCore
import SwiftUI

/// The level readout: one row under the cutout, the glyph on the left and a
/// long segmented bar beside it. No label and no number.
///
/// Muted is told by the glyph alone: the struck speaker and an empty bar, in
/// plain white, against a plain speaker and an empty bar at a level of zero.
/// Those are different statements and stay different. The level is kept
/// underneath a mute and comes back with it.
public struct HUDRowView: View {

    private let readout: HUDReadout
    private let metrics: HUDRowMetrics
    private let glowing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(readout: HUDReadout, metrics: HUDRowMetrics, glowing: Bool = false) {
        self.readout = readout
        self.metrics = metrics
        self.glowing = glowing
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
        }
        .frame(width: metrics.bodyWidth, height: metrics.height, alignment: .topLeading)
        // Glyph and bar are one readout: a single element beats VoiceOver
        // landing on an unlabelled image and then a bare shape.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controlName)
        .accessibilityValue(isMuted ? "Muted" : "\(Int((readout.level * 100).rounded())) percent")
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
                .animation(reduceMotion ? Motion.fast : Motion.levelChange, value: shown)
        }
        .frame(width: metrics.barWidth, height: metrics.barHeight)
        .offset(x: metrics.barLeading, y: metrics.barTop)
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

/// The panel shown under the hardware cutout while the pointer is on the HUD,
/// in the Control-Centre idiom: a bold title line, then a full-width slider
/// flanked by the quiet/dim glyph on the left and the loud/bright one on the
/// right. The whole slider row is draggable.
public struct HUDAdjustPanel: View {

    private let readout: HUDReadout
    private let glowing: Bool
    private let outputs: [AudioOutputOption]
    private let displays: [DisplayLevelOption]
    private let onAdjust: (Double) -> Void
    private let onDragging: (Bool) -> Void
    private let onSelectOutput: (UInt32) -> Void
    private let onAdjustDisplay: (UInt32, Double) -> Void

    public init(
        readout: HUDReadout,
        glowing: Bool = false,
        outputs: [AudioOutputOption] = [],
        displays: [DisplayLevelOption] = [],
        onAdjust: @escaping (Double) -> Void,
        onDragging: @escaping (Bool) -> Void = { _ in },
        onSelectOutput: @escaping (UInt32) -> Void = { _ in },
        onAdjustDisplay: @escaping (UInt32, Double) -> Void = { _, _ in }
    ) {
        self.readout = readout
        self.glowing = glowing
        self.outputs = outputs
        self.displays = displays
        self.onAdjust = onAdjust
        self.onDragging = onDragging
        self.onSelectOutput = onSelectOutput
        self.onAdjustDisplay = onAdjustDisplay
    }

    /// The order the rows opened in, frozen for the life of the panel.
    ///
    /// The list is sorted current-first, which is right when it is drawn — and
    /// wrong the instant it is used. Touching another output makes *it* the
    /// current one, the list re-sorts, and the row leaps to the top from under
    /// the pointer, taking the row that was there down with it. The user asked
    /// for a level on one device and the panel rearranged itself.
    ///
    /// So the sort decides the order once, when the panel appears, and after
    /// that the rows stay where they are. A device that arrives mid-panel goes
    /// on the end rather than jumping the queue.
    @State private var outputOrder: [UInt32] = []
    @State private var displayOrder: [UInt32] = []

    /// The display the pointer is on first, so the screen the keys act on is the
    /// one under your eyes at the top — the same ordering rule the audio list
    /// uses for the current route.
    private var orderedDisplays: [DisplayLevelOption] {
        let sorted = displays.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        // Capped to the same count the shape's height budget plans for
        // (`hudExtraRows` caps brightness at 4): an uncapped fifth display
        // would render but clip behind the hardware cutout.
        return Array(Self.held(sorted, in: displayOrder).prefix(4))
    }

    /// Current route first, the rest alphabetical, capped so a machine with a
    /// dozen virtual devices cannot swallow the screen.
    private var orderedOutputs: [AudioOutputOption] {
        let sorted = outputs.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return Array(Self.held(sorted, in: outputOrder).prefix(5))
    }

    /// Re-orders a freshly sorted list to the order it was first seen in.
    /// Anything not in that order — a device plugged in while the panel is
    /// open — keeps its sorted position at the end.
    /// `nonisolated` because it is arithmetic on two lists and nothing else —
    /// a `View` is main-actor isolated by default, and inheriting that here
    /// meant the rule could only be exercised from the main thread.
    nonisolated static func held<T: Identifiable>(_ items: [T], in order: [T.ID]) -> [T] {
        guard !order.isEmpty else { return items }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return items.enumerated().sorted { left, right in
            let a = rank[left.element.id]
            let b = rank[right.element.id]
            switch (a, b) {
            case let (a?, b?): return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            // Both new: keep the sort they arrived in.
            case (nil, nil): return left.offset < right.offset
            }
        }.map(\.element)
    }

    private var title: String {
        switch readout.kind {
        case .volume:
            // The actual destination beats a generic "Sound": seeing "AirPods
            // Pro" tells you what you are about to make louder.
            readout.deviceName ?? "Sound"
        case .brightness: "Display"
        case .keyboardBacklight: "Keyboard"
        }
    }

    private var minSymbol: String {
        switch readout.kind {
        case .volume: readout.isMuted ? "speaker.slash.fill" : "speaker.fill"
        case .brightness: "sun.min.fill"
        case .keyboardBacklight: "light.min"
        }
    }

    private var maxSymbol: String {
        switch readout.kind {
        case .volume: "speaker.wave.3.fill"
        case .brightness: "sun.max.fill"
        case .keyboardBacklight: "light.max"
        }
    }

    public var body: some View {
        VStack(spacing: 10) {
            if readout.kind == .brightness, orderedDisplays.count > 1 {
                // More than one screen: a row each, every one live. Unlike the
                // audio list there is no faded "other" state, because both
                // displays are lit and both are directly adjustable.
                ForEach(orderedDisplays) { display in
                    displaySection(display)
                }
            } else if readout.kind == .volume, !orderedOutputs.isEmpty {
                // One section per real route: its name, then its own bar. The
                // current route is bright and draggable; the others sit faded
                // beneath it, and tapping one switches the output to it.
                ForEach(orderedOutputs) { output in
                    deviceSection(output)
                }
            } else {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                activeSlider
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        // The order is decided once, on the way in. `orderedOutputs` reads
        // the frozen order, so it is captured from the plain sort here — and
        // re-captured if the lists arrive a beat after the panel does.
        .onAppear(perform: captureOrders)
        .onChange(of: outputs.count) { _, _ in captureOrders() }
        .onChange(of: displays.count) { _, _ in captureOrders() }
        // A panel that closes and opens again is a fresh look at the machine,
        // and deserves a fresh sort. SwiftUI may keep this view's identity
        // across the two, so the reset is explicit.
        .onDisappear {
            outputOrder = []
            displayOrder = []
        }
    }

    private func captureOrders() {
        if outputOrder.isEmpty, !outputs.isEmpty {
            outputOrder = outputs
                .sorted {
                    if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                .map(\.id)
        }
        if displayOrder.isEmpty, !displays.isEmpty {
            displayOrder = displays
                .sorted {
                    if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
                    if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                .map(\.id)
        }
    }

    /// One display: its name, then its own live slider.
    @ViewBuilder
    private func displaySection(_ display: DisplayLevelOption) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .font(.cardLabel)
                    .frame(width: 16)
                Text(display.name)
                    .font(.system(size: 12, weight: display.isCurrent ? .bold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
            .foregroundStyle(display.isCurrent ? .white : .white.opacity(0.6))

            slider(level: display.level) { onAdjustDisplay(display.id, $0) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(display.name) brightness")
                .accessibilityValue("\(Int((display.level * 100).rounded())) percent")
                .accessibilityAdjustableAction { direction in
                    onAdjustDisplay(display.id, Self.stepped(display.level, direction))
                }
        }
    }

    /// The current route: bright name, live draggable slider between the
    /// quiet/loud glyphs.
    @ViewBuilder
    private func deviceSection(_ output: AudioOutputOption) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: Self.deviceSymbol(for: output.name))
                    .font(.cardLabel)
                    .frame(width: 16)
                Text(output.name)
                    .font(.system(size: 12, weight: output.isCurrent ? .bold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
            .foregroundStyle(output.isCurrent ? .white : .white.opacity(0.45))

            if output.isCurrent {
                activeSlider
            } else {
                // The route's own level, dimmed — informational until tapped.
                // Muted reads as zero here too: the scalar survives a mute and
                // would otherwise show a level nothing is playing at.
                fadedBar(level: output.isMuted ? 0 : (output.level ?? 0))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(output.name) volume")
                    .accessibilityValue(
                        output.isMuted
                            ? "Muted"
                            : "\(Int(((output.level ?? 0) * 100).rounded())) percent"
                    )
                    // Tapping the row is the only way to switch to it; VoiceOver
                    // gets the same as the row's default action.
                    .accessibilityAction { onSelectOutput(output.id) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !output.isCurrent else { return }
            onSelectOutput(output.id)
        }
    }

    private var activeSlider: some View {
        slider(level: readout.level, onChange: onAdjust)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(controlName)
            .accessibilityValue("\(Int((readout.level * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                onAdjust(Self.stepped(readout.level, direction))
            }
    }

    /// One VoiceOver step on a drag-only bar: five percent, clamped.
    static func stepped(_ level: Double, _ direction: AccessibilityAdjustmentDirection) -> Double {
        let step: Double = direction == .increment ? 0.05 : -0.05
        return min(max(level + step, 0), 1)
    }

    private var controlName: String {
        switch readout.kind {
        case .volume: "Volume"
        case .brightness: "Brightness"
        case .keyboardBacklight: "Keyboard backlight"
        }
    }

    /// The draggable bar. Extracted so every display row gets a genuinely live
    /// slider rather than the audio list's read-only faded bar.
    private func slider(level: Double, onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 11) {
            Image(systemName: minSymbol)
                .font(.cardTitle)
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 18)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let fill = width * min(max(level, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule()
                        .fill(.white)
                        .shadow(color: glowing ? .white.opacity(0.9) : .clear, radius: glowing ? 3.5 : 0)
                        .shadow(color: glowing ? .white.opacity(0.55) : .clear, radius: glowing ? 7 : 0)
                        .frame(width: fill)
                }
                .contentShape(Rectangle().inset(by: -10))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Latch first: the shell must know a drag is in
                            // flight before the cursor can wander off the
                            // shape mid-slide.
                            onDragging(true)
                            onChange(min(max(value.location.x / width, 0), 1))
                        }
                        .onEnded { _ in onDragging(false) }
                )
                .animation(Motion.fast, value: level)
            }
            .frame(height: 6)

            Image(systemName: maxSymbol)
                .font(.cardTitle)
                .foregroundStyle(.white)
                .frame(width: 18)
        }
    }

    /// A dim, non-interactive bar showing another route's level.
    private func fadedBar(level: Double) -> some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: width * min(max(level, 0), 1))
            }
        }
        .frame(height: 5)
        .padding(.horizontal, 29)   // aligns with the active slider's track
    }

    private static func deviceSymbol(for name: String) -> String {
        AudioDeviceSymbol.forName(name)
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
