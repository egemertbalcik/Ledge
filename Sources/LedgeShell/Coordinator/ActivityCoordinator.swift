import Foundation
import LedgeCore
import LedgeProviders
import LedgeUI
import os

/// Owns the activity queue: runs the providers, mirrors the queue into the
/// presentation the view reads, and schedules expiry.
@MainActor
public final class ActivityCoordinator {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "activities")

    private let hub = ProviderHub()
    private let presentation: NotchPresentation
    private let preferences: Preferences
    private let expiry = TimerBank<ActivityID>()

    /// Expiry deadlines already scheduled, keyed by activity, valued by the
    /// `createdAt` they were scheduled against. Re-scheduling only happens when
    /// that changes, so an activity that updates continuously does not have its
    /// lifetime extended forever by its own updates.
    private var scheduledFor: [ActivityID: TimeInterval] = [:]

    /// Something new arrived — the shell may want to peek.
    public var onArrival: (Activity) -> Void = { _ in }

    /// The queue went empty, so there is nothing left to show.
    public var onEmpty: () -> Void = {}

    /// Fires when music's presence or play state changes, so the overlay can
    /// rest in the companion while it plays, linger after it pauses, and close
    /// once it is gone. `present` = a track is loaded; `playing` = it is playing.
    public var onNowPlayingChanged: (
        _ present: Bool, _ playing: Bool, _ pausedTimerRemaining: TimeInterval?
    ) -> Void = { _, _, _ in }

    /// When the current timer session went from ticking to paused, for the
    /// bounded paused-timer rest.
    private var timerPausedSince: TimeInterval?
    static let pausedTimerLinger: TimeInterval = 5 * 60

    private var knownIDs: Set<ActivityID> = []
    private var lastNowPlayingPresent = false
    private var lastNowPlayingPlaying = false
    private var lastNowPlayingSource: String?

    /// Ids the user swiped away recently, so their next republish is not
    /// announced back at them. Pruned against the window on every sync.
    private var recentlyDismissed: [ActivityID: TimeInterval] = [:]
    private static let dismissQuietWindow: TimeInterval = 15

    /// Whether the queue was empty last time it changed.
    ///
    /// `onEmpty` collapses the overlay, so firing it on *every* event that
    /// leaves the queue empty — rather than on the transition into empty —
    /// sends a redundant `.dismissed` each time. Batch retraction from
    /// disabling a provider makes that fire mid-batch.
    private var wasEmpty = true
    private let now: () -> TimeInterval

    /// Whether a permission is currently usable. Injected rather than reached
    /// for, so this stays free of the system layer and testable.
    ///
    /// Defaults to yes: a coordinator built without one behaves exactly as it
    /// did before, which is what every existing test expects.
    private let isPermitted: (PermissionKind) -> Bool

    public init(
        presentation: NotchPresentation,
        preferences: Preferences,
        isPermitted: @escaping (PermissionKind) -> Bool = { _ in true },
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.presentation = presentation
        self.preferences = preferences
        self.isPermitted = isPermitted
        self.now = now
    }

    /// Whether this provider can do its job right now: switched on, and
    /// holding whatever permission it needs.
    ///
    /// A provider whose permission is refused used to start anyway and poll
    /// something that would never answer — no cards, no error, just work. It
    /// waits instead, and `restartProvider` brings it in the moment the grant
    /// lands.
    func canRun(_ registration: ProviderRegistration) -> Bool {
        guard preferences.isProviderEnabled(
            registration.id, defaultEnabled: registration.isEnabledByDefault
        ) else { return false }
        guard let permission = registration.permission else { return true }
        // Nothing that touches a permission runs before the welcome tour is
        // done — not even the ones that would only *read* a status. The read
        // is what raised an Automation dialog on a fresh Mac seconds after
        // launch, with no window on screen to say what had asked for it.
        guard preferences.hasCompletedOnboarding else { return false }
        guard !registration.permissionIsOptional else { return true }
        return isPermitted(permission)
    }

    public func add(_ provider: any ActivityProvider) {
        hub.add(provider)
    }

    /// The registrations this coordinator knows how to run, kept so a provider
    /// can be built lazily the first time it is switched on.
    private var registrations: [String: ProviderRegistration] = [:]

    public func register(_ registration: ProviderRegistration) {
        registrations[registration.id] = registration
    }

    /// Starts every registered provider the user has switched on.
    ///
    /// A disabled provider is never constructed — `make` is deferred precisely
    /// so a switched-off source does no work and asks for no permission.
    public func startEnabled() {
        for (id, registration) in registrations
        where canRun(registration) && !hub.registeredIdentifiers.contains(id) {
            hub.add(registration.make())
        }
        hub.start()

        // Event-driven providers are silent until something happens, so without
        // this there is no way to tell a running provider from one that never
        // started.
        let running = hub.runningIdentifiers.sorted().joined(separator: ", ")
        let off = registrations.values
            .filter { !preferences.isProviderEnabled($0.id, defaultEnabled: $0.isEnabledByDefault) }
            .map(\.id)
            .sorted().joined(separator: ", ")
        Self.log.notice("""
            providers running: [\(running, privacy: .public)]             disabled: [\(off, privacy: .public)]
            """)
    }

    /// Switches one provider on or off at runtime.
    ///
    /// Enabling builds and starts it; disabling stops it and takes its cards
    /// off screen. Neither requires a relaunch.
    public func setProvider(_ id: String, enabled: Bool) {
        guard let registration = registrations[id] else { return }
        preferences.setProvider(id, enabled: enabled)

        if enabled {
            if !hub.registeredIdentifiers.contains(id) {
                hub.add(registration.make())
            }
            hub.start(id)
            Self.log.notice("provider \(id, privacy: .public) enabled")
        } else {
            hub.remove(id)
            Self.log.notice("provider \(id, privacy: .public) disabled")
        }
    }

    /// Whether a provider is currently registered (built and running).
    public func isProviderRunning(_ id: String) -> Bool {
        hub.registeredIdentifiers.contains(id)
    }

    /// Brings the running set back in line with the preferences after they
    /// changed underneath — "Reset all settings" flips every provider back to
    /// its default without going through `setProvider`, and nothing else
    /// observes those keys. Starts what is now enabled and not running, stops
    /// what is now disabled and running.
    public func reconcileWithPreferences() {
        for (id, registration) in registrations {
            let wanted = preferences.isProviderEnabled(id, defaultEnabled: registration.isEnabledByDefault)
            let running = hub.registeredIdentifiers.contains(id)
            if wanted && !running {
                hub.add(registration.make())
                hub.start(id)
                Self.log.notice("provider \(id, privacy: .public) enabled by reconcile")
            } else if !wanted && running {
                hub.remove(id)
                Self.log.notice("provider \(id, privacy: .public) disabled by reconcile")
            }
        }
    }

    /// Rebuilds one provider without touching its enabled preference. Used when
    /// configuration it was constructed over (the weather city) changes.
    /// Refreshes the weather in place. A restart on the wake path retracted
    /// the standing card and threw away the stale-but-valid reading at the
    /// exact moment Wi-Fi was still reassociating — the card vanished for the
    /// whole retry interval instead of quietly updating.
    public func refreshWeather() {
        (hub.provider(for: "weather") as? WeatherProvider)?.refresh()
    }

    public func refreshWeatherIfStale(olderThan maxAge: TimeInterval) {
        (hub.provider(for: "weather") as? WeatherProvider)?.refreshIfStale(olderThan: maxAge)
    }

    public func refreshCalendar() {
        (hub.provider(for: "calendar") as? CalendarProvider)?.refresh()
    }

    /// Stops a provider without recording it as switched off.
    ///
    /// For a permission taken away underneath us: the user still wants this
    /// card, they simply cannot have it right now, so the preference must not
    /// be rewritten. `restartProvider` brings it back when the grant returns.
    public func suspendProvider(_ id: String) {
        guard hub.registeredIdentifiers.contains(id) else { return }
        hub.remove(id)
        Self.log.notice("provider \(id, privacy: .public) suspended — permission withdrawn")
    }

    public func restartProvider(_ id: String) {
        guard let registration = registrations[id], canRun(registration) else { return }
        hub.remove(id)
        hub.add(registration.make())
        hub.start(id)
    }

    public var registeredProviders: [ProviderRegistration] {
        registrations.values.sorted { $0.displayName < $1.displayName }
    }

    public func start() {
        hub.onChange = { [weak self] queue in self?.queueChanged(queue) }
        expiry.onFire = { [weak self] id in
            guard let self else { return }
            // Hashed: a device card's source *is* its Bluetooth MAC address.
            Self.log.debug("expired \(id.kind.rawValue, privacy: .public):\(id.source, privacy: .private(mask: .hash))")
            self.hub.mutate { $0.retract(id) }
        }
        hub.start()
    }

    public func stop() {
        hub.stop()
        expiry.cancelAll()
        // Without this, a restart would treat everything already on screen as a
        // fresh arrival and fire a peek for each.
        // Ordering state is session state: a restart must not inherit a
        // freeze that has no open stack behind it. Reset *before* the
        // bookkeeping clears — mutate notifies, and a notification landing on
        // emptied knownIDs would re-announce every standing card and re-arm
        // the expiry timers this stop just cancelled.
        hub.mutate { $0.orderFrozen = false }
        // An in-flight provider event whose resumption was enqueued before
        // cancellation still lands after this returns; with the bookkeeping
        // cleared it would re-announce every standing card into the stopped
        // shell and re-arm the expiry timers just cancelled. Unhook the
        // callbacks — start() rewires both.
        hub.onChange = { _ in }
        expiry.onFire = { _ in }
        knownIDs.removeAll()
        scheduledFor.removeAll()
        announcedPayload.removeAll()
        wasEmpty = true
        lastNowPlayingPresent = false
        lastNowPlayingPlaying = false
        lastNowPlayingSource = nil
        recentlyDismissed.removeAll()
        pendingSelection = nil
        timerPausedSince = nil
    }

    // MARK: - User actions

    /// Selects a specific activity, so what the user opens matches what they
    /// were just looking at.
    public func select(_ id: ActivityID) { hub.mutate { $0.select(id) } }

    /// Selects an id the moment it lands on the queue — for user actions
    /// whose card arrives asynchronously. Starting a timer from a chip
    /// retracts the ready card and publishes the session across the provider
    /// stream: selecting immediately misses (the card is not there yet), and
    /// not selecting strands the user on whichever neighbour inherited the
    /// stage. The intent expires quickly; it must not fire on a much later
    /// unrelated republish.
    public func selectWhenAvailable(_ id: ActivityID) {
        if hub.queue.activities.contains(where: { $0.id == id }) {
            select(id)
            return
        }
        pendingSelection = (id, now() + 2)
    }

    private var pendingSelection: (id: ActivityID, until: TimeInterval)?

    public func cycleForward() { hub.mutate { $0.cycleForward() } }
    public func cycleBackward() { hub.mutate { $0.cycleBackward() } }
    public func dismissSelected() {
        // Remembered so a continuously-republishing provider (now playing,
        // the timer — every second) cannot re-announce the very card the
        // user just swiped away: its next republish is a technical arrival,
        // not news.
        if let id = hub.queue.selectedID {
            recentlyDismissed[id] = Date().timeIntervalSinceReferenceDate
        }
        hub.mutate { $0.dismissSelected() }
    }
    /// Mirrors the open card stack: while it is on screen, nothing may
    /// reorder under the cursor; closing applies the world's accumulated
    /// score changes in one motion.
    public func setOrderFrozen(_ frozen: Bool) {
        hub.mutate { $0.orderFrozen = frozen }
    }

    public func setPinnedKind(_ kind: ActivityKind?) {
        hub.mutate { $0.pinnedKind = kind }
    }

    public var isEmpty: Bool { hub.queue.isEmpty }

    /// The current card with an exact id, for a drained peek that needs the
    /// activity back to display. By id, not kind: two queued device connects
    /// must each resolve to their own card.
    public func activity(withID id: ActivityID) -> Activity? {
        hub.queue.activities.first { $0.id == id }
    }

    // MARK: - Syncing

    /// The payload last announced per re-announcing activity. A Focus toggle,
    /// a second keyboard switch, an unplug after a plug-in — all reuse one id,
    /// so the only reliable signal that the *user's world changed again* is
    /// the payload changing.
    private var announcedPayload: [ActivityID: ActivityPayload] = [:]

    private func queueChanged(_ queue: ActivityQueue) {
        // Before ANY bookkeeping: landing the pending selection re-enters
        // `hub.mutate`, whose notification re-runs this whole function with
        // the selection applied — that nested pass does the real work
        // (arrivals included, since `knownIDs` is untouched here), and this
        // outer pass must fall away without syncing a stale queue over it.
        if let pending = pendingSelection {
            if now() > pending.until {
                pendingSelection = nil
            } else if queue.activities.contains(where: { $0.id == pending.id }) {
                pendingSelection = nil
                hub.mutate { $0.select(pending.id) }
                return
            }
        }

        let currentIDs = Set(queue.activities.map(\.id))
        var arrived = currentIDs.subtracting(knownIDs)
        knownIDs = currentIDs

        // Kinds that reuse one id re-announce when their payload changes, so
        // a second toggle inside the first card's lifetime still gets its own
        // motion. Restricted to Focus and *expiring* cards: Now Playing and
        // the timer re-publish every second and must not re-peek. These
        // changed arrivals are also exempt from the dismiss quiet-window
        // below — a payload that moved is *news* (the next Focus toggle, a
        // second keyboard switch), not the swiped-away card creeping back.
        var changed: Set<ActivityID> = []
        for activity in queue.activities
        where activity.id.kind == .focus || activity.expiresAfter != nil {
            if announcedPayload[activity.id] != activity.payload {
                arrived.insert(activity.id)
                changed.insert(activity.id)
            }
            announcedPayload[activity.id] = activity.payload
        }
        for id in Array(announcedPayload.keys) where !currentIDs.contains(id) {
            announcedPayload[id] = nil
        }

        syncPresentation(queue)
        syncExpiry(queue)

        // Announce arrivals after the presentation is up to date, so a peek
        // triggered here already has something to draw. *Every* arrival in
        // the batch, most urgent first: the first takes the stage and the
        // coordinator's own peek-in-progress branch queues the rest — only
        // announcing the max silently dropped a simultaneous second arrival.
        // A card the user dismissed moments ago is exempt: republishing
        // providers bring it back within a second, and announcing that read
        // as the app overriding the swipe.
        let dismissCutoff = Date().timeIntervalSinceReferenceDate - Self.dismissQuietWindow
        recentlyDismissed = recentlyDismissed.filter { $0.value > dismissCutoff }
        for activity in arrived
            .compactMap({ id in queue.activities.first { $0.id == id } })
            .sorted(by: { $0.priority > $1.priority }) {
            // Changed payloads pass the window: the arrival handler is also
            // where the coordinator *learns* Focus state, and filtering a
            // Focus flip because its card was dismissed 10 seconds earlier
            // left the quiet-during-Focus gate blind for the whole session.
            guard recentlyDismissed[activity.id] == nil || changed.contains(activity.id)
            else { continue }
            onArrival(activity)
        }

        if queue.isEmpty && !wasEmpty { onEmpty() }
        wasEmpty = queue.isEmpty

        // Tell the overlay what may *rest* in the island — content-aware, not
        // a mirror of the queue. Indefinite residents: playing music, a
        // ticking timer, and a close event (the countdown to a meeting under an
        // hour away is exactly what a glanceable notch is for).
        // Bounded residents: paused music (the companion linger) and a paused
        // timer (five minutes — a session frozen for an afternoon must not
        // squat in the notch). Everything else never rests.
        let timerRunning = queue.activities.contains {
            if case .timer(let payload) = $0.payload { return !payload.isIdle && payload.isRunning }
            return false
        }
        // A finished leg's announcement is not a paused session: it expires
        // on its own and must not stamp `timerPausedSince` (a real pause
        // inside its 12 seconds inherited the older stamp) nor rest as a
        // bounded resident.
        let timerPaused = queue.activities.contains {
            if case .timer(let payload) = $0.payload {
                return !payload.isIdle && !payload.isRunning && !payload.isFinished
            }
            return false
        }
        if timerPaused {
            if timerPausedSince == nil { timerPausedSince = now() }
        } else {
            timerPausedSince = nil
        }
        let pausedTimerRemaining = timerPausedSince.map {
            max(0, Self.pausedTimerLinger - (now() - $0))
        }
        let closeEvent = queue.activities.contains {
            if case .event(let payload) = $0.payload {
                return payload.hasEvent && payload.startsIn <= 60 * 60 && payload.startsIn >= -60
            }
            return false
        }
        // `restsInEars`, not `isPlaying`: this decides whether the island
        // opens, and the ears decide what to draw in it. When the two rules
        // differed the island opened for a video the compact view then
        // declined to draw, and the notch sat there with two empty ears.
        // Dictation counts as a resident while it lasts. Without this the card
        // existed, flashed for its announcement and vanished — the phase only
        // opens for something the coordinator calls a live fact, and a thing
        // that is listening to you right now is exactly that.
        let dictation = queue.activities.contains { activity in
            guard case .privacy(let payload) = activity.payload else { return false }
            return payload.isSystemSpeech && payload.micActive && !payload.cameraActive
        }
        let playing = timerRunning || closeEvent || dictation || queue.activities.contains {
            $0.id.kind == .nowPlaying && $0.restsInEars
        }
        let present = playing
            || queue.activities.contains { activity in
                guard case .nowPlaying(let payload) = activity.payload else { return false }
                // Paused media is present for its linger — but only what the
                // ears would have drawn had it still been playing.
                return payload.showsInCompact
            }
            || (pausedTimerRemaining ?? 0) > 0
        // The *source* is part of the change too: Music handing off to Spotify
        // keeps both booleans true, but the equalizer's per-track character
        // must follow the player actually making sound.
        let playingSource = queue.activities.first {
            if case .nowPlaying(let payload) = $0.payload { return payload.isPlaying }
            return false
        }?.id.source
        if present != lastNowPlayingPresent || playing != lastNowPlayingPlaying
            || playingSource != lastNowPlayingSource {
            lastNowPlayingPresent = present
            lastNowPlayingPlaying = playing
            lastNowPlayingSource = playingSource
            onNowPlayingChanged(present, playing, pausedTimerRemaining)
        }

        // What is actually on the queue, so a provider that publishes nothing
        // can be told apart from one that is not running at all. Kinds only,
        // sources hashed: a device card's source is its Bluetooth MAC and a
        // calendar card's is its event key — identifiers, not diagnostics.
        Self.log.debug("""
            queue: [\(queue.activities.map(\.id.kind.rawValue)
                .joined(separator: ", "), privacy: .public)] \
            sources: \(queue.activities.map(\.id.source)
                .joined(separator: ", "), privacy: .private(mask: .hash))
            """)
    }

    private func syncPresentation(_ queue: ActivityQueue) {
        // A peek draws the copy of the card taken when it arrived, and nothing
        // refreshed it — so anything that changes while the peek is on screen
        // stood still for its whole two seconds and then jumped. A countdown
        // started from the notch showed the same second three times before it
        // began to move, which reads as the timer not having started.
        //
        // The snapshot is kept when the card has left the queue: some peeks
        // are built locally and were never on it.
        if let peeked = presentation.peeked,
           let live = queue.activities.first(where: { $0.id == peeked.id }) {
            presentation.peeked = live
        }
        presentation.selected = queue.selected
        presentation.companion = queue.companion
        presentation.nowPlaying = queue.activities.first { $0.id.kind == .nowPlaying }
        // The satellite's standing tenants: the running timer session and the
        // live recording indicator, read straight off the queue every sync so
        // the seat empties the moment either retracts.
        presentation.timerSession = queue.activities.first {
            $0.id.kind == .timer && $0.id.source == "session"
        }
        presentation.privacyActive = queue.activities.first { $0.id.kind == .privacy }
        // Only dictation, not every recording: an app listening to you during
        // an hour-long call must not hold the island open for the hour, while
        // dictation is seconds of the user's own doing and is exactly what
        // they want confirmed for its duration.
        presentation.dictationActive = queue.activities.first { activity in
            guard case .privacy(let payload) = activity.payload else { return false }
            return payload.isSystemSpeech && payload.micActive && !payload.cameraActive
        }
        // The lingering card follows the queue while it lasts: the coordinator
        // decides *whether* a paused track may still be drawn, but which track
        // that is can change underneath it — skipping while paused is somebody
        // at the keyboard — and a held copy would show the wrong one.
        if presentation.lingeringNowPlaying != nil {
            presentation.lingeringNowPlaying = queue.activities.first { $0.id.kind == .nowPlaying }
        }
        // The close-event card, selection-independent: a meeting under an
        // hour away is companion material — the countdown rests in the
        // ears whichever card the user last read.
        presentation.closeEvent = queue.activities.first {
            guard case .event(let payload) = $0.payload else { return false }
            return payload.hasEvent && payload.startsIn <= 60 * 60 && payload.startsIn >= -60
        }
        presentation.count = queue.count
        presentation.selectedIndex = queue.selectedIndex ?? 0
    }

    private func syncExpiry(_ queue: ActivityQueue) {
        var live: Set<ActivityID> = []

        for activity in queue.activities {
            guard let expiresAfter = activity.expiresAfter else { continue }
            live.insert(activity.id)

            // Already scheduled against this exact creation time — leave it be.
            if scheduledFor[activity.id] == activity.createdAt { continue }

            let deadline = activity.createdAt + expiresAfter
            scheduledFor[activity.id] = activity.createdAt
            expiry.schedule(activity.id, after: deadline - now())
        }

        // Snapshot the keys: mutating the dictionary while iterating its own
        // lazy `keys` view is a trap waiting to be sprung.
        for id in Array(scheduledFor.keys) where !live.contains(id) {
            expiry.cancel(id)
            scheduledFor[id] = nil
        }
    }
}
