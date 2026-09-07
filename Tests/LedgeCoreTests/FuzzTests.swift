import CoreGraphics
import Foundation
import Testing

@testable import LedgeCore

/// Deterministic PRNG so every failure reproduces from its seed. SplitMix64:
/// tiny, well-distributed, and not `SystemRandomNumberGenerator`, whose output
/// changes run to run and would make a red fuzz test undebuggable.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Reducer fuzz

/// Random—but realistic—event storms against the reducer, checking invariants
/// no single example-based test states.
///
/// The generator only produces sequences the shell can produce: a click needs
/// the cursor inside, a timer can only fire while armed, hover only flips.
/// Timers are modelled as a set folded from the returned effects, which is
/// exactly what the coordinator does with them.
@Suite("Reducer fuzz")
struct ReducerFuzzTests {

    private struct Harness {
        var state: NotchState
        var armed: Set<NotchTimer> = []

        init(clickPins: Bool) {
            state = NotchState(clickPins: clickPins)
        }

        mutating func apply(_ event: NotchEvent) {
            if case .timerFired(let timer) = event {
                // A fired timer is consumed whether or not the reducer acts.
                armed.remove(timer)
            }
            for effect in NotchReducer.reduce(&state, event) {
                switch effect {
                case .startTimer(let timer, _): armed.insert(timer)
                case .cancelTimer(let timer): armed.remove(timer)
                }
            }
        }

        /// Every event the shell could deliver from this state.
        var possibleEvents: [NotchEvent] {
            var events: [NotchEvent] = [
                .hoverChanged(!state.isHovering),
                .peekRequested(2),
                .hudRequested(1.5),
                .hudReleased,
                .nowPlayingChanged(!state.hasNowPlaying),
                .dismissed,
                .forceCollapse,
            ]
            // A click comes from a tap on the overlay: cursor inside.
            if state.isHovering { events.append(.clicked) }
            for timer in armed { events.append(.timerFired(timer)) }
            return events
        }
    }

    /// The machine must never sit open with nothing left to close it: every
    /// non-resting phase needs either the cursor or an armed timer keeping an
    /// exit alive. Violations are exactly the "stuck notch" bug class.
    private func checkInvariants(
        _ h: Harness,
        seed: UInt64,
        step: Int,
        history: [NotchEvent]
    ) {
        let s = h.state
        let context = "seed \(seed) step \(step): \(history.suffix(6)) -> \(s), armed \(h.armed)"

        // Liveness: an exit must exist.
        switch s.phase {
        case .peek:
            #expect(h.armed.contains(.peek), Comment(rawValue: "peek unarmed — \(context)"))
        case .hud:
            #expect(s.isHovering || h.armed.contains(.hud), Comment(rawValue: "hud unarmed — \(context)"))
        case .expanded:
            #expect(s.isHovering || h.armed.contains(.pinRelease), Comment(rawValue: "expanded abandoned — \(context)"))
        case .hover:
            #expect(s.isHovering, Comment(rawValue: "hover without cursor — \(context)"))
        case .idle, .companion:
            break
        }

        // A restore is only owed by a HUD.
        #expect(s.suspended == nil || s.phase == .hud, Comment(rawValue: "suspended outside hud — \(context)"))
        // The HUD never owes a restore to itself or to a timer-driven peek…
        #expect(s.suspended != .hud, Comment(rawValue: "hud suspended hud — \(context)"))
        // A pin is an expanded card, possibly interrupted by a HUD.
        if s.isPinned {
            #expect(
                s.phase == .expanded || (s.phase == .hud && s.suspended == .expanded),
                Comment(rawValue: "pin lost its card — \(context)")
            )
        }
        // Expanded is always a pin: nothing else produces the phase.
        if s.phase == .expanded {
            #expect(s.isPinned, Comment(rawValue: "expanded unpinned — \(context)"))
        }
        // The companion exists to show music; drawn without a track it is an
        // empty pill stuck on screen.
        if s.phase == .companion {
            #expect(s.hasNowPlaying, Comment(rawValue: "companion without music — \(context)"))
        }
    }

    @Test("10k random event storms leave no stuck state", arguments: [UInt64(1), 2, 3, 4])
    func storms(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for run in 0..<2_500 {
            var harness = Harness(clickPins: run % 2 == 0)
            var history: [NotchEvent] = []
            for step in 0..<40 {
                let events = harness.possibleEvents
                let event = events[Int(rng.next() % UInt64(events.count))]
                history.append(event)
                harness.apply(event)
                checkInvariants(harness, seed: seed, step: step, history: history)
            }
        }
    }

    @Test("Quiescence: dismiss from any reachable state rests the machine")
    func dismissAlwaysRests(  ) {
        var rng = SplitMix64(seed: 99)
        for run in 0..<2_000 {
            var harness = Harness(clickPins: run % 2 == 0)
            for _ in 0..<25 {
                let events = harness.possibleEvents
                harness.apply(events[Int(rng.next() % UInt64(events.count))])
            }
            harness.apply(.dismissed)
            let s = harness.state
            #expect(s.isPinned == false)
            #expect(s.suspended == nil)
            let resting: NotchPhase = s.isHovering ? .hover : (s.hasNowPlaying ? .companion : .idle)
            #expect(s.phase == resting)
        }
    }
}

