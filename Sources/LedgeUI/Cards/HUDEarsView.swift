import LedgeCore
import SwiftUI

/// The level readout, drawn in the ears either side of the cutout: a glyph on
/// one side, a short bar on the other. No label and no number — the system's
/// own HUD is a glyph and a bar, and this matches it.
///
/// Muted is a distinct state: the glyph sits in a red capsule, echoing the
/// iPhone's silent-mode indicator, and the bar is dimmed.
public struct HUDEarsView: View {

    private let readout: HUDReadout
    private let cutoutWidth: CGFloat
    private let inset: CGFloat
    private let contentOffset: CGFloat
    private let glowing: Bool

    public init(
        readout: HUDReadout,
        cutoutWidth: CGFloat,
        inset: CGFloat,
        contentOffset: CGFloat = 0,
        glowing: Bool = false
    ) {
        self.readout = readout
        self.cutoutWidth = cutoutWidth
        self.inset = inset
        self.contentOffset = contentOffset
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
        HStack(spacing: 0) {
            // A positive offset moves both toward the cutout: the glyph right,
            // the bar left, so the two stay mirrored. User-tunable.
            // Clamped: the stored offset is only slider-bounded, and NaN or a
            // huge value in a transform draws the content off-screen or not at
            // all.
            let safeOffset = contentOffset.isFinite
                ? min(max(contentOffset, -60), 60) : 0
            leading
                .frame(maxWidth: .infinity, alignment: .center)
                .offset(x: safeOffset)

            Color.clear.frame(width: cutoutWidth)

            trailing
                .frame(maxWidth: .infinity, alignment: .center)
                .offset(x: -safeOffset)
        }
        // Only a small safety margin off the rounded corners. A large outer
        // padding would shove the glyph and bar toward the cutout; keeping it
        // small lets `.center` sit each one in the true middle of its ear.
        .padding(.horizontal, 4)
        .animation(Motion.levelChange, value: readout.level)
        .animation(Motion.medium, value: isMuted)
        // Glyph and bar are one readout: a single element beats VoiceOver
        // landing on an unlabelled image and then a bare shape.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controlName)
        .accessibilityValue(isMuted ? "Muted" : "\(Int((readout.level * 100).rounded())) percent")
    }

    @ViewBuilder
    private var leading: some View {
        if isMuted {
            // The muted glyph rides in a red capsule, the way iOS shows silent
            // mode — a splash of colour instead of a bar.
            Image(systemName: readout.symbolName)
                .font(.cardControl)
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 20)
                .background(Color.red, in: Capsule())
        } else {
            // A plain cross-fade between glyphs, not the symbol "replace" effect
            // that shrinks the old icon to a point first — the user wants the new
            // level glyph to simply fade in when a threshold is crossed.
            Image(systemName: readout.symbolName)
                .font(.cardTitle)
                .foregroundStyle(.white)
                .frame(width: 20)
                .contentTransition(.opacity)
                .animation(Motion.medium, value: readout.symbolName)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        // A short bar, not a full-width one — the native HUD's bar is compact.
        // Centred in its ear, mirroring the glyph on the other side.
        LevelBar(
            level: isMuted ? 0 : readout.level,
            tint: isMuted ? .white.opacity(0.3) : .white,
            glowing: glowing && !isMuted
        )
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

struct LevelBar: View {
    let level: Double
    let tint: Color

    /// A definite intrinsic width, so the bar sizes and centres reliably. A
    /// `GeometryReader` here is greedy — it reports the whole offered space and
    /// its content pins to the leading edge, which made the bar read as leaning.
    var width: CGFloat = 36
    var height: CGFloat = 5

    /// Draw the fill with a soft white bloom, like a lit rod.
    var glowing: Bool = false

    var body: some View {
        let fillWidth = width * min(max(level, 0), 1)
        // The track is drawn clearly, not as a faint hint: when it is nearly
        // invisible only the left-aligned fill shows, and a half-full bar then
        // reads as "leaning left" even though it is perfectly centred.
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.34))

            // Soft, even bloom around the whole lit fill — the look of a lit rod.
            Capsule()
                .fill(tint)
                .shadow(color: glowing ? tint.opacity(0.9) : .clear, radius: glowing ? 3.5 : 0)
                .shadow(color: glowing ? tint.opacity(0.55) : .clear, radius: glowing ? 7 : 0)
                .frame(width: fillWidth)
        }
        .frame(width: width, height: height)
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
            // Muted goes red — the same splash the ear HUD shows, so hitting
            // mute while music holds the island reads instantly in the
            // satellite instead of a white ring quietly sitting at its level.
            let muted = readout.kind == .volume && readout.isMuted
            circle {
                // One ring for both states, so muting *drains* the arc to
                // zero instead of snapping — the ring's own level animation
                // carries it. The red heart scales in underneath the white
                // slash; unmuting plays the whole thing backwards.
                ring(level: muted ? 0 : readout.level, tint: .white.opacity(0.92))
                if muted {
                    Circle()
                        .fill(Color.red)
                        .padding(7)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                Image(systemName: readout.symbolName)
                    .font(.system(size: diameter * 0.32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .animation(Motion.medium, value: muted)
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

        case .dictation:
            circle {
                // The waveform macOS puts on the cursor while it listens, so
                // the notch and the pointer say the same thing.
                Image(systemName: "waveform")
                    .font(.cardTitle)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dictating")

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
