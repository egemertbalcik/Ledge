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

    @Test("The levels card measures itself rather than taking a fixed height")
    func levelsMeasuresItself() {
        // It was 160: right when the card was two bars and nothing else, and
        // wrong the moment it could hold one row or four — an output, a
        // built-in panel, an external one, and a sentence under any of them.
        // At 160 the external display's explanation ran through the page dots
        // and off the bottom of the card, which is the one failure the
        // island's own shape hides from you.
        //
        // Unmeasured, it takes the simple card's floor, which is tall enough
        // for any of them and so can only ever be too generous.
        #expect(floor(.levels) == NotchLayout.simpleCardHeight(0))
        // And it grows with what it reports.
        let tall = NotchLayout.expandedContentSize(
            kind: .levels, phase: .hover, base: CGSize(width: 315, height: 0),
            cardContentHeight: 180
        ).height
        #expect(tall > floor(.levels), "the card did not take its own measurement")
    }

    @Test("Both cards leave more than the dots' bare footprint")
    func bothLeaveRoom() {
        // Not a tight rule — the point is that neither floor is set so close
        // that the last row and the dots share a band again.
        #expect(floor(.levels) > NotchLayout.dotsBand * 2)
        #expect(floor(.weather) > NotchLayout.dotsBand * 2)
    }

    // MARK: - Width

    private func geometry(scale: CGFloat) -> NotchGeometry {
        NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: 735,
            isHardwareNotch: true,
            displayScale: scale
        )
    }

    @Test("A card is the island's width plus the growth, and nothing per-card")
    func widthIsOneRule() {
        let ears: CGFloat = 44
        let width = NotchLayout.cardWidth(kind: nil, geometry: geometry(scale: 1), earWidth: ears)
        #expect(width == 179 + ears * 2 + NotchLayout.openCardGrowth)
        for kind in [ActivityKind.nowPlaying, .weather, .timer, .power] {
            #expect(NotchLayout.cardWidth(kind: kind, geometry: geometry(scale: 1), earWidth: ears)
                == width)
        }
    }

    /// Only the part the app chose scales. The cutout is hardware and already
    /// differs between Macs; scaling it again would count that difference
    /// twice.
    @Test("A bigger panel widens the ears, not the cutout")
    func widthScalesOnlyWhatWeChose() {
        let small = NotchLayout.cardWidth(kind: nil, geometry: geometry(scale: 1), earWidth: 44)
        let large = NotchLayout.cardWidth(kind: nil, geometry: geometry(scale: 1.2), earWidth: 44)
        #expect(large > small)
        #expect(abs((large - 179) - (small - 179) * 1.2) < 0.001, "binary floating point")
    }

    @Test("The calendar keeps its own seat when the island is narrower")
    func calendarHasItsOwnWidth() {
        let ears = NotchLayout.defaultEarWidth
        // Seven columns beside a day column do not compress below this.
        #expect(NotchLayout.cardWidth(kind: .event, geometry: geometry(scale: 1), earWidth: ears)
            == NotchLayout.calendarWidth)
        #expect(NotchLayout.cardWidth(kind: .event, geometry: geometry(scale: 1.2), earWidth: ears)
            == NotchLayout.calendarWidth * 1.2)
        #expect(NotchLayout.cardWidth(kind: .event, geometry: geometry(scale: 1), earWidth: ears)
            > NotchLayout.cardWidth(kind: nil, geometry: geometry(scale: 1), earWidth: ears),
            "at the default ears the calendar is the wider one")
    }

    /// A floor, not a fixed width: wide ears carry every other card past the
    /// calendar's own number, and a calendar sitting 70pt narrower than its
    /// neighbours makes every swipe onto it a visible step inward.
    @Test("Wide ears carry the calendar with them")
    func calendarFollowsWideEars() {
        let generic = NotchLayout.cardWidth(kind: nil, geometry: geometry(scale: 1), earWidth: 90)
        #expect(generic > NotchLayout.calendarWidth)
        #expect(NotchLayout.cardWidth(kind: .event, geometry: geometry(scale: 1), earWidth: 90)
            == generic)
    }

    // MARK: - The ends of the width preference

    /// The ears are a preference with a range, and both ends of it have to
    /// produce a card somebody can use: narrow enough to be worth setting,
    /// wide enough not to swallow the screen.
    @Test("Both ends of the ear preference give a sane card")
    func earPreferenceBounds() {
        let reference = geometry(scale: 1)

        let narrowest = NotchLayout.cardWidth(kind: nil, geometry: reference, earWidth: 36)
        #expect(narrowest == 179 + 36 * 2 + NotchLayout.openCardGrowth)
        #expect(narrowest > reference.notchSize.width, "a card is never narrower than its cutout")

        let widest = NotchLayout.cardWidth(kind: nil, geometry: reference, earWidth: 90)
        #expect(widest == 179 + 90 * 2 + NotchLayout.openCardGrowth)
        #expect(widest < reference.screenSize.width / 2, "and never half the screen")
    }

    /// A hand-edited or corrupted defaults database is the source here, and
    /// NaN slips through `min`/`max` intact — the stdlib returns its first
    /// argument when a comparison fails.
    @Test("Nonsense in the preference cannot reach the card")
    func earPreferenceIsSanitized() {
        #expect(NotchLayout.sanitizedEarWidth(.nan) == NotchLayout.defaultEarWidth)
        #expect(NotchLayout.sanitizedEarWidth(.infinity) == NotchLayout.defaultEarWidth,
            "not finite, so not a width — the clamp would happily return it")
        #expect(NotchLayout.sanitizedEarWidth(4_000) == 90)
        #expect(NotchLayout.sanitizedEarWidth(-10) == 36)
        #expect(NotchLayout.sanitizedEarWidth(44) == 44)

        let reference = geometry(scale: 1)
        #expect(NotchLayout.cardWidth(kind: nil, geometry: reference, earWidth: 4_000)
            == 179 + 90 * 2 + NotchLayout.openCardGrowth, "clamped, not obeyed")
        #expect(NotchLayout.cardWidth(kind: nil, geometry: reference, earWidth: .nan)
            == NotchLayout.cardWidth(kind: nil, geometry: reference,
                                     earWidth: NotchLayout.defaultEarWidth))
    }

    /// The narrowing that prompted all of this took every card from 301 to
    /// 283, and no font size moved.
    @Test("The default ears put the reference card at 275")
    func defaultWidthAtReference() {
        #expect(NotchLayout.defaultEarWidth == 48)
        let width = NotchLayout.cardWidth(
            kind: nil, geometry: geometry(scale: 1), earWidth: NotchLayout.defaultEarWidth
        )
        #expect(width == 275)
    }

    /// What the ears give up when they narrow comes off the gap beside the
    /// cutout, not off the outer margin — the content is centred, so half of
    /// any narrowing would otherwise be taken from the wrong side.
    @Test("A narrowing is owed to the inner gap")
    func narrowingComesFromTheInside() {
        let nudge = max(0, (NotchLayout.referenceEarWidth - NotchLayout.defaultEarWidth) / 2)
        #expect(nudge == 2, "half of the four points each ear lost")
        #expect(NotchLayout.referenceEarWidth == 52)
        // Nobody at or above the reference width is moved at all.
        #expect(max(0, (NotchLayout.referenceEarWidth - 52) / 2) == 0)
        #expect(max(0, (NotchLayout.referenceEarWidth - 90) / 2) == 0)
    }

    /// One shape, two states of it. The card used to sit 16pt wider than the
    /// island it grew out of, which read as two shapes rather than one opening.
    @Test("The island and the card are the same width")
    func islandMatchesTheCard() {
        #expect(NotchLayout.openCardGrowth == 0)
        let reference = geometry(scale: 1)
        let island = reference.notchSize.width + NotchLayout.defaultEarWidth * 2
        #expect(island == 275)
        #expect(NotchLayout.cardWidth(kind: nil, geometry: reference,
                                      earWidth: NotchLayout.defaultEarWidth) == island)
    }

    /// And the same at any ear width and any Mac, since both are the same
    /// expression now.
    @Test("They stay equal wherever the preference is set")
    func islandTracksTheCard() {
        for ears in [CGFloat(36), 44, 52, 70, 90] {
            for scale in [CGFloat(1.0), 1.18] {
                let geo = geometry(scale: scale)
                let island = geo.notchSize.width + ears * 2 * scale
                #expect(abs(NotchLayout.cardWidth(kind: nil, geometry: geo, earWidth: ears)
                    - island) < 0.001)
            }
        }
    }

    /// A display with no cutout has no hardware to be narrow for, and its
    /// stand-in is 53pt narrower than a real one — which was dragging every
    /// card down with it.
    @Test("A card on a display with no cutout has a floor")
    func syntheticDisplayFloor() {
        let synthetic = NotchGeometry.simulated(screenSize: CGSize(width: 1920, height: 1080))
        #expect(!synthetic.isHardwareNotch)
        #expect(NotchLayout.cardWidth(kind: nil, geometry: synthetic,
                                      earWidth: NotchLayout.defaultEarWidth)
            == NotchLayout.syntheticMinimumWidth)
    }

    @Test("Wide ears carry a cutout-less card past its floor")
    func syntheticFloorYieldsToWideEars() {
        let synthetic = NotchGeometry.simulated(screenSize: CGSize(width: 1920, height: 1080))
        #expect(NotchLayout.cardWidth(kind: nil, geometry: synthetic, earWidth: 90)
            == 126 + 90 * 2 + NotchLayout.openCardGrowth)
    }

    /// The floor is the cards' alone: the compact island is the shape sitting
    /// beside a cutout, and it follows the preference wherever it is drawn.
    @Test("The floor does not reach a real Mac's card")
    func floorIsForSyntheticOnly() {
        let real = geometry(scale: 1)
        let narrow = NotchLayout.cardWidth(kind: nil, geometry: real, earWidth: 36)
        #expect(narrow == 179 + 36 * 2 + NotchLayout.openCardGrowth)
        #expect(narrow < NotchLayout.syntheticMinimumWidth, "a narrow preference stays narrow")
    }

    /// Production lays a card out in reference units and scales the result, so
    /// what the *content* gets is the card width divided by the scale — and a
    /// bigger notch eats into it, rather than the content growing to match.
    @Test("Content is laid out in reference units, scale applied after")
    func contentUnitsAreReference() {
        let big = NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 200, height: 38),
            notchCenterX: 735, isHardwareNotch: true, displayScale: 1.18
        )
        let ears = NotchLayout.defaultEarWidth
        let layoutWidth = NotchLayout.cardWidth(kind: nil, geometry: big, earWidth: ears)
            / big.displayScale
        #expect(layoutWidth
            < NotchLayout.cardWidth(kind: nil, geometry: geometry(scale: 1), earWidth: ears))
        #expect(layoutWidth > 250, "but never so tight that the content has nowhere to go")
    }

    /// The width the whole card is sized to must be the width this function
    /// says — they were the same expression written twice, and the preview
    /// gallery quietly used a third number.
    @Test("Card sizing asks the same question")
    func sizingAgreesWithTheRule() {
        for kind in [ActivityKind.nowPlaying, .event] {
            let size = NotchLayout.cardSize(
                kind: kind, phase: .expanded, base: CGSize(width: 0, height: 140),
                geometry: geometry(scale: 1.2), routePickerRows: 0, hasSelection: true,
                earWidth: 44
            )
            #expect(size.width
                == NotchLayout.cardWidth(kind: kind, geometry: geometry(scale: 1.2), earWidth: 44))
        }
    }

    // MARK: - The simple cards size to their content

    /// A Focus card is a 46pt circle and two lines. It used to take the height
    /// *preference* as a floor like every other card, which is how 66pt of
    /// content came out 170pt tall with ninety points of black under it.
    @Test("A simple card is its content, the cutout, and the dots")
    func simpleCardFollowsItsContent() {
        let height = NotchLayout.simpleCardHeight(66)
        #expect(height == NotchLayout.referenceNotchHeight + 66 + NotchLayout.dotsBand)
        #expect(NotchLayout.simpleCardHeight(120) > height, "taller content, taller card")
    }

    @Test("Before the card has measured itself, the old fixed height stands")
    func simpleCardBeforeMeasurement() {
        #expect(NotchLayout.simpleCardHeight(0) == 132)
        #expect(NotchLayout.simpleCardHeight(.nan) == 132)
        #expect(NotchLayout.simpleCardHeight(-40) == 132)
    }

    @Test("It cannot collapse to nothing, nor run away")
    func simpleCardIsBounded() {
        #expect(NotchLayout.simpleCardHeight(1) == 96)
        #expect(NotchLayout.simpleCardHeight(10_000) == 220)
    }

    /// A taller cutout moves the whole budget with it, exactly as the Clock
    /// card's own height does.
    @Test("A taller cutout moves it")
    func simpleCardFollowsTheCutout() {
        #expect(NotchLayout.simpleCardHeight(66, notchHeight: 38)
            == 38 + 66 + NotchLayout.dotsBand)
        #expect(abs(NotchLayout.simpleCardHeight(0, notchHeight: 38)
            - (132 + (38 - NotchLayout.referenceNotchHeight))) < 0.001)
    }

    /// The preference still sets the cards where a taller one buys something,
    /// and no longer sets the ones where it only bought a hole.
    @Test("The height preference no longer floors a simple card")
    func preferenceDoesNotFloorSimpleCards() {
        let tallPreference = CGSize(width: 0, height: 300)
        let focus = NotchLayout.expandedContentSize(
            kind: .focus, phase: .expanded, base: tallPreference, cardContentHeight: 66
        )
        #expect(focus.height == NotchLayout.referenceNotchHeight + 66 + NotchLayout.dotsBand,
            "its content, not the slider")
        let media = NotchLayout.expandedContentSize(
            kind: .nowPlaying, phase: .expanded, base: tallPreference
        )
        #expect(media.height == 300, "still the slider's to set")
    }

    /// The island and the card are one width on *every* Mac, not only the
    /// reference one. The compact phases used the raw ear preference while the
    /// cards scaled it, so a 16-inch drew a 296pt island under a 313pt card.
    @Test("Island and card stay equal at every scale")
    func islandMatchesCardAtEveryScale() {
        for (notch, scale) in [(CGFloat(179), CGFloat(1.0)), (190, 1.03), (200, 1.18)] {
            let geo = NotchGeometry(
                screenSize: CGSize(width: 1470, height: 956),
                notchSize: CGSize(width: notch, height: 32),
                notchCenterX: 735, isHardwareNotch: true, displayScale: scale
            )
            let island = NotchLayout.hud(geo, bottomRadius: 12, gutterRadius: 8).bodySize.width
            let card = NotchLayout.cardWidth(kind: nil, geometry: geo)
            #expect(abs(island - card) < 0.001,
                "island \(island) against card \(card) at scale \(scale)")
        }
    }

    @Test("A peek is the same width as the island it grows from")
    func peekMatchesTheIsland() {
        let geo = NotchGeometry(
            screenSize: CGSize(width: 1728, height: 1117),
            notchSize: CGSize(width: 200, height: 38),
            notchCenterX: 864, isHardwareNotch: true, displayScale: 1.18
        )
        let peek = NotchLayout.peek(geo, bottomRadius: 12, gutterRadius: 8).bodySize.width
        let hud = NotchLayout.hud(geo, bottomRadius: 12, gutterRadius: 8).bodySize.width
        #expect(abs(peek - hud) < 0.001)
    }
}


