import Foundation
import Testing

@testable import LedgeSystem

@Suite("AppleScript missing value")
@MainActor
struct ScriptingMissingValueTests {

    private let separator = "\u{1F}"

    private var spotify: ScriptingNowPlayingSource.Player {
        ScriptingNowPlayingSource.players.first { $0.bundleID == "com.spotify.client" }!
    }

    private var music: ScriptingNowPlayingSource.Player {
        ScriptingNowPlayingSource.players.first { $0.bundleID == "com.apple.Music" }!
    }

    private func line(_ fields: String...) -> String {
        fields.joined(separator: separator)
    }

    @Test("A missing artist or album is empty, not the literal text")
    func missingTextFields() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "missing value", "missing value", "1000", "0", "playing", "id", ""),
            player: spotify
        ))
        #expect(snapshot.artist == "")
        #expect(snapshot.album == "")
    }

    @Test("A missing duration stays unknown rather than filling the bar")
    func missingDuration() throws {
        // A stream with no duration used to parse to 0 and then be clamped up
        // to the position — a full progress bar for something with no end.
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "missing value", "42", "playing", "id"),
            player: music
        ))
        #expect(snapshot.duration == 0)
        #expect(snapshot.elapsed == 42)
    }

    @Test("A missing track id falls back to the metadata key")
    func missingTrackID() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "1000", "0", "playing", "missing value", ""),
            player: spotify
        ))
        #expect(snapshot.trackKey == "com.spotify.client|Artist|Album|Title")
    }

    @Test("A missing artwork URL yields none")
    func missingArtwork() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "1000", "0", "playing", "id", "missing value"),
            player: spotify
        ))
        #expect(snapshot.artworkURL == nil)
    }

    @Test("A missing title is still empty, and a real one is left alone")
    func missingTitleAndOrdinaryText() throws {
        let missing = try #require(ScriptingNowPlayingSource.parse(
            line("missing value", "Artist", "Album", "1000", "0", "playing", "id", ""),
            player: spotify
        ))
        #expect(missing.title == "")

        let ordinary = try #require(ScriptingNowPlayingSource.parse(
            line("Missing Values (Live)", "Artist", "Album", "1000", "0", "playing", "id", ""),
            player: spotify
        ))
        #expect(ordinary.title == "Missing Values (Live)")
    }
}

@Suite("Automation denial latch")
struct AutomationDenialLatchTests {

    @Test("A denial is remembered for the cooldown, then forgotten")
    func deniedThenCleared() {
        var latch = AutomationDenialLatch()
        let cooldown = AutomationDenialLatch.cooldown
        let untouched = latch.isDenied("com.apple.Music", now: 0)
        #expect(untouched == false)

        latch.recordDenial("com.apple.Music", now: 0)
        let justAfter = latch.isDenied("com.apple.Music", now: 1)
        let nearEnd = latch.isDenied("com.apple.Music", now: cooldown - 1)
        let atEnd = latch.isDenied("com.apple.Music", now: cooldown)
        // And having lapsed, it stays clear until denied again.
        let afterEnd = latch.isDenied("com.apple.Music", now: cooldown + 1)
        #expect(justAfter)
        #expect(nearEnd)
        #expect(atEnd == false)
        #expect(afterEnd == false)
    }

    @Test("Denying one player does not silence the other")
    func perPlayer() {
        var latch = AutomationDenialLatch()
        latch.recordDenial("com.apple.Music", now: 0)
        let other = latch.isDenied("com.spotify.client", now: 1)
        #expect(other == false)
    }

    @Test("Only a TCC refusal reads as a denial")
    func recognisesDenial() {
        #expect(ScriptingNowPlayingSource.indicatesAutomationDenial(
            "execution error: Not authorized to send Apple events to Music. (-1743)"
        ))
        #expect(ScriptingNowPlayingSource.indicatesAutomationDenial("Music got an error: -1743"))
        #expect(ScriptingNowPlayingSource.indicatesAutomationDenial(
            "execution error: Music got an error: Can’t get current track. (-1728)"
        ) == false)
        #expect(ScriptingNowPlayingSource.indicatesAutomationDenial("") == false)
    }
}
