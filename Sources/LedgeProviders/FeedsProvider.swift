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
            self.source.startWatching { [weak self] in self?.rescan() }
            self.rescan()
        }
    }

    public func stop() {
        source.stopWatching()
        continuation?.finish()
        continuation = nil
        standing = [:]
        turnedAway = [:]
    }

    /// Reads the folder and brings the queue in line with it.
    ///
    /// Everything is settled against one reading of the clock, so staleness is
    /// the same fact for every feed in a scan. It is also how a feed goes
    /// stale at all: nothing changes in the folder when a deadline passes, so
    /// the source's slow rescan is what lands here and notices.
    private func rescan() {
        guard continuation != nil else { return }
        let moment = now()
        let unix = moment.timeIntervalSince1970

        var feeds: [String: FeedPayload] = [:]
        var rejected: [String: String] = [:]

        for file in source.files() {
            guard let data = file.data else {
                rejected[file.name] = FeedParser.Rejection.oversize(bytes: file.byteCount).description
                continue
            }
            switch FeedParser.parse(
                data, fallbackID: file.name, fallbackUpdatedAt: file.modifiedAt, now: unix
            ) {
            case .success(let feed):
                // Two files claiming one id would fight over a single card.
                // The one written more recently has the better claim.
                if let existing = feeds[feed.id], existing.updatedAt >= feed.payload.updatedAt {
                    rejected[file.name] = "id \"\(feed.id)\" is already taken by a newer file"
                    continue
                }
                feeds[feed.id] = feed.payload
            case .failure(let rejection):
                rejected[file.name] = rejection.description
            }
        }

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
