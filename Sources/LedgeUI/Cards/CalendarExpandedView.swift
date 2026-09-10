import LedgeCore
import SwiftUI

/// The expanded calendar: a big date and event summary on the left, a month
/// grid on the right — the layout Apple's calendar widget uses.
public struct CalendarExpandedView: View {

    private let payload: EventPayload

    /// Pinned for previews and the card gallery; nil means live.
    private let fixedNow: Date?

    /// Live on every render: the calendar provider republishes each minute,
    /// so a card kept open across midnight re-renders with the new day — a
    /// `Date` captured at construction kept yesterday's ring and selection.
    private var now: Date { fixedNow ?? Date() }

    /// The day the user tapped, if any. Nil means the card shows the next
    /// upcoming event, which is what it opens on.
    @State private var selectedDay: Int?

    /// Which month is on the grid: 0 is the current month, ±1 its neighbours —
    /// the span the provider ships data for.
    @State private var monthOffset: Int = 0

    /// Which month the selected day belongs to. Browsing used to clear the
    /// selection outright, on the grounds that day 6 of August is not day 6 of
    /// September — true, and the fix is to remember which month was meant
    /// rather than to forget the day. The column then keeps showing that day,
    /// headed by its own month's name, while the grid moves independently.
    @State private var selectedOffset: Int = 0

    @Environment(\.openURL) private var openURL

    /// Which event row the cursor is on, for its doorway chevron.
    @State private var hoveredEntry: String?

    /// `selectedDay` is settable at construction only so the card gallery can
    /// render the tapped state; the app always starts on the upcoming event.
    /// Told the depth of the month being drawn, so the card can be sized for
    /// it. Defaults to nobody listening, which is what the gallery wants.
    private let onWeekRows: (Int) -> Void

    public init(
        payload: EventPayload,
        now: Date? = nil,
        selectedDay: Int? = nil,
        monthOffset: Int = 0,
        onWeekRows: @escaping (Int) -> Void = { _ in }
    ) {
        self.payload = payload
        self.onWeekRows = onWeekRows
        self.fixedNow = now
        // Today starts selected: the card opens saying what is on *today*,
        // which is the question a calendar glance is usually asking. Tapping
        // today again still returns to the next-event summary.
        let seed = now ?? Date()
        _selectedDay = State(initialValue: selectedDay
            ?? (monthOffset == 0 ? Calendar.current.component(.day, from: seed) : nil))
        _monthOffset = State(initialValue: monthOffset)
    }

    /// The month being shown, and its event data from the shipped windows.
    private var shownMonth: Date {
        Calendar.current.date(byAdding: .month, value: monthOffset, to: now) ?? now
    }

    private var shownWindow: MonthWindow? {
        let comps = Calendar.current.dateComponents([.year, .month], from: shownMonth)
        return payload.monthWindows.first { $0.year == comps.year && $0.month == comps.month }
    }

    private var grid: MonthGrid {
        // The flat fields are the fallback for payloads published before the
        // windows existed (or fixtures that only set the current month).
        let days = monthOffset == 0 && shownWindow == nil
            ? Set(payload.monthEventDays)
            : Set(shownWindow?.eventDays ?? [])
        return MonthGrid.make(containing: shownMonth, eventDays: days)
    }

