import Foundation
import LedgeCore
import CoreGraphics
import SwiftUI
import Testing

@testable import LedgeUI

/// The calendar card with a camera in it — and, just as much, the calendar
/// card without one.
@Suite("The calendar card's self-view")
@MainActor
struct CalendarSelfViewTests {

    /// The card's own seat. Everything here is measured against it, because
    /// the whole placement argument was about a 126pt column inside it.
    private static let width = NotchLayout.calendarWidth

    private func payload(
        day: Int,
        meeting: Bool = true
    ) -> EventPayload {
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
                    MonthDayEntry(title: "Design review", time: "11:00"),
                ])
            ],
            monthWindows: []
        )
    }

    private func drawn(
        day: Int,
        meeting: Bool = true,
        selfView: SelfViewPayload = .off
    ) -> CGSize? {
        // A fixed clock, so the card's "today" is the day being asked about
        // rather than whatever day the suite happens to run on.
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = day
        components.hour = 10
        let now = Calendar.current.date(from: components)
        let card = CalendarExpandedView(
            payload: payload(day: day, meeting: meeting),
            now: now,
            selectedDay: day,
            selfView: selfView
        )
        let renderer = ImageRenderer(content: card.frame(width: Self.width))
        renderer.scale = 2
        return renderer.nsImage?.size
    }

    @Test("Join and the camera segment fit beside every date in a month")
    func fitsEveryDate() {
        // The widest date is the whole argument for dropping Join's own
        // glyph: "30" is 41.9pt of a 126pt column, and the capsule plus the
        // segment has to live in what is left.
        for day in 1...30 {
            let size = drawn(day: day)
            #expect(size != nil, "nothing drawn for day \(day)")
            if let size {
                #expect(
                    size.width <= Self.width + 0.5,
                    "day \(day) overflowed the card (drew \(size.width))"
                )
            }
        }
    }

    @Test("Every face of the self-view draws inside the card")
    func everyFaceFits() {
        for phase in SelfViewPhase.allCases {
            for day in [1, 14, 30] {
                let payload = SelfViewPayload(
                    phase: phase,
                    waitHasLasted: true,
                    countdown: phase == .live ? 8 : nil
                )
                let size = drawn(day: day, selfView: payload)
                #expect(size != nil, "nothing drawn for \(phase) on day \(day)")
                if let size {
                    #expect(
                        size.width <= Self.width + 0.5,
                        "\(phase) overflowed on day \(day) (drew \(size.width))"
                    )
                }
            }
        }
    }

    /// The card's actual pixels, so a test can say what changed and where.
    ///
    /// Sizes alone proved almost nothing here: the frame is drawn *over* the
    /// month and changes no layout, which is the whole point of it, so a
    /// test that compares the rendered size passes just as happily with the
    /// self-view deleted.
    private func pixels(
        day: Int,
        meeting: Bool = true,
        selfView: SelfViewPayload = .off
    ) -> (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int)? {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = day
        components.hour = 10
        let now = Calendar.current.date(from: components)
        let card = CalendarExpandedView(
            payload: payload(day: day, meeting: meeting),
            now: now,
            selectedDay: day,
            selfView: selfView
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

    /// How many pixels differ inside a vertical slice of the card.
    private func differences(
        _ a: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int),
        _ b: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int),
        fromX: Int,
        toX: Int
    ) -> Int {
        var differing = 0
        for y in 0..<min(a.height, b.height) {
            for x in fromX..<min(toX, min(a.width, b.width)) {
                let i = y * a.bytesPerRow + x * 4
                let j = y * b.bytesPerRow + x * 4
                if a.bytes[i] != b.bytes[j]
                    || a.bytes[i + 1] != b.bytes[j + 1]
                    || a.bytes[i + 2] != b.bytes[j + 2] {
                    differing += 1
                }
            }
        }
        return differing
    }

    @Test("The picture covers the month, and leaves the day column alone")
    func theFrameShows() {
        guard let resting = pixels(day: 14),
              let live = pixels(day: 14, selfView: SelfViewPayload(phase: .live)) else {
            Issue.record("the card did not render")
            return
        }
        #expect(resting.width == live.width)
        #expect(resting.height == live.height, "the picture must not change the card's height")

        // Not "something changed": the month dims to nothing under a live
        // picture, so a card with the picture deleted would differ there too
        // and a difference count would pass with the whole feature removed.
        // What is checked is that something is *drawn* where the month was —
        // the fog, and the picture over it — on a card whose ground is black.
        let monthStarts = 18 + 126 + 12
        let lit = litPixels(live, fromX: monthStarts, toX: live.width)
        #expect(lit > 2_000, "the picture must be drawn over the month (lit \(lit) pixels)")

        // And the resting card is still a month: a grid of white digits on
        // black, which is lit in a different, much sparser way.
        let restingLit = litPixels(resting, fromX: monthStarts, toX: resting.width)
        #expect(lit > restingLit, "the picture fills the column the digits only dot")
    }

    /// How many pixels in a slice are brighter than the card's black ground.
    private func litPixels(
        _ shot: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int),
        fromX: Int,
        toX: Int
    ) -> Int {
        var lit = 0
        for y in 0..<shot.height {
            for x in fromX..<min(toX, shot.width) {
                let i = y * shot.bytesPerRow + x * 4
                let luminance = Int(shot.bytes[i]) + Int(shot.bytes[i + 1]) + Int(shot.bytes[i + 2])
                if luminance > 45 { lit += 1 }
            }
        }
        return lit
    }

    @Test("The day column does not move when the picture opens")
    func theDayColumnIsUntouched() {
        // The owner's one condition: the ordinary calendar card does not
        // change. The events, the date and the weekday are the proof — the
        // capsule is excluded because its segment is meant to light up.
        guard let resting = pixels(day: 14),
              let live = pixels(day: 14, selfView: SelfViewPayload(phase: .live)) else {
            Issue.record("the card did not render")
            return
        }
        // Below the 32pt date row: the event list, which must be identical.
        var differing = 0
        let listStartsY = 14 + 12 + 38 + 8
        for y in listStartsY..<min(resting.height, live.height) {
            for x in 0..<(18 + 126) {
                let i = y * resting.bytesPerRow + x * 4
                if resting.bytes[i] != live.bytes[i]
                    || resting.bytes[i + 1] != live.bytes[i + 1]
                    || resting.bytes[i + 2] != live.bytes[i + 2] {
                    differing += 1
                }
            }
        }
        #expect(differing == 0, "the day column changed in \(differing) pixels")
    }

    @Test("A card with no meeting draws no segment at all")
    func noMeetingDrawsNothingExtra() {
        guard let withMeeting = pixels(day: 14),
              let without = pixels(day: 14, meeting: false) else {
            Issue.record("the card did not render")
            return
        }
        // The capsule and its segment are the only difference, and they are
        // in the day column.
        let inTheMonth = differences(withMeeting, without, fromX: 18 + 126 + 12, toX: without.width)
        #expect(inTheMonth == 0, "the month is the same with or without a meeting")
    }

    @Test("A day with no meeting has nowhere for a segment to be")
    func noMeetingNoSegment() {
        // Not a rendering check — the segment is drawn inside `joinButton`,
        // which only exists when there is a link to join. This is the
        // promise the owner asked for in as many words: with no meeting, the
        // card is exactly what it has always been.
        let source = Self.cardSource
        guard let join = source.range(of: "private var joinButton: some View") else {
            Issue.record("the join button has been renamed; this guard needs rewriting")
            return
        }
        let afterJoin = source[join.lowerBound...]
        guard let segment = afterJoin.range(of: "selfViewSegment") else {
            Issue.record("the segment is no longer drawn from the join button")
            return
        }
        let between = afterJoin[afterJoin.startIndex..<segment.lowerBound]
        #expect(
            between.contains("if let url = meetingToJoin"),
            "the segment must be inside the branch that only runs when there is a meeting"
        )
    }

    @Test("A card built with the meeting already over lets the camera go")
    func checksOnTheWayIn() {
        // `onChange` says nothing about a value it is seeing for the first
        // time, and a card can be built with the meeting already ended: it
        // was off screen behind a readout while the clock ran out.
        let source = Self.cardSource
        guard let appear = source.range(of: ".onAppear {\n            if meetingToJoin == nil") else {
            Issue.record("the arrival check has moved; this guard needs rewriting")
            return
        }
        let body = source[appear.lowerBound...].prefix(200)
        #expect(body.contains("selfViewActions.letGo()"))
    }

    @Test("The segment is a person, not a second camera")
    func theGlyphIsAPerson() {
        // Two camera glyphs a few points apart ask "which one starts the
        // call?". Join's own glyph was given up for this; a camera here would
        // spend that for nothing.
        let source = Self.cardSource
        #expect(source.contains("person.crop.square"))
        guard let segment = source.range(of: "private var selfViewSegment") else {
            Issue.record("the segment has been renamed; this guard needs rewriting")
            return
        }
        let body = source[segment.lowerBound...].prefix(1200)
        #expect(body.contains("video.fill") == false, "the segment must not wear a camera")
    }

    @Test("Nothing in the card takes focus")
    func nothingIsFocusable() {
        // Twice now a `.focusable()` on a card has hijacked the window's
        // focus and made every render draw a preview or a dimmed row. The
        // calendar is not going to be the third.
        #expect(Self.cardSource.contains(".focusable(") == false)
    }

    @Test("The frame is drawn over the month, never over the day column")
    func theFrameStaysOnItsHalf() {
        let source = Self.cardSource
        guard let stack = source.range(of: "ZStack {") else {
            Issue.record("the month column is no longer in a stack with the frame")
            return
        }
        let body = source[stack.lowerBound...].prefix(900)
        #expect(body.contains("monthColumn(grid)"))
        #expect(body.contains("SelfViewFrameView"))
        // The left column is built before the stack and is not inside it.
        let left = source.range(of: "leftColumn(grid)")
        #expect(left != nil)
        if let left { #expect(left.lowerBound < stack.lowerBound) }
    }

    static var cardSource: String {
        (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/LedgeUI/Cards/CalendarExpandedView.swift"),
            encoding: .utf8
        )) ?? ""
    }
}
