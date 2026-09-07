import EventKit
import Foundation
import os

/// One upcoming calendar event, reduced to what the card needs.
public struct EventSnapshot: Equatable, Sendable {
    public var title: String
    public var location: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool

    /// The calendar's colour, so the card can carry it.
    public var accentRed: Double
    public var accentGreen: Double
    public var accentBlue: Double

    /// Stable identity for dedupe across refreshes.
    public var eventKey: String

    /// A video-call link found in the event, so the card can offer to join.
    public var meetingURL: String?

    public init(
        title: String,
        location: String = "",
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        accentRed: Double = 0.36,
        accentGreen: Double = 0.55,
        accentBlue: Double = 0.9,
        eventKey: String,
        meetingURL: String? = nil
    ) {
        self.title = title
        self.location = location
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.accentRed = accentRed
        self.accentGreen = accentGreen
        self.accentBlue = accentBlue
        self.eventKey = eventKey
        self.meetingURL = meetingURL
    }
}

/// Where calendar events come from.
@MainActor
public protocol CalendarSource: AnyObject {

    /// Whether events can be read right now. False until Calendar access is
    /// granted — and checking this must never prompt.
    var isAuthorized: Bool { get }

    /// Non-all-day events starting within the window, soonest first.
    ///
    /// Async because the underlying `EKEventStore` query can be slow and must
    /// not run on the main thread — Apple documents it as potentially
    /// expensive, and it fires on a ~60s cadence while a card is shown.
    func upcomingEvents(within window: TimeInterval) async -> [EventSnapshot]

    /// Day numbers in a month that have any event, for the month grid.
    /// `monthOffset` counts whole months from the current one (-1 = previous),
    /// so the grid's arrows can show neighbouring months without a fresh grant.
    func eventDays(monthOffset: Int) async -> Set<Int>

    /// Every event in a month, grouped by day, so tapping a day in the grid can
    /// say what is on it. Titles and times only — the grid never needs more.
    func events(monthOffset: Int) async -> [Int: [(title: String, time: String, eventID: String)]]

    /// Fires when the database changes — an event added, moved, or deleted.
    func startWatching(_ onChange: @escaping @MainActor () -> Void)
    func stopWatching()
}

