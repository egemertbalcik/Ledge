import LedgeCore
import Observation
import SwiftUI

/// What the overlay is currently showing. Written by the coordinator from the
/// reducer and the queue; read by the view.
@MainActor
@Observable
public final class NotchPresentation {
    public var phase: NotchPhase = .idle
    public var selected: Activity?
    public var companion: Activity?

    /// The now-playing activity, whatever else is selected.
    ///
    /// The companion phase *means* "music is resting in the ears", so it has to
    /// draw the music — not whatever happens to top the queue. Once the
    /// calendar became a standing card it outranked now-playing permanently,
    /// and starting a song showed the calendar in the ears.
    public var nowPlaying: Activity?

    /// Pull-source for the live audio band levels, set once by the shell.
    /// A closure rather than stored values: levels change ~20 times a second,
    /// and storing them here would invalidate every observer of this model on
    /// each tick. The equalizers poll it from their own frame timers.
    @ObservationIgnored public var audioLevels: () -> [Double] = { [] }

    public var count: Int = 0
    public var selectedIndex: Int = 0

    /// The level readout, kept apart from the queue: a HUD flashes and goes, so
    /// it should never be something you can cycle to or dismiss.
    public var hud: HUDReadout?

    /// The transient tenant of the satellite seat — a level readout or a
    /// device announcement — holding it for a dwell. Nil between transients.
    public var hudSatellite: SatelliteContent?

    /// What the notch is standing up to say, while it is saying it. Nil the
    /// rest of the time, which is nearly always.
    public var announcement: NotchAnnouncement?

    /// The most recent level readout of any kind, kept regardless of phase so
    /// an open Levels card can follow the hardware keys — its bars are
    /// otherwise a snapshot from the moment it opened.
    public var latestLevel: HUDReadout?

    /// The running timer session's activity, standing tenant of the satellite
    /// while music keeps the island (and the island itself when it does not).
    public var timerSession: Activity?

    /// The privacy card while recording is live — the satellite's most urgent
    /// standing tenant.
    public var privacyActive: Activity?

    /// The dictation card while it lasts, so the companion seat can carry it
    /// while music holds the island — and so the ears have something to draw
    /// on a quiet one.
    public var dictationActive: Activity?

    /// A paused track *while its linger is still running*, which is a
    /// different fact from "a paused track exists".
    ///
    /// The ears used to read `nowPlaying` straight, and got away with it
    /// because the island closed when the linger ended and nothing was drawn
    /// at all. Once something else could hold the island open — a standing
    /// indicator — that stale card sat in the ears indefinitely and nothing
    /// behind it in the chain ever got a turn. The coordinator owns the
    /// linger, so it owns this.
    public var lingeringNowPlaying: Activity?

    /// Whether the notch is saying hello: a pair of eyes in the ears, blinking
    /// once or twice before the island closes. Set at launch and cleared when
    /// it is over — nothing else in the app looks at it.
    public var greeting = false

    /// What the current peek is announcing. A peek used to draw the *selected*
    /// card, and a low-priority arrival — pressing play under a standing
    /// calendar — flashed the wrong card entirely.
    public var peeked: Activity?

    /// The event card while a meeting is close (under an hour out),
    /// whichever card is selected — the resting countdown the companion may
    /// show.
    public var closeEvent: Activity?

    /// The card being walked away from, for the ten-second farewell — shown
    /// ahead of the standing residents so leaving the weather card does not
    /// snap instantly to the music.
    public var farewell: Activity?

    /// Whether the cursor is over the shape. The HUD uses it to widen its bar
    /// into a directly draggable slider.
    public var isHovering: Bool = false

    /// The audio outputs shown in the hovered sound panel, current device
    /// first. Populated by the coordinator when the panel opens, so the device
    /// enumeration does not run on every hover tick.
    public var hudOutputs: [AudioOutputOption] = []
    /// Attached displays, for the expanded brightness panel. Empty, or a single
    /// entry, keeps the panel in its plain one-slider form.
    public var hudDisplays: [DisplayLevelOption] = []

