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

    /// Which run of this provider is current.
    ///
    /// A stream's termination handler stops the provider, and it reaches the
    /// main actor a turn after the stream ends. A provider stopped and started
    /// again inside that turn — what switching the media source does — was
    /// then stopped by the *old* stream's handler: the restarted run had its
    /// poll cancelled before it published anything, and media updates simply
    /// ceased until the next relaunch. Every piece of work that outlives a
    /// turn carries the run it belongs to and gives up when that run is over.
    private var run = 0

    /// How many reads this run has begun, and the number of the newest one
    /// whose answer reached the card.
    ///
    /// Three paths read the source and they overlap by design: the steady
    /// poll, the burst after a transport press, and the immediate refresh. A
    /// read is an `osascript` away, so the answers come back out of order —
    /// and a slow one landing after a fresh one put the previous track and
    /// play state back on screen, visibly undoing the button the user had
    /// just pressed.
    private var reads = 0
    private var publishedRead = 0

    /// A read in progress: the run that asked for it, and its place in that
    /// run's order.
    private struct Read {
        var run: Int
        var number: Int
    }

    private func beginRead() -> Read {
        reads += 1
        return Read(run: run, number: reads)
    }

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

    /// The cover key of the card on screen — the item, and which cover it is
    /// carrying — exactly as the artwork cache files it.
    ///
    /// Separate from `lastTrackKey`, which is a pause-clock identity (the
    /// player *and* the track) and so never equalled a bare key. A finished
    /// cover fetch compared itself against that one and always lost, which is
    /// why artwork landed in the cache and the card went on showing the
    /// placeholder until some later poll happened to redraw it.
    private var shownCoverKey: String?

    /// The last native snapshot we published while it was playing, and when.
    ///
    /// Held so a web page the user has hidden cannot evict the music. The
    /// system has one now-playing slot; a browser taking it does not mean
    /// Spotify stopped, and with web media hidden the page is not published —
    /// so without this the card simply disappeared and the user was left with
    /// nothing while the music played on.
    private var heldNative: (snapshot: NowPlayingSnapshot, at: TimeInterval)?

    /// How long a native player keeps its card while the system is naming a
    /// page instead.
    ///
    /// Bounded on purpose: once the page holds the slot there is nothing left
    /// to confirm the player with, so this is uncertainty rather than
    /// knowledge. A minute is long enough to cover a browser handing its slot
    /// around between tabs, and short enough that a player genuinely stopped
    /// does not leave a card sitting there. A track whose length is known
    /// expires earlier, when it would have ended.
    static let nativeHoldWithoutSighting: TimeInterval = 60

    /// What the source last reported, whether or not it earned a card.
    ///
    /// Kept so a preference change can be answered from memory. Re-reading
    /// the source would be a second or more of osascript for an answer we
    /// already have, and the question a switch asks is not "what is playing"
    /// but "what is this allowed to do" — see `reconsider()`.
    private var lastSnapshot: NowPlayingSnapshot?

    /// Whether video may hold the ears. Read fresh on every poll rather than
    /// captured, so turning the toggle off clears the compact view that is up.
    private let showsVideo: () -> Bool

    /// Whether a bundle identifier belongs to an application rather than to a
    /// web page.
    ///
    /// Injected because the honest answer needs the system: `MediaOwner`
    /// knows the browsers we listed, and `BrowserCatalogue` knows the ones
    /// LaunchServices has registered for `https`, which is all of them. The
    /// default is the pure reading, for tests and for a provider built
    /// without a system to ask.
    private let ownerIsApp: @MainActor (String) -> Bool

    /// Whether a web page's media may have a card, the ears, or neither.
    /// Read fresh on every poll for the same reason as `showsVideo`: turning
    /// either switch takes effect on the next tick, with no relaunch and no
    /// waiting for the track to change.
    private let webMedia: () -> WebMediaPolicy

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
    ///
    /// Browser media answers to its own switch and not to the general video
    /// one. Two reasons: the specific preference should win over the general
    /// one, and the general one cannot be applied honestly to a browser
    /// anyway — a page reports no media type, so "video" there is a guess
    /// made from the runtime (`MediaKind.resolve`). Leaving both in force
    /// made "Show web media in the compact view" a switch that did nothing,
    /// which is worse than either rule on its own.
    static func showsInCompact(
        _ snapshot: NowPlayingSnapshot,
        showsVideo: Bool,
        webMedia: WebMediaPolicy = .hidden,
        ownerIsApp: Bool? = nil
    ) -> Bool {
        // A website's media can have a card and still be kept out of the
        // ears: the compact view is the part that sits there uninvited, where
        // a card only appears when someone goes looking for it. Which of the
        // two a site gets is the user's rule for it.
        let isApp = ownerIsApp ?? MediaOwner.isOpenableApp(bundleID: snapshot.appBundleID)
        guard webMedia.allowsCompact(ownerIsApp: isApp)
        else { return false }
        // Said yes to browser media in the ears: that is the answer. The
        // length floor below still applies, and refuses nothing a card was
        // granted to — `shouldShow` holds video to the same two minutes.
        guard isApp else {
            return snapshot.isLive || snapshot.duration >= MediaKind.longFormDuration
        }
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
        webMedia: @escaping () -> WebMediaPolicy = { .hidden },
        ownerIsApp: @escaping @MainActor (String) -> Bool = {
            MediaOwner.isOpenableApp(bundleID: $0)
        },
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.source = source
        self.showsVideo = showsVideo
        self.webMedia = webMedia
        self.ownerIsApp = ownerIsApp
        self.playbackWatcher = playbackWatcher
        self.artwork = artwork
        self.playingInterval = playingInterval
        self.idleInterval = idleInterval
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        run += 1
        let token = run
        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop(run: token) }
            }
            self.task = Task { @MainActor [weak self] in
                await self?.poll(run: token)
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
        let read = beginRead()
        let snapshot = await source.snapshot()
        publish(snapshot, from: read)
    }

    /// The user pressed something. Told to the source before the re-read, so a
    /// source that resists track changes knows this one was asked for.
    public func expectChange() {
        source.expectChange()
        // A press is the one unambiguous sign that somebody is at the
        // keyboard, so whatever was retired for sitting paused is back in
        // play. A transport that could not bring a card back would read as a
        // transport that does nothing.
        pauses.userAsked()
        refreshSoon()
    }

    /// Re-decides what the current player may do, now.
    ///
    /// Called when a media preference changes. Turning web cards off retracts
    /// the page's card on the spot rather than at the next track change;
    /// turning them on puts it up without a relaunch; turning off only the
    /// compact switch republishes the same card with the ears released.
    public func reconsider() {
        guard continuation != nil else { return }
        publish(lastSnapshot, from: beginRead())
    }

    public func refreshSoon() {
        // Nothing to refresh into. The watcher and the source's own notifier
        // are unhooked by `stop`, but the shell can still call this through
        // `expectChange` after the provider has gone, and a stopped provider
        // must not start spawning reads again.
        guard continuation != nil else { return }
        let token = run
        boostTask?.cancel()
        boostTask = Task { @MainActor [weak self] in
            // Cumulative ~120ms, ~380ms, ~880ms — brackets how long Music and
            // Spotify take to reflect a playpause over their scripting bridge.
            for delayMs in [120, 260, 500] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard let self, !Task.isCancelled, self.run == token else { return }
                let read = self.beginRead()
                let snapshot = await self.source.snapshot()
                guard !Task.isCancelled else { return }
                self.publish(snapshot, from: read)
            }
        }
    }

    public func stop() { stop(run: run) }

    /// Stops the run that asked for it.
    ///
    /// The stream's termination handler arrives a turn late, by which time the
    /// provider may already have been started again — and the run it is
    /// talking about is not the one now going.
    private func stop(run token: Int) {
        guard token == run else { return }
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
        shownCoverKey = nil
        lastSnapshot = nil
        heldNative = nil
    }

    /// The native card to keep while a hidden page holds the system's slot,
    /// with its position moved forward — or nil once holding it stops being
    /// honest.
    ///
    /// Expires at whichever comes first: the track running out, or
    /// `nativeHoldWithoutSighting` without any confirmation that the player is
    /// still going. Both are documented uncertainty rather than a guess that
    /// never ends.
    private func heldNativeCard(at now: TimeInterval) -> NowPlayingSnapshot? {
        guard let held = heldNative else { return nil }
        let elapsed = max(0, now - held.at)
        guard elapsed < Self.nativeHoldWithoutSighting else {
            heldNative = nil
            return nil
        }
        var moved = held.snapshot
        moved.elapsed = held.snapshot.elapsed + elapsed
        if moved.duration > 0, moved.elapsed >= moved.duration - 1 {
            // The track would have finished. Nothing here can say what is
            // playing now, so the card goes rather than lying.
            heldNative = nil
            return nil
        }
        return moved
    }

    private func poll(run token: Int) async {
        while !Task.isCancelled {
            let read = beginRead()
            let snapshot = await source.snapshot()
            // The provider may have been stopped — or stopped and started
            // again — during the (seconds-long) osascript wait. Publishing
            // then would plant a stale publishedID into the run that followed.
            guard continuation != nil, !Task.isCancelled, token == run else { return }
            publish(snapshot, from: read)

            let interval = self.interval(playing: snapshot?.isPlaying ?? false)
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return  // cancelled
            }
        }
    }

    /// Publishes an answer unless the provider has moved on since it was asked
    /// for.
    ///
    /// Two ways it can have. The run the read belongs to may be over — stopped,
    /// or stopped and started again — in which case this answer describes a
    /// provider that no longer exists. Or a later read may already have
    /// published, in which case this one is describing a past the card has left
    /// behind: letting it through is how a button press appeared to be undone a
    /// second after it was made.
    private func publish(_ snapshot: NowPlayingSnapshot?, from read: Read) {
        guard read.run == run, continuation != nil, read.number > publishedRead
        else { return }
        publishedRead = read.number
        publish(snapshot)
    }

    private func publish(_ reported: NowPlayingSnapshot?) {
        lastSnapshot = reported
        // A web page with cards switched off is refused here rather than
        // hidden in the view, so nothing downstream has to know the
        // difference: no activity means no card, no page dot, no selection,
        // nothing to hand to the ears and no island opening for it. Published
        // again, without a relaunch, the first time the switch is back on.
        let policy = webMedia()
        var snapshot = reported
        var refusedAsWebContent = false
        /// Whether what we are about to publish came from the source this poll,
        /// rather than being the native card we are holding on its behalf.
        var isReported = true
        if let reported, !policy.allowsCard(ownerIsApp: ownerIsApp(reported.appBundleID)) {
            // Hidden, so it gets no card — but it does not get to take the
            // music's card away either. The player that was playing keeps it
            // while that is still credible; see `heldNative`.
            if let held = heldNativeCard(at: now()) {
                snapshot = held
                isReported = false
            } else {
                snapshot = nil
                refusedAsWebContent = true
            }
        }
        let isApp = snapshot.map { ownerIsApp($0.appBundleID) } ?? false
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
            shownCoverKey = nil
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
            // Retired already, and nothing since has said otherwise. This
            // reading is the same paused track it has been all along, so it
            // does not buy its card back: clearing the clock on retirement
            // used to leave the very next poll with nothing to measure, so it
            // started a fresh quarter of an hour and put the card the user had
            // just watched expire straight back on screen.
            guard !pauses.isRetired(key) else {
                if let publishedID {
                    continuation?.yield(.retract(publishedID))
                    self.publishedID = nil
                }
                lastTrackKey = nil
                shownCoverKey = nil
                return
            }
            // Three cases, and they are not interchangeable: the same track
            // still paused (the clock already running), a different track
            // (its own clock, from its own memory or from now), and this same
            // track coming back after something else held the slot — which
            // reads as "different" here, because the last key was cleared
            // when the card went away, and is exactly the case the memory is
            // for.
            let startedPausing = pauses.pausedSince(
                key,
                continuing: lastTrackKey == key,
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
                lastTrackKey = nil
                shownCoverKey = nil
                return
            }
        }

        if DebugSwitches.tracing("media") {
            Self.log.notice("media: \(snapshot.appBundleID, privacy: .public) playing=\(snapshot.isPlaying, privacy: .public) elapsed=\(snapshot.elapsed, format: .fixed(precision: 1), privacy: .public) title=\(snapshot.title, privacy: .public)")
        }

        if isApp, isReported {
            // The source is naming a player: this is knowledge, and it
            // replaces whatever was being held.
            //
            // Only a *reported* snapshot may do this. Storing the substituted
            // one made every hidden-page poll look like a fresh sighting, so
            // the sixty seconds restarted a second at a time and a live stream
            // could have been held for ever — the one thing the bound exists
            // to prevent.
            heldNative = snapshot.isPlaying ? (snapshot, now()) : nil
        }

        let id = ActivityID(kind: .nowPlaying, source: snapshot.appBundleID)

        // A different player took over — retract the old card rather than
        // leaving two on screen.
        if let publishedID, publishedID != id {
            continuation?.yield(.retract(publishedID))
        }
        if lastTrackKey != Self.pauseKey(snapshot) {
            // Skipping while paused is somebody at the keyboard — a *new*
            // track, freshly paused, which starts its own clock. But the card
            // coming back after something else held the slot is the same
            // track as before, and `lastTrackKey` was cleared when it went;
            // dating that as a new pause is what let an old track live for
            // ever, one interruption at a time.
            lastTrackKey = Self.pauseKey(snapshot)
        }
        publishedID = id
        shownCoverKey = snapshot.coverKey

        // The adapter delivers artwork as bytes (there is no URL for a
        // browser tab); seed the cache from them so adapter-only players get
        // real covers instead of the placeholder forever.
        //
        // Filed under the *cover* key rather than the track key. Keyed on the
        // song alone, a revised cover for a song already in the cache found
        // the old image sitting there and stopped — the better art was handed
        // over, ignored, and the card kept the first one for the length of the
        // track.
        let coverKey = snapshot.coverKey
        var cached = artwork.cached(for: coverKey)
        if cached == nil, let data = snapshot.artworkData {
            cached = artwork.load(key: coverKey, data: data)
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
                itemKey: snapshot.trackKey,
                artworkKey: coverKey,
                artworkData: cached?.data,
                kind: snapshot.kind,
                showsInCompact: Self.showsInCompact(
                    snapshot, showsVideo: showsVideo(), webMedia: policy, ownerIsApp: isApp
                ),
                isLive: snapshot.isLive,
                ownerIsApp: isApp
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
           !artwork.hasFailed(for: coverKey) {
            let key = coverKey
            // A fetch already running for *this* track is left alone. The card
            // publishes every second while the cover downloads, and cancelling
            // on each of those killed the download a second in — then the
            // loader latched the cancellation as a failure and refused to try
            // again for ninety seconds. Only a different track cancels.
            if artworkFetchKey != key {
                artworkFetch?.cancel()
                artworkFetchKey = key
                let token = run
                artworkFetch = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let loaded = await self.artwork.load(key: key, url: url)
                    guard !Task.isCancelled, self.run == token else { return }
                    if self.artworkFetchKey == key { self.artworkFetchKey = nil }
                    guard loaded != nil, self.continuation != nil else { return }
                    // Still the cover the card is waiting for? A skip during
                    // the fetch has already published its own card, and that
                    // one owns the screen. Compared against the key the cover
                    // is filed under: `lastTrackKey` is a pause-clock identity
                    // — the player and the track together — so this test could
                    // never pass, and a cover that arrived while a track sat
                    // paused waited in the cache for a poll minutes away.
                    guard self.shownCoverKey == key else { return }
                    await self.refreshNow()
                }
            }
        }
    }
}
