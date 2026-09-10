import LedgeCore
import SwiftUI

/// One route the audio can go to, for the output picker.
public struct AudioOutputOption: Identifiable, Equatable {
    public let id: UInt32
    public let name: String
    public let isCurrent: Bool
    /// That device's own volume, 0...1, when readable — drawn as the faded bar
    /// under a non-current route.
    public let level: Double?
    /// Whether that device is muted. macOS keeps the scalar volume unchanged
    /// while muted, so the level alone cannot say.
    public let isMuted: Bool

    public init(id: UInt32, name: String, isCurrent: Bool, level: Double? = nil, isMuted: Bool = false) {
        self.id = id
        self.name = name
        self.isCurrent = isCurrent
        self.level = level
        self.isMuted = isMuted
    }
}

/// One display in the expanded brightness panel.
///
/// Deliberately a separate type from `AudioOutputOption` despite the similar
/// shape: audio has a single *route* and tapping another switches to it, whereas
/// every display is lit at once and each row adjusts its own screen. Sharing one
/// type would mean a flag that silently changes what a tap does.
public struct DisplayLevelOption: Identifiable, Equatable {
    public let id: UInt32
    public let name: String
    /// The display the pointer is on — the one the brightness keys act on.
    public let isCurrent: Bool
    public let isBuiltIn: Bool
    public let level: Double

    public init(id: UInt32, name: String, isCurrent: Bool, isBuiltIn: Bool, level: Double) {
        self.id = id
        self.name = name
        self.isCurrent = isCurrent
        self.isBuiltIn = isBuiltIn
        self.level = level
    }
}

/// Transport actions the card can invoke. Supplied by the shell so `LedgeUI`
/// stays free of the system layer.
public struct NowPlayingActions {
    public var playPause: () -> Void
    public var next: () -> Void
    public var previous: () -> Void
    /// Seek to a fraction of the track, 0...1.
    public var seek: (Double) -> Void
    /// Synthesized band levels for the equalizer — `LevelSimulator`'s musical
    /// motion seeded by the track, never a recording — and empty when the
    /// animation is switched off. Pulled by the equalizer's own frame timer so
    /// 20 Hz updates never invalidate the whole card.
    public var audioLevels: () -> [Double] = { [] }
    /// Choose the audio output (opens the system's output picker).
    public var chooseOutput: () -> Void
    /// The selectable audio outputs, current one flagged.
    public var outputs: () -> [AudioOutputOption]
    /// Routes system audio to the given output.
    public var selectOutput: (UInt32) -> Void
    /// Sets one output device's own volume, 0...1.
    public var setOutputVolume: (UInt32, Double) -> Void
    /// Latches a drag in flight, so the overlay stays open while the pointer
    /// wanders off the row being dragged.
    public var setDragging: (Bool) -> Void
    /// Reports how many destination rows the route menu is showing, or 0 when
    /// it closes. The shell sizes its hit region from this, so the clickable
    /// area grows with the card rather than clicks falling through the window.
    public var setRoutePickerRows: (Int) -> Void

    /// Brings the app that owns this media forward. Only ever called for a
    /// card whose payload says it belongs to an app rather than a web page.
    public var openOwningApp: () -> Void

    public init(
        playPause: @escaping () -> Void = {},
        next: @escaping () -> Void = {},
        previous: @escaping () -> Void = {},
        seek: @escaping (Double) -> Void = { _ in },
        audioLevels: @escaping () -> [Double] = { [] },
        chooseOutput: @escaping () -> Void = {},
        outputs: @escaping () -> [AudioOutputOption] = { [] },
        selectOutput: @escaping (UInt32) -> Void = { _ in },
        setOutputVolume: @escaping (UInt32, Double) -> Void = { _, _ in },
        setRoutePickerRows: @escaping (Int) -> Void = { _ in },
        openOwningApp: @escaping () -> Void = {},
        setDragging: @escaping (Bool) -> Void = { _ in }
    ) {
        self.playPause = playPause
        self.next = next
        self.previous = previous
        self.seek = seek
        self.audioLevels = audioLevels
        self.chooseOutput = chooseOutput
        self.outputs = outputs
        self.selectOutput = selectOutput
        self.setOutputVolume = setOutputVolume
        self.setRoutePickerRows = setRoutePickerRows
        self.openOwningApp = openOwningApp
        self.setDragging = setDragging
    }
}

