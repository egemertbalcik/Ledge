import Foundation

/// What the calendar card shows of today: what is still to come.
///
/// Today is the one day the card is looked at to see what is *next*, and a
/// meeting that finished at ten is noise by eleven. Any other day is shown
/// whole — tapping last Monday asks what happened on it, and the answer is
/// all of it, as the day looked when it began.
///
/// The grid is left alone: today's dot stays after its last event ends,
/// because the dot says the day had something on it, and the list is what
/// says what is left.
///
/// Pure, with the clock passed in, so where the line falls is testable
/// without a view or the system time.
public enum CalendarToday {

    /// Today's events with the ones already over taken out. An event in
    /// progress stays until it ends; an all-day event stays all day.
    public static func remaining(_ entries: [MonthDayEntry], at now: Date) -> [MonthDayEntry] {
        entries.filter { !$0.hasEnded(at: now) }
    }

    /// The next moment today's list changes: the soonest end still ahead.
    /// Nil when nothing left today has an end to wait for.
    public static func nextEnd(of entries: [MonthDayEntry], after now: Date) -> Date? {
        entries.compactMap(\.ends).filter { $0 > now }.min()
    }
}
