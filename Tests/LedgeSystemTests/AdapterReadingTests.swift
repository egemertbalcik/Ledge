import Foundation
import Synchronization
import Testing

@testable import LedgeSystem

/// One `now` line as the adapter writes it.
private func nowLine(
    trackID: String = "13958813", artworkID: String? = nil, artwork: Data? = nil
) -> AdapterPayload {
    var payload = AdapterPayload()
    payload.kind = .now
    payload.playing = true
    payload.title = "A video"
    payload.trackID = trackID
    payload.bundleID = "com.apple.WebKit.GPU"
    payload.parentBundleID = "com.apple.Safari"
    payload.artworkID = artworkID
    payload.artwork = artwork
    payload.artworkMIME = artwork == nil ? nil : "image/jpeg"
    return payload
}

private let frame = Data([0xFF, 0xD8, 0xFF, 0x01])
private let poster = Data([0xFF, 0xD8, 0xFF, 0x02])

@Suite("Covers the adapter has already sent")
@MainActor
struct AdapterCoverCacheTests {

    private func source() -> MediaRemoteAdapterSource {
        MediaRemoteAdapterSource(dylibURL: URL(fileURLWithPath: "/nonexistent"))
    }

    /// Safari flips between a video's frame and its poster. The adapter now
    /// sends each image once and afterwards names it by id alone.
    @Test("A line naming an artwork id already seen, with no bytes, shows that id's image")
    func namedIDGetsItsOwnBytes() throws {
        let source = source()
        source.receive([nowLine(artworkID: "A", artwork: frame)], from: 0)
        source.receive([nowLine(artworkID: "B", artwork: poster)], from: 0)
        try #require(source.latest?.artworkID == "B")
        try #require(source.latest?.artwork == poster)

        source.receive([nowLine(artworkID: "A")], from: 0)
        #expect(source.latest?.artworkID == "A")
        #expect(source.latest?.artwork == frame, "the frame, not the poster held from the line before")
        #expect(source.latest?.artworkMIME == "image/jpeg")
    }

    @Test("A line that stops mentioning artwork keeps the held cover")
    func silenceKeepsCover() throws {
        let source = source()
        source.receive([nowLine(artworkID: "A", artwork: frame)], from: 0)
        try #require(source.latest?.artwork == frame)

        source.receive([nowLine()], from: 0)
        #expect(source.latest?.artworkID == "A")
        #expect(source.latest?.artwork == frame)
    }

    @Test("A different track does not inherit a cover it never named")
    func otherTrackDoesNotInherit() throws {
        let source = source()
        source.receive([nowLine(artworkID: "A", artwork: frame)], from: 0)
        try #require(source.latest?.artwork == frame)

        source.receive([nowLine(trackID: "other")], from: 0)
        #expect(source.latest?.artwork == nil)
    }

    /// The adapter remembers four ids and ages them by use; the cache must
    /// still hold any of those four, however the uses interleave.
    /// Found by review (R3), through the real receive path: a second player
    /// whose item happens to share the first one's id got its cover.
    @Test("Another player with an equal track id does not inherit the cover")
    func otherPlayerSameIDDoesNotInherit() throws {
        let source = source()
        source.receive([nowLine(trackID: "1", artworkID: "A", artwork: frame)], from: 0)
        try #require(source.latest?.artwork == frame)

        var other = nowLine(trackID: "1")
        other.title = "Another film"
        other.bundleID = "org.videolan.vlc"
        other.parentBundleID = nil
        source.receive([other], from: 0)
        try #require(source.latest?.bundleID == "org.videolan.vlc", "the second player's line is held")
        #expect(source.latest?.artwork == nil)
        #expect(source.latest?.artworkID == nil)
    }

    @Test("Any id the adapter would not resend is still held")
    func outlivesTheAdaptersMemory() throws {
        var cache = AdapterCoverCache()
        _ = cache.fill(nowLine(artworkID: "keep", artwork: frame))
        // "keep" stays among the adapter's four most recently named ids the
        // whole way through, while more new ids go by than the cache holds.
        for index in 0..<(AdapterCoverCache.capacity * 2) {
            _ = cache.fill(nowLine(artworkID: "new\(index)", artwork: poster))
            let named = cache.fill(nowLine(artworkID: "keep"))
            try #require(named.artworkID == "keep")
            #expect(named.artwork == frame, "lost after \(index + 1) new ids")
        }
        #expect(AdapterCoverCache.capacity >= 4, "at least the adapter's LedgeArtworkRecentCapacity")
    }

