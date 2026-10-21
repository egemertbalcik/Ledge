import AppKit
import CoreGraphics
import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// What browsing the month must leave alone: the day column says the same
/// thing about today whichever month the grid is showing, and nothing beside
/// the big date may squeeze it.
@Suite("The calendar card while browsing")
@MainActor
struct CalendarPagingTests {

    private static let width = NotchLayout.calendarWidth

    /// Where the day column ends and the month begins, in points.
    private static let dayColumnEnd = 18 + 126
    private static let monthStarts = 18 + 126 + 12

    private typealias Shot = (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int)

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 10))!
    }

    private func payload(day: Int, meeting: Bool) -> EventPayload {
        EventPayload(
            title: "Design review",
            location: "Room 2",
            startsIn: 240,
            endsIn: 240 + 45 * 60,
            hasEvent: true,
            meetingURL: meeting ? "https://zoom.us/j/123456" : nil,
            monthEventDays: [day],
            monthEvents: [
                MonthDayEvents(day: day, entries: [
                    MonthDayEntry(title: "Standup", time: "09:30"),
                ])
            ],
            monthWindows: []
        )
    }

    private func shot(
        now: Date,
        selectedDay: Int?,
        monthOffset: Int = 0,
        meeting: Bool = false
    ) -> Shot? {
        let day = Calendar.current.component(.day, from: now)
        let card = CalendarExpandedView(
            payload: payload(day: day, meeting: meeting),
            now: now,
            selectedDay: selectedDay,
            monthOffset: monthOffset
        )
        .frame(width: Self.width)
        .background(Color.black)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height, bytesPerRow)
    }

    private func pixel(_ s: Shot, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = y * s.bytesPerRow + x * 4
        return (Int(s.bytes[i]), Int(s.bytes[i + 1]), Int(s.bytes[i + 2]))
    }

    /// The bounding box of the pixels that match, inside a region.
    private func bounds(
        _ s: Shot, x: Range<Int>, y: Range<Int>? = nil,
        where match: (Int, Int, Int) -> Bool
    ) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var box: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for py in (y ?? 0..<s.height) where py < s.height {
            for px in x where px < s.width {
                let p = pixel(s, px, py)
                guard match(p.r, p.g, p.b) else { continue }
                if let b = box {
                    box = (min(b.minX, px), max(b.maxX, px), min(b.minY, py), max(b.maxY, py))
                } else {
                    box = (px, px, py, py)
                }
            }
        }
        return box
    }

    private func differences(_ a: Shot, _ b: Shot, x: Range<Int>, y: Range<Int>) -> Int {
        var differing = 0
        for py in y where py < min(a.height, b.height) {
            for px in x where px < min(a.width, b.width) {
                let p = pixel(a, px, py), q = pixel(b, px, py)
                if p.r != q.r || p.g != q.g || p.b != q.b { differing += 1 }
            }
        }
        return differing
    }

    private func count(_ s: Shot, x: Range<Int>, y: Range<Int>, where match: (Int, Int, Int) -> Bool) -> Int {
        var n = 0
        for py in y where py < s.height {
            for px in x where px < s.width {
                let p = pixel(s, px, py)
                if match(p.r, p.g, p.b) { n += 1 }
            }
        }
        return n
    }

    private static func isRed(_ r: Int, _ g: Int, _ b: Int) -> Bool { r > 150 && g < 90 && b < 90 }
    private static func isGreen(_ r: Int, _ g: Int, _ b: Int) -> Bool { g > 120 && r < 110 && b < 110 }
    private static func isLit(_ r: Int, _ g: Int, _ b: Int) -> Bool { r + g + b > 45 }
    private static func isWhite(_ r: Int, _ g: Int, _ b: Int) -> Bool { r > 150 && g > 150 && b > 150 }

    @Test("Browsing to another month does not rename today's weekday")
    func todaysWeekdaySurvivesPaging() {
        // A Tuesday whose day number falls on other weekdays either side:
        // the 20th is a Friday in November 2026 and a Sunday in September.
        let now = Self.date(2026, 10, 20)
        guard let home = shot(now: now, selectedDay: 20),
              let next = shot(now: now, selectedDay: 20, monthOffset: 1),
              let previous = shot(now: now, selectedDay: 20, monthOffset: -1) else {
            Issue.record("the card did not render")
            return
        }
        let left = 0..<Self.dayColumnEnd
        guard let weekday = bounds(home, x: left, where: Self.isRed) else {
            Issue.record("no weekday drawn on the home month")
            return
        }
        let row = max(weekday.minY - 1, 0)..<(weekday.maxY + 2)

        for (name, paged) in [("next", next), ("previous", previous)] {
            // Reached the state in question: the grid is on another month, and
            // the column, still showing today, says so with a month note.
            let all = 0..<min(home.height, paged.height)
            #expect(
                differences(home, paged, x: Self.monthStarts..<home.width, y: all) > 0,
                "the \(name) grid did not move to another month"
            )
            let beyond = (weekday.maxX + 3)..<Self.dayColumnEnd
            #expect(count(home, x: beyond, y: row, where: Self.isLit) == 0)
            #expect(
                count(paged, x: beyond, y: row, where: Self.isLit) > 0,
                "the \(name) month should name today's month beside the weekday"
            )

            // The weekday itself is the same word, drawn in the same place.
            let word = 0..<(weekday.maxX + 2)
            #expect(
                differences(home, paged, x: word, y: row) == 0,
                "today's weekday changed when the grid moved to the \(name) month"
            )
        }
    }

    @Test("The next-event summary keeps today's weekday whichever month is shown")
    func summarySurvivesPaging() {
        // No selection: the summary column, headed by today's weekday and date.
        let now = Self.date(2026, 10, 20)
        guard let next = shot(now: now, selectedDay: nil, monthOffset: 1),
              let previous = shot(now: now, selectedDay: nil, monthOffset: -1) else {
            Issue.record("the card did not render")
            return
        }
        let all = 0..<min(next.height, previous.height)
        #expect(differences(next, previous, x: Self.monthStarts..<next.width, y: all) > 0,
                "the two grids should be different months")
        #expect(bounds(next, x: 0..<Self.dayColumnEnd, where: Self.isRed) != nil,
                "the summary should be headed by a weekday")
        // Nothing in the summary is about the month on show.
        #expect(
            differences(next, previous, x: 0..<Self.dayColumnEnd, y: all) == 0,
            "the summary said something different about today in the two months"
        )
    }

    @Test("Today's Join stays when the grid pages into a shorter month")
    func joinSurvivesAClampedMonth() {
        // 31 January plus a month is clamped to 28 February. The column is
        // still today's, so its Join is still today's meeting.
        let now = Self.date(2027, 1, 31)
        guard let home = shot(now: now, selectedDay: 31, meeting: true),
              let next = shot(now: now, selectedDay: 31, monthOffset: 1, meeting: true) else {
            Issue.record("the card did not render")
            return
        }
        let left = 0..<Self.dayColumnEnd
        let all = 0..<min(home.height, next.height)
        let homeGreen = count(home, x: left, y: all, where: Self.isGreen)
        #expect(homeGreen > 100, "Join should be drawn on today's column (green \(homeGreen))")
        #expect(differences(home, next, x: Self.monthStarts..<home.width, y: all) > 0,
                "the grid did not move to February")
        let nextGreen = count(next, x: left, y: all, where: Self.isGreen)
        #expect(nextGreen == homeGreen, "Join went missing while browsing (green \(homeGreen) -> \(nextGreen))")
    }

    @Test("A month's depth reaches the shell inside the click that pages to it")
    func depthArrivesWithTheMonth() {
        // A month whose neighbour is a different depth, in this Mac's own
        // week start.
        var start = DateComponents(year: 2026, month: 1, day: 10, hour: 10)
        var now = Self.date(2026, 1, 10)
        var nextRows = 0
        for _ in 0..<48 {
            now = Calendar.current.date(from: start)!
            let next = Calendar.current.date(byAdding: .month, value: 1, to: now)!
            nextRows = MonthGrid.make(containing: next).weeks.count
            if nextRows != MonthGrid.make(containing: now).weeks.count { break }
            start.month! += 1
        }

        var reports: [Int] = []
        let size = CGSize(width: Self.width, height: 240)
        let card = CalendarExpandedView(payload: payload(day: 10, meeting: false), now: now) {
            reports.append($0)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let before = reports

        // "Next month": the rightmost 16pt of the header, inside the card's
        // 18pt side and 14pt top padding.
        let point = NSPoint(x: size.width - 18 - 8, y: size.height - (14 + 7))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            ) {
                window.sendEvent(event)
            }
        }
        // Before SwiftUI has drawn the new month: the depth has to be known
        // already, or the shell sizes the card an update after the grid.
        let duringTheClick = reports
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(before.last != nextRows, "the card should start on a month of another depth")
        #expect(reports.last == nextRows, "the click did not page the month (reports \(reports))")
        #expect(
            duringTheClick.last == nextRows,
            "the depth arrived after the click (\(duringTheClick) then \(reports))"
        )
    }

    @Test("Join beside the big date never squeezes the date, on any day of a month")
    func joinNeverSqueezesTheDate() {
        // October 2026 has 31 days. "20" and "30" are the widest dates —
        // "30" is 41.9pt — and they were the two drawn as "…".
        for day in 1...31 {
            let now = Self.date(2026, 10, day)
            guard let plain = shot(now: now, selectedDay: day),
                  let joined = shot(now: now, selectedDay: day, meeting: true) else {
                Issue.record("the card did not render for day \(day)")
                continue
            }
            let left = 0..<Self.dayColumnEnd
            guard let weekday = bounds(plain, x: left, where: Self.isRed) else {
                Issue.record("no weekday drawn on day \(day)")
                continue
            }
            // The 32pt date's row, under the weekday.
            let dateRow = (weekday.maxY + 2)..<(weekday.maxY + 40)
            guard let date = bounds(plain, x: left, y: dateRow, where: Self.isWhite) else {
                Issue.record("no date drawn on day \(day)")
                continue
            }
            // Reached: Join is there, beside this date.
            #expect(
                count(joined, x: left, y: dateRow, where: Self.isGreen) > 100,
                "Join was not drawn on day \(day)"
            )
            // And the date is drawn exactly as it is without it.
            let digits = 0..<(date.maxX + 2)
            #expect(
                differences(plain, joined, x: digits, y: dateRow) == 0,
                "Join squeezed the date on day \(day)"
            )
        }
    }
}
