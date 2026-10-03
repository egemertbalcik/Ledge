import Foundation
import Testing

@testable import LedgeCore
@testable import LedgeSystem

/// What happens when two things are making sound at once.
///
/// The notch has one seat and no way to ask which one the user means, so the
/// rules are about *what kind* of thing each one is. A page that starts while
/// an app plays is autoplay until proven otherwise; anything else is somebody
/// pressing play.
@Suite("Media handover between players")
@MainActor
struct MediaHandoverTests {

    private final class Source: NowPlayingSource {
        let identifier: String
        var isAvailable = true
        var value: NowPlayingSnapshot?
        init(identifier: String, value: NowPlayingSnapshot? = nil) {
            self.identifier = identifier
            self.value = value
        }
        func snapshot() async -> NowPlayingSnapshot? { value }
        func expectChange() {}
    }

    private final class Clock { var now: TimeInterval = 1_000 }

    private static let spotify = "com.spotify.client"
    private static let chrome = "com.google.Chrome"
    private static let safari = "com.apple.Safari"

    private func track(
        _ bundleID: String,
        title: String,
        playing: Bool = true,
        elapsed: TimeInterval = 10
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title,
            artist: "A",
            isPlaying: playing,
            elapsed: elapsed,
            duration: 300,
            appName: bundleID,
            appBundleID: bundleID,
            trackKey: "\(bundleID)-\(title)"
        )
    }

    private func composite(
        adapter: Source,
        scripting: Source,
        clock: Clock
    ) -> CompositeNowPlayingSource {
        CompositeNowPlayingSource(
            adapter: adapter,
            scripting: scripting,
            scriptedSnapshot: { _ in nil },
            scriptingHandles: { $0 == Self.spotify },
            now: { clock.now },
            lastTransportAt: { 0 }
        )
    }

    @Test("A page that starts playing does not take the notch from an app")
    func autoplayDoesNotStealFromAnApp() async {
        let clock = Clock()
        // Spotify is playing and holds the seat.
        let adapter = Source(identifier: "adapter", value: track(Self.spotify, title: "Song"))
        let scripting = Source(identifier: "scripting", value: track(Self.spotify, title: "Song"))
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        // A tab starts playing — and keeps claiming to, for a good while.
        adapter.value = track(Self.chrome, title: "Autoplaying clip")
        for _ in 0..<10 {
            clock.now += 1
            let answer = await source.snapshot()
            #expect(answer?.appBundleID == Self.spotify, "the music keeps the notch")
        }
    }

    @Test("An app that starts playing takes the notch from a page")
    func appTakesOverFromAPage() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.chrome, title: "Video"))
        let scripting = Source(identifier: "scripting", value: track(Self.chrome, title: "Video"))
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        adapter.value = track(Self.spotify, title: "Song")
        var answer: NowPlayingSnapshot?
        for _ in 0..<6 {
            clock.now += 1
            answer = await source.snapshot()
        }
        #expect(answer?.appBundleID == Self.spotify)
    }

    @Test("A paused incumbent gives the seat up at once")
    func pausedIncumbentYields() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.spotify, title: "Song"))
        let scripting = Source(identifier: "scripting", value: track(Self.spotify, title: "Song"))
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        // The music is paused, and a page is playing.
        scripting.value = track(Self.spotify, title: "Song", playing: false)
        adapter.value = track(Self.chrome, title: "Video")
        clock.now += 1
        var answer = await source.snapshot()
        // Corroboration still applies within the stream, so give it a beat.
        clock.now += 2
        answer = await source.snapshot()
        #expect(answer?.appBundleID == Self.chrome, "nothing is holding the seat")
    }

    /// The case reported from a real session: Spotify playing and holding the
    /// compact view, a video autoplaying in a browser tab, and the browser's
    /// card arriving anyway. Persistence is what the corroboration window
    /// measures, and an autoplaying video is nothing but persistent — so it
    /// kept qualifying and took the seat. A page may not do that to an app.
    @Test("A page never corroborates its way past a playing app")
    func pageCannotTakeSeatFromPlayingApp() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.spotify, title: "Song"))
        let scripting = Source(identifier: "scripting", value: track(Self.spotify, title: "Song"))
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        // The page keeps playing, poll after poll — exactly what defeated the
        // corroboration window before.
        adapter.value = track(Self.safari, title: "Video")
        var answer: NowPlayingSnapshot?
        for _ in 0..<20 {
            clock.now += 1
            answer = await source.snapshot()
        }
        #expect(answer?.appBundleID == Self.spotify, "the music keeps the notch while it plays")
    }

    /// And the hold is not a trap: once the player is actually paused, the page
    /// is welcome to the seat. Known from the scripting fallback, which is the
    /// one source that can still see a player the system has stopped naming —
    /// and asked on its own cadence, so the handover lands within ten seconds
    /// of the pause rather than on the next poll.
    @Test("Pausing the app hands the seat to the page")
    func pausingReleasesTheSeatToThePage() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.spotify, title: "Song"))
        let scripting = Source(identifier: "scripting", value: track(Self.spotify, title: "Song"))
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        adapter.value = track(Self.safari, title: "Video")
        clock.now += 1
        #expect(await source.snapshot()?.appBundleID == Self.spotify)

        scripting.value = track(Self.spotify, title: "Song", playing: false)
        // The cached scripting answer is good for `scriptingCadenceWhilePlaying`,
        // so the pause is seen at the next question rather than at the next poll.
        clock.now += CompositeNowPlayingSource.scriptingCadenceWhilePlaying + 1
        #expect(await source.snapshot()?.appBundleID == Self.safari)
    }

    /// Without Automation permission there is no way to ask whether the player
    /// is still going, so the hold is bounded rather than indefinite: a minute
    /// with no sighting of the app at all, and the page is let through.
    @Test("With nothing able to confirm the app, the hold expires")
    func holdIsBoundedWhenNothingCanConfirm() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.spotify, title: "Song"))
        // No scripting at all — Automation not granted.
        let scripting = Source(identifier: "scripting", value: nil)
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        adapter.value = track(Self.safari, title: "Video", elapsed: 0)
        clock.now += 30
        #expect(await source.snapshot()?.appBundleID == Self.spotify, "still held at thirty seconds")

        clock.now += CompositeNowPlayingSource.appHoldAgainstPage
        #expect(await source.snapshot()?.appBundleID == Self.safari, "and released after the window")
    }

    /// An app taking over from an app is somebody pressing play, and still
    /// goes through the corroboration window it always did.
    @Test("An app still corroborates its way past another app")
    func appStillTakesSeatFromApp() async {
        let clock = Clock()
        let music = "com.apple.Music"
        let adapter = Source(identifier: "adapter", value: track(Self.spotify, title: "Song"))
        let scripting = Source(identifier: "scripting", value: track(Self.spotify, title: "Song"))
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        adapter.value = track(music, title: "Other")
        var answer: NowPlayingSnapshot?
        for _ in 0..<8 {
            clock.now += 1
            answer = await source.snapshot()
        }
        #expect(answer?.appBundleID == music)
    }

    @Test("One page does not hold the notch against another page")
    func pageYieldsToPage() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.chrome, title: "First"))
        let scripting = Source(identifier: "scripting", value: nil)
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        _ = await source.snapshot()

        adapter.value = track(Self.safari, title: "Second")
        var answer: NowPlayingSnapshot?
        for _ in 0..<6 {
            clock.now += 1
            answer = await source.snapshot()
        }
        #expect(answer?.appBundleID == Self.safari)
    }

    // MARK: - How quickly a new track lands

    /// The "compact view is slow" report. Spotify announced a track change in
    /// under a tenth of a second; the card kept the old title for two, because
    /// every different item had to be seen twice, 1.2s apart, before it was
    /// believed.
    @Test("An app's next track is shown at once, not after corroboration")
    func appTrackChangeIsImmediate() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.spotify, title: "First"))
        let scripting = Source(identifier: "scripting", value: track(Self.spotify, title: "First"))
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        #expect(await source.snapshot()?.title == "First")

        // Next track, read a fifth of a second later — sooner than any
        // corroboration window.
        clock.now += 0.2
        adapter.value = track(Self.spotify, title: "Second")
        scripting.value = track(Self.spotify, title: "Second")
        #expect(await source.snapshot()?.title == "Second")
    }

    /// The churn the corroboration exists for is still resisted: a browser
    /// naming a different item once is not yet news.
    @Test("A page's new item still has to persist before it is believed")
    func pageTrackChangeStillCorroborates() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track(Self.chrome, title: "Clip"))
        let scripting = Source(identifier: "scripting", value: nil)
        let source = composite(adapter: adapter, scripting: scripting, clock: clock)
        #expect(await source.snapshot()?.title == "Clip")

        clock.now += 0.2
        adapter.value = track(Self.chrome, title: "Autoplay")
        #expect(await source.snapshot()?.title == "Clip", "seen once is not enough")

        clock.now += CompositeNowPlayingSource.challengerCorroboration
        #expect(await source.snapshot()?.title == "Autoplay", "still there, so it is real")
    }
}