    /// Which display the pointer is on, when Ledge is drawn on more than one.
    /// `nil` means "no display is hovered", not "all of them".
    ///
    /// The reducer stays display-agnostic — one brain, one queue — and this is
    /// the single fact each panel needs to decide whether a hover-driven phase
    /// is *its* hover. Without it every screen expands together, which is
    /// exactly as odd as it sounds.
    public var hoveredDisplayID: UInt32?

    /// How many destinations the media card's route menu is showing, or 0 when
    /// it is closed. Written by the card, read by both the overlay and the
    /// shell's hit-region maths — see `NotchLayout.routePickerHeight`.
    public var routePickerRows: Int = 0

    /// How many week rows the calendar card is drawing. Reported by the card
    /// as it draws, because the month on show is its own state — browsing to
    /// a deeper month has to make the card deeper with it.
    public var calendarWeekRows: Int = 0

    /// How tall the Clock card's content is. Reported by the card, because
    /// which of its three faces is showing is the card's own state.
    public var timerContentHeight: CGFloat = 0

    public init() {}
}

/// The thing that hangs out of the notch.
///
/// The hosting panel is a fixed size — every visible change happens here, so the
/// shape animation never has to stay in step with a window resize.
public struct NotchOverlayView: View {

    private let geometry: NotchGeometry
    @Bindable private var preferences: Preferences
    @Bindable private var presentation: NotchPresentation
    private let onTap: () -> Void
    private let nowPlayingActions: NowPlayingActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the page dots are at full strength (fresh open / just cycled).
    @State private var dotsBright = false
    @State private var dotsFadeTask: Task<Void, Never>?

