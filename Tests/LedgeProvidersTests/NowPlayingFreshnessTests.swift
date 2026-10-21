import AppKit
import CoreGraphics
import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

/// A source whose answers the test decides, and whose reads it can hold open.
///
/// Holding one open is the whole point: the three paths that read a player —
/// the steady poll, the burst after a press, and the immediate refresh — all
/// run at once in real use, and `osascript` takes long enough that their
/// answers come back in a different order from the one they were asked in.
@MainActor
private final class GatedNowPlayingSource: NowPlayingSource, NowPlayingChangePublishing {

    let identifier = "gated"
    var isAvailable = true
    var onChange: (() -> Void)?

    var current: NowPlayingSnapshot?
    private(set) var calls = 0

    /// Which read is to be held open, and the continuation holding it.
    private var holdCall: Int?
    private var held: CheckedContinuation<NowPlayingSnapshot?, Never>?

    var isHolding: Bool { held != nil }

    func hold(call: Int) { holdCall = call }

    /// Lets the held read answer, with a reading from before whatever has
    /// happened since.
    func release(_ snapshot: NowPlayingSnapshot?) {
        let continuation = held
        held = nil
        holdCall = nil
        continuation?.resume(returning: snapshot)
    }

    func snapshot() async -> NowPlayingSnapshot? {
        calls += 1
        if calls == holdCall {
            return await withCheckedContinuation { held = $0 }
        }
        return current
    }
}

/// Reads a provider's stream while it runs, so a test can wait for the
/// publication it is about rather than for a fixed number of turns.
@MainActor
private final class Publications {

    private(set) var payloads: [NowPlayingPayload] = []
    private(set) var retractions = 0
    private var task: Task<Void, Never>?

    func read(_ stream: AsyncStream<ProviderEvent>) {
        task = Task { @MainActor [weak self] in
            for await event in stream {
                switch event {
                case .publish(let activity):
                    if case .nowPlaying(let payload) = activity.payload {
                        self?.payloads.append(payload)
                    }
                case .retract:
                    self?.retractions += 1
                default:
                    break
                }
            }
        }
    }

    /// Hands the run loop back until the condition holds.
    ///
    /// Every step being waited on is a scheduler step — a main-actor hop, or
    /// an image decoded on a utility task — but a utility task is not done in
    /// any number of yields, and ten thousand of them ran out on a loaded
    /// machine. So there is no count: the suite's time limit is what turns a
    /// test that will never pass into a failure rather than a hang.
    @discardableResult
    func waiting(for condition: () -> Bool) async -> Bool {
        while !condition() {
            do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
        }
        return true
    }

    func finish() async {
        await task?.value
    }

    var titles: [String] { payloads.map(\.title) }
}

@Suite("A media reading that arrives late", .serialized, .timeLimit(.minutes(10)))
@MainActor
struct NowPlayingFreshnessTests {

    private func track(
        _ title: String,
        playing: Bool = true,
        cover: URL? = nil
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title, artist: "Artist", isPlaying: playing,
            elapsed: 20, duration: 300,
            appName: "Spotify", appBundleID: "com.spotify.client",
            trackKey: title, artworkURL: cover
        )
    }

    /// Intervals long enough that nothing polls on its own: every read in
    /// these tests is one the test asked for.
    private func provider(
        _ source: GatedNowPlayingSource,
        artwork: ArtworkLoader = ArtworkLoader()
    ) -> NowPlayingProvider {
        NowPlayingProvider(
            source: source,
            artwork: artwork,
            playingInterval: 3600,
            idleInterval: 3600,
            playbackWatcher: nil
        )
    }

    @Test("It must not replace the reading that overtook it")
    func lateReadingDoesNotWin() async {
        let source = GatedNowPlayingSource()
        let provider = provider(source)
        let seen = Publications()
        seen.read(provider.start())
        #expect(await seen.waiting { source.calls == 1 }, "the opening poll never ran")

        // A read that goes slowly — a player that is busy answering its
        // scripting bridge — started before anything else happened.
        source.hold(call: 2)
        let slow = Task { await provider.refreshNow() }
        #expect(await seen.waiting { source.isHolding })

        // Meanwhile the user presses something, and that read is quick.
        source.current = track("New")
        await provider.refreshNow()
        #expect(await seen.waiting { seen.titles.last == "New" }, "the press never reached the card")

        // Only now does the slow one answer, with what was playing before.
        source.release(track("Old"))
        await slow.value
        provider.stop()
        await seen.finish()

        #expect(
            seen.titles == ["New"],
            "a reading from before the press was published after it: \(seen.titles)"
        )
    }

    @Test("An old stream ending must not stop the provider that replaced it")
    func restartSurvivesTheOldStream() async {
        let source = GatedNowPlayingSource()
        source.current = track("Before")
        let provider = provider(source)

        let old = Publications()
        old.read(provider.start())
        #expect(await old.waiting { source.calls >= 1 })

        provider.stop()
        source.current = track("After")
        let fresh = Publications()
        fresh.read(provider.start())

        // Until the old stream's termination handler has actually run. A task
        // queued behind it and twenty yields were a guess that it had, and
        // when the guess was short the test passed without the handler having
        // had its go at the wrong run.
        #expect(await fresh.waiting { provider.terminationsHandled >= 1 },
                "the old stream's termination was never handled")

        await provider.refreshNow()
        provider.stop()
        await old.finish()
        await fresh.finish()

        #expect(
            fresh.titles.contains("After"),
            "the restarted provider published nothing: \(fresh.titles)"
        )
    }

    @Test("A cover that finishes downloading puts itself on the card")
    func artworkCompletionRepublishes() async {
        let cover = URL(string: "https://example.invalid/cover.png")!
        let bytes = Self.solidPNG()
        let loader = ArtworkLoader(fetch: { url in
            (bytes, URLResponse(
                url: url, mimeType: "image/png",
                expectedContentLength: bytes.count, textEncodingName: nil
            ))
        })

        let source = GatedNowPlayingSource()
        // Paused on purpose: this is the case where nothing else was coming.
        // A playing track is re-read every second and would pick the cover up
        // by accident, so the fault only showed on a card that had to wait out
        // the idle interval — which here is an hour.
        source.current = track("Cover", playing: false, cover: cover)

        let provider = provider(source, artwork: loader)
        let seen = Publications()
        seen.read(provider.start())

        #expect(
            await seen.waiting { seen.payloads.contains { $0.artworkData != nil } },
            "the cover reached the cache and the card was never told"
        )
        provider.stop()
        await seen.finish()

        #expect(seen.payloads.first?.artworkData == nil, "the first card cannot have had it yet")
        #expect(seen.payloads.last?.artworkData != nil)
    }

    /// A small solid PNG, built here so the colour derivation runs against a
    /// real decoded image rather than a hand-made buffer.
    private static func solidPNG() -> Data {
        let side = 8
        var pixels = [UInt8]()
        for _ in 0..<(side * side) { pixels.append(contentsOf: [200, 40, 40, 255]) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: side, height: side,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent
              ),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return Data() }
        return data
    }
}
