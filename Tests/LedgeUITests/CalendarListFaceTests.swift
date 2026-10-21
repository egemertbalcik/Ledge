import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// What the Calendar card's page shows of the user's calendars.
@Suite("The calendar page's list")
struct CalendarListFaceTests {

    private let calendars = [
        CalendarInfo(id: "w", title: "Work", account: "iCloud", accountRank: 1),
        CalendarInfo(id: "h", title: "Home", account: "iCloud", accountRank: 1),
        CalendarInfo(id: "b", title: "Birthdays", account: "Other", accountRank: 5),
    ]

    @Test("Without the grant there is nothing, however many calendars there are")
    func nothingWithoutTheGrant() {
        // Reached: the same calendars with the grant are a list.
        guard case .list = CalendarListFace(granted: true, calendars: calendars, isShown: { _ in true }) else {
            Issue.record("granted calendars should be listed")
            return
        }
        #expect(CalendarListFace(granted: false, calendars: calendars, isShown: { _ in true }) == .absent)
    }

    @Test("Granted with no calendars is its own quiet state")
    func noCalendars() {
        #expect(CalendarListFace(granted: true, calendars: [], isShown: { _ in true }) == .noCalendars)
    }

    @Test("The warning is there when every calendar is off, and only then")
    func everyCalendarOffWarns() {
        let allOff = CalendarListFace(granted: true, calendars: calendars, isShown: { _ in false })
        let oneOn = CalendarListFace(granted: true, calendars: calendars, isShown: { $0 == "b" })
        let accounts = CalendarInfo.grouped(calendars)
        #expect(allOff == .list(accounts, everyCalendarOff: true))
        #expect(oneOn == .list(accounts, everyCalendarOff: false))
    }

    @Test("The calendar switches stay live while the card is switched off")
    func switchesStayLive() {
        let source = CardsTabSource.cardsTab
        guard let start = source.range(of: "private var calendars: some View"),
              let end = source.range(of: "// MARK: - Weather", range: start.upperBound..<source.endIndex)
        else {
            Issue.record("the calendar section has moved; this guard needs rewriting")
            return
        }
        let section = source[start.lowerBound..<end.lowerBound]
        // Reached: this is the section with the switches in it.
        #expect(section.contains("Toggle(isOn:"))
        #expect(!section.contains(".disabled("), "a choice made ahead of time must stay changeable")
    }

    @Test("Search lands on the accounts themselves, not only on the empty state")
    func searchLandsOnTheList() {
        let source = CardsTabSource.cardsTab
        guard let list = source.range(of: "case .list(let accounts"),
              let end = source.range(of: "// MARK: - Weather", range: list.upperBound..<source.endIndex)
        else {
            Issue.record("the calendar section has moved; this guard needs rewriting")
            return
        }
        let branch = source[list.lowerBound..<end.lowerBound]
        #expect(branch.contains("ForEach(accounts)"), "reached the branch that draws the accounts")
        #expect(branch.contains(#".searchRow("calendarList""#))
    }
}

private enum CardsTabSource {
    static var cardsTab: String {
        (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/LedgeUI/Settings/CardsSettingsTab.swift"),
            encoding: .utf8
        )) ?? ""
    }
}