/// The flagship card, laid out like the iOS Dynamic Island now-playing view:
/// artwork and a title/artist stack with an equaliser on the top row, a
/// full-width scrubber flanked by elapsed and remaining times, and a full-width
/// transport row beneath.
public struct NowPlayingCardView: View {

    private let payload: NowPlayingPayload
    private let actions: NowPlayingActions
    private let isCompactWidth: Bool

    /// While a drag is in progress the bar follows the finger rather than the
    /// player, otherwise the next poll would yank the handle back mid-gesture.
    @State private var scrubFraction: Double?
    @State private var clearTask: Task<Void, Never>?

    /// Optimistic favourite state: the button reflects the tap immediately, and
    /// the real state (if the player ever reports it) reconciles on the payload.

    /// Optimistic play/pause state. The icon and the equaliser flip the instant
    /// the button is tapped, rather than waiting for the next poll to confirm the
    /// player obeyed — the gap that made the transport feel dead and provoked a
    /// second, cancelling tap. Cleared the moment the payload's real state
    /// changes, so a command the player ignored self-corrects.
    @State private var playingOverride: Bool?

    /// Bumped on each next/previous press, with the direction pressed, so the
    /// artwork knows which way to turn when the track change lands. The flip
    /// itself waits for the actual change — a press that changes nothing (next
    /// at the end of a queue) must not flip.
    @State private var navToken: Int = 0
    @State private var navForward: Bool = true

    /// How far the pointer must travel across a route row before it counts as
    /// a volume drag rather than a tap that selects the route.
    private static let dragThreshold: CGFloat = 8

    /// Levels being dragged right now, by device. The poll re-reads the real
    /// level every second, which would otherwise yank the fill back mid-slide.
    @State private var draggedLevels: [UInt32: Double] = [:]
    /// Snapshot of the route menu's destinations, taken when it opens.
    @State private var routeOptions: [AudioOutputOption] = []

    /// Whether the route picker has taken over the card.
    ///
    /// It replaces the player rather than floating above it: the overlay clips
    /// to the notch silhouette, so a popover or menu panel would be cut off at
    /// the shape's edge, and growing the card would put the drawn shape out of
    /// step with the hit region the shell computes separately.
    ///
    /// Opens on launch under `LEDGE_SHOW_OUTPUTS=1`, so the picker can be looked
    /// at without a click — synthetic clicks do not reach a non-activating
    /// panel, which makes it otherwise unverifiable except by hand.
    @State private var isShowingOutputs =
        ProcessInfo.processInfo.environment["LEDGE_SHOW_OUTPUTS"] == "1"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ties the parts both faces share — the artwork, the title and artist,
    /// the equalizer — so they are understood as the *same* elements moving
    /// rather than one set fading out while another fades in.
    ///
    /// This is what made the swap feel abrupt however the timing was tuned:
    /// the artwork sits in almost the same place on both faces, so
    /// cross-fading it looked like a cut with nothing travelling. Matched, it
    /// stays put and only the half that genuinely differs — transport against
    /// output list — changes.
    @Namespace private var faces

    public init(
        payload: NowPlayingPayload,
        actions: NowPlayingActions = NowPlayingActions(),
        isCompactWidth: Bool = false,
        swapResponse: Double = 0.38,
        swapDamping: Double = 0.68
    ) {
        self.payload = payload
        self.actions = actions
        self.isCompactWidth = isCompactWidth
        self.swapResponse = swapResponse
        self.swapDamping = swapDamping
    }

    /// The spring the shell resizes the shape with, so the contents turn over
    /// on the same curve. Passed in because the card cannot see preferences.
    private let swapResponse: Double
    private let swapDamping: Double

    private func closeOutputs() {
        isShowingOutputs = false
        actions.setRoutePickerRows(0)
    }

    private var displayedFraction: Double { scrubFraction ?? payload.progress }
    private var isPlayingDisplayed: Bool { playingOverride ?? payload.isPlaying }

    public var body: some View {
        if isCompactWidth {
            compact
        } else {
            full
        }
    }

    // MARK: - Compact (duo mode)

