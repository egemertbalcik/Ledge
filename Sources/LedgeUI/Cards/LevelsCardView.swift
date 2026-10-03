import LedgeCore
import SwiftUI

/// What the levels card can ask the shell to do. Values and device lists are
/// *pulled* when the card opens — the same one-shot rule the HUD's hover
/// panel uses — so no enumeration ever runs while the card is closed.
public struct LevelsActions {
    public var outputs: () -> [AudioOutputOption]
    public var displays: () -> [DisplayLevelOption]
    public var setOutputVolume: (UInt32, Double) -> LevelFeedback?
    public var setDisplayBrightness: (UInt32, Double) -> Void
    /// Latches a drag in flight, so the overlay stays open while the pointer
    /// wanders off the bar being dragged.
    public var setDragging: (Bool) -> Void

    public init(
        outputs: @escaping () -> [AudioOutputOption] = { [] },
        displays: @escaping () -> [DisplayLevelOption] = { [] },
        setOutputVolume: @escaping (UInt32, Double) -> LevelFeedback? = { _, _ in nil },
        setDisplayBrightness: @escaping (UInt32, Double) -> Void = { _, _ in },
        setDragging: @escaping (Bool) -> Void = { _ in }
    ) {
        self.outputs = outputs
        self.displays = displays
        self.setOutputVolume = setOutputVolume
        self.setDisplayBrightness = setDisplayBrightness
        self.setDragging = setDragging
    }
}

/// Sound and brightness in iOS Control Centre's own language: two thick
/// continuous-corner sliders, the glyph and name riding inside the bar, no
/// chrome around them. Touching one bar dims the other — the focus is the
/// level being changed.
public struct LevelsCardView: View {

    private let actions: LevelsActions
    private let isCompactWidth: Bool

    /// The latest hardware readout, so the keys move the bars while the card
    /// is open. A bar being dragged ignores it — the pointer owns that one.
    private let liveLevel: HUDReadout?

    public init(
        actions: LevelsActions = LevelsActions(),
        isCompactWidth: Bool = false,
        liveLevel: HUDReadout? = nil
    ) {
        self.actions = actions
        self.isCompactWidth = isCompactWidth
        self.liveLevel = liveLevel
    }

    private enum Bar { case sound, display }

    /// Snapshots taken when the card opens; drags update them locally so the
    /// bar follows the pointer, and the hardware follows the bar.
    @State private var output: AudioOutputOption?
    @State private var display: DisplayLevelOption?
    @State private var volume: Double = 0
    @State private var brightness: Double = 0
    /// Whether the current output is muted. Kept beside the level because
    /// macOS leaves the scalar where it was: without this the bar opened at
    /// its pre-mute value over a silent Mac.
    @State private var isMuted = false

    /// The bar being dragged. The other one dims while it is set — iOS's own
    /// cue that the interaction owns exactly one control.
    @State private var active: Bar?

