import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

/// A clock the test moves by hand.
@MainActor
private final class FeedClock {
    /// 2026-11-06 12:00:00 UTC.
    var date = Date(timeIntervalSince1970: 1_794_052_800)
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

@Suite("Feeds provider")
@MainActor
struct FeedsProviderTests {

    private func file(_ name: String, _ json: String, modifiedAt: TimeInterval = 0) -> FeedFile {
        FeedFile(name: name, data: Data(json.utf8), modifiedAt: modifiedAt)
    }

    private func limits(percent: Int = 10, level: String = "normal", updatedAt: Int = 1_794_052_700) -> String {
        """
        {"version": 1, "id": "limits", "title": "Limits", "compact_leading": "C \(percent)%",
         "level": "\(level)", "updated_at": \(updatedAt), "stale_after": 3600,
         "rows": [{"label": "Claude 5h", "value": "\(percent)% used", "fraction": 0.\(percent)}]}
        """
    }

    /// Everything the provider says while `body` runs, then stops it.
    private func collect(
        _ provider: FeedsProvider,
        while body: () -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func published(_ events: [ProviderEvent]) -> [(id: ActivityID, payload: FeedPayload)] {
        events.compactMap { event in
            guard case .publish(let activity) = event, case .feeds(let payload) = activity.payload
            else { return nil }
            return (activity.id, payload)
        }
    }

    // MARK: - Publishing

    @Test("Each valid file is a standing card of its own")
    func cardPerFile() async {
        let clock = FeedClock()
        let source = StubFeedSource(files: [
            file("limits", limits()),
            file("disk", #"{"version": 1, "title": "Disk", "rows": []}"#),
        ])
        let provider = FeedsProvider(source: source, now: { clock.date })
        let events = await collect(provider) {}

        let cards = published(events)
        #expect(cards.map { $0.id } == [
            ActivityID(kind: .feeds, source: "disk"),
            ActivityID(kind: .feeds, source: "limits"),
        ])
        #expect(cards.first { $0.id.source == "limits" }?.payload.title == "Limits")
        #expect(cards.first { $0.id.source == "disk" }?.payload.title == "Disk")

        for case .publish(let activity) in events {
            #expect(activity.expiresAfter == nil, "a feed stands until its file goes")
        }
    }

