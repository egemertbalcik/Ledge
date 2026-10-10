import AppKit
import CoreGraphics
import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

/// Answers whatever the test last set.
@MainActor
private final class StagedSource: NowPlayingSource {
    let identifier = "staged"
    var isAvailable = true
    var value: NowPlayingSnapshot?
    private(set) var calls = 0
    init(_ value: NowPlayingSnapshot? = nil) { self.value = value }
    func snapshot() async -> NowPlayingSnapshot? {
        calls += 1
        return value
    }
}

/// A small solid PNG, so the colour derivation runs against a real decoded
/// image and two revisions are distinguishable by their bytes.
private func cover(red: UInt8, blue: UInt8) throws -> Data {
    let side = 8
    var pixels = [UInt8]()
    for _ in 0..<(side * side) { pixels.append(contentsOf: [red, 20, blue, 255]) }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(
        width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
    return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
}

@MainActor
private func settle(until condition: () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// A cover is not a song.
///
/// The two were one field for a while, and it went wrong in both directions at
/// once: a cover arriving a poll late — or being replaced with a better one —
/// read as a track change, and two songs from one album, sharing a cover, read
/// as the same song.
@Suite("Which song, and which cover, are different questions", .serialized)
@MainActor
struct MediaIdentityTests {

    private func adapterLine(
        title: String,
        artworkID: String?,
        playing: Bool = true
    ) throws -> NowPlayingSnapshot {
        var json: [String: Any] = [
            "kind": "now", "playing": playing, "title": title,
            "artist": "Same artist", "album": "Same album",
            "duration": 200, "elapsed": 20, "bundleID": "org.videolan.vlc",
        ]
        if let artworkID { json["artworkID"] = artworkID }
        let line = try JSONSerialization.data(withJSONObject: json)
        let payload = try JSONDecoder().decode(AdapterPayload.self, from: line)
        return try #require(payload.snapshot(at: 1000))
    }

    private func provider(
        _ source: StagedSource,
        artwork: ArtworkLoader = ArtworkLoader(),
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source, artwork: artwork,
            playingInterval: 3600, idleInterval: 3600, playbackWatcher: nil, now: now
        )
    }

    private func payloads(_ stream: AsyncStream<ProviderEvent>) async -> [NowPlayingPayload] {
        var values: [NowPlayingPayload] = []
        for await event in stream {
            if case .publish(let activity) = event,
               case .nowPlaying(let payload) = activity.payload {
                values.append(payload)
            }
        }
        return values
    }

    // MARK: - A cover arriving, or being replaced, is not a new song

    @Test("A cover arriving late, or being replaced, leaves the song's identity alone")
    func coverDoesNotInventASong() throws {
        let bare = try adapterLine(title: "Same song", artworkID: nil)
        let withCover = try adapterLine(title: "Same song", artworkID: "cover-1")
        let revised = try adapterLine(title: "Same song", artworkID: "cover-2")

        #expect(bare.trackKey == withCover.trackKey, "a cover arriving looked like a track change")
        #expect(withCover.trackKey == revised.trackKey, "a better cover looked like a track change")

        // And the cover is still identified — on its own axis, which is what
        // lets a revision replace the image without moving the song.
        #expect(bare.coverKey != withCover.coverKey)
        #expect(withCover.coverKey != revised.coverKey)
    }

    // MARK: - Two songs from one album are two songs

    @Test("A different paused song sharing the album's cover does not inherit its retirement")
    func sharedCoverDoesNotShareRetirement() async throws {
        var clock: TimeInterval = 1000
        var old = try adapterLine(title: "Old song", artworkID: "album-cover", playing: false)
        old.isPlaying = false
        let source = StagedSource(old)
        let provider = provider(source, now: { clock })

        let stream = provider.start()
        #expect(await settle { source.calls >= 1 })

        // Old song sits long enough to lose its card.
        clock += NowPlayingProvider.pausedCardLifetime + 1
        await provider.refreshNow()

        // Somebody comes back and leaves a *different* song paused — one that
        // happens to share the album's cover.
        var new = try adapterLine(title: "New song", artworkID: "album-cover", playing: false)
        new.isPlaying = false
        source.value = new
        await provider.refreshNow()
        provider.stop()

        let titles = await payloads(stream).map(\.title)
        try #require(titles.first == "Old song")
        #expect(
            titles.last == "New song",
            "the retired song's cover kept a different song off the card: \(titles)"
        )
    }

    // MARK: - A better cover for the same song replaces the one on screen

    @Test("A revised cover for the same song replaces the cached one")
    func revisedCoverReplacesTheOldOne() async throws {
        let red = try cover(red: 220, blue: 10)
        let blue = try cover(red: 10, blue: 220)

        func song(_ bytes: Data, revision: String) -> NowPlayingSnapshot {
            NowPlayingSnapshot(
                title: "Same song", artist: "Artist", album: "Album", isPlaying: true,
                elapsed: 20, duration: 200, appName: "Music", appBundleID: "com.apple.Music",
                trackKey: "stable-song", artworkID: revision, artworkData: bytes
            )
        }

        let loader = ArtworkLoader()
        let source = StagedSource(song(red, revision: "red"))
        let provider = provider(source, artwork: loader)

        let stream = provider.start()
        #expect(await settle { source.calls >= 1 })

        source.value = song(blue, revision: "blue")
        await provider.refreshNow()
        provider.stop()

        let published = await payloads(stream)
        let last = try #require(published.last)
        #expect(last.title == "Same song")
        #expect(last.artworkData == blue, "the card kept the first cover for the life of the song")
        // And the song never changed underneath it, which is the half that
        // keeps the art from turning over for a new picture.
        #expect(Set(published.compactMap(\.itemKey)).count == 1)
    }

    // MARK: - A cover belongs to the song it came with

    @Test("A new song does not borrow the cover of the one before it")
    func coverIsNotBorrowedAcrossSongs() async throws {
        // The moment after a skip: the scripting side already names the new
        // song while the adapter still names the old one and is holding its
        // art. Borrowing across that gap produced new metadata with the
        // previous song's cover — which was then cached under the new song.
        let oldCover = try cover(red: 220, blue: 10)
        let adapter = StagedSource(NowPlayingSnapshot(
            title: "Old song", artist: "Artist", album: "Album", isPlaying: true,
            elapsed: 20, duration: 200, appName: "Music", appBundleID: "com.apple.Music",
            trackKey: "adapter-old", artworkID: "old-cover", artworkData: oldCover
        ))
        let scripted = NowPlayingSnapshot(
            title: "New song", artist: "Artist", album: "Album", isPlaying: true,
            elapsed: 1, duration: 180, appName: "Music", appBundleID: "com.apple.Music",
            trackKey: "script-new"
        )
        let source = CompositeNowPlayingSource(
            adapter: adapter, scripting: StagedSource(),
            scriptedSnapshot: { _ in scripted }, scriptingHandles: { _ in true },
            playbackWatcher: nil
        )

        let answer = await source.snapshot()
        try #require(answer?.title == "New song")
        #expect(answer?.artworkData == nil, "the new song is carrying the previous song's cover")
    }

    @Test("A cover is still borrowed when both sides describe the same song")
    func coverIsBorrowedWhenTheyAgree() async throws {
        // The borrow exists for Music, whose scripting dictionary exposes no
        // artwork URL at all. Refusing every borrow would take its covers away.
        let art = try cover(red: 10, blue: 220)
        let adapter = StagedSource(NowPlayingSnapshot(
            title: "Same song", artist: "Artist", album: "Album", isPlaying: true,
            elapsed: 20, duration: 200, appName: "Music", appBundleID: "com.apple.Music",
            trackKey: "adapter-id", artworkID: "cover", artworkData: art
        ))
        let scripted = NowPlayingSnapshot(
            title: "Same song", artist: "Artist", album: "Album", isPlaying: true,
            elapsed: 20, duration: 200, appName: "Music", appBundleID: "com.apple.Music",
            trackKey: "script-id"
        )
        let source = CompositeNowPlayingSource(
            adapter: adapter, scripting: StagedSource(),
            scriptedSnapshot: { _ in scripted }, scriptingHandles: { _ in true },
            playbackWatcher: nil
        )

        let answer = await source.snapshot()
        #expect(answer?.title == "Same song")
        #expect(answer?.artworkData == art, "Music's covers were refused along with the wrong ones")
    }

    @Test("A field one side left blank is not a contradiction")
    func missingMetadataIsNotDisagreement() {
        let full = NowPlayingSnapshot(
            title: "Song", artist: "Artist", album: "Album",
            appName: "Music", appBundleID: "com.apple.Music"
        )
        let sparse = NowPlayingSnapshot(
            title: "Song", artist: "", album: "",
            appName: "Music", appBundleID: "com.apple.Music"
        )
        #expect(!CompositeNowPlayingSource.contradict(full, sparse))

        let different = NowPlayingSnapshot(
            title: "Another song", artist: "Artist", album: "Album",
            appName: "Music", appBundleID: "com.apple.Music"
        )
        #expect(CompositeNowPlayingSource.contradict(full, different))
    }
}