public final class EventKitCalendarSource: CalendarSource {

    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "calendar")

    private var observer: (any NSObjectProtocol)?

    /// The one store this source ever talks to, created on first use and kept
    /// for the source's lifetime.
    ///
    /// It used to be a throwaway per query, and with the provider asking for
    /// the next events plus three month grids every minute that was seven
    /// `EKEventStore` inits a minute for most of the workday. Each init opens
    /// an XPC session to the calendar daemon and pulls the source list, so the
    /// "cheap allocation" was the expensive part of the query.
    ///
    /// Only ever *called* on `queryQueue`, which is serial; main holds the
    /// reference so it can be the change notification's `object:` filter and
    /// hand it to the queue. Nothing here needs recreating on
    /// `EKEventStoreChanged` — a predicate fetch goes to the daemon each time
    /// and never returns objects we hold on to, so the store cannot go stale
    /// on us.
    private var store: EKEventStore?

    /// Every store query runs here, one at a time. EventKit does not promise
    /// a store is safe to drive from two threads at once, and a serial queue
    /// keeps that invariant without spinning up a store per query.
    private let queryQueue = DispatchQueue(
        label: "com.egemert.ledge.calendar.query", qos: .utility
    )

    public init() {}

    private func sharedStore() -> EKEventStore {
        if let store { return store }
        let created = EKEventStore()
        store = created
        return created
    }

    public var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    public func upcomingEvents(within window: TimeInterval) async -> [EventSnapshot] {
        guard isAuthorized else { return [] }
        return await query { store in
            let now = Date()
            let predicate = store.predicateForEvents(
                withStart: now,
                end: now.addingTimeInterval(window),
                calendars: nil
            )
            return store.events(matching: predicate)
                .filter { !$0.isAllDay }
                .filter { $0.status != .canceled }
                // An invitation the user declined is not a plan of theirs. The
                // declined state lives on the attendee, not on `status`.
                .filter { !Self.isDeclined($0) }
                .compactMap(Self.snapshot(from:))
                .sorted { $0.start < $1.start }
        }
    }

    public func eventDays(monthOffset: Int) async -> Set<Int> {
        guard isAuthorized else { return [] }
        return await query { store in
            let calendar = Calendar.current
            let now = Date()
            guard let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
                  let monthStart = calendar.date(byAdding: .month, value: monthOffset, to: thisMonth),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else { return [] }

            let predicate = store.predicateForEvents(withStart: monthStart, end: monthEnd, calendars: nil)
            var days: Set<Int> = []
            for event in store.events(matching: predicate) where event.status != .canceled && !Self.isDeclined(event) {
                days.formUnion(Self.days(
                    of: event, calendar: calendar,
                    monthStart: monthStart, monthEnd: monthEnd
                ))
            }
            return days
        }
    }

    public func events(monthOffset: Int) async -> [Int: [(title: String, time: String, eventID: String)]] {
        guard isAuthorized else { return [:] }
        return await query { store in
            let calendar = Calendar.current
            let now = Date()
            guard let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
                  let monthStart = calendar.date(byAdding: .month, value: monthOffset, to: thisMonth),
                  let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else { return [:] }

            // Locale-aware and hour-only: the grid's detail line has room for a
            // time, not a date.
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none

            let predicate = store.predicateForEvents(withStart: monthStart, end: monthEnd, calendars: nil)
            var byDay: [Int: [(start: Date, isAllDay: Bool, title: String, time: String, eventID: String)]] = [:]
            for event in store.events(matching: predicate) where event.status != .canceled && !Self.isDeclined(event) {
                guard let start = event.startDate else { continue }
                for day in Self.days(
                    of: event, calendar: calendar,
                    monthStart: monthStart, monthEnd: monthEnd
                ) {
                    // The clock time only belongs on the day the event starts;
                    // on its later days it reads as starting again.
                    let startsToday = calendar.component(.day, from: start) == day
                        && start >= monthStart
                    byDay[day, default: []].append((
                        start: start,
                        isAllDay: event.isAllDay,
                        title: event.title ?? "Event",
                        time: event.isAllDay || !startsToday ? "" : formatter.string(from: start),
                        eventID: event.calendarItemIdentifier
                    ))
                }
            }

            // All-day first, then by start time. An all-day event has no clock
            // time to sort on, so whatever order the store returned dropped it
            // into the middle of the day's timed events.
            return byDay.mapValues { entries in
                entries
                    .sorted { a, b in
                        if a.isAllDay != b.isAllDay { return a.isAllDay }
                        return a.start < b.start
                    }
                    .map { (title: $0.title, time: $0.time, eventID: $0.eventID) }
            }
        }
    }

    /// The day numbers of this month an event actually touches.
    ///
    /// The month predicate matches any event *overlapping* the month, and using
    /// the start date's day for those is doubly wrong: an event running in from
    /// last month dotted this month's grid at its old day number (July 30th's
    /// offsite marked August 30th), and a multi-day event marked only its first
    /// day. Walk the days the event covers, clipped to the month.
    private nonisolated static func days(
        of event: EKEvent,
        calendar: Calendar,
        monthStart: Date,
        monthEnd: Date
    ) -> [Int] {
        guard let start = event.startDate else { return [] }
        // EventKit gives all-day events an exclusive end at midnight of the
        // next day; treating that as covering the next day would dot one day
        // too many. A zero-length event still covers its own day.
        let end = max(event.endDate ?? start, start)
        let first = max(start, monthStart)
        let last = min(end, monthEnd)
        guard first < monthEnd, last > monthStart else { return [] }

        var days: [Int] = []
        var cursor = calendar.startOfDay(for: first)
        while cursor < last {
            if cursor >= monthStart {
                days.append(calendar.component(.day, from: cursor))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        // An event that starts and ends inside the same instant (or a timed
        // event ending exactly at a day boundary) must still mark its day.
        if days.isEmpty, first < monthEnd {
            days.append(calendar.component(.day, from: first))
        }
        return days
    }

    // MARK: - Off-main query

    /// Carries the store into the queue's closure. `EKEventStore` is not
    /// `Sendable`, and rightly so; what makes this safe is that the closure
    /// runs on the serial `queryQueue`, so the store is never driven by two
    /// threads at once.
    private struct StoreHandle: @unchecked Sendable {
        let store: EKEventStore
    }

    /// Runs a store query on the serial query queue against the shared store.
    ///
    /// Still off-main: Apple documents `events(matching:)` as potentially
    /// slow, and it fires on a ~60s cadence while a card is shown.
    private func query<T: Sendable>(
        _ body: @escaping @Sendable (EKEventStore) -> T
    ) async -> T {
        let handle = StoreHandle(store: sharedStore())
        return await withCheckedContinuation { continuation in
            queryQueue.async {
                continuation.resume(returning: body(handle.store))
            }
        }
    }

    private nonisolated static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        } ?? false
    }

    private nonisolated static func snapshot(from event: EKEvent) -> EventSnapshot? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        var red = 0.36, green = 0.55, blue = 0.9
        if let color = event.calendar?.cgColor, let parts = color.components, parts.count >= 3 {
            red = parts[0]; green = parts[1]; blue = parts[2]
        }
        // Fold the occurrence start into the key: EventKit returns the same
        // `eventIdentifier` for every occurrence of a recurring event, so
        // without the start two occurrences in the same window collide.
        let identifier = event.eventIdentifier ?? event.title ?? "?"
        return EventSnapshot(
            title: event.title ?? "Event",
            location: event.location ?? "",
            start: start,
            end: end,
            accentRed: red,
            accentGreen: green,
            accentBlue: blue,
            eventKey: "\(identifier)|\(start.timeIntervalSinceReferenceDate)",
            meetingURL: Self.meetingURL(of: event)
        )
    }

    /// The first video-call link in the event's URL, location or notes.
    ///
    /// Calendar invitations bury the link in any of the three; the known
    /// providers cover the meetings a Mac user actually joins, and requiring a
    /// known host keeps arbitrary tracking links out of a one-click button.
    private nonisolated static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com",
        "teams.live.com", "webex.com", "whereby.com", "facetime.apple.com",
    ]

    private nonisolated static func meetingURL(of event: EKEvent) -> String? {
        var candidates: [String] = []
        if let url = event.url?.absoluteString { candidates.append(url) }
        if let location = event.location { candidates.append(location) }
        if let notes = event.notes { candidates.append(notes) }

        // Every link in every field, not just the first per field: notes
        // routinely lead with an agenda or tracking link and bury the Zoom
        // link further down.
        for text in candidates {
            var search = text.startIndex..<text.endIndex
            while let range = text.range(
                of: #"https://[^\s<>"')\]]+"#, options: .regularExpression, range: search
            ) {
                search = range.upperBound..<text.endIndex
                var link = String(text[range])
                // Trailing punctuation from prose ("join: https://… .") is not
                // part of the link.
                while let last = link.last, ".,;".contains(last) { link.removeLast() }
                if let host = URL(string: link)?.host()?.lowercased(),
                   meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return link
                }
            }
        }
        return nil
    }

    public func startWatching(_ onChange: @escaping @MainActor () -> Void) {
        stopWatching()

        // Filter on the shared store: every store in the process posts this
        // for the same database change, so without `object:` a second store
        // anywhere in the app would fire the callback twice.
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: sharedStore(),
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    public func stopWatching() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// Fixed events, for tests and the preview app.
@MainActor
public final class StubCalendarSource: CalendarSource {

    public var isAuthorized: Bool
    public var events: [EventSnapshot]
    private var onChange: (() -> Void)?

    public init(events: [EventSnapshot] = [], isAuthorized: Bool = true) {
        self.events = events
        self.isAuthorized = isAuthorized
    }

    public func upcomingEvents(within window: TimeInterval) async -> [EventSnapshot] {
        guard isAuthorized else { return [] }
        let cutoff = Date().addingTimeInterval(window)
        return events.filter { $0.start <= cutoff }.sorted { $0.start < $1.start }
    }

    public func eventDays(monthOffset: Int) async -> Set<Int> {
        guard isAuthorized else { return [] }
        let calendar = Calendar.current
        return Set(events.map { calendar.component(.day, from: $0.start) })
    }

    public func events(monthOffset: Int) async -> [Int: [(title: String, time: String, eventID: String)]] {
        guard isAuthorized else { return [:] }
        let calendar = Calendar.current
        var byDay: [Int: [(title: String, time: String, eventID: String)]] = [:]
        for event in events {
            let day = calendar.component(.day, from: event.start)
            byDay[day, default: []].append((title: event.title, time: "", eventID: ""))
        }
        return byDay
    }

    public func set(_ events: [EventSnapshot]) {
        self.events = events
        onChange?()
    }

    public func startWatching(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    public func stopWatching() {
        onChange = nil
    }
}
