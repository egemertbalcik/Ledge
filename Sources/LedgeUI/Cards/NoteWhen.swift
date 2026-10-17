import Foundation

/// When a note was last edited, in the order a person thinks of it.
///
/// Relative and short, because the column it sits in is beside a title that
/// wants every point it can get, and because "12 Oct 2026, 14:26" answers a
/// question nobody asked of a note they wrote this morning.
///
/// Pure, and in `LedgeUI` rather than the card, so every one of these can be
/// checked without drawing anything.
///
/// The order is minutes, hours, Yesterday, weekday, date — smallest unit that
/// still says something. A note written twenty minutes ago reads as "20m"
/// whether or not midnight happened in between, because twenty minutes is the
/// more useful fact; "Yesterday" takes over once the hours would start
/// rounding to something uninformative. And "Yesterday" means the calendar day
/// before, not twenty-four hours, so a note from yesterday afternoon does not
/// read as "22h".
public enum NoteWhen {

    public static func label(_ editedAt: TimeInterval, now: Date,
                             calendar: Calendar = .current) -> String {
        let edited = Date(timeIntervalSince1970: editedAt)
        let elapsed = now.timeIntervalSince(edited)

        // The future, which a clock change or a file copied from another Mac
        // can produce. Shown as now rather than as a negative minute.
        if elapsed < 60 { return "now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }

        let today = calendar.startOfDay(for: now)
        if edited >= today { return "\(Int(elapsed / 3600))h" }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return dayAndMonth(edited, now: now, calendar: calendar)
        }
        if edited >= yesterday { return "Yesterday" }
        // Within the week, by weekday name: "Tue" says more than "4d" about a
        // note somebody is trying to remember writing.
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today), edited >= weekAgo {
            return edited.formatted(.dateTime.weekday(.abbreviated))
        }
        return dayAndMonth(edited, now: now, calendar: calendar)
    }

    /// The year only when it is not this one. A note from March does not need
    /// to say 2026 in a column 40 points wide.
    private static func dayAndMonth(_ edited: Date, now: Date,
                                    calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: edited)
            == calendar.component(.year, from: now)
        return sameYear
            ? edited.formatted(.dateTime.day().month(.abbreviated))
            : edited.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