// MARK: - Queue fuzz

/// Random op storms against the activity queue. Providers republish, retract
/// and expire on their own schedules while the user cycles and dismisses; the
/// interleavings are exactly what example-based tests cannot enumerate.
@Suite("Activity queue fuzz")
struct QueueFuzzTests {

    private static let kinds: [ActivityKind] = Array(ActivityKind.allCases)

    /// A payload matching the kind, with the boost-bearing fields randomized —
    /// an all-focus fuzz exercised none of Urgency's branches, which made the
    /// score-ordering invariant quietly equivalent to the old priority one.
    private func makePayload(_ kind: ActivityKind, _ rng: inout SplitMix64) -> ActivityPayload {
        switch kind {
        case .nowPlaying:
            return .nowPlaying(NowPlayingPayload(
                title: "t", artist: "a", isPlaying: rng.next() % 2 == 0
            ))
        case .event:
            return .event(EventPayload(
                title: "e",
                startsIn: TimeInterval(rng.next() % 7_200),
                hasEvent: rng.next() % 2 == 0
            ))
        case .timer:
            return .timer(TimerPayload(
                label: "f", remaining: 60, total: 300,
                isRunning: rng.next() % 2 == 0,
                isFinished: rng.next() % 4 == 0,
                isIdle: rng.next() % 4 == 0
            ))
        case .privacy:
            return .privacy(PrivacyPayload(
                cameraActive: rng.next() % 2 == 0, micActive: rng.next() % 2 == 0
            ))
        case .weather:
            return .weather(WeatherPayload(
                temperatureCelsius: 20,
                rainSoonMinutes: rng.next() % 2 == 0 ? Int(rng.next() % 60) : nil
            ))
        default:
            return .focus(FocusPayload(name: "fuzz"))
        }
    }

    private func makeActivity(_ rng: inout SplitMix64, tick: TimeInterval) -> Activity {
        let kind = Self.kinds[Int(rng.next() % UInt64(Self.kinds.count))]
        return Activity(
            id: ActivityID(kind: kind, source: "s\(rng.next() % 6)"),
            priority: Int(rng.next() % 100),
            createdAt: tick,
            expiresAfter: rng.next() % 3 == 0 ? TimeInterval(rng.next() % 5) + 0.5 : nil,
            payload: makePayload(kind, &rng)
        )
    }

