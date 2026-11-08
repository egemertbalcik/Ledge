import Foundation
import LedgeCore
import LedgeProviders
import LedgeUI
import Testing

@testable import LedgeShell

/// A provider the test drives by hand.
private final class Pump: ActivityProvider {
    let identifier: String
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    init(identifier: String) { self.identifier = identifier }

    func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { self.continuation = $0 }
    }

    func stop() { continuation?.finish(); continuation = nil }

    func publish(_ activity: Activity) { continuation?.yield(.publish(activity)) }
    func retract(_ id: ActivityID) { continuation?.yield(.retract(id)) }
}

/// What the shell is told about a feed resting in the ears, and when a feed
/// may make the notch peek.
///
/// A feed used to reach the shell only as part of the music's "present"
/// fact, so with a paused track sitting in Now Playing a feed could come or go
/// without the shell hearing of it: the island stayed shut for a new feed, or
/// stayed open and empty after one left.
@Suite("A feed rests on its own signal", .timeLimit(.minutes(1)))
@MainActor
struct RestingFeedTests {

    @MainActor
    private final class Harness {
        let presentation = NotchPresentation()
        let activities: ActivityCoordinator
        let music = Pump(identifier: "nowplaying")
        let feeds = Pump(identifier: "feeds")
        var facts: [(present: Bool, playing: Bool)] = []
        var feedSignals: [Bool] = []
        var escalations: [ActivityID] = []
        /// Whether the notch takes an escalation's peek, as a Focus or the
        /// greeting would decide.
        var admits = true

        init() {
            let preferences = Preferences(store: MemoryPreferenceStore())
            preferences.hasCompletedOnboarding = true
            activities = ActivityCoordinator(
                presentation: presentation,
                preferences: preferences,
                isPermitted: { _ in true }
            )
            activities.onNowPlayingChanged = { [weak self] present, playing, _ in
                self?.facts.append((present, playing))
            }
            activities.onRestingFeedChanged = { [weak self] rests in
                self?.feedSignals.append(rests)
            }
            activities.onFeedEscalation = { [weak self] activity in
                guard let self else { return false }
                self.escalations.append(activity.id)
                return self.admits
            }
            activities.register(ProviderRegistration(
                id: "nowplaying", displayName: "Now Playing", kind: .nowPlaying,
                permission: nil, make: { [music] in music }
            ))
            activities.register(ProviderRegistration(
                id: "feeds", displayName: "Feeds", kind: .feeds,
                permission: nil, make: { [feeds] in feeds }
            ))
            activities.startEnabled()
            activities.start()
        }

        func pausedSong() -> Activity {
            Activity(
                id: ActivityID(kind: .nowPlaying, source: "com.spotify.client"),
                createdAt: 0,
                payload: .nowPlaying(NowPlayingPayload(
                    title: "Song", artist: "Artist", isPlaying: false,
                    sourceName: "Spotify", itemKey: "spotify:track:song"
                ))
            )
        }

        func feed(
            _ source: String = "usage",
            level: FeedLevel = .normal,
            reading: String = "42%",
            updatedAt: TimeInterval = Date().timeIntervalSince1970
        ) -> Activity {
            Activity(
                id: ActivityID(kind: .feeds, source: source),
                createdAt: 0,
                payload: .feeds(FeedPayload(
                    title: source, compactLeading: reading, level: level,
                    updatedAt: updatedAt
                ))
            )
        }

        /// Waits for something the delivery produces, rather than a guessed
        /// interval. False when it has not come within five seconds, so a
        /// regression fails the test instead of hanging it.
        @discardableResult
        func settle(until arrived: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while !arrived() {
                guard ContinuousClock.now < deadline else { return false }
                do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
            }
            return true
        }

        /// A chance for something that must not happen to show.
        func idle() async {
            for _ in 0 ..< 200 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    @Test("A feed arriving beside a paused track is heard, and so is its going")
    func aFeedBesideAPausedTrack() async {
        let harness = Harness()
        harness.music.publish(harness.pausedSong())
        #expect(await harness.settle(until: { harness.presentation.nowPlaying != nil }),
                "the paused track never arrived")
        let factsBefore = harness.facts.count

        // The case where the feed never showed.
        harness.feeds.publish(harness.feed())
        #expect(await harness.settle(until: { harness.feedSignals == [true] }))
        #expect(harness.presentation.restingFeed?.id.source == "usage")

        // The case where the island stayed open and empty.
        harness.feeds.retract(ActivityID(kind: .feeds, source: "usage"))
        #expect(await harness.settle(until: { harness.feedSignals == [true, false] }))
        #expect(harness.presentation.restingFeed == nil)

        // And the music's own facts never heard about any of it.
        await harness.idle()
        #expect(harness.facts.count == factsBefore)
    }

    @Test("A feed is never part of the music's present")
    func aFeedIsNotPresent() async {
        let harness = Harness()
        harness.feeds.publish(harness.feed())
        #expect(await harness.settle(until: { harness.feedSignals == [true] }))
        await harness.idle()
        #expect(harness.facts.allSatisfy { !$0.present })
    }

