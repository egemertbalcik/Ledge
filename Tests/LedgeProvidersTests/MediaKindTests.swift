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
    func snapshot() async -> NowPlayingSnapshot? { current }
}

private func media(
    _ title: String,
    playing: Bool = true,
    duration: TimeInterval = 240,
    kind: MediaKind = .audio,
    bundleID: String = "com.spotify.client"
) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        title: title, artist: "Artist", isPlaying: playing, duration: duration,
        appName: "Player", appBundleID: bundleID, trackKey: title, kind: kind
    )
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
        showsVideo: @escaping () -> Bool = { true },
        appsOnly: @escaping () -> Bool = { false }
    ) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60,
            playbackWatcher: nil, showsVideo: showsVideo, appsOnly: appsOnly
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

    private func live(_ kind: MediaKind, playing: Bool = true) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: "The match", artist: "A channel", isPlaying: playing,
            elapsed: 900, duration: 0,
            appName: "Safari", appBundleID: "com.apple.Safari",
            trackKey: "live", isLive: true, kind: kind
        )
    }

    /// The two-minute floor exists to keep clips out, and a broadcast has no
    /// length to measure against it.
    @Test("A live broadcast reaches the compact view despite having no length")
    func liveVideoIsCompactWorthy() {
        #expect(NowPlayingProvider.showsInCompact(live(.video), showsVideo: true))
        #expect(NowPlayingProvider.shouldShow(live(.video)))
    }

    @Test("Turning video off still turns it off")
    func togglingStillApplies() {
        #expect(NowPlayingProvider.showsInCompact(live(.video), showsVideo: false) == false)
    }

    @Test("Live radio is audio and behaves as audio always has")
    func liveAudioUnaffected() {
        #expect(NowPlayingProvider.showsInCompact(live(.audio), showsVideo: false))
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
/// the card can be a video nobody chose. "Only show media from apps" refuses
/// the lot of it.
@Suite("Only media from apps")
@MainActor
struct AppMediaOnlyTests {

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
        appsOnly: Bool,
        hidesWebCard: Bool = true
    ) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60,
            playbackWatcher: nil,
            appsOnly: { appsOnly }, hidesWebCard: { hidesWebCard }
        )
    }

    @Test("A web page gets no card when only apps may have one")
    func webRefused() async {
        let source = ScriptedSource()
        source.current = media("Some video", bundleID: "com.apple.Safari")
        let made = provider(source, appsOnly: true)
        let events = await collect(made) { await made.refreshNow() }
        #expect(events.isEmpty, "nothing published at all — no card, no compact view, no peek")
    }

    @Test("A player still gets one")
    func playerAllowed() async {
        let source = ScriptedSource()
        source.current = media("A track", bundleID: "com.spotify.client")
        let made = provider(source, appsOnly: true)
        let events = await collect(made) { await made.refreshNow() }
        #expect(!events.isEmpty)
    }

    @Test("With the setting off, a web page is carried as before")
    func webAllowedByDefault() async {
        let source = ScriptedSource()
        source.current = media("Some video", bundleID: "com.apple.Safari")
        let made = provider(source, appsOnly: false)
        let events = await collect(made) { await made.refreshNow() }
        #expect(!events.isEmpty)
    }

    @Test("A card already up is taken away when the source turns out to be a page")
    func cardRetracted() async {
        // The provider retracts through the same path it uses for a player
        // that stopped, so nothing is left behind in the queue.
        let source = ScriptedSource()
        source.current = media("A track", bundleID: "com.spotify.client")
        let provider = provider(source, appsOnly: true)
        let events = await collect(provider) {
            await provider.refreshNow()
            source.current = media("Some video", bundleID: "com.google.Chrome")
            await provider.refreshNow()
        }
        let retracted = events.contains { if case .retract = $0 { return true } else { return false } }
        #expect(retracted, "the player's card is withdrawn rather than replaced by the page's")
    }
}

/// Keeping a page out of the ears and refusing it a card are two different
/// wishes, and the second is only offered once the first has been made.
@Suite("Web media: ears, then card")
@MainActor
struct WebMediaScopeTests {

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

    @Test("Kept out of the ears, a page still has its card")
    func compactOnlyKeepsTheCard() async {
        let source = ScriptedSource()
        source.current = media("Some video", bundleID: "com.apple.Safari")
        let made = NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60, playbackWatcher: nil,
            appsOnly: { true }, hidesWebCard: { false }
        )
        let payload = published(await collect(made) { await made.refreshNow() })
        #expect(payload != nil, "the card is still published")
        #expect(payload?.showsInCompact == false, "but it does not rest in the ears")
    }

    @Test("A player is untouched by either switch")
    func playerUnaffected() async {
        let source = ScriptedSource()
        source.current = media("A track", bundleID: "com.spotify.client")
        let made = NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60, playbackWatcher: nil,
            appsOnly: { true }, hidesWebCard: { true }
        )
        let payload = published(await collect(made) { await made.refreshNow() })
        #expect(payload?.showsInCompact == true)
    }

    @Test("Hiding the card needs both switches")
    func cardNeedsBoth() async {
        // The second switch alone does nothing: it is disabled in Settings
        // until the first is on, and the rule says the same thing so the two
        // cannot drift apart.
        let source = ScriptedSource()
        source.current = media("Some video", bundleID: "com.apple.Safari")
        let onlyCardSwitch = NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60, playbackWatcher: nil,
            appsOnly: { false }, hidesWebCard: { true }
        )
        let events = await collect(onlyCardSwitch) { await onlyCardSwitch.refreshNow() }
        #expect(!events.isEmpty, "nothing is hidden while the first switch is off")
    }

    @Test("The compact rule reads the same way as the provider")
    func ruleMatches() {
        let page = media("Some video", bundleID: "com.apple.Safari")
        let player = media("A track", bundleID: "com.spotify.client")
        #expect(NowPlayingProvider.showsInCompact(page, showsVideo: true, appsOnly: true) == false)
        #expect(NowPlayingProvider.showsInCompact(page, showsVideo: true, appsOnly: false))
        #expect(NowPlayingProvider.showsInCompact(player, showsVideo: true, appsOnly: true))
    }
}

