import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

/// Answers whatever the test last set, so nothing but the clock moves.
@MainActor
private final class ScriptedSource: NowPlayingSource {
    let identifier = "scripted"
    var isAvailable = true
    var current: NowPlayingSnapshot?
    /// How many times the player has actually been asked.
    var reads = 0
    func snapshot() async -> NowPlayingSnapshot? {
        reads += 1
        return current
    }
}

/// - Parameter host: the website, for a browser fixture. Left nil for a
///   native player — and for the browser case where the origin could not be
///   established, which is its own test.
private func media(
    _ title: String,
    playing: Bool = true,
    duration: TimeInterval = 240,
    kind: MediaKind = .audio,
    bundleID: String = "com.spotify.client",
    elapsed: TimeInterval = 0,
    host: String? = "youtube.com"
) -> NowPlayingSnapshot {
    let isBrowser = !MediaOwner.isOpenableApp(bundleID: bundleID)
    return NowPlayingSnapshot(
        title: title, artist: "Artist", isPlaying: playing,
        elapsed: elapsed, duration: duration,
        appName: "Player", appBundleID: bundleID, trackKey: title, kind: kind,
        // Only a browser has a website — and only blob evidence can match a
        // rule, which is what a real media-source page produces.
        origin: isBrowser
            ? MediaOriginEvidence.from(host: host, isBlob: true)
            : .none
    )
}

/// A policy allowing one website, which is what "shown" means now.
private func allowing(
    _ host: String = "youtube.com",
    _ appearance: WebsiteAppearance = .cardAndCompact
) -> WebsitePolicy {
    WebsitePolicy(rules: [WebsiteRule(host: WebsiteHost(host)!, appearance: appearance)])
}

@Suite("Telling watching from listening")
struct MediaKindResolutionTests {

    @Test("What the source says wins over everything else")
    func reportedTypeWins() {
        // A two-hour concert film in the TV app is video however long it runs,
        // and a two-hour DJ set in Music is audio for the same reason.
        #expect(MediaKind.resolve(reported: .audio, bundleID: "com.apple.TV", duration: 7200) == .audio)
        #expect(MediaKind.resolve(reported: .video, bundleID: "com.spotify.client", duration: 180) == .video)
    }

    @Test("Spotify stays audio however long the track")
    func spotifyIsNeverVideo() {
        #expect(MediaKind.resolve(reported: .audio, bundleID: "com.spotify.client", duration: 3600) == .audio)
        #expect(MediaKind.resolve(reported: nil, bundleID: "com.spotify.client", duration: 3600) == .audio)
    }

    @Test("A player that only ever does one of the two is taken at its name")
    func knownAppsDecide() {
        #expect(MediaKind.resolve(reported: nil, bundleID: "com.apple.TV", duration: 0) == .video)
        #expect(MediaKind.resolve(reported: nil, bundleID: "com.colliderli.iina", duration: 90) == .video)
        #expect(MediaKind.resolve(reported: nil, bundleID: "com.apple.Music", duration: 5400) == .audio)
    }

    /// The case the whole ladder exists for: measured on macOS 26, a video
    /// playing in a browser reports no media type, no artwork and no album —
    /// only a title, a channel and a runtime. Length is the one signal left.
    @Test("A browser, which says nothing, is judged by the runtime")
    func browsersFallBackToDuration() {
        let chrome = "com.google.Chrome"
        #expect(MediaKind.resolve(reported: nil, bundleID: chrome, duration: 40) == .audio)
        #expect(MediaKind.resolve(reported: nil, bundleID: chrome, duration: 42 * 60) == .video)
        // A live stream reports nothing at all; radio is the likelier reading.
        #expect(MediaKind.resolve(reported: nil, bundleID: chrome, duration: 0) == .audio)
    }

    @Test("Anything under a minute is not worth showing; an unknown length is")
    func shortMedia() {
        #expect(MediaKind.isWorthShowing(duration: 3) == false)
        #expect(MediaKind.isWorthShowing(duration: 59) == false)
        #expect(MediaKind.isWorthShowing(duration: 240))
        #expect(MediaKind.isWorthShowing(duration: 0), "a live stream reports no length")
    }
}

@Suite("What the notch agrees to carry")
@MainActor
struct MediaGateTests {

