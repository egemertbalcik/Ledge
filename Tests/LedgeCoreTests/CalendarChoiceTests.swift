import Foundation
import Testing

@testable import LedgeCore

/// Which calendars Ledge reads: the rule, and where the choice is kept.
@Suite("Choosing calendars")
@MainActor
struct CalendarChoiceTests {

    private let all = ["work", "home", "shared"]

    @Test("Nothing hidden reads every calendar")
    func nothingHidden() {
        #expect(CalendarFilter.scope(calendars: all, hidden: []) == .all)
    }

    @Test("A hidden calendar is left out, and only that one")
    func oneHidden() {
        #expect(CalendarFilter.scope(calendars: all, hidden: ["home"]) == .only(["work", "shared"]))
    }

    @Test("Every calendar hidden reads nothing, not everything")
    func everythingHidden() {
        // Reached: each one alone is a real hide.
        for id in all {
            #expect(CalendarFilter.scope(calendars: all, hidden: [id]) != .all)
        }
        // The case that must not fall back: EventKit reads `nil` — and as far
        // as anybody can tell an empty list — as every calendar.
        #expect(CalendarFilter.scope(calendars: all, hidden: Set(all)) == .none)
    }

    @Test("A deleted calendar's leftover entry hides nothing")
    func staleEntriesAreHarmless() {
        #expect(CalendarFilter.scope(calendars: all, hidden: ["gone"]) == .all)
        #expect(CalendarFilter.scope(calendars: all, hidden: ["gone", "home"]) == .only(["work", "shared"]))
        // Not even when it is all that is stored and nothing exists to show:
        // there is nothing hidden that is there.
        #expect(CalendarFilter.scope(calendars: [], hidden: ["gone"]) == .all)
    }

    @Test("A calendar added later is shown without anybody choosing it")
    func newCalendarsAreShown() {
        let before = CalendarFilter.scope(calendars: ["work", "home"], hidden: ["home"])
        #expect(before == .only(["work"]))
        let after = CalendarFilter.scope(calendars: ["work", "home", "new"], hidden: ["home"])
        #expect(after == .only(["work", "new"]))
    }

    @Test("The choice is kept, survives a reload, and is cleared by reset")
    func preferenceRoundTrips() {
        let store = MemoryPreferenceStore()
        let preferences = Preferences(store: store)
        #expect(preferences.hiddenCalendarIDs.isEmpty, "every calendar starts shown")

        preferences.setCalendar("home", shown: false)
        preferences.setCalendar("shared", shown: false)
        #expect(preferences.hiddenCalendarIDs == ["home", "shared"])
        #expect(!preferences.isCalendarShown("home"))
        // Never stored, so shown: that is what makes a new calendar appear.
        #expect(preferences.isCalendarShown("brand-new"))

        let reloaded = Preferences(store: store)
        #expect(reloaded.hiddenCalendarIDs == ["home", "shared"])

        reloaded.setCalendar("home", shown: true)
        #expect(reloaded.hiddenCalendarIDs == ["shared"])

        reloaded.resetToDefaults()
        #expect(reloaded.hiddenCalendarIDs.isEmpty)
        #expect(Preferences(store: store).hiddenCalendarIDs.isEmpty, "reset left it in the store")
    }

    @Test("Switching a calendar to what it already is changes nothing anybody observes")
    func noChurn() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.setCalendar("home", shown: false)
        let writes = WriteCount()
        withObservationTracking { _ = preferences.hiddenCalendars } onChange: { writes.bump() }
        preferences.setCalendar("home", shown: false)
        preferences.setCalendar("work", shown: true)
        // Every change seen sends the calendar card back to the store.
        #expect(writes.value == 0)
        // Reached: a real change is seen.
        preferences.setCalendar("work", shown: false)
        #expect(writes.value == 1)
    }

    @Test("Calendars are listed by account, in sidebar order")
    func groupedByAccount() {
        let grouped = CalendarInfo.grouped([
            CalendarInfo(id: "b", title: "Birthdays", account: "Other", accountRank: 5),
            CalendarInfo(id: "w", title: "Work", account: "iCloud", accountRank: 2),
            CalendarInfo(id: "h", title: "Home", account: "iCloud", accountRank: 2),
            CalendarInfo(id: "g", title: "Team", account: "Google", accountRank: 2),
            CalendarInfo(id: "m", title: "Local", account: "On My Mac", accountRank: 0),
        ])
        #expect(grouped.map(\.title) == ["On My Mac", "Google", "iCloud", "Other"])
        #expect(grouped.first { $0.title == "iCloud" }?.calendars.map(\.title) == ["Home", "Work"])
    }

    @Test("Names sort the way a person reads them, accounts and calendars alike")
    func namesSortAsRead() {
        let grouped = CalendarInfo.grouped([
            CalendarInfo(id: "1", title: "work", account: "Google", accountRank: 2),
            CalendarInfo(id: "2", title: "Ödev", account: "Google", accountRank: 2),
            CalendarInfo(id: "3", title: "Home", account: "Google", accountRank: 2),
            CalendarInfo(id: "4", title: "Team", account: "ege@company.com", accountRank: 2),
        ])
        // Reached: a byte order would put "work" before "Ödev" and "Google"
        // before "ege@…", which is the order this rules out.
        #expect(["work", "Ödev"].sorted() == ["work", "Ödev"])
        #expect(grouped.map(\.title) == ["ege@company.com", "Google"])
        #expect(grouped.last?.calendars.map(\.title) == ["Home", "Ödev", "work"])
    }

    @Test("Birthdays and Holidays share the account macOS files them under")
    func otherIsOneGroup() {
        let grouped = CalendarInfo.grouped([
            CalendarInfo(id: "b", title: "Birthdays", account: "Other", accountRank: 5),
            CalendarInfo(id: "h", title: "Holidays in Türkiye", account: "Other", accountRank: 4),
            CalendarInfo(id: "w", title: "Work", account: "iCloud", accountRank: 1),
        ])
        #expect(grouped.map(\.title) == ["iCloud", "Other"])
        // By name within the group, whatever kind each calendar is.
        #expect(grouped.last?.calendars.map(\.title) == ["Birthdays", "Holidays in Türkiye"])
    }
}

private final class WriteCount: @unchecked Sendable {
    private(set) var value = 0
    func bump() { value += 1 }
}
