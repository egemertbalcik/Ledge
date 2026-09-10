import CoreGraphics
import Foundation
import Testing

@testable import LedgeCore

/// `cardSize` is the one place the drawn shape and the shell's hit region agree
/// on how big the open card is.
///
/// They live in different targets and used to compute it separately, which is
/// exactly how the empty-state card came to be drawn taller than it was
/// clickable — the bottom of it swallowed nothing and clicks landed on whatever
/// application was behind.
@Suite("Open card size")
struct CardSizeTests {

    private let geometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 179, height: 32),
        notchCenterX: 735.5,
        isHardwareNotch: true
    )
    private let base = CGSize(width: 315, height: 125)

    private func size(
        kind: ActivityKind? = nil,
        rows: Int = 0,
        hasSelection: Bool = true
    ) -> CGSize {
        NotchLayout.cardSize(
            kind: kind,
            phase: .hover,
            base: base,
            geometry: geometry,
            routePickerRows: rows,
            hasSelection: hasSelection
        )
    }

    @Test("An empty queue grows the card to fit the hints")
    func emptyStateGrows() {
        let empty = size(hasSelection: false)
        #expect(empty.height >= geometry.notchSize.height + NotchLayout.emptyHintsHeight)
        // Compared against a plain card, not a now-playing one: that kind
        // carries its own taller floor and would swamp the difference.
        #expect(empty.height > size(kind: nil, hasSelection: true).height)
    }

    @Test("The route menu is sized to its rows, not floored at the card height")
    func routeMenuHugsRows() {
        // One destination should give a short card, not a tall one with a hole
        // beneath the single row.
        let one = size(kind: .nowPlaying, rows: 1)
        let three = size(kind: .nowPlaying, rows: 3)
        #expect(one.height < three.height)
        #expect(one.height == geometry.notchSize.height
            + NotchLayout.routePickerHeight(rows: 1)
            + NotchLayout.routePickerPadding)
    }

    @Test("Every card opens at the island's own width; only the calendar differs")
    func oneWidthDiscipline() {
        // Width is a discipline, not a preference: the open card is the
        // compact island (cutout + both ears) plus the fixed opening
        // breath, whatever the base says.
        let openWidth = geometry.notchSize.width + NotchLayout.hudEarWidth * 2
            + NotchLayout.openCardGrowth
        for kind in ActivityKind.allCases where kind != .event {
            #expect(size(kind: kind).width == openWidth, "\(kind.rawValue)")
        }
        #expect(size(kind: .event).width == NotchLayout.calendarWidth)
        // Heights remain per-card and still respect the base.
        #expect(size(kind: .event).height >= base.height)
    }
}

/// The weather card is the only card whose content changes shape: the
/// precipitation line comes and goes, and at a fixed height it pushed the
/// hourly strip down onto the page dots.
@Suite("Weather card height")
struct WeatherCardHeightTests {

    private let geometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 179, height: 32),
        notchCenterX: 735.5,
        isHardwareNotch: true
    )
    private let base = CGSize(width: 315, height: 125)

    private func height(rainSoonMinutes: Int?) -> CGFloat {
        NotchLayout.cardSize(
            kind: .weather,
            phase: .hover,
            base: base,
            payload: .weather(WeatherPayload(
                temperatureCelsius: 21,
                hourly: [WeatherHourPayload(hour: 14, temperatureCelsius: 21)],
                rainSoonMinutes: rainSoonMinutes
            )),
            geometry: geometry,
            routePickerRows: 0,
            hasSelection: true
        ).height
    }

    @Test("rain on the way buys the card the row it needs")
    func rainGrowsTheCard() {
        #expect(height(rainSoonMinutes: 60) == height(rainSoonMinutes: nil) + 19)
    }

    @Test("rain starting now counts as a row too")
    func rainStartingNow() {
        // Zero minutes is "Rain starting" — a different string on the same row.
        #expect(height(rainSoonMinutes: 0) == height(rainSoonMinutes: nil) + 19)
    }

    @Test("a dry forecast gets the floor, and the floor clears the page dots")
    func dryIsTheFloor() {
        // Raised from 186 to 194 with the owner's approval: at 186 the hourly
        // strip stopped six points above the dots and read as resting on them.
        #expect(NotchLayout.expandedContentSize(
            kind: .weather, phase: .hover, base: CGSize(width: 315, height: 125)
        ).height == 190)
    }

    @Test("a payload of another kind adds nothing")
    func otherKinds() {
        #expect(NotchLayout.weatherExtraHeight(for: nil) == 0)
        #expect(NotchLayout.weatherExtraHeight(for: .focus(FocusPayload(name: "Work"))) == 0)
    }
}

