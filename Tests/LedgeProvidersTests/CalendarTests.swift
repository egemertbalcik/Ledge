import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

@Suite("Calendar planning")
@MainActor
struct CalendarPlanTests {

    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func event(
        startsIn: TimeInterval,
        duration: TimeInterval = 3600,
        key: String = "e1",
        title: String = "Meeting"
    ) -> EventSnapshot {
        EventSnapshot(
            title: title,
            start: base.addingTimeInterval(startsIn),
            end: base.addingTimeInterval(startsIn + duration),
            eventKey: key
        )
    }

    private func plan(_ events: [EventSnapshot]) -> CalendarProvider.Plan {
        CalendarProvider.plan(events: events, now: base)
    }

    @Test("An empty calendar shows nothing and checks back later")
    func emptyCalendar() {
        let result = plan([])
        #expect(result.show == nil)
        #expect(result.nextCheck != nil)
    }

    @Test("A distant event stays hidden until the lead window")
    func distantEventHidden() {
        // Showing a card for a meeting most of a day out would be a standing
        // widget, not news. Expressed relative to `leadTime` rather than a
        // literal, so tuning the window cannot silently invert the test.
        let distant = CalendarProvider.leadTime + 2 * 3600
        let result = plan([event(startsIn: distant, key: "far")])
        #expect(result.show == nil)
        // Wake exactly when it enters the lead window, not on a poll.
        #expect(result.nextCheck == distant - CalendarProvider.leadTime)
    }

    @Test("An imminent event is shown")
    func imminentEventShown() {
        let result = plan([event(startsIn: 10 * 60, key: "soon")])
        #expect(result.show?.eventKey == "soon")
    }

    @Test("An event in progress is shown until it ends")
    func inProgressShown() {
        let result = plan([event(startsIn: -600, duration: 3600, key: "current")])
        #expect(result.show?.eventKey == "current")
        #expect(result.nextCheck != nil)
    }

    @Test("A finished event is gone even if the store still returns it")
    func finishedEventGone() {
        let result = plan([event(startsIn: -7200, duration: 3600, key: "over")])
        #expect(result.show == nil)
    }

    @Test("Something happening now beats something further off")
    func currentBeatsUpcoming() {
        // A short meeting in progress keeps the card while the next one is
        // still outside the imminent window.
        let result = plan([
            event(startsIn: CalendarProvider.imminentLead + 10 * 60, key: "next"),
            event(startsIn: -300, duration: 1800, key: "now"),
        ])
        #expect(result.show?.eventKey == "now")
    }

    @Test("A short current event yields to one starting within minutes")
    func shortCurrentYieldsToImminent() {
        // Back-to-back: the next meeting's countdown and join link matter
        // more than the one the user is already sitting in.
        let result = plan([
            event(startsIn: 10 * 60, key: "next"),
            event(startsIn: -300, duration: 1800, key: "now"),
        ])
        #expect(result.show?.eventKey == "next")
    }

    @Test("A long block yields to anything upcoming inside the lead window")
    func longCurrentYieldsWithinLead() {
        // "OOO Mon–Fri" used to hide every meeting of the week for days.
        let result = plan([
            event(startsIn: -24 * 3600, duration: 5 * 24 * 3600, key: "ooo"),
            event(startsIn: 3 * 3600, key: "standup"),
        ])
        #expect(result.show?.eventKey == "standup")
    }

    @Test("A long block yields to something imminent too")
    func longCurrentYieldsToImminent() {
        let result = plan([
            event(startsIn: -24 * 3600, duration: 5 * 24 * 3600, key: "ooo"),
            event(startsIn: 5 * 60, key: "standup"),
        ])
        #expect(result.show?.eventKey == "standup")
    }

    @Test("A long block keeps the card when nothing is coming up within the lead")
    func longCurrentKeepsStageWhenQuiet() {
        // The block is still the truthful thing to show on an empty
        // afternoon; the point of the rule is to stop it hiding meetings.
        let result = plan([
            event(startsIn: -24 * 3600, duration: 5 * 24 * 3600, key: "ooo"),
            event(startsIn: CalendarProvider.leadTime + 3600, key: "far"),
        ])
        #expect(result.show?.eventKey == "ooo")
    }

