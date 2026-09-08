import CoreGraphics
import Foundation
import Observation

/// The preference registry.
///
/// Defaults live here rather than in the view layer, so `LedgeCore` stays the
/// single source of truth and the Settings UI is just a set of bindings.
public enum Prefs {

    // Appearance
    public static let bottomRadius = PrefKey<CGFloat>("appearance.bottomRadius", default: 30)
    public static let closedBottomRadius = PrefKey<CGFloat>("appearance.closedBottomRadius", default: 13)
    public static let gutterRadius = PrefKey<CGFloat>("appearance.gutterRadius", default: 10)
    /// Horizontal seat of the detached satellite readout, measured as extra
    /// points right of the vacated ear's centre. A slider because it has to be
    /// eyeballed against the real bezel, like every other appearance value.
    public static let satelliteOffset = PrefKey<CGFloat>("appearance.satelliteOffset", default: 5)
    public static let cornerSmoothing = PrefKey<CGFloat>("appearance.cornerSmoothing", default: 0.6)
    /// Width of each compact ear, which also sets every open card's width
    /// under the one-width discipline. Draft-edited in Settings and applied
    /// with a button — never live-dragged, since it rebuilds the silhouette.
    public static let earWidth = PrefKey<CGFloat>("appearance.earWidth", default: 53)
    /// Horizontal nudge for the leading ear's symbol, in points. Positive
    /// moves it toward the cutout. Draft-edited on the Compact pane.
    public static let earLeadingOffset = PrefKey<CGFloat>("appearance.earLeadingOffset", default: 0)
    /// Same for the trailing ear's indicator; positive moves toward the cutout.
    public static let earTrailingOffset = PrefKey<CGFloat>("appearance.earTrailingOffset", default: 0)
    public static let expandedWidth = PrefKey<CGFloat>("appearance.expandedWidth", default: 420)
    public static let expandedHeight = PrefKey<CGFloat>("appearance.expandedHeight", default: 160)

    // Motion
    public static let springResponse = PrefKey<Double>("motion.springResponse", default: 0.38)
    public static let springDamping = PrefKey<Double>("motion.springDamping", default: 0.68)

    // Behaviour
    public static let hoverOpenDelay = PrefKey<Double>("behaviour.hoverOpenDelay", default: 0.12)
    public static let hoverCloseDelay = PrefKey<Double>("behaviour.hoverCloseDelay", default: 0.22)
    /// Whether a click opens the card in full. The name is historical: a
    /// click no longer outlives the pointer, because a card that followed the
    /// cursor off the notch read as the notch being stuck rather than as
    /// anything the user had asked for.
    public static let peekDuration = PrefKey<Double>("behaviour.peekDuration", default: 2.0)
    public static let hudDuration = PrefKey<Double>("behaviour.hudDuration", default: 1.4)
    /// How long the music companion lingers after playback stops before the
    /// notch closes. Zero hides it immediately.
    ///
    /// Forty-five seconds: long enough to pause, take a call, and come back
    /// to a notch that still shows what you were listening to. A full minute
    /// read as the notch failing to notice the music had stopped.
    public static let companionLinger = PrefKey<Double>("behaviour.companionLinger", default: 120)

    // Timer
    public static let timerWorkMinutes = PrefKey<Double>("timer.workMinutes", default: 25)
    public static let timerShortBreakMinutes = PrefKey<Double>("timer.shortBreakMinutes", default: 5)
    public static let timerLongBreakMinutes = PrefKey<Double>("timer.longBreakMinutes", default: 15)
    public static let timerAutoAdvance = PrefKey<Bool>("timer.autoAdvance", default: true)
    /// Recently used quick-timer minutes, freshest first, comma-joined.
    public static let timerRecents = PrefKey<String>("timer.recents", default: "")

