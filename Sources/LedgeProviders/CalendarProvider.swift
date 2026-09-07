import Foundation
import LedgeCore
import LedgeSystem
import os

/// Turns the calendar into activities.
///
/// Same rule as battery and Bluetooth: **transitions, not state.** A standing
/// "next event" card would sit in the queue all day, cycling in front of
/// whatever is playing. An event is news when it is *imminent* — inside the
/// lead window — and stays up until it ends, then goes away.
@MainActor
public final class CalendarProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "calendar")

    public let identifier = "calendar"

    /// How far ahead an event becomes worth showing.
    ///
    /// Equal to the query window, which makes the calendar a *standing* card
    /// sitting alongside weather rather than something that appears only just
    /// before a meeting. At thirty minutes the card was almost never on screen,
    /// which read as broken rather than quiet.
    ///
    /// The event is still only *peeked* when it arrives; sitting in the queue
    /// is not the same as interrupting.
    static var leadTime: TimeInterval { queryWindow }

    /// How far ahead to ask the store for events at all. Wide enough that the
    /// next re-evaluation date is always known.
    static let queryWindow: TimeInterval = 12 * 60 * 60

    /// While a card is up, the countdown it shows goes stale; republishing on
    /// this cadence keeps "in 12m" honest without hammering the store.
    static let refreshInterval: TimeInterval = 60

    /// An event this close to starting outranks whatever is in progress. Close
    /// enough that the user is about to get up and go, or reach for the join
    /// link — which is what the card is for — and far enough that the swap
    /// does not read as a flicker on back-to-back meetings.
    static let imminentLead: TimeInterval = 15 * 60

    /// An in-progress event longer than this is a *block* — an OOO week, a
    /// trip, "Focus 9–17" — rather than something the user is sitting in. A
    /// block is background, so anything coming up inside the lead window is
    /// the news, not the block.
    static let longEventDuration: TimeInterval = 4 * 60 * 60

    /// What to do now, and when to look again.
    ///
    /// Pure, so the whole scheduling policy is testable against invented
    /// events and a fixed clock.
    struct Plan: Equatable {
        var show: EventSnapshot?
        var nextCheck: TimeInterval?
    }

    static func plan(events: [EventSnapshot], now: Date) -> Plan {
        // Events still in progress or upcoming, soonest first. Anything already
        // over is out regardless of what the store returned.
        let relevant = events
            .filter { $0.end > now }
            .sorted { $0.start < $1.start }

        // Of the events in progress, the one ending soonest is the one the
        // user is actually in: a standup that starts inside a week-long OOO
        // block would otherwise lose to the block for its whole half hour,
        // because the block started first.
        let current = relevant
            .filter { $0.start <= now }
            .min { $0.end < $1.end }
        let upcoming = relevant.first { $0.start > now }

        // Which of the two is worth the card, when both exist:
        //
        //  * Upcoming starts within `imminentLead` — show it. Whatever is on
        //    now, the user needs the next one's countdown and join link more.
        //  * Current is a long block and upcoming is inside the lead window —
        //    show upcoming. An OOO Mon–Fri entry used to hide every meeting
        //    of the week behind "OOO", for days.
        //  * Otherwise current keeps the stage; a 30-minute meeting is not
        //    interrupted by something an hour off.
        if let current {
            var yieldsToUpcoming = false
            if let upcoming {
                let untilStart = upcoming.start.timeIntervalSince(now)
                let currentIsLong = current.end.timeIntervalSince(current.start) > Self.longEventDuration
                yieldsToUpcoming = untilStart <= Self.imminentLead
                    || (currentIsLong && untilStart <= Self.leadTime)
            }
            if !yieldsToUpcoming {
                // Refresh while shown, and no later than its end.
                let next = min(Self.refreshInterval, current.end.timeIntervalSince(now))
                return Plan(show: current, nextCheck: max(next, 1))
            }
        }

        guard let upcoming else {
            // Nothing on the horizon. The change watcher covers additions; the
            // periodic check covers the query window rolling forward.
            return Plan(show: nil, nextCheck: Self.queryWindow / 2)
        }

        let untilStart = upcoming.start.timeIntervalSince(now)
        if untilStart <= Self.leadTime {
            let next = min(Self.refreshInterval, untilStart)
            return Plan(show: upcoming, nextCheck: max(next, 1))
        }

        // Too far out to show. Wake exactly when it enters the lead window.
        return Plan(show: nil, nextCheck: untilStart - Self.leadTime)
    }

    private let source: any CalendarSource
    private let now: () -> Date
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var pending: DispatchWorkItem?
    private var evaluateTask: Task<Void, Never>?
    private var publishedID: ActivityID?

    /// The three month grids as last read, and the calendar day they were read
    /// on.
    ///
    /// The grids only change when the database does, so re-querying them on
    /// every 60-second countdown tick was six store queries a minute for a
    /// result that was identical the previous fifty-nine times. They are
    /// dropped — and re-read on the next evaluate — when the store reports a
    /// change, on wake (`refresh()`), and when the day rolls over: the month
    /// rollover shifts which three months the grid covers, and a daily reread
    /// is a cheap floor against anything the change notification misses.
    private var monthWindows: [MonthWindow]?
    private var monthWindowsDay: DateComponents?

    public init(
        source: any CalendarSource,
        now: @escaping () -> Date = { Date() }
    ) {
        self.source = source
        self.now = now
    }

    public func start() -> AsyncStream<ProviderEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in self?.stop() }
            }
            self.source.startWatching { [weak self] in
                // Something was added, moved or deleted: the grids are stale.
                self?.monthWindows = nil
                self?.requestEvaluate()
            }
            self.requestEvaluate()
        }
    }

    public func stop() {
        source.stopWatching()
        pending?.cancel()
        pending = nil
        evaluateTask?.cancel()
        evaluateTask = nil
        continuation?.finish()
        continuation = nil
        publishedID = nil
        monthWindows = nil
    }

    /// Re-evaluates now. For the wake path: the long-horizon check runs on a
    /// suspending clock, so a night of sleep leaves the pending wake owing
    /// its full awake time — a 9:00 meeting's card would otherwise appear
    /// hours late or after the meeting.
    public func refresh() {
        guard continuation != nil else { return }
        // Change notifications may not have been delivered across the sleep,
        // so treat wake as a store change too.
        monthWindows = nil
        requestEvaluate()
    }

    /// The periodic countdown tick, by hand. The real one is a 60-second
    /// timer on the main queue, which no test should sit through; this lets a
    /// test check what a tick does and does not query.
    func tickForTesting() {
        requestEvaluate()
    }

    /// Kicks off an evaluation, replacing any in flight.
    ///
    /// The store query is async and off-main now, so two evaluations could
    /// otherwise overlap and publish out of order. Cancelling the previous one
    /// keeps a single, latest read.
    private func requestEvaluate() {
        evaluateTask?.cancel()
        evaluateTask = Task { @MainActor [weak self] in
            await self?.evaluate()
        }
    }

    private func evaluate() async {
        let events = await source.upcomingEvents(within: Self.queryWindow)
        // The provider may have been stopped while the query was in flight.
        guard !Task.isCancelled, continuation != nil else { return }

        let plan = Self.plan(events: events, now: now())

        // Without the grant there is nothing to show and nothing to ask for —
        // the card must not appear at all, empty or otherwise.
        guard source.isAuthorized else {
            if let publishedID {
                continuation?.yield(.retract(publishedID))
                self.publishedID = nil
            }
            // Whatever was cached was read under a grant that is now gone;
            // if access comes back, start from a fresh read.
            monthWindows = nil
            if let delay = plan.nextCheck { schedule(after: delay) }
            return
        }

        // The card stands whether or not anything is coming up. It is a
        // calendar, not a meeting alarm — a month you can open and tap is worth
        // having on a quiet day, and retracting it on an empty afternoon is
        // what made the calendar look like it had stopped working.
        // Previous, current and next month, so the grid's arrows have data
        // without a fresh EventKit round-trip per tap.
        let calendar = Calendar.current
        let today = calendar.dateComponents([.year, .month, .day], from: now())
        if monthWindows == nil || monthWindowsDay != today {
            guard let windows = await readMonthWindows(calendar: calendar) else { return }
            monthWindows = windows
            monthWindowsDay = today
        }
        let windows = monthWindows ?? []
        let current = windows.first { window in
            let comps = calendar.dateComponents([.year, .month], from: now())
            return window.year == comps.year && window.month == comps.month
        }
        publish(
            plan.show,
            monthEventDays: Set(current?.eventDays ?? []),
            monthEvents: current?.events ?? [],
            monthWindows: windows
        )

        if let delay = plan.nextCheck {
            schedule(after: delay)
        }
    }

    /// Reads the previous, current and next month's grids from the store.
    /// Nil if the provider was stopped or superseded while a query was in
    /// flight, in which case the caller must publish nothing.
    private func readMonthWindows(calendar: Calendar) async -> [MonthWindow]? {
        var windows: [MonthWindow] = []
        for offset in -1...1 {
            let days = await source.eventDays(monthOffset: offset)
            let byDay = await source.events(monthOffset: offset)
            guard !Task.isCancelled, continuation != nil else { return nil }
            guard let month = calendar.date(byAdding: .month, value: offset, to: now()) else { continue }
            let comps = calendar.dateComponents([.year, .month], from: month)
            windows.append(MonthWindow(
                year: comps.year ?? 0,
                month: comps.month ?? 0,
                eventDays: Array(days).sorted(),
                events: byDay
                    .map { day, entries in
                        MonthDayEvents(
                            day: day,
                            entries: entries.map {
                                MonthDayEntry(title: $0.title, time: $0.time, eventID: $0.eventID)
                            }
                        )
                    }
                    .sorted { $0.day < $1.day }
            ))
        }
        return windows
    }

    private func publish(
        _ event: EventSnapshot?,
        monthEventDays: Set<Int>,
        monthEvents: [MonthDayEvents] = [],
        monthWindows: [MonthWindow] = []
    ) {
        let dayEvents = monthEvents

        // One stable id for the empty card, so a quiet day does not churn the
        // queue and the month grid keeps the day the user tapped.
        let id = ActivityID(kind: .event, source: event?.eventKey ?? "calendar")

        // A different event took over — the old card must not linger.
        if let publishedID, publishedID != id {
            continuation?.yield(.retract(publishedID))
        }
        publishedID = id

        continuation?.yield(.publish(Activity(
            id: id,
            createdAt: now().timeIntervalSinceReferenceDate,
            // No expiry: the plan retracts it when the event ends. Letting a
            // timer race the plan would drop the card mid-meeting.
            payload: .event(EventPayload(
                title: event?.title ?? "",
                location: event?.location ?? "",
                startsIn: event.map { $0.start.timeIntervalSince(now()) } ?? 0,
                accent: event.map {
                    AccentColor(red: $0.accentRed, green: $0.accentGreen, blue: $0.accentBlue)
                } ?? .neutral,
                hasEvent: event != nil,
                meetingURL: event?.meetingURL,
                monthEventDays: Array(monthEventDays).sorted(),
                monthEvents: dayEvents,
                monthWindows: monthWindows
            ))
        )))
    }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.requestEvaluate() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 1), execute: item)
    }
}