/// A page nobody can see must not hold the notch. The composite holds the
/// incumbent against churn — which is right for a visible card and wrong for a
/// hidden one: with nothing drawn for it, holding meant the notch showed
/// nothing at all while a player waited behind it.
@Suite("Hidden websites never hold the notch")
@MainActor
struct HiddenWebsiteHandoverTests {

    private final class Source: NowPlayingSource {
        let identifier: String
        var isAvailable = true
        var value: NowPlayingSnapshot?
        init(identifier: String, value: NowPlayingSnapshot? = nil) {
            self.identifier = identifier
            self.value = value
        }
        func snapshot() async -> NowPlayingSnapshot? { value }
        func expectChange() {}
    }

    private final class Clock { var now: TimeInterval = 1_000 }

    private func page(_ title: String, host: String?) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title, artist: "A channel", isPlaying: true, elapsed: 10, duration: 9_000,
            appName: "Safari", appBundleID: "com.apple.Safari", trackKey: "page-\(title)",
            kind: .video, origin: MediaOriginEvidence.from(host: host, isBlob: true)
        )
    }

    private func track(_ title: String) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title, artist: "Artist", isPlaying: true, elapsed: 10, duration: 300,
            appName: "Spotify", appBundleID: "com.spotify.client", trackKey: "track-\(title)"
        )
    }

    private func composite(
        adapter: Source,
        scripting: Source,
        clock: Clock,
        allows: @escaping @MainActor (NowPlayingSnapshot) -> Bool
    ) -> CompositeNowPlayingSource {
        CompositeNowPlayingSource(
            adapter: adapter,
            scripting: scripting,
            scriptedSnapshot: { [weak scripting] _ in scripting?.value },
            scriptingHandles: { $0 == "com.spotify.client" },
            now: { clock.now },
            lastTransportAt: { 0 },
            allowsMedia: allows
        )
    }

    /// A hidden page playing, and then the user presses play in Spotify: the
    /// track must take the notch at once, not after the churn window.
    @Test("A hidden page yields to a player immediately")
    func hiddenPageYieldsAtOnce() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: page("Advert", host: "ads.example"))
        let scripting = Source(identifier: "scripting", value: nil)
        let source = composite(
            adapter: adapter, scripting: scripting, clock: clock,
            // Only youtube.com is allowed; the advert's site is not.
            allows: {
                $0.verifiedWebsite == WebsiteHost("youtube.com")
                    || $0.appBundleID == "com.spotify.client"
            }
        )
        _ = await source.snapshot()

        adapter.value = track("Bad Habit")
        clock.now += 1
        let answer = await source.snapshot()
        #expect(
            answer?.appBundleID == "com.spotify.client",
            "a page nobody can see held the notch against the music"
        )
    }

    /// And an allowed page still holds it, as any visible card does.
    @Test("An allowed page still holds the notch against churn")
    func allowedPageStillHolds() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: page("A video", host: "youtube.com"))
        let scripting = Source(identifier: "scripting", value: nil)
        let source = composite(
            adapter: adapter, scripting: scripting, clock: clock,
            allows: { _ in true }
        )
        _ = await source.snapshot()

        adapter.value = page("An advert", host: "youtube.com")
        clock.now += 1
        let answer = await source.snapshot()
        #expect(answer?.title == "A video", "the churn guard stopped working")
    }

    /// A hidden page cannot corroborate its way into the seat either.
    @Test("A hidden page cannot corroborate past a player")
    func hiddenPageCannotCorroborate() async {
        let clock = Clock()
        let adapter = Source(identifier: "adapter", value: track("Song"))
        let scripting = Source(identifier: "scripting", value: track("Song"))
        let source = composite(
            adapter: adapter, scripting: scripting, clock: clock,
            allows: { $0.appBundleID == "com.spotify.client" }
        )
        _ = await source.snapshot()

        adapter.value = page("Advert", host: "ads.example")
        var answer: NowPlayingSnapshot?
        for _ in 0..<20 {
            clock.now += 1
            answer = await source.snapshot()
        }
        #expect(
            answer?.appBundleID == "com.spotify.client",
            "a hidden page corroborated its way past the music"
        )
    }

    /// A website change is a different item even when the track key is not.
    @Test("A tab navigating elsewhere is a different item")
    func originChangeIsADifferentItem() {
        let allowed = page("Same", host: "youtube.com")
        var elsewhere = allowed
        elsewhere.origin = .blobOrigin(WebsiteHost("example.org")!)
        #expect(CompositeNowPlayingSource.isDifferentItem(allowed, elsewhere))
        #expect(CompositeNowPlayingSource.isDifferentItem(allowed, allowed) == false)
    }

    /// An *unverified* asset host changes on its own: adaptive streaming moves
    /// between edge servers mid-track, and none of that changes what the user
    /// sees or what any rule matches. Treating it as a new item reset the pause
    /// clock, disturbed handover and republished an unchanged card.
    @Test("A CDN host changing mid-track is not a new item")
    func cdnChangeIsNotANewItem() {
        var first = page("Same", host: nil)
        first.origin = .directAsset(WebsiteHost("rr1.googlevideo.com")!)
        var second = first
        second.origin = .directAsset(WebsiteHost("rr5.googlevideo.com")!)

        #expect(
            CompositeNowPlayingSource.isDifferentItem(first, second) == false,
            "an edge-server switch looked like a different track"
        )
        #expect(first == second, "and republished a card that had not changed")
    }

    @Test("Gaining or losing an unverified host is not a new item")
    func appearingCDNIsNotANewItem() {
        var none = page("Same", host: nil)
        none.origin = .none
        var withCDN = none
        withCDN.origin = .directAsset(WebsiteHost("googlevideo.com")!)
        #expect(CompositeNowPlayingSource.isDifferentItem(none, withCDN) == false)
        #expect(none == withCDN)
    }

    /// But gaining a *verified* origin is: Ledge may now be allowed to show
    /// something it was hiding a moment ago.
    @Test("Gaining a verified website is a new item")
    func gainingVerifiedOriginIsANewItem() {
        var unknown = page("Same", host: nil)
        unknown.origin = .directAsset(WebsiteHost("googlevideo.com")!)
        var known = unknown
        known.origin = .blobOrigin(WebsiteHost("youtube.com")!)
        #expect(CompositeNowPlayingSource.isDifferentItem(unknown, known))
        #expect(unknown != known)
    }
}