    // Shelf
    /// Parked file paths, newline-separated. `PrefKey` supports no arrays, and
    /// this matches how `disabledProviders` already encodes a set.
    public static let shelfPaths = PrefKey<String>("shelf.paths", default: "")
    /// New screenshots land on the Shelf automatically, ready to drag into a
    /// chat instead of littering the Desktop. Toggleable — some people's
    /// screenshot flow is sacred.
    public static let shelfAutoScreenshots = PrefKey<Bool>("shelf.autoScreenshots", default: true)

    // HUD
    /// On by default: watching volume through CoreAudio needs no permission,
    /// so the ordinary HUD costs the user nothing.
    public static let hudEnabled = PrefKey<Bool>("hud.enabled", default: true)
    public static let hudBrightnessEnabled = PrefKey<Bool>("hud.brightnessEnabled", default: true)
    /// On by default, and gated on Accessibility, which is the only thing that
    /// makes it possible at all.
    ///
    /// It was off, on the reasoning that a tap which swallows key presses must
    /// be switched on deliberately. In practice the reasoning was wrong twice
    /// over. Somebody grants Accessibility for exactly one reason — the
    /// permission's own description says so: Ledge's readout *instead of* the
    /// system's grey square — and then got both anyway, with a switch
    /// elsewhere in Settings they had no reason to look for. And the fallback
    /// it protects against is not a key that does nothing: without the grant
    /// the tap cannot be created, so nothing is swallowed and macOS behaves
    /// exactly as it always did.
    ///
    /// So: granted means suppressed, from the first launch, with no second
    /// switch to find. Anyone who wants the system readout back turns this
    /// off, and their answer is remembered.
    public static let suppressSystemHUD = PrefKey<Bool>("hud.suppressSystem", default: true)
    /// 1/16 matches the size of one press of the hardware key.
    public static let hudVolumeStep = PrefKey<Double>("hud.volumeStep", default: 0.0625)
    public static let hudBrightnessStep = PrefKey<Double>("hud.brightnessStep", default: 0.0625)
    /// Horizontal nudge for the HUD glyph and bar, in points. Positive moves both
    /// toward the cutout (inward); negative toward the screen edges. Symmetric, so
    /// the two sides always stay mirrored.
    public static let hudContentOffset = PrefKey<CGFloat>("hud.contentOffset", default: 0)
    /// Draw the volume/brightness bar with a soft white bloom instead of a flat
    /// fill.
    /// External displays' dimming levels, as `vendor-model-serial=level` pairs.
    /// Keyed by the display's identity rather than its `CGDirectDisplayID`,
    /// which is only stable while it stays plugged in.
    public static let externalBrightness = PrefKey<String>("brightness.external", default: "")

    public static let hudGlowBar = PrefKey<Bool>("hud.glowBar", default: false)

    // Activities
    /// Provider ids the user has switched off, comma-separated.
    ///
    /// One key for all of them, rather than one per provider. Adding a
    /// preference is five coordinated edits across two files; a key per
    /// provider would multiply that by the number of providers for no gain.
    /// Storing only the *exceptions* also means a newly added provider is on by
    /// default without touching preferences at all.
    public static let disabledProviders = PrefKey<String>("activities.disabled", default: "")
    /// The mirror image: providers switched on that default to off.
    public static let enabledProviders = PrefKey<String>("activities.enabled", default: "")

    public static let swipeThreshold = PrefKey<Double>("activities.swipeThreshold", default: 28)
    public static let naturalSwipe = PrefKey<Bool>("activities.naturalSwipe", default: true)
    /// Empty means no weather: the card only exists once a city is chosen.
    public static let weatherCity = PrefKey<String>("weather.city", default: "")
    /// A `WeatherUnits` raw value. "auto" follows the locale; the payloads
    /// themselves stay Celsius and only the drawn number changes.
    public static let weatherUnits = PrefKey<String>("weather.units", default: "auto")
    /// Ambient peeks stay quiet while a macOS Focus is on. On by default —
    /// Do Not Disturb should mean it — but visible and reversible.
    public static let quietDuringFocus = PrefKey<Bool>("behavior.quietDuringFocus", default: true)
    /// The card kind that always opens first — an ActivityKind rawValue, or
    /// empty for the automatic urgency ordering. A direct order beats a score.
    public static let pinnedCard = PrefKey<String>("behavior.pinnedCard", default: "")
    /// The hairline along the shape's free edges. A fixed subtle stroke —
    /// it needs no permission and costs nothing.
    public static let outlineEnabled = PrefKey<Bool>("appearance.outlineEnabled", default: true)

