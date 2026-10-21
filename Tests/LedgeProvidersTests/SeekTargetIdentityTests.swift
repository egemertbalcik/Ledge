import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

/// What a scrub is checked against, after the card's name for the song has
/// been kept from an earlier answer.
///
/// The composite keeps one name per song, so the card does not turn over
/// when the answer switches sources. The adapter usually names the song
/// first, with MediaRemote's own identifier. When scripting then takes over
/// mid-song — the Automation button pressed for the first time, or a first
/// read that missed its deadline — the card keeps that name, and the seek
/// guard compared MediaRemote's identifier with AppleScript's
/// `id of current track`. They are different namespaces, so every scrub was
/// dropped for the rest of the song.
@Suite("A scrub is checked against the player's own id", .serialized)
@MainActor
struct SeekTargetIdentityTests {

    @MainActor
    private final class Feed: NowPlayingSource {
        let identifier = "adapter"
        var isAvailable = true
        var value: NowPlayingSnapshot?
        init(_ value: NowPlayingSnapshot?) { self.value = value }
        func snapshot() async -> NowPlayingSnapshot? { value }
    }

    @MainActor
    private final class World {
        var now: TimeInterval = 1_000
        var allowed = false
    }

    private static let spotify = ScriptingNowPlayingSource.players.first {
        $0.bundleID == "com.spotify.client"
    }!

    /// What the coordinator sends with a seek (LedgeCoordinator's `seek`).
    private func seekItem(_ payload: NowPlayingPayload) -> String? {
        payload.transportKey
    }

    private func lastPayload(_ events: [ProviderEvent]) -> NowPlayingPayload? {
        events.reversed().lazy.compactMap { event -> NowPlayingPayload? in
            guard case .publish(let activity) = event,
                  case .nowPlaying(let payload) = activity.payload
            else { return nil }
            return payload
        }.first
    }

    private func adapterLine(trackID: String?) throws -> NowPlayingSnapshot? {
        let id = trackID.map { #","trackID":"\#($0)""# } ?? ""
        let json = """
            {"adapter":1,"ok":true,"kind":"now","t":1000,"playing":true,\
            "title":"Song","artist":"Artist","album":"Album","duration":200,"elapsed":10,\
            "rate":1\(id),"bundleID":"com.spotify.client","displayName":"Spotify"}
            """
        return try JSONDecoder().decode(AdapterPayload.self, from: Data(json.utf8)).snapshot(at: 1_000)
    }

    /// The adapter names the song first, then scripting answers for it.
    private func handover(adapterTrackID: String?) async throws -> NowPlayingPayload? {
        let world = World()
        let line = ["Song", "Artist", "Album", "200000", "10", "playing", "spotify:track:own-id", ""]
            .joined(separator: "\u{1F}")
        let scripted = try #require(ScriptingNowPlayingSource.parse(line, player: Self.spotify))
        let script = ScriptingNowPlayingSource(
            mayQueryPlayers: { world.allowed },
            availablePlayers: { [Self.spotify] },
            readPlayer: { _ in .answered(scripted) },
            now: { world.now }
        )
        let composite = CompositeNowPlayingSource(
            adapter: Feed(try adapterLine(trackID: adapterTrackID)),
            scripting: script,
            scriptedSnapshot: { await script.snapshot(forBundleID: $0) },
            scriptingHandles: { ScriptingNowPlayingSource.handles($0) },
            now: { world.now },
            lastTransportAt: { 0 }
        )
        let provider = NowPlayingProvider(
            source: composite, artwork: ArtworkLoader(),
            playingInterval: 60, idleInterval: 60,
            playbackWatcher: nil, ownerIsApp: { _ in true },
            now: { world.now }
        )
        let stream = provider.start()
        await provider.refreshNow()
        // The Automation button, pressed while the song plays on.
        world.allowed = true
        world.now += 11
        await provider.refreshNow()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return lastPayload(events)
    }

    @Test("After scripting takes over a song the adapter named, a scrub is checked against the script's id")
    func mediaRemoteNameDoesNotBecomeTheSeekTarget() async throws {
        let payload = try #require(try await handover(adapterTrackID: "MR-opaque-identifier"))
        // Reached: the card kept the adapter's name for the song, which is
        // the stable-name rule working, and the answer is now the script's.
        try #require(payload.itemKey == "com.spotify.client|MR-opaque-identifier")

        let script = NowPlayingCommander.transportScript(.seek(120, item: seekItem(payload)), for: Self.spotify)
        #expect(
            script.contains(#"is not "spotify:track:own-id" then return"#),
            "the scrub is not checked against the id the player reports"
        )
        #expect(!script.contains("MR-opaque-identifier"), "MediaRemote's identifier reached the AppleScript guard")
        #expect(script.contains("set player position to 120.000"))
    }

    @Test("Before scripting has answered, nothing is offered as the player's id")
    func adapterOnlyCardHasNoScriptedId() async throws {
        let feed = Feed(try adapterLine(trackID: "MR-opaque-identifier"))
        let snapshot = try #require(await feed.snapshot())
        // Reached: an adapter answer that does carry an identifier.
        try #require(snapshot.trackKey.hasSuffix("MR-opaque-identifier"))
        #expect(snapshot.transportKey == nil, "MediaRemote's identifier was offered as the player's own")

        // So its seek is written without an id check rather than refused.
        let script = NowPlayingCommander.transportScript(.seek(30, item: snapshot.transportKey), for: Self.spotify)
        #expect(!script.contains("id of current track"))
        #expect(script.contains("set player position to 30.000"))
    }
}
