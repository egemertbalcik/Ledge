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
            trackKey: "live", isLive: true, kind: kind
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
        #expect(NowPlayingProvider.showsInCompact(live(.video), showsVideo: true, webMedia: .shown))
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
        #expect(NowPlayingProvider.showsInCompact(live(.video), showsVideo: false, webMedia: .shown))
        #expect(
            NowPlayingProvider.showsInCompact(
                live(.video), showsVideo: true,
                webMedia: WebMediaPolicy(showsCards: true, showsInCompact: false)
            ) == false,
            "and its own switch still decides"
        )
    }

    @Test("Live radio is audio and behaves as audio always has")
    func liveAudioUnaffected() {
        #expect(NowPlayingProvider.showsInCompact(live(.audio), showsVideo: false, webMedia: .shown))
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
        webMedia: @escaping () -> WebMediaPolicy
    ) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60,
            playbackWatcher: nil, webMedia: webMedia
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
        let made = provider(source, webMedia: { WebMediaPolicy(showsCards: true, showsInCompact: false) })
        let events = await collect(made) { await made.refreshNow() }
        #expect(published(events) != nil)
        #expect(published(events)?.showsInCompact == false)
    }

    @Test("Both on: a page's media is carried the way a player's is")
    func cardAndCompact() async {
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { .shown })
        let events = await collect(made) { await made.refreshNow() }
        #expect(published(events)?.showsInCompact == true)
    }

    /// The invalid pair, which Settings cannot produce but a preference file
    /// can hold. It must behave as both off rather than as compact-only.
    @Test("Compact without cards publishes nothing")
    func compactWithoutCards() async {
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { WebMediaPolicy(showsCards: false, showsInCompact: true) })
        let events = await collect(made) { await made.refreshNow() }
        #expect(events.isEmpty)
    }

    @Test("An app's own media is untouched by either switch")
    func nativeMediaUnchanged() async {
        for policy in [WebMediaPolicy.hidden, .shown] {
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
        var policy = WebMediaPolicy.shown
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
        var policy = WebMediaPolicy.shown
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { policy })
        let events = await collect(made) {
            await made.refreshNow()
            policy = WebMediaPolicy(showsCards: true, showsInCompact: false)
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
        var policy = WebMediaPolicy.hidden
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { policy })
        let events = await collect(made) {
            await made.refreshNow()
            policy = .shown
            made.reconsider()
        }
        #expect(published(events)?.title == "Some video")
        #expect(published(events)?.showsInCompact == true)
    }

    /// A browser taking the system's now-playing slot does not mean the music
    /// stopped. With web media off the page is not published, so withdrawing
    /// the player's card as well would leave the notch showing nothing while
    /// Spotify played on — the card is held instead, bounded by
    /// `nativeHoldWithoutSighting`.
    @Test("A hidden page does not take the player's card away")
    func playerCardIsHeld() async {
        let source = ScriptedSource()
        source.current = media("A track", bundleID: "com.spotify.client")
        let made = provider(source, webMedia: { .hidden })
        let events = await collect(made) {
            await made.refreshNow()
            source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.google.Chrome")
            await made.refreshNow()
        }
        #expect(!retracted(events), "the music's card was taken away by a page nobody can see")
        #expect(published(events)?.title == "A track", "and nothing of the page's was ever published")
    }

    /// What "hidden" has to mean end to end: the queue the cards are drawn
    /// from never hears about it, so there is no card to cycle to, no page dot
    /// counting it, nothing selected pointing at it, and nothing offered to
    /// the ears. Driven through the queue rather than asserted on events
    /// alone, because a ghost is a queue state, not a provider one.
    @Test("A hidden page leaves no card, no dot, no selection and no resting seat")
    func noGhostsInTheQueue() async {
        var queue = ActivityQueue()
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { .hidden })
        for event in await collect(made, while: { await made.refreshNow() }) {
            queue.apply(event)
        }
        #expect(queue.isEmpty, "no card")
        #expect(queue.count == 0, "nothing for the page dots to count")
        #expect(queue.selectedID == nil, "nothing selected")
        #expect(queue.activities.first(where: { $0.restsInEars }) == nil, "nothing in the ears")
    }

    /// And the same page, allowed, does take all four — otherwise the test
    /// above would pass against a provider that published nothing ever.
    @Test("The same page, allowed, does take a card and a seat")
    func allowedPageTakesItsPlace() async {
        var queue = ActivityQueue()
        let source = ScriptedSource()
        source.current = media("Some video", duration: 9000, kind: .video, bundleID: "com.apple.Safari")
        let made = provider(source, webMedia: { .shown })
        for event in await collect(made, while: { await made.refreshNow() }) {
            queue.apply(event)
        }
        #expect(queue.count == 1)
        #expect(queue.selectedID?.source == "com.apple.Safari")
        #expect(queue.activities.first?.restsInEars == true)
    }

    @Test("The compact rule reads the same way the provider does")
    func ruleMatchesProvider() {
        let page = media("Some video", bundleID: "com.apple.Safari")
        let player = media("A track", bundleID: "com.spotify.client")
        #expect(NowPlayingProvider.showsInCompact(page, showsVideo: true, webMedia: .hidden) == false)
        #expect(NowPlayingProvider.showsInCompact(
            page, showsVideo: true,
            webMedia: WebMediaPolicy(showsCards: true, showsInCompact: false)
        ) == false)
        #expect(NowPlayingProvider.showsInCompact(page, showsVideo: true, webMedia: .shown))
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
