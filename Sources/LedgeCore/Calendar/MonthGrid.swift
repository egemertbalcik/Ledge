import Foundation

/// A month laid out as calendar rows, starting on the region's own first
/// weekday — the grid Apple's calendar widget draws, wherever the Mac is set.
///
/// Pure and calendar-injectable so the layout (which day starts the week, how
/// many leading blanks, which cells are this month) is testable without a view
/// or the system clock.
public struct MonthGrid: Equatable, Sendable {

    /// One cell. A `nil` day is a leading or trailing blank that pads the grid
    /// to whole weeks.
    public struct Cell: Equatable, Sendable {
        public let day: Int?
        public let isToday: Bool
        public let isWeekend: Bool
        public let hasEvent: Bool

        public init(day: Int?, isToday: Bool = false, isWeekend: Bool = false, hasEvent: Bool = false) {
            self.day = day
            self.isToday = isToday
            self.isWeekend = isWeekend
            self.hasEvent = hasEvent
        }
    }

    /// Uppercase month name, e.g. "JUNE".
    public let monthName: String

    /// Uppercase weekday, e.g. "FRIDAY".
    public let todayWeekday: String

    /// Today's day number.
    public let todayDay: Int

    /// Rows of seven cells each, first column = the region's first weekday.
    public let weeks: [[Cell]]

    /// One very-short symbol per column ("M", "S", …), in column order and
    /// uppercased — so the header row always agrees with the layout beneath.
    public let weekdayHeaders: [String]

    public init(
        monthName: String,
        todayWeekday: String,
        todayDay: Int,
        weeks: [[Cell]],
        weekdayHeaders: [String] = ["M", "T", "W", "T", "F", "S", "S"]
    ) {
        self.monthName = monthName
        self.todayWeekday = todayWeekday
        self.todayDay = todayDay
        self.weeks = weeks
        self.weekdayHeaders = weekdayHeaders
    }

    /// Builds the grid for the month containing `today`.
    ///
    /// - Parameter eventDays: day numbers in this month that have an event.
    public static func make(
        containing today: Date,
        eventDays: Set<Int> = [],
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> MonthGrid {
        var calendar = calendar
        calendar.locale = locale

        let comps = calendar.dateComponents([.year, .month, .day], from: today)
        let todayDay = comps.day ?? 1

        guard let firstOfMonth = calendar.date(from: DateComponents(
            year: comps.year, month: comps.month, day: 1
        )),
        let range = calendar.range(of: .day, in: .month, for: firstOfMonth)
        else {
            return MonthGrid(monthName: "", todayWeekday: "", todayDay: todayDay, weeks: [])
        }

        // The region decides which day leads: `firstWeekday` is 1=Sunday …
        // 7=Saturday, straight from the Mac's calendar settings.
        let weekStart = min(max(calendar.firstWeekday, 1), 7)

        let daysInMonth = range.count

        // Leading blanks: how far the month's first day sits from the
        // region's week start.
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingBlanks = (firstWeekday - weekStart + 7) % 7

        // The formatter must share the calendar's timezone. Otherwise a date at
        // midnight UTC formats a day (and month) off in any other zone — which
        // is exactly the kind of bug that only shows up in another timezone.
        let monthFormatter = DateFormatter()
        monthFormatter.locale = locale
        monthFormatter.timeZone = calendar.timeZone
        monthFormatter.dateFormat = "MMMM"
        let monthName = monthFormatter.string(from: firstOfMonth).uppercased(with: locale)

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = locale
        weekdayFormatter.timeZone = calendar.timeZone
        weekdayFormatter.dateFormat = "EEEE"
        let todayWeekday = weekdayFormatter.string(from: today).uppercased(with: locale)

        var cells: [Cell] = []
        cells.append(contentsOf: (0..<leadingBlanks).map { _ in Cell(day: nil) })

        for day in 1...daysInMonth {
            // The actual weekday in this column, wherever the week starts —
            // weekend stays Saturday/Sunday, not "the last two columns".
            let column = (leadingBlanks + day - 1) % 7
            let weekday = (weekStart - 1 + column) % 7 + 1
            cells.append(Cell(
                day: day,
                isToday: day == todayDay,
                isWeekend: weekday == 1 || weekday == 7,
                hasEvent: eventDays.contains(day)
            ))
        }

        // Pad the final week to seven.
        while cells.count % 7 != 0 { cells.append(Cell(day: nil)) }

        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }

        // Header symbols rotated to the same start, so "S M T W T F S" in
        // Sunday-first regions and "M T W T F S S" in Monday-first ones.
        let symbols = calendar.veryShortWeekdaySymbols
        let headers = (0..<7).map { column -> String in
            let index = (weekStart - 1 + column) % 7
            return symbols.indices.contains(index)
                ? symbols[index].uppercased(with: locale) : ""
        }

        return MonthGrid(
            monthName: monthName,
            todayWeekday: todayWeekday,
            todayDay: todayDay,
            weeks: weeks,
            weekdayHeaders: headers
        )
    }
}
