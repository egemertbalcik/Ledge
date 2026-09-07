import AppKit
import CoreGraphics
import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

@Suite("Now playing parsing")
@MainActor
struct ScriptingParsingTests {

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

    @Test("Empty output means nothing is playing")
    func emptyOutput() {
        #expect(ScriptingNowPlayingSource.parse("", player: spotify) == nil)
    }

    @Test("Truncated output is rejected rather than half-parsed")
    func truncatedOutput() {
        #expect(ScriptingNowPlayingSource.parse("a\u{1F}b", player: spotify) == nil)
    }

    @Test("Spotify durations arrive in milliseconds")
    func spotifyMilliseconds() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "214000", "42.5", "playing", "track:1", ""),
            player: spotify
        ))
        #expect(snapshot.duration == 214)
        #expect(snapshot.elapsed == 42.5)
        #expect(snapshot.isPlaying)
    }

    @Test("Music durations arrive in seconds")
    func musicSeconds() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "214", "42", "playing", "1234"),
            player: music
        ))
        #expect(snapshot.duration == 214)
    }

    @Test("A comma decimal separator is handled")
    func localeDecimalSeparator() throws {
        // AppleScript formats reals in the user's locale, so a machine set to a
        // comma-decimal locale returns "214,5" and a naive Double() gives nil.
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "214500", "42,5", "playing", "id", ""),
            player: spotify
        ))
        #expect(snapshot.elapsed == 42.5)
        #expect(snapshot.duration == 214.5)
    }

    @Test("A paused player is reported, not discarded")
    func pausedState() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "1000", "0", "paused", "id", ""),
            player: spotify
        ))
        #expect(!snapshot.isPlaying)
    }

    @Test("A position past the end cannot make progress exceed 1")
    func overshootClamped() throws {
        // Players briefly report a position beyond the duration while changing
        // tracks; unclamped, the scrub bar runs off its own track.
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "100000", "150", "playing", "id", ""),
            player: spotify
        ))
        #expect(snapshot.duration >= snapshot.elapsed)

        let payload = NowPlayingPayload(
            title: snapshot.title,
            artist: snapshot.artist,
            elapsed: snapshot.elapsed,
            duration: snapshot.duration
        )
        #expect(payload.progress <= 1)
    }

    @Test("A title containing separators survives, since fields use a unit separator")
    func awkwardTitle() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("A, B - C | D", "Artist", "Album", "1000", "0", "playing", "id", ""),
            player: spotify
        ))
        #expect(snapshot.title == "A, B - C | D")
    }

    @Test("An empty artwork field yields no URL rather than a bogus one")
    func emptyArtworkURL() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "1000", "0", "playing", "id", ""),
            player: spotify
        ))
        #expect(snapshot.artworkURL == nil)
    }

    @Test("The track key includes the app, so two players cannot collide")
    func trackKeyNamespaced() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "1000", "0", "playing", "shared-id", ""),
            player: spotify
        ))
        #expect(snapshot.trackKey.hasPrefix("com.spotify.client|"))
    }
}

@Suite("Artwork colour")
struct ArtworkColourTests {

    @Test("A dark colour is raised to a legible brightness without shifting hue")
    func brightenPreservesHue() {
        let dark = AccentColor(red: 0.1, green: 0.05, blue: 0.025)
        let bright = ArtworkLoader.brighten(dark)
        #expect(max(bright.red, bright.green, bright.blue) > 0.5)
        // Ratios preserved means the hue is unchanged.
        #expect(abs((bright.green / bright.red) - (dark.green / dark.red)) < 0.001)
    }

    @Test("An already bright colour is left alone")
    func brightenLeavesBrightAlone() {
        let bright = AccentColor(red: 0.9, green: 0.2, blue: 0.2)
        #expect(ArtworkLoader.brighten(bright) == bright)
    }

    @Test("Pure black cannot be scaled, and is returned unchanged rather than NaN")
    func brightenBlackIsSafe() {
        let black = AccentColor(red: 0, green: 0, blue: 0)
        let result = ArtworkLoader.brighten(black)
        #expect(result == black)
        #expect(!result.red.isNaN)
    }

    @Test("Unreadable data yields no colour instead of crashing")
    func rejectsGarbage() {
        #expect(ArtworkLoader.dominantColor(of: Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test("A solid red image resolves to red")
    func solidColour() throws {
        let data = try #require(Self.solidImagePNG(red: 1, green: 0, blue: 0))
        let colour = try #require(ArtworkLoader.dominantColor(of: data))
        #expect(colour.red > 0.8)
        #expect(colour.green < 0.2)
        #expect(colour.blue < 0.2)
    }

    /// Builds a small solid-colour PNG in memory, so the colour maths is tested
    /// against a real decoded image rather than a hand-made pixel buffer.
    private static func solidImagePNG(red: Double, green: Double, blue: Double) -> Data? {
        let side = 16
        var pixels = [UInt8]()
        for _ in 0..<(side * side) {
            pixels.append(UInt8(red * 255))
            pixels.append(UInt8(green * 255))
            pixels.append(UInt8(blue * 255))
            pixels.append(255)
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else { return nil }

        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
    }
}

@Suite("Now playing payload")
struct NowPlayingPayloadTests {

    @Test("Equality ignores the artwork bytes and uses the key")
    func equalityUsesArtworkKey() {
        // This comparison runs several times a second; comparing cover-image
        // bytes on every poll would be pure waste.
        let a = NowPlayingPayload(
            title: "t", artist: "a",
            artworkKey: "k", artworkData: Data(repeating: 1, count: 1000)
        )
        let b = NowPlayingPayload(
            title: "t", artist: "a",
            artworkKey: "k", artworkData: Data(repeating: 2, count: 1000)
        )
        #expect(a == b)
    }

    @Test("A different track key is a different payload")
    func differentKeyDiffers() {
        let a = NowPlayingPayload(title: "t", artist: "a", artworkKey: "one")
        let b = NowPlayingPayload(title: "t", artist: "a", artworkKey: "two")
        #expect(a != b)
    }

    @Test("Artwork arriving is a change, so the card redraws")
    func artworkArrivalIsAChange() {
        let without = NowPlayingPayload(title: "t", artist: "a", artworkKey: "k")
        let with = NowPlayingPayload(
            title: "t", artist: "a",
            artworkKey: "k", artworkData: Data([1, 2, 3])
        )
        #expect(without != with)
    }

    @Test("Progress is guarded against an unknown duration")
    func progressGuarded() {
        #expect(NowPlayingPayload(title: "t", artist: "a", elapsed: 5, duration: 0).progress == 0)
        #expect(NowPlayingPayload(title: "t", artist: "a", elapsed: 50, duration: 100).progress == 0.5)
    }
}