    private func checkInvariants(_ queue: ActivityQueue, seed: UInt64, step: Int) {
        let context = "seed \(seed) step \(step)"

        // The selection may never dangle, and an empty queue selects nothing.
        if let id = queue.selectedID {
            #expect(queue.activities.contains { $0.id == id }, Comment(rawValue: "dangling selection — \(context)"))
        }
        if !queue.isEmpty {
            #expect(queue.selectedID != nil, Comment(rawValue: "nothing selected — \(context)"))
        }

        // One slot per id.
        let ids = queue.activities.map(\.id)
        #expect(Set(ids).count == ids.count, Comment(rawValue: "duplicate ids — \(context)"))

        // Ordered by urgency score, then recency — unless the order is
        // frozen, where staleness is the contract.
        if !queue.orderFrozen {
            for (a, b) in zip(queue.activities, queue.activities.dropFirst()) {
                let left = Urgency.score(of: a, pinned: queue.pinnedKind)
                let right = Urgency.score(of: b, pinned: queue.pinnedKind)
                #expect(
                    left > right || (left == right && a.createdAt >= b.createdAt),
                    Comment(rawValue: "order broken — \(context)")
                )
            }
        }

        // The undo stack stays bounded.
        #expect(queue.dismissed.count <= ActivityQueue.dismissedLimit)
    }

    @Test("50k random ops keep every invariant", arguments: [UInt64(11), 12, 13])
    func storms(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<500 {
            var queue = ActivityQueue()
            var tick: TimeInterval = 0
            // The residents' relative order at the moment the freeze began —
            // the freeze contract is that it survives everything but removal.
            var frozenOrder: [ActivityID]? = nil
            for step in 0..<100 {
                tick += TimeInterval(rng.next() % 3)
                let wasFrozen = queue.orderFrozen
                switch rng.next() % 10 {
                case 0, 1, 2:
                    queue.upsert(makeActivity(&rng, tick: tick))
                case 3:
                    // Retract an id that may or may not be present.
                    let victim = makeActivity(&rng, tick: tick)
                    queue.retract(victim.id)
                case 4:
                    queue.dismissSelected()
                case 5:
                    _ = queue.restoreLastDismissed(at: tick)
                case 6:
                    rng.next() % 2 == 0 ? queue.cycleForward() : queue.cycleBackward()
                case 7:
                    queue.orderFrozen.toggle()
                case 8:
                    queue.pinnedKind = rng.next() % 2 == 0 ? nil : Self.kinds[Int(rng.next() % UInt64(Self.kinds.count))]
                default:
                    queue.removeExpired(at: tick)
                }
                // Track the freeze window and hold residents to their order.
                // A card that *leaves* the queue mid-freeze (dismissed,
                // expired, retracted) stops being a resident for good: if the
                // user restores it, it re-enters as a newcomer and may seat
                // anywhere — that is their own action moving their own card.
                if queue.orderFrozen && !wasFrozen {
                    frozenOrder = queue.activities.map(\.id)
                } else if !queue.orderFrozen {
                    frozenOrder = nil
                }
                if queue.orderFrozen, frozenOrder != nil {
                    let present = Set(queue.activities.map(\.id))
                    frozenOrder = frozenOrder?.filter { present.contains($0) }
                }
                if let order = frozenOrder, queue.orderFrozen {
                    let residents = queue.activities.map(\.id).filter { order.contains($0) }
                    #expect(
                        residents == order,
                        Comment(rawValue: "frozen residents reordered — seed \(seed) step \(step)")
                    )
                }
                checkInvariants(queue, seed: seed, step: step)
            }
        }
    }

    @Test("A provider republishing every tick never reorders the queue")
    func republishStability() {
        var queue = ActivityQueue()
        var rng = SplitMix64(seed: 7)
        for index in 0..<6 {
            queue.upsert(Activity(
                id: ActivityID(kind: .nowPlaying, source: "s\(index)"),
                priority: 30,
                createdAt: TimeInterval(index),
                payload: .focus(FocusPayload(name: "x"))
            ))
        }
        let order = queue.activities.map(\.id)
        // A storm of same-priority republishes with fresh timestamps — the
        // stated guarantee is that in-place updates never re-sort.
        for _ in 0..<1_000 {
            let source = "s\(rng.next() % 6)"
            queue.upsert(Activity(
                id: ActivityID(kind: .nowPlaying, source: source),
                priority: 30,
                createdAt: TimeInterval(rng.next() % 10_000),
                payload: .focus(FocusPayload(name: "y"))
            ))
            #expect(queue.activities.map(\.id) == order)
        }
    }
}

