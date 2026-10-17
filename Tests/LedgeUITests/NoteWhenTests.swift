import Foundation
import Testing

@testable import LedgeUI

/// When a note was last edited, in the order a person thinks of it.
///
/// The boundaries are the whole of this: "Yesterday" is the calendar day
/// before, not twenty-four hours, and a note written at 23:50 must read as
/// "Yesterday" twenty minutes later rather than as "0h".
@Suite("How a note says when it was written")
struct NoteWhenTests {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ year: Int, _ month: Int, _ day: Int,
                    _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"),
                                           year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private func label(_ edited: Date, _ now: Date) -> String {
        NoteWhen.label(edited.timeIntervalSince1970, now: now, calendar: calendar)
    }

    @Test("Under a minute is now")
    func justNow() {
        let now = at(2026, 10, 16, 14, 26)
        #expect(label(now, now) == "now")
        #expect(label(now.addingTimeInterval(-59), now) == "now")
        #expect(label(now.addingTimeInterval(-60), now) == "1m")
    }

    @Test("A note from the future reads as now, not as a negative minute")
    func theFuture() {
        // A clock change, or a file copied from another Mac. The card must
        // not print "-43m".
        let now = at(2026, 10, 16, 14, 26)
        #expect(label(now.addingTimeInterval(3600), now) == "now")
    }

    @Test("Minutes, then hours, inside the day")
    func minutesThenHours() {
        let now = at(2026, 10, 16, 14, 26)
        #expect(label(now.addingTimeInterval(-4 * 60), now) == "4m")
        #expect(label(now.addingTimeInterval(-59 * 60), now) == "59m")
        #expect(label(now.addingTimeInterval(-2 * 3600), now) == "2h")
    }

    @Test("Yesterday is the calendar day before, not twenty-four hours")
    func yesterdayIsACalendarDay() {
        // Twenty minutes after midnight, a note from ten minutes before it
        // reads in minutes — that is the more useful fact, and it is the one
        // the smallest-unit rule gives. What must never appear is "0h".
        let justAfterMidnight = at(2026, 10, 16, 0, 10)
        #expect(label(at(2026, 10, 15, 23, 50), justAfterMidnight) == "20m")

        // The boundary that is actually about the calendar: a note from
        // yesterday *afternoon* is Yesterday, not "22h". Elapsed hours would
        // say the second thing and mean nothing to anybody.
        let now = at(2026, 10, 16, 14, 26)
        #expect(label(at(2026, 10, 15, 16, 0), now) == "Yesterday")
        // And the first hour of today is still today.
        #expect(label(at(2026, 10, 16, 0, 30), now) == "13h")
    }

    @Test("Within the week it is a weekday name")
    func theWeek() {
        let now = at(2026, 10, 16, 14, 26)  // a Friday
        let tuesday = at(2026, 10, 13, 9, 0)
        #expect(label(tuesday, now) == tuesday.formatted(.dateTime.weekday(.abbreviated)))
        // Seven days back is past the week and takes a date.
        let lastFriday = at(2026, 10, 9, 9, 0)
        #expect(label(lastFriday, now).contains("Oct"))
    }

    @Test("Older than a week is a date, with the year only when it differs")
    func olderThanAWeek() {
        let now = at(2026, 10, 16, 14, 26)
        let thisYear = label(at(2026, 3, 2, 9, 0), now)
        #expect(thisYear.contains("Mar"))
        #expect(!thisYear.contains("2026"), "this year's notes do not need to say which year")

        let lastYear = label(at(2025, 10, 12, 9, 0), now)
        #expect(lastYear.contains("Oct"))
        #expect(lastYear.contains("2025"), "a note from another year has to say so")
    }

    @Test("Nothing ever wraps: every label is short")
    func everyLabelIsShort() {
        // The column is beside a title that wants every point it can get, and
        // a time that wraps pushes the title rather than the other way round.
        let now = at(2026, 10, 16, 14, 26)
        let moments: [Date] = [
            now, now.addingTimeInterval(-30), now.addingTimeInterval(-45 * 60),
            now.addingTimeInterval(-5 * 3600), at(2026, 10, 15, 23, 50),
            at(2026, 10, 13, 9, 0), at(2026, 3, 2, 9, 0), at(2024, 1, 31, 9, 0)
        ]
        for moment in moments {
            let text = label(moment, now)
            #expect(text.count <= 12, "\(text) is too long for the column it sits in")
            #expect(!text.contains("\n"))
        }
    }
}
