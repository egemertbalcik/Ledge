import Foundation
import LedgeCore
import Testing
@testable import LedgeProviders
@testable import LedgeSystem

/// The calendars a user switched off, as the card sees them: one choice for
/// the card, its peek, the month grid's dots and the day list.
@Suite("Calendar provider: chosen calendars")
@MainActor
struct CalendarChoiceProviderTests {

    private let work = CalendarInfo(id: "work", title: "Work", account: "iCloud")
    private let home = CalendarInfo(id: "home", title: "Home", account: "iCloud")

    /// A day of this month that is not today, for an event that only the
    /// grid and the day list can show.
    private static var otherDay: Date {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.component(.day, from: now)
        return calendar.date(byAdding: .day, value: today <= 15 ? 5 : -5, to: now)!
    }

    /// Standup on Work in ten minutes; on Home, a dentist in five — sooner,
    /// so it is the one the card would choose — and a trip on another day.
    private func events() -> [EventSnapshot] {
        let now = Date()
        let trip = Self.otherDay
        return [
            EventSnapshot(title: "Standup", start: now.addingTimeInterval(600),
                          end: now.addingTimeInterval(2400), eventKey: "standup",
                          meetingURL: "https://zoom.us/j/1", calendarID: "work"),
            EventSnapshot(title: "Dentist", start: now.addingTimeInterval(300),
                          end: now.addingTimeInterval(1800), eventKey: "dentist",
                          meetingURL: "https://zoom.us/j/2", calendarID: "home"),
            EventSnapshot(title: "Trip", start: trip, end: trip.addingTimeInterval(3600),
                          eventKey: "trip", calendarID: "home"),
        ]
    }

    /// The last card published, after starting and settling.
    private func lastCard(
        _ provider: CalendarProvider,
        while body: () async -> Void = {}
    ) async -> EventPayload? {
        let stream = provider.start()
        await provider.evaluationSettled()
        await body()
        await provider.evaluationSettled()
        provider.stop()
        var last: EventPayload?
        for await event in stream {
            if case .publish(let activity) = event, case .event(let payload) = activity.payload {
                last = payload
            }
        }
        return last
    }

    private func thisMonth(_ payload: EventPayload) -> MonthWindow? {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return payload.monthWindows.first { $0.year == comps.year && $0.month == comps.month }
    }

    private func titles(_ payload: EventPayload) -> Set<String> {
        Set(payload.monthWindows.flatMap { $0.events.flatMap { $0.entries.map(\.title) } })
    }

    private var tripDay: Int { Calendar.current.component(.day, from: Self.otherDay) }

    @Test("A hidden calendar's events are gone from the card, the grid and the day list")
    func hiddenCalendarIsGoneEverywhere() async {
        // Reached: with nothing hidden, Home's events are on all three.
        let shown = await lastCard(CalendarProvider(
            source: StubCalendarSource(events: events(), calendars: [work, home])
        ))
        #expect(shown?.title == "Dentist", "the sooner Home event should be the card's")
        #expect(shown.map(titles)?.contains("Trip") == true)
        #expect(shown.flatMap(thisMonth)?.eventDays.contains(tripDay) == true)

        let hidden = await lastCard(CalendarProvider(
            source: StubCalendarSource(events: events(), calendars: [work, home]),
            hiddenCalendars: { ["home"] }
        ))
        guard let hidden else {
            Issue.record("no card")
            return
        }
        // The card, and with it the peek, Join and the self-view, all of
        // which are read from what the card is showing.
        #expect(hidden.title == "Standup")
        #expect(hidden.meetingURL == "https://zoom.us/j/1")
        // The day list.
        #expect(!titles(hidden).contains("Dentist"))
        #expect(!titles(hidden).contains("Trip"))
        #expect(titles(hidden).contains("Standup"))
        // The grid's dots.
        #expect(thisMonth(hidden)?.eventDays.contains(tripDay) == false)
    }

    @Test("Every calendar hidden shows nothing, not everything")
    func everythingHiddenShowsNothing() async {
        let payload = await lastCard(CalendarProvider(
            source: StubCalendarSource(events: events(), calendars: [work, home]),
            hiddenCalendars: { ["home", "work"] }
        ))
        // Reached: the card still stands — it is a calendar, not an alarm.
        guard let payload else {
            Issue.record("the card should still stand, empty")
            return
        }
        #expect(!payload.hasEvent)
        #expect(payload.monthWindows.count == 3)
        #expect(titles(payload).isEmpty)
        #expect(payload.monthWindows.allSatisfy { $0.eventDays.isEmpty })
        #expect(payload.monthEventDays.isEmpty)
    }

    @Test("A calendar added later is shown without a visit to Settings")
    func newCalendarIsShown() async {
        let source = StubCalendarSource(events: events(), calendars: [work, home])
        let provider = CalendarProvider(source: source, hiddenCalendars: { ["home"] })
        let payload = await lastCard(provider) {
            let shared = CalendarInfo(id: "shared", title: "Shared", account: "Google")
            source.events.append(EventSnapshot(
                title: "Review", start: Date().addingTimeInterval(120),
                end: Date().addingTimeInterval(900), eventKey: "review", calendarID: "shared"
            ))
            // EventKit reports a new calendar as a store change.
            source.set(calendars: [work, home, shared])
        }
        // The soonest of everything not hidden; Home is still out.
        #expect(payload?.title == "Review")
        #expect(payload.map(titles)?.contains("Review") == true)
        #expect(payload.map(titles)?.contains("Dentist") == false)
    }

    @Test("Switching a calendar off re-reads the card and its grids at once")
    func switchingRereads() async {
        let source = CountingCalendarSource(events: events(), calendars: [work, home])
        var hidden: Set<String> = []
        let provider = CalendarProvider(source: source, hiddenCalendars: { hidden })

        let payload = await lastCard(provider) {
            #expect(source.monthQueries == 6, "the first evaluation reads the three grids")
            hidden = ["home"]
            provider.calendarsChanged()
        }

        // The grids were read through the old choice, so they go too.
        #expect(source.monthQueries == 12)
        #expect(payload?.title == "Standup")
        #expect(payload.map(titles)?.contains("Trip") == false)
    }

    @Test("Grids read through another choice are never reused, whoever forgot to say")
    func gridsFollowTheChoiceOnATick() async {
        let source = CountingCalendarSource(events: events(), calendars: [work, home])
        var hidden: Set<String> = []
        let provider = CalendarProvider(source: source, hiddenCalendars: { hidden })

        let payload = await lastCard(provider) {
            provider.tickForTesting()
            await provider.evaluationSettled()
            #expect(source.monthQueries == 6, "the same choice reuses the grids")
            // No `calendarsChanged()`: the next tick alone must not publish
            // this minute's card beside the old choice's grids.
            hidden = ["home"]
            provider.tickForTesting()
        }

        #expect(source.monthQueries == 12)
        #expect(payload?.title == "Standup")
        #expect(payload.map(titles)?.contains("Trip") == false)
    }

    @Test("The list Settings shows comes from the source, and only with the grant")
    func calendarListNeedsTheGrant() async {
        let granted = StubCalendarSource(calendars: [work, home])
        #expect(await granted.calendars() == [work, home])
        let refused = StubCalendarSource(calendars: [work, home], isAuthorized: false)
        #expect(await refused.calendars().isEmpty)
    }
}
