import LedgeCore
import SwiftUI

/// One route the audio can go to, for the output picker.
public struct AudioOutputOption: Identifiable, Equatable, Sendable {
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
    /// Presses the transport. The card shows what was asked for only if this
    /// says something actually left the app — a press the player's queue
    /// refused changed nothing, and a card that moved anyway was telling the
    /// user something had happened when nothing had.
    ///
    /// `Bool` rather than the system layer's own answer, because `LedgeUI`
    /// takes values and knows nothing about how a command is sent.
    public var playPause: () -> Bool
    public var next: () -> Bool
    public var previous: () -> Bool
    /// Seek to a fraction of the track, 0...1.
    ///
    /// - Returns: whether anything left the app. A refused seek must not move
    ///   the bar: the player was never asked, so there is nothing coming.
    public var seek: (Double) -> Bool
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
    public var setOutputVolume: (UInt32, Double) -> LevelFeedback?
    /// Takes the drag latch, so the overlay stays open while the pointer
    /// wanders off the row being dragged, and hands back the drag's token.
    ///
    /// A token rather than a plain flag because the card is replaced on every
    /// track change and a route row disappears with its device: the view that
    /// goes away has to let go of the latch, and must not let go of a drag
    /// that has meanwhile begun somewhere else. See `DragLatch`.
    public var beginDrag: () -> Int

    /// Lets go of the latch, if this is still the drag holding it.
    public var endDrag: (Int) -> Void
    /// Reports how many destination rows the route menu is showing, or 0 when
    /// it closes. The shell sizes its hit region from this, so the clickable
    /// area grows with the card rather than clicks falling through the window.
    public var setRoutePickerRows: (Int) -> Void

    /// Brings the app that owns this media forward. Only ever called for a
    /// card whose payload says it belongs to an app rather than a web page.
    public var openOwningApp: () -> Void

    public init(
        playPause: @escaping () -> Bool = { true },
        next: @escaping () -> Bool = { true },
        previous: @escaping () -> Bool = { true },
        seek: @escaping (Double) -> Bool = { _ in false },
        audioLevels: @escaping () -> [Double] = { [] },
        chooseOutput: @escaping () -> Void = {},
        outputs: @escaping () -> [AudioOutputOption] = { [] },
        selectOutput: @escaping (UInt32) -> Void = { _ in },
        setOutputVolume: @escaping (UInt32, Double) -> LevelFeedback? = { _, _ in nil },
        setRoutePickerRows: @escaping (Int) -> Void = { _ in },
        openOwningApp: @escaping () -> Void = {},
        beginDrag: @escaping () -> Int = { 0 },
        endDrag: @escaping (Int) -> Void = { _ in }
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
        self.beginDrag = beginDrag
        self.endDrag = endDrag
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
    /// The song it grabbed travels with it — see `ScrubGrip`.
    @State private var grip = ScrubGrip()

    /// Where the bar points between letting go and the player agreeing.
    ///
    /// It used to be a flat 600ms hold: the bar went where you put it, fell
    /// back to the last reading — which for a player that had not acted yet
    /// was the position *before* the drag — and arrived a second later. One
    /// seek drawn as three movements, the middle one backwards. The rule now
    /// waits for the player rather than for a clock; see `SeekIntent`.
    @State private var seek = SeekIntent()

    /// Wakes the bar when the seek's deadline passes, for the case where no
    /// reading is coming to wake it — a paused player, asked to move, that
    /// never answers.
    @State private var seekDeadline: Task<Void, Never>?
    @State private var seekTick = 0

    /// Which song is on, for the purpose of "is this still the same one".
    ///
    /// The player's own identity for it where there is one. Title and artist
    /// are the fallback and used to be the whole answer, which cannot tell two
    /// recordings of the same piece apart — and for a while the *artwork* key
    /// stood in here, which could not tell a late cover from a new song.
    private var songKey: String {
        payload.itemKey ?? "\(payload.title)\u{1F}\(payload.artist)"
    }

    /// Optimistic favourite state: the button reflects the tap immediately, and
    /// the real state (if the player ever reports it) reconciles on the payload.

    /// Optimistic play/pause state. The icon and the equaliser flip the instant
    /// the button is tapped, rather than waiting for the next poll to confirm the
    /// player obeyed — the gap that made the transport feel dead and provoked a
    /// second, cancelling tap. Cleared the moment the payload's real state
    /// changes, so a command the player ignored self-corrects.
    /// What the transport button was just asked to do, shown before the player
    /// has said whether it happened. The rule lives in `PlaybackIntent`, where
    /// the deadline can be tested without waiting for it.
    @State private var intent = PlaybackIntent()
    /// Redraws the button when the intent's deadline passes: the rule is
    /// clockless, so something has to come back and look.
    @State private var overrideExpiry: Task<Void, Never>?
    @State private var intentTick = 0

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

    /// The drag this view is holding the latch for, if it is holding one.
    /// Only the token taken here is ever given back — see `DragLatch`.
    @State private var dragToken: Int?
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
        // The list going away takes its drags with it. A volume drag whose row
        // is no longer on screen cannot end in `onEnded`, and the latch it
        // took would otherwise be held until something unrelated cleared it.
        draggedLevels.removeAll()
        releaseDrag()
    }