    private var compact: some View {
        HStack(spacing: 10) {
            NowPlayingArtwork(payload: payload, size: 34, radius: 8, flipToken: navToken, flipForward: navForward)
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.title)
                    .font(.cardControl)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(payload.artist)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            NowPlayingEqualizer(isAnimating: isPlayingDisplayed, levels: actions.audioLevels)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: payload.isPlaying) { _, _ in playingOverride = nil }
    }

    // MARK: - Full

    /// The player-to-picker swap, in the app's own swap language rather than a
    /// transition invented here.
    private var pickerSwap: AnyTransition {
        Motion.routeSwap(reduced: reduceMotion)
    }

    private var full: some View {
        ZStack {
            if isShowingOutputs {
                outputPicker
                    .transition(pickerSwap)
            } else {
                player
                    .transition(pickerSwap)
            }
        }
        // *The* animation the shell resizes the shape with, not a cousin of
        // it. `Motion.swap` shortens the response and loosens the damping,
        // which is right for one card replacing another and wrong here: the
        // contents finished before the box did, and going back and forth —
        // which interrupts both mid-flight — turned that gap into a wobble.
        .animation(
            Motion.expand(response: swapResponse, damping: swapDamping, reduced: reduceMotion),
            value: isShowingOutputs
        )
        // The card outlives a collapse, so without this it would reopen straight
        // back into the picker rather than the player — and the shell would keep
        // sizing its hit region for a menu that is not on screen.
        .onDisappear { closeOutputs() }
    }

    /// Wraps content in the doorway to the owning app, or leaves it alone.
    ///
    /// A web page's card leads nowhere on purpose — the browser may be on
    /// another Space showing a different tab, and "open" would be a promise
    /// about which of forty tabs comes forward that nothing here can keep.
    @ViewBuilder
    private func openOwner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if payload.ownerIsApp {
            Button(action: actions.openOwningApp) { content() }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    payload.sourceName.isEmpty ? "Open the app" : "Open \(payload.sourceName)"
                )
        } else {
            content()
        }
    }

    private var player: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                // Artwork and title together are the doorway to the player.
                //
                // A transparent Button behind the whole card was supposed to be
                // that doorway, and could not be: an Image and a Text are
                // hittable in their own right, so every click that landed on
                // the cover or the track name — that is, every click anyone
                // would actually aim — was swallowed by them and reached
                // nothing. The catcher behind still takes the empty space; this
                // takes the part the eye picks.
                openOwner {
                    HStack(alignment: .center, spacing: 12) {
                        NowPlayingArtwork(
                            payload: payload, size: 44, radius: 10,
                            flipToken: navToken, flipForward: navForward
                        )
                        .matchedGeometryEffect(id: "artwork", in: faces)

                        VStack(alignment: .leading, spacing: 2) {
                            MarqueeText(payload.title, font: .system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(payload.artist)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        .matchedGeometryEffect(id: "identity", in: faces)
                    }
                }
                // A new track plays from the start, so the optimistic
                // play/pause override belonged to the old one. The activity id
                // is the *player*, not the track, so it does not reset on its
                // own.
                .onChange(of: payload.artworkKey ?? "\(payload.title)|\(payload.artist)") { _, _ in
                    playingOverride = nil
                }

                Spacer(minLength: 8)

                NowPlayingEqualizer(isAnimating: isPlayingDisplayed, levels: actions.audioLevels)
                    .matchedGeometryEffect(id: "equalizer", in: faces)
                    .padding(.top, 2)
            }

            if payload.isLive { liveBar } else { scrubber }
            transport
        }
        .padding(.horizontal, 15)
        .padding(.top, 12)
        .padding(.bottom, 16)
        // The card is a doorway to the app that owns the music, the way
        // clicking a widget opens its app — but only for an app. A web page's
        // card leads nowhere: the browser may be on another Space showing a
        // different tab, and "open" would be a promise about which of forty
        // tabs comes forward that nothing here can keep.
        //
        // Behind the content, deliberately. Everything with a job of its own —
        // the transport buttons, the scrub bar, the AirPlay button, the title —
        // is in front and takes its own clicks first; this catches what is left,
        // which is the empty space around them.
        //
        // A Button rather than a tap gesture, matching the weather card: the
        // overlay's own tap handler pins the card, and a bare gesture would
        // fire alongside it.
        .background {
            if payload.ownerIsApp {
                Button(action: actions.openOwningApp) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    payload.sourceName.isEmpty ? "Open the app" : "Open \(payload.sourceName)"
                )
            }
        }
        // Real state landed (or reverted) — drop the optimistic guess.
        .onChange(of: payload.isPlaying) { _, _ in playingOverride = nil }
    }


    // MARK: - Scrubber

    /// What a live broadcast shows instead of a scrub bar.
    ///
    /// There is no end to count down to and no position to drag to, so the
    /// bar and the remaining time are both lies — one of them a draggable
    /// one. A match, a radio station and a stream all answer the same two
    /// questions: is this live, and how long have I been here.
    private var liveBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.12)))

            Spacer(minLength: 0)

            Text(TimerCardView.clock(payload.elapsed))
                .monospacedDigit()
        }
        .font(.cardBody)
        .foregroundStyle(.white.opacity(0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live")
        .accessibilityValue("\(TimerCardView.clock(payload.elapsed)) elapsed")
    }

    private var scrubber: some View {
        // Hour-aware (a 2h podcast is "1:23:45", not an unreadable "83:45"),
        // with the label seats widened to match — the m:ss widths truncated
        // hour-long times to an ellipsis.
        let hasHours = payload.duration >= 3600
        return HStack(spacing: 8) {
            Text(TimerCardView.clock(payload.duration * displayedFraction))
                .frame(width: hasHours ? 54 : 34, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule()
                        .fill(.white)
                        .frame(width: proxy.size.width * min(max(displayedFraction, 0), 1))
                }
                .contentShape(Rectangle().inset(by: -6))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard proxy.size.width > 0 else { return }
                            clearTask?.cancel()
                            clearTask = nil
                            scrubFraction = min(max(value.location.x / proxy.size.width, 0), 1)
                        }
                        .onEnded { _ in
                            if let fraction = scrubFraction { actions.seek(fraction) }
                            clearTask?.cancel()
                            clearTask = Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(600))
                                guard !Task.isCancelled else { return }
                                scrubFraction = nil
                            }
                        }
                )
            }
            .frame(height: 5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                "\(TimerCardView.clock(payload.duration * displayedFraction)) of \(TimerCardView.clock(payload.duration))"
            )
            // Drag-only otherwise; VoiceOver's up/down steps it in twentieths.
            // The same hold-then-release the drag uses, so the next poll does
            // not yank the bar back before the player has caught up.
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 0.05 : -0.05
                let next = min(max(displayedFraction + step, 0), 1)
                scrubFraction = next
                actions.seek(next)
                clearTask?.cancel()
                clearTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    scrubFraction = nil
                }
            }

            // The minus sign reads as "time remaining", matching Apple's player.
            Text("-\(TimerCardView.clock(payload.duration * (1 - displayedFraction)))")
                .frame(width: hasHours ? 58 : 38, alignment: .trailing)
        }
        .font(.cardBody)
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.5))
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 0) {
            // The star used to sit here. Its space is kept rather than closed
            // up: the spacers divide whatever is left between them, so letting
            // the gap collapse would have slid the transport and the route
            // button across the card. Removing one control is not a reason for
            // the others to move.
            Color.clear.frame(width: 30, height: 28)
            Spacer(minLength: 0)
            glyph("backward.fill", size: 13) {
                navForward = false
                navToken &+= 1
                actions.previous()
            }
            .accessibilityLabel("Previous track")
            Spacer(minLength: 0)
            glyph(isPlayingDisplayed ? "pause.fill" : "play.fill", size: 17) {
                playingOverride = !isPlayingDisplayed
                actions.playPause()
            }
            .accessibilityLabel(isPlayingDisplayed ? "Pause" : "Play")
            Spacer(minLength: 0)
            glyph("forward.fill", size: 13) {
                navForward = true
                navToken &+= 1
                actions.next()
            }
            .accessibilityLabel("Next track")
            Spacer(minLength: 0)
            outputMenu
        }
    }

    /// The button that reveals the route list. Its glyph is the device sound is
    /// going to right now, so the control says where you are before it is opened.
    private var outputMenu: some View {
        Button {
            if isShowingOutputs {
                closeOutputs()
            } else {
                // Read the devices *before* the swap starts. This is a full
                // CoreAudio enumeration; running it from the picker's
                // `onAppear` put it inside the first frames of the animation,
                // where it costs a frame or two — which is felt precisely when
                // the swap is interrupted.
                routeOptions = actions.outputs()
                actions.setRoutePickerRows(max(routeOptions.count, 1))
                isShowingOutputs = true
            }
        } label: {
            // The AirPlay glyph, as iOS uses bottom-right of its Now Playing
            // view — the control is "where is this going", not "what is it now",
            // so it does not change with the route.
            Image(systemName: "airplayaudio")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isShowingOutputs ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.9)))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(isShowingOutputs ? 0.16 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Audio output")
    }

    /// The route menu, in the shape of iOS's AirPlay sheet: what is playing
    /// across the top, then one capsule per destination beneath it.
    ///
    /// The destinations are snapshotted when the menu opens (and after a
    /// route switch), the same one-shot rule the HUD uses: `actions.outputs()`
    /// is a full CoreAudio device-and-level enumeration, and calling it from
    /// `body` ran it once a second for as long as the menu stayed open.
    private var outputPicker: some View {
        VStack(alignment: .leading, spacing: NotchLayout.routeHeaderGap) {
            header
            // Scrolls past three, which is where the card stops growing.
            ScrollView(.vertical, showsIndicators: false) {
                // The rows arrive with the menu rather than after it. A
                // per-row delay looks like a list opening when it plays out,
                // and like the card lagging when it is reversed halfway —
                // and being reversed halfway is what pressing the button
                // twice does.
                VStack(spacing: NotchLayout.routeRowSpacing) {
                    ForEach(routeOptions) { option in
                        outputRow(option)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // Clear of the hardware cutout above it. The player earns its own
        // breathing room from the artwork row's 12pt top inset; the menu's
        // header sat directly under the notch, which reads as the card being
        // cropped by it.
        .padding(.top, NotchLayout.routePickerTopPadding)
        // Keep the scrolling viewport clear of the page dots and the shape's
        // rounded bottom, including when the last of many outputs is reached.
        .padding(.bottom, NotchLayout.routePickerBottomPadding)
        // The same margins the player keeps. The menu used to set its own, far
        // narrower ones so the capsules could be as wide as possible, and the
        // card visibly changed shape when the AirPlay button was pressed —
        // swapping the contents of a card should not move its edges.
        .padding(.horizontal, 12)
        // Reported here rather than only from the button, so the card is sized
        // correctly however the menu came to be open.
        .onAppear {
            // Already read on the press in the ordinary case; this is for the
            // menu arriving any other way (the debug switch, a restore).
            guard routeOptions.isEmpty else { return }
            routeOptions = actions.outputs()
            actions.setRoutePickerRows(max(routeOptions.count, 1))
        }
        .onChange(of: routeOptions.count) { _, count in
            actions.setRoutePickerRows(max(count, 1))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            NowPlayingArtwork(
                payload: payload, size: 42, radius: 10,
                flipToken: navToken, flipForward: navForward
            )
            .matchedGeometryEffect(id: "artwork", in: faces)
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.title)
                    .font(.cardHeadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(payload.artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .matchedGeometryEffect(id: "identity", in: faces)
            Spacer(minLength: 8)
            NowPlayingEqualizer(isAnimating: isPlayingDisplayed, scale: 1.15, levels: actions.audioLevels)
                .matchedGeometryEffect(id: "equalizer", in: faces)
            Button {
                closeOutputs()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.cardLabel)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close audio outputs")
        }
        .frame(height: NotchLayout.routeHeaderHeight)
        // Inset a little further than the capsules below it. Flush with them,
        // the artwork read as if it were part of the list rather than titling
        // it — and this brings the header to the player's own 15pt margin, so
        // the artwork does not move at all when the menu opens.
        .padding(.horizontal, 3)
    }

    /// One destination.
    ///
    /// The capsule *is* the level control: its fill shows the device's volume
    /// and dragging across it sets it, which is how the iOS sheet behaves and
    /// what lets a row this size hold a glyph, a name, a tick and a level
    /// without any of them feeling wedged in. A separate bar inside the capsule
    /// needed height the notch does not have.
    ///
    /// Tap and drag share one gesture on purpose: a child `DragGesture` under a
    /// parent `onTapGesture` never sees the drag — the tap wins — which is why
    /// the level was unmovable.
    private func outputRow(_ option: AudioOutputOption) -> some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            // Muted reads as zero. macOS leaves the scalar at whatever it was
            // before the mute, so a silent output was drawing a confident 60%
            // — the number was real and the sound was not.
            let reported = option.isMuted ? 0 : (option.level ?? 0)
            let shown = min(max(draggedLevels[option.id] ?? reported, 0), 1)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(option.isCurrent ? 0.12 : 0.07))

                // The level, in the same track-and-fill language the level HUD
                // uses, drawn as the row's own fill.
                Capsule(style: .continuous)
                    .fill(.white.opacity(option.isCurrent ? 0.26 : 0.14))
                    .frame(width: width * shown)

                HStack(spacing: 11) {
                    Image(systemName: Self.outputSymbol(for: option.name))
                        .font(.system(size: 15, weight: .regular))
                        // Fixed width so every name starts on the same column,
                        // however wide its glyph happens to be.
                        .frame(width: 21)
                    Text(option.name)
                        .font(.system(size: 13, weight: option.isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if option.isCurrent {
                        Image(systemName: "checkmark")
                            .font(.cardControl)
                    }
                }
                // Only the active route is drawn at full strength; iOS
                // distinguishes it by weight and tint, not by the tick alone.
                .foregroundStyle(option.isCurrent ? .white : .white.opacity(0.7))
                .padding(.horizontal, 15)
            }
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Below the threshold this is still a tap in progress,
                        // so the level must not jump to wherever it landed.
                        //
                        // Deliberately generous. This row can set the volume of
                        // a device you are *not* listening to, so a nudge during
                        // a click would silently zero an output you only
                        // discover is dead much later — which is exactly the
                        // failure that is hard to attribute back to this app.
                        guard abs(value.translation.width) > Self.dragThreshold else { return }
                        // Latch first: the shell must know a drag is in flight
                        // before the pointer can wander off the shape mid-slide.
                        actions.setDragging(true)
                        let next = min(max(value.location.x / width, 0), 1)
                        draggedLevels[option.id] = next
                        actions.setOutputVolume(option.id, next)
                    }
                    .onEnded { value in
                        // Tap only if the threshold was never crossed — not if
                        // the *final* translation happens to land back near the
                        // start. A volume drag that wandered out and returned
                        // used to both set the level and switch the route.
                        let dragged = draggedLevels[option.id] != nil
                        if !dragged && abs(value.translation.width) <= Self.dragThreshold {
                            actions.selectOutput(option.id)
                            // Re-snapshot so the tick moves to the new route.
                            routeOptions = actions.outputs()
                        }
                        if dragged {
                            // Re-read before letting go of the dragged value.
                            // The rows are a snapshot taken when the menu
                            // opened, so releasing without this dropped the
                            // fill straight back to the level the device had
                            // *before* the drag — the change had been made and
                            // the row said otherwise, which reads as the
                            // control not working at all.
                            routeOptions = actions.outputs()
                        }
                        draggedLevels[option.id] = nil
                        actions.setDragging(false)
                    }
            )
        }
        .frame(height: NotchLayout.routeRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.isCurrent ? "\(option.name), current output" : option.name)
        .accessibilityValue(
            option.isMuted
                ? "Muted"
                : (option.level.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
        )
        .accessibilityAddTraits(.isButton)
        // The gesture above is tap-and-drag in one; VoiceOver gets the two
        // halves separately — activate selects the route, adjust sets its level.
        .accessibilityAction {
            guard !option.isCurrent else { return }
            actions.selectOutput(option.id)
            routeOptions = actions.outputs()
        }
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 0.05 : -0.05
            let next = min(max((option.level ?? 0) + step, 0), 1)
            actions.setOutputVolume(option.id, next)
            // Re-snapshot rather than latching a drag level: there is no
            // gesture end here to unlatch it, and the device answers at once.
            routeOptions = actions.outputs()
        }
    }

    private static func outputSymbol(for name: String?) -> String {
        AudioDeviceSymbol.forName(name)
    }

    private func glyph(
        _ symbol: String,
        size: CGFloat,
        weight: Font.Weight = .semibold,
        action: @escaping () -> Void
    ) -> some View {
        TransportButton(symbol: symbol, size: size, weight: weight, action: action)
    }
}

