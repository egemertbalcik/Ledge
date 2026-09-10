// CoreGraphics, not AppKit: `Foundation` surfaces the CGSize/CGRect types but
// not their `Equatable` conformances. This keeps LedgeCore headless.
import CoreGraphics
import Foundation

/// Measured facts about a display and its notch.
///
/// This is a pure value type: measurement lives in `LedgeShell` (which can see
/// `NSScreen`), so everything downstream stays headless-testable.
public struct NotchGeometry: Sendable, Equatable {

    /// Full frame of the display, in that display's own coordinate space.
    public let screenSize: CGSize

    /// Size of the physical notch cutout, or the size we simulate on a
    /// notchless display. Width includes only the cutout, not the gutters.
    public let notchSize: CGSize

    /// Horizontal midpoint of the notch, measured from the display's left edge.
    /// On real hardware this is the screen centre; a simulated notch may differ.
    public let notchCenterX: CGFloat

    /// Whether the display reported a real hardware cutout.
    public let isHardwareNotch: Bool

    /// How much bigger this Mac's cards should be than the reference Mac's.
    ///
    /// Every notched Mac runs about 128 points per inch at its default
    /// resolution, so a point is the same *physical* size on a 13-inch Air and
    /// a 16-inch Pro — and a card of fixed point size is physically identical
    /// on both, which is why it reads as too small on the larger machine. This
    /// is the correction: 1.0 on the reference display, larger in proportion
    /// to the panel, clamped by whoever measures it.
    ///
    /// Only open cards use it. The compact island is sized from the hardware
    /// cutout and must not move.
    public let displayScale: CGFloat

    public init(
        screenSize: CGSize,
        notchSize: CGSize,
        notchCenterX: CGFloat,
        isHardwareNotch: Bool,
        displayScale: CGFloat = 1
    ) {
        self.screenSize = screenSize
        self.notchSize = notchSize
        self.notchCenterX = notchCenterX
        self.isHardwareNotch = isHardwareNotch
        self.displayScale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
    }

    /// Fallback for displays with no cutout.
    ///
    /// Not a copy of the M-series notch: without hardware behind it, a
    /// 180-wide, 32-tall shape reads as a long rectangle stuck to the bezel.
    /// A free-floating pill wants to be shorter and proportionally taller — the
    /// iOS Dynamic Island's idle proportions rather than the MacBook cutout's.
    /// The extra height also lets the fully-rounded ends actually show.
    public static func simulated(screenSize: CGSize) -> NotchGeometry {
        NotchGeometry(
            screenSize: screenSize,
            notchSize: CGSize(width: 126, height: 37),
            notchCenterX: screenSize.width / 2,
            isHardwareNotch: false
        )
    }
}

/// The size the shape should occupy for a given phase.
///
/// Deliberately pure: the reducer picks a phase, this turns a phase into
/// numbers, and the view layer animates between them. No AppKit involved, so
/// the whole thing is unit-testable.
public struct NotchLayout: Sendable, Equatable {

    /// Size of the shape body, excluding gutters.
    public let bodySize: CGSize

    /// Radius of the two bottom corners.
    public let bottomRadius: CGFloat

    /// Radius of the inverted corners where the shape meets the screen edge.
    public let gutterRadius: CGFloat

    public init(bodySize: CGSize, bottomRadius: CGFloat, gutterRadius: CGFloat) {
        self.bodySize = bodySize
        self.bottomRadius = bottomRadius
        self.gutterRadius = gutterRadius
    }

    /// Total size the hosting view must reserve, including both gutters.
    public var boundingSize: CGSize {
        // The gutter is preference-driven and the closed path does not pass it
        // through the expanded clamp; NaN here would size the hosting view and
        // its hit rect NaN-wide.
        let gutter = gutterRadius.isFinite ? max(gutterRadius, 0) : 0
        return CGSize(width: bodySize.width + gutter * 2, height: bodySize.height)
    }

    /// Closed state: the shape exactly fills the physical cutout, so the app is
    /// invisible until something happens.
    public static func closed(
        _ geometry: NotchGeometry,
        bottomRadius: CGFloat,
        gutterRadius: CGFloat
    ) -> NotchLayout {
        NotchLayout(
            bodySize: geometry.notchSize,
            bottomRadius: bottomRadius,
            gutterRadius: gutterRadius
        )
    }

