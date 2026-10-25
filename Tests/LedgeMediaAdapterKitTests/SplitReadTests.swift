import Foundation
import LedgeMediaAdapterKit
import Testing

/// The artwork read that follows a metadata read must be about the same item.
///
/// Found by review (R5): the player moved on between the two reads, and the
/// second reply's cover — the next item's — went out under the first item's
/// title and was remembered as its image. The dictionaries here stand in for
/// MediaRemote's two replies, the way the reviewer's fake getter did.
@Suite("Matching the artwork read to the metadata read")
struct SplitReadTests {

    private static let keys = ["unique", "title", "artist", "album"]
    private static let systemArt = "artSystemID"

    private static let metadata: [String: String] = [
        "title": "A", "unique": "A-key", "artist": "Band", "artSystemID": "A-image",
    ]

    private func same(_ full: [String: Any]?) -> Bool {
        ledge_artwork_same_item(Self.metadata, full, Self.keys, Self.systemArt)
    }

    @Test("The same item, with its bytes, matches")
    func sameItemMatches() {
        #expect(same([
            "title": "A", "unique": "A-key", "artist": "Band", "artSystemID": "A-image", "art": Data([1, 2]),
        ]))
        // The system's artwork name only counts when both replies carry one.
        #expect(same(["title": "A", "unique": "A-key", "artist": "Band"]))
    }

    @Test("A reply about the next item is refused")
    func nextItemRefused() throws {
        let next: [String: Any] = ["title": "B", "unique": "B-key", "artist": "Band", "artSystemID": "B-image"]
        try #require(next["title"] as? String != Self.metadata["title"], "it really is another item")
        #expect(!same(next))
        #expect(!same(["title": "A", "unique": "B-key", "artist": "Band"]), "same title, another item")
        #expect(!same(["title": "A", "unique": "A-key", "artist": "Band", "artSystemID": "B-image"]),
                "same item named, another image")
        #expect(!same(["title": "A", "artist": "Band"]), "an identifier that vanished is not agreement")
        #expect(!same(nil))
    }

    @Test("The adapter checks the reply before it takes the bytes")
    func adapterUsesIt() throws {
        let adapter = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/LedgeMediaAdapter/LedgeMediaAdapter.m"),
            encoding: .utf8
        )
        let read = try #require(adapter.range(of: "static BOOL ReadArtwork(NSDictionary *info, NSDictionary *client) {"))
        let body = adapter[read.upperBound...].prefix(2400)
        let check = try #require(body.range(of: "if (!ledge_artwork_same_item(info, full, IdentityKeys(), gKeyArtworkIdentifier)) {"))
        let take = try #require(body.range(of: "TakeArtwork(gKeyArtworkData ? full[gKeyArtworkData] : nil);"))
        let held = try #require(body.range(of: "gHeldTrackKey = trackKey;"))
        #expect(check.upperBound <= take.lowerBound, "checked before the bytes are taken")
        #expect(check.upperBound <= held.lowerBound, "and before the item is remembered")
    }

    /// The first refresh of a stream runs on the queue the polls run on, so
    /// it cannot overlap one (XV-3).
    @Test("The first stream refresh is queued with the polls, not run on the entry thread")
    func firstRefreshIsSerialised() throws {
        let adapter = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/LedgeMediaAdapter/LedgeMediaAdapter.m"),
            encoding: .utf8
        )
        let run = try #require(adapter.range(of: "        CFRunLoopRun();"))
        let before = adapter[..<run.lowerBound].suffix(300)
        #expect(before.contains("dispatch_async(gQueue, ^{ Refresh(); });"))
        #expect(!before.hasSuffix("        Refresh();\n"))
    }
}
