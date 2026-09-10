import Foundation
import Testing

@testable import LedgeSystem

/// What the loader remembers about a fetch that did not produce a cover.
///
/// The rule that matters: a *refusal* is worth remembering, because asking
/// again would get the same refusal and the card polls every second. A
/// *cancellation* is not — it says nothing about the URL, only that we stopped
/// caring, and remembering it held real covers back for ninety seconds.
@Suite("Artwork failures worth remembering")
@MainActor
struct ArtworkLoaderTests {

    private let url = URL(string: "https://example.invalid/cover.jpg")!

    /// Built outside the fetch closures: the closures are `@Sendable` and run
    /// off this actor, so they carry finished values rather than call back in.
    nonisolated private static func response(_ status: Int) -> URLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.invalid/cover.jpg")!,
            statusCode: status, httpVersion: nil, headerFields: nil
        )!
    }

    @Test("A cancelled fetch is not held against the cover")
    func cancellationIsNotAFailure() async {
        let loader = ArtworkLoader(fetch: { _ in throw CancellationError() })
        _ = await loader.load(key: "track", url: url)
        #expect(!loader.hasFailed(for: "track"), "cancelling is not a verdict on the URL")
    }

    @Test("A cancelled URL request is not held against it either")
    func urlCancellationIsNotAFailure() async {
        let loader = ArtworkLoader(fetch: { _ in throw URLError(.cancelled) })
        _ = await loader.load(key: "track", url: url)
        #expect(!loader.hasFailed(for: "track"))
    }

    @Test("A refusal is remembered, so the poll cannot hammer it")
    func refusalIsRemembered() async {
        let loader = ArtworkLoader(fetch: { _ in (Data(), Self.response(404)) })
        _ = await loader.load(key: "track", url: url)
        #expect(loader.hasFailed(for: "track"))
    }

    @Test("Bytes that are not an image are remembered too")
    func undecodableIsRemembered() async {
        let loader = ArtworkLoader(fetch: { _ in (Data("not an image".utf8), Self.response(200)) })
        _ = await loader.load(key: "track", url: url)
        #expect(loader.hasFailed(for: "track"))
    }

    /// The shape of the bug: the card republishes every second while a cover
    /// downloads, and a cancelled attempt must leave the next one free to run.
    @Test("A cancelled attempt leaves the next one free to succeed")
    func retryAfterCancellationWorks() async {
        let attempts = Attempts()
        let loader = ArtworkLoader(fetch: { _ in
            if await attempts.first() { throw CancellationError() }
            return (Self.pixel, Self.response(200))
        })
        _ = await loader.load(key: "track", url: url)
        let second = await loader.load(key: "track", url: url)
        #expect(second != nil, "the second attempt is not blocked by the first being cancelled")
    }

    private actor Attempts {
        private var count = 0
        func first() -> Bool {
            count += 1
            return count == 1
        }
    }

    /// A one-pixel PNG, so `dominantColor` has something real to read.
    nonisolated(unsafe) private static let pixel: Data = {
        let base64 = """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
            """
        return Data(base64Encoded: base64)!
    }()
}