    /// Width of the content area either side of the cutout in the compact
    /// phases. Content lives in these "ears"; the cutout itself stays empty
    /// because there is physical hardware behind it.
    /// Peek, HUD, and companion share one ear width, so a Focus change, a volume
    /// readout, and the resting music companion are all the same compact size.
    /// User-adjustable through Settings (draft + Apply, never live), clamped
    /// so the ears can neither vanish nor swallow the screen. Written only
    /// from the main thread — the shell applies it at start and on Apply.
    public static let defaultEarWidth: CGFloat = 53
    public nonisolated(unsafe) private(set) static var peekEarWidth: CGFloat = defaultEarWidth
    public nonisolated(unsafe) private(set) static var hudEarWidth: CGFloat = defaultEarWidth

    /// Applies a new ear width to every compact phase and, through the width
    /// discipline, every card. NaN and extremes degrade to the default.
    public static func setEarWidth(_ width: CGFloat) {
        let sane = sanitizedEarWidth(width)
        peekEarWidth = sane
        hudEarWidth = sane
    }

    private static func sanitizedEarWidth(_ width: CGFloat) -> CGFloat {
        width.isFinite ? min(max(width, 36), 90) : defaultEarWidth
    }

    /// Extra height beyond the bare cutout for every compact phase. Half a
    /// point — one Retina pixel — by the owner's decision, tuned by eye
    /// (0 → 1 → 0.5, each on request): the compact shape's rounded bottom
    /// clears the hardware edge by exactly one pixel. Not to be changed
    /// without asking.
    public static let compactExtraHeight: CGFloat = 0.5

    /// Peek: the cutout appears to *widen* rather than drop a card. It grows in
    /// width, with just a couple of points of extra height so the rounded bottom
    /// sits neatly below the hardware cutout.
    /// How much taller an *announcing* peek stands.
    ///
    /// The cutout's own height, so the shape very nearly doubles and the strip
    /// that appears below the hardware is about as tall as the compact view
    /// above it. Deliberately nowhere near a card: this is the notch raising
    /// its voice for a second, not opening.
    ///
    /// Taken from the hardware rather than fixed, so it holds on a machine
    /// whose cutout is a different size.
    public static func announceExtraHeight(for geometry: NotchGeometry) -> CGFloat {
        geometry.notchSize.height
    }

    public static func peek(
        _ geometry: NotchGeometry,
        bottomRadius: CGFloat,
        gutterRadius: CGFloat,
        announcing: Bool = false,
        earWidth: CGFloat? = nil
    ) -> NotchLayout {
        expanded(
            geometry,
            size: CGSize(
                width: geometry.notchSize.width + (earWidth.map(sanitizedEarWidth) ?? peekEarWidth) * 2,
                height: geometry.notchSize.height + compactExtraHeight
                    + (announcing ? announceExtraHeight(for: geometry) : 0)
            ),
            bottomRadius: bottomRadius,
            gutterRadius: gutterRadius
        )
    }

    /// HUD: a level readout in the ears — a glyph on one side, a bar on the
    /// other. Same idea as peek, a little wider to fit the bar, same slight
    /// extra height.
    public static func hud(
        _ geometry: NotchGeometry,
        bottomRadius: CGFloat,
        gutterRadius: CGFloat
    ) -> NotchLayout {
        expanded(
            geometry,
            size: CGSize(
                width: geometry.notchSize.width + hudEarWidth * 2,
                height: geometry.notchSize.height + compactExtraHeight
            ),
            bottomRadius: bottomRadius,
            gutterRadius: gutterRadius
        )
    }

    /// Four hint rows plus their spacing and room below the last one.
    public static let emptyHintsHeight: CGFloat = 106

    /// The card's own padding around the route menu.
    public static let routePickerTopPadding: CGFloat = 10
    public static let routePickerBottomPadding: CGFloat = 20
    public static let routePickerPadding = routePickerTopPadding + routePickerBottomPadding