    /// Takes the drag latch, once, for whichever gesture asked first.
    private func holdDrag() {
        guard dragToken == nil else { return }
        dragToken = actions.beginDrag()
    }

    /// Lets go of the latch this view took, and of nothing else. A view that
    /// has already been replaced releasing whatever happens to be latched is
    /// how an old card could end a drag that had just begun on its successor.
    private func releaseDrag() {
        _ = grip.released(on: songKey)
        guard let token = dragToken else { return }
        dragToken = nil
        actions.endDrag(token)
    }

    /// Everything this view was holding on to, let go of together.
    ///
    /// The latch, the levels being dragged, the pending scrub position and the
    /// two timers that would have cleared it — all of them outlive the view
    /// otherwise, and the latch outliving it is what kept the notch open and
    /// eating clicks.
    private func letGoOfEverything() {
        closeOutputs()
        releaseDrag()
        draggedLevels.removeAll()
        overrideExpiry?.cancel()
        overrideExpiry = nil
        seekDeadline?.cancel()
        seekDeadline = nil
    }

    private var displayedFraction: Double {
        // The pointer is down on *this* song: the bar follows the finger and
        // nothing else. A fraction measured against the song before this one
        // is not shown at all — it was a position in a different length.
        if let held = grip.displayed(on: songKey) { return held }
        // `seekTick` is read so the deadline's wake-up redraws this.
        _ = seekTick
        guard payload.duration > 0 else { return payload.progress }
        let shown = seek.displayed(
            reported: payload.elapsed, on: songKey, at: Self.now()
        )
        return min(max(shown / payload.duration, 0), 1)
    }

    /// Asks the player to move, and holds the bar there until it agrees.
    ///
    /// Refused while a pointer is on the bar. The other way in is VoiceOver's
    /// step, and the two running at once left them disagreeing about where the
    /// bar was: the step seeks the player while the drag goes on drawing the
    /// finger, and then the drag's own seek lands on top of it.
    private func ask(toSeek fraction: Double) {
        guard payload.duration > 0, !grip.isHeld else { return }
        let position = payload.duration * fraction
        seek.asked(for: position, from: payload.elapsed, on: songKey, at: Self.now())
        // The answer first, the optimism second: a press the queue refused
        // moved the bar anyway, to a place the player was never asked to go.
        if !actions.seek(fraction) { seek.refused() }
        armSeekDeadline()
    }