    @Test("Republishing a feed in place says nothing new")
    func republishingIsQuiet() async {
        let harness = Harness()
        harness.feeds.publish(harness.feed(reading: "1%"))
        #expect(await harness.settle(until: { harness.feedSignals == [true] }))
        for percent in 2...20 {
            harness.feeds.publish(harness.feed(reading: "\(percent)%"))
        }
        #expect(await harness.settle(until: {
            if case .feeds(let payload)? = harness.presentation.restingFeed?.payload {
                return payload.compactLeading == "20%"
            }
            return false
        }), "the last republish never arrived")
        #expect(harness.feedSignals == [true])
    }

    @Test("The feed in the ears keeps them when another writes more recently")
    func theEarsStayPut() async {
        let harness = Harness()
        let now = Date().timeIntervalSince1970
        harness.feeds.publish(harness.feed("first", updatedAt: now - 60))
        #expect(await harness.settle(until: { harness.presentation.restingFeed?.id.source == "first" }))

        let second = ActivityID(kind: .feeds, source: "second")
        harness.feeds.publish(harness.feed("second", updatedAt: now))
        #expect(await harness.settle(until: { harness.activities.activity(withID: second) != nil }),
                "the second feed never arrived")
        #expect(harness.presentation.restingFeed?.id.source == "first")

        // Until the first stops resting.
        harness.feeds.retract(ActivityID(kind: .feeds, source: "first"))
        #expect(await harness.settle(until: { harness.presentation.restingFeed?.id.source == "second" }))
        #expect(harness.feedSignals == [true])
    }

    @Test("A level flapping round critical peeks once")
    func flappingPeeksOnce() async {
        let harness = Harness()
        harness.feeds.publish(harness.feed(level: .warning, reading: "89%"))
        #expect(await harness.settle(until: { harness.presentation.restingFeed != nil }))
        harness.feeds.publish(harness.feed(level: .critical, reading: "91%"))
        #expect(await harness.settle(until: { harness.escalations.count == 1 }), "the first step never peeked")
        for round in 0 ..< 10 {
            harness.feeds.publish(harness.feed(level: .warning, reading: "89.\(round)%"))
            harness.feeds.publish(harness.feed(level: .critical, reading: "91.\(round)%"))
        }
        #expect(await harness.settle(until: {
            if case .feeds(let payload)? = harness.presentation.restingFeed?.payload {
                return payload.compactLeading == "91.9%"
            }
            return false
        }), "the last flap never arrived")
        #expect(harness.escalations.count == 1)
    }

    @Test("A feed swiped away at warning that comes back critical still peeks")
    func dismissedThenCritical() async {
        let harness = Harness()
        let id = ActivityID(kind: .feeds, source: "usage")
        harness.feeds.publish(harness.feed(level: .warning))
        #expect(await harness.settle(until: { harness.activities.activity(withID: id) != nil }))
        harness.activities.select(id)
        harness.activities.dismissSelected()
        #expect(await harness.settle(until: { harness.activities.activity(withID: id) == nil }),
                "the swipe never took the card away")

        harness.feeds.publish(harness.feed(level: .critical))
        #expect(await harness.settle(until: { harness.escalations == [id] }))
    }

    @Test("A peek the notch turned down does not silence the next one")
    func turnedDownThenShown() async {
        let harness = Harness()
        let id = ActivityID(kind: .feeds, source: "usage")
        harness.feeds.publish(harness.feed(level: .warning, reading: "89%"))
        #expect(await harness.settle(until: { harness.activities.activity(withID: id) != nil }))

        // Turned down, as during a Focus.
        harness.admits = false
        harness.feeds.publish(harness.feed(level: .critical, reading: "91%"))
        #expect(await harness.settle(until: { harness.escalations.count == 1 }), "the step was never offered")

        // Shown this time, well inside the cooldown.
        harness.admits = true
        harness.feeds.publish(harness.feed(level: .warning, reading: "89.5%"))
        harness.feeds.publish(harness.feed(level: .critical, reading: "91.5%"))
        #expect(await harness.settle(until: { harness.escalations.count == 2 }), "the next step was silenced")

        // And now the cooldown holds.
        harness.feeds.publish(harness.feed(level: .warning, reading: "89.9%"))
        harness.feeds.publish(harness.feed(level: .critical, reading: "91.9%"))
        #expect(await harness.settle(until: {
            if case .feeds(let payload)? = harness.presentation.restingFeed?.payload {
                return payload.compactLeading == "91.9%"
            }
            return false
        }), "the last step never arrived")
        await harness.idle()
        #expect(harness.escalations.count == 2)
    }

    @Test("A feed swiped away whose file then goes is forgotten")
    func dismissedThenGone() async {
        let harness = Harness()
        let id = ActivityID(kind: .feeds, source: "usage")
        harness.feeds.publish(harness.feed(level: .warning))
        #expect(await harness.settle(until: { harness.activities.activity(withID: id) != nil }))
        harness.activities.select(id)
        harness.activities.dismissSelected()
        #expect(await harness.settle(until: { harness.activities.activity(withID: id) == nil }),
                "the swipe never took the card away")

        // The file is deleted, and a new one of the same name appears critical:
        // a first sighting, read against nothing.
        harness.feeds.retract(id)
        await harness.idle()
        harness.feeds.publish(harness.feed(level: .critical))
        #expect(await harness.settle(until: { harness.activities.activity(withID: id) != nil }))
        await harness.idle()
        #expect(harness.escalations.isEmpty)
    }

    @Test("A feed that is retracted and comes back critical is a first sighting")
    func retractedThenCritical() async {
        let harness = Harness()
        let id = ActivityID(kind: .feeds, source: "usage")
        harness.feeds.publish(harness.feed(level: .warning))
        #expect(await harness.settle(until: { harness.activities.activity(withID: id) != nil }))
        harness.feeds.retract(id)
        #expect(await harness.settle(until: { harness.activities.activity(withID: id) == nil }))
        harness.feeds.publish(harness.feed(level: .critical))
        #expect(await harness.settle(until: { harness.activities.activity(withID: id) != nil }))
        await harness.idle()
        #expect(harness.escalations.isEmpty)
    }
}
