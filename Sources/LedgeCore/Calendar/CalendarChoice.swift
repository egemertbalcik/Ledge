import Foundation

/// One of the user's event calendars, reduced to what Settings draws and what
/// the filter needs. `EKCalendar` is neither `Sendable` nor available to the
/// layers that draw, so this is what crosses.
public struct CalendarInfo: Equatable, Hashable, Sendable, Identifiable {

    /// `EKCalendar.calendarIdentifier`: what a hidden calendar is stored as.
    public let id: String
    public let title: String

    /// The account it belongs to, as Calendar.app's sidebar names it
    /// ("iCloud", "Google", "On My Mac").
    public let account: String

    /// Where the account sits in that sidebar. Calendar.app's own order is
    /// not something EventKit hands out, so this is the kind of account —
    /// local, then synced, then subscriptions and birthdays — which is the
    /// order it uses for them.
    public let accountRank: Int

    public let red: Double
    public let green: Double
    public let blue: Double

    public init(
        id: String,
        title: String,
        account: String,
        accountRank: Int = 0,
        red: Double = 0.36,
        green: Double = 0.55,
        blue: Double = 0.9
    ) {
        self.id = id
        self.title = title
        self.account = account
        self.accountRank = accountRank
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// One account and its calendars.
    public struct Account: Equatable, Sendable, Identifiable {
        public let title: String
        public let calendars: [CalendarInfo]
        public var id: String { title }
    }

    /// The calendars by account, in sidebar order: accounts by kind, then by
    /// name; calendars by name within each. Names are compared the way a
    /// person reads them (`localizedStandardCompare`), so "Ödev" sits beside
    /// "Okul" and a lowercase name is not sent to the end.
    ///
    /// A group is the account *name* the user sees, not the kind behind it.
    /// macOS files Birthdays and subscribed calendars such as Holidays under
    /// one account called "Other", and Calendar.app shows them as one group,
    /// so they share one here, ordered by name like any other group; the
    /// group takes the earliest place any of its calendars would.
    public static func grouped(_ calendars: [CalendarInfo]) -> [Account] {
        let byAccount = Dictionary(grouping: calendars, by: \.account)
        return byAccount
            .map { title, members in
                Account(
                    title: title,
                    calendars: members.sorted {
                        $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }
                )
            }
            .sorted { a, b in
                let rankA = a.calendars.map(\.accountRank).min() ?? 0
                let rankB = b.calendars.map(\.accountRank).min() ?? 0
                if rankA != rankB { return rankA < rankB }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }
}

/// Which calendars to read events from, given the ones the user hid.
///
/// One rule for every reader — the card, its peek, the month grid and the day
/// list — so the four can never disagree about what a hidden calendar is.
public enum CalendarFilter {

    public enum Scope: Equatable, Sendable {
        /// Nothing is hidden that exists: read every calendar.
        case all
        /// Read these and nothing else.
        case only(Set<String>)
        /// Every calendar is hidden: read nothing.
        ///
        /// Its own case because both ways of saying "no calendars" to
        /// EventKit — `nil` and, as far as anybody can tell, an empty list —
        /// read as "all of them". A user who switched every calendar off
        /// would get every event back.
        case none
    }

    /// - Parameters:
    ///   - calendars: every event calendar that exists right now.
    ///   - hidden: the identifiers the user switched off. Identifiers of
    ///     calendars that no longer exist are ignored, so a deleted
    ///     calendar's leftover entry can never hide anything — and a calendar
    ///     added later is shown, because it was never switched off.
    public static func scope(calendars: [String], hidden: Set<String>) -> Scope {
        guard calendars.contains(where: hidden.contains) else { return .all }
        let shown = Set(calendars.filter { !hidden.contains($0) })
        return shown.isEmpty ? .none : .only(shown)
    }
}
