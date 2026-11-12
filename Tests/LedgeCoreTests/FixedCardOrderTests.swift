import Foundation
import Testing

@testable import LedgeCore

/// Everyday cards go in one fixed order, with what can be read ahead of controls
/// and containers. Only news jumps ahead, and only until it is over.
@Suite("Fixed card order")
struct FixedCardOrderTests {

    static let expected: [ActivityKind] = [
        .nowPlaying, .event, .weather, .focus, .keepAwake, .levels, .timer, .notes, .shelf,
    ]

    private static func card(_ kind: ActivityKind, _ payload: ActivityPayload, source: String = "t") -> Activity {
        Activity(id: ActivityID(kind: kind, source: source), createdAt: 0, payload: payload)
    }

    private static func music(playing: Bool = true) -> Activity {
        card(.nowPlaying, .nowPlaying(NowPlayingPayload(title: "t", artist: "a", isPlaying: playing)))
    }

    private static func calendar(startsIn: TimeInterval = 4 * 3600, hasEvent: Bool = true) -> Activity {
        card(.event, .event(EventPayload(title: "Standup", startsIn: startsIn, hasEvent: hasEvent)))
    }

    private static func weather(rain: Int? = nil) -> Activity {
        card(.weather, .weather(WeatherPayload(temperatureCelsius: 20, rainSoonMinutes: rain)))
    }

    private static func keepAwake(_ phase: KeepAwakePayload.Phase = .ready) -> Activity {
        card(.keepAwake, .keepAwake(KeepAwakePayload(phase: phase, remaining: 3600, until: "17:40")))
    }

    private static func timer(running: Bool = false) -> Activity {
        // One id for both, to replace in place. The provider gives them
        // separate ids and never publishes the two together.
        card(.timer, .timer(TimerPayload(
            label: "Focus", remaining: 600, total: 1500, isRunning: running, isIdle: !running
        )))
    }

    private static var focus: Activity { card(.focus, .focus(FocusPayload(name: "Work"))) }
    private static var levels: Activity { card(.levels, .levels(LevelsPayload(volume: 0.5, brightness: 0.5))) }
    private static var notes: Activity { card(.notes, .notes(NotesPayload())) }
    private static var shelf: Activity { card(.shelf, .shelf(ShelfPayload())) }

    private static var deck: [Activity] {
        [music(), calendar(), weather(), focus, keepAwake(), levels, timer(), notes, shelf]
    }

    /// Every ordering of `items`, for selection rules that depend on arrival.
    private static func permutations<T>(_ items: [T]) -> [[T]] {
        guard let first = items.first else { return [[]] }
        return permutations(Array(items.dropFirst())).flatMap { rest in
            (0...rest.count).map { index in
                var next = rest
                next.insert(first, at: index)
                return next
            }
        }
    }

    private static func queue(_ cards: [Activity]) -> ActivityQueue {
        var queue = ActivityQueue()
        for card in cards { queue.upsert(card) }
        return queue
    }

    // MARK: - The order

    @Test("Everyday cards take one order whichever arrives first, and none goes missing")
    func oneOrder() {
        var generator = SeededGenerator(state: 0x1ED6E)
        for _ in 0..<200 {
            var cards = Self.deck.shuffled(using: &generator)
            for index in cards.indices { cards[index].createdAt = TimeInterval(index) }
            let queue = Self.queue(cards)
            #expect(queue.activities.map(\.kind) == Self.expected)
        }
    }