    /// Whether something being *watched* may hold the ears.
    ///
    /// On by default: a video in the compact view reads the same as a track,
    /// and being able to see and pause what is playing is the point of the
    /// companion. Off for anyone who wants the notch to hold still while the
    /// screen is busy — the card stays either way, so the transport is never
    /// more than a hover away.
    public static let showVideoInCompact = PrefKey<Bool>("nowplaying.showVideoInCompact", default: true)

    /// Whether a web page's media may have a card at all.
    ///
    /// A browser holds one now-playing slot for every tab and hands it around,
    /// so the card can be a video nobody chose. Off by default: the card is
    /// most useful for exactly the YouTube tab people watch. On, only real
    /// players — Music, Spotify, Podcasts — reach the notch.
    public static let appMediaOnly = PrefKey<Bool>("nowplaying.appMediaOnly", default: false)

    /// Whether a web page's media is refused a card as well as the compact
    /// view. Only meaningful while `appMediaOnly` is on.
    public static let hideWebMediaCard = PrefKey<Bool>("nowplaying.hideWebMediaCard", default: false)

    // General
    public static let launchAtLogin = PrefKey<Bool>("general.launchAtLogin", default: false)
    public static let hideFromScreenCapture = PrefKey<Bool>("general.hideFromScreenCapture", default: false)

    /// Reveals the fine-tuning panes — shape, motion, ear geometry, timings.
    /// Deliberately has no control of its own: they exist for tuning the app,
    /// not for using it, and a settings window full of sliders nobody needs is
    /// the thing this preference exists to prevent. Turn it on with
    /// `defaults write com.egemert.ledge general.advanced -bool true`.
    public static let advanced = PrefKey<Bool>("general.advanced", default: false)
    /// Hide the overlay while a full-screen app covers the display it lives on.
    /// Draw on every display, not just the notched one. Off by default so an
    /// existing install behaves exactly as it did before.

    // General, cont.
    /// False until the first-run window has been dismissed.
    public static let hasCompletedOnboarding = PrefKey<Bool>("general.onboardingDone", default: false)

    /// False until Ledge has shown this user *something* it can be steered
    /// from — the tour, or Settings in its place. An accessory app draws no
    /// window of its own, so a launch that opens neither is indistinguishable
    /// from a launch that failed; the first one always opens one.
    public static let hasBeenIntroduced = PrefKey<Bool>("general.introduced", default: false)

    /// The tour page the user last reached, so it resumes where it stopped
    /// rather than starting over. A tour can end without being finished —
    /// closed, quit, or the app restarted by the system mid-way.
    public static let tourPage = PrefKey<Double>("general.tourPage", default: 0)

    // Developer
    public static let debugTint = PrefKey<Bool>("developer.debugTint", default: false)

