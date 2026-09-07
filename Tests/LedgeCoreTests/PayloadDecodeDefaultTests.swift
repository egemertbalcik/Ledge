import Foundation
import Testing

@testable import LedgeCore

@Suite("Muted levels")
struct MutedLevelsTests {

    @Test("A muted output draws an empty bar, whatever the scalar says")
    func mutedShowsZero() {
        // macOS leaves the scalar volume where it was while muted; the bar has
        // to follow the mute, not the number.
        let muted = LevelsPayload(volume: 0.6, brightness: 0.5, isMuted: true)
        #expect(muted.displayedVolume == 0)
        #expect(muted.volume == 0.6, "the level it will return to is still remembered")
    }

    @Test("Unmuted draws the level it reports")
    func unmutedShowsLevel() {
        #expect(LevelsPayload(volume: 0.42, brightness: 0.5).displayedVolume == 0.42)
    }

    @Test("A payload written before mute existed decodes as unmuted")
    func decodesOlderPayload() throws {
        let json = #"{"volume":0.3,"brightness":0.8}"#.data(using: .utf8)!
        let payload = try JSONDecoder().decode(LevelsPayload.self, from: json)
        #expect(payload.isMuted == false)
        #expect(payload.displayedVolume == 0.3)
    }
}

/// The location arrow on the weather card is a claim about where the numbers
/// came from, so it defaults to the claim that is always safe to make: none.
@Suite("Weather location claim")
struct WeatherLocationClaimTests {

    @Test("A payload written before the flag existed claims no location")
    func decodesOlderPayload() throws {
        let json = #"{"temperatureCelsius":18.0,"symbolName":"cloud.fill","condition":"Cloudy","city":"Lisbon","isDay":true,"hourly":[],"fetchedAt":0}"#
            .data(using: .utf8)!
        let payload = try JSONDecoder().decode(WeatherPayload.self, from: json)
        #expect(!payload.usesDeviceLocation)
    }

    @Test("A typed city claims nothing by default")
    func defaultsToFalse() {
        #expect(!WeatherPayload(temperatureCelsius: 18).usesDeviceLocation)
    }

    @Test("The flag survives a round trip")
    func roundTrips() throws {
        let payload = WeatherPayload(temperatureCelsius: 18, usesDeviceLocation: true)
        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(WeatherPayload.self, from: data).usesDeviceLocation)
    }
}

/// The compact ear draws a countdown as a dial, and what it trims the arc to is
/// `1 - progress`. That expression is the whole contract between the payload and
/// the drawing, so it is worth pinning: a dial that fills as the time runs out
/// is the same code with the sign flipped.
@Suite("Countdown dial fraction")
struct CountdownDialFractionTests {

    private func remainingFraction(remaining: TimeInterval, total: TimeInterval) -> Double {
        1 - TimerPayload(label: "Focus", remaining: remaining, total: total, isRunning: true).progress
    }

    @Test("a fresh session has a full ring")
    func fresh() {
        #expect(remainingFraction(remaining: 1500, total: 1500) == 1)
    }

    @Test("the ring empties as the time goes")
    func empties() {
        #expect(remainingFraction(remaining: 750, total: 1500) == 0.5)
        #expect(abs(remainingFraction(remaining: 150, total: 1500) - 0.1) < 0.000_001)
    }

    @Test("a finished session has no ring left")
    func finished() {
        #expect(remainingFraction(remaining: 0, total: 1500) == 0)
    }

    @Test("overrun and underrun stay on the dial")
    func clamped() {
        // The countdown can be republished a beat late, and a negative
        // remaining must not wind the arc backwards past empty.
        #expect(remainingFraction(remaining: -30, total: 1500) == 0)
        #expect(remainingFraction(remaining: 3000, total: 1500) == 1)
    }

    @Test("a stopwatch has no total and so no arc")
    func stopwatch() {
        // Zero total is the stopwatch's signature; the ear keeps its glyph
        // there, and this is what tells it apart.
        #expect(remainingFraction(remaining: 42, total: 0) == 1)
    }
}

/// Clicking the media card brings its app forward — but only if there is an
/// app, rather than a page inside a browser.
@Suite("Whose media is it")
struct MediaOwnerTests {

    @Test("A player's own card is a doorway")
    func playersOpen() {
        for player in ["com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.colliderli.iina"] {
            #expect(MediaOwner.isOpenableApp(bundleID: player), "\(player) should open")
        }
    }

    @Test("A browser's is not")
    func browsersDoNot() {
        // The browser may be on another Space showing a different tab, so
        // "open" would promise something this app cannot deliver.
        for browser in [
            "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
            "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
        ] {
            #expect(!MediaOwner.isOpenableApp(bundleID: browser), "\(browser) should not open")
        }
    }

    @Test("A browser's audio helper is not either")
    func helpersDoNotOpen() {
        // A video in Safari can be attributed to these; the adapter resolves
        // them to the parent, and this is the belt to that pair of braces.
        #expect(!MediaOwner.isOpenableApp(bundleID: "com.apple.WebKit.GPU"))
        #expect(!MediaOwner.isOpenableApp(bundleID: "com.apple.WebKit.WebContent"))
    }

    @Test("A source that will not name itself opens nothing")
    func unnamedOpensNothing() {
        #expect(!MediaOwner.isOpenableApp(bundleID: ""))
    }

    @Test("A payload that says nothing is not a doorway")
    func payloadDefaultsClosed() throws {
        let json = #"{"title":"T","artist":"A","album":"","isPlaying":true,"elapsed":0,"duration":0,"sourceName":"S","accent":{"red":0.5,"green":0.5,"blue":0.5},"kind":"audio"}"#
            .data(using: .utf8)!
        let payload = try JSONDecoder().decode(NowPlayingPayload.self, from: json)
        #expect(!payload.ownerIsApp)
        #expect(!NowPlayingPayload(title: "T", artist: "A").ownerIsApp)
    }
}

