import Foundation

/// What the overlay is currently doing.
public enum NotchPhase: String, Equatable, Sendable, CaseIterable {

    /// Flush with the cutout. Invisible.
    case idle

    /// A brief teaser: slightly larger than the cutout, shown when something
    /// arrives while the user is not looking at it.
    case peek

    /// Open because the cursor is on it.
    case hover

    /// Open because the user clicked. Hover no longer closes it.
    case expanded

    /// A transient level readout (volume, brightness). Preempts whatever was
    /// showing and restores it afterwards.
    case hud

    /// The persistent resting state while music plays: a compact companion in
    /// the ears — artwork on one side, rhythm on the other — that stays until the
    /// music stops or the cursor opens the full card. Same footprint as the HUD.
    case companion

}

/// Timers the reducer can ask for. Named rather than opaque so the runner can
/// cancel and replace them idempotently.
public enum NotchTimer: String, Equatable, Sendable, CaseIterable {
    case peek
    case hud

    /// Releases a pinned card a few seconds after the cursor walks away, so an
    /// accidental click or swipe can never leave the overlay stuck open.
    case pinRelease
}

public struct NotchState: Equatable, Sendable {

    /// Whether a click should hold the overlay open.
    ///
    /// A preference rather than a constant because the Behaviour tab offers it;
    /// it lived there unread until now, which meant a switch that did nothing.
    public var clickPins: Bool = true

    /// Whether hovering opens the overlay.
    ///
    /// Configuration, like `clickPins`, and it lives *here* rather than as a
    /// gate on sending `hoverChanged`: the coordinator once swallowed the
    /// whole event stream when this was off, which meant `isHovering` could
    /// never become true — clicks could not open the overlay and pinned cards
    /// never armed their release. Only the open transition is optional; the
    /// truth of where the cursor is never is.
    public var expandOnHover: Bool = true

    public var phase: NotchPhase

    /// Cursor is inside the region that keeps the overlay open.
    public var isHovering: Bool

    /// Clicked open. Survives the cursor leaving.
    public var isPinned: Bool

    /// Whether the readout on screen was opened from the ear beside the
    /// companion rather than by a level key.
    ///
    /// It decides how it leaves. A readout raised by the keys owns the whole
    /// compact view, and holding it for a moment after the pointer goes is
    /// right — you may be coming back to it. One opened by hovering the
    /// *companion* was never the whole compact view: it was a small thing
    /// beside the music. Giving it the full bar on the way out shows the user
    /// something they never asked for, a second after they walked away.
    public var hudFromCompanion: Bool

    /// Phase to restore when a transient phase (`hud`) ends. `nil` unless a
    /// transient phase is active.
    public var suspended: NotchPhase?

    /// Whether a track is currently playing. When true the overlay rests in
    /// `.companion` instead of `.idle`, so music stays visible in the notch.
    public var hasNowPlaying: Bool

    public init(
        phase: NotchPhase = .idle,
        isHovering: Bool = false,
        isPinned: Bool = false,
        hudFromCompanion: Bool = false,
        suspended: NotchPhase? = nil,
        hasNowPlaying: Bool = false,
        clickPins: Bool = true,
        expandOnHover: Bool = true
    ) {
        self.clickPins = clickPins
        self.expandOnHover = expandOnHover
        self.phase = phase
        self.isHovering = isHovering
        self.isPinned = isPinned
        self.hudFromCompanion = hudFromCompanion
        self.suspended = suspended
        self.hasNowPlaying = hasNowPlaying
    }
}

public enum NotchEvent: Equatable, Sendable {
    case hoverChanged(Bool)
    case clicked
    case peekRequested(TimeInterval)
    /// - Parameter fromCompanion: the readout was opened by hovering the one
    ///   sitting beside the resting companion, rather than by a level key. It
    ///   changes only how it leaves — see `hudFromCompanion`.
    case hudRequested(TimeInterval, fromCompanion: Bool = false)
    case timerFired(NotchTimer)

    /// The shell has decided a held HUD should retire anyway: the pointer was
    /// merely parked on the notch when the key was pressed and has not moved
    /// since, so the "held for adjustment" hover was never an intent. Retires
    /// like the HUD timer would with no hover; a no-op outside `.hud`.
    case hudReleased

    /// Music started (true) or stopped (false). Drives the resting state between
    /// `.idle` and the persistent `.companion`.
    case nowPlayingChanged(Bool)

    /// Explicit close: swipe down, or clicking a pinned overlay again.
    case dismissed

    /// Something external made the overlay invalid: display change, sleep,
    /// a fullscreen app taking over.
    case forceCollapse
}

public enum NotchEffect: Equatable, Sendable {
    case startTimer(NotchTimer, TimeInterval)
    case cancelTimer(NotchTimer)
}