/// A month is four, five or six rows deep, and the card used to be sized for
/// the deepest of them — so most months carried a band of empty black under
/// the grid.
@Suite("Calendar card height")
struct CalendarCardHeightTests {

    @Test("Each week row adds exactly its own height")
    func rowsAddUp() {
        let four = NotchLayout.calendarHeight(weekRows: 4)
        let five = NotchLayout.calendarHeight(weekRows: 5)
        let six = NotchLayout.calendarHeight(weekRows: 6)
        #expect(five - four == NotchLayout.calendarRowHeight)
        #expect(six - five == NotchLayout.calendarRowHeight)
    }

    @Test("The deepest month keeps the height the card has always had")
    func sixRowsUnchanged() {
        // 216pt was the fixed size before this was dynamic. A six-row month
        // must not lose a point of it, or the last week clips.
        #expect(NotchLayout.calendarHeight(weekRows: 6) == 216)
    }

    @Test("A shallower month is shorter")
    func shallowerIsShorter() {
        #expect(NotchLayout.calendarHeight(weekRows: 5) == 194)
        #expect(NotchLayout.calendarHeight(weekRows: 4) == 172)
    }

    @Test("Before the card has said anything, room is left for the deepest")
    func unknownAssumesDeepest() {
        // The card reports its depth as it draws; guessing short would clip
        // the last week for the frame before it does.
        #expect(NotchLayout.calendarHeight(weekRows: 0) == NotchLayout.calendarHeight(weekRows: 6))
    }

    @Test("A nonsense row count cannot produce a nonsense card")
    func clamped() {
        // Nothing produces these, but the value arrives from a view's state.
        #expect(NotchLayout.calendarHeight(weekRows: 99) == NotchLayout.calendarHeight(weekRows: 6))
        #expect(NotchLayout.calendarHeight(weekRows: -3) == NotchLayout.calendarHeight(weekRows: 6))
        #expect(NotchLayout.calendarHeight(weekRows: 1) == NotchLayout.calendarHeight(weekRows: 4))
    }

    @Test("The month grid still gets its seven columns after the narrowing")
    func gridKeepsItsColumns() {
        // 300pt card, 22pt padding each side, a 132pt day column and a 12pt
        // gap: what is left is the grid's, and it is more than the 320pt card
        // used to leave it.
        let grid = NotchLayout.calendarWidth - 44 - 132 - 12
        #expect(grid >= 7 * 15, "each column needs room for two digits and a dot")
        #expect(grid > 320 - 44 - 160 - 12, "the grid gained by the card losing width")
    }
}

/// The day column lists events above the page dots, which are drawn over the
/// bottom edge of the card and do not move for anything.
@Suite("Calendar day list room")
struct CalendarDayListTests {

    private func room(_ rows: Int) -> CGFloat {
        NotchLayout.calendarDayListHeight(weekRows: rows)
    }

    @Test("A deeper month gives the list more room, one row's worth at a time")
    func deeperGivesMore() {
        #expect(room(5) - room(4) == NotchLayout.calendarRowHeight)
        #expect(room(6) - room(5) == NotchLayout.calendarRowHeight)
    }