/// A transport control that highlights on hover. At rest it is just the glyph —
/// no resting background — so nothing looks pre-selected; moving the cursor over
/// it fades in a soft rounded backing, the feedback the media buttons lacked.
struct TransportButton: View {
    let symbol: String
    var size: CGFloat
    var weight: Font.Weight = .semibold
    var tint: AnyShapeStyle = AnyShapeStyle(.white.opacity(0.9))
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .frame(width: 30, height: 28)
                .background(
                    hovering ? AnyShapeStyle(.white.opacity(0.16)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The six dancing bars in the top-right — the iOS "now playing" motif.
///
/// Driven by playback state, not real audio: capturing system audio costs a
/// permission prompt for a decorative animation, which every shipping notch app
/// declines to pay. When paused the bars settle to a low, even line.
struct NowPlayingEqualizer: View {
    let isAnimating: Bool
    /// 1 leaves the player card exactly as it was; the route menu asks for a
    /// slightly larger one to sit beside its bigger artwork and title.
    var scale: CGFloat = 1
    /// Live band levels of the actual audio; empty falls back to the
    /// decorative sine so the bars never sit dead while music plays.
    var levels: () -> [Double] = { [] }

    // Six bars, as iOS draws its now-playing indicator: capsules on a shared
    // centre line growing symmetrically, neighbours out of phase.
    private static let phases: [Double] = [0.0, 0.55, 0.2, 0.75, 0.35, 0.9]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let live = isAnimating ? levels() : []
            HStack(alignment: .center, spacing: 2.5 * scale) {
                ForEach(Array(Self.phases.enumerated()), id: \.offset) { index, phase in
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(
                            width: 2.5 * scale,
                            height: height(at: t, phase: phase, live: live, index: index) * scale
                        )
                }
            }
            .frame(height: 18 * scale, alignment: .center)
        }
    }

    private func height(
        at time: TimeInterval,
        phase: Double,
        live: [Double],
        index: Int
    ) -> CGFloat {
        guard isAnimating else { return 3 }
        if live.count == Self.phases.count {
            let level = live[index]
            guard level.isFinite else { return 3 }
            return 3 + CGFloat(min(max(level, 0), 1)) * 14
        }
        let wave = sin((time * 4.2) + phase * .pi * 2)
        return 3 + CGFloat((wave + 1) / 2) * 14
    }
}

/// The album art, with two behaviours the plain image lacked:
///
/// - **No filler on a track change.** The previous artwork stays on screen until
///   the next track's image has actually decoded, so the gradient-and-note
///   placeholder never flashes between songs.
/// - **A card flip.** When the new image is ready it flips in on the vertical
///   axis — a short, premium reveal rather than a snap.
struct NowPlayingArtwork: View {