/// Where the detached satellite sits.
///
/// The view drew it from a seat computed inline while the shell hit-tested the
/// island's bounding box, which does not contain the satellite at all — so a
/// satellite pushed out by the offset preference was drawn somewhere the
/// pointer was never told about. One rectangle now answers all three: drawing,
/// hover, and which card a click belongs to.
@Suite("The satellite's seat")
struct SatelliteSeatTests {

    private func geometry(
        scale: CGFloat, notch: CGFloat = 179, cutoutHeight: CGFloat = 32
    ) -> NotchGeometry {
        NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: notch, height: cutoutHeight),
            notchCenterX: 735, isHardwareNotch: true, displayScale: scale
        )
    }

    private func island(_ geometry: NotchGeometry) -> CGSize {
        NotchLayout.hud(geometry, bottomRadius: 12, gutterRadius: 8).boundingSize
    }

    @Test("It sits past the island's trailing edge, not inside it")
    func sitsOutside() {
        let geo = geometry(scale: 1)
        let size = island(geo)
        let seat = NotchLayout.satelliteRect(
            islandSize: size, geometry: geo, gutterRadius: 8, offset: 5
        )
        #expect(seat.width == geo.notchSize.height + 1, "a circle the height of the cutout")
        #expect(seat.midY == size.height / 2, "vertically centred on the island")
        #expect(seat.maxX > size.width - NotchLayout.earWidth(for: geo),
            "past the ear the island gives up while it is out")
    }

    /// The nudge is why this exists: at the far end of its range the circle is
    /// well outside the island, which is exactly where hit testing used to
    /// stop.
    @Test("The offset moves it, and the rectangle moves with it")
    func offsetMovesIt() {
        let geo = geometry(scale: 1)
        let size = island(geo)
        let near = NotchLayout.satelliteRect(islandSize: size, geometry: geo, gutterRadius: 8, offset: 0)
        let far = NotchLayout.satelliteRect(islandSize: size, geometry: geo, gutterRadius: 8, offset: 200)
        #expect(far.minX - near.minX == 200)
        #expect(far.minX > size.width, "entirely outside the island at the far end")
    }

    @Test("Nonsense in the preference cannot throw it off screen")
    func offsetIsClamped() {
        let geo = geometry(scale: 1)
        let size = island(geo)
        let sane = NotchLayout.satelliteRect(islandSize: size, geometry: geo, gutterRadius: 8, offset: 5)
        let nan = NotchLayout.satelliteRect(islandSize: size, geometry: geo, gutterRadius: 8, offset: .nan)
        let huge = NotchLayout.satelliteRect(islandSize: size, geometry: geo, gutterRadius: 8, offset: 9_000)
        let tiny = NotchLayout.satelliteRect(islandSize: size, geometry: geo, gutterRadius: 8, offset: -9_000)
        #expect(nan == sane, "not a number, so the default seat")
        #expect(huge.minX - sane.minX == 195, "clamped at 200")
        #expect(tiny.minX - sane.minX == -65, "clamped at -60")
    }

    /// A bigger panel moves the ear the seat is measured from, so the seat
    /// moves with it rather than landing inside the island on a 16-inch.
    @Test("It follows the ears when the panel scales")
    func followsTheScale() {
        let reference = geometry(scale: 1)
        let large = geometry(scale: 1.18, notch: 200, cutoutHeight: 38)
        let a = NotchLayout.satelliteRect(
            islandSize: island(reference), geometry: reference, gutterRadius: 8, offset: 5
        )
        let b = NotchLayout.satelliteRect(
            islandSize: island(large), geometry: large, gutterRadius: 8, offset: 5
        )
        #expect(b.minX > a.minX, "a wider island seats it further out")
        #expect(b.width > a.width, "and a taller cutout makes it bigger")
    }
}