    /// Keys that used to exist and no longer do, cleared on launch so a
    /// setting nobody can see cannot sit in the defaults domain forever.
    ///
    /// `timer.chimeOnFinish` played `NSSound.beep()` when a session ended —
    /// the system alert, which is the same sound a terminal makes when it
    /// wants an answer, and not something anyone asked for. The notch standing
    /// up says the session ended; it does not need to make that noise too.
    public static let retiredNames: [String] = [
        "timer.chimeOnFinish",
        // The menu bar item is gone; the switch that hid it has nothing to
        // hide. Settings is reached by opening Ledge again, and quitting and
        // checking for updates are buttons inside it.
        "general.showMenuBarIcon",
        // Five switches that offered a choice nobody wanted to make. The app
        // simply does the thing they defaulted to: hovering opens a card,
        // clicking pins it, arrivals announce themselves, and the overlay
        // steps aside for a full-screen app. The side-by-side layout, which defaulted to off,
        // is gone with them.
        "behaviour.expandOnHover",
        "behaviour.clickToPin",
        "activities.duoMode",
        "activities.peekOnArrival",
        "general.hideInFullscreen",
        // Gone with them: music and timers simply stay visible in full screen.
        "behavior.companionOverFullscreen",
        // The equaliser just moves now.
        "nowplaying.equalizerEnabled",
    ]

    /// Every key name, for reset-to-defaults.
    public static let allNames: [String] = [
        bottomRadius.name, closedBottomRadius.name, gutterRadius.name, satelliteOffset.name,
        cornerSmoothing.name, expandedWidth.name, expandedHeight.name,
        springResponse.name, springDamping.name,
        hoverOpenDelay.name, hoverCloseDelay.name,
        peekDuration.name, hudDuration.name, companionLinger.name,
        timerWorkMinutes.name, timerShortBreakMinutes.name, timerLongBreakMinutes.name,
        timerAutoAdvance.name, timerRecents.name, shelfPaths.name,
        swipeThreshold.name, naturalSwipe.name,
        disabledProviders.name, enabledProviders.name, weatherCity.name, weatherUnits.name,
        quietDuringFocus.name,
        pinnedCard.name,
        outlineEnabled.name, shelfAutoScreenshots.name,
        earWidth.name, earLeadingOffset.name, earTrailingOffset.name,
        hudEnabled.name, hudBrightnessEnabled.name, suppressSystemHUD.name,
        hudVolumeStep.name, hudBrightnessStep.name, hudContentOffset.name, hudGlowBar.name,
        externalBrightness.name,
        showVideoInCompact.name, appMediaOnly.name, hideWebMediaCard.name,
        launchAtLogin.name, hideFromScreenCapture.name, advanced.name,
        debugTint.name,
    ]
}

/// Observable façade over the store.
///
/// Stored properties (not computed) so `@Observable` can track them; each
/// `didSet` writes through. Settings binds to these directly.
@MainActor
@Observable
public final class Preferences {

    @ObservationIgnored private let store: PreferenceStoring
    @ObservationIgnored private var isLoading = false

    /// Fired after `resetToDefaults()` has rewritten every key, for the few
    /// holders of derived state (the shelf's items, the timer's recents, the
    /// running provider set) that would otherwise write the old value back.
    @ObservationIgnored public var onReset: () -> Void = {}

    public var bottomRadius: CGFloat { didSet { persist(bottomRadius, Prefs.bottomRadius) } }
    public var closedBottomRadius: CGFloat { didSet { persist(closedBottomRadius, Prefs.closedBottomRadius) } }
    public var gutterRadius: CGFloat { didSet { persist(gutterRadius, Prefs.gutterRadius) } }
    public var satelliteOffset: CGFloat { didSet { persist(satelliteOffset, Prefs.satelliteOffset) } }
    public var cornerSmoothing: CGFloat { didSet { persist(cornerSmoothing, Prefs.cornerSmoothing) } }
    public var earWidth: CGFloat { didSet { persist(earWidth, Prefs.earWidth) } }
    public var earLeadingOffset: CGFloat { didSet { persist(earLeadingOffset, Prefs.earLeadingOffset) } }
    public var earTrailingOffset: CGFloat { didSet { persist(earTrailingOffset, Prefs.earTrailingOffset) } }
    public var expandedWidth: CGFloat { didSet { persist(expandedWidth, Prefs.expandedWidth) } }
    public var expandedHeight: CGFloat { didSet { persist(expandedHeight, Prefs.expandedHeight) } }