    /// The open card's size — the single source both the drawn shape and the
    /// shell's hit region use.
    ///
    /// They live in different targets and used to compute this separately, and
    /// they drifted: the view grew the card to fit the empty-state hints and the
    /// hit region did not, so the bottom of that card was drawn but not
    /// clickable and every click there fell through to the app behind.
    /// The calendar's own seat: the one card allowed wider than the island,
    /// because it carries a month grid beside a day column.
    ///
    /// Narrowed from 320 with the owner's approval: the day column was wider
    /// than anything it holds, so the two halves read as pushed apart rather
    /// than sat beside each other. The grid did not lose room — the column
    /// gave it up.
    public static let calendarWidth: CGFloat = 300

    /// One week's row in the month grid.
    public static let calendarRowHeight: CGFloat = 22

    /// Everything in the calendar card that is not week rows: the cutout
    /// allowance, the card's own vertical padding, the month name and the
    /// weekday letters.
    public static let calendarChrome: CGFloat = 84

    /// The same, for a display whose cutout is not the reference height: the
    /// chrome includes the allowance, so a taller notch means a taller card
    /// rather than a shorter grid.
    public static func calendarChrome(notchHeight: CGFloat) -> CGFloat {
        calendarChrome + (notchHeight - referenceNotchHeight)
    }

    /// The room the day column has for its list of events, before the page
    /// dots at the bottom of the card.
    ///
    /// The card's height follows the month now, so "three fit" stopped being
    /// true: three events fit a six-row month and ran into the dots in a
    /// four-row one. The dots are drawn over the shape's bottom edge and do
    /// not move for anything, so the list is given a ceiling and asked to fit
    /// under it — how many rows that turns out to be depends on how many of
    /// the titles wrap, which is not something a number here can know.
    ///
    /// Worked from the same numbers `calendarHeight` uses: the card, less the
    /// cutout allowance and its own padding, less the date heading and the gap
    /// under it, less the join capsule when today is selected, less the band
    /// the dots occupy.
    public static func calendarDayListHeight(
        weekRows: Int,
        hasJoinButton: Bool,
        notchHeight: CGFloat = referenceNotchHeight
    ) -> CGFloat {
        let content = calendarHeight(weekRows: weekRows, notchHeight: notchHeight)
            - notchHeight - 28
        let heading: CGFloat = 59
        let join: CGFloat = hasJoinButton ? 30 : 0
        // The list is text to the very edge of its last line, so it keeps a
        // little air over the dots rather than stopping level with them.
        return max(0, content - heading - join - dotsBand - 6)
    }

    /// The shortest a listed event can be: one line of title, unwrapped.
    /// Below this there is no honest way to show a row, and the column says
    /// how many there are instead.
    public static let calendarEntryRowHeight: CGFloat = 30

    /// The cutout every card sits below, on the Mac these numbers were tuned
    /// against — a 13-inch Air, whose notch is 32 points tall.
    ///
    /// Kept as the *reference*, not as the answer: a MacBook Pro's cutout is
    /// taller, and a card whose height budgeted 32 for it gave the content
    /// that much less room, which is what "the padding looks different on my
    /// Mac" turned out to be. Everything that sizes a card takes the real one.
    public static let referenceNotchHeight: CGFloat = 32

    /// Deprecated spelling of the reference height, kept for the preview app.
    public static let notchAllowance: CGFloat = referenceNotchHeight

    /// How much taller (or shorter) this display's cutout is than the one the
    /// card heights were tuned against.
    public static func cutoutDelta(for geometry: NotchGeometry) -> CGFloat {
        geometry.notchSize.height - referenceNotchHeight
    }

    /// What the page dots actually occupy at the bottom of an open card: they
    /// sit 7pt off the edge and stand about 5pt tall. They are drawn over the
    /// shape and move for nothing, so every card that sizes itself takes this
    /// out first rather than discovering it afterwards.
    ///
    /// This is the footprint, not a comfortable margin — a card that wants air
    /// above them says so itself, because how much looks right depends on what
    /// its last row is.
    public static let dotsBand: CGFloat = 12

