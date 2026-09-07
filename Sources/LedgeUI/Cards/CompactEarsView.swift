import LedgeCore
import SwiftUI

/// The compact presentation: content sits in the two "ears" either side of the
/// cutout, and the middle is left empty because there is physical hardware
/// behind it. This is what makes a peek read as the notch itself widening
/// rather than a window appearing under it.
public struct CompactEarsView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.weatherUnits) private var weatherUnits

    private let audioLevels: () -> [Double]

    /// While anything is detached beside the island, the trailing ear yields —
    /// iOS's split look: the main island carries only its leading content, and
    /// the satellite owns the right.
    private let trailingHidden: Bool

    private let activity: Activity
    private let cutoutWidth: CGFloat
    private let inset: CGFloat
    /// Horizontal nudges for each ear's content; positive moves toward the
    /// cutout. Clamped so a hand-edited value cannot push content offscreen.
    private let leadingOffset: CGFloat
    private let trailingOffset: CGFloat

    public init(activity: Activity, cutoutWidth: CGFloat, inset: CGFloat,
        audioLevels: @escaping () -> [Double] = { [] },
        trailingHidden: Bool = false,
        leadingOffset: CGFloat = 0,
        trailingOffset: CGFloat = 0) {
        self.activity = activity
        self.cutoutWidth = cutoutWidth
        self.inset = inset
        self.audioLevels = audioLevels
        self.trailingHidden = trailingHidden
        self.leadingOffset = leadingOffset.isFinite ? min(max(leadingOffset, -24), 24) : 0
        self.trailingOffset = trailingOffset.isFinite ? min(max(trailingOffset, -24), 24) : 0
    }

    public var body: some View {
        // The ears divide whatever is left either side of the cutout, rather
        // than taking a fixed width that knows nothing about the gutters.
        HStack(spacing: 0) {
            // Each ear swaps its own content. The `ZStack` lets the outgoing and
            // incoming cards overlap for the length of the dissolve — as plain
            // `HStack` children they would briefly be two siblings and shove the
            // layout sideways in the middle of the transition.
            ZStack {
                leading
                    .id(activity.id)
                    .transition(Motion.earSwap(reduced: reduceMotion))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(x: leadingOffset)

            // Reserved space for the physical cutout. Nothing may draw here.
            Color.clear.frame(width: cutoutWidth)

            ZStack {
                trailing
                    .id(activity.id)
                    .transition(Motion.earSwap(reduced: reduceMotion))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(x: -trailingOffset)
        }
        .padding(.horizontal, inset)
        // Driven by identity: a now-playing card republishes every second, and
        // animating on the whole activity would restart this on every tick.
        .animation(Motion.earContent, value: activity.id)
        .animation(Motion.earContent, value: trailingHidden)
        // Glyph and readout are one activity: a single element, the way the
        // level HUD's ears read, instead of VoiceOver landing on an unlabelled
        // image and then a bare "24°".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// What the two ears say together, as VoiceOver reads them: the kind first,
    /// then whatever the trailing ear draws, spelled out.
    private var accessibilityDescription: String {
        func percent(_ fraction: Double) -> String {
            "\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent"
        }
        switch activity.payload {
        case .nowPlaying(let payload):
            let state = payload.isPlaying ? "Now playing" : "Paused"
            return [state, payload.title, payload.artist].filter { !$0.isEmpty }.joined(separator: ", ")
        case .device(let payload):
            if let lowest = payload.orderedLevels.map(\.level).min() {
                return "\(payload.name), battery \(percent(lowest))"
            }
            return "\(payload.name), \(payload.isConnected ? "connected" : "disconnected")"
        case .power(let payload):
            return "\(payload.isCharging ? "Charging" : "Battery"), \(percent(payload.percentage))"
        case .focus(let payload):
            return "\(payload.name), Focus \(payload.isActive ? "On" : "Off")"
        case .event(let payload):
            return payload.hasEvent
                ? "Calendar, \(payload.title), \(ActivityCardView.relative(payload.startsIn))"
                : "Calendar, no events today"
        case .message(let payload):
            return payload.body.isEmpty ? payload.title : "\(payload.title), \(payload.body)"
        case .weather(let payload):
            let degrees = WeatherUnits.displayDegrees(celsius: payload.temperatureCelsius, units: weatherUnits)
            return "Weather, \(degrees) degrees, \(payload.condition)"
        case .timer(let payload):
            return payload.mode == .stopwatch
                ? "Stopwatch, \(TimerCardView.clock(payload.remaining))"
                : "Timer, \(TimerCardView.clock(payload.remaining)) remaining"
        case .shelf(let payload):
            return "Shelf, \(payload.items.count == 1 ? "1 item" : "\(payload.items.count) items")"
        case .privacy(let payload):
            return "\(payload.title) in use"
        case .keyboard(let payload):
            if payload.code == "⇪" {
                return "Caps Lock \(payload.symbolName == "capslock.fill" ? "on" : "off")"
            }
            return "Keyboard layout, \(payload.name)"
        case .levels(let payload):
            return payload.isMuted ? "Levels, muted" : "Levels, volume \(percent(payload.volume))"
        }
    }

    @ViewBuilder
    private var leading: some View {
        if case .nowPlaying(let payload) = activity.payload {
            // Album art in the ear, so the resting companion reads as "music",
            // not a generic note glyph.
            NowPlayingThumbnail(payload: payload, accent: accent)
                .frame(width: 22, height: 22)
        } else if case .device = activity.payload, symbolName.contains("airpods") {
            // Apple's own AirPods artwork — the official SF Symbol for the exact
            // model — drawn large with a soft top-lit gradient, the way the
            // system's pairing UI presents it.
            Image(systemName: symbolName)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(white: 0.72)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
        } else if LedgeSymbol.isCustom(symbolName) {
            // A glyph Apple does not ship. Sized to sit level with the SF
            // Symbols beside it rather than to its own bounding box.
            BluetoothGlyph()
                .foregroundStyle(accent)
                .frame(height: 15)
                .padding(.horizontal, 6)
        } else if case .keyboard(let payload) = activity.payload, payload.code == "⇪" {
            // Caps lock: the *identity* stays put on the left — the same
            // glyph whichever way the key went — and the right ear carries
            // the state. Two ears, two jobs.
            Image(systemName: "capslock.fill")
                .font(.cardTitle)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 6)
        } else if case .timer(let payload) = activity.payload,
                  payload.mode != .stopwatch, payload.total > 0, !payload.isFinished {
            // A countdown gets the dial; a stopwatch has no total to empty and
            // keeps its glyph.
            TimerDial(remaining: 1 - payload.progress, tint: accent)
                .padding(.horizontal, 6)
        } else if case .weather = activity.payload {
            // The system's own multicolor weather rendering — the yellow sun,
            // the grey cloud, the blue rain — instead of a flat accent-tinted
            // template. This is exactly the glyph iOS's status surfaces draw.
            Image(systemName: symbolName)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent)
                .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                .padding(.horizontal, 5)
        } else if case .event = activity.payload {
            // The Calendar app's own visual identity: today's number in red
            // on a white rounded tile — unmistakably "calendar", where the
            // flat glyph read as clip-art.
            CalendarDayTile()
        } else {
            Image(systemName: symbolName)
                .font(.cardTitle)
                .foregroundStyle(accent)
                .padding(.horizontal, 6)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if trailingHidden {
            // Keep the ear's full footprint: the row stays symmetric so the
            // leading side cannot re-flow by a point, and the vacated region
            // is clipped away by the shape's trailing inset regardless.
            Color.clear
                .frame(width: 22, height: 14)
                .transition(Motion.earSwap(reduced: reduceMotion))
        } else {
            trailingContent
                .transition(Motion.earSwap(reduced: reduceMotion))
        }
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch activity.payload {
        case .nowPlaying(let payload):
            MiniWaveform(isAnimating: payload.isPlaying, tint: accent, levels: audioLevels)
        case .device(let payload):
            // The battery as a ring: the charged arc drawn thicker than the
            // track. For multi-cell devices (AirPods: case/left/right) the lowest
            // cell is shown — it is the one that dies first.
            // Battery when the device reports one, and nothing at all when it
            // does not. Plenty of hardware never tells macOS its level — a
            // NuPhy keyboard reports `battery={}` — and standing a coloured dot
            // in the battery's place implies a reading that does not exist. The
            // glyph and the name already say "connected".
            if let lowest = payload.orderedLevels.map(\.level).min() {
                BatteryRing(level: lowest)
            } else if let status = payload.statusText, !status.isEmpty {
                // Nothing to charge, but something to say: a switch's state, or
                // where sound has just gone.
                switch payload.statusStyle {
                case .badge:
                    // The same badge Caps Lock wears, for the same reason: a
                    // switch's state has to be readable in a glance and
                    // unmistakable between two rapid toggles.
                    Text(status.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(payload.isConnected ? Color.green : .white.opacity(0.6))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                payload.isConnected ? Color.green.opacity(0.25) : .white.opacity(0.12)
                            )
                        )
                case .plain:
                    Text(status)
                        .font(.cardLabel)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        case .power(let payload):
            // Plugging in gets the charge-flash ring; running on battery keeps
            // the plain readout (red when it is time to find a cable).
            // Single-line always: "100%" beside the ring is at the ear's
            // limit, and a wrapped percentage read as two stacked digits.
            if payload.isCharging {
                HStack(spacing: 4) {
                    BatteryRing(level: max(payload.percentage, 0.02))
                    Text("\(Int((payload.percentage * 100).rounded()))%")
                        .font(.cardCaption)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text("\(Int((payload.percentage * 100).rounded()))%")
                    .font(.cardCaption)
                    .monospacedDigit()
                    .foregroundStyle(payload.percentage < 0.2 ? .red : .white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        case .event(let payload):
            // A quiet day has no countdown; "now" for a card with no event
            // read as a meeting starting.
            // The card's "in 1h 59m" is too wide for the ear at full size, so
            // the "in " goes — the countdown alone still reads as a countdown
            // beside the calendar tile — and what remains may shrink rather
            // than wrap onto a second line.
            if payload.hasEvent {
                Text(Self.earCountdown(payload.startsIn))
                    .font(.cardCaption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        case .weather(let payload):
            Text("\(WeatherUnits.displayDegrees(celsius: payload.temperatureCelsius, units: weatherUnits))°")
                .font(.cardCaption)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .timer(let payload):
            // The countdown itself, so a glance at the ear is enough — and in
            // the timer's own colour rather than white, which is how iOS sets
            // it: the two ears then read as one instrument, the dial and its
            // number, instead of a coloured ornament beside a white label.
            // Orange for work, green for a break, because that is the pairing
            // the rest of the app already uses.
            Text(TimerCardView.clock(payload.remaining))
                .font(.cardCaption)
                .monospacedDigit()
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .shelf(let payload):
            Text("\(payload.items.count)")
                .font(.cardLabel)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
        case .keyboard(let payload):
            if payload.code == "⇪" {
                // The state as a badge: green ON, quiet OFF — readable in a
                // glance, unmistakable in a row of rapid toggles.
                let isOn = payload.symbolName == "capslock.fill"
                Text(isOn ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(isOn ? Color.green : .white.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(isOn ? Color.green.opacity(0.25) : .white.opacity(0.12))
                    )
            } else {
                // The two-letter code is the whole point of the layout card:
                // it is the one thing macOS's own menu-bar flag makes hard to
                // read at a glance.
                Text(payload.code)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        case .levels(let payload):
            // The volume at last publish — a snapshot, like the glyph itself.
            // Muted reads as a slash, not as the level it would return to.
            Text(payload.isMuted ? "—" : "\(Int((payload.volume * 100).rounded()))%")
                .font(.cardCaption)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .privacy(let payload):
            if payload.isSystemSpeech, !payload.cameraActive {
                // Moving bars, not the word. The ear is narrow, the word is
                // long, and the leading glyph already says what this is —
                // what the far side has to say is that it is *listening right
                // now*, which motion says and text cannot. Synthesized, like
                // the music equalizer: no audio is captured to draw it.
                MiniWaveform(isAnimating: true, tint: .white)
            } else {
                // The dots themselves, in Apple's colours — green camera, amber mic.
                HStack(spacing: 5) {
                    if payload.cameraActive {
                        Circle().fill(.green).frame(width: 7, height: 7)
                    }
                    if payload.micActive {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                    }
                }
            }
        case .focus(let payload):
            // A Focus change reads as "On"/"Off" beside the mode's glyph.
            Text(payload.isActive ? "On" : "Off")
                .font(.cardLabel)
                .foregroundStyle(.white.opacity(0.9))
        case .message:
            connectionDot
        }
    }

    /// The card's relative countdown with its "in " prefix dropped: "1h 59m",
    /// "15m", "now". Only the ear uses this — the card keeps the full phrase.
    static func earCountdown(_ seconds: TimeInterval) -> String {
        let full = ActivityCardView.relative(seconds)
        return full.hasPrefix("in ") ? String(full.dropFirst(3)) : full
    }

    private var connectionDot: some View {
        Circle()
            .fill(accent)
            .frame(width: 6, height: 6)
    }

    private var symbolName: String {
        switch activity.payload {
        case .nowPlaying(let payload): payload.isPlaying ? "music.note" : "pause.fill"
        case .device(let payload): payload.symbolName
        case .power(let payload): payload.isCharging ? "bolt.fill" : "battery.25"
        case .focus(let payload): payload.symbolName
        case .event: "calendar"
        case .message(let payload): payload.symbolName
        case .weather(let payload): payload.symbolName
        case .timer(let payload):
            payload.mode == .stopwatch ? "stopwatch" : (payload.isBreak ? "cup.and.saucer.fill" : "timer")
        case .shelf: "tray.full.fill"
        case .privacy(let payload):
            // Dictation gets the waveform macOS itself puts on the cursor, so
            // the notch shows the same thing the pointer does.
            payload.cameraActive ? "video.fill"
                : (payload.isSystemSpeech ? "waveform" : "mic.fill")
        case .keyboard(let payload): payload.symbolName ?? "keyboard"
        case .levels: "slider.horizontal.3"
        }
    }

    private var accent: Color {
        switch activity.payload {
        case .nowPlaying(let payload): payload.accent.color
        case .event(let payload): payload.accent.color
        case .power(let payload): payload.percentage < 0.2 ? .red : .green
        case .device(let payload): payload.isApple ? .cyan : .white
        case .focus: .focusAccent
        case .message: .orange
        case .weather(let payload): payload.isDay ? .yellow : .indigo
        case .timer(let payload): payload.isBreak ? .green : .orange
        case .shelf: .teal
        case .privacy(let payload):
            // Dictation is not a privacy warning, so it does not wear the
            // warning colour: it is something the user just switched on.
            payload.cameraActive ? .green : (payload.isSystemSpeech ? .white : .orange)
        case .keyboard: .white
        case .levels: .white
        }
    }
}

/// Today's day number on a white rounded tile — the Calendar app icon's
/// language, sized for the ear. Live via a minute timeline, so a card left
/// resting across midnight ticks over with the day.
struct CalendarDayTile: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text("\(Calendar.current.component(.day, from: context.date))")
                .font(.cardSmallFigure)
                .monospacedDigit()
                .foregroundStyle(.red)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(.white)
                )
        }
    }
}

/// Battery as a ring, styled like Apple's own compact indicators: a faint track
/// with a thin monochrome fill arc. White when healthy, red only when low — the
/// colour, not the thickness, carries the warning, which reads far less toy-like
/// than a fat green arc.
/// The countdown as a dial: a ring that empties as the time runs out, with a
/// hand at the arc's end.
///
/// This is the shape iOS gives a running timer in the Dynamic Island, and it
/// earns the ear for the same reason it earns the island: a glyph says "this is
/// a timer" once and then says it forever, while a dial says how much is left
/// every time it is glanced at, and moves — which is what makes the notch read
/// as something that is running rather than something that is displayed.
///
/// The hand is what separates it from an ordinary progress ring. It sits at the
/// end of the remaining arc, so the two agree, and it is the part the eye
/// catches at this size: at 15 points a ring losing 1/300th of its arc a second
/// is still, and a hand sweeping the same distance is not.
struct TimerDial: View {

    /// How much time is left, from 1 at the start to 0 at the end.
    let remaining: Double

    let tint: Color

    /// Never quite empty while it runs: a dial with no arc at all reads as
    /// finished a few seconds before it is.
    private var fraction: Double { min(max(remaining, 0.015), 1) }

    var body: some View {
        ZStack {
            // The full round it has to run, dimmed — the same hue rather than a
            // grey, which is what keeps the pair reading as one object.
            Circle().stroke(tint.opacity(0.3), lineWidth: 2.5)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                // From twelve o'clock, clockwise, like every clock face.
                .rotationEffect(.degrees(-90))

            // The hand, at the arc's end.
            Capsule()
                .fill(tint)
                .frame(width: 1.8, height: 5.5)
                // Grown from the centre outwards, then turned to the angle:
                // anchoring at the bottom is what makes the rotation a sweep
                // around the middle rather than a spin in place.
                .offset(y: -2.75)
                .rotationEffect(.degrees(360 * fraction))
        }
        .frame(width: 15, height: 15)
        .animation(Motion.slow, value: fraction)
    }
}

struct BatteryRing: View {
    let level: Double

    private var tint: Color {
        level < 0.2 ? .red : .green
    }

    var body: some View {
        // Activity-ring proportions: track and fill share one generous width,
        // the track being the same hue dimmed — that equal-weight look is what
        // reads as Apple, not a hairline arc.
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(level, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.slow, value: level)
        }
        .frame(width: 16, height: 16)
        .padding(2)
    }
}

/// The tiny album-art tile shown in the companion ear. Falls back to a tinted
/// gradient with a note when the player exposes no artwork.
struct NowPlayingThumbnail: View {
    let payload: NowPlayingPayload
    let accent: Color

    @State private var decoded: (key: String, image: NSImage)?

    private var image: NSImage? {
        guard let data = payload.artworkData else { return nil }
        // The byte count rides along in the fallback key: with no artworkKey,
        // consecutive same-titled tracks (radio streams) otherwise kept
        // serving the previous track's decoded cover.
        let key = payload.artworkKey ?? "\(payload.title)-\(data.count)"
        if let decoded, decoded.key == key { return decoded.image }
        guard let img = NSImage(data: data) else { return nil }
        Task { @MainActor in decoded = (key, img) }
        return img
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [accent.opacity(0.6), accent.opacity(0.25)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.cardCaption)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// Six bars that bounce while something is playing.
///
/// Deliberately not driven by real audio: capturing system audio costs a TCC
/// prompt for a decorative animation, which is the worst permission-to-value
/// trade in the project. Driving it from `isPlaying` gives essentially the same
/// perceived result.
struct MiniWaveform: View {
    let isAnimating: Bool
    let tint: Color
    /// Synthesized band levels from `LevelSimulator` — musical motion seeded
    /// by the track, never a recording. Empty keeps the plain sine sway, which
    /// is what the bars fall back to with the equalizer switched off.
    var levels: () -> [Double] = { [] }

    private static let phases: [Double] = [0.0, 0.4, 0.75, 0.2, 0.6, 0.95]

    /// Height from a live band level, nil when no levels are available. The
    /// ramp amplitude still applies so starting and stopping stays soft.
    private func liveHeight(_ live: [Double], index: Int, amplitude: Double) -> CGFloat? {
        guard live.count > index, amplitude > 0 else { return nil }
        let level = live[index]
        guard level.isFinite else { return nil }
        return 3 + CGFloat(min(max(level, 0), 1) * amplitude) * 11
    }

    /// How long the bars take to rise or settle when playback starts or stops.
    private static let rampDuration: TimeInterval = 0.28

    /// When `isAnimating` last changed, so the ramp can be computed from the
    /// timeline's own clock.
    @State private var changedAt: Date = .distantPast

    /// True once the settle ramp has finished and the timeline may stop.
    ///
    /// A stored flag flipped by a scheduled task, not a computed check: the
    /// `paused` argument is only re-evaluated when the *body* re-renders, and
    /// after the stop-ramp nothing else triggers a render — a computed
    /// "ramp done" was captured as false mid-ramp and the 24 Hz timeline
    /// ticked forever behind a resting island.
    @State private var parked = true
    @State private var parkTask: Task<Void, Never>?

    var body: some View {
        // Kept running through the ramp even once playback has stopped —
        // pausing the timeline the instant music stops is what made the bars
        // snap flat. It parks itself as soon as the ramp is done, so an idle
        // companion still costs nothing.
        TimelineView(
            .animation(minimumInterval: 1.0 / 24.0, paused: !isAnimating && parked)
        ) { context in
            let amount = amplitude(at: context.date)
            let live = isAnimating ? levels() : []
            HStack(spacing: 2) {
                ForEach(Array(Self.phases.enumerated()), id: \.offset) { index, phase in
                    Capsule()
                        .fill(tint)
                        .frame(
                            width: 2.5,
                            height: liveHeight(live, index: index, amplitude: amount)
                                ?? height(
                                    at: context.date.timeIntervalSinceReferenceDate,
                                    phase: phase,
                                    amplitude: amount
                                )
                        )
                }
            }
            .frame(height: 14, alignment: .center)
        }
        .onChange(of: isAnimating) { _, playing in
            changedAt = Date()
            parkTask?.cancel()
            if playing {
                parked = false
                parkTask = nil
            } else {
                // Park just past the ramp's end; flipping the state is itself
                // the render that lets `paused` finally read true.
                parkTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.rampDuration + 0.05))
                    guard !Task.isCancelled else { return }
                    parked = true
                }
            }
        }
        .onDisappear { parkTask?.cancel() }
    }

    /// 0 when stopped, 1 while playing, eased across the ramp in between.
    ///
    /// Derived from the timeline's clock rather than driven by `withAnimation`:
    /// the heights are computed inside the closure, and state read there arrives
    /// at its final value immediately rather than interpolated — so an animation
    /// modifier could not smooth it.
    private func amplitude(at date: Date) -> Double {
        let progress = min(max(date.timeIntervalSince(changedAt) / Self.rampDuration, 0), 1)
        // Smoothstep, so the bars ease away instead of sliding linearly to flat.
        let eased = progress * progress * (3 - 2 * progress)
        return isAnimating ? eased : 1 - eased
    }

    private func height(at time: TimeInterval, phase: Double, amplitude: Double) -> CGFloat {
        guard amplitude > 0 else { return 3 }
        let wave = sin((time * 3.4) + phase * .pi * 2)
        return 3 + CGFloat((wave + 1) / 2) * 11 * amplitude
    }
}

/// One dot per activity, filled for the selected one. Only shown when there is
/// more than one, so a single activity gets no chrome.
public struct PageDots: View {

    private let count: Int
    private let selectedIndex: Int

    public init(count: Int, selectedIndex: Int) {
        self.count = count
        self.selectedIndex = selectedIndex
    }

    public var body: some View {
        if count > 1 {
            HStack(spacing: 5) {
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(index == selectedIndex ? 0.85 : 0.25))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }
}