    private func collect(_ provider: NowPlayingProvider, while body: () async -> Void) async -> [ProviderEvent] {
        let stream = provider.start()
        await body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func provider(
        _ source: ScriptedSource,
        showsVideo: @escaping () -> Bool = { true }
    ) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60,
            playbackWatcher: nil, showsVideo: showsVideo
        )
    }

    @Test("Only length decides whether there is a card at all")
    func cardRule() {
        #expect(NowPlayingProvider.shouldShow(media("Track")))
        #expect(NowPlayingProvider.shouldShow(media("Sting", duration: 4)) == false)
        #expect(NowPlayingProvider.shouldShow(media("Film", duration: 9000, kind: .video)))
        #expect(
            NowPlayingProvider.shouldShow(media("Radio", duration: 0)),
            "an unknown length is not a short one"
        )
    }

    /// Audio and video get different floors. A ninety-second track is a track;
    /// a ninety-second video is a clip, and a clip that cannot take the ears
    /// has nothing to offer as a card either.
    @Test("Video under two minutes gets no card at all")
    func shortVideoIsNotShown() {
        #expect(NowPlayingProvider.shouldShow(media("Clip", duration: 90, kind: .video)) == false)
        #expect(NowPlayingProvider.shouldShow(media("Interlude", duration: 90)))
        #expect(NowPlayingProvider.shouldShow(media("Episode", duration: 121, kind: .video)))
    }

    @Test("Who may hold the ears")
    func compactRule() {
        let film = media("Dune", duration: 9000, kind: .video)
        #expect(NowPlayingProvider.showsInCompact(film, showsVideo: true))
        #expect(NowPlayingProvider.showsInCompact(film, showsVideo: false) == false)
        #expect(
            NowPlayingProvider.showsInCompact(media("Clip", duration: 90, kind: .video), showsVideo: true) == false,
            "a ninety-second clip is over before the island finishes opening — and gets no card either"
        )
        #expect(
            NowPlayingProvider.showsInCompact(media("Track", duration: 90), showsVideo: false),
            "the toggle is about video; music is never turned out of the ears"
        )
    }

    @Test("A clip too short to read never reaches the notch")
    func shortMediaNeverPublishes() async {
        let source = ScriptedSource()
        let provider = provider(source)
        source.current = media("Advert", duration: 15)
        let events = await collect(provider) { await provider.refreshNow() }
        #expect(events.isEmpty, "nothing was published, so nothing had to be taken away")
    }

    @Test("Turning video off keeps the card and empties the ears")
    func togglingOffLeavesTheCard() async {
        var allowed = true
        let source = ScriptedSource()
        let provider = provider(source, showsVideo: { allowed })

        source.current = media("Dune", duration: 9000, kind: .video)
        let events = await collect(provider) {
            await provider.refreshNow()
            allowed = false
            await provider.refreshNow()
        }
        let published = events.compactMap { event -> Activity? in
            if case .publish(let activity) = event { return activity } else { return nil }
        }
        #expect(published.count == 2, "the card stays; only its place in the ears goes")
        #expect(published.first?.restsInEars == true)
        #expect(published.last?.restsInEars == false)
        #expect(!events.contains { if case .retract = $0 { return true } else { return false } })
    }

    /// The sequence that would otherwise strand a card: a clip too short to
    /// show is refused, and the music that follows must arrive clean rather
    /// than inheriting the clip's paused clock or track key.
    @Test("A refused player leaves nothing behind for the next one")
    func refusalLeavesNoState() async {
        let source = ScriptedSource()
        let provider = provider(source)

        source.current = media("Advert", playing: false, duration: 15)
        let events = await collect(provider) {
            await provider.refreshNow()
            source.current = media("Bad Habit")
            await provider.refreshNow()
        }
        let publishes = events.compactMap { event -> Activity? in
            if case .publish(let activity) = event { return activity } else { return nil }
        }
        #expect(publishes.count == 1)
        if case .nowPlaying(let payload) = publishes.first?.payload {
            #expect(payload.title == "Bad Habit")
        } else {
            Issue.record("the music should have been published")
        }
    }
}

@Suite("What the ears refuse to draw, the island does not open for")
struct CompactEligibilityTests {

