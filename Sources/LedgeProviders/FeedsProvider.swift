import Foundation
import LedgeCore
import LedgeSystem
import os

/// Publishes a card for every file in the feeds folder.
///
/// A standing card, like Weather and Notes: it has no expiry and it does not
/// announce itself. A feed is a status somebody else keeps, rewritten whenever
/// its producer likes, so a file changing is not an event — the card quietly
/// takes the new numbers. Retraction is the file going away, and nothing else.
///
/// What a file means is `FeedParser`'s; what is on the disk is the source's.
/// This is the part between: it reads the folder when the source says it may
/// have changed, publishes the feeds whose contents differ from the last
/// publish, and retracts the ones that are gone.
@MainActor
public final class FeedsProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "feeds")

    public let identifier = "feeds"

    private let source: any FeedSource
    private let now: () -> Date
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    /// What each standing card was last published as, by feed id. A rescan
    /// publishes only what differs, so a producer that rewrites an unchanged
    /// file every minute costs the queue nothing.
    private var standing: [String: FeedPayload] = [:]

    /// Why each file was last turned away, by file name. Logged when it
    /// changes and not on every scan, which would write the same line a minute
    /// for as long as a broken file sat in the folder.
    private var turnedAway: [String: String] = [:]

    /// The last feed each file parsed into, by file name. A file that is
    /// still there but cannot be read right now — caught half-written by a
    /// producer that writes in place — keeps showing what it last said,
    /// rather than its card vanishing under the pointer and coming back as a
    /// new one a moment later.
    private var lastGood: [String: FeedParser.Feed] = [:]

    /// How long a file may stay unreadable and still show what it last said.
    /// Long enough for a producer caught mid-write, and two of the folder's
    /// minute-long rescans. Past it the file is broken rather than busy — a
    /// producer that moved to a newer version, a file grown past the limit —
    /// and the card goes out of date, so it dims and gives up the ears
    /// instead of showing old numbers as current for good.
    public static let brokenGrace: TimeInterval = 2 * 60

    /// When each file first failed to read in its current run of failures,
    /// by file name. Cleared by the next good read.
    private var brokenSince: [String: TimeInterval] = [:]

    /// Each file as it was last read, and when Ledge first read it like that,
    /// by file name. The parser holds a file's dates to that moment, which
    /// stays put while the file does. A version is its date and its bytes
    /// both: a copy that keeps the old date (`cp -p`, `rsync -t`) is still new.
    private var firstSeen: [String: (modifiedAt: TimeInterval, data: Data?, at: TimeInterval)] = [:]

    public init(
        source: any FeedSource,
        now: @escaping () -> Date = { Date() }
    ) {
        self.source = source
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            self.source.startWatching { [weak self] files in self?.apply(files) }
        }
    }

    public func stop() {
        source.stopWatching()
        continuation?.finish()
        continuation = nil
        standing = [:]
        turnedAway = [:]
        lastGood = [:]
        brokenSince = [:]
        firstSeen = [:]
    }

    /// Brings the queue in line with what the folder holds.
    ///
    /// Everything is settled against one reading of the clock, so staleness is
    /// the same fact for every feed in a scan. It is also how a feed goes
    /// stale at all: nothing changes in the folder when a deadline passes, so
    /// the source's slow rescan is what lands here and notices.
    private func apply(_ files: [FeedFile]) {
        guard continuation != nil else { return }
        let moment = now()
        let unix = moment.timeIntervalSince1970

        var feeds: [String: FeedPayload] = [:]
        var rejected: [String: String] = [:]

        for file in files {
            if let seen = firstSeen[file.name], seen.modifiedAt == file.modifiedAt, seen.data == file.data {
                // The same version as last time.
            } else {
                firstSeen[file.name] = (file.modifiedAt, file.data, unix)
            }
            let seenAt = firstSeen[file.name]?.at ?? unix
            let result: Result<FeedParser.Feed, FeedParser.Rejection> = file.data.map {
                FeedParser.parse(
                    $0, fallbackID: file.name, fallbackUpdatedAt: file.modifiedAt,
                    now: unix, seenAt: seenAt
                )
            } ?? .failure(.oversize(bytes: file.byteCount))
            let parsed: FeedParser.Feed
            switch result {
            case .success(let feed):
                lastGood[file.name] = feed
                brokenSince[file.name] = nil
                parsed = feed
            case .failure(let rejection):
                rejected[file.name] = rejection.description
                // Still there, just not readable this time: keep what it
                // last said, settled against now so it can still go stale,
                // and out of date once it has been unreadable too long.
                guard let kept = lastGood[file.name] else { continue }
                let since = brokenSince[file.name] ?? unix
                brokenSince[file.name] = since
                var payload = kept.payload.settled(at: unix)
                if unix - since >= Self.brokenGrace { payload.isStale = true }
                parsed = FeedParser.Feed(id: kept.id, payload: payload)
            }
            // Two files claiming one id would fight over a single card. The
            // one written more recently has the better claim.
            if let existing = feeds[parsed.id], existing.updatedAt >= parsed.payload.updatedAt {
                rejected[file.name] = "id \"\(parsed.id)\" is already taken by a newer file"
                continue
            }
            feeds[parsed.id] = parsed.payload
        }
        // A file that is gone takes what it last said with it.
        let present = Set(files.map(\.name))
        lastGood = lastGood.filter { present.contains($0.key) }
        brokenSince = brokenSince.filter { present.contains($0.key) }
        firstSeen = firstSeen.filter { present.contains($0.key) }

        for (name, reason) in rejected.sorted(by: { $0.key < $1.key }) where turnedAway[name] != reason {
            Self.log.notice("""
                feed \(name, privacy: .public).json skipped: \(reason, privacy: .public)
                """)
        }
        turnedAway = rejected

        for id in feeds.keys.sorted() {
            guard let payload = feeds[id], standing[id] != payload else { continue }
            standing[id] = payload
            continuation?.yield(.publish(Activity(
                id: ActivityID(kind: .feeds, source: id),
                createdAt: moment.timeIntervalSinceReferenceDate,
                // No expiry: a container, not news. The producer's own
                // `stale_after` is the card's lifetime, and it dims rather
                // than disappears.
                expiresAfter: nil,
                payload: .feeds(payload)
            )))
        }
        for id in standing.keys.sorted() where feeds[id] == nil {
            standing[id] = nil
            continuation?.yield(.retract(ActivityID(kind: .feeds, source: id)))
        }
    }
}
