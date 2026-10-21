import Foundation
import Testing

@testable import LedgeCore
@testable import LedgeProviders
@testable import LedgeSystem

/// How long a player keeps its card while a page the user has hidden holds the
/// system's now-playing slot, and what lets it go.
///
/// Two things hold the player: the composite, which can still ask Music and
/// Spotify directly and lets go the moment they say paused, and the provider,
/// for a source that cannot. They used to stack. The composite's held answer
/// reached the provider looking like a fresh sighting, so a pause the composite
/// had confirmed still left a minute of "playing" on the card, and with
/// nothing to confirm the player the one-minute bound became two.
@Suite("Holding a player against a hidden page")
@MainActor
struct NativeHoldTests {

    private final class Fake: NowPlayingSource {
        let identifier = "adapter"
        var isAvailable = true
        var value: NowPlayingSnapshot?
        init(_ value: NowPlayingSnapshot?) { self.value = value }
        func snapshot() async -> NowPlayingSnapshot? { value }
    }

    /// A holding source whose every reading is set by the test.
    private final class FakeHolding: NowPlayingHoldingSource {
        let identifier = "holding"
        var isAvailable = true
        var next: NowPlayingReading
        init(_ next: NowPlayingReading) { self.next = next }
        func snapshot() async -> NowPlayingSnapshot? { next.snapshot }
        func reading() async -> NowPlayingReading { next }
    }

    /// One clock and one set of player answers, shared by everything in a test.
    private final class World {
        var clock: TimeInterval = 1_000
        var players: [String: ScriptingNowPlayingSource.PlayerReading] = [:]
        var pressedAt: TimeInterval = 0
        /// The Automation consent gate: false is "not yet asked".
        var mayAsk = true
        /// Reads a player actually answered with "nothing is playing".
        var nothingReads = 0
        var elapsed: TimeInterval { clock - 1_000 }
    }

    private static let music = "com.apple.Music"
    private static let spotify = "com.spotify.client"
    private static let safari = "com.apple.Safari"