    private func card(showsInCompact: Bool, playing: Bool = true) -> Activity {
        Activity(
            id: ActivityID(kind: .nowPlaying, source: "player"), createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(
                title: "Dune", artist: "Villeneuve", isPlaying: playing,
                kind: .video, showsInCompact: showsInCompact
            ))
        )
    }

    @Test("Video the compact view will draw rests exactly as music does")
    func drawableVideoRests() {
        #expect(card(showsInCompact: true).restsInEars)
        #expect(card(showsInCompact: false).restsInEars == false)
    }

    @Test("Nothing announces itself into ears that would not draw it")
    func silentWhenNotDrawable() {
        #expect(card(showsInCompact: true).isWorthAnnouncing)
        #expect(card(showsInCompact: false).isWorthAnnouncing == false)
    }

    /// Belt and braces: the resting chain refuses it wherever it is offered,
    /// so a caller that computes its own candidate cannot let one through —
    /// which is exactly how the island came to open onto two empty ears.
    @Test("The resting chain turns it away at every seat it could take")
    func restingChainRefuses() {
        let video = card(showsInCompact: false)
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: video, runningTimer: nil,
            closeEvent: nil, nowPlaying: nil, selected: nil
        ) == nil)
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: nil, nowPlaying: video, selected: nil
        ) == nil)
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: nil, nowPlaying: nil, selected: video
        ) == nil)
    }

    @Test("A running timer still rests while a film the ears refuse plays")
    func timerOutlivesVideo() {
        let timer = Activity(
            id: ActivityID(kind: .timer, source: "pomodoro"), createdAt: 0,
            payload: .timer(TimerPayload(label: "Focus", remaining: 300, total: 1500, isRunning: true))
        )
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: card(showsInCompact: false), runningTimer: timer,
            closeEvent: nil, nowPlaying: nil, selected: nil
        ) == timer)
    }
}

@Suite("Live has no end to count down to")
@MainActor
struct LiveMediaTests {

    private func live(
        _ kind: MediaKind,
        playing: Bool = true,
        bundleID: String = "com.apple.Safari"
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: "The match", artist: "A channel", isPlaying: playing,
            elapsed: 900, duration: 0,
            appName: "A player", appBundleID: bundleID,
            trackKey: "live", isLive: true, kind: kind,
            // A browser fixture has a website; `liveInApp` has none.
            origin: MediaOwner.isOpenableApp(bundleID: bundleID)
                ? .none : .blobOrigin(WebsiteHost("youtube.com")!)
        )
    }

    /// An app's own live video, for the general video switch — which is what
    /// that switch governs now that browser media answers to its own.
    private func liveInApp(_ kind: MediaKind) -> NowPlayingSnapshot {
        live(kind, bundleID: "com.apple.TV")
    }

    /// The two-minute floor exists to keep clips out, and a broadcast has no
    /// length to measure against it.
    @Test("A live broadcast reaches the compact view despite having no length")
    func liveVideoIsCompactWorthy() {
        #expect(NowPlayingProvider.showsInCompact(live(.video), showsVideo: true, webMedia: allowing()))
        #expect(NowPlayingProvider.shouldShow(live(.video)))
    }

    @Test("Turning video off still turns an app's live video off")
    func togglingStillApplies() {
        #expect(NowPlayingProvider.showsInCompact(liveInApp(.video), showsVideo: false) == false)
        #expect(NowPlayingProvider.showsInCompact(liveInApp(.video), showsVideo: true))
    }

    /// The specific switch wins over the general one. Leaving both in force
    /// made "Show web media in the compact view" a control that did nothing
    /// whenever video was off — and for a browser, "video" is a guess made
    /// from the runtime in the first place.
    @Test("Browser media in the ears does not also need the video switch")
    func webCompactIsAuthoritative() {
        #expect(NowPlayingProvider.showsInCompact(live(.video), showsVideo: false, webMedia: allowing()))
        #expect(
            NowPlayingProvider.showsInCompact(
                live(.video), showsVideo: true,
                webMedia: allowing("youtube.com", .card)
            ) == false,
            "and its own switch still decides"
        )
    }

    @Test("Live radio is audio and behaves as audio always has")
    func liveAudioUnaffected() {
        #expect(NowPlayingProvider.showsInCompact(live(.audio), showsVideo: false, webMedia: allowing()))
    }

    /// A duration of zero while playing is what a stream looks like when the
    /// source does not say. The system's own flag wins when it does.
    @Test("The payload carries it, and an older stored card does not")
    func payloadCarriesLive() throws {
        let payload = NowPlayingPayload(title: "x", artist: "y", isLive: true)
        #expect(payload.isLive)

        let json = Data(#"{"title":"x","artist":"y"}"#.utf8)
        #expect(try JSONDecoder().decode(NowPlayingPayload.self, from: json).isLive == false)
    }
}

/// A browser holds one now-playing slot for every tab and hands it around, so
/// what arrives from one is often not what anyone chose to play. Both
/// switches are off until somebody says otherwise, and these are the states
/// they make.
@Suite("Web media, by permission")
@MainActor
struct WebMediaGateTests {