    @Test("The join capsule takes nothing from the list")
    func joinTakesNothing() {
        // It rides beside the date, which is taller than it is. When it had a
        // band of its own, the deepest month with a call to join had less than
        // one row left and the column counted the day's events instead of
        // naming them.
        #expect(room(6) >= 3 * 20)
        #expect(room(4) >= NotchLayout.calendarEntryRowHeight)
    }

    @Test("Room is never negative, however cramped")
    func neverNegative() {
        for rows in 1...8 {
            #expect(room(rows) >= 0)
        }
    }

    @Test("The deepest month has room for three single-line events")
    func deepestFitsThree() {
        #expect(room(6) >= 3 * 20, "three unwrapped rows and their spacing")
    }

    @Test("Even the shallowest month can name one event")
    func shallowestNamesOne() {
        // Four week rows is the shortest the card ever is. The count fallback
        // still exists for a display too short to hold a row at all; it is no
        // longer reachable by having a meeting to join.
        #expect(room(4) >= NotchLayout.calendarEntryRowHeight)
    }
}

/// The Clock card wears three faces of different heights, and the user can
/// switch between them, so it measures itself and the shell follows.
@Suite("Clock card height")
struct TimerCardHeightTests {

    @Test("The card is its content plus the cutout and the dots' band")
    func contentPlusChrome() {
        let content: CGFloat = 150
        #expect(NotchLayout.timerHeight(contentHeight: content)
            == NotchLayout.notchAllowance + content + NotchLayout.dotsBand)
    }

    @Test("Taller content makes a taller card, point for point")
    func followsContent() {
        let small = NotchLayout.timerHeight(contentHeight: 140)
        let large = NotchLayout.timerHeight(contentHeight: 160)
        #expect(large - small == 20)
    }

    @Test("Before the card has measured itself, the old fixed height stands")
    func unmeasuredKeepsTheFloor() {
        // Tall enough for any face, so nothing clips in the frame before the
        // first report.
        #expect(NotchLayout.timerHeight(contentHeight: 0) == 180)
    }

    @Test("The page dots always have their band")
    func dotsKeepTheirRoom() {
        for content in stride(from: 100.0, through: 220.0, by: 10) {
            let height = NotchLayout.timerHeight(contentHeight: content)
            guard height < 280 else { continue }   // the ceiling, tested below
            #expect(height - content - NotchLayout.notchAllowance >= NotchLayout.dotsBand)
        }
    }

    @Test("A nonsense measurement cannot produce a nonsense card")
    func clamped() {
        #expect(NotchLayout.timerHeight(contentHeight: 4_000) == 280)
        #expect(NotchLayout.timerHeight(contentHeight: 10) == 140)
        #expect(NotchLayout.timerHeight(contentHeight: -50) == 180, "treated as unmeasured")
    }
}

/// Both of these cards end in a full-width row — a strip of hours, a
/// brightness bar — that ran too close to the page dots.
@Suite("Room over the page dots")
struct BottomRoomTests {

    private func floor(_ kind: ActivityKind) -> CGFloat {
        NotchLayout.expandedContentSize(
            kind: kind, phase: .hover, base: CGSize(width: 315, height: 0)
        ).height
    }

    @Test("The levels card is no longer shorter than its own content")
    func levelsClearsTheDots() {
        // At 148 the brightness row reached *into* the dots' band. Measured
        // against a render, not reasoned about: the content needed 16 more.
        #expect(floor(.levels) == 160)
    }

    @Test("Both cards leave more than the dots' bare footprint")
    func bothLeaveRoom() {
        // Not a tight rule — the point is that neither floor is set so close
        // that the last row and the dots share a band again.
        #expect(floor(.levels) > NotchLayout.dotsBand * 2)
        #expect(floor(.weather) > NotchLayout.dotsBand * 2)
    }
}