    @Test("A short current event is not displaced by something an hour off")
    func shortCurrentKeepsStageAgainstDistant() {
        // Just under the long threshold: a 4-hour workshop is still something
        // the user is *in*, so a meeting an hour out waits its turn.
        let result = plan([
            event(startsIn: -3600, duration: 4 * 3600, key: "workshop"),
            event(startsIn: 3600, key: "later"),
        ])
        #expect(result.show?.eventKey == "workshop")
    }

    @Test("Of two events in progress, the one ending soonest is shown")
    func nestedCurrentPrefersSoonestEnd() {
        // A standup that started inside a week-long block is what the user is
        // in right now; picking the earliest *start* gave the block the card
        // for the standup's whole half hour.
        let result = plan([
            event(startsIn: -24 * 3600, duration: 5 * 24 * 3600, key: "ooo"),
            event(startsIn: -5 * 60, duration: 1800, key: "standup"),
        ])
        #expect(result.show?.eventKey == "standup")
    }

    @Test("The soonest of several upcoming events wins")
    func soonestWins() {
        let result = plan([
            event(startsIn: 25 * 60, key: "later"),
            event(startsIn: 5 * 60, key: "sooner"),
        ])
        #expect(result.show?.eventKey == "sooner")
    }

    @Test("While a card is up, the countdown refreshes on a short cadence")
    func refreshWhileShown() {
        let result = plan([event(startsIn: 10 * 60, key: "soon")])
        let next = try! #require(result.nextCheck)
        #expect(next <= CalendarProvider.refreshInterval)
        #expect(next >= 1, "a non-positive delay would spin")
    }

    @Test("An event ending in under a second cannot schedule a zero delay")
    func noZeroDelay() {
        let result = plan([event(startsIn: -3599.5, duration: 3600, key: "ending")])
        if let next = result.nextCheck {
            #expect(next >= 0.5)
        }
    }
}

/// Wraps the stub and counts month-grid queries, so a test can say how often
/// the provider went back to the store.
@MainActor
private final class CountingCalendarSource: CalendarSource {
    let inner: StubCalendarSource
    var monthQueries = 0

    init(events: [EventSnapshot] = []) {
        inner = StubCalendarSource(events: events)
    }

    var isAuthorized: Bool { inner.isAuthorized }

    func upcomingEvents(within window: TimeInterval) async -> [EventSnapshot] {
        await inner.upcomingEvents(within: window)
    }

    func eventDays(monthOffset: Int) async -> Set<Int> {
        monthQueries += 1
        return await inner.eventDays(monthOffset: monthOffset)
    }

    func events(monthOffset: Int) async -> [Int: [(title: String, time: String, eventID: String)]] {
        monthQueries += 1
        return await inner.events(monthOffset: monthOffset)
    }

    func startWatching(_ onChange: @escaping @MainActor () -> Void) {
        inner.startWatching(onChange)
    }

    func stopWatching() {
        inner.stopWatching()
    }
}

@Suite("Calendar provider")
@MainActor
struct CalendarProviderTests {

