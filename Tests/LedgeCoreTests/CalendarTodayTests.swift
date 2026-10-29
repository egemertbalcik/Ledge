import Foundation
import LedgeCore
import Testing

/// Today on the calendar card: only what is still to come.
///
/// The line is drawn at the end of an event, not its start — a meeting in
/// progress is the one most worth seeing — and an all-day event, which has no
/// end worth the name, stays all day.
@Suite("Today's events on the calendar card")
struct CalendarTodayTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(_ title: String, endsIn minutes: Double?) -> MonthDayEntry {
        MonthDayEntry(
            title: title,
            time: "10:00",
            ends: minutes.map { now.addingTimeInterval($0 * 60) }
        )
    }

    // MARK: - The list

    @Test("A finished event is taken off today's list")
    func finishedGoes() {
        let list = [entry("Standup", endsIn: -15), entry("Retro", endsIn: 90)]
        #expect(CalendarToday.remaining(list, at: now).map(\.title) == ["Retro"])
    }

    @Test("An event in progress stays until it ends")
    func inProgressStays() {
        let running = entry("Design review", endsIn: 20)
        #expect(CalendarToday.remaining([running], at: now) == [running])
    }

    @Test("An event ending this very moment is over")
    func endingNowIsOver() {
        #expect(CalendarToday.remaining([entry("Standup", endsIn: 0)], at: now).isEmpty)
    }

    @Test("An all-day event, which has no end, stays all day")
    func allDayStays() {
        let holiday = MonthDayEntry(title: "Holiday")
        #expect(CalendarToday.remaining([holiday], at: now) == [holiday])
    }

    @Test("The order of what is left is the order it came in")
    func orderKept() {
        let list = [
            MonthDayEntry(title: "Holiday"),
            entry("Standup", endsIn: -30),
            entry("Lunch", endsIn: 60),
            entry("Retro", endsIn: 240),
        ]
        #expect(CalendarToday.remaining(list, at: now).map(\.title) == ["Holiday", "Lunch", "Retro"])
    }

    // MARK: - The next change

    @Test("The list next changes when the soonest remaining event ends")
    func nextEndIsSoonest() {
        let list = [
            entry("Standup", endsIn: -10),
            entry("Retro", endsIn: 120),
            entry("Lunch", endsIn: 45),
            MonthDayEntry(title: "Holiday"),
        ]
        #expect(CalendarToday.nextEnd(of: list, after: now) == now.addingTimeInterval(45 * 60))
    }

    @Test("Nothing left with an end means nothing to wait for")
    func nothingToWaitFor() {
        let list = [entry("Standup", endsIn: -10), MonthDayEntry(title: "Holiday")]
        #expect(CalendarToday.nextEnd(of: list, after: now) == nil)
    }

    // MARK: - The payload

    @Test("A payload from before the end was carried still reads, and is never over")
    func olderPayloadDecodes() throws {
        let json = #"{"title":"Standup","time":"09:30","eventID":"x"}"#
        let decoded = try JSONDecoder().decode(MonthDayEntry.self, from: Data(json.utf8))
        #expect(decoded.ends == nil)
        #expect(!decoded.hasEnded(at: .distantFuture))
    }

    @Test("The end survives a round trip")
    func endRoundTrips() throws {
        let original = entry("Standup", endsIn: 30)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MonthDayEntry.self, from: data) == original)
    }
}