    /// The Clock card's height, from the height its content reported.
    ///
    /// The three faces — the countdown, the launcher's chips, the stopwatch —
    /// are not the same height, and the segmented header lets the user move
    /// between them, so no single number was ever right: it was set for the
    /// tallest, and the others sat above a band of nothing.
    ///
    /// The card measures itself rather than having its faces described here in
    /// numbers that would drift the moment one of them gained a row.
    ///
    /// - Parameter contentHeight: what the card reported, or zero before it
    ///   has — then the old fixed height stands, which is tall enough for any
    ///   face and so cannot clip while waiting.
    public static func timerHeight(
        contentHeight: CGFloat,
        notchHeight: CGFloat = referenceNotchHeight
    ) -> CGFloat {
        let delta = notchHeight - referenceNotchHeight
        guard contentHeight > 0 else { return 180 + delta }
        return min(max(notchHeight + contentHeight + dotsBand, 140 + delta), 280 + delta)
    }

    /// A month is four, five or six rows deep, and the card was sized for the
    /// deepest of them — so most months carried a band of empty black under
    /// the grid. It now follows the month on show.
    ///
    /// Six rows when nobody has said yet: the card reports its own depth as it
    /// draws, and guessing short would clip the last week for the moment
    /// before it does.
    public static func calendarHeight(
        weekRows: Int,
        notchHeight: CGFloat = referenceNotchHeight
    ) -> CGFloat {
        let rows = weekRows > 0 ? min(max(weekRows, 4), 6) : 6
        return calendarChrome(notchHeight: notchHeight) + CGFloat(rows) * calendarRowHeight
    }

    /// How much wider an open card sits than the compact island — the small
    /// outward breath that makes opening read as a transition.
    public static let openCardGrowth: CGFloat = 16

    public static func cardSize(
        kind: ActivityKind?,
        phase: NotchPhase,
        base: CGSize,
        payload: ActivityPayload? = nil,
        calendarWeekRows: Int = 0,
        timerContentHeight: CGFloat = 0,
        geometry: NotchGeometry,
        routePickerRows: Int,
        hasSelection: Bool
    ) -> CGSize {
        var content = expandedContentSize(
            kind: kind, phase: phase, base: base,
            payload: payload, calendarWeekRows: calendarWeekRows,
            timerContentHeight: timerContentHeight,
            notchHeight: geometry.notchSize.height
        )
        // Two corrections, both about the Mac this is running on rather than
        // the one the numbers were tuned on.
        //
        // The cutout: every floor above budgets `referenceNotchHeight` for the
        // notch the content sits under. A Pro's is taller, and without this
        // the content simply got less room — the "padding looks wrong on my
        // MacBook Pro" report.
        //
        // The panel: a point is the same physical size on every notched Mac,
        // so a card of fixed point size is physically identical on a 13-inch
        // Air and a 16-inch Pro, which reads as too small on the larger one.
        let scale = geometry.displayScale
        content.height = (content.height + cutoutDelta(for: geometry)) * scale

        // One width discipline, not per-card floors. Every card opens at
        // the compact island's width plus a small, fixed growth — enough
        // that opening visibly breathes outward without ballooning — and
        // the calendar alone gets its fixed wider seat. Heights stay
        // per-card; widths are no longer anyone's to pick.
        //
        // The cutout's own width is hardware and already differs between Macs,
        // so only the part this app chose — the ears and the growth — scales,
        // rather than scaling a number that has grown once already.
        content.width = kind == .event
            ? Self.calendarWidth * scale
            : geometry.notchSize.width + (hudEarWidth * 2 + Self.openCardGrowth) * scale

        // The route menu is sized to its rows exactly rather than floored at the
        // player's height, so one destination gives a short card instead of a
        // tall one with a hole under the single row.
        if routePickerRows > 0 {
            return sanitized(CGSize(
                width: content.width,
                height: (geometry.notchSize.height
                    + routePickerHeight(rows: routePickerRows)
                    + routePickerPadding) * scale
            ), geometry: geometry)
        }

        // The hints list is four fixed rows and cannot be compressed, and a
        // notchless display's cutout stand-in is taller than the MacBook's.
        guard !hasSelection else {
            // A sliver for the page dots, which draw inside the shape's bottom
            // margin: without it they crowded whichever card's content ran
            // closest to the edge.
            return sanitized(
                CGSize(width: content.width, height: content.height + 10),
                geometry: geometry
            )
        }
        let needed = geometry.notchSize.height + emptyHintsHeight
        return sanitized(
            CGSize(width: content.width, height: max(content.height, needed)),
            geometry: geometry
        )
    }