    private static func track(
        _ bundleID: String, playing: Bool = true, title: String = "Song", key: String? = nil
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title, artist: "Artist", album: "Album",
            isPlaying: playing, elapsed: 10, duration: 3_600,
            appName: bundleID, appBundleID: bundleID, trackKey: key ?? "\(bundleID)|42"
        )
    }

    private static let page = NowPlayingSnapshot(
        title: "Autoplay", artist: "", isPlaying: true, elapsed: 0, duration: 9_000,
        appName: "Safari", appBundleID: safari, trackKey: "page", kind: .video
    )

    /// The composite as the app builds it, with web media at its default.
    private func composite(_ adapter: Fake, _ world: World, players: [String]) -> CompositeNowPlayingSource {
        let chosen = ScriptingNowPlayingSource.players.filter { players.contains($0.bundleID) }
        let scripting = ScriptingNowPlayingSource(
            mayQueryPlayers: { world.mayAsk },
            availablePlayers: { chosen },
            readPlayer: {
                let reading = world.players[$0.bundleID] ?? .nothing
                if case .nothing = reading { world.nothingReads += 1 }
                return reading
            },
            now: { world.clock }
        )
        return CompositeNowPlayingSource(
            adapter: adapter,
            scripting: scripting,
            scriptedSnapshot: { [weak scripting] in await scripting?.snapshot(forBundleID: $0) },
            scriptingHandles: { ScriptingNowPlayingSource.handles($0) },
            now: { world.clock },
            lastTransportAt: { world.pressedAt },
            allowsMedia: {
                WebMediaPolicy.hidden.allowsCard(
                    ownerIsApp: BrowserCatalogue.shared.isOpenableApp(bundleID: $0.appBundleID)
                )
            }
        )
    }

    private func provider(_ source: any NowPlayingSource, _ world: World) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source, artwork: ArtworkLoader(),
            playingInterval: 600, idleInterval: 600, playbackWatcher: nil,
            webMedia: { .hidden },
            ownerIsApp: { BrowserCatalogue.shared.isOpenableApp(bundleID: $0) },
            now: { world.clock }
        )
    }

    private func record(_ made: NowPlayingProvider, while body: () async -> Void) async -> [ProviderEvent] {
        let stream = made.start()
        await body()
        made.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    /// The seconds at which the card said this player was playing, by the
    /// provider's own clock.
    private func playing(_ bundleID: String, in events: [ProviderEvent]) -> [TimeInterval] {
        events.compactMap {
            guard case .publish(let activity) = $0, activity.id.source == bundleID,
                  case .nowPlaying(let payload) = activity.payload, payload.isPlaying
            else { return nil }
            return activity.createdAt - 1_000
        }
    }

    /// Whether the card was taken down after it last said playing, rather than
    /// simply left where it was.
    private func retractedAfterPlaying(_ events: [ProviderEvent]) -> Bool {
        guard let last = events.lastIndex(where: {
            if case .publish(let activity) = $0, case .nowPlaying(let payload) = activity.payload {
                return payload.isPlaying
            }
            return false
        }) else { return false }
        return events[(last + 1)...].contains { if case .retract = $0 { return true } else { return false } }
    }

    /// One poll a second.
    private func tick(_ made: NowPlayingProvider, _ world: World, then: () async -> Void = {}) async {
        world.clock += 1
        await made.refreshNow()
        await then()
    }

    // MARK: -

    /// The provider's own hold, for a source that does no holding of its own.
    /// A minute from the last time the player was actually reported, and not a
    /// second more however many polls the page keeps winning.
    @Test("The provider's own hold ends a minute after the player was last reported")
    func providerHoldIsBounded() async throws {
        let world = World()
        let source = Fake(Self.track(Self.spotify))
        let made = provider(source, world)
        let events = await record(made) {
            await made.refreshNow()
            source.value = Self.page
            for _ in 0..<80 { await tick(made, world) }
        }
        let held = playing(Self.spotify, in: events)
        try #require(held.contains(30), "reached: the card was being held against the page")
        let last = try #require(held.last)
        #expect(last < NowPlayingProvider.nativeHoldWithoutSighting, "held until t+\(last)s")
        #expect(retractedAfterPlaying(events), "and then taken down")
    }

    /// The composite asks Music directly, hears "paused", and lets the page
    /// through. The provider must not then hold Music on its own account: what
    /// it would be holding is the composite's echo, not anything it saw.
    @Test("A pause the player confirms ends the hold, with web media hidden")
    func confirmedPauseReleases() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music))
        let adapter = Fake(Self.track(Self.music))
        let made = provider(composite(adapter, world, players: [Self.music]), world)
        // The same composite on the same inputs, to see where it lets go alone.
        let twinAdapter = Fake(adapter.value)
        let twin = composite(twinAdapter, world, players: [Self.music])

        var twinHeld: NowPlayingSnapshot?
        var twinReleasedAt: TimeInterval?
        let events = await record(made) {
            await made.refreshNow()
            _ = await twin.snapshot()
            adapter.value = Self.page
            twinAdapter.value = Self.page
            await tick(made, world) { twinHeld = await twin.snapshot() }
            world.players[Self.music] = .answered(Self.track(Self.music, playing: false))
            for _ in 0..<90 {
                await tick(made, world) {
                    let answer = await twin.snapshot()
                    if twinReleasedAt == nil, answer?.appBundleID == Self.safari {
                        twinReleasedAt = world.elapsed
                    }
                }
            }
        }
        try #require(twinHeld?.appBundleID == Self.music, "reached: Music was held against the page")
        let released = try #require(twinReleasedAt, "reached: the composite let the page through")
        try #require(released < CompositeNowPlayingSource.appHoldAgainstPage, "reached: on the pause, not the bound")
        let last = try #require(playing(Self.music, in: events).last)
        #expect(last < released, "the card said Music was playing \(last - released + 1)s after the pause was confirmed")
        #expect(retractedAfterPlaying(events), "and then taken down")
    }

    /// Past the composite's own minute the player is kept by asking it
    /// directly, poll after poll. Those answers are real sightings, so they do
    /// renew the provider's hold, and a pause heard the same way must end it.
    @Test("A pause heard after the first minute still ends the hold")
    func latePauseReleases() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music))
        let adapter = Fake(Self.track(Self.music))
        let made = provider(composite(adapter, world, players: [Self.music]), world)
        var pausedAt: TimeInterval = 0
        let events = await record(made) {
            await made.refreshNow()
            adapter.value = Self.page
            for _ in 0..<90 { await tick(made, world) }
            world.players[Self.music] = .answered(Self.track(Self.music, playing: false))
            pausedAt = world.elapsed
            for _ in 0..<80 { await tick(made, world) }
        }
        let held = playing(Self.music, in: events)
        try #require(held.contains(pausedAt), "reached: Music was still on the card, playing, past the first minute")
        let last = try #require(held.last)
        #expect(
            last <= pausedAt + CompositeNowPlayingSource.scriptingCadenceWhilePlaying,
            "the card said Music was playing until t+\(last)s after a pause at t+\(pausedAt)s"
        )
        #expect(retractedAfterPlaying(events), "and then taken down")
    }

    /// With Automation refused nothing can confirm the player, and the minute
    /// is the whole of the hold — counted from the last real sighting, not
    /// from the composite's last echo of it.
    @Test("With nothing to confirm the player, the hold is one minute, not two")
    func unconfirmedHoldIsOneMinute() async throws {
        let world = World()
        world.players[Self.spotify] = .unreadable
        let adapter = Fake(Self.track(Self.spotify))
        let made = provider(composite(adapter, world, players: [Self.spotify]), world)
        let events = await record(made) {
            await made.refreshNow()
            adapter.value = Self.page
            for _ in 0..<140 { await tick(made, world) }
        }
        let held = playing(Self.spotify, in: events)
        try #require(held.contains(30), "reached: the card was being held against the page")
        let last = try #require(held.last)
        // The provider dates a sighting when it publishes it, which can be a
        // poll after the read that saw it; hence at most, not before.
        #expect(last <= CompositeNowPlayingSource.appHoldAgainstPage, "held until t+\(last)s")
        #expect(retractedAfterPlaying(events), "and then taken down")
    }

    /// Pausing from the card while a page holds the slot. The press goes to
    /// Music, Music says paused, and the card must not flip back to playing
    /// once the button's own grace is over.
    @Test("A pause pressed on the card is not undone by the hold")
    func pauseFromTheCardStays() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music))
        let adapter = Fake(Self.track(Self.music))
        let source = composite(adapter, world, players: [Self.music])
        let made = provider(source, world)
        var pressedAt: TimeInterval = 0
        let events = await record(made) {
            await made.refreshNow()
            adapter.value = Self.page
            await tick(made, world)
            await tick(made, world)
            // What the shell does on the press: the command goes out, and the
            // source is told the change was asked for.
            world.players[Self.music] = .answered(Self.track(Self.music, playing: false))
            world.pressedAt = world.clock
            pressedAt = world.elapsed
            source.expectChange()
            for _ in 0..<10 { await tick(made, world) }
        }
        let held = playing(Self.music, in: events)
        try #require(held.contains(pressedAt), "reached: Music was held against the page when the pause was pressed")
        let after = held.filter { $0 > pressedAt }
        #expect(after.isEmpty, "the card went back to playing at t+\(after)s after the pause at t+\(pressedAt)s")
    }

    /// What the source heard stop is one player. Another one the provider is
    /// holding is still owed its minute.
    @Test("Hearing a different player stop does not end the hold")
    func otherPlayerStoppingKeepsTheHold() async throws {
        let world = World()
        let source = FakeHolding(NowPlayingReading(snapshot: Self.track(Self.spotify)))
        let made = provider(source, world)
        let events = await record(made) {
            await made.refreshNow()
            source.next = NowPlayingReading(snapshot: Self.page, heardStopped: Self.music)
            for _ in 0..<5 { await tick(made, world) }
        }
        let held = playing(Self.spotify, in: events)
        try #require(held.first == 0, "reached: Spotify was seen playing")
        try #require(!events.contains {
            if case .publish(let activity) = $0 { return activity.id.source == Self.safari }
            return false
        }, "reached: the page was hidden, so only the hold can keep a card up")
        #expect(held.last == 5, "Spotify kept its card")
    }

    /// Stopped rather than paused: Music answers that nothing is playing at
    /// all. That is the player's own word, as final as a pause, and it has to
    /// end the hold the same way rather than be mistaken for silence.
    @Test("A stop the player confirms ends the hold, with web media hidden")
    func confirmedStopReleases() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music))
        let adapter = Fake(Self.track(Self.music))
        let made = provider(composite(adapter, world, players: [Self.music]), world)
        var stoppedAt: TimeInterval = 0
        var nothingBy: TimeInterval?
        let events = await record(made) {
            await made.refreshNow()
            adapter.value = Self.page
            await tick(made, world)
            world.players[Self.music] = .nothing
            stoppedAt = world.elapsed
            for _ in 0..<70 {
                await tick(made, world)
                if nothingBy == nil, world.nothingReads > 0 { nothingBy = world.elapsed }
            }
        }
        let held = playing(Self.music, in: events)
        try #require(held.contains(stoppedAt), "reached: Music was held against the page when it stopped")
        let heard = try #require(nothingBy, "reached: Music was asked, and answered nothing")
        try #require(heard < CompositeNowPlayingSource.appHoldAgainstPage, "reached: inside the hold, so only the answer can end it")
        let last = try #require(held.last)
        #expect(last < heard, "the card said Music was playing until t+\(last)s; Music answered nothing at t+\(heard)s")
        #expect(retractedAfterPlaying(events), "and then taken down")
    }

    /// Before the user has said Ledge may ask the players, nothing is asked, so
    /// nothing was heard: the hold is the bounded one, not a release.
    @Test("A player nobody may ask yet keeps the bounded hold")
    func notYetAskedKeepsTheHold() async throws {
        let world = World()
        world.mayAsk = false
        // What Music would say, if it were asked.
        world.players[Self.music] = .nothing
        let adapter = Fake(Self.track(Self.music))
        let made = provider(composite(adapter, world, players: [Self.music]), world)
        let events = await record(made) {
            await made.refreshNow()
            adapter.value = Self.page
            for _ in 0..<70 { await tick(made, world) }
        }
        try #require(world.nothingReads == 0, "reached: nobody asked Music anything")
        let held = playing(Self.music, in: events)
        #expect(held.contains(30), "held against the page while nothing could be learned")
        let last = try #require(held.last)
        #expect(last <= CompositeNowPlayingSource.appHoldAgainstPage, "and only for the minute")
    }

    /// A "nothing" heard while Music was stopped, before it started playing,
    /// is about a moment that is over. It must not end the hold that playing
    /// earned — not from the cache, and not carried into a later read in which
    /// Music did not answer at all.
    @Test("A stop heard before the player started does not end its hold")
    func earlierStopDoesNotEndTheHold() async throws {
        let world = World()
        world.players[Self.music] = .nothing
        let adapter = Fake(nil)
        let made = provider(composite(adapter, world, players: [Self.music]), world)
        var nothingBeforePlaying = 0
        var silentReadsFrom = 0
        let events = await record(made) {
            await made.refreshNow()
            nothingBeforePlaying = world.nothingReads
            world.players[Self.music] = .answered(Self.track(Self.music))
            adapter.value = Self.track(Self.music)
            await tick(made, world)
            adapter.value = Self.page
            for _ in 0..<15 { await tick(made, world) }
            // Music stops answering, past the few seconds its last answer may
            // cover for it, and a press forces a fresh read of every player.
            world.players[Self.music] = .unreadable
            world.pressedAt = world.clock
            silentReadsFrom = Int(world.elapsed)
            for _ in 0..<15 { await tick(made, world) }
        }
        try #require(nothingBeforePlaying > 0, "reached: Music had answered nothing before it played")
        try #require(world.nothingReads == nothingBeforePlaying, "reached: and never again")
        let held = playing(Self.music, in: events)
        try #require(held.contains(1), "reached: then Music was seen playing")
        #expect(held.contains(TimeInterval(silentReadsFrom)), "kept its card against the page")
        #expect(held.contains(31), "and through reads Music did not answer")
    }

    /// The stop is heard by the read aimed at Music, while the system still
    /// names Music as playing; then a page takes the slot. Spotify is playing
    /// too and comes first when every player is read, so that read never asks
    /// Music again. The stop it already gave has to be enough.
    @Test("A stop heard by the read aimed at the player ends the hold, with another player first in line")
    func targetedStopReleases() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music))
        world.players[Self.spotify] = .answered(Self.track(Self.spotify, title: "Other"))
        let adapter = Fake(Self.track(Self.music))
        let made = provider(composite(adapter, world, players: [Self.spotify, Self.music]), world)
        var heardBefore = 0
        var pageAt: TimeInterval = 0
        let events = await record(made) {
            await made.refreshNow()
            // Music stops. The adapter goes on describing it as playing.
            world.players[Self.music] = .nothing
            for _ in 0..<(Int(CompositeNowPlayingSource.scriptingCadenceWhilePlaying) + 1) {
                await tick(made, world)
            }
            heardBefore = world.nothingReads
            adapter.value = Self.page
            pageAt = world.elapsed + 1
            for _ in 0..<40 { await tick(made, world) }
        }
        try #require(heardBefore > 0, "reached: Music answered nothing to the read aimed at it, before the page")
        // A read of every player in this same world answers Spotify, so it
        // would never have asked Music again.
        let everyone = ScriptingNowPlayingSource(
            mayQueryPlayers: { true },
            availablePlayers: { ScriptingNowPlayingSource.players },
            readPlayer: { world.players[$0.bundleID] ?? .nothing },
            now: { world.clock }
        )
        let first = await everyone.snapshot()
        try #require(first?.appBundleID == Self.spotify && first?.isPlaying == true, "reached: Spotify is first in line, playing")
        let held = playing(Self.music, in: events)
        try #require(held.contains(0), "reached: Music had the card, playing")
        let last = try #require(held.last)
        #expect(last < pageAt, "the card said Music was playing until t+\(last)s; the page came at t+\(pageAt)s")
        #expect(retractedAfterPlaying(events), "and then taken down")
    }

    /// The browser hands its slot back to Music for a moment, the read aimed
    /// at Music hears it has stopped, and the page takes the slot again. The
    /// answer the fallback cached a few seconds earlier still says playing;
    /// the player's later word has to win over it.
    @Test("A stop heard while the page let go for a moment beats an older cached answer")
    func latestStopBeatsCachedPlaying() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music))
        let adapter = Fake(Self.track(Self.music))
        let made = provider(composite(adapter, world, players: [Self.music]), world)
        var cachedPlayingAt: TimeInterval = 0
        var pageBackAt: TimeInterval = 0
        let events = await record(made) {
            await made.refreshNow()
            for _ in 0..<4 { await tick(made, world) }
            // Page: the fallback asks Music and caches "playing".
            adapter.value = Self.page
            await tick(made, world)
            cachedPlayingAt = world.elapsed
            for _ in 0..<4 { await tick(made, world) }
            // Back to Music for a moment, once its own cached answer is due
            // again; Music has stopped, and says so.
            world.players[Self.music] = .nothing
            adapter.value = Self.track(Self.music)
            await tick(made, world)
            // The page again, inside the fallback's cached answer's cadence.
            adapter.value = Self.page
            pageBackAt = world.elapsed + 1
            for _ in 0..<20 { await tick(made, world) }
        }
        try #require(world.nothingReads > 0, "reached: Music answered nothing")
        try #require(
            pageBackAt - cachedPlayingAt < CompositeNowPlayingSource.scriptingCadenceWhilePlaying,
            "reached: the fallback's cached 'playing' was still current when the page came back"
        )
        let held = playing(Self.music, in: events)
        try #require(held.contains(cachedPlayingAt), "reached: Music was held against the page the first time")
        let last = try #require(held.last)
        #expect(last < pageBackAt, "the card said Music was playing until t+\(last)s; it had stopped by t+\(pageBackAt - 1)s")
    }

    /// The seconds at which the card said this title was playing.
    private func playing(title: String, in events: [ProviderEvent]) -> [TimeInterval] {
        events.compactMap {
            guard case .publish(let activity) = $0,
                  case .nowPlaying(let payload) = activity.payload,
                  payload.isPlaying, payload.title == title
            else { return nil }
            return activity.createdAt - 1_000
        }
    }

    /// Music plays Old, a page takes the slot, and Music says behind it that
    /// nothing is playing. Then Music plays New — a different track, seen by
    /// the system — while its scripted reads fail. A stop is about the item
    /// it was heard for: New has not been heard to stop, so it gets the
    /// ordinary hold against the next page, until Music is heard to stop
    /// again.
    @Test("A different track played after a stop gets its own hold")
    func newTrackOutlivesTheStop() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music, title: "Old"))
        let adapter = Fake(Self.track(Self.music, title: "Old", key: "system-old"))
        let made = provider(composite(adapter, world, players: [Self.music]), world)
        var firstPageAt: TimeInterval = 0
        var stopHeardBy: TimeInterval?
        var newAt: TimeInterval = 0
        var secondPageAt: TimeInterval = 0
        var stoppedAgainAt: TimeInterval = 0
        let events = await record(made) {
            await made.refreshNow()
            adapter.value = Self.page
            firstPageAt = world.elapsed + 1
            await tick(made, world)
            world.players[Self.music] = .nothing
            for _ in 0..<12 {
                await tick(made, world)
                if stopHeardBy == nil, world.nothingReads > 0 { stopHeardBy = world.elapsed }
            }
            // Music plays a different track; nothing can script it now.
            world.players[Self.music] = .unreadable
            adapter.value = Self.track(Self.music, title: "New", key: "system-new")
            newAt = world.elapsed + 1
            await tick(made, world)
            await tick(made, world)
            adapter.value = Self.page
            secondPageAt = world.elapsed + 1
            for _ in 0..<30 { await tick(made, world) }
            // And then Music is heard to stop New: a press forces the read.
            world.players[Self.music] = .nothing
            world.pressedAt = world.clock
            stoppedAgainAt = world.elapsed + 1
            for _ in 0..<5 { await tick(made, world) }
        }
        let heard = try #require(stopHeardBy, "reached: Music answered nothing behind the first page")
        let old = playing(title: "Old", in: events)
        try #require(old.contains(firstPageAt), "reached: Old was held against the first page")
        try #require(!old.contains { $0 > heard && $0 < newAt }, "reached: the stop ended Old's hold")
        let new = playing(title: "New", in: events)
        try #require(new.contains(newAt), "reached: New was seen playing, after the stop")
        #expect(new.contains(secondPageAt + 29), "New kept its card against the page")
        #expect(!new.contains { $0 > stoppedAgainAt + 1 }, "until Music was heard to stop New")
    }

    /// The other order. Music stops Old behind a page; the system then goes
    /// on describing Old as playing while Music's reads fail, and a page takes
    /// the slot again. That repeat is a stale copy of the stopped item, not a
    /// new one — it is named the system's way, not the script's — and it must
    /// not buy the hold back.
    @Test("A stale copy of the stopped track does not buy its hold back")
    func staleCopyStaysStopped() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music, title: "Old"))
        let adapter = Fake(Self.track(Self.music, title: "Old", key: "system-old"))
        let made = provider(composite(adapter, world, players: [Self.music]), world)
        var stopHeardBy: TimeInterval?
        var staleFrom: TimeInterval = 0
        var secondPageAt: TimeInterval = 0
        let events = await record(made) {
            await made.refreshNow()
            adapter.value = Self.page
            await tick(made, world)
            world.players[Self.music] = .nothing
            for _ in 0..<12 {
                await tick(made, world)
                if stopHeardBy == nil, world.nothingReads > 0 { stopHeardBy = world.elapsed }
            }
            // The page lets go; the system names Old again, as playing.
            world.players[Self.music] = .unreadable
            adapter.value = Self.track(Self.music, title: "Old", key: "system-old")
            staleFrom = world.elapsed + 1
            for _ in 0..<3 { await tick(made, world) }
            adapter.value = Self.page
            secondPageAt = world.elapsed + 1
            for _ in 0..<30 { await tick(made, world) }
        }
        try #require(stopHeardBy != nil, "reached: Music answered nothing behind the first page")
        let old = playing(title: "Old", in: events)
        try #require(old.contains(0), "reached: Old was named by the script at first")
        try #require(old.contains(staleFrom), "reached: the system went on naming Old as playing after the stop")
        let after = old.filter { $0 >= secondPageAt }
        #expect(after.isEmpty, "the stale copy held the card against the page at t+\(after)s")
    }

    /// The stop and the new track arrive together: the system names New, and
    /// the read that asks Music about it hears that nothing is playing. That
    /// stop is about New — it is what was asked — not about Old, so New is
    /// not let off it.
    @Test("A stop heard while asking about a new track stops that track")
    func stopHeardForTheNewTrack() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music, title: "Old"))
        let adapter = Fake(Self.track(Self.music, title: "Old", key: "system-old"))
        let made = provider(composite(adapter, world, players: [Self.music]), world)
        var newAt: TimeInterval = 0
        var heardWithNew = false
        var pageAt: TimeInterval = 0
        let events = await record(made) {
            await made.refreshNow()
            world.players[Self.music] = .nothing
            adapter.value = Self.track(Self.music, title: "New", key: "system-new")
            newAt = world.elapsed + 1
            await tick(made, world)
            heardWithNew = world.nothingReads > 0
            world.players[Self.music] = .unreadable
            for _ in 0..<3 { await tick(made, world) }
            adapter.value = Self.page
            pageAt = world.elapsed + 1
            for _ in 0..<30 { await tick(made, world) }
        }
        try #require(heardWithNew, "reached: Music answered nothing to the read about New")
        let new = playing(title: "New", in: events)
        try #require(new.contains(newAt), "reached: the system named New as playing")
        let after = new.filter { $0 >= pageAt }
        #expect(after.isEmpty, "New, stopped, held the card against the page at t+\(after)s")
    }

    /// Spotify holds the notch when the system names Music's New, and the
    /// read that asks Music about New hears that nothing is playing. That stop
    /// is New's, though New is not what goes out: when New is later accepted
    /// on the system's word alone, it has not outlived anything, and it does
    /// not get held against a page.
    @Test("A stop heard about a track another player kept off the notch stays with that track")
    func stopStaysWithTheTrackAskedAbout() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music, title: "Old"))
        world.players[Self.spotify] = .answered(Self.track(Self.spotify, title: "Other", key: "spotify-other"))
        let adapter = Fake(Self.track(Self.music, title: "Old", key: "system-old"))
        let source = composite(adapter, world, players: [Self.spotify, Self.music])

        let first = await source.reading()
        try #require(first.snapshot?.title == "Old", "reached: Music's Old had the notch")
        world.clock = 1_020
        adapter.value = Self.track(Self.spotify, title: "Other", key: "system-other")
        let switched = await source.reading()
        try #require(switched.snapshot?.title == "Other", "reached: Spotify's Other took it")

        world.clock = 1_021
        adapter.value = Self.track(Self.music, title: "New", key: "system-new")
        world.players[Self.music] = .nothing
        let asked = await source.reading()
        try #require(world.nothingReads == 1, "reached: the read about New answered nothing")
        try #require(asked.snapshot?.title == "Other" && asked.isHeld, "reached: Other was held over New")

        world.players[Self.music] = .unreadable
        var accepted: NowPlayingReading?
        for second in [1_040.0, 1_044] {
            world.clock = second
            accepted = await source.reading()
        }
        try #require(accepted?.snapshot?.title == "New" && accepted?.isHeld == false, "reached: New was accepted on the system's word")

        world.clock = 1_045
        adapter.value = Self.page
        let page = await source.reading()
        #expect(page.snapshot?.title != "New", "New, stopped, was held against the page")
        #expect(page.heardStopped == Self.music)
    }

    /// A held answer is not a sighting. Music's X is on the notch; the
    /// system then names Music's Y, paused, and Music answers that nothing is
    /// playing, so the stop is Y's — and X is held against Y for the grace
    /// window. That echo of X must not count as X being seen playing after
    /// the stop: Music has said nothing is playing at all, and the next page
    /// gets the notch.
    @Test("A held answer does not count as seeing the player after its stop")
    func heldEchoIsNotASighting() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music, title: "X"))
        let adapter = Fake(Self.track(Self.music, title: "X", key: "system-x"))
        let source = composite(adapter, world, players: [Self.music])

        let first = await source.reading()
        try #require(first.snapshot?.title == "X" && first.snapshot?.isPlaying == true, "reached: X was seen playing")

        world.clock += 1
        adapter.value = Self.track(Self.music, playing: false, title: "Y", key: "system-y")
        world.players[Self.music] = .nothing
        let echo = await source.reading()
        try #require(world.nothingReads == 1, "reached: the read about Y answered nothing")
        try #require(echo.snapshot?.title == "X" && echo.isHeld && echo.snapshot?.isPlaying == true, "reached: X was held, as an echo")

        // Nothing can be asked from here on.
        world.players[Self.music] = .unreadable
        world.clock += 1
        adapter.value = Self.page
        let page = await source.reading()
        #expect(page.snapshot?.title != "X", "the echo of X bought it a hold against the page")
        #expect(page.heardStopped == Self.music)
    }
    /// The stale-copy case again, with the stop heard by the read aimed at
    /// Music rather than by the scan. The system names Old its own way and
    /// the script another; the stop has to be placed under the name Old goes
    /// out with, or the very next stale copy reads as a different item.
    @Test("A stop heard about the system's copy of a track is placed under the track's own name")
    func targetedStopUsesTheOutgoingName() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music, title: "Old"))
        let adapter = Fake(Self.track(Self.music, title: "Old", key: "system-old"))
        let made = provider(composite(adapter, world, players: [Self.music]), world)
        var heardBy: TimeInterval?
        var pageAt: TimeInterval = 0
        let events = await record(made) {
            await made.refreshNow()
            world.players[Self.music] = .nothing
            for _ in 0..<12 {
                await tick(made, world)
                if heardBy == nil, world.nothingReads > 0 { heardBy = world.elapsed }
            }
            world.players[Self.music] = .unreadable
            for _ in 0..<3 { await tick(made, world) }
            adapter.value = Self.page
            pageAt = world.elapsed + 1
            for _ in 0..<20 { await tick(made, world) }
        }
        let heard = try #require(heardBy, "reached: the read aimed at Music answered nothing")
        let old = playing(title: "Old", in: events)
        try #require(old.contains(0), "reached: Old went out under the script's name first")
        try #require(old.contains(heard + 1), "reached: the system went on naming Old as playing after the stop")
        let after = old.filter { $0 >= pageAt }
        #expect(after.isEmpty, "the stale copy held the card against the page at t+\(after)s")
    }

    /// A question's target belongs to the stop it was asked for, not to the
    /// next one. Music's read about Y heard a stop; Music then answered for X,
    /// which ends that stop; later the scan of every player hears Music stop
    /// with no question asked, so that stop is X's, the item Music last
    /// showed. Placed against Y instead, the system's next copy of X would
    /// read as a different item and outlive it.
    @Test("A stop the scan hears is placed against what the player last showed, not an older question")
    func scanStopIgnoresAnOlderTarget() async throws {
        let world = World()
        world.players[Self.music] = .answered(Self.track(Self.music, title: "X", key: "system-x"))
        let playingX = Self.track(Self.music, title: "X", key: "system-x")
        let adapter = Fake(playingX)
        let source = composite(adapter, world, players: [Self.music])

        let first = await source.reading()
        try #require(first.snapshot?.title == "X", "reached: X was shown")

        world.clock += 1
        adapter.value = Self.track(Self.music, playing: false, title: "Y", key: "system-y")
        world.players[Self.music] = .nothing
        let asked = await source.reading()
        try #require(world.nothingReads == 1 && asked.snapshot?.title == "X" && asked.isHeld,
                     "reached: the read about Y heard a stop, with X held")

        world.clock += 1
        adapter.value = playingX
        world.players[Self.music] = .answered(playingX)
        let answered = await source.reading()
        try #require(answered.snapshot?.title == "X" && !answered.isHeld, "reached: Music answered for X")

        world.clock += 1
        world.players[Self.music] = .nothing
        adapter.value = Self.page
        let scanned = await source.reading()
        try #require(world.nothingReads == 2 && scanned.heardStopped == Self.music,
                     "reached: the scan heard Music stop, behind a page")

        world.clock += 1
        world.players[Self.music] = .unreadable
        adapter.value = playingX
        let copy = await source.reading()
        try #require(copy.snapshot?.title == "X" && copy.snapshot?.isPlaying == true && !copy.isHeld,
                     "reached: the system named X as playing again")

        world.clock += 1
        adapter.value = Self.page
        let page = await source.reading()
        #expect(page.snapshot?.title != "X", "the copy of X outlived X's stop and was held against the page")
    }
}