    private func brightenDots() {
        dotsBright = true
        dotsFadeTask?.cancel()
        dotsFadeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            dotsBright = false
        }
    }

    private let timerActions: TimerActions
    private let shelfActions: ShelfActions
    private let levelsActions: LevelsActions
    /// Files dropped on the notch. Returns whether they were taken.
    private let onDropFiles: ([URL]) -> Bool
    private let onHUDAdjust: (HUDReadout.Kind, Double) -> Void
    private let onHUDAdjustDisplay: (UInt32, Double) -> Void
    /// This panel's display. `nil` on the single-display path, where every
    /// hover is necessarily this panel's.
    private let displayID: UInt32?
    private let onHUDDragging: (Bool) -> Void

    public init(
        geometry: NotchGeometry,
        preferences: Preferences,
        presentation: NotchPresentation,
        onTap: @escaping () -> Void = {},
        nowPlayingActions: NowPlayingActions = NowPlayingActions(),
        timerActions: TimerActions = TimerActions(),
        shelfActions: ShelfActions = ShelfActions(),
        levelsActions: LevelsActions = LevelsActions(),
        onDropFiles: @escaping ([URL]) -> Bool = { _ in false },
        onHUDAdjust: @escaping (HUDReadout.Kind, Double) -> Void = { _, _ in },
        onHUDAdjustDisplay: @escaping (UInt32, Double) -> Void = { _, _ in },
        displayID: UInt32? = nil,
        onHUDDragging: @escaping (Bool) -> Void = { _ in }
    ) {
        self.geometry = geometry
        self.preferences = preferences
        self.presentation = presentation
        self.onTap = onTap
        self.nowPlayingActions = nowPlayingActions
        self.timerActions = timerActions
        self.shelfActions = shelfActions
        self.levelsActions = levelsActions
        self.onDropFiles = onDropFiles
        self.onHUDAdjust = onHUDAdjust
        self.onHUDAdjustDisplay = onHUDAdjustDisplay
        self.displayID = displayID
        self.onHUDDragging = onHUDDragging
    }

    /// True while a drag is hovering the shape, so it can light up as a target.
    @State private var isDropTargeted = false

    /// What the greeting's eyes are doing. Held here so both eyes are drawn
    /// from the same values in the same frame.
    @State private var greetingState: GreetingState = .closed

    /// Plays the greeting once, beat by beat.
    ///
    /// Under Reduce Motion the eyes simply appear, hold, and go: the point of
    /// the performance is the movement, and there is no honest way to keep it
    /// for someone who has asked for less of exactly that.
    private func performGreeting() async {
        guard presentation.greeting else { return }
        guard !reduceMotion else {
            var open = GreetingState()
            open.opacity = 1
            open.scale = 1
            open.openness = 1
            withAnimation(.easeInOut(duration: 0.3)) { greetingState = open }
            return
        }
        greetingState = .closed
        for beat in GreetingState.script() {
            withAnimation(beat.animation) { greetingState = beat.state }
            try? await Task.sleep(for: .seconds(beat.length))
            if Task.isCancelled { return }
        }
    }

    private var expandedSize: CGSize {
        presentation.cardSize(preferences: preferences, geometry: geometry, phase: phase)
    }

    private var hudExtraHeight: CGFloat {
        presentation.hudExtraHeight(hovered: isHovering)
    }

    /// Whether the pointer is on *this* panel's display.
    ///
    /// True when nothing reports a hovered display, so the single-display path
    /// and every non-hover phase behave exactly as before.
    private var isHoveredDisplay: Bool {
        guard let hovered = presentation.hoveredDisplayID, let displayID else { return true }
        return hovered == displayID
    }

    /// The phase this panel should actually draw.
    ///
    /// `hover` and `expanded` are the two phases a *pointer* causes, so they
    /// belong to the display the pointer is on. Everything else — peeks, the
    /// companion, the level HUD — is information rather than interaction, and
    /// still shows on every screen.
    private var phase: NotchPhase {
        guard !isHoveredDisplay else { return presentation.phase }
        // `presentation.phase`, never `phase`: reading this property from inside
        // its own getter recurses until the stack dies.
        switch presentation.phase {
        case .hover, .expanded:
            // Whether THIS display rests as a companion is the same test the
            // companion content uses — something must actually be running.
            // `presentation.companion` (the next card in the cycle) was the
            // old test, and it is about the queue's population, not music: a
            // second standing card faked a companion, and solo music failed
            // the test and vanished to idle during a hover elsewhere.
            let hasRestingContent = playingNowPlaying != nil || runningTimerSession != nil
            return hasRestingContent ? .companion : .idle
        default:
            return presentation.phase
        }
    }

    private var isHovering: Bool { isHoveredDisplay && presentation.isHovering }

    /// The media actions with the route-menu reporter attached, so the card can
    /// tell the presentation how tall it has become without knowing about it.
    private var routeAwareActions: NowPlayingActions {
        var actions = nowPlayingActions
        actions.setRoutePickerRows = { rows in presentation.routePickerRows = rows }
        actions.setDragging = onHUDDragging
        return actions
    }

    private var layout: NotchLayout {
        .layout(
            for: phase,
            geometry: geometry,
            expandedSize: expandedSize,
            bottomRadius: preferences.bottomRadius,
            closedBottomRadius: preferences.closedBottomRadius,
            gutterRadius: preferences.gutterRadius,
            isHudInteractive: isHovering,
            hudExtraHeight: hudExtraHeight,
            isAnnouncing: presentation.announcement != nil
        )
    }

    /// The silhouette: the notch's own shape, flaring into the bezel with
    /// gutters. Panels exist only on notched displays, so there is no other
    /// case to draw.
    private var shape: LedgeShape {
        LedgeShape(
            bottomRadius: layout.bottomRadius,
            gutterRadius: layout.gutterRadius,
            cornerSmoothing: preferences.cornerSmoothing,
            trailingInset: satelliteCollapse
        )
    }

    /// The timer session while one is genuinely running or paused mid-leg.
    private var runningTimerSession: Activity? {
        guard let session = presentation.timerSession,
              case .timer(let payload) = session.payload,
              !payload.isIdle
        else { return nil }
        return session
    }

    /// The now-playing activity, only when it has business in the ears —
    /// playing, and something listened to rather than watched.
    private var playingNowPlaying: Activity? {
        guard let activity = presentation.nowPlaying, activity.restsInEars else { return nil }
        return activity
    }

    /// Who holds the satellite seat right now, if anyone. The freshest
    /// transient wins the dwell; then the running timer; then the recording
    /// indicator — and the timer never orbits itself.
    private var satelliteContent: SatelliteContent? {
        guard phase == .companion else { return nil }
        // Nothing orbits an announcement. The satellite is the timer's own
        // readout more often than not, and a ring counting beside "Break time"
        // is the same contradiction the ears would be.
        guard presentation.announcement == nil else { return nil }
        let timerContent: SatelliteContent? = {
            guard let session = presentation.timerSession,
                  case .timer(let payload) = session.payload,
                  !payload.isIdle
            else { return nil }
            return .timer(
                remaining: payload.remaining,
                total: payload.total,
                isBreak: payload.isBreak,
                isRunning: payload.isRunning
            )
        }()
        let privacyContent: SatelliteContent? = {
            guard let activity = presentation.privacyActive,
                  case .privacy(let payload) = activity.payload,
                  payload.cameraActive || payload.micActive
            else { return nil }
            // Dictation is drawn as itself, in the island or in this seat, and
            // must not also appear here as a bare microphone: one microphone,
            // one indicator, and the user asked for the one that says what it
            // is actually doing.
            if payload.isSystemSpeech, !payload.cameraActive { return nil }
            return .privacy(camera: payload.cameraActive, microphone: payload.micActive)
        }()
        return SatelliteArbiter.resolve(
            transient: presentation.hudSatellite,
            privacy: privacyContent,
            timer: timerContent,
            timerIsMainIsland: playingNowPlaying == nil,
            dictation: presentation.dictationActive == nil ? nil : .dictation
        )
    }

    /// How much the island's trailing side gives up while the satellite is
    /// out: the whole trailing ear, so the body's right edge lands at the
    /// hardware cutout with only the gutter flare beyond it.
    private var satelliteCollapse: CGFloat {
        satelliteContent != nil ? NotchLayout.hudEarWidth : 0
    }

    public var body: some View {
        let layout = layout

        ZStack(alignment: .top) {
            shape.fill(
                preferences.debugTint
                    ? AnyShapeStyle(.red.opacity(0.55))
                    : AnyShapeStyle(.black)
            )
            content
                // One state, both eyes, one timeline — and driven from here
                // rather than from inside the greeting's own branch. That
                // branch belongs to the phase switch, and the phase changes
                // while the eyes are still performing: a task attached there
                // is at the mercy of a `case` it does not control.
                .task(id: presentation.greeting) { await performGreeting() }
                // The greeting handing over to whatever rests. Both sides fade
                // on one curve, so the last frame of the eyes and the first
                // frame of the music are a single movement rather than a
                // substitution — the island has not moved, only what is inside
                // it. Slower than an ordinary card swap because the eyes are
                // leaving a performance, and cutting from that is jarring in a
                // way cutting between two cards is not.
                .animation(
                    reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.42),
                    value: presentation.greeting
                )
        }
        // `alignment: .top` is not cosmetic. `frame` does not clip, and the
        // ZStack sizes to its tallest child — so if the content cannot compress
        // to the requested height, a centred frame shifts the whole stack
        // upwards and the card ends up drawn *under* the physical cutout.
        // Pinning to the top means overflow hangs off the bottom instead, where
        // the clip below removes it.
        .frame(
            width: layout.boundingSize.width,
            height: layout.boundingSize.height,
            alignment: .top
        )
        // Clipped after the frame, so the clip path and the filled path are
        // measured against the same rect. Inside the ZStack they are not: the
        // fill gets the proposed size and the clip gets the content's own,
        // which lets content render outside the silhouette when they disagree.
        .clipShape(shape)
        // The detached satellite, seated just past the island's right edge
        // while the companion rests — the ear inside goes dark and this circle
        // owns the readout. It slides out from behind the island as if
        // detaching, and tucks back in when its dwell ends.
        .overlay(alignment: .leading) {
            if let content = satelliteContent {
                // Anchored by its *leading* edge, a fixed distance past the
                // island's pulled-in right edge — so every tenant, circle or
                // timer capsule, keeps the same gap regardless of its width.
                let seat = layout.boundingSize.width
                    - (preferences.gutterRadius + NotchLayout.hudEarWidth)
                    + (preferences.satelliteOffset.isFinite
                        ? min(max(preferences.satelliteOffset, -60), 200) : 5)
                SatelliteView(content: content, diameter: geometry.notchSize.height + 1)
                    .offset(x: seat)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(x: -(geometry.notchSize.height + 9))
                            .combined(with: .scale(scale: 0.4))
                            .combined(with: .opacity),
                        removal: .offset(x: -(geometry.notchSize.height + 9))
                            .combined(with: .scale(scale: 0.5))
                            .combined(with: .opacity)
                    ))
                    .allowsHitTesting(false)
            }
        }
        .animation(
            Motion.expand(
                response: preferences.springResponse,
                damping: preferences.springDamping,
                reduced: reduceMotion
            ),
            value: satelliteContent
        )
        // Anchored to the drawn shape, not the card content: content can run
        // taller than the shape on cards with height floors, and dots pinned
        // to its bottom were half-clipped by the shape on exactly those cards.
        .overlay(alignment: .bottom) {
            if (phase == .hover || phase == .expanded), presentation.selected != nil {
                PageDots(
                    count: presentation.count,
                    selectedIndex: presentation.selectedIndex
                )
                // Bright while they carry news — the card just opened or just
                // cycled — then near-invisible, the way iOS treats scroll
                // indicators. Always faintly present so cycling stays
                // discoverable without shouting.
                .opacity(dotsBright ? 1 : 0.3)
                .animation(.easeOut(duration: 0.5), value: dotsBright)
                .onAppear { brightenDots() }
                .onChange(of: presentation.selectedIndex) { brightenDots() }
                .padding(.bottom, 7)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
        .overlay {
            // A constant hairline along the free-hanging edges, so the black
            // shape never disappears into a dark window. It used to be
            // sampled live from the pixels behind the notch — which meant
            // Screen Recording access and a permanent indicator in Control
            // Centre. A fixed subtle stroke reads the same on dark, vanishes
            // into light backdrops on its own, costs nothing, and needs no
            // permission at all.
            if preferences.outlineEnabled, phase != .idle {
                shape.stroke(.white.opacity(0.14), lineWidth: 1)
                    // The top edge is flush with the screen's own edge — the
                    // shape *is* connected there, and outlining it would draw
                    // a seam where the eye expects continuity.
                    .mask(alignment: .bottom) {
                        Rectangle().padding(.top, 3)
                    }
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    .allowsHitTesting(false)
            }
            // A dashed outline while a drag is over the notch, so the shape
            // reads as a target rather than an obstacle.
            if isDropTargeted {
                // `AnyShape` has no `strokeBorder`, so stroke the path itself
                // and inset the frame to keep the dashes inside the silhouette.
                shape.stroke(
                    Color.white.opacity(0.75),
                    style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                )
                .transition(.opacity)
            }
        }
        .contentShape(shape)
        // Suppressed while the route menu is open. This tap pins and dismisses
        // the whole overlay, and it fires *as well as* the row's own gesture —
        // so choosing a device also toggled the card's pinned state, which is
        // what made the menu feel like it stuck and fought back.
        .onTapGesture {
            guard presentation.routePickerRows == 0 else { return }
            onTap()
        }
        // On the shape rather than on the shelf card: a file must be droppable
        // onto a closed notch, which is the whole gesture.
        .dropDestination(for: URL.self) { urls, _ in
            onDropFiles(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(
            Motion.expand(
                response: preferences.springResponse,
                damping: preferences.springDamping,
                reduced: reduceMotion
            ),
            value: phase
        )
        // Standing up changes the height without changing the phase, so the
        // shape has to animate on that too — otherwise it snaps to the taller
        // silhouette while the strip fades in behind it.
        .animation(
            Motion.expand(
                response: preferences.springResponse,
                damping: preferences.springDamping,
                reduced: reduceMotion
            ),
            value: presentation.announcement != nil
        )
        // The HUD grows downward on hover without a phase change, so the shape
        // has to animate on that flag too.
        .animation(
            Motion.expand(
                response: preferences.springResponse,
                damping: preferences.springDamping,
                reduced: reduceMotion
            ),
            value: isHovering
        )
        // Different cards are different sizes — media is shorter than weather,
        // and the route menu is sized to its rows. Without this the silhouette
        // snapped to the new height while the contents cross-faded, which is
        // the jump: two halves of one change moving at different speeds.
        .animation(
            Motion.expand(
                response: preferences.springResponse,
                damping: preferences.springDamping,
                reduced: reduceMotion
            ),
            value: expandedSize
        )
        .animation(Motion.tuning, value: preferences.bottomRadius)
        .animation(Motion.tuning, value: preferences.closedBottomRadius)
        .animation(Motion.tuning, value: preferences.gutterRadius)
        .animation(Motion.tuning, value: preferences.expandedWidth)
        .animation(Motion.tuning, value: preferences.expandedHeight)
        // Every temperature under this view — card, ear, generic row — reads
        // the same unit, without each initializer carrying it.
        .environment(\.weatherUnits, preferences.weatherUnits)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        // The per-panel phase, so a non-hovered display draws its resting
        // content rather than the hovered display's open card.
        switch phase {
        case .idle:
            EmptyView()

        case .peek, .companion:
            if presentation.greeting {
                // Eyes, one per ear, with the cutout between them. Ahead of
                // everything else: for the second and a half this lasts, the
                // notch is a face rather than a status surface.
                HStack(spacing: 0) {
                    NotchGreetingEyes(side: .leading, state: greetingState)
                        .frame(maxWidth: .infinity)
                        .offset(x: preferences.earLeadingOffset)
                    Color.clear.frame(width: geometry.notchSize.width)
                    NotchGreetingEyes(side: .trailing, state: greetingState)
                        .frame(maxWidth: .infinity)
                        .offset(x: -preferences.earTrailingOffset)
                }
                .padding(.horizontal, preferences.gutterRadius)
                .frame(
                    height: geometry.notchSize.height + NotchLayout.compactExtraHeight,
                    alignment: .top
                )
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
                .accessibilityHidden(true)
            }
            // The eyes give way to whatever rests, rather than being replaced
            // by it. Both sides fade on the same curve, so the last frame of
            // the greeting and the first frame of the music are one movement —
            // the island has not moved, only what is inside it.
            // The companion is the music *while it plays*; paused, it follows
            // the selection, so cycling to another card in the open view is
            // respected instead of snapping back to a stalled player.
            // The resting island's content: playing music first, then a
            // running timer, then whatever is selected. Explicit about the
            // timer because the *selected* card can be a standing calendar or
            // weather card that outranks it in the queue — the companion is a
            // resting state for things that run, not a mirror of the queue.
            // A peek draws what it is announcing, falling back to selection.
            // The resting order is a policy, not a mirror of the queue:
            // playing music, then the timer session, then a close event's
            // countdown, then paused music riding out its linger. `selected`
            // comes last and only matters during the brief walk-away rest —
            // a calendar with nothing imminent can no longer squat in the
            // notch behind a paused track's linger.
            else if let shown = phase == .companion
                ? CompactRest.resolve(
                    farewell: presentation.farewell,
                    playingNowPlaying: playingNowPlaying,
                    runningTimer: runningTimerSession,
                    closeEvent: presentation.closeEvent,
                    nowPlaying: presentation.lingeringNowPlaying,
                    selected: presentation.selected,
                    standing: presentation.dictationActive
                  )
                // A peek is explicit news and shows whatever it announces; with
                // nothing announced the same resting rule applies, so a timer
                // nobody started cannot appear here either.
                : (presentation.peeked ?? presentation.selected.flatMap { $0.restsInEars ? $0 : nil }) {
                CompactEarsView(
                    activity: shown,
                    cutoutWidth: geometry.notchSize.width,
                    inset: preferences.gutterRadius,
                    audioLevels: presentation.audioLevels,
                    // While the satellite holds any content, the trailing ear
                    // yields — the island carries only its leading side.
                    trailingHidden: satelliteContent != nil,
                    leadingOffset: preferences.earLeadingOffset,
                    trailingOffset: preferences.earTrailingOffset
                )
                // Deliberately *not* keyed here. Replacing the whole ears view
                // would transition the reserved cutout gap along with it; the
                // swap belongs to each ear individually, and `CompactEarsView`
                // owns it.
                .transition(.opacity)
                // Silent while the notch is standing up. The strip below says
                // the session ended, and a dial still counting beside it — or a
                // countdown reading 0:00 — argues with it. Hidden rather than
                // removed, so the ears keep their footprint and nothing beside
                // the hardware moves.
                .opacity(presentation.announcement == nil ? 1 : 0)
                .animation(Motion.medium, value: presentation.announcement != nil)
                // Held to the compact band, pinned to the top of it.
                //
                // The ears have no height of their own, so when the shape grew
                // to announce something they were handed the taller box and
                // centred themselves in it: the glyph and the countdown slid
                // down to sit level with the strip, as though the announcement
                // had shoved them out of the way. Nothing beside the hardware
                // should move because something appeared below it.
                .frame(
                    height: geometry.notchSize.height + NotchLayout.compactExtraHeight,
                    alignment: .top
                )
                .frame(maxHeight: .infinity, alignment: .top)
            }

            // Standing up appends to the compact view rather than replacing
            // it. The first attempt drew the strip *instead* of the ears, so
            // the moment the notch grew, what it had been showing vanished —
            // a taller notch with nothing in the half the user was looking at.
            if let announcement = presentation.announcement {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: geometry.notchSize.height + NotchLayout.compactExtraHeight)
                    AnnouncementStrip(
                        announcement: announcement,
                        height: NotchLayout.announceExtraHeight(for: geometry),
                        bottomRadius: preferences.bottomRadius
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

        case .hud:
            if let readout = presentation.hud {
                if isHovering {
                    // Hovered: the compact glyph-and-bar gives way entirely to a
                    // Control-Centre style panel below the hardware cutout.
                    VStack(spacing: 0) {
                        // One extra point below the hardware cutout so the title
                        // never reads as touching it.
                        Color.clear
                            .frame(height: geometry.notchSize.height + NotchLayout.compactExtraHeight + 1)
                        HUDAdjustPanel(
                            readout: readout,
                            glowing: preferences.hudGlowBar,
                            outputs: readout.kind == .volume ? presentation.hudOutputs : [],
                            displays: readout.kind == .brightness ? presentation.hudDisplays : [],
                            onAdjust: { level in onHUDAdjust(readout.kind, level) },
                            onDragging: onHUDDragging,
                            onSelectOutput: { id in nowPlayingActions.selectOutput(id) },
                            onAdjustDisplay: onHUDAdjustDisplay
                        )
                        .frame(height: NotchLayout.hudAdjustHeight + hudExtraHeight)
                    }
                    .transition(.opacity)
                } else {
                    HUDEarsView(
                        readout: readout,
                        cutoutWidth: geometry.notchSize.width,
                        inset: preferences.gutterRadius,
                        contentOffset: preferences.hudContentOffset,
                        glowing: preferences.hudGlowBar
                    )
                    // The same dissolve the ears use, so music giving way to a
                    // volume or brightness readout reads like the music-to-
                    // keyboard swap rather than a hard cut. Both live in the
                    // same strip at the same size; only the contents differ.
                    .transition(Motion.earSwap(reduced: reduceMotion))
                }
            }

        case .hover, .expanded:
            // Laid out in the reference Mac's units, then scaled to this one.
            //
            // The alternative — scaling forty font sizes and paddings by hand —
            // puts every tuned number back in play for a result that is meant
            // to be identical in proportion. Scaling up is safe: the backing
            // store is 2x and the ceiling is 1.20, so the text still has more
            // pixels than the display asks for.
            expandedContent
                .frame(
                    width: expandedSize.width / geometry.displayScale,
                    height: expandedSize.height / geometry.displayScale
                )
                .scaleEffect(geometry.displayScale, anchor: .top)
                .frame(width: expandedSize.width, height: expandedSize.height)
                // Drawn over the card's own bottom padding rather than given a
                // row of its own: in-flow, the dots were the first casualty of
                // the cards' fixed heights and never actually rendered.
                .transition(.opacity)
        }
    }

    /// What SwiftUI should treat as "the same card".
    ///
    /// Usually the activity itself. The Clock card is the exception: it is one
    /// card wearing three activities — the ready card, a running session, and
    /// the finished flash — and the provider swaps between them as the user
    /// works. Keyed by activity, starting the stopwatch tore the card down and
    /// built a new one: the whole thing flashed as though it had reloaded, and
    /// the fresh view had no memory of which face was being looked at, so
    /// resetting the stopwatch landed the user back on the timer.
    ///
    /// One key for the family keeps it a single card that changes, which is
    /// what it looks like and what the user is entitled to expect.
    static func cardIdentity(_ activity: Activity) -> String {
        activity.id.kind == .timer ? "card.timer" : "\(activity.id.kind.rawValue).\(activity.id.source)"
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 0) {
            if let selected = presentation.selected {
                if case .event(let payload) = selected.payload {
                    // The month grid *is* the calendar card, not a second view
                    // behind a click. A one-line row with a tinted icon says
                    // less than the grid does and looks like every other row;
                    // the grid is the thing worth opening the notch for.
                    CalendarExpandedView(payload: payload) { rows in
                        presentation.calendarWeekRows = rows
                    }
                        // A stable identity: there is only ever one calendar
                        // card, but its activity id changes when the shown
                        // event changes — and identity-keyed @State snapped a
                        // browsed month back to today mid-look. This must be
                        // the *only* .id: a second, activity-keyed one applied
                        // after it becomes the outermost identity and silently
                        // reintroduces exactly that reset.
                        .id("calendar-card")
                        .transition(Motion.expandedSwap(reduced: reduceMotion))
                } else {
                    ActivityCardView(
                        activity: selected,
                        // Route-aware: this is the card that owns the AirPlay
                        // button, so it is the one that must report the menu's
                        // row count and latch its drags. Wired to the duo-mode
                        // card alone, those were no-ops exactly where they
                        // mattered and the shell never grew its hit region.
                        nowPlayingActions: routeAwareActions,
                        timerActions: timerActions,
                        shelfActions: shelfActions,
                        levelsActions: levelsActions,
                        liveLevel: presentation.latestLevel,
                        // Only the full-width card measures itself; the duo
                        // cards are sized by the split, not by their content.
                        onTimerHeight: { presentation.timerContentHeight = $0 },
                        swapResponse: preferences.springResponse,
                        swapDamping: preferences.springDamping
                    )
                        // Without an explicit identity the card's identity is
                        // positional, so cycling to a *different* activity
                        // animates the old card's geometry into the new one and
                        // carries its `@State` — a half-finished scrub, a stale
                        // measured text width — across to it.
                        .id(Self.cardIdentity(selected))
                        // The same swap the calendar branch uses, so cycling
                        // from the month grid to a card and back is one motion
                        // rather than a dissolve one way and a cut the other.
                        .transition(Motion.expandedSwap(reduced: reduceMotion))
                }

                Spacer(minLength: 0)
            } else {
                // The overlay can be opened deliberately with nothing queued —
                // and because every provider is event-driven, that is the state
                // a curious user reaches most often. Naming the features here is
                // the only discovery path the overlay itself offers.
                Spacer(minLength: 0)
                if isDropTargeted {
                    // Mid-drag the hints are noise; say what the drop will do.
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Drop to add to Shelf")
                            .font(.cardBody)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .transition(.opacity)
                } else {
                    EmptyHintsView(onStartTimer: timerActions.toggle)
                }
                Spacer(minLength: 0)
            }
        }
        // Rigid padding rather than a `Color.clear` spacer. A spacer is a view
        // and can be compressed away when the content does not fit, which puts
        // the card under the physical cutout — the one thing that must never
        // happen. Padding cannot be compressed.
        .padding(.top, geometry.notchSize.height)
        // Inset to the body edge (past the gutter flare), so a card's own
        // padding then reads as breathing room from the *black* edge rather
        // than being eaten by the gutter curve. The old `gutterRadius - 14`
        // collapsed to zero for a typical gutter, leaving content a few points
        // from the edge — the padding complaint.
        .padding(.horizontal, preferences.gutterRadius)
        // Animate on identity, not on the whole activity. `Activity` carries
        // `elapsed`, which changes every second while something plays — so
        // animating on the value re-ran this transaction at 1 Hz and dragged
        // the marquee's scroll offset into it, producing a visible hitch.
        .animation(
            Motion.swap(response: preferences.springResponse, reduced: reduceMotion),
            value: presentation.selected?.id
        )
        // Phase changes swap one compact view for another — music for the level
        // HUD, and back. Without this the branch flips with no animation at all
        // and the transitions above never run.
        // A readout is feedback and must not wait on the timing that suits a
        // change of subject.
        .animation(phase == .hud ? Motion.readoutIn : Motion.earContent, value: phase)
    }
}
