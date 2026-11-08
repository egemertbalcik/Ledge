import Foundation
import LedgeCore
import Testing

/// Which feed has the closed notch, where it sits among what else rests there,
/// and when a change of level is worth the notch's attention.
@Suite("Feed selection")
struct FeedSelectionTests {

    private func feed(
        _ source: String,
        leading: String? = "C 90%",
        trailing: String? = nil,
        level: FeedLevel = .normal,
        updatedAt: TimeInterval = 1_000,
        stale: Bool = false
    ) -> Activity {
        Activity(
            id: ActivityID(kind: .feeds, source: source),
            createdAt: 0,
            payload: .feeds(FeedPayload(
                title: source,
                compactLeading: leading,
                compactTrailing: trailing,
                level: level,
                updatedAt: updatedAt,
                isStale: stale
            ))
        )
    }

    private func other(_ kind: ActivityKind, _ payload: ActivityPayload) -> Activity {
        Activity(id: ActivityID(kind: kind, source: "x"), createdAt: 0, payload: payload)
    }

    // MARK: - Which feed

    @Test("The most recently updated feed with compact text has the ears")
    func newestWins() {
        let older = feed("older", updatedAt: 1_000)
        let newer = feed("newer", updatedAt: 2_000)
        #expect(FeedSelection.compactFeed(among: [older, newer])?.id.source == "newer")
        #expect(FeedSelection.compactFeed(among: [newer, older])?.id.source == "newer")
    }

    @Test("A newer feed with nothing for the ears does not take them")
    func silentFeedsAreSkipped() {
        let quiet = feed("quiet", leading: nil, updatedAt: 9_000)
        let loud = feed("loud", updatedAt: 1_000)
        #expect(FeedSelection.compactFeed(among: [quiet, loud])?.id.source == "loud")
    }

    @Test("Stale feeds are passed over, and with none left the ears are free")
    func staleFeedsArePassedOver() {
        let stale = feed("stale", updatedAt: 9_000, stale: true)
        let fresh = feed("fresh", updatedAt: 1_000)
        #expect(FeedSelection.compactFeed(among: [stale, fresh])?.id.source == "fresh")
        #expect(FeedSelection.compactFeed(among: [stale]) == nil)
        #expect(FeedSelection.compactFeed(among: []) == nil)
    }

    @Test("Equal times go to the lower id, whichever order they arrive in")
    func tiesAreStable() {
        let a = feed("a", updatedAt: 5)
        let b = feed("b", updatedAt: 5)
        #expect(FeedSelection.compactFeed(among: [a, b])?.id.source == "a")
        #expect(FeedSelection.compactFeed(among: [b, a])?.id.source == "a")
    }

    @Test("Cards of other kinds are never mistaken for a feed")
    func onlyFeeds() {
        let focus = other(.focus, .focus(FocusPayload(name: "Work")))
        #expect(FeedSelection.compactFeed(among: [focus]) == nil)
    }

    // MARK: - Where it sits in the ears

    @Test("A feed takes the ears ahead of the card last read")
    func feedBeatsSelected() {
        let weather = other(.weather, .weather(WeatherPayload(temperatureCelsius: 20)))
        let resolved = CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: nil, nowPlaying: nil,
            feed: feed("a"), selected: weather
        )
        #expect(resolved?.kind == .feeds)
    }

    @Test("Everything that is going on takes the ears from a feed")
    func feedYieldsToResidents() {
        let music = other(.nowPlaying, .nowPlaying(NowPlayingPayload(
            title: "t", artist: "a", isPlaying: true
        )))
        let timer = other(.timer, .timer(TimerPayload(label: "Focus", remaining: 60, total: 300)))
        let farewell = other(.weather, .weather(WeatherPayload(temperatureCelsius: 20)))

        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: music, runningTimer: nil,
            closeEvent: nil, nowPlaying: nil, feed: feed("a"), selected: nil
        )?.kind == .nowPlaying)
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: timer,
            closeEvent: nil, nowPlaying: nil, feed: feed("a"), selected: nil
        )?.kind == .timer)
        #expect(CompactRest.resolve(
            farewell: farewell, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: nil, nowPlaying: nil, feed: feed("a"), selected: nil
        )?.kind == .weather)
    }

    @Test("A feed with nothing for the ears leaves them to the card last read")
    func silentFeedDoesNotRest() {
        let weather = other(.weather, .weather(WeatherPayload(temperatureCelsius: 20)))
        let resolved = CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: nil, nowPlaying: nil,
            feed: feed("a", leading: nil), selected: weather
        )
        #expect(resolved?.kind == .weather)
    }

    // MARK: - What is news

    @Test("Only a step into critical is worth the notch's attention")
    func escalation() {
        // Seen for the first time: a baseline, even if it is already critical.
        #expect(!FeedAttention.isEscalation(from: nil, to: .critical))
        #expect(!FeedAttention.isEscalation(from: nil, to: .normal))

        #expect(FeedAttention.isEscalation(from: .normal, to: .critical))
        #expect(FeedAttention.isEscalation(from: .warning, to: .critical))

        // Already critical, and rewritten as critical every minute.
        #expect(!FeedAttention.isEscalation(from: .critical, to: .critical))

        // Getting better, or only getting worse as far as a warning.
        #expect(!FeedAttention.isEscalation(from: .critical, to: .normal))
        #expect(!FeedAttention.isEscalation(from: .critical, to: .warning))
        #expect(!FeedAttention.isEscalation(from: .normal, to: .warning))
        #expect(!FeedAttention.isEscalation(from: .warning, to: .normal))
    }
}