    private func collect(_ provider: NowPlayingProvider, while body: () async -> Void) async -> [ProviderEvent] {
        let stream = provider.start()
        await body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func published(_ events: [ProviderEvent]) -> NowPlayingPayload? {
        for event in events.reversed() {
            if case .publish(let activity) = event, case .nowPlaying(let payload) = activity.payload {
                return payload
            }
        }
        return nil
    }

    private func retracted(_ events: [ProviderEvent]) -> Bool {
        events.contains { if case .retract = $0 { return true } else { return false } }
    }

    private func provider(
        _ source: ScriptedSource,
        webMedia: @escaping () -> WebsitePolicy,
        now: @escaping () -> TimeInterval = { 1_000 }
    ) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60,
            playbackWatcher: nil, webMedia: webMedia, now: now
        )
    }

    /// Nothing published is the whole of it: no card to cycle to, so no page
    /// dot, nothing selectable, nothing to hand the ears, and no island
    /// opening to announce it.
    @Test("Off and off: a page is not published at all", arguments: [
        "com.apple.Safari", "com.google.Chrome",
    ])
    func bothOffPublishesNothing(bundleID: String) async {
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: bundleID)
        let made = provider(source, webMedia: { .hidden })
        let events = await collect(made) { await made.refreshNow() }
        #expect(events.isEmpty, "\(bundleID) got no card, no compact view, no announcement")
    }

    @Test("Cards on, compact off: the card exists and the ears stay empty")
    func cardWithoutCompact() async {
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { allowing("youtube.com", .card) })
        let events = await collect(made) { await made.refreshNow() }
        #expect(published(events) != nil)
        #expect(published(events)?.showsInCompact == false)
    }

    @Test("Both on: a page's media is carried the way a player's is")
    func cardAndCompact() async {
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { allowing() })
        let events = await collect(made) { await made.refreshNow() }
        #expect(published(events)?.showsInCompact == true)
    }

    /// The invalid pair, which Settings cannot produce but a preference file
    /// can hold. It must behave as both off rather than as compact-only.
    @Test("Compact without cards publishes nothing")
    func compactWithoutCards() async {
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { WebsitePolicy.hidden })
        let events = await collect(made) { await made.refreshNow() }
        #expect(events.isEmpty)
    }

    @Test("An app's own media is untouched by either switch")
    func nativeMediaUnchanged() async {
        for policy in [WebsitePolicy.hidden, allowing()] {
            let source = ScriptedSource()
            source.current = media("A track", bundleID: "com.spotify.client")
            let made = provider(source, webMedia: { policy })
            let events = await collect(made) { await made.refreshNow() }
            #expect(published(events)?.title == "A track")
            #expect(published(events)?.showsInCompact == true)
        }
    }

    /// The card has to go while the same track keeps playing — waiting for the
    /// next track would leave a card up that the user has just forbidden.
    @Test("Switching cards off retracts the page's card there and then")
    func disablingCardsRetractsImmediately() async {
        var policy = allowing()
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { policy })
        var reads = 0
        let events = await collect(made) {
            await made.refreshNow()
            policy = .hidden
            reads = source.reads
            made.reconsider()
        }
        #expect(retracted(events), "the card is taken away without the track changing")
        #expect(source.reads == reads, "and without asking the player anything")
    }

    @Test("Switching only the compact switch off keeps the card")
    func disablingCompactKeepsTheCard() async {
        var policy = allowing()
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { policy })
        let events = await collect(made) {
            await made.refreshNow()
            policy = allowing("youtube.com", .card)
            made.reconsider()
        }
        let publishes = events.compactMap { event -> Activity? in
            if case .publish(let activity) = event { return activity } else { return nil }
        }
        #expect(publishes.count == 2)
        #expect(publishes.first?.restsInEars == true)
        #expect(publishes.last?.restsInEars == false)
        #expect(!retracted(events), "the card itself was never in question")
    }

    @Test("Switching cards on shows what is already playing, without a relaunch")
    func enablingPublishesWhatIsPlaying() async {
        var policy = WebsitePolicy.hidden
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { policy })
        let events = await collect(made) {
            await made.refreshNow()
            policy = allowing()
            made.reconsider()
        }
        #expect(published(events)?.title == "Some video")
        #expect(published(events)?.showsInCompact == true)
    }

    /// A browser taking the system's now-playing slot does not mean the music
    /// stopped — and with web media hidden the page is not published, so the
    /// card simply vanished and left the user with nothing while Spotify
    /// played on. The player keeps its card while that is still credible.
    @Test("A hidden page does not take the music's card away")
    func hiddenPageDoesNotEvictTheMusic() async {
        let source = ScriptedSource()
        source.current = media("A track", bundleID: "com.spotify.client")
        let made = provider(source, webMedia: { .hidden })
        let events = await collect(made) {
            await made.refreshNow()
            source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.google.Chrome")
            await made.refreshNow()
        }
        #expect(!retracted(events), "the music's card was taken away by a page nobody can see")
        #expect(published(events)?.title == "A track")
        #expect(published(events)?.showsInCompact == true, "and it keeps the ears")
    }

    /// The hold is bounded: once the page has the slot there is nothing left
    /// to confirm the player with, so after a minute without a sighting the
    /// card goes rather than sitting there for ever.
    @Test("The held card expires after a minute without a sighting")
    func heldCardExpires() async {
        var clock: TimeInterval = 1_000
        let source = ScriptedSource()
        source.current = media("A track", bundleID: "com.spotify.client")
        let made = provider(source, webMedia: { .hidden }, now: { clock })
        let events = await collect(made) {
            await made.refreshNow()
            source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.google.Chrome")
            clock += 10
            await made.refreshNow()
            clock += NowPlayingProvider.nativeHoldWithoutSighting
            await made.refreshNow()
        }
        #expect(retracted(events), "the card was held for ever")
    }

    /// And a track that would have finished takes its card with it, rather
    /// than the scrub bar running past the end of a song nobody can confirm.
    @Test("The held card goes when the track would have ended")
    func heldCardEndsWithTheTrack() async {
        var clock: TimeInterval = 1_000
        let source = ScriptedSource()
        // Long enough to earn a card at all — a minute is the floor — and
        // nearly over, so the track's end arrives before the minute of
        // uncertainty does.
        source.current = media(
            "A track", duration: 90, bundleID: "com.spotify.client", elapsed: 80
        )
        let made = provider(source, webMedia: { .hidden }, now: { clock })
        let events = await collect(made) {
            await made.refreshNow()
            source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.google.Chrome")
            // Past the end of the track, inside the minute's uncertainty: the
            // track running out is what retires the card here.
            clock += 15
            await made.refreshNow()
        }
        #expect(retracted(events))
    }

    /// With web media allowed, the page is welcome to the slot: nothing is
    /// held, and the card changes hands as it always did.
    @Test("An allowed page takes the slot normally")
    func allowedPageTakesTheSlot() async {
        let source = ScriptedSource()
        source.current = media("A track", bundleID: "com.spotify.client")
        let made = provider(source, webMedia: { allowing() })
        let events = await collect(made) {
            await made.refreshNow()
            source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.google.Chrome")
            await made.refreshNow()
        }
        #expect(retracted(events), "the player's card is withdrawn rather than left beside the page's")
        #expect(published(events)?.title == "Some video")
    }

    /// A paused player is not "still playing", so there is nothing to hold:
    /// the page is refused and the paused card goes, which is the behaviour
    /// the pause clock already describes.
    @Test("A paused player is not held against a hidden page")
    func pausedPlayerIsNotHeld() async {
        let source = ScriptedSource()
        source.current = media("A track", playing: false, bundleID: "com.spotify.client")
        let made = provider(source, webMedia: { .hidden })
        let events = await collect(made) {
            await made.refreshNow()
            source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.google.Chrome")
            await made.refreshNow()
        }
        #expect(retracted(events))
    }

    @Test("The compact rule reads the same way the provider does")
    func ruleMatchesProvider() {
        let page = media("Some video", bundleID: "com.apple.Safari")
        let player = media("A track", bundleID: "com.spotify.client")
        #expect(NowPlayingProvider.showsInCompact(page, showsVideo: true, webMedia: .hidden) == false)
        #expect(NowPlayingProvider.showsInCompact(
            page, showsVideo: true,
            webMedia: allowing("youtube.com", .card)
        ) == false)
        #expect(NowPlayingProvider.showsInCompact(page, showsVideo: true, webMedia: allowing()))
        #expect(NowPlayingProvider.showsInCompact(player, showsVideo: true, webMedia: .hidden))
    }

    /// A browser that says nothing about what it is playing is judged by
    /// length, so a long song streamed through a page is classified as video —
    /// see `MediaKind.resolve`. The switches are therefore about browser media
    /// as a whole, which is the conservative reading and the one the copy
    /// describes.
    @Test("Web audio is gated with web video, because the two cannot be told apart")
    func webAudioIsGatedToo() async {
        let source = ScriptedSource()
        source.current = media("A song", duration: 200, kind: .audio, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { .hidden })
        let events = await collect(made) { await made.refreshNow() }
        #expect(events.isEmpty)
    }
}