    /// Comes back when the hold would have expired, because the rule is
    /// clockless and something has to look.
    private func armSeekDeadline() {
        seekDeadline?.cancel()
        seekDeadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(SeekIntent.deadline))
            guard !Task.isCancelled else { return }
            seekTick &+= 1
        }
    }
    private var isPlayingDisplayed: Bool {
        // `intentTick` is read so the deadline's wake-up redraws this.
        _ = intentTick
        return intent.displayed(reported: payload.isPlaying, at: Self.now())
    }

    private static func now() -> TimeInterval { Date().timeIntervalSinceReferenceDate }

    /// Shows what was asked for, and comes back when the deadline passes so
    /// the player's own state can take over.
    private func setOptimistically(_ playing: Bool) {
        intent.ask(for: playing, at: Self.now())
        overrideExpiry?.cancel()
        overrideExpiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PlaybackIntent.grace))
            guard !Task.isCancelled else { return }
            intentTick &+= 1
        }
    }

    /// The player answered, or the card went away.
    private func clearOverride() {
        overrideExpiry?.cancel()
        overrideExpiry = nil
        intent.reported()
    }

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
        .onChange(of: payload.isPlaying) { _, _ in clearOverride() }
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
        // The card outlives a collapse, and it is also replaced outright on
        // every track change — which is not a phase change, so nothing else
        // cleans up after it. A gesture only lets go in `onEnded`, and a view
        // taken off screen mid-drag never gets one.
        .onDisappear { letGoOfEverything() }
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
                .onChange(of: songKey) { _, _ in
                    clearOverride()
                    // Both the position asked for and the one under the
                    // pointer belonged to the song before this one. A fraction
                    // measured against that song's length says nothing about
                    // this one, so the bar goes back to showing the player at
                    // once rather than drawing a borrowed position until the
                    // finger lifts.
                    seek.itemChanged()
                    grip.itemChanged()
                }
                // Where the player says it is. This is what ends a hold —
                // arrival has to be remembered, or a player drifting on past
                // the target afterwards reads as never having arrived and the
                // bar jumps backwards to the asked-for position.
                .onChange(of: payload.elapsed) { _, position in
                    seek.reconcile(reported: position, on: songKey, at: Self.now())
                }

                Spacer(minLength: 8)

                NowPlayingEqualizer(isAnimating: isPlayingDisplayed, levels: actions.audioLevels)
                    .matchedGeometryEffect(id: "equalizer", in: faces)
                    .padding(.top, 2)
            }

            if payload.isLive { liveBar } else { scrubber }
            transport
        }
        .padding(.horizontal, 8)
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
        .onChange(of: payload.isPlaying) { _, _ in clearOverride() }
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
                            // Grabbing the bar again abandons whatever the
                            // last seek was still waiting for: the finger is
                            // the newer answer.
                            seek.refused()
                            seekDeadline?.cancel()
                            seekDeadline = nil
                            // The same latch the volume rows take: without it
                            // the card could close under a pointer that
                            // wandered off the shape mid-scrub, and the seek
                            // never arrived.
                            holdDrag()
                            grip.moved(to: value.location.x / proxy.size.width, on: songKey)
                        }
                        .onEnded { _ in
                            // Only if it is still the song that was grabbed. A
                            // track ending mid-drag would otherwise seek the
                            // one that replaced it to wherever the pointer
                            // happened to be.
                            let fraction = grip.released(on: songKey)
                            releaseDrag()
                            if let fraction { ask(toSeek: fraction) }
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
                ask(toSeek: min(max(displayedFraction + step, 0), 1))
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
                guard actions.previous() else { return }
                navForward = false
                navToken &+= 1
            }
            .accessibilityLabel("Previous track")
            Spacer(minLength: 0)
            glyph(isPlayingDisplayed ? "pause.fill" : "play.fill", size: 17) {
                // Asked first, shown second. Showing it first meant a refused
                // press still flipped the glyph, and the card then sat on a
                // state no player was ever told to reach.
                let displayed = isPlayingDisplayed
                guard actions.playPause() else { return }
                setOptimistically(!displayed)
            }
            .accessibilityLabel(isPlayingDisplayed ? "Pause" : "Play")
            Spacer(minLength: 0)
            glyph("forward.fill", size: 13) {
                guard actions.next() else { return }
                navForward = true
                navToken &+= 1
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
        .padding(.horizontal, 8)
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
        // The list was a snapshot taken when it opened, so anything that
        // happened elsewhere — volume changed from the keyboard or another
        // app, the route switched in Control Centre, headphones plugged in or
        // pulled out — left it showing what used to be true for as long as it
        // stayed open. It re-reads while it is on screen, and only while it is
        // on screen.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.routeRefreshInterval)
                guard !Task.isCancelled else { return }
                // The list refreshes through a drag rather than stopping for
                // one: the drawn level already prefers `draggedLevels`, so the
                // pointer's value cannot be yanked back by a re-read. What the
                // merge protects is the *row* — a device that drops out of
                // range mid-slide must not take its own gesture off screen
                // with it, because a gesture removed that way never ends and
                // the card was left letting go of the latch on its behalf,
                // closing the notch under a finger that was still down.
                let rows = RoutePickerRows.merging(
                    actions.outputs(), into: routeOptions, dragging: Set(draggedLevels.keys)
                )
                if rows != routeOptions { routeOptions = rows }
            }
        }
    }

    /// How often an open output list re-reads the devices.
    ///
    /// A second: fast enough that plugging in headphones while looking at the
    /// list is seen as it happens, slow enough to be nothing next to the
    /// polling the card already does for the track itself.
    private static let routeRefreshInterval: Duration = .seconds(1)

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
            // A device that exposes no volume — many HDMI displays, some USB
            // interfaces — was drawn as a slider sitting at zero, which reads
            // as an output turned all the way down rather than one whose level
            // is not ours to set. It is a plain row instead.
            let isAdjustable = option.level != nil

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(option.isCurrent ? 0.12 : 0.07))

                // The level, in the same track-and-fill language the level HUD
                // uses, drawn as the row's own fill.
                if isAdjustable {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(option.isCurrent ? 0.26 : 0.14))
                        .frame(width: width * shown)
                }

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
                        guard isAdjustable else { return }
                        guard abs(value.translation.width) > Self.dragThreshold else { return }
                        // Latch first: the shell must know a drag is in flight
                        // before the pointer can wander off the shape mid-slide.
                        holdDrag()
                        let next = min(max(value.location.x / width, 0), 1)
                        // The latched drag level is the device's answer, so a
                        // clamped or refused write shows where the output
                        // really is while the pointer is still down.
                        draggedLevels[option.id] = actions
                            .setOutputVolume(option.id, next)?.level ?? next
                    }
                    .onEnded { value in
                        // Tap only if the threshold was never crossed — not if
                        // the *final* translation happens to land back near the
                        // start. A volume drag that wandered out and returned
                        // used to both set the level and switch the route.
                        let dragged = draggedLevels[option.id] != nil
                        if !dragged && abs(value.translation.width) <= Self.dragThreshold {
                            if option.isCurrent && isAdjustable {
                                // The output you are listening to sets its
                                // level where you click, the way the Levels
                                // card does. Selecting it again is a no-op, so
                                // a click on this row had no effect at all
                                // unless it happened to travel far enough to
                                // count as a drag.
                                let next = min(max(value.location.x / width, 0), 1)
                                _ = actions.setOutputVolume(option.id, next)
                            } else {
                                actions.selectOutput(option.id)
                            }
                            // Re-snapshot so the tick and the level catch up.
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
                        releaseDrag()
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
            _ = actions.setOutputVolume(option.id, next)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.waveformAnimationsEnabled) private var animationsEnabled
    let isAnimating: Bool
    /// 1 leaves the player card exactly as it was; the route menu asks for a
    /// slightly larger one to sit beside its bigger artwork and title.
    var scale: CGFloat = 1
    /// Synthesized levels, never an audio recording. Empty uses a sine sway.
    var levels: () -> [Double] = { [] }

    // Six bars, as iOS draws its now-playing indicator: capsules on a shared
    // centre line growing symmetrically, neighbours out of phase.
    private static let phases: [Double] = [0.0, 0.55, 0.2, 0.75, 0.35, 0.9]

    var body: some View {
        FixedRateClock(
            isActive: isAnimating && animationsEnabled && !reduceMotion,
            interval: .milliseconds(50)
        ) { date in
            let t = date.timeIntervalSinceReferenceDate
            let live = isAnimating && animationsEnabled && !reduceMotion ? levels() : []
            WaveformBars(
                heights: Self.phases.enumerated().map { index, phase in
                    height(at: t, phase: phase, live: live, index: index) * scale
                },
                tint: .white.opacity(0.9), barWidth: 2.5 * scale,
                spacing: 2.5 * scale, height: 18 * scale
            )
        }
    }

    private func height(
        at time: TimeInterval,
        phase: Double,
        live: [Double],
        index: Int
    ) -> CGFloat {
        guard isAnimating && animationsEnabled && !reduceMotion else { return 3 }
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
    /// The turn in progress. Held so it can be stopped when the view goes:
    /// a flip left running against a card that is no longer on screen is work
    /// nobody is watching, and it comes back at the end to start another one.
    @State private var flipTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Which song this is — not which cover it is carrying. The turn belongs
    /// to a song changing; a cover arriving or being replaced updates the face
    /// where it stands, which is what `artworkArrived` is for.
    private var trackKey: String {
        payload.itemKey ?? "\(payload.title)\u{1F}\(payload.artist)"
    }

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
            .onDisappear { letGoOfTheTurn() }
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
    /// Stops everything this view had in flight.
    ///
    /// A card is replaced on every track change, and none of these tasks is
    /// tied to its lifetime: the turn, the grace that waits for a slow cover,
    /// and the expiry that forgets which way the last press pointed all ran on
    /// against a view that had gone.
    private func letGoOfTheTurn() {
        flipTask?.cancel()
        flipTask = nil
        graceTask?.cancel()
        graceTask = nil
        pendingExpiry?.cancel()
        pendingExpiry = nil
        isFlipping = false
        angle = 0
    }

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
            shownKey = key
            if let arrived = latestImage {
                shownImage = arrived
                return
            }
            // No cover yet. The old one holds for the same grace the turn
            // would have spent edge-on — long enough for one that is on its
            // way, short enough that a song without a cover of its own does
            // not wear the last song's for as long as it plays.
            graceTask?.cancel()
            graceTask = Task { @MainActor in
                try? await Task.sleep(for: Self.edgeOnGrace)
                guard !Task.isCancelled, shownKey == key, latestKey == key else { return }
                shownImage = latestImage
            }
            return
        }
        isFlipping = true

        let out: Double = forward ? 90 : -90
        withAnimation(.easeIn(duration: 0.16)) { angle = out }
        flipTask = Task { @MainActor in
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
            // Still nothing after the grace. The old art may not ride
            // through: a song with no cover of its own would wear the
            // previous song's for as long as it played, which is a quiet lie
            // about what is on. The placeholder says "no cover" instead, and
            // `artworkArrived` still fills it in if one turns up late.
            shownImage = face
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