    /// The base size is preference-driven, and a corrupted defaults database
    /// can hand this math a negative number or NaN. NaN in particular poisons
    /// every CGRect it touches — the shape silently stops drawing and the hit
    /// region stops matching. Degrade to the bare cutout instead.
    private static func sanitized(_ size: CGSize, geometry: NotchGeometry) -> CGSize {
        CGSize(
            width: size.width.isFinite
                ? max(size.width, geometry.notchSize.width) : geometry.notchSize.width,
            height: size.height.isFinite
                ? max(size.height, geometry.notchSize.height) : geometry.notchSize.height
        )
    }

    // MARK: - Route picker

    /// One destination row in the media card's route menu.
    public static let routeRowHeight: CGFloat = 42
    public static let routeRowSpacing: CGFloat = 8
    /// Artwork, title and artist across the top of the route menu.
    public static let routeHeaderHeight: CGFloat = 44
    /// Gap between the header and the first destination.
    public static let routeHeaderGap: CGFloat = 12

    /// How much taller the media card must be while the route menu is open.
    ///
    /// Both the drawn shape and the shell's hit region derive their height from
    /// this one function. They are computed in different files from different
    /// state, and the only thing keeping a click near the bottom row from
    /// falling straight through the window is that both call this.
    ///
    /// Capped at three rows: past that the card would be taller than the menu is
    /// worth, and the list scrolls instead.
    public static func routePickerHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        let capped = min(rows, 3)
        return routeHeaderHeight
            + routeHeaderGap
            + CGFloat(capped) * routeRowHeight
            + CGFloat(max(0, capped - 1)) * routeRowSpacing
    }

    /// How far the hovered HUD hangs below the cutout for its Control-Centre
    /// style panel: a title line plus the full slider row.
    public static let hudAdjustHeight: CGFloat = 64

    /// Extra width each side while the panel is open. Kept minimal: the hovered
    /// HUD grows *downward* — its footprint should stay essentially the compact
    /// width, not swell sideways.
    public static let hudAdjustExtraWidth: CGFloat = 8

    /// Height of one *live-slider* section in the hovered panel: the name
    /// line (~15pt) plus its 5pt gap, the slider row (~18pt), and the 10pt
    /// spacing to the next section. Every brightness row is one of these.
    /// Undercounting it (it was 36) made the bottom-anchored stack overflow
    /// upward and clip the *top* rows behind the hardware cutout.
    public static let hudDeviceRowHeight: CGFloat = 48

    /// Height of one *faded* section — a name line and a 5pt read-only bar.
    /// The sound panel's non-current routes are these; budgeting them at the
    /// live-row height opened a dead black band above the list.
    public static let hudFadedRowHeight: CGFloat = 36

    /// The single place a phase becomes numbers.
    ///
    /// `isHudInteractive` is true while the pointer is on a level readout: the
    /// HUD then grows *downward*, making room for the big draggable bar under
    /// the hardware cutout.
    public static func layout(
        for phase: NotchPhase,
        geometry: NotchGeometry,
        expandedSize: CGSize,
        bottomRadius: CGFloat,
        closedBottomRadius: CGFloat,
        gutterRadius: CGFloat,
        isHudInteractive: Bool = false,
        hudExtraHeight: CGFloat = 0,
        isAnnouncing: Bool = false
    ) -> NotchLayout {
        // The radii are preference-driven and a corrupted defaults database
        // can hand this NaN, which slips *through* min/max (the stdlib returns
        // its first argument when a comparison fails) and poisons every rect
        // downstream — `sanitized` guards the sizes but nothing guarded these.
        // Degrade toward the bare cutout, matching that policy.
        let bottomRadius = bottomRadius.isFinite ? max(0, bottomRadius) : 0
        let closedBottomRadius = closedBottomRadius.isFinite ? max(0, closedBottomRadius) : 0
        let gutterRadius = gutterRadius.isFinite ? max(0, gutterRadius) : 0

        switch phase {
        case .idle:
            // Closed, the shape must match the hardware cutout's own corner
            // radius, not the expanded card's. They are different numbers, and
            // using one for both is what makes these overlays look stuck on.
            return .closed(
                geometry,
                bottomRadius: min(closedBottomRadius, geometry.notchSize.height / 2),
                gutterRadius: gutterRadius
            )
        case .peek:
            return .peek(
                geometry,
                bottomRadius: bottomRadius,
                gutterRadius: gutterRadius,
                announcing: isAnnouncing
            )
        case .hud where isHudInteractive:
            // Hovered: grow downward by the extra sections' measured height —
            // a *point* budget, because a live brightness row and a faded
            // audio route cost different amounts.
            return expanded(
                geometry,
                size: CGSize(
                    width: geometry.notchSize.width + (hudEarWidth + hudAdjustExtraWidth) * 2,
                    height: geometry.notchSize.height + compactExtraHeight + hudAdjustHeight
                        + max(0, hudExtraHeight.isFinite ? hudExtraHeight : 0)
                ),
                bottomRadius: bottomRadius,
                gutterRadius: gutterRadius
            )
        case .hud, .companion:
            // The companion shares the HUD footprint — width-only, notch height —
            // so music rests in the ears the same size as the volume readout.
            return .hud(geometry, bottomRadius: bottomRadius, gutterRadius: gutterRadius)
        case .hover, .expanded:
            return .expanded(
                geometry,
                size: expandedSize,
                bottomRadius: bottomRadius,
                gutterRadius: gutterRadius
            )
        }
    }

    /// Upper end of the Appearance height control, in reference-display points.
    public static let maximumExpandedHeight: CGFloat = 440
    public static let weatherPrecipitationHeight: CGFloat = 19

    /// Reserve the largest supported card before installing the hosting view.
    /// This keeps changing Height from resizing the window mid-animation.
    /// The 32pt margin covers the near-critically-damped expansion spring.
    public static func panelSize(for geometry: NotchGeometry) -> CGSize {
        let tallest = ActivityKind.allCases.map { kind in
            let size = cardSize(
                kind: kind, phase: .expanded,
                base: CGSize(width: 0, height: maximumExpandedHeight),
                calendarWeekRows: 6, timerContentHeight: .greatestFiniteMagnitude,
                geometry: geometry, routePickerRows: 0, hasSelection: true
            )
            return size.height + (kind == .weather ? weatherPrecipitationHeight * geometry.displayScale : 0)
        }.max() ?? 0
        let routes = (geometry.notchSize.height + routePickerHeight(rows: 3)
            + routePickerPadding) * geometry.displayScale
        return CGSize(
            width: geometry.screenSize.width,
            height: min(geometry.screenSize.height, max(tallest, routes) + 32)
        )
    }

    /// The room the precipitation line needs, and zero when there is none.
    ///
    /// The weather card is the one card whose content changes shape: "Rain in
    /// ~60m" appears between the header and the hourly strip and pushes
    /// everything below it down. At a fixed height that push landed the strip
    /// on the page dots, so the card grows by exactly the row instead — its
    /// 11pt line plus the 5pt that separates it from the header.
    public static func weatherExtraHeight(for payload: ActivityPayload?) -> CGFloat {
        guard case .weather(let weather) = payload, weather.rainSoonMinutes != nil else { return 0 }
        return weatherPrecipitationHeight
    }

    /// The expanded size to use for a given piece of content.
    ///
    /// Most cards fit the user's tuned size, but the expanded calendar draws a
    /// whole month grid and needs more room. Computed here — rather than in the
    /// view — so the hit region and the drawn shape agree on the same number.
    public static func expandedContentSize(
        kind: ActivityKind?,
        phase: NotchPhase,
        base: CGSize,
        payload: ActivityPayload? = nil,
        calendarWeekRows: Int = 0,
        timerContentHeight: CGFloat = 0,
        notchHeight: CGFloat = referenceNotchHeight
    ) -> CGSize {
        switch kind {
        case .nowPlaying:
            // The full transport row does not fit a short card; the now-playing
            // view needs headroom whenever it is open, hovered or pinned. Width
            // is kept narrower (iOS-Island-like) but the height keeps its full
            // padding so the transport row is not cramped against the edge.
            return CGSize(width: base.width, height: max(base.height, 164))
        case .device, .focus:
            // The device card carries product artwork and up to three battery
            // cells; the Focus card a 46pt circle. Both need a touch more than
            // the base row height, and the same width as the other cards so the
            // silhouette does not jump between them.
            return CGSize(width: base.width, height: max(base.height, 132))
        case .weather:
            // Same width as the media card so the two flagship cards present one
            // silhouette, and tall enough for the header plus the hourly strip —
            // plus the precipitation line when there is one, which is the only
            // part of this card that comes and goes.
            // 186 left the hourly strip six points off the page dots, which
            // read as the row resting on them; 194 was too generous the other
            // way. Four points of it back.
            return CGSize(
                width: base.width,
                height: max(base.height, 190) + weatherExtraHeight(for: payload)
            )
        case .timer:
            // The Clock card: the segmented header over the timer's ring,
            // countdown and control row (or the stopwatch's hero and buttons).
            // Each of those faces is a different height, and the user can
            // switch between them, so the card measures itself and this
            // follows.
            return CGSize(
                width: base.width,
                height: max(base.height, timerHeight(
                    contentHeight: timerContentHeight, notchHeight: notchHeight
                ))
            )
        case .levels:
            // Two labelled Control-Centre bars. Wide enough for a long output
            // name; short — there is nothing below the second bar.
            //
            // 148 was two and a half points *short*: the brightness row ran
            // into the page dots' band rather than stopping above it. Twelve
            // more clears them without the card growing a visible margin.
            return CGSize(width: base.width, height: max(base.height, 160))
        case .event:
            // As deep as the month on show, and no deeper. The height covers
            // the *whole* card including the cutout allowance the content is
            // inset by, which is what `calendarChrome` accounts for.
            return CGSize(
                width: base.width,
                height: max(base.height, calendarHeight(
                    weekRows: calendarWeekRows, notchHeight: notchHeight
                ))
            )
        default:
            // Everything else (shelf, power, message, privacy, keyboard) still
            // needs *some* room below the cutout: the height preference's legal
            // minimum equals the notch height, which left these kinds a 0pt
            // content area — an expanded card that drew nothing.
            return CGSize(width: base.width, height: max(base.height, 120))
        }
    }

    /// Expanded state, clamped so the shape can never run off either screen edge.
    public static func expanded(
        _ geometry: NotchGeometry,
        size: CGSize,
        bottomRadius: CGFloat,
        gutterRadius: CGFloat
    ) -> NotchLayout {
        // NaN radii would slip through every clamp below (stdlib min/max keep
        // their first argument when a comparison fails); this is the choke
        // point every open layout funnels through, so it is guarded here too.
        let bottomRadius = bottomRadius.isFinite ? bottomRadius : 0
        let gutterRadius = gutterRadius.isFinite ? gutterRadius : 0

        // Order matters. Clamping to the screen *after* flooring at the cutout
        // means the clamp can win and produce a body narrower than the notch it
        // is meant to cover — or, on a zero-size screen during a display
        // reconfiguration, a negative width that flows into the shape path and
        // the panel frame. Floor the ceiling at zero first.
        let maxWidth = max(0, geometry.screenSize.width - gutterRadius * 2)
        let width = max(0, min(max(size.width, geometry.notchSize.width), maxWidth))
        let height = max(0, max(size.height, geometry.notchSize.height))

        // A radius wider than the body it rounds produces a self-intersecting
        // path. Peek and HUD bodies are only a few points taller than the
        // cutout, and the Appearance slider goes well past that.
        let safeBottom = max(0, min(bottomRadius, min(width / 2, height / 2)))
        let safeGutter = max(0, min(gutterRadius, min(width / 2, height)))

        return NotchLayout(
            bodySize: CGSize(width: width, height: height),
            bottomRadius: safeBottom,
            gutterRadius: safeGutter
        )
    }
}