    let payload: NowPlayingPayload
    let size: CGFloat
    let radius: CGFloat
    /// Bumped by the card on a next/previous press, with the direction that was
    /// pressed. This only *records* the direction: the flip itself fires when the
    /// track actually changes, so a press that changes nothing never flips.
    var flipToken: Int = 0
    var flipForward: Bool = true

    @State private var shownKey: String?
    @State private var shownImage: NSImage?
    @State private var angle: Double = 0
    @State private var isFlipping = false
    /// The newest artwork this view has seen, kept in state rather than read
    /// from `payload` inside the turn: a running Task holds the struct it was
    /// created with, and by the time the card is edge-on that copy is a
    /// version behind. The state box is shared with every later render, so
    /// this is the one way to ask "what is current *now*".
    @State private var latestImage: NSImage?
    @State private var latestKey: String?
    /// The direction recorded by the last press, consumed by the next track
    /// change. Expires so a stale press does not steer an unrelated auto-advance
    /// minutes later.
    @State private var pendingForward: Bool?
    @State private var pendingExpiry: Task<Void, Never>?
    /// Waits briefly for a slow artwork before flipping to the placeholder, so
    /// the flip is never late — but also never shows filler when art is coming.
    @State private var graceTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trackKey: String { payload.artworkKey ?? payload.title }