    public var springResponse: Double { didSet { persist(springResponse, Prefs.springResponse) } }
    public var springDamping: Double { didSet { persist(springDamping, Prefs.springDamping) } }

    public var hoverOpenDelay: Double { didSet { persist(hoverOpenDelay, Prefs.hoverOpenDelay) } }
    public var hoverCloseDelay: Double { didSet { persist(hoverCloseDelay, Prefs.hoverCloseDelay) } }
    public var peekDuration: Double { didSet { persist(peekDuration, Prefs.peekDuration) } }
    public var companionLinger: Double { didSet { persist(companionLinger, Prefs.companionLinger) } }
    public var timerWorkMinutes: Double { didSet { persist(timerWorkMinutes, Prefs.timerWorkMinutes) } }
    public var timerShortBreakMinutes: Double { didSet { persist(timerShortBreakMinutes, Prefs.timerShortBreakMinutes) } }
    public var timerLongBreakMinutes: Double { didSet { persist(timerLongBreakMinutes, Prefs.timerLongBreakMinutes) } }
    public var timerAutoAdvance: Bool { didSet { persist(timerAutoAdvance, Prefs.timerAutoAdvance) } }
    public var timerRecents: String { didSet { persist(timerRecents, Prefs.timerRecents) } }
    public var shelfPaths: String { didSet { persist(shelfPaths, Prefs.shelfPaths) } }
    public var hudDuration: Double { didSet { persist(hudDuration, Prefs.hudDuration) } }

    public var hudEnabled: Bool { didSet { persist(hudEnabled, Prefs.hudEnabled) } }
    public var hudBrightnessEnabled: Bool { didSet { persist(hudBrightnessEnabled, Prefs.hudBrightnessEnabled) } }
    public var suppressSystemHUD: Bool { didSet { persist(suppressSystemHUD, Prefs.suppressSystemHUD) } }
    public var hudVolumeStep: Double { didSet { persist(hudVolumeStep, Prefs.hudVolumeStep) } }
    public var hudBrightnessStep: Double { didSet { persist(hudBrightnessStep, Prefs.hudBrightnessStep) } }
    public var hudContentOffset: CGFloat { didSet { persist(hudContentOffset, Prefs.hudContentOffset) } }
    public var hudGlowBar: Bool { didSet { persist(hudGlowBar, Prefs.hudGlowBar) } }
    public var externalBrightness: String { didSet { persist(externalBrightness, Prefs.externalBrightness) } }

    public var disabledProviders: String { didSet { persist(disabledProviders, Prefs.disabledProviders) } }
    public var enabledProviders: String { didSet { persist(enabledProviders, Prefs.enabledProviders) } }

    public var swipeThreshold: Double { didSet { persist(swipeThreshold, Prefs.swipeThreshold) } }
    public var naturalSwipe: Bool { didSet { persist(naturalSwipe, Prefs.naturalSwipe) } }
    public var weatherCity: String { didSet { persist(weatherCity, Prefs.weatherCity) } }
    public var weatherUnits: String { didSet { persist(weatherUnits, Prefs.weatherUnits) } }
    public var quietDuringFocus: Bool { didSet { persist(quietDuringFocus, Prefs.quietDuringFocus) } }
    public var pinnedCard: String { didSet { persist(pinnedCard, Prefs.pinnedCard) } }
    public var outlineEnabled: Bool { didSet { persist(outlineEnabled, Prefs.outlineEnabled) } }
    public var shelfAutoScreenshots: Bool { didSet { persist(shelfAutoScreenshots, Prefs.shelfAutoScreenshots) } }

    public var showVideoInCompact: Bool { didSet { persist(showVideoInCompact, Prefs.showVideoInCompact) } }
    public var appMediaOnly: Bool { didSet { persist(appMediaOnly, Prefs.appMediaOnly) } }
    public var hideWebMediaCard: Bool { didSet { persist(hideWebMediaCard, Prefs.hideWebMediaCard) } }

