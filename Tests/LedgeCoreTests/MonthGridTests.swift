import Foundation
import Testing

@testable import LedgeCore

@Suite("Month grid")
struct MonthGridTests {

    /// A fixed, timezone-stable calendar so the layout is deterministic.
    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2 // Monday
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("Weeks are always seven cells wide")
    func rowsOfSeven() {
        let grid = MonthGrid.make(
            containing: date(2026, 8, 15),
            calendar: calendar(),
            locale: Locale(identifier: "en_US")
        )
        #expect(grid.weeks.allSatisfy { $0.count == 7 })
    }

    @Test("Every real day of the month appears exactly once")
    func everyDayPresent() {
        let grid = MonthGrid.make(
            containing: date(2026, 2, 10),   // Feb 2026, 28 days
            calendar: calendar(),
            locale: Locale(identifier: "en_US")
        )
        let days = grid.weeks.flatMap { $0 }.compactMap(\.day)
        #expect(days == Array(1...28))
    }

    @Test("Monday-first: a month starting on Sunday has six leading blanks")
    func mondayFirstLeadingBlanks() {
        // 1 March 2026 is a Sunday.
        let grid = MonthGrid.make(
            containing: date(2026, 3, 1),
            calendar: calendar(),
            locale: Locale(identifier: "en_US")
        )
        let firstWeek = grid.weeks[0]
        #expect(firstWeek.prefix(6).allSatisfy { $0.day == nil })
        #expect(firstWeek[6].day == 1)
    }

    @Test("Today is marked, and only today")
    func todayMarked() {
        let grid = MonthGrid.make(
            containing: date(2026, 6, 19),
            calendar: calendar(),
            locale: Locale(identifier: "en_US")
        )
        let todays = grid.weeks.flatMap { $0 }.filter(\.isToday)
        #expect(todays.count == 1)
        #expect(todays.first?.day == 19)
        #expect(grid.todayDay == 19)
    }

    @Test("Weekends are flagged in the Monday-first layout")
    func weekendsFlagged() {
        let grid = MonthGrid.make(
            containing: date(2026, 6, 19),
            calendar: calendar(),
            locale: Locale(identifier: "en_US")
        )
        // 20 and 21 June 2026 are Saturday and Sunday.
        let cells = grid.weeks.flatMap { $0 }
        #expect(cells.first { $0.day == 20 }?.isWeekend == true)
        #expect(cells.first { $0.day == 21 }?.isWeekend == true)
        #expect(cells.first { $0.day == 19 }?.isWeekend == false)   // Friday
    }

    @Test("Event days are dotted")
    func eventDaysDotted() {
        let grid = MonthGrid.make(
            containing: date(2026, 6, 19),
            eventDays: [17, 25],
            calendar: calendar(),
            locale: Locale(identifier: "en_US")
        )
        let cells = grid.weeks.flatMap { $0 }
        #expect(cells.first { $0.day == 17 }?.hasEvent == true)
        #expect(cells.first { $0.day == 25 }?.hasEvent == true)
        #expect(cells.first { $0.day == 18 }?.hasEvent == false)
    }

    @Test("A month starting on Monday has no leading blanks")
    func mondayStartNoBlanks() {
        // 1 June 2026 is a Monday.
        let grid = MonthGrid.make(
            containing: date(2026, 6, 1),
            calendar: calendar(),
            locale: Locale(identifier: "en_US")
        )
        #expect(grid.weeks[0][0].day == 1)
    }

    @Test("Leap February has 29 days, each present once")
    func leapFebruary() {
        let grid = MonthGrid.make(
            containing: date(2028, 2, 10),   // 2028 is a leap year
            calendar: calendar(),
            locale: Locale(identifier: "en_US")
        )
        let days = grid.weeks.flatMap { $0 }.compactMap(\.day)
        #expect(days == Array(1...29))
    }

    @Test("The layout follows the region's first weekday")
    func regionDecidesWeekStart() {
        // A US calendar starts the week on Sunday; the grid honours it — a
        // Sunday-starting month has no leading blanks at all, and the header
        // row leads with Sunday to match.
        var sundayFirst = Calendar(identifier: .gregorian)
        sundayFirst.timeZone = TimeZone(identifier: "UTC")!
        sundayFirst.firstWeekday = 1   // Sunday

        let sundayGrid = MonthGrid.make(
            containing: date(2026, 3, 1),   // starts on a Sunday
            eventDays: [],
            calendar: sundayFirst,
            locale: Locale(identifier: "en_US")
        )
        #expect(sundayGrid.weeks[0][0].day == 1)
        #expect(sundayGrid.weekdayHeaders.first == "S")
        #expect(sundayGrid.weekdayHeaders == ["S", "M", "T", "W", "T", "F", "S"])
        // Weekend stays Saturday/Sunday, wherever the columns land.
        #expect(sundayGrid.weeks[0][0].isWeekend, "March 1st 2026 is a Sunday")
        #expect(!sundayGrid.weeks[0][1].isWeekend, "the 2nd is a Monday")

        // And a Monday-first region keeps the old layout: six leading blanks
        // for the same month, headers leading with Monday.
        var mondayFirst = sundayFirst
        mondayFirst.firstWeekday = 2
        let mondayGrid = MonthGrid.make(
            containing: date(2026, 3, 1),
            eventDays: [],
            calendar: mondayFirst,
            locale: Locale(identifier: "en_GB")
        )
        #expect(mondayGrid.weeks[0].prefix(6).allSatisfy { $0.day == nil })
        #expect(mondayGrid.weeks[0][6].day == 1)
        #expect(mondayGrid.weekdayHeaders.first == "M")
        #expect(mondayGrid.weeks[0][6].isWeekend, "the Sunday in the last column")
    }

    @Test("The month and weekday names are uppercased")
    func names() {
        let grid = MonthGrid.make(
            containing: date(2026, 6, 19),
            calendar: calendar(),
            locale: Locale(identifier: "en_US")
        )
        #expect(grid.monthName == "JUNE")
        #expect(grid.todayWeekday == "FRIDAY")
    }
}