    public var body: some View {
        VStack(spacing: isCompactWidth ? 9 : 12) {
            bar(
                .sound,
                symbol: volumeSymbol,
                name: soundName,
                level: displayedVolume
            ) { level in
                setVolume(level)
            }
            .accessibilityLabel("Volume")
            .accessibilityValue(isMuted ? "Muted" : "\(Int((volume * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                // Each step is a whole interaction of its own — there is no
                // drag to hold a target through — so each one re-reads the
                // devices before working out where the level should land.
                refreshDevices()
                setVolume(Self.stepped(displayedVolume, direction))
            }

            bar(
                .display,
                symbol: HUDReadout.brightnessSymbol(level: brightness),
                name: display?.name ?? "Display",
                level: brightness
            ) { level in
                brightness = level
                if let display { actions.setDisplayBrightness(display.id, level) }
            }
            .accessibilityLabel("Brightness")
            .accessibilityValue("\(Int((brightness * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                refreshDevices()
                brightness = Self.stepped(brightness, direction)
                if let display { actions.setDisplayBrightness(display.id, brightness) }
            }
        }
        .padding(.horizontal, isCompactWidth ? 12 : 8)
        .padding(.vertical, isCompactWidth ? 10 : 14)
        .onAppear(perform: snapshot)
        // The card holds the *device*, not just its level: every adjustment
        // writes to the output it snapshotted when it opened. Switching
        // outputs elsewhere — headphones in, AirPlay picked in Control Centre
        // — left it showing one device's volume and moving another's, because
        // an arriving readout updated the number and never the identity.
        //
        // It re-reads while it is on screen, and never mid-drag: the bar under
        // the pointer is the truth until the pointer lifts.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.deviceRefreshInterval)
                guard !Task.isCancelled, active == nil else { continue }
                refreshDevices()
            }
        }
        .onChange(of: liveLevel) { _, readout in
            guard let readout else { return }
            // Key steps glide the way the HUD's own bar does; a drag never
            // comes through here, so the pointer keeps its raw tracking.
            withAnimation(Motion.fast) {
                switch readout.kind {
                case .volume where active != .sound:
                    isMuted = readout.isMuted
                    volume = readout.level
                case .brightness where active != .display:
                    brightness = readout.level
                default:
                    break
                }
            }
        }
    }

    /// One VoiceOver step on a drag-only bar: five percent, clamped.
    private static func stepped(_ level: Double, _ direction: AccessibilityAdjustmentDirection) -> Double {
        let step: Double = direction == .increment ? 0.05 : -0.05
        return min(max(level + step, 0), 1)
    }

    /// What the bar draws: nothing while muted, whatever the scalar says.
    private var displayedVolume: Double { isMuted ? 0 : volume }

    /// The device name, or the state when it overrides it — a muted output is
    /// worth saying outright rather than leaving to a glyph.
    private var soundName: String {
        guard let name = output?.name else { return isMuted ? "Muted" : "Sound" }
        return isMuted ? "\(name) — Muted" : name
    }

    /// The one path that moves the sound bar. Dragging or stepping a muted bar
    /// unmutes it, which is what the hardware keys do and what the shell's
    /// action performs on the device.
    private func setVolume(_ level: Double) {
        volume = level
        if level > 0 { isMuted = false }
        guard let output else { return }
        let shown = Self.adopting(
            actions.setOutputVolume(output.id, level),
            requested: level,
            wasMuted: isMuted
        )
        volume = shown.level
        isMuted = shown.isMuted
    }

    /// What the bar should show after a write: the device's answer when it
    /// gave one, and the gesture's own value when it did not.
    ///
    /// A clamped or refused write must not leave the bar at a level the output
    /// is not at — the control would be lying until the next poll corrected
    /// it, which is the failure the readback exists to prevent. A device that
    /// answers nothing (no such output) leaves the gesture's value in place
    /// rather than snapping the bar to zero.
    static func adopting(
        _ feedback: LevelFeedback?,
        requested: Double,
        wasMuted: Bool
    ) -> (level: Double, isMuted: Bool) {
        guard let feedback else {
            return (min(max(requested, 0), 1), requested > 0 ? false : wasMuted)
        }
        return (feedback.level, feedback.isMuted)
    }

    private var volumeSymbol: String {
        HUDReadout.volumeSymbol(level: volume, isMuted: isMuted)
    }

    /// How often an open card re-reads which devices it is pointed at.
    private static let deviceRefreshInterval: Duration = .seconds(1)

    /// What an open card should point at, having re-read the devices.
    ///
    /// Separated from the act of pointing at it because this is the decision
    /// that was wrong: the card kept the device it opened on and wrote every
    /// adjustment there, however the system's output had changed since.
    ///
    /// - Returns: the output to adopt, and whether to take its level with it.
    ///   A level is adopted only when the *device* changed — the current
    ///   device's level is already arriving through `liveLevel`, and writing
    ///   it here would fight the animation carrying it.
    nonisolated static func retarget(
        current: AudioOutputOption?, outputs: [AudioOutputOption]
    ) -> (output: AudioOutputOption?, adoptLevel: Bool) {
        let fresh = outputs.first(where: \.isCurrent) ?? outputs.first
        guard let fresh else { return (nil, current != nil) }
        if fresh.id != current?.id { return (fresh, true) }
        // The same device, but its name or mute state may have moved, and both
        // are on screen.
        return (fresh, false)
    }

    /// The device an interaction should write to.
    ///
    /// The rule the polling alone could not keep: an interaction *begins* by
    /// re-reading, and then holds what it found until it ends. Polling leaves a
    /// gap exactly the width of this — the output switches, the hand starts
    /// dragging before the next tick, and the refresh is suspended for the
    /// whole gesture, so every write lands on the device that was current a
    /// second ago.
    ///
    /// - Parameters:
    ///   - held: the target this interaction has already fixed on, or nil if
    ///     it is only now beginning.
    ///   - enumerate: the devices, read only when one is beginning. A drag in
    ///     progress must not re-read: moving the target under the hand is the
    ///     opposite mistake, and the same one seen from the other side.
    nonisolated static func interactionTarget(
        holding held: AudioOutputOption?,
        enumerate: () -> [AudioOutputOption]
    ) -> AudioOutputOption? {
        if let held { return held }
        let outputs = enumerate()
        return outputs.first(where: \.isCurrent) ?? outputs.first
    }

    /// Re-reads the current output and display, and points the card at them.
    private func refreshDevices() {
        let (fresh, adoptLevel) = Self.retarget(current: output, outputs: actions.outputs())
        output = fresh
        if adoptLevel {
            volume = fresh?.level ?? 0
            isMuted = fresh?.isMuted ?? false
        }

        let displays = actions.displays()
        let currentDisplay = displays.first(where: \.isCurrent) ?? displays.first
        if currentDisplay?.id != display?.id {
            display = currentDisplay
            brightness = currentDisplay?.level ?? 0
        }
    }

    private func snapshot() {
        let outputs = actions.outputs()
        output = outputs.first(where: \.isCurrent) ?? outputs.first
        volume = output?.level ?? 0
        isMuted = output?.isMuted ?? false
        let displays = actions.displays()
        display = displays.first(where: \.isCurrent) ?? displays.first
        brightness = display?.level ?? 0
    }

    @ViewBuilder
    private func barLabel(symbol: String, name: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: isCompactWidth ? 12 : 14, weight: .semibold))
            Text(name)
                .font(.system(size: isCompactWidth ? 11 : 12, weight: .medium))
                .lineLimit(1)
        }
    }

    /// One Control-Centre slider: a thick capsule-cornered track, white fill,
    /// the glyph and name inside its leading edge. iOS draws exactly this for
    /// the expanded Sound and Display controls.
    @ViewBuilder
    private func bar(
        _ kind: Bar,
        symbol: String,
        name: String,
        level: Double,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        let height: CGFloat = isCompactWidth ? 34 : 40
        let dimmed = active != nil && active != kind
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let shape = RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            ZStack(alignment: .leading) {
                shape.fill(.white.opacity(0.16))
                // The fill is clipped by the track rather than drawn as its
                // own rounded shape: a rounded fill at low levels becomes a
                // squashed pill narrower than its own corners.
                Rectangle()
                    .fill(.white.opacity(0.95))
                    .frame(width: width * min(max(level, 0), 1))
                    .clipShape(shape)

                // Drawn twice and split at the fill's edge, the way iOS
                // does it per-pixel: white where the label rides the dark
                // track, dark where the fill has swept under it — a single
                // color left the tail unreadable at mid levels.
                barLabel(symbol: symbol, name: name)
                    .foregroundStyle(.white.opacity(0.75))
                    .overlay(alignment: .leading) {
                        barLabel(symbol: symbol, name: name)
                            .foregroundStyle(Color.black.opacity(0.7))
                            .mask(alignment: .leading) {
                                Rectangle()
                                    .frame(width: max(width * min(max(level, 0), 1)
                                        - (isCompactWidth ? 11 : 14), 0))
                            }
                    }
                    .padding(.leading, isCompactWidth ? 11 : 14)
            }
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // The first event of a drag re-reads the devices, and
                        // the rest of the drag keeps whatever that found.
                        //
                        // Polling alone left a gap this fits in exactly: the
                        // output switches, the hand starts dragging before the
                        // next tick, and the refresh is then suspended for the
                        // whole gesture — so every write of that drag lands on
                        // the device that is no longer playing. Refreshing
                        // here closes it; refreshing again mid-drag would move
                        // the target under the hand, which is the opposite
                        // mistake.
                        if active != kind {
                            // Beginning: read once, and hold it for the rest
                            // of the gesture.
                            if kind == .sound {
                                output = Self.interactionTarget(
                                    holding: nil, enumerate: actions.outputs
                                )
                                volume = output?.level ?? volume
                                isMuted = output?.isMuted ?? isMuted
                            } else {
                                refreshDevices()
                            }
                            active = kind
                        }
                        actions.setDragging(true)
                        onChange(min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { _ in
                        active = nil
                        actions.setDragging(false)
                    }
            )
        }
        .frame(height: height)
        .opacity(dimmed ? 0.35 : 1)
        .animation(.easeOut(duration: 0.16), value: active)
    }
}