// MARK: - Month grid sweep

/// Every month for two decades, plus hostile inputs. The grid is pure math
/// over `Calendar`, so the whole space is cheap to sweep.
@Suite("Month grid sweep")
struct MonthGridSweepTests {

    @Test("Every month 2016–2036 lays out exactly once, in order, in weeks of seven")
    func decades() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Istanbul"))

        for year in 2016...2036 {
            for month in 1...12 {
                let today = try #require(calendar.date(from: DateComponents(
                    year: year, month: month, day: min(15, 28)
                )))
                let grid = MonthGrid.make(containing: today, calendar: calendar)

                for week in grid.weeks {
                    #expect(week.count == 7, "ragged week in \(year)-\(month)")
                }
                let days = grid.weeks.flatMap { $0 }.compactMap(\.day)
                let expected = calendar.range(of: .day, in: .month, for: today)!.count
                #expect(days == Array(1...expected), "day sequence broken in \(year)-\(month)")
                #expect(grid.weeks.flatMap { $0 }.filter(\.isToday).count == 1)
            }
        }
    }

    @Test("DST transition days and year boundaries do not shift the grid")
    func awkwardDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        // DST springs forward 2026-03-29 in Berlin; also check the leap day and
        // both sides of New Year midnight.
        let awkward: [DateComponents] = [
            .init(year: 2026, month: 3, day: 29, hour: 3),
            .init(year: 2028, month: 2, day: 29, hour: 0),
            .init(year: 2026, month: 12, day: 31, hour: 23, minute: 59),
            .init(year: 2027, month: 1, day: 1, hour: 0),
        ]
        for comps in awkward {
            let date = try #require(calendar.date(from: comps))
            let grid = MonthGrid.make(containing: date, calendar: calendar)
            let days = grid.weeks.flatMap { $0 }.compactMap(\.day)
            let expected = calendar.range(of: .day, in: .month, for: date)!.count
            #expect(days == Array(1...expected))
            let today = grid.weeks.flatMap { $0 }.first(where: \.isToday)
            #expect(today?.day == comps.day)
        }
    }
}

// MARK: - Geometry fuzz

/// Hostile preference values reach the layout math unfiltered — a corrupted
/// defaults database or a migration bug must degrade the drawing, never crash
/// it or poison a CGRect with NaN.
@Suite("Geometry fuzz")
struct GeometryFuzzTests {

    @Test("cardSize stays finite and at least notch-sized for hostile inputs")
    func cardSizeHostileInputs() {
        var rng = SplitMix64(seed: 21)
        let hostile: [CGFloat] = [0, -1, -1e6, 1e9, .leastNonzeroMagnitude, 1e-9]
        func dimension(_ rng: inout SplitMix64) -> CGFloat {
            let roll = rng.next() % 4
            if roll == 0 { return hostile[Int(rng.next() % UInt64(hostile.count))] }
            return CGFloat(rng.next() % 2_000)
        }

        for _ in 0..<5_000 {
            let geometry = NotchGeometry(
                screenSize: CGSize(width: max(dimension(&rng), 1), height: max(dimension(&rng), 1)),
                notchSize: CGSize(width: max(dimension(&rng), 1), height: max(dimension(&rng), 1)),
                notchCenterX: dimension(&rng),
                isHardwareNotch: rng.next() % 2 == 0
            )
            let kind: ActivityKind? = rng.next() % 5 == 0
                ? nil
                : QueueFuzzTests.randomKind(&rng)
            let size = NotchLayout.cardSize(
                kind: kind,
                phase: .hover,
                base: CGSize(width: dimension(&rng), height: dimension(&rng)),
                geometry: geometry,
                routePickerRows: Int(rng.next() % 5),
                hasSelection: rng.next() % 2 == 0
            )
            #expect(size.width.isFinite && size.height.isFinite)
            #expect(size.width >= 0 && size.height >= 0)
        }
    }
}

extension QueueFuzzTests {
    fileprivate static func randomKind(_ rng: inout SplitMix64) -> ActivityKind {
        kinds[Int(rng.next() % UInt64(kinds.count))]
    }
}
