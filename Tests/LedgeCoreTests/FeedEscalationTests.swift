import Foundation
import LedgeCore
import Testing

/// When a feed may make the notch peek, which feed holds the ears, and how
/// the parser treats a date or a version it should not trust.
@Suite("Feed escalations and the ears")
struct FeedEscalationTests {

    private let usage = ActivityID(kind: .feeds, source: "usage")
    private let backup = ActivityID(kind: .feeds, source: "backup")

    // MARK: - Peeking

    @Test("A first sighting is a baseline, even when it is already critical")
    func firstSightingIsQuiet() {
        var escalations = FeedEscalations()
        let peek1 = escalations.observe(usage, level: .critical, now: 0)
        #expect(!peek1)
    }

    @Test("A step into critical peeks once")
    func stepPeeks() {
        var escalations = FeedEscalations()
        let peek2 = escalations.observe(usage, level: .warning, now: 0)
        #expect(!peek2)
        let peek3 = escalations.observe(usage, level: .critical, now: 10)
        #expect(peek3)
        escalations.didPeek(usage, now: 10)
        // Staying critical is not a new step.
        let peek4 = escalations.observe(usage, level: .critical, now: 20)
        #expect(!peek4)
    }

    @Test("A level flapping round its threshold peeks once per cooldown")
    func flappingIsQuiet() {
        var escalations = FeedEscalations()
        _ = escalations.observe(usage, level: .warning, now: 0)
        var peeks = 0
        // 89%, 91%, 89%, 91%… every ten seconds for most of the cooldown.
        var now: TimeInterval = 10
        while now < FeedEscalations.cooldown - 10 {
            if escalations.observe(usage, level: .critical, now: now) {
                peeks += 1
                escalations.didPeek(usage, now: now)
            }
            _ = escalations.observe(usage, level: .warning, now: now + 5)
            now += 10
        }
        #expect(peeks == 1)

        // Once the cooldown has passed, the next step may peek again.
        _ = escalations.observe(usage, level: .warning, now: FeedEscalations.cooldown + 20)
        let peek5 = escalations.observe(usage, level: .critical, now: FeedEscalations.cooldown + 30)
        #expect(peek5)
    }

    @Test("One feed's cooldown is its own")
    func cooldownIsPerFeed() {
        var escalations = FeedEscalations()
        _ = escalations.observe(usage, level: .normal, now: 0)
        _ = escalations.observe(backup, level: .normal, now: 0)
        let peek6 = escalations.observe(usage, level: .critical, now: 10)
        #expect(peek6)
        escalations.didPeek(usage, now: 10)
        let peek7 = escalations.observe(backup, level: .critical, now: 11)
        #expect(peek7)
    }

    @Test("A peek the notch turned down starts no cooldown")
    func turnedDownIsNotAPeek() {
        var escalations = FeedEscalations()
        _ = escalations.observe(usage, level: .warning, now: 0)
        // Allowed, but the notch said no: a Focus, the greeting.
        let allowed = escalations.observe(usage, level: .critical, now: 10)
        #expect(allowed)
        // The next real step may still peek, well inside the cooldown.
        _ = escalations.observe(usage, level: .warning, now: 20)
        let again = escalations.observe(usage, level: .critical, now: 30)
        #expect(again)
        escalations.didPeek(usage, now: 30)
        // And once it has been seen, the cooldown holds.
        _ = escalations.observe(usage, level: .warning, now: 40)
        let quiet = escalations.observe(usage, level: .critical, now: 50)
        #expect(!quiet)
    }

    @Test("A forgotten feed starts again from a baseline")
    func forgetting() {
        var escalations = FeedEscalations()
        _ = escalations.observe(usage, level: .warning, now: 0)
        escalations.forget(usage)
        #expect(!escalations.knownIDs.contains(usage))
        let peek8 = escalations.observe(usage, level: .critical, now: 10)
        #expect(!peek8)
    }

