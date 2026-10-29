import AppKit
import CoreGraphics
import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// Today's column lists only what is still to come; any other day is listed
/// whole; and today's dot stays after the last of its events, because it
/// says the day had something on it.
///
/// Checked on the drawn card rather than on the rule alone, because the rule
/// was never the risk — reading the wrong day's list, or filtering a day that
/// is not today, would pass every test of `CalendarToday` and still be wrong
/// on screen. Each check draws two cards that must look the same and compares
/// them: a card with a finished event against one that never had it.
@Suite("Today's list on the calendar card")
@MainActor
struct CalendarTodayListTests {

    private static let width = NotchLayout.calendarWidth
    /// The day column, and the month grid beside it, in points.
    private static let dayColumn = 0..<(18 + 126)
    private static let monthColumn = (18 + 126 + 12)..<Int(width)

    private typealias Shot = (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int)

    /// Wednesday 14 October 2026, 13:00 — mid-month, so yesterday and
    /// tomorrow are in the same grid.
    private static let now = Calendar.current.date(
        from: DateComponents(year: 2026, month: 10, day: 14, hour: 13)
    )!
    private static let today = 14

    private static func at(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(
            from: DateComponents(year: 2026, month: 10, day: 14, hour: hour, minute: minute)
        )!
    }

    private static let standup = MonthDayEntry(
        title: "Standup", time: "09:30", eventID: "standup", ends: at(hour: 9, minute: 45)
    )
    private static let review = MonthDayEntry(
        title: "Design review", time: "12:30", eventID: "review", ends: at(hour: 13, minute: 30)
    )
    private static let retro = MonthDayEntry(
        title: "Retro", time: "16:00", eventID: "retro", ends: at(hour: 17)
    )

