import Foundation
import LedgeCore
import LedgeSystem
import os

/// Turns a `NowPlayingSource` into activities.
///
/// Polls rather than subscribes, because AppleScript offers no change
/// notification. The interval follows the state: often while playing, so the
/// scrub bar tracks; rarely when paused or idle, so an unused machine is not
/// spawning a subprocess every second forever.
@MainActor
public final class NowPlayingProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "nowplaying")

    public let identifier = "nowplaying"

    private let source: any NowPlayingSource
    private let artwork: ArtworkLoader
    /// Wakes the slow poll the moment a player announces a change, so pressing
    /// play does not wait out the idle interval.
    private let playbackWatcher: PlaybackChangeWatcher?
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var task: Task<Void, Never>?
    private var boostTask: Task<Void, Never>?

    /// The cover being fetched for the track on screen. Cancelled when another
    /// track takes its place, so a slow fetch for a song nobody is listening
    /// to any more cannot republish over the one that is.
    private var artworkFetch: Task<Void, Never>?

    /// The track whose cover is being fetched, so a republish of the same
    /// track does not cancel its own download.
    private var artworkFetchKey: String?

    private let playingInterval: TimeInterval
    private let idleInterval: TimeInterval

    /// The resting beat when the source announces its own changes.
    ///
    /// A poll exists to notice what nothing told us about. When the adapter is
    /// in play it tells us — a play, a pause, a track, a player — so asking
    /// every four seconds was four wake-ups a minute spent re-reading a cache
    /// that had not changed. This is the backstop for the day a notification
    /// is missed, not the mechanism.
    static let pushedIdleInterval: TimeInterval = 15.0

    /// Whether the source pushes. Read once at start, since it is a property
    /// of which source was chosen, not of the moment.
    private var sourcePushes = false

    /// How long to wait before looking again.
    private func interval(playing: Bool) -> TimeInterval {
        if playing { return playingInterval }
        return sourcePushes ? max(idleInterval, Self.pushedIdleInterval) : idleInterval
    }
    private let now: () -> TimeInterval

    /// The id this provider owns. Retained so the activity can be retracted when
    /// playback stops, even after the snapshot that named it is gone.
    private var publishedID: ActivityID?

    /// How long a paused track keeps its card in the cycle.
    ///
    /// A player left paused is not news, but it is not nothing either: coming
    /// back within the half hour and finding the track still there is the
    /// point of the card. Coming back the next morning to a track you stopped
    /// at noon is clutter. (Distinct from the *ears*, which paused music
    /// leaves after the companion linger — a minute by default.)
    /// A quarter of an hour. Long enough that a pause to take a call still
    /// leaves the track where you left it, short enough that this morning's
    /// album is not still in the cycle at lunch.
    static let pausedCardLifetime: TimeInterval = 15 * 60

    /// When playback last stopped, or nil while something is playing. The card
    /// is retracted once this is older than `pausedCardLifetime`.
    /// When each paused track was paused. See `PauseClock` — the rule, and
    /// the interruption it survives, live there.
    private var pauses = PauseClock()

    /// The player and the track — the same thing across republishes, unlike
    /// the activity, which is rebuilt each time.
    private static func pauseKey(_ snapshot: NowPlayingSnapshot) -> String {
        "\(snapshot.appBundleID)|\(snapshot.trackKey)"
    }

    /// The track the card last showed, so a skip made while paused reads as
    /// somebody at the keyboard rather than more idle time.
    private var lastTrackKey: String?

    /// Whether video may hold the ears. Read fresh on every poll rather than
    /// captured, so turning the toggle off clears the compact view that is up.
    private let showsVideo: () -> Bool

    /// Whether only an application's own media may rest in the compact view —
    /// see `Prefs.appMediaOnly`.
    private let appsOnly: () -> Bool

    /// Whether a web page's media is refused a card as well as the ears — see
    /// `Prefs.hideWebMediaCard`. Only consulted when `appsOnly` is on, because
    /// hiding the card of something that is welcome in the ears is not a state
    /// anyone asked for.
    private let hidesWebCard: () -> Bool

    /// Whether the notch should carry this at all.
    ///
    /// Length alone, no preference involved. A minute is not enough time to
    /// read a card, let alone act on one — that is what keeps notification
    /// stings, autoplaying adverts and preview clips from flashing a scrub bar
    /// across the notch and leaving again. Video is held to the higher bar it
    /// would need for the compact view anyway: a ninety-second clip that
    /// cannot take the ears has no business taking a card either, since the
    /// only thing left to do with it is watch the notch draw it.
    ///
    /// Live streams report no duration at all and are let through — an unknown
    /// length is not a short one.
    static func shouldShow(_ snapshot: NowPlayingSnapshot) -> Bool {
        // Live has no duration to judge, and is never a clip.
        guard !snapshot.isLive else { return true }
        guard snapshot.duration > 0 else { return true }
        let floor = snapshot.kind == .video
            ? MediaKind.longFormDuration
            : MediaKind.shortestWorthShowing
        return snapshot.duration >= floor
    }

    /// Whether this may hold the ears, as opposed to merely having a card.
    ///
    /// Audio always may. Video may when it has been left switched on and runs
    /// long enough to be worth opening the island for — a two-minute floor,
    /// which a clip does not clear and an episode does without noticing. A
    /// live video stream reports no length and stays out of the ears, where a
    /// radio stream is let in: the one signal we have says nothing, so the
    /// quieter reading wins.
    static func showsInCompact(
        _ snapshot: NowPlayingSnapshot,
        showsVideo: Bool,
        appsOnly: Bool = false
    ) -> Bool {
        // A web page's media can be kept out of the ears while keeping its
        // card: the compact view is the part that sits there uninvited, and a
        // card only appears when someone goes looking for it.
        if appsOnly, !MediaOwner.isOpenableApp(bundleID: snapshot.appBundleID) { return false }
        guard snapshot.kind == .video else { return true }
        // A live broadcast is long-form by definition: it has no length to
        // measure against the two-minute floor, and the floor exists to keep
        // clips out, not matches.
        if snapshot.isLive { return showsVideo }
        return showsVideo && snapshot.duration >= MediaKind.longFormDuration
    }


    public init(
        source: any NowPlayingSource,
        artwork: ArtworkLoader,
        playingInterval: TimeInterval = 1.0,
        idleInterval: TimeInterval = 4.0,
        playbackWatcher: PlaybackChangeWatcher? = PlaybackChangeWatcher(),
        showsVideo: @escaping () -> Bool = { true },
        appsOnly: @escaping () -> Bool = { false },
        hidesWebCard: @escaping () -> Bool = { false },
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.showsVideo = showsVideo
        self.appsOnly = appsOnly
        self.hidesWebCard = hidesWebCard
        self.playbackWatcher = playbackWatcher
        self.artwork = artwork
        self.playingInterval = playingInterval
        self.idleInterval = idleInterval
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            self.task = Task { @MainActor [weak self] in
                await self?.poll()
            }
            // Same burst the transport buttons use: the players answer
            // AppleScript with their new state a moment after announcing it, so
            // a single immediate read would still catch the old one.
            self.playbackWatcher?.startWatching { [weak self] in self?.refreshSoon() }
            // Music and Spotify announce themselves through the watcher above.
            // Everything else — a video in a browser, above all — is only
            // known to the adapter, and waiting out the idle interval to
            // notice it made pressing play in Safari feel broken.
            if let publisher = self.source as? any NowPlayingChangePublishing {
                self.sourcePushes = true
                publisher.onChange = { [weak self] in self?.refreshSoon() }
            }
        }
    }

    /// Re-reads the player a few times in quick succession.
    ///
    /// The steady poll is 1s while playing and 4s while paused — far too slow to
    /// confirm a transport command the user just issued. After sending one, the
    /// shell calls this so the card's real state (play/pause icon, elapsed)
    /// catches up in a few hundred milliseconds instead of on the next tick.
    /// One snapshot, published straight away — the poll's own body without the
    /// waiting. Exposed so the paused-card lifetime can be driven against an
    /// injected clock instead of three quarters of an hour of real seconds.
    func refreshNow() async {
        let snapshot = await source.snapshot()
        guard continuation != nil else { return }
        publish(snapshot)
    }

    /// The user pressed something. Told to the source before the re-read, so a
    /// source that resists track changes knows this one was asked for.
    public func expectChange() {
        source.expectChange()
        refreshSoon()
    }

    public func refreshSoon() {
        boostTask?.cancel()
        boostTask = Task { @MainActor [weak self] in
            // Cumulative ~120ms, ~380ms, ~880ms — brackets how long Music and
            // Spotify take to reflect a playpause over their scripting bridge.
            for delayMs in [120, 260, 500] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard let self, !Task.isCancelled else { return }
                let snapshot = await self.source.snapshot()
                guard !Task.isCancelled else { return }
                self.publish(snapshot)
            }
        }
    }

    public func stop() {
        playbackWatcher?.stopWatching()
        (source as? any NowPlayingChangePublishing)?.onChange = nil
        task?.cancel()
        task = nil
        boostTask?.cancel()
        boostTask = nil
        artworkFetch?.cancel()
        artworkFetch = nil
        artworkFetchKey = nil
        continuation?.finish()
        continuation = nil
        // A restarted provider must not believe it still owns a card the hub
        // has already taken down.
        publishedID = nil
        // The pause clock belongs to the run that started it: a provider
        // switched off and on again is the user asking for the card back.
        pauses.cardWentAway()
        lastTrackKey = nil
    }

    private func poll() async {
        while !Task.isCancelled {
            let snapshot = await source.snapshot()
            // The provider may have been stopped during the (seconds-long)
            // osascript wait; publishing then would plant a stale publishedID
            // into the next start of this same instance.
            guard continuation != nil, !Task.isCancelled else { return }
            publish(snapshot)

            let interval = self.interval(playing: snapshot?.isPlaying ?? false)
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return  // cancelled
            }
        }
    }

    private func publish(_ snapshot: NowPlayingSnapshot?) {
        // Refused outright only when both switches are on: keeping a page out
        // of the ears is one wish, and refusing it a card is a second and
        // larger one. Refused here rather than hidden in the view, so nothing
        // downstream has to know the difference — the island does not open for
        // it either.
        let refusedAsWebContent = appsOnly() && hidesWebCard()
            && snapshot.map { !MediaOwner.isOpenableApp(bundleID: $0.appBundleID) } ?? false
        if DebugSwitches.tracing("media"), snapshot == nil {
            Self.log.notice("media: source reported nothing")
        }
        guard let snapshot, Self.shouldShow(snapshot), !refusedAsWebContent else {
            // Nothing to show: take the card away, but only if we put one up.
            // The paused clock and the track key go with it, so a refused
            // player leaves no state behind to confuse the next one.
            if let publishedID {
                continuation?.yield(.retract(publishedID))
                self.publishedID = nil
            }
            pauses.cardWentAway()
            lastTrackKey = nil
            return
        }

        // A paused track that has sat untouched long enough stops being worth
        // a card. Anything that means the user came back — playing again, or a
        // different track — clears the clock.
        if snapshot.isPlaying {
            pauses.playing(Self.pauseKey(snapshot))
        } else {
            // Kept against the track, not against this run of the card.
            //
            // The card is retracted whenever something else takes the system's
            // now-playing slot — a browser clip, say — and republished when
            // that goes away again. Each of those republishes used to start
            // the fifteen minutes over, so a track paused in the morning could
            // still be in the cycle at lunch as long as something kept
            // interrupting it. The pause happened once; it is dated once.
            let key = Self.pauseKey(snapshot)
            // Three cases, and they are not interchangeable: the same track
            // still paused (the clock already running), a different track
            // (its own clock, from its own memory or from now), and this same
            // track coming back after something else held the slot — which
            // reads as "different" here, because the last key was cleared
            // when the card went away, and is exactly the case the memory is
            // for.
            let startedPausing = pauses.pausedSince(
                key,
                continuing: lastTrackKey == snapshot.trackKey,
                now: now()
            )
            if now() - startedPausing >= Self.pausedCardLifetime {
                if let publishedID {
                    Self.log.notice("paused for \(Int(Self.pausedCardLifetime / 60), privacy: .public) minutes — retiring the card")
                    continuation?.yield(.retract(publishedID))
                    self.publishedID = nil
                }
                // Retired: the next time this track is seen paused it starts
                // its own fifteen minutes, because by then it will have been
                // played again to get there.
                pauses.retired(Self.pauseKey(snapshot))
                return
            }
        }

        if DebugSwitches.tracing("media") {
            Self.log.notice("media: \(snapshot.appBundleID, privacy: .public) playing=\(snapshot.isPlaying, privacy: .public) elapsed=\(snapshot.elapsed, format: .fixed(precision: 1), privacy: .public) title=\(snapshot.title, privacy: .public)")
        }

        let id = ActivityID(kind: .nowPlaying, source: snapshot.appBundleID)

        // A different player took over — retract the old card rather than
        // leaving two on screen.
        if let publishedID, publishedID != id {
            continuation?.yield(.retract(publishedID))
        }
        if lastTrackKey != snapshot.trackKey {
            // Skipping while paused is somebody at the keyboard — a *new*
            // track, freshly paused, which starts its own clock. But the card
            // coming back after something else held the slot is the same
            // track as before, and `lastTrackKey` was cleared when it went;
            // dating that as a new pause is what let an old track live for
            // ever, one interruption at a time.
            lastTrackKey = snapshot.trackKey
        }
        publishedID = id

        // The adapter delivers artwork as bytes (there is no URL for a
        // browser tab); seed the cache from them so adapter-only players get
        // real covers instead of the placeholder forever.
        var cached = artwork.cached(for: snapshot.trackKey)
        if cached == nil, let data = snapshot.artworkData {
            cached = artwork.load(key: snapshot.trackKey, data: data)
        }

        continuation?.yield(.publish(Activity(
            id: id,
            createdAt: now(),
            payload: .nowPlaying(NowPlayingPayload(
                title: snapshot.title,
                artist: snapshot.artist,
                album: snapshot.album,
                isPlaying: snapshot.isPlaying,
                elapsed: snapshot.elapsed,
                duration: snapshot.duration,
                sourceName: snapshot.appName,
                accent: cached?.accent ?? .neutral,
                artworkKey: snapshot.trackKey,
                artworkData: cached?.data,
                kind: snapshot.kind,
                showsInCompact: Self.showsInCompact(
                    snapshot, showsVideo: showsVideo(), appsOnly: appsOnly()
                ),
                isLive: snapshot.isLive,
                ownerIsApp: MediaOwner.isOpenableApp(bundleID: snapshot.appBundleID)
            ))
        )))

        // Fetch in the background — doing it inline would stall the card
        // behind a network request — and publish again the moment it lands.
        //
        // Waiting for the next poll to notice the cache was up to a second of
        // placeholder on a card whose title and artist were already right,
        // which reads as the artwork being slow when it had already arrived.
        // The republish is the same shape as a poll tick, which this card gets
        // every second anyway, so nothing downstream sees anything unusual.
        if cached == nil,
           let url = snapshot.artworkURL,
           !artwork.hasFailed(for: snapshot.trackKey) {
            let key = snapshot.trackKey
            // A fetch already running for *this* track is left alone. The card
            // publishes every second while the cover downloads, and cancelling
            // on each of those killed the download a second in — then the
            // loader latched the cancellation as a failure and refused to try
            // again for ninety seconds. Only a different track cancels.
            if artworkFetchKey != key {
                artworkFetch?.cancel()
                artworkFetchKey = key
                artworkFetch = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let loaded = await self.artwork.load(key: key, url: url)
                    guard !Task.isCancelled else { return }
                    if self.artworkFetchKey == key { self.artworkFetchKey = nil }
                    guard loaded != nil, self.continuation != nil else { return }
                    // Still the same track? A skip during the fetch has already
                    // published its own card, and that one owns the screen.
                    guard self.lastTrackKey == key else { return }
                    await self.refreshNow()
                }
            }
        }
    }
}