/// The hold that keeps a player's card while a hidden page has the system's
/// now-playing slot is bounded — and the bound has to be real. Storing the
/// substituted snapshot as though it were a fresh sighting restarted the clock
/// on every poll, so a live stream could be held for ever.
@Suite("The native hold is bounded")
@MainActor
struct NativeHoldExpiryTests {

    private final class Source: NowPlayingSource {
        let identifier = "scripted"
        var isAvailable = true
        var current: NowPlayingSnapshot?
        func snapshot() async -> NowPlayingSnapshot? { current }
        func expectChange() {}
    }

    private func provider(
        _ source: Source,
        now: @escaping () -> TimeInterval
    ) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60,
            playbackWatcher: nil, webMedia: { .hidden }, now: now
        )
    }

    private func track(
        _ title: String,
        bundleID: String,
        duration: TimeInterval = 240,
        kind: MediaKind = .audio,
        isLive: Bool = false
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title, artist: "Artist", isPlaying: true, duration: duration,
            appName: "Player", appBundleID: bundleID, trackKey: title,
            isLive: isLive, kind: kind
        )
    }

    private func collect(
        _ provider: NowPlayingProvider,
        while body: () async -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        await body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    /// Polling every second for longer than the hold: the card has to go once,
    /// and exactly once.
    @Test("A hidden page polled every second does not hold the card for ever")
    func pollingDoesNotRefreshTheHold() async {
        var clock: TimeInterval = 1_000
        let source = Source()
        source.current = track("A track", bundleID: "com.spotify.client", duration: 9_000)
        let made = provider(source, now: { clock })

        let events = await collect(made) {
            await made.refreshNow()
            source.current = track(
                "Some video", bundleID: "com.google.Chrome", duration: 9_000, kind: .video
            )
            for _ in 0..<90 {
                clock += 1
                await made.refreshNow()
            }
        }
        let retractions = events.filter { if case .retract = $0 { return true } else { return false } }
        #expect(retractions.count == 1, "the hold was refreshed by its own substitution")
    }

    /// A live stream has no duration, so track-end expiry cannot save it — the
    /// elapsed-time bound is the only thing that can.
    @Test("A live native stream is held for a minute and no longer")
    func liveStreamIsBounded() async {
        var clock: TimeInterval = 1_000
        let source = Source()
        source.current = track("Radio", bundleID: "com.apple.Music", duration: 0, isLive: true)
        let made = provider(source, now: { clock })

        let events = await collect(made) {
            await made.refreshNow()
            source.current = track(
                "Some video", bundleID: "com.apple.Safari", duration: 9_000, kind: .video
            )
            for _ in 0..<70 {
                clock += 1
                await made.refreshNow()
            }
        }
        #expect(
            events.contains { if case .retract = $0 { return true } else { return false } },
            "a live stream with no length was held indefinitely"
        )
    }

    @Test("Inside the hold, the card is still there")
    func heldInsideTheWindow() async {
        var clock: TimeInterval = 1_000
        let source = Source()
        source.current = track("A track", bundleID: "com.spotify.client", duration: 9_000)
        let made = provider(source, now: { clock })

        let events = await collect(made) {
            await made.refreshNow()
            source.current = track(
                "Some video", bundleID: "com.google.Chrome", duration: 9_000, kind: .video
            )
            for _ in 0..<30 {
                clock += 1
                await made.refreshNow()
            }
        }
        #expect(!events.contains { if case .retract = $0 { return true } else { return false } })
    }
}