    private func collect(
        _ provider: CalendarProvider,
        while body: () async -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        // Evaluation is async now (the store query is off-main), so let the
        // initial read complete before acting or stopping.
        await settle()
        await body()
        await settle()
        provider.stop()

        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    @Test("An imminent event publishes a card with the calendar's colour")
    func publishesImminent() async {
        let start = Date().addingTimeInterval(10 * 60)
        let source = StubCalendarSource(events: [
            EventSnapshot(
                title: "Standup",
                location: "Room 2",
                start: start,
                end: start.addingTimeInterval(1800),
                accentRed: 0.9, accentGreen: 0.2, accentBlue: 0.2,
                eventKey: "standup"
            )
        ])
        let provider = CalendarProvider(source: source)

        let events = await collect(provider) {}

        guard case .publish(let activity)? = events.first else {
            Issue.record("expected a publish")
            return
        }
        #expect(activity.id == ActivityID(kind: .event, source: "standup"))
        guard case .event(let payload) = activity.payload else {
            Issue.record("expected an event payload")
            return
        }
        #expect(payload.title == "Standup")
        #expect(abs(payload.accent.red - 0.9) < 0.001)
        // The plan owns the card's lifetime; an expiry timer racing it would
        // drop the card mid-meeting.
        #expect(activity.expiresAfter == nil)
    }

    @Test("Nothing is published without authorization")
    func silentWhenUnauthorized() async {
        let start = Date().addingTimeInterval(10 * 60)
        let source = StubCalendarSource(
            events: [EventSnapshot(
                title: "Hidden",
                start: start,
                end: start.addingTimeInterval(600),
                eventKey: "hidden"
            )],
            isAuthorized: false
        )
        let provider = CalendarProvider(source: source)
        let events = await collect(provider) {}
        #expect(events.isEmpty)
    }

    @Test("A calendar change retracts a card whose event was deleted")
    func deletionRetracts() async {
        let start = Date().addingTimeInterval(10 * 60)
        let source = StubCalendarSource(events: [
            EventSnapshot(
                title: "Doomed",
                start: start,
                end: start.addingTimeInterval(600),
                eventKey: "doomed"
            )
        ])
        let provider = CalendarProvider(source: source)

        let events = await collect(provider) {
            source.set([])
        }

        // The card no longer disappears when the event does: the calendar is a
        // standing surface, so a deletion swaps it to the empty state under a
        // stable id. The *old* card still has to be retracted, or two event
        // cards would sit in the queue at once.
        guard case .retract(let retracted)? = events.dropLast().last else {
            Issue.record("expected the deleted event's card to be retracted")
            return
        }
        #expect(retracted.source == "doomed")

        guard case .publish(let activity)? = events.last,
              case .event(let payload) = activity.payload
        else {
            Issue.record("expected an empty calendar card to remain")
            return
        }
        #expect(activity.id.source == "calendar")
        #expect(!payload.hasEvent)
    }

    /// Three months, two queries each.
    private let queriesPerRead = 6

    @Test("The month grids are queried once, then reused across ticks")
    func monthGridsCachedAcrossTicks() async {
        let start = Date().addingTimeInterval(10 * 60)
        let source = CountingCalendarSource(events: [
            EventSnapshot(title: "Standup", start: start, end: start.addingTimeInterval(1800), eventKey: "standup")
        ])
        let provider = CalendarProvider(source: source)

        let events = await collect(provider) {
            #expect(source.monthQueries == queriesPerRead, "the first evaluate reads the grids")
            provider.tickForTesting()
            await settle()
            provider.tickForTesting()
            await settle()
        }

        // Every countdown tick used to cost six store queries for grids that
        // had not changed. The card still republishes on each tick.
        #expect(source.monthQueries == queriesPerRead)
        #expect(events.filter { if case .publish = $0 { true } else { false } }.count == 3)
    }

    @Test("A store change re-reads the month grids")
    func storeChangeRereadsGrids() async {
        let source = CountingCalendarSource()
        let provider = CalendarProvider(source: source)

        _ = await collect(provider) {
            let start = Date().addingTimeInterval(10 * 60)
            source.inner.set([
                EventSnapshot(title: "New", start: start, end: start.addingTimeInterval(600), eventKey: "new")
            ])
        }

        #expect(source.monthQueries == 2 * queriesPerRead)
    }

    @Test("Wake re-reads the month grids")
    func wakeRereadsGrids() async {
        let source = CountingCalendarSource()
        let provider = CalendarProvider(source: source)

        _ = await collect(provider) {
            // Change notifications may not have arrived across a sleep.
            provider.refresh()
        }

        #expect(source.monthQueries == 2 * queriesPerRead)
    }

    @Test("Day rollover re-reads the month grids; the same day does not")
    func dayRolloverRereadsGrids() async {
        let source = CountingCalendarSource()
        var clock = Date()
        let provider = CalendarProvider(source: source, now: { clock })

        _ = await collect(provider) {
            provider.tickForTesting()
            await settle()
            #expect(source.monthQueries == queriesPerRead, "a tick on the same day reuses the grids")

            // Cross midnight: the three months the grid covers may have
            // shifted, and a daily reread is the floor against a missed
            // change notification.
            clock = Calendar.current.date(byAdding: .day, value: 1, to: clock)!
            provider.tickForTesting()
        }

        #expect(source.monthQueries == 2 * queriesPerRead)
    }
}