    @Test("Lines from a stopped session are ignored")
    func stragglersIgnored() {
        let source = source()
        source.receive([nowLine(artworkID: "A", artwork: frame)], from: 41)
        #expect(source.latest == nil)
    }
}

/// Mutable state a test can share with the reader's consumer, which runs off
/// the main actor.
private final class DecodedLines: Sendable {
    let payloads = Mutex<[AdapterPayload]>([])
    var count: Int { payloads.withLock { $0.count } }
}

/// A `now` line as the adapter serialises it, newline included.
private func wireLine(trackID: String, artworkID: String? = nil, artwork: Data? = nil) -> Data {
    var object: [String: Any] = [
        "adapter": 1, "ok": true, "kind": "now", "playing": true, "title": "A video",
        "trackID": trackID, "bundleID": "com.apple.WebKit.GPU", "parentBundleID": "com.apple.Safari",
    ]
    if let artworkID { object["artworkID"] = artworkID }
    if let artwork {
        object["artwork"] = artwork.base64EncodedString()
        object["artworkMIME"] = "image/jpeg"
    }
    var line = try! JSONSerialization.data(withJSONObject: object)
    line.append(0x0A)
    return line
}

/// A single line carrying `artworkBytes` bytes of artwork, as the old adapter
/// wrote a Safari video frame: one line, megabytes long.
private func artworkLine(artworkBytes: Int) -> Data {
    wireLine(trackID: "13958813", artworkID: "16d7dcb09e84c6ab",
             artwork: Data(repeating: 0x5A, count: artworkBytes))
}

private func chunks(of data: Data, size: Int) -> [Data] {
    stride(from: 0, to: data.count, by: size).map { data[$0..<min($0 + size, data.count)] }
}

@Suite("Reading the adapter's pipe")
struct AdapterLineReaderTests {

    /// Proof that the reading happens somewhere else: the main actor is held
    /// the whole time, and the line is decoded anyway. Were the reader on the
    /// main actor, nothing could arrive until it was let go.
    ///
    /// Not a ticker measuring gaps on the main actor. The test process shares
    /// one main actor between every suite, and other tests hold it for seconds
    /// at a time, so a gap measured there belongs to whichever test ran.
    @Test("A five-megabyte line is decoded while the main actor is busy")
    @MainActor
    func decodesOffMain() throws {
        let line = artworkLine(artworkBytes: 3_700_000)
        let pieces = chunks(of: line, size: 16 * 1024)
        try #require(line.count > 4_900_000, "the line must be as long as the one that stalled Ledge")
        try #require(pieces.count >= 300)

        let received = DecodedLines()
        let reader = AdapterLineReader { payloads in
            received.payloads.withLock { $0 += payloads }
        }
        defer { reader.finish() }
        for piece in pieces { reader.feed(piece) }

        // Hold the main thread, without yielding, until the line arrives or
        // five seconds pass.
        let deadline = ContinuousClock.now + .seconds(5)
        while received.count == 0, ContinuousClock.now < deadline { usleep(1_000) }

        #expect(received.count == 1)
        let payload = try #require(received.payloads.withLock { $0.first })
        #expect(payload.artworkID == "16d7dcb09e84c6ab")
        #expect(payload.artwork?.count == 3_700_000, "the base64 is decoded before the main actor sees it")
    }

    @Test("Lines come out in the order their chunks went in")
    func orderIsKept() async throws {
        let received = DecodedLines()
        let reader = AdapterLineReader { payloads in
            received.payloads.withLock { $0 += payloads }
        }
        defer { reader.finish() }

        // Many small chunks, so a reordering anywhere would show.
        var stream = Data()
        for index in 0..<500 { stream.append(wireLine(trackID: "\(index)")) }
        let pieces = chunks(of: stream, size: 11)
        try #require(pieces.count > 5_000, "lines must be split across many chunks")
        for piece in pieces { reader.feed(piece) }

        let deadline = ContinuousClock.now + .seconds(5)
        while received.count < 500, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let ids = received.payloads.withLock { $0.map(\.trackID) }
        #expect(ids == (0..<500).map { "\($0)" })
    }
}
