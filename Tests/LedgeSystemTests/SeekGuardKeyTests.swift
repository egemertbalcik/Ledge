import Foundation
import Testing

@testable import LedgeSystem

/// The seek guard, fed the key production actually sends.
///
/// The card seeks with the snapshot's `transportKey`, `bundle|id` from the
/// player's own script and nil from anywhere else. The guard once compared
/// a whole `bundle|id` key with the player's bare `id of current track`,
/// which can never be equal, so every scrub of Spotify or Music returned
/// before it wrote the position. The old test passed a bare id, a shape no
/// caller ever produces. That the card's kept name never reaches the guard
/// is `SeekTargetIdentityTests`, through the real composite.
@Suite("The seek guard checks the id the player reports")
@MainActor
struct SeekGuardKeyTests {

    private let separator = "\u{1F}"

    private func player(_ id: String) -> ScriptingNowPlayingSource.Player {
        ScriptingNowPlayingSource.players.first { $0.bundleID == id }!
    }

    /// The literal the guard compares the player's id against.
    private func guardLiteral(in script: String) -> String? {
        guard let start = script.range(of: "is not \""),
              let end = script.range(of: "\" then return", range: start.upperBound..<script.endIndex)
        else { return nil }
        return String(script[start.upperBound..<end.lowerBound])
    }

    @Test("Spotify: a scrub on a scripted song compares the bare id")
    func spotifyScriptedKey() throws {
        let bareID = "spotify:track:6habFhsOp2NvshLv26DqMb"
        let line = ["Song", "Artist", "Album", "206410", "30", "playing", bareID, ""]
            .joined(separator: separator)
        let spotify = player("com.spotify.client")
        let snapshot = try #require(ScriptingNowPlayingSource.parse(line, player: spotify))
        // Reached: the key is the one production builds from this field.
        try #require(snapshot.trackKey.hasSuffix(bareID))

        let script = NowPlayingCommander.transportScript(.seek(120, item: snapshot.transportKey), for: spotify)
        let literal = try #require(guardLiteral(in: script), "the seek lost its guard")
        #expect(literal == bareID, "the guard compares \(literal) with the player's \(bareID), and never writes")
        #expect(script.contains("set player position to 120.000"))
    }

    @Test("Music: a scrub on a scripted song compares the bare id")
    func musicScriptedKey() throws {
        let bareID = "41234"
        let line = ["Song", "Artist", "Album", "206.4", "30", "playing", bareID]
            .joined(separator: separator)
        let music = player("com.apple.Music")
        let snapshot = try #require(ScriptingNowPlayingSource.parse(line, player: music))
        try #require(snapshot.trackKey.hasSuffix(bareID))

        let script = NowPlayingCommander.transportScript(.seek(120, item: snapshot.transportKey), for: music)
        let literal = try #require(guardLiteral(in: script), "the seek lost its guard")
        #expect(literal == bareID)
    }

    @Test("A key made of metadata carries no id to check, so the seek is written unguarded")
    func metadataKeyIsWritten() throws {
        let json = """
            {"adapter":1,"ok":true,"kind":"now","t":100,"playing":true,\
            "title":"Song","artist":"Artist","album":"Album","duration":200,"elapsed":10,\
            "rate":1,"bundleID":"com.spotify.client","displayName":"Spotify"}
            """
        let payload = try JSONDecoder().decode(AdapterPayload.self, from: Data(json.utf8))
        let snapshot = try #require(payload.snapshot(at: 100))
        // Reached: no trackID, so the key is the composed one.
        try #require(snapshot.trackKey.contains("Artist"))

        let script = NowPlayingCommander.transportScript(
            .seek(120, item: snapshot.transportKey), for: player("com.spotify.client")
        )
        #expect(guardLiteral(in: script) == nil, "a composed key can never equal a player's track id")
        #expect(script.contains("set player position to 120.000"))
    }

    @Test("An adapter's identifier is never offered to the guard as the player's id")
    func adapterIdentifiedKey() throws {
        // MediaRemote's identifier, even one that happens to look like a
        // Spotify URI, is not a namespace the AppleScript guard shares.
        let json = """
            {"adapter":1,"ok":true,"kind":"now","t":100,"playing":true,\
            "title":"Song","artist":"Artist","album":"Album","duration":200,"elapsed":10,\
            "rate":1,"trackID":"spotify:track:abc","bundleID":"com.spotify.client","displayName":"Spotify"}
            """
        let payload = try JSONDecoder().decode(AdapterPayload.self, from: Data(json.utf8))
        let snapshot = try #require(payload.snapshot(at: 100))
        try #require(snapshot.trackKey.hasSuffix("spotify:track:abc"))
        #expect(snapshot.transportKey == nil)

        let script = NowPlayingCommander.transportScript(
            .seek(120, item: snapshot.transportKey), for: player("com.spotify.client")
        )
        #expect(guardLiteral(in: script) == nil)
        #expect(script.contains("set player position to 120.000"))
    }

    @Test("Another player's key is not this player's id")
    func otherPlayersKey() {
        let musicKey = TrackKey.identified("41234", by: "com.apple.Music")
        #expect(TrackKey.itemID(in: musicKey, for: "com.spotify.client") == nil)
        #expect(TrackKey.itemID(in: musicKey, for: "com.apple.Music") == "41234")
    }
}