    private func month(at offset: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: offset, to: now) ?? now
    }

    private func window(at offset: Int) -> MonthWindow? {
        let comps = Calendar.current.dateComponents([.year, .month], from: month(at: offset))
        return payload.monthWindows.first { $0.year == comps.year && $0.month == comps.month }
    }

    /// The events of a given month — the selected one is not always the one on
    /// show any more.
    private func events(at offset: Int) -> [MonthDayEvents] {
        if offset == 0 && window(at: offset) == nil { return payload.monthEvents }
        return window(at: offset)?.events ?? []
    }

    /// The weekday of the selected date, whichever month it belongs to.
    ///
    /// Today's comes from the grid, which already holds it in the region's own
    /// wording; any other day is formatted from its date.
    private func weekdayName(day: Int, offset: Int, grid: MonthGrid, isToday: Bool) -> String {
        if isToday { return grid.todayWeekday }
        var components = Calendar.current.dateComponents([.year, .month], from: month(at: offset))
        components.day = day
        guard let date = Calendar.current.date(from: components) else { return grid.todayWeekday }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: date).uppercased()
    }

    /// The real date behind a day number in one of the shown months.
    private func date(day: Int, offset: Int) -> Date? {
        var components = Calendar.current.dateComponents([.year, .month], from: month(at: offset))
        components.day = day
        return Calendar.current.date(from: components)
    }

    /// Opens Calendar.app on a given day.
    ///
    /// `calshow:` takes seconds since 2001, which is exactly what
    /// `timeIntervalSinceReferenceDate` is. Noon rather than midnight, so a
    /// timezone an hour either side of the formatter's cannot land the app on
    /// the day before.
    private func openCalendar(on date: Date) {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        guard let url = URL(string: "calshow:\(Int(noon.timeIntervalSinceReferenceDate))") else { return }
        openURL(url)
    }

    private func monthName(at offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("LLLL")
        return formatter.string(from: month(at: offset)).uppercased()
    }


    public var body: some View {
        let grid = grid
        HStack(alignment: .top, spacing: 12) {
            // Sized against the 300pt card. Narrowed from 160 with the owner's
            // approval: nothing in this column is that wide, so the spare
            // points read as a gulf between the day and the month rather than
            // as breathing room, and the grid keeps its seven columns either
            // way. Titles still wrap to two lines rather than truncating.
            leftColumn(grid)
                .frame(width: 132, alignment: .leading)

            monthColumn(grid)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 22, symmetric: breathing room against both curved edges, paid for
        // inside (a narrower day column and tighter gap), not by widening
        // the card.
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        // The card is sized by the shell, which cannot know which month is on
        // show — browsing is this view's own state. So it says.
        .onAppear { onWeekRows(grid.weeks.count) }
        .onChange(of: grid.weeks.count) { _, rows in onWeekRows(rows) }
    }

    // MARK: - Left

    @ViewBuilder
    private func leftColumn(_ grid: MonthGrid) -> some View {
        if let day = selectedDay {
            selectedDayColumn(grid, day: day)
        } else {
            upcomingColumn(grid)
        }
    }

    /// The day the user tapped: its number, and what is on it.
    ///
    /// Tapping used to set `selectedDay` and stop there — the disc moved and
    /// nothing else did, because this column only ever rendered the *next*
    /// event. The selection had no reader.
    private func selectedDayColumn(_ grid: MonthGrid, day: Int) -> some View {
        let entries = events(at: selectedOffset).first { $0.day == day }?.entries ?? []
        let isToday = selectedOffset == 0 && day == grid.todayDay
        // The month is worth naming only when the grid is looking at a
        // different one — beside a grid already titled AUGUST it would just be
        // the word twice.
        let elsewhere = selectedOffset != monthOffset
        return VStack(alignment: .leading, spacing: 0) {
            // The weekday always. It is what the column is *for* — which day
            // of the week this is — and the month, when it is needed at all,
            // is a note beside it rather than a replacement for it.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(weekdayName(day: day, offset: selectedOffset, grid: grid, isToday: isToday))
                    .font(.cardBadge)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if elsewhere {
                    Text(monthName(at: selectedOffset))
                        .font(.cardFootnote)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            // The Join capsule rides beside the date rather than under it.
            //
            // It used to have a band of its own, and that band came out of the
            // list below: with a call to join, the day's events had less than
            // one row's height left and the column fell back to saying "2
            // events" instead of naming them — hiding the very thing the card
            // is for in order to show a button about one of them. The date is
            // 32 points tall and the capsule is shorter, so here it costs
            // nothing at all.
            HStack(alignment: .center, spacing: 8) {
                // The date opens Calendar.app on this day, the way the weather
                // card opens Weather. The rows below open their own event; this
                // is for the day as a whole, and for a day whose events are not
                // all listed.
                Button {
                    if let date = date(day: day, offset: selectedOffset) {
                        openCalendar(on: date)
                    }
                } label: {
                    Text("\(day)")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(day) in Calendar")
                if selectedOffset == 0 && day == grid.todayDay {
                    joinButton
                }
                Spacer(minLength: 0)
            }

            // A fixed gap, not a Spacer: a Spacer here pinned the events to the
            // bottom of the card, leaving a hole under the date and reading as
            // two unrelated blocks rather than "this day, and what is on it".
            Spacer().frame(height: 8)

            if entries.isEmpty {
                Text("No events")
                    .font(.cardControl)
                    .foregroundStyle(.white)
                Text("This day is clear")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                // As many as the card is tall enough for. A fixed three fitted
                // the deepest month and ran under the page dots in a shallow
                // one, and a row half-hidden behind the dots reads as breakage
                // rather than "there is more" — which is what the last line is
                // for.
                // How many rows fit is a question about *these* titles: three
                // short ones fit where two wrapped ones do not. So the list is
                // given the height it may use and offered at three lengths;
                // the longest that fits wins. A fixed count could only be
                // right for one of those cases, and picking three was right
                // for the deepest month and ran under the dots everywhere
                // else.
                let room = NotchLayout.calendarDayListHeight(weekRows: grid.weeks.count)
                if room < NotchLayout.calendarEntryRowHeight {
                    // A four-row month with today's join capsule leaves a few
                    // points. A row squeezed into that would be clipped, which
                    // is the very thing being fixed, so the count goes in
                    // instead — small, true, and it fits.
                    Text(entries.count == 1 ? "1 event" : "\(entries.count) events")
                        .font(.cardCaption)
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    ViewThatFits(in: .vertical) {
                        entryList(entries, showing: 3)
                        entryList(entries, showing: 2)
                        entryList(entries, showing: 1)
                    }
                    .frame(maxHeight: room, alignment: .top)
                }
            }
        }
    }

    /// The list at a given length, with the tail counted rather than clipped.
    private func entryList(_ entries: [MonthDayEntry], showing count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entries.prefix(count)) { entry in
                entryRow(entry)
            }
            if entries.count > count {
                Text("+\(entries.count - count) more")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    /// One event on the selected day.
    ///
    /// An all-day event has no time, and reserving the time column for it left
    /// a conspicuous empty gutter — so it takes the whole width instead, which
    /// is also the extra room its title usually needs.
    ///
    /// A row with an EventKit identifier is a doorway into Calendar.app at
    /// that very event, the same pattern as the weather card. Without one
    /// (fixtures, older payloads) it stays plain text.
    @ViewBuilder
    private func entryRow(_ entry: MonthDayEntry) -> some View {
        if entry.eventID.isEmpty {
            entryRowBody(entry)
        } else {
            Button {
                let allowed = CharacterSet.urlPathAllowed
                let escaped = entry.eventID.addingPercentEncoding(withAllowedCharacters: allowed)
                    ?? entry.eventID
                if let url = URL(string: "ical://ekevent/\(escaped)") {
                    openURL(url)
                }
            } label: {
                HStack(spacing: 4) {
                    entryRowBody(entry)
                    // A doorway into Calendar.app; the chevron only shows on
                    // hover, so a quiet list stays quiet.
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(hoveredEntry == entry.id ? 0.45 : 0))
                        .animation(Motion.medium, value: hoveredEntry)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in hoveredEntry = inside ? entry.id : nil }
            .accessibilityLabel("Open \(entry.title) in Calendar")
        }
    }

    @ViewBuilder
    private func entryRowBody(_ entry: MonthDayEntry) -> some View {
        if entry.time.isEmpty {
            entryTitle(entry.title)
        } else {
            HStack(alignment: .top, spacing: 5) {
                // Its natural width, not a reserved column. The column was 38pt
                // — sized for "10:30 AM" — which left a visible gulf between a
                // 24-hour time and its title, and the two belong together.
                // Where every time is the same width, as in a 24-hour locale,
                // the titles still line up; where they are not, sitting beside
                // the right time matters more than sharing a left edge.
                Text(entry.time)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize()
                    // Lines up with the title's first line now that the title
                    // can wrap: a baseline alignment would drift as it does.
                    .padding(.top, 1)
                entryTitle(entry.title)
            }
        }
    }

    /// Two lines, not one. Most event titles are longer than the ~100pt the
    /// column gives them, and a single truncated line hid which event it was.
    private func entryTitle(_ title: String) -> some View {
        Text(title)
            .font(.cardFootnote)
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            // Without this the surrounding fixed-width column collapses the
            // text to one line and truncates rather than wrapping.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The call to join, if there is one to join right now. The window itself
    /// is `MeetingJoin`, which is pure and tested.
    private var meetingToJoin: URL? {
        guard payload.hasEvent,
              let link = payload.meetingURL,
              let url = URL(string: link),
              url.scheme != nil
        else { return nil }
        return MeetingJoin.isOffered(
            startsIn: payload.startsIn,
            endsIn: payload.endsIn,
            hasLink: true
        ) ? url : nil
    }

    /// The reason the imminent-event card exists at all: the link is buried in
    /// the invitation, and the meeting is about to start.
    @ViewBuilder
    private var joinButton: some View {
        if let url = meetingToJoin {
            Button {
                openURL(url)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "video.fill")
                        .font(.cardFootnote)
                    Text("Join")
                        .font(.cardLabel)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(.green.opacity(0.85)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Join \(payload.title)")
        }
    }

    /// What the card opens on: today's date and the next thing coming up.
    private func upcomingColumn(_ grid: MonthGrid) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(grid.todayWeekday)
                .font(.cardBadge)
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Button {
                openCalendar(on: now)
            } label: {
                Text("\(grid.todayDay)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open today in Calendar")

            Spacer().frame(height: 8)

            if payload.hasEvent {
                // Two lines: at one, a typical event title truncated to the
                // point of not identifying the event. There is room for the
                // second now that the column is wider and the events are not
                // pushed to the bottom of the card.
                Text(payload.title)
                    .font(.cardControl)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                joinButton
                    .padding(.top, 6)
            } else {
                Text("No events")
                    .font(.cardControl)
                    .foregroundStyle(.white)
                Text("This day is clear")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var subtitle: String {
        let when = ActivityCardView.relative(payload.startsIn)
        if payload.location.isEmpty { return when }
        return "\(when) · \(payload.location)"
    }

    // MARK: - Month

    private func monthColumn(_ grid: MonthGrid) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text(grid.monthName)
                    .font(.cardBadge)
                    .foregroundStyle(.red)

                Spacer(minLength: 4)

                // One month either side — that is all the data the provider
                // ships; going further would show a grid with silently missing
                // dots, which reads as "no events" rather than "no data".
                monthArrow("chevron.left", enabled: monthOffset > -1) {
                    monthOffset -= 1
                }
                monthArrow("chevron.right", enabled: monthOffset < 1) {
                    monthOffset += 1
                }
            }

            HStack(spacing: 0) {
                // From the grid itself, so the header row always matches the
                // region's week start beneath it.
                ForEach(Array(grid.weekdayHeaders.enumerated()), id: \.offset) { _, header in
                    Text(header)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                        cellView(cell).frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: MonthGrid.Cell) -> some View {
        if let day = cell.day {
            // Only ring it in the month it belongs to. The selection outlives a
            // month change now, and ringing the same number in September
            // claimed a day the column is not showing.
            let isSelected = selectedDay == day && selectedOffset == monthOffset
            // MonthGrid flags "today" by day number of the date it was built
            // around; on a neighbouring month that number is meaningless.
            let isToday = cell.isToday && monthOffset == 0
            Button {
                // Tapping the selected day again returns to the next event, so
                // there is always a way back without hunting for a close box.
                selectedDay = isSelected ? nil : day
                selectedOffset = monthOffset
            } label: {
                VStack(spacing: 1) {
                Text("\(day)")
                    .font(.system(size: 9, weight: isToday || isSelected ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(dayColor(cell, isToday: isToday, isSelected: isSelected))
                    .frame(width: 16, height: 14)
                    .background {
                        // A filled disc means *selected*; a ring means *today*.
                        // Red text was the first attempt at today and barely
                        // registered at 9pt on a dark card, and giving today
                        // the filled disc made every glance look like a day was
                        // already chosen. A ring is legible without claiming
                        // the selection.
                        if isSelected {
                            Circle().fill(.white).frame(width: 16, height: 16)
                        } else if isToday {
                            Circle()
                                .strokeBorder(.white.opacity(0.9), lineWidth: 1.2)
                                .frame(width: 16, height: 16)
                        }
                    }

                // A dot under the number rather than a red numeral: the colour
                // was doing two jobs at once — "has an event" and "is a
                // weekend" both changed the digit, so neither read clearly.
                Circle()
                    .fill(dotColor(cell, isSelected: isSelected))
                    .frame(width: 2.5, height: 2.5)
            }
                .frame(width: 18, height: 19)
                .contentShape(Rectangle())
            }
            // A `Button`, not a bare tap gesture: the overlay carries its own
            // tap handler that pins and dismisses the whole card, and a tap
            // gesture fires *alongside* it — the collision the route menu hit,
            // where choosing something also toggled the pinned state.
            .buttonStyle(.plain)
            .accessibilityLabel(cell.hasEvent ? "Day \(day), has events" : "Day \(day)")
        } else {
            Color.clear.frame(width: 18, height: 19)
        }
    }

    /// The event dot, which has to stay visible against a filled selection.
    private func dotColor(_ cell: MonthGrid.Cell, isSelected: Bool) -> Color {
        guard cell.hasEvent else { return .clear }
        return isSelected ? .white : .white.opacity(0.65)
    }

    private func monthArrow(
        _ symbol: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.7 : 0.2))
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(symbol.contains("left") ? "Previous month" : "Next month")
    }

    private func dayColor(_ cell: MonthGrid.Cell, isToday: Bool, isSelected: Bool) -> Color {
        // Selected wins: the digit sits on a white disc and has to be legible.
        if isSelected { return .black }
        if isToday { return .white }
        if cell.isWeekend { return .white.opacity(0.35) }
        return .white
    }
}