    private func decodedImage() -> NSImage? {
        guard let data = payload.artworkData else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .onAppear { seedIfNeeded() }
            .onChange(of: flipToken) { _, _ in recordDirection() }
            .onChange(of: trackKey) { _, _ in trackChanged() }
            .onChange(of: payload.artworkData) { _, _ in artworkArrived() }
    }

    @ViewBuilder
    private var content: some View {
        if let image = shownImage {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [payload.accent.color.opacity(0.5), payload.accent.color.opacity(0.2)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // A music note over a film is the wrong apology. Plenty of
                // media arrives with no artwork at all — a browser publishes
                // whatever the page bothered to set, which is often nothing —
                // so the placeholder should at least be honest about what it
                // is standing in for.
                Image(systemName: payload.isVideo ? "play.rectangle.fill" : "music.note")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    /// First image ever: show it plainly, no theatre.
    private func seedIfNeeded() {
        if shownImage == nil, shownKey == nil, let image = decodedImage() {
            shownImage = image
            shownKey = trackKey
            latestImage = image
            latestKey = trackKey
        }
    }

    /// A next/previous press: remember which way to turn, nothing more.
    private func recordDirection() {
        pendingForward = flipForward
        pendingExpiry?.cancel()
        pendingExpiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            pendingForward = nil
        }
    }

    /// The song actually changed — begin the turn immediately, in the same
    /// beat as the title. Which face lands is decided later, at the edge-on
    /// moment: the metadata reaches us a poll before the cover does, and
    /// flipping the *old* art in and swapping it afterwards read as two
    /// separate movements for one track change.
    private func trackChanged() {
        guard trackKey != shownKey else { return }
        graceTask?.cancel()
        latestKey = trackKey
        latestImage = decodedImage()
        flip(key: trackKey)
    }

    /// Art landed. If the turn is still in the air it will pick this up when
    /// it reaches edge-on; if the flip is long over, the face changes in
    /// place — no second turn for one song.
    private func artworkArrived() {
        seedIfNeeded()
        let image = decodedImage()
        latestKey = trackKey
        latestImage = image
        guard trackKey == shownKey, let image else { return }
        if shownImage !== image { shownImage = image }
    }

    /// One clean card turn about the vertical axis. Next spins one way, previous
    /// the mirror — and the swap happens exactly edge-on, so the face is never
    /// seen mirrored.
    /// How long the card may sit edge-on waiting for a cover that is on its
    /// way. Invisible time — the card is a hairline at ninety degrees — and
    /// short enough that a slow fetch still turns rather than stalling.
    ///
    /// Sized from measurement rather than taste: on this machine a next-track
    /// press lands the new metadata and its artwork URL together, and fetching
    /// the cover then takes about 260 ms cold (instant when cached). The turn
    /// covers 160 ms on the way out plus this, so the reveal shows the new
    /// cover with room to spare, and only a genuinely slow network falls back
    /// to carrying the old art through.
    private static let edgeOnGrace: Duration = .milliseconds(240)
    private static let edgeOnStep: Duration = .milliseconds(20)

    private func flip(key: String) {
        guard !isFlipping else {
            // A second change mid-flip: let the current turn finish, then catch
            // up to whatever is current.
            return
        }
        let forward = pendingForward ?? true
        pendingForward = nil
        pendingExpiry?.cancel()

        // Reduce Motion: the face changes, the card stays flat.
        guard !reduceMotion else {
            shownImage = latestImage ?? shownImage
            shownKey = key
            return
        }
        isFlipping = true

        let out: Double = forward ? 90 : -90
        withAnimation(.easeIn(duration: 0.16)) { angle = out }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))

            // Edge-on: nothing of the card is visible, so this is the moment to
            // decide what it turns back with. Read through the state boxes —
            // `payload` on this captured struct is whatever it was when the
            // turn began.
            var face = latestKey == key ? latestImage : nil
            if face == nil {
                var waited: Duration = .zero
                while waited < Self.edgeOnGrace {
                    try? await Task.sleep(for: Self.edgeOnStep)
                    waited += Self.edgeOnStep
                    if Task.isCancelled { break }
                    // Moved on again — stop waiting for a cover nobody needs.
                    if let current = latestKey, current != key { break }
                    if let arrived = latestImage, latestKey == key {
                        face = arrived
                        break
                    }
                }
            }
            // Still nothing: the old art rides through, and `artworkArrived`
            // updates the face in place when it finally lands.
            shownImage = face ?? shownImage
            shownKey = key
            angle = -out
            withAnimation(.easeOut(duration: 0.18)) { angle = 0 }
            try? await Task.sleep(for: .milliseconds(190))
            isFlipping = false
            // The track may have advanced again while we were turning.
            if let current = latestKey, current != shownKey { flipToLatest() }
        }
    }

    /// Catches up after a turn that finished on a stale song.
    private func flipToLatest() {
        guard let key = latestKey, key != shownKey else { return }
        flip(key: key)
    }
}