    @Test("A file with no id of its own is named by its filename")
    func filenameIsTheID() async {
        let source = StubFeedSource(files: [file("ci-status", #"{"version": 1}"#)])
        let events = await collect(FeedsProvider(source: source)) {}
        #expect(published(events).map { $0.id.source } == ["ci-status"])
    }

    @Test("A file that cannot be read is skipped and the rest stand")
    func badFilesAreSkipped() async {
        let source = StubFeedSource(files: [
            file("a-broken", "{ not json"),
            file("b-future", #"{"version": 9, "title": "Future"}"#),
            file("c-fine", #"{"version": 1, "title": "Fine"}"#),
            FeedFile(name: "d-huge", data: nil, byteCount: 5_000_000),
        ])
        let events = await collect(FeedsProvider(source: source)) {}
        #expect(published(events).map { $0.id.source } == ["c-fine"])
    }

    @Test("Two files claiming one id leave one card, from the newer file")
    func duplicateIDs() async {
        let source = StubFeedSource(files: [
            file("a", #"{"version": 1, "id": "same", "title": "Old", "updated_at": 1000}"#),
            file("b", #"{"version": 1, "id": "same", "title": "New", "updated_at": 2000}"#),
        ])
        let events = await collect(FeedsProvider(source: source)) {}
        let cards = published(events)
        #expect(cards.count == 1)
        #expect(cards.first?.payload.title == "New")
    }

    // MARK: - Following the folder

    @Test("Rewriting a file with the same contents publishes nothing")
    func unchangedIsQuiet() async {
        let source = StubFeedSource(files: [file("limits", limits())])
        let provider = FeedsProvider(source: source)
        let events = await collect(provider) {
            source.set([self.file("limits", self.limits())])
            source.set([self.file("limits", self.limits())])
        }
        #expect(published(events).count == 1, "only the first reading is news")
    }

    @Test("Rewriting a file with new numbers updates its card in place")
    func changedUpdates() async {
        let source = StubFeedSource(files: [file("limits", limits(percent: 10))])
        let provider = FeedsProvider(source: source)
        let events = await collect(provider) {
            source.set([self.file("limits", self.limits(percent: 40))])
        }
        let cards = published(events)
        #expect(cards.count == 2)
        #expect(Set(cards.map { $0.id }).count == 1, "the same card, not another")
        #expect(cards.last?.payload.compactLeading == "C 40%")
    }

    @Test("A file appearing is a new card, and its going is a retraction")
    func appearAndDisappear() async {
        let source = StubFeedSource()
        let provider = FeedsProvider(source: source)
        let events = await collect(provider) {
            source.set([self.file("limits", self.limits())])
            source.set([])
        }
        #expect(events.count == 2)
        guard case .publish(let activity)? = events.first else {
            Issue.record("expected the card to be published")
            return
        }
        #expect(events.last == .retract(activity.id))
    }

    @Test("A file replaced by a broken one takes its card away")
    func brokenReplacement() async {
        let source = StubFeedSource(files: [file("limits", limits())])
        let provider = FeedsProvider(source: source)
        let events = await collect(provider) {
            source.set([self.file("limits", "{ half a fi")])
        }
        #expect(events.last == .retract(ActivityID(kind: .feeds, source: "limits")))
    }

    // MARK: - Going stale

    @Test("A feed goes stale when its deadline passes, with no change to the file")
    func goingStale() async {
        let clock = FeedClock()
        // Written 100 s before the clock, good for an hour.
        let source = StubFeedSource(files: [file("limits", limits())])
        let provider = FeedsProvider(source: source, now: { clock.date })
        let events = await collect(provider) {
            clock.advance(1_800)
            source.set(source.files())
            clock.advance(3_600)
            source.set(source.files())
        }
        let cards = published(events)
        #expect(cards.map { $0.payload.isStale } == [false, true])
    }

    @Test("A stale feed that is written again comes back")
    func freshAgain() async {
        let clock = FeedClock()
        let source = StubFeedSource(files: [file("limits", limits())])
        let provider = FeedsProvider(source: source, now: { clock.date })
        let events = await collect(provider) {
            clock.advance(7_200)
            source.set(source.files())
            let now = Int(clock.date.timeIntervalSince1970)
            source.set([self.file("limits", self.limits(updatedAt: now))])
        }
        #expect(published(events).map { $0.payload.isStale } == [false, true, false])
    }

    // MARK: - Lifecycle

    @Test("Starting watches the source, and stopping lets go of it")
    func watchesWhileRunning() async {
        let source = StubFeedSource()
        let provider = FeedsProvider(source: source)
        #expect(!source.isWatching)
        _ = provider.start()
        #expect(source.isWatching)
        provider.stop()
        #expect(!source.isWatching)
    }

    @Test("A stopped provider publishes nothing more")
    func stoppedIsSilent() async {
        let source = StubFeedSource()
        let provider = FeedsProvider(source: source)
        let stream = provider.start()
        provider.stop()
        source.set([file("limits", limits())])
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        #expect(events.isEmpty)
    }

    // MARK: - The registry

    @Test("Feeds are registered, and off until asked for")
    func registeredOff() {
        let registration = ProviderRegistry
            .all(nowPlayingProvider: { FeedsProvider(source: StubFeedSource()) })
            .first { $0.id == "feeds" }
        #expect(registration != nil)
        #expect(registration?.kind == .feeds)
        #expect(registration?.isEnabledByDefault == false)
        #expect(registration?.permission == nil)
    }
}