    private func shot(day: Int, entries: [MonthDayEntry], dotted: [Int]? = nil) -> Shot? {
        let payload = EventPayload(
            title: "",
            location: "",
            startsIn: 0,
            hasEvent: false,
            monthEventDays: dotted ?? (entries.isEmpty ? [] : [day]),
            monthEvents: entries.isEmpty ? [] : [MonthDayEvents(day: day, entries: entries)],
            monthWindows: []
        )
        let card = CalendarExpandedView(payload: payload, now: Self.now, selectedDay: day)
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

    private func differences(_ a: Shot, _ b: Shot, x: Range<Int>) -> Int {
        guard a.height == b.height, a.width == b.width else { return .max }
        var differing = 0
        for py in 0..<a.height {
            for px in x where px < a.width {
                let i = py * a.bytesPerRow + px * 4
                if a.bytes[i] != b.bytes[i] || a.bytes[i + 1] != b.bytes[i + 1]
                    || a.bytes[i + 2] != b.bytes[i + 2] { differing += 1 }
            }
        }
        return differing
    }

    @Test("Today lists only what is still to come; a meeting in progress stays")
    func todayDropsFinished() throws {
        let withFinished = try #require(shot(day: Self.today, entries: [Self.standup, Self.review, Self.retro]))
        let without = try #require(shot(day: Self.today, entries: [Self.review, Self.retro]))
        let withEverything = try #require(shot(
            day: Self.today,
            entries: [Self.standup, Self.review, Self.retro].map { MonthDayEntry(
                title: $0.title, time: $0.time, eventID: $0.eventID
            ) }
        ))
        #expect(differences(withFinished, without, x: Self.dayColumn) == 0,
                "the 09:30 standup ended at 09:45 and must not be listed at 13:00")
        // Arrival: the same three, none of them known to have ended, draw a
        // different column. Without this the comparison above would also pass
        // on a card that listed nothing at all.
        #expect(differences(withFinished, withEverything, x: Self.dayColumn) > 0)
    }

    @Test("A past day is listed whole, as it looked when it began")
    func pastDayListedWhole() throws {
        let yesterday = Self.today - 1
        // The same events, ended long before now, against the same events
        // with no ends at all: a past day must not tell them apart.
        let ended = try #require(shot(day: yesterday, entries: [Self.standup, Self.review, Self.retro]))
        let unknown = try #require(shot(
            day: yesterday,
            entries: [Self.standup, Self.review, Self.retro].map { MonthDayEntry(
                title: $0.title, time: $0.time, eventID: $0.eventID
            ) }
        ))
        #expect(differences(ended, unknown, x: Self.dayColumn) == 0)
        // Arrival: the column lists them. Two empty "No events" columns would
        // agree just as well.
        let empty = try #require(shot(day: yesterday, entries: []))
        #expect(differences(ended, empty, x: Self.dayColumn) > 0)
    }

    @Test("When everything today is over, the column says so and today keeps its dot")
    func todayAllOver() throws {
        let allOver = try #require(shot(day: Self.today, entries: [Self.standup]))
        let stillAhead = try #require(shot(day: Self.today, entries: [Self.retro]))
        let neverHad = try #require(shot(day: Self.today, entries: []))
        #expect(differences(allOver, stillAhead, x: Self.monthColumn) == 0,
                "a day that had an event is dotted whether or not it is over")
        // Arrival: the dot is really there, not two empty grids agreeing.
        #expect(differences(allOver, neverHad, x: Self.monthColumn) > 0)
        // Not "No events · This day is clear": the morning had a standup.
        #expect(differences(allOver, neverHad, x: Self.dayColumn) > 0)
    }

    // MARK: - A card left open

    /// A card in a real window with a real clock, so the card's own wait for
    /// the next end runs. Every other test here pins the clock, which turns
    /// that wait off.
    private struct Live {
        let window: NSWindow
        let view: NSView
        func close() { window.orderOut(nil); window.close() }
    }

    private func live(_ entries: [MonthDayEntry], today: Int) -> Live {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let payload = EventPayload(
            title: "", location: "", startsIn: 0, hasEvent: false,
            monthEventDays: [today],
            monthEvents: [MonthDayEvents(day: today, entries: entries)],
            monthWindows: []
        )
        let root = CalendarExpandedView(payload: payload, selectedDay: today)
            .frame(width: Self.width)
            .background(Color.black)
        let size = NSSize(width: Self.width, height: 260)
        // Far off every screen, so nothing is drawn where anyone sees it.
        let origin = CGPoint(x: -20000, y: -20000)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: root)
        view.sizingOptions = []
        window.contentView = view
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        window.orderFrontRegardless()
        return Live(window: window, view: view)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ live: Live) -> Shot? {
        let rect = live.view.bounds
        guard let rep = live.view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        live.view.cacheDisplay(in: rect, to: rep)
        guard let image = rep.cgImage else { return nil }
        let width = image.width, height = image.height, bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height, bytesPerRow)
    }

    /// Async, and waiting with `Task.sleep`: spinning the run loop from a
    /// synchronous test never lets the card's own task run, so it would only
    /// start after the test had already finished looking.
    @Test("A card left open lets go of a meeting when it ends")
    func openCardRedrawsAtTheEnd() async throws {
        let now = Date()
        let calendar = Calendar.current
        // A day boundary inside the wait would change which day is today and
        // test something else entirely.
        let midnight = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        guard midnight.timeIntervalSince(now) > 30 else { return }
        let today = calendar.component(.day, from: now)
        let column = 0..<Int(18 + 126)
        let end = now.addingTimeInterval(4)

        let ending = live([
            MonthDayEntry(title: "Standup", time: "09:30", eventID: "standup", ends: end),
        ], today: today)
        defer { ending.close() }
        // What the column must become: the same day with the meeting already over.
        let over = live([
            MonthDayEntry(title: "Standup", time: "09:30", eventID: "standup", ends: now.addingTimeInterval(-60)),
        ], today: today)
        defer { over.close() }

        try await Task.sleep(for: .seconds(0.3))
        settle(0.05)
        let before = try #require(capture(ending))
        let target = try #require(capture(over))
        // Arrival: the meeting is listed while it runs. Only judged when the
        // picture was taken before the end — a loaded run can be slow enough
        // that the card has already, correctly, let it go.
        if Date() < end {
            #expect(differences(before, target, x: column) > 0, "the running meeting should be listed")
        }

        // Its end is a few seconds away and the card waits half a second past it.
        // Looked at until it changes rather than once after a fixed wait: a
        // loaded run can hold the main actor for seconds, and a test that
        // fails for being slow is not testing the card.
        var remaining = 0
        let deadline = end.addingTimeInterval(30)
        repeat {
            try await Task.sleep(for: .seconds(0.25))
            settle(0.02)
            let after = try #require(capture(ending))
            remaining = differences(after, target, x: column)
        } while remaining != 0 && Date() < deadline
        #expect(remaining == 0, "the card was left open past the end and still lists the meeting")

    }
}