    public var launchAtLogin: Bool { didSet { persist(launchAtLogin, Prefs.launchAtLogin) } }
    public var hideFromScreenCapture: Bool { didSet { persist(hideFromScreenCapture, Prefs.hideFromScreenCapture) } }
    public var advanced: Bool { didSet { persist(advanced, Prefs.advanced) } }

    public var hasCompletedOnboarding: Bool { didSet { persist(hasCompletedOnboarding, Prefs.hasCompletedOnboarding) } }
    public var hasBeenIntroduced: Bool { didSet { persist(hasBeenIntroduced, Prefs.hasBeenIntroduced) } }
    public var tourPage: Double { didSet { persist(tourPage, Prefs.tourPage) } }
    public var debugTint: Bool { didSet { persist(debugTint, Prefs.debugTint) } }

    public init(store: PreferenceStoring) {
        self.store = store
        store.removeAll(named: Prefs.retiredNames)
        bottomRadius = store.value(for: Prefs.bottomRadius)
        closedBottomRadius = store.value(for: Prefs.closedBottomRadius)
        gutterRadius = store.value(for: Prefs.gutterRadius)
        satelliteOffset = store.value(for: Prefs.satelliteOffset)
        cornerSmoothing = store.value(for: Prefs.cornerSmoothing)
        earWidth = store.value(for: Prefs.earWidth)
        earLeadingOffset = store.value(for: Prefs.earLeadingOffset)
        earTrailingOffset = store.value(for: Prefs.earTrailingOffset)
        expandedWidth = store.value(for: Prefs.expandedWidth)
        expandedHeight = store.value(for: Prefs.expandedHeight)
        springResponse = store.value(for: Prefs.springResponse)
        springDamping = store.value(for: Prefs.springDamping)
        hoverOpenDelay = store.value(for: Prefs.hoverOpenDelay)
        hoverCloseDelay = store.value(for: Prefs.hoverCloseDelay)
        peekDuration = store.value(for: Prefs.peekDuration)
        companionLinger = store.value(for: Prefs.companionLinger)
        timerWorkMinutes = store.value(for: Prefs.timerWorkMinutes)
        timerShortBreakMinutes = store.value(for: Prefs.timerShortBreakMinutes)
        timerLongBreakMinutes = store.value(for: Prefs.timerLongBreakMinutes)
        timerAutoAdvance = store.value(for: Prefs.timerAutoAdvance)
        timerRecents = store.value(for: Prefs.timerRecents)
        shelfPaths = store.value(for: Prefs.shelfPaths)
        hudDuration = store.value(for: Prefs.hudDuration)
        hudEnabled = store.value(for: Prefs.hudEnabled)
        hudBrightnessEnabled = store.value(for: Prefs.hudBrightnessEnabled)
        suppressSystemHUD = store.value(for: Prefs.suppressSystemHUD)
        hudVolumeStep = store.value(for: Prefs.hudVolumeStep)
        hudBrightnessStep = store.value(for: Prefs.hudBrightnessStep)
        hudContentOffset = store.value(for: Prefs.hudContentOffset)
        hudGlowBar = store.value(for: Prefs.hudGlowBar)
        externalBrightness = store.value(for: Prefs.externalBrightness)
        disabledProviders = store.value(for: Prefs.disabledProviders)
        enabledProviders = store.value(for: Prefs.enabledProviders)
        swipeThreshold = store.value(for: Prefs.swipeThreshold)
        naturalSwipe = store.value(for: Prefs.naturalSwipe)
        weatherCity = store.value(for: Prefs.weatherCity)
        weatherUnits = store.value(for: Prefs.weatherUnits)
        quietDuringFocus = store.value(for: Prefs.quietDuringFocus)
        pinnedCard = store.value(for: Prefs.pinnedCard)
        outlineEnabled = store.value(for: Prefs.outlineEnabled)
        shelfAutoScreenshots = store.value(for: Prefs.shelfAutoScreenshots)
        showVideoInCompact = store.value(for: Prefs.showVideoInCompact)
        appMediaOnly = store.value(for: Prefs.appMediaOnly)
        hideWebMediaCard = store.value(for: Prefs.hideWebMediaCard)
        launchAtLogin = store.value(for: Prefs.launchAtLogin)
        hideFromScreenCapture = store.value(for: Prefs.hideFromScreenCapture)
        advanced = store.value(for: Prefs.advanced)
        hasCompletedOnboarding = store.value(for: Prefs.hasCompletedOnboarding)
        hasBeenIntroduced = store.value(for: Prefs.hasBeenIntroduced)
        tourPage = store.value(for: Prefs.tourPage)
        debugTint = store.value(for: Prefs.debugTint)
    }