/// Per-website rules, as the provider applies them: which sites get a card,
/// which also get the ears, and what happens when a rule or a tab's website
/// changes under a player that never stopped.
@Suite("Website rules, at the provider")
@MainActor
struct WebsiteRuleProviderTests {

    private final class Source: NowPlayingSource {
        let identifier = "scripted"
        var isAvailable = true
        var current: NowPlayingSnapshot?
        private(set) var reads = 0
        func snapshot() async -> NowPlayingSnapshot? {
            reads += 1
            return current
        }
        func expectChange() {}
    }

    private func page(
        _ title: String = "A video",
        host: String?,
        bundleID: String = "com.apple.Safari",
        kind: MediaKind = .video,
        duration: TimeInterval = 9_000
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title, artist: "A channel", isPlaying: true, duration: duration,
            appName: "Safari", appBundleID: bundleID, trackKey: title, kind: kind,
            origin: MediaOriginEvidence.from(host: host, isBlob: true)
        )
    }

    private func track(_ title: String = "A track") -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title, artist: "Artist", isPlaying: true, duration: 240,
            appName: "Spotify", appBundleID: "com.spotify.client", trackKey: title
        )
    }

    private func provider(
        _ source: Source,
        policy: @escaping () -> WebsitePolicy
    ) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60,
            playbackWatcher: nil, webMedia: policy, now: { 1_000 }
        )
    }

    private func collect(
        _ provider: NowPlayingProvider,
        while body: () async -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        await body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func published(_ events: [ProviderEvent]) -> NowPlayingPayload? {
        for event in events.reversed() {
            if case .publish(let activity) = event, case .nowPlaying(let payload) = activity.payload {
                return payload
            }
        }
        return nil
    }

    private func retracted(_ events: [ProviderEvent]) -> Bool {
        events.contains { if case .retract = $0 { return true } else { return false } }
    }

    private func rules(_ pairs: [(String, WebsiteAppearance)]) -> WebsitePolicy {
        WebsitePolicy(rules: pairs.map { WebsiteRule(host: WebsiteHost($0.0)!, appearance: $0.1) })
    }

    @Test("An unlisted website is not published at all")
    func unlistedHidden() async {
        let source = Source()
        source.current = page(host: "example.org")
        let made = provider(source, policy: { self.rules([("youtube.com", .cardAndCompact)]) })
        let events = await collect(made) { await made.refreshNow() }
        #expect(events.isEmpty, "a site nobody allowed got a card")
    }

    /// The case Ledge cannot name: hidden, whatever the list says.
    @Test("A page with no known website stays hidden")
    func unknownOriginHidden() async {
        let source = Source()
        source.current = page(host: nil)
        let made = provider(source, policy: { self.rules([("youtube.com", .cardAndCompact)]) })
        let events = await collect(made) { await made.refreshNow() }
        #expect(events.isEmpty)
    }

    @Test("Card-only gets a card and never the ears")
    func cardOnly() async {
        let source = Source()
        source.current = page(host: "youtube.com")
        let made = provider(source, policy: { self.rules([("youtube.com", .card)]) })
        let events = await collect(made) { await made.refreshNow() }
        #expect(published(events) != nil)
        #expect(published(events)?.showsInCompact == false)
    }

    @Test("Card-and-compact gets both")
    func cardAndCompact() async {
        let source = Source()
        source.current = page(host: "music.youtube.com")
        let made = provider(source, policy: { self.rules([("music.youtube.com", .cardAndCompact)]) })
        let events = await collect(made) { await made.refreshNow() }
        #expect(published(events)?.showsInCompact == true)
    }

    /// The brief's own example: two rules, one site each, different reach.
    @Test("The specific rule wins over the general one")
    func specificRuleWins() async {
        let policy = rules([("youtube.com", .card), ("music.youtube.com", .cardAndCompact)])
        let watching = Source()
        watching.current = page(host: "www.youtube.com")
        let watchingProvider = provider(watching, policy: { policy })
        let watchingEvents = await collect(watchingProvider) { await watchingProvider.refreshNow() }
        #expect(published(watchingEvents)?.showsInCompact == false, "youtube.com is card-only")

        let listening = Source()
        listening.current = page("A song", host: "music.youtube.com", kind: .audio, duration: 240)
        let listeningProvider = provider(listening, policy: { policy })
        let listeningEvents = await collect(listeningProvider) { await listeningProvider.refreshNow() }
        #expect(published(listeningEvents)?.showsInCompact == true)
    }

    @Test("A native player is unaffected by the website list")
    func nativeUnaffected() async {
        let source = Source()
        source.current = track()
        let made = provider(source, policy: { .hidden })
        let events = await collect(made) { await made.refreshNow() }
        #expect(published(events)?.title == "A track")
        #expect(published(events)?.showsInCompact == true)
    }

    /// Allowing a site publishes what is already playing — no relaunch, and
    /// no second read of the player.
    @Test("Allowing a website publishes it at once, without re-reading")
    func allowingPublishesImmediately() async {
        var policy = WebsitePolicy.hidden
        let source = Source()
        source.current = page(host: "youtube.com")
        let made = provider(source, policy: { policy })

        var readsBefore = 0
        let events = await collect(made) {
            await made.refreshNow()
            policy = self.rules([("youtube.com", .cardAndCompact)])
            readsBefore = source.reads
            made.reconsider()
        }
        #expect(published(events)?.title == "A video")
        #expect(source.reads == readsBefore, "the player was read again for a settings change")
    }

    @Test("Removing a website's rule retracts it at once")
    func removingRetractsImmediately() async {
        var policy = rules([("youtube.com", .cardAndCompact)])
        let source = Source()
        source.current = page(host: "youtube.com")
        let made = provider(source, policy: { policy })
        let events = await collect(made) {
            await made.refreshNow()
            policy = .hidden
            made.reconsider()
        }
        #expect(retracted(events), "the card stayed after its website was removed")
    }

    @Test("Narrowing to card-only drops the compact view and keeps the card")
    func narrowingDropsCompact() async {
        var policy = rules([("youtube.com", .cardAndCompact)])
        let source = Source()
        source.current = page(host: "youtube.com")
        let made = provider(source, policy: { policy })
        let events = await collect(made) {
            await made.refreshNow()
            policy = self.rules([("youtube.com", .card)])
            made.reconsider()
        }
        let publishes = events.compactMap { event -> Activity? in
            if case .publish(let activity) = event { return activity } else { return nil }
        }
        #expect(publishes.count == 2)
        #expect(publishes.first?.restsInEars == true)
        #expect(publishes.last?.restsInEars == false)
        #expect(!retracted(events), "the card itself was never in question")
    }

    /// Navigating the same tab to an unlisted site must retract, even though
    /// the browser and the track key have not changed in any way Ledge can see
    /// except the website.
    @Test("Navigating to an unlisted website retracts the card")
    func navigationAwayRetracts() async {
        let source = Source()
        source.current = page("Same title", host: "youtube.com")
        let made = provider(source, policy: { self.rules([("youtube.com", .cardAndCompact)]) })
        let events = await collect(made) {
            await made.refreshNow()
            // The very same title and track key, a different site.
            source.current = self.page("Same title", host: "example.org")
            await made.refreshNow()
        }
        #expect(retracted(events), "an origin change went unnoticed")
    }

    @Test("Navigating back publishes it again")
    func navigationBackPublishes() async {
        let source = Source()
        source.current = page("Same title", host: "youtube.com")
        let made = provider(source, policy: { self.rules([("youtube.com", .cardAndCompact)]) })
        let events = await collect(made) {
            await made.refreshNow()
            source.current = self.page("Same title", host: "example.org")
            await made.refreshNow()
            source.current = self.page("Same title", host: "youtube.com")
            await made.refreshNow()
        }
        #expect(published(events)?.title == "Same title")
        #expect(published(events)?.showsInCompact == true)
    }

    /// A hidden page does not evict the music: the card the user can see stays.
    @Test("A hidden website cannot take the music's card away")
    func hiddenPageDoesNotEvictNative() async {
        let source = Source()
        source.current = track()
        let made = provider(source, policy: { .hidden })
        let events = await collect(made) {
            await made.refreshNow()
            source.current = self.page(host: "example.org")
            await made.refreshNow()
        }
        #expect(!retracted(events), "a page nobody can see took the music's card")
        #expect(published(events)?.title == "A track")
    }

    @Test("The compact rule reads the same way as the provider")
    func ruleMatchesProvider() {
        let policy = rules([("youtube.com", .card), ("music.youtube.com", .cardAndCompact)])
        let watching = page(host: "youtube.com")
        let listening = page("A song", host: "music.youtube.com", kind: .audio, duration: 240)
        #expect(
            NowPlayingProvider.showsInCompact(watching, showsVideo: true, webMedia: policy) == false
        )
        #expect(NowPlayingProvider.showsInCompact(listening, showsVideo: true, webMedia: policy))
        #expect(
            NowPlayingProvider.showsInCompact(
                page(host: "example.org"), showsVideo: true, webMedia: policy
            ) == false
        )
    }
}