    @Test("What a card is doing doesn't move it")
    func stateDoesNotMove() {
        let musics = [Self.music(playing: true), Self.music(playing: false)]
        let calendars = [
            Self.calendar(startsIn: 45 * 60),
            Self.calendar(startsIn: 4 * 3600),
            Self.calendar(startsIn: 0, hasEvent: false),
        ]
        let weathers = [Self.weather(), Self.weather(rain: 20)]
        let holds = [Self.keepAwake(.ready), Self.keepAwake(.running)]
        let timers = [Self.timer(running: false), Self.timer(running: true)]

        var checked = 0
        for music in musics {
            for calendar in calendars {
                for weather in weathers {
                    for hold in holds {
                        for timer in timers {
                            let queue = Self.queue([
                                timer, hold, weather, calendar, music,
                                Self.focus, Self.levels, Self.notes, Self.shelf,
                            ])
                            #expect(queue.activities.map(\.kind) == Self.expected)
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == 2 * 3 * 2 * 2 * 2)
    }

    @Test("Real news goes ahead of every everyday card")
    func newsGoesAhead() {
        let news: [Activity] = [
            Self.card(.privacy, .privacy(PrivacyPayload(cameraActive: true))),
            Self.calendar(startsIn: 15 * 60),
            Self.calendar(startsIn: -60),
            Self.card(.timer, .timer(TimerPayload(
                label: "Focus", remaining: 0, total: 300, isRunning: false, isFinished: true
            )), source: "finished"),
            Self.keepAwake(.finished(.timeUp)),
            Self.card(.device, .device(DevicePayload(name: "AirPods", symbolName: "airpods"))),
            Self.card(.power, .power(PowerPayload(percentage: 10, isCharging: false))),
            Self.card(.message, .message(MessagePayload(title: "t", body: "b"))),
            Self.card(.keyboard, .keyboard(KeyboardLayoutPayload(name: "ABC"))),
        ]
        let top = Self.deck.map { Urgency.score(of: $0) }.max() ?? .max
        #expect(top == Urgency.score(of: Self.music()))
        for item in news {
            #expect(Urgency.score(of: item) > top, "\(item.kind)")
        }
    }

    @Test("A finished Keep Awake goes back to its place when it returns to ready")
    func newsEnds() {
        var queue = Self.queue(Self.deck)
        queue.upsert(Self.keepAwake(.finished(.timeUp)))
        #expect(queue.activities.first?.kind == .keepAwake, "fixture: its ending has to have jumped ahead")

        queue.upsert(Self.keepAwake(.ready))
        #expect(queue.activities.map(\.kind) == Self.expected)
    }

    // MARK: - The card a first hover opens

    @Test("The first card is the first in the order, whichever arrives first")
    func firstCard() {
        let everyday: [Activity] = [
            Self.music(), Self.calendar(), Self.weather(), Self.keepAwake(.running), Self.levels,
        ]
        for arrival in Self.permutations(everyday) {
            #expect(Self.queue(arrival).selected?.kind == .nowPlaying)
        }
        let noMusic = Array(everyday.dropFirst())
        for arrival in Self.permutations(noMusic) {
            #expect(Self.queue(arrival).selected?.kind == .event)
        }
        let noCalendar = Array(noMusic.dropFirst())
        for arrival in Self.permutations(noCalendar) {
            #expect(Self.queue(arrival).selected?.kind == .weather)
        }
    }

    @Test("Starting Keep Awake leaves the card on screen and the order alone")
    func startingMovesNothing() {
        var queue = Self.queue(Self.deck)
        queue.select(Self.weather().id)
        #expect(queue.selected?.kind == .weather, "fixture: must be on the weather first")

        queue.upsert(Self.keepAwake(.running))
        #expect(queue.selected?.kind == .weather)
        #expect(queue.activities.map(\.kind) == Self.expected)
    }

    @Test("Turning Keep Awake on in Settings doesn't take the screen from a card with more to read")
    func arrivingDoesNotTake() {
        for held in [Self.music(playing: false), Self.calendar(), Self.weather()] {
            var queue = Self.queue([held])
            #expect(queue.selected?.id == held.id, "fixture: must be on that card first")

            queue.upsert(Self.keepAwake(.running))
            #expect(queue.selected?.id == held.id)
            #expect(queue.count == 2, "it is still there to move to")
        }
    }

    @Test("A stack opening afresh starts on the first card, not the one last read")
    func opensOnFirst() {
        var queue = Self.queue(Self.deck)
        queue.select(Self.keepAwake().id)
        #expect(queue.selected?.kind == .keepAwake, "fixture: must be on Keep Awake first")

        queue.selectFirst()
        #expect(queue.selected?.kind == .nowPlaying)
        #expect(queue.count == Self.deck.count)
    }

    @Test("A meeting about to start is the first card, and a pin beats it")
    func firstFollowsTheOrder() {
        var queue = Self.queue(Self.deck)
        queue.upsert(Self.calendar(startsIn: 5 * 60))
        queue.selectFirst()
        #expect(queue.selected?.kind == .event)

        queue.pinnedKind = .weather
        queue.selectFirst()
        #expect(queue.selected?.kind == .weather)
    }

    @Test("Going to the first card on an empty queue does nothing")
    func firstOnEmpty() {
        var queue = ActivityQueue()
        queue.selectFirst()
        #expect(queue.selected == nil)
    }

    /// `LedgeCoordinator` can't be built in a test, so this reads it. Each line
    /// is a way for the rule to die quietly: the queue would still pass above
    /// while nothing ever asked it for the first card.
    @Test("The shell asks for the first card with nothing on screen, unless told to keep the last one")
    func hoverWiring() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let coordinator = try String(
            contentsOf: root.appending(path: "Sources/LedgeShell/Coordinator/LedgeCoordinator.swift"),
            encoding: .utf8
        )
        let start = try #require(coordinator.range(of: "private func settleBeforeReducing("))
        let settling = coordinator[start.upperBound...]
        let end = settling.range(of: "\n    }\n")?.lowerBound ?? settling.endIndex
        let hook = settling[..<end]
        #expect(hook.contains("if event == .hoverChanged(true), state.phase == .idle, preferences.pinnedCard != Prefs.lastReadCard {"))
        #expect(hook.contains("activities.selectFirst()"))

        // The ears keep their rule: what they show is what opens.
        #expect(coordinator.contains("""
                        } else if let shown = self.restingContent() {
                            self.activities.select(shown.id)
                        } else {
                            self.activities.selectFirst()
                        }
"""))
    }

    /// The order reads `pinnedCard` as a card kind. "Last one read" has to
    /// read as no pin there, or choosing it would move a card to the front.
    @Test("Last one read names no card and is not the default")
    func lastReadIsNoPin() throws {
        #expect(ActivityKind(rawValue: Prefs.lastReadCard) == nil)
        #expect(Prefs.lastReadCard != Prefs.pinnedCard.defaultValue)

        var queue = Self.queue(Self.deck)
        queue.pinnedKind = ActivityKind(rawValue: Prefs.lastReadCard)
        let levels = try #require(queue.activities.first { $0.kind == .levels })
        queue.select(levels.id)
        #expect(queue.selected?.kind == .levels)
        queue.selectFirst()
        #expect(queue.selected?.kind == .nowPlaying)
    }

    @Test("Settings offers Last one read under Opens first")
    func lastReadIsOffered() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tab = try String(
            contentsOf: root.appending(path: "Sources/LedgeUI/Settings/CardsSettingsTab.swift"),
            encoding: .utf8
        )
        let start = try #require(tab.range(of: "Picker(\"Opens first\""))
        let picker = tab[start.upperBound...].prefix { $0 != "}" }
        #expect(picker.contains("Text(\"Last one read\").tag(Prefs.lastReadCard)"))
        #expect(picker.contains("Text(\"Whatever matters most\").tag(\"\")"))
    }

    // MARK: - What the order must not change

    @Test("A keyboard fact can still cut in over every everyday card")
    func keyboardStillCutsIn() {
        let input = Self.card(.keyboard, .keyboard(KeyboardLayoutPayload(name: "ABC")))
        for card in Self.deck {
            #expect(PeekTurn.takesOver(input, from: card, standingUp: false), "\(card.kind)")
        }
    }

    @Test("An everyday card stays below the announcements it must not displace")
    func staysBelowAnnouncements() {
        let lowestNews = [ActivityKind.device, .power, .message, .keyboard, .privacy]
            .map(\.defaultPriority).min() ?? 0
        for kind in Self.expected {
            #expect(kind.defaultPriority < lowestNews, "\(kind)")
        }
    }
}

/// Reproducible shuffles, so a failure can be replayed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