    /// Sets the debug tint for this run only. The LEDGE_DEBUG_TINT launch
    /// flag goes through here so one debug launch cannot leave the shape
    /// red on every normal launch after it.
    public func setDebugTintTransient(_ value: Bool) {
        let wasLoading = isLoading
        isLoading = true
        debugTint = value
        isLoading = wasLoading
    }

    private func persist<Value>(_ value: Value, _ key: PrefKey<Value>) {
        guard !isLoading else { return }
        store.set(value, for: key)
    }

    /// Whether the user (or a previous seed) ever wrote this preference.
    public func hasStoredValue(_ name: String) -> Bool {
        store.hasValue(named: name)
    }

    public func resetToDefaults() {
        store.removeAll(named: Prefs.allNames + Prefs.retiredNames)
        isLoading = true
        bottomRadius = Prefs.bottomRadius.defaultValue
        closedBottomRadius = Prefs.closedBottomRadius.defaultValue
        gutterRadius = Prefs.gutterRadius.defaultValue
        satelliteOffset = Prefs.satelliteOffset.defaultValue
        cornerSmoothing = Prefs.cornerSmoothing.defaultValue
        earWidth = Prefs.earWidth.defaultValue
        earLeadingOffset = Prefs.earLeadingOffset.defaultValue
        earTrailingOffset = Prefs.earTrailingOffset.defaultValue
        expandedWidth = Prefs.expandedWidth.defaultValue
        expandedHeight = Prefs.expandedHeight.defaultValue
        springResponse = Prefs.springResponse.defaultValue
        springDamping = Prefs.springDamping.defaultValue
        hoverOpenDelay = Prefs.hoverOpenDelay.defaultValue
        hoverCloseDelay = Prefs.hoverCloseDelay.defaultValue
        peekDuration = Prefs.peekDuration.defaultValue
        companionLinger = Prefs.companionLinger.defaultValue
        timerWorkMinutes = Prefs.timerWorkMinutes.defaultValue
        timerShortBreakMinutes = Prefs.timerShortBreakMinutes.defaultValue
        timerLongBreakMinutes = Prefs.timerLongBreakMinutes.defaultValue
        timerAutoAdvance = Prefs.timerAutoAdvance.defaultValue
        timerRecents = Prefs.timerRecents.defaultValue
        shelfPaths = Prefs.shelfPaths.defaultValue
        hudDuration = Prefs.hudDuration.defaultValue
        hudEnabled = Prefs.hudEnabled.defaultValue
        hudBrightnessEnabled = Prefs.hudBrightnessEnabled.defaultValue
        suppressSystemHUD = Prefs.suppressSystemHUD.defaultValue
        hudVolumeStep = Prefs.hudVolumeStep.defaultValue
        hudBrightnessStep = Prefs.hudBrightnessStep.defaultValue
        hudContentOffset = Prefs.hudContentOffset.defaultValue
        hudGlowBar = Prefs.hudGlowBar.defaultValue
        externalBrightness = Prefs.externalBrightness.defaultValue
        disabledProviders = Prefs.disabledProviders.defaultValue
        enabledProviders = Prefs.enabledProviders.defaultValue
        swipeThreshold = Prefs.swipeThreshold.defaultValue
        naturalSwipe = Prefs.naturalSwipe.defaultValue
        weatherCity = Prefs.weatherCity.defaultValue
        weatherUnits = Prefs.weatherUnits.defaultValue
        quietDuringFocus = Prefs.quietDuringFocus.defaultValue
        pinnedCard = Prefs.pinnedCard.defaultValue
        outlineEnabled = Prefs.outlineEnabled.defaultValue
        shelfAutoScreenshots = Prefs.shelfAutoScreenshots.defaultValue
        showVideoInCompact = Prefs.showVideoInCompact.defaultValue
        appMediaOnly = Prefs.appMediaOnly.defaultValue
        hideWebMediaCard = Prefs.hideWebMediaCard.defaultValue
        launchAtLogin = Prefs.launchAtLogin.defaultValue
        hideFromScreenCapture = Prefs.hideFromScreenCapture.defaultValue
        advanced = Prefs.advanced.defaultValue
        // Onboarding is intentionally NOT reset — resetting settings should not
        // re-show the welcome window to an existing user.
        debugTint = Prefs.debugTint.defaultValue
        isLoading = false
        onReset()
    }