/// The pause clock is keyed on what the user can see, which an unverified
/// asset host is not: adaptive streaming changes CDN host mid-track, and
/// keying on it restarted the fifteen minutes each time.
@Suite("Pause identity ignores unverified hosts")
@MainActor
struct PauseIdentityTests {

    private final class Source: NowPlayingSource {
        let identifier = "scripted"
        var isAvailable = true
        var current: NowPlayingSnapshot?
        func snapshot() async -> NowPlayingSnapshot? { current }
        func expectChange() {}
    }

    private func paused(cdn: String) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: "A track", artist: "Artist", isPlaying: false, duration: 240,
            appName: "Spotify", appBundleID: "com.spotify.client", trackKey: "A track",
            origin: .directAsset(WebsiteHost(cdn)!)
        )
    }

    /// A track paused fifteen minutes ago is retired — and must still be
    /// retired when the CDN host it reports has changed in the meantime.
    @Test("A CDN change does not restart the pause clock")
    func cdnChangeDoesNotRestartTheClock() async {
        var clock: TimeInterval = 1_000
        let source = Source()
        source.current = paused(cdn: "rr1.googlevideo.com")
        let made = NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60, playbackWatcher: nil,
            webMedia: { .hidden }, now: { clock }
        )

        let stream = made.start()
        await made.refreshNow()
        // The same paused track, reported from another edge server, long after
        // the card should have retired.
        clock += NowPlayingProvider.pausedCardLifetime + 10
        source.current = paused(cdn: "rr5.googlevideo.com")
        await made.refreshNow()
        made.stop()

        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        #expect(
            events.contains { if case .retract = $0 { return true } else { return false } },
            "the pause clock restarted when the CDN host changed"
        )
    }
}