    // MARK: - The ears

    private func feed(_ source: String, updatedAt: TimeInterval, ears: Bool = true, stale: Bool = false) -> Activity {
        Activity(
            id: ActivityID(kind: .feeds, source: source),
            createdAt: 0,
            payload: .feeds(FeedPayload(
                title: source,
                compactLeading: ears ? "1" : nil,
                updatedAt: updatedAt,
                isStale: stale
            ))
        )
    }

    @Test("The feed in the ears keeps them while it still rests, however recent the others")
    func theEarsAreSticky() {
        let older = feed("a", updatedAt: 100)
        let newer = feed("b", updatedAt: 200)
        #expect(FeedSelection.compactFeed(among: [older, newer])?.id.source == "b")
        #expect(FeedSelection.compactFeed(among: [older, newer], keeping: older.id)?.id.source == "a")
    }

    @Test("A feed that stops resting hands the ears to the most recent one left")
    func theEarsMoveOn() {
        let staleNow = feed("a", updatedAt: 300, stale: true)
        let other = feed("b", updatedAt: 200)
        let quiet = feed("c", updatedAt: 400, ears: false)
        #expect(FeedSelection.compactFeed(among: [staleNow, other, quiet], keeping: staleNow.id)?.id.source == "b")
        // And a feed that has gone altogether.
        #expect(FeedSelection.compactFeed(among: [other], keeping: staleNow.id)?.id.source == "b")
    }

    // MARK: - What the parser trusts

    @Test("A date ahead of the clock counts as now, give or take a little skew")
    func futureDatesAreHeldBack() throws {
        let now: TimeInterval = 1_794_052_800
        let ahead = #"{"version": 1, "updated_at": 4102444800, "stale_after": 60}"#
        let feed = try FeedParser.parse(Data(ahead.utf8), fallbackID: "f", now: now).get()
        #expect(feed.payload.updatedAt == now + FeedParser.clockSkew)
        // So it can still go stale.
        #expect(feed.payload.settled(at: now + FeedParser.clockSkew + 61).isStale)

        // Read again two hours on, the same file is held to when it was first
        // seen, not to the later read, so it does not stay "Just now".
        let later = try FeedParser.parse(Data(ahead.utf8), fallbackID: "f", now: now + 7_200, seenAt: now).get()
        #expect(later.payload.updatedAt == now + FeedParser.clockSkew)
        #expect(later.payload.isStale)

        let slightly = #"{"version": 1, "updated_at": \#(Int(now) + 60)}"#
        let near = try FeedParser.parse(Data(slightly.utf8), fallbackID: "f", now: now).get()
        #expect(near.payload.updatedAt == now + 60)
    }

    @Test("True is not a number, for the version or for a fraction")
    func booleansAreNotNumbers() throws {
        let asVersion = #"{"version": true}"#
        #expect(FeedParser.parse(Data(asVersion.utf8), fallbackID: "f", now: 0) == .failure(.missingVersion))

        let asFraction = #"{"version": 1, "compact_leading_fraction": true, "rows": [{"label": "a", "value": "b", "fraction": false}]}"#
        let feed = try FeedParser.parse(Data(asFraction.utf8), fallbackID: "f", now: 0).get()
        #expect(feed.payload.compactLeadingFraction == nil)
        #expect(feed.payload.rows.first?.fraction == nil)
    }

    @Test("A whole-number version written as a decimal still reads, and a fraction of one does not")
    func decimalVersions() {
        #expect((try? FeedParser.parse(Data(#"{"version": 1.0}"#.utf8), fallbackID: "f", now: 0).get()) != nil)
        #expect(FeedParser.parse(Data(#"{"version": 1.5}"#.utf8), fallbackID: "f", now: 0) == .failure(.missingVersion))
        #expect(FeedParser.parse(Data(#"{"version": 1e300}"#.utf8), fallbackID: "f", now: 0) == .failure(.missingVersion))
    }
}