    // MARK: - Providers

    /// Provider ids currently switched off.
    /// Providers the user switched on explicitly. Only meaningful for the ones
    /// that are off by default.
    public var enabledProviderIDs: Set<String> {
        // Trimmed and empty-filtered just like the disabled list: a hand-edited
        // "spotify, weather" must not quietly lose its second entry.
        Set(
            enabledProviders
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    public var disabledProviderIDs: Set<String> {
        Set(
            disabledProviders
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
    }

    /// Whether a provider should run.
    ///
    /// The stored preference holds only the *exceptions*, so a provider the user
    /// has never touched has no entry either way — and `defaultEnabled` is what
    /// decides it. Without that argument an off-by-default provider silently ran
    /// anyway, which is exactly what `isEnabledByDefault` was meant to prevent.
    public func isProviderEnabled(_ id: String, defaultEnabled: Bool = true) -> Bool {
        if disabledProviderIDs.contains(id) { return false }
        if enabledProviderIDs.contains(id) { return true }
        return defaultEnabled
    }

    public func setProvider(_ id: String, enabled: Bool) {
        var disabled = disabledProviderIDs
        var enabledIDs = enabledProviderIDs
        if enabled {
            disabled.remove(id)
            // Recorded explicitly, so switching on an off-by-default provider
            // survives a relaunch rather than reverting to its default.
            enabledIDs.insert(id)
        } else {
            disabled.insert(id)
            enabledIDs.remove(id)
        }
        // Sorted so the stored strings are stable and do not churn in defaults
        // every time a toggle is flipped.
        disabledProviders = disabled.sorted().joined(separator: ",")
        enabledProviders = enabledIDs.sorted().joined(separator: ",")
    }

    /// The tuned numbers, in a form that can be pasted back into `Prefs`.
    public var exportedSwift: String {
        [
            ("bottomRadius", bottomRadius), ("closedBottomRadius", closedBottomRadius),
            ("gutterRadius", gutterRadius), ("cornerSmoothing", cornerSmoothing),
            ("expandedWidth", expandedWidth), ("expandedHeight", expandedHeight),
            ("springResponse", CGFloat(springResponse)), ("springDamping", CGFloat(springDamping)),
            ("hoverOpenDelay", CGFloat(hoverOpenDelay)), ("hoverCloseDelay", CGFloat(hoverCloseDelay)),
        ]
        .map { "\($0.0): \(String(format: "%.2f", Double($0.1)))" }
        .joined(separator: "\n")
    }
}
