import Foundation
import Testing

@testable import LedgeCore

@Suite("Activity queue")
struct ActivityQueueTests {

    private func activity(
        _ kind: ActivityKind,
        _ source: String,
        priority: Int? = nil,
        createdAt: TimeInterval = 0,
        expiresAfter: TimeInterval? = nil,
        title: String = "t"
    ) -> Activity {
        Activity(
            id: ActivityID(kind: kind, source: source),
            priority: priority,
            createdAt: createdAt,
            expiresAfter: expiresAfter,
            payload: .message(MessagePayload(title: title))
        )
    }

    // MARK: - Ordering

    @Test("Higher priority sorts to the front")
    func priorityOrdering() {
        var queue = ActivityQueue()
        queue.upsert(activity(.nowPlaying, "a", priority: 10))
        queue.upsert(activity(.message, "b", priority: 90))
        queue.upsert(activity(.device, "c", priority: 50))
        #expect(queue.activities.map(\.id.source) == ["b", "c", "a"])
    }

    @Test("Equal priorities order newest first")
    func recencyOrdering() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "old", priority: 50, createdAt: 1))
        queue.upsert(activity(.message, "new", priority: 50, createdAt: 2))
        #expect(queue.activities.map(\.id.source) == ["new", "old"])
    }

    @Test("Ordering is total, so identical priority and time cannot flicker")
    func totalOrdering() {
        var first = ActivityQueue()
        first.upsert(activity(.message, "b", priority: 50, createdAt: 1))
        first.upsert(activity(.message, "a", priority: 50, createdAt: 1))

        var second = ActivityQueue()
        second.upsert(activity(.message, "a", priority: 50, createdAt: 1))
        second.upsert(activity(.message, "b", priority: 50, createdAt: 1))

        #expect(first.activities.map(\.id.source) == second.activities.map(\.id.source))
    }

    // MARK: - Upsert

    @Test("The same id replaces in place rather than stacking")
    func upsertReplaces() {
        var queue = ActivityQueue()
        queue.upsert(activity(.nowPlaying, "p", title: "first"))
        queue.upsert(activity(.nowPlaying, "p", title: "second"))
        #expect(queue.count == 1)
        #expect(queue.selected?.payload == .message(MessagePayload(title: "second")))
    }

    @Test("Updating an activity does not steal the selection back to it")
    func updateDoesNotStealSelection() {
        var queue = ActivityQueue()
        queue.upsert(activity(.nowPlaying, "music", priority: 30))
        queue.upsert(activity(.message, "alert", priority: 90))
        #expect(queue.selectedID?.source == "alert")

        // A now-playing tick arrives; the user is still reading the alert.
        queue.upsert(activity(.nowPlaying, "music", priority: 30, title: "updated"))
        #expect(queue.selectedID?.source == "alert")
    }

    @Test("A more important arrival takes the screen")
    func higherPriorityArrivalSelects() {
        var queue = ActivityQueue()
        queue.upsert(activity(.nowPlaying, "music", priority: 30))
        queue.upsert(activity(.message, "alert", priority: 90))
        #expect(queue.selectedID?.source == "alert")
    }

    @Test("A less important arrival waits its turn")
    func lowerPriorityArrivalDoesNotSelect() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "alert", priority: 90))
        queue.upsert(activity(.nowPlaying, "music", priority: 30))
        #expect(queue.selectedID?.source == "alert")
    }

    @Test("A changed priority re-sorts, an unchanged one does not")
    func priorityChangeResorts() {
        var queue = ActivityQueue()
        queue.upsert(activity(.nowPlaying, "a", priority: 10))
        queue.upsert(activity(.device, "b", priority: 20))
        #expect(queue.activities.map(\.id.source) == ["b", "a"])

        queue.upsert(activity(.nowPlaying, "a", priority: 99))
        #expect(queue.activities.map(\.id.source) == ["a", "b"])
    }

    // MARK: - Selection invariants

    @Test("Selection is never a dangling id")
    func selectionNeverDangles() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "a"))
        queue.upsert(activity(.message, "b"))
        queue.retract(ActivityID(kind: .message, source: "a"))
        queue.retract(ActivityID(kind: .message, source: "b"))
        #expect(queue.selectedID == nil)
        #expect(queue.selected == nil)
    }

    @Test("Removing the selected activity lands on its neighbour")
    func removalMovesSelection() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "a", priority: 30))
        queue.upsert(activity(.message, "b", priority: 20))
        queue.upsert(activity(.message, "c", priority: 10))
        queue.select(ActivityID(kind: .message, source: "b"))

        queue.retract(ActivityID(kind: .message, source: "b"))
        #expect(queue.selectedID?.source == "c")
    }

    @Test("Removing the last activity falls back to the new last")
    func removalAtEndClamps() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "a", priority: 30))
        queue.upsert(activity(.message, "b", priority: 20))
        queue.select(ActivityID(kind: .message, source: "b"))

        queue.retract(ActivityID(kind: .message, source: "b"))
        #expect(queue.selectedID?.source == "a")
    }

    @Test("Selecting something absent is ignored rather than dangling")
    func selectUnknownIgnored() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "a"))
        queue.select(ActivityID(kind: .device, source: "ghost"))
        #expect(queue.selectedID?.source == "a")
    }

    // MARK: - Cycling

    @Test("Cycling wraps in both directions")
    func cyclingWraps() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "a", priority: 30))
        queue.upsert(activity(.message, "b", priority: 20))
        queue.upsert(activity(.message, "c", priority: 10))
        #expect(queue.selectedID?.source == "a")

        queue.cycleForward()
        #expect(queue.selectedID?.source == "b")
        queue.cycleForward()
        queue.cycleForward()
        #expect(queue.selectedID?.source == "a")

        queue.cycleBackward()
        #expect(queue.selectedID?.source == "c")
    }

    @Test("Cycling a single activity is a no-op")
    func cyclingSingleIsNoop() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "only"))
        queue.cycleForward()
        #expect(queue.selectedID?.source == "only")
    }

    @Test("The companion is the next in the cycle, and absent when alone")
    func companion() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "a", priority: 30))
        #expect(queue.companion == nil)

        queue.upsert(activity(.message, "b", priority: 20))
        #expect(queue.companion?.id.source == "b")

        queue.cycleForward()
        #expect(queue.companion?.id.source == "a", "companion wraps around")
    }

    // MARK: - Dismiss and restore

    @Test("Dismiss removes and restore brings it back, selected")
    func dismissAndRestore() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "a", priority: 30))
        queue.upsert(activity(.message, "b", priority: 20))

        queue.dismissSelected()
        #expect(queue.count == 1)
        #expect(queue.selectedID?.source == "b")
        #expect(queue.canRestore)

        queue.restoreLastDismissed()
        #expect(queue.count == 2)
        #expect(queue.selectedID?.source == "a")
        #expect(!queue.canRestore)
    }

    @Test("Restore pops the most recently dismissed first")
    func restoreIsLIFO() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "a", priority: 30))
        queue.upsert(activity(.message, "b", priority: 20))
        queue.dismiss(ActivityID(kind: .message, source: "a"))
        queue.dismiss(ActivityID(kind: .message, source: "b"))

        #expect(queue.restoreLastDismissed()?.id.source == "b")
        #expect(queue.restoreLastDismissed()?.id.source == "a")
    }

    @Test("The undo stack is bounded")
    func dismissedStackBounded() {
        var queue = ActivityQueue()
        for index in 0..<(ActivityQueue.dismissedLimit + 5) {
            let id = "a\(index)"
            queue.upsert(activity(.message, id))
            queue.dismiss(ActivityID(kind: .message, source: id))
        }
        #expect(queue.dismissed.count == ActivityQueue.dismissedLimit)
        // The oldest entries are the ones dropped.
        #expect(queue.dismissed.first?.id.source == "a5")
    }

    @Test("Retracting forgets a dismissal, so restore cannot resurrect it")
    func retractClearsDismissed() {
        var queue = ActivityQueue()
        queue.upsert(activity(.device, "buds"))
        queue.dismiss(ActivityID(kind: .device, source: "buds"))
        #expect(queue.canRestore)

        // The provider says the device is gone. Undo must not bring it back.
        queue.upsert(activity(.device, "buds"))
        queue.retract(ActivityID(kind: .device, source: "buds"))
        #expect(!queue.canRestore)
    }

    @Test("Restoring into an empty queue selects the restored activity")
    func restoreIntoEmpty() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "a"))
        queue.dismissSelected()
        #expect(queue.isEmpty)
        #expect(queue.selectedID == nil)

        queue.restoreLastDismissed()
        #expect(queue.selectedID?.source == "a")
    }

    // MARK: - Expiry

    @Test("Only activities past their lifetime expire")
    func expiry() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "short", createdAt: 100, expiresAfter: 5))
        queue.upsert(activity(.message, "long", createdAt: 100, expiresAfter: 60))
        queue.upsert(activity(.nowPlaying, "forever", createdAt: 100))

        #expect(queue.expiredIDs(at: 104).isEmpty)
        #expect(queue.expiredIDs(at: 106).map(\.source) == ["short"])

        queue.removeExpired(at: 106)
        #expect(queue.activities.map(\.id.source).sorted() == ["forever", "long"])
    }

    @Test("Retracting something absent changes nothing")
    func retractUnknownIsNoop() {
        var queue = ActivityQueue()
        queue.upsert(activity(.message, "a"))
        let before = queue
        queue.retract(ActivityID(kind: .device, source: "ghost"))
        #expect(queue == before)
    }

    // MARK: - Events versus status

    @Test("An expiring arrival is shown even under a higher-priority card")
    func expiringArrivalTakesTheScreen() {
        // The real case: the camera is in use (privacy, 75) and the user
        // switches keyboard layout (72). Ranked purely by priority the switch
        // is invisible, and an announcement nobody sees may as well not fire.
        var queue = ActivityQueue()
        queue.upsert(activity(.privacy, "system", priority: 75))
        queue.upsert(activity(.keyboard, "input", priority: 72, expiresAfter: 2.5))
        #expect(queue.selected?.id == ActivityID(kind: .keyboard, source: "input"))
    }

    @Test("It hands the screen straight back when it expires")
    func screenReturnsAfterExpiry() {
        var queue = ActivityQueue()
        queue.upsert(activity(.privacy, "system", priority: 75))
        queue.upsert(activity(.keyboard, "input", priority: 72, expiresAfter: 2.5))
        queue.retract(ActivityID(kind: .keyboard, source: "input"))
        #expect(queue.selected?.id == ActivityID(kind: .privacy, source: "system"))
    }

    @Test("A standing arrival still waits its turn")
    func standingArrivalDoesNotSteal() {
        // Only *events* jump the queue. A card with no expiry is status, and
        // status must never yank the user off what they are reading.
        var queue = ActivityQueue()
        queue.upsert(activity(.privacy, "system", priority: 75))
        queue.upsert(activity(.nowPlaying, "spotify", priority: 30))
        #expect(queue.selected?.id == ActivityID(kind: .privacy, source: "system"))
    }

    @Test("Updating an event in place does not re-take the screen")
    func updateDoesNotReselect() {
        // Updates go through the replace path, so a provider republishing does
        // not repeatedly steal selection from whatever the user cycled to.
        var queue = ActivityQueue()
        queue.upsert(activity(.device, "aa", priority: 60, expiresAfter: 14))
        queue.upsert(activity(.privacy, "system", priority: 75))
        queue.cycleForward()
        let chosen = queue.selected?.id
        queue.upsert(activity(.device, "aa", priority: 60, expiresAfter: 14, title: "updated"))
        #expect(queue.selected?.id == chosen)
    }

    @Test("Provider events go through the same paths as direct calls")
    func applyEvents() {
        var queue = ActivityQueue()
        queue.apply(.publish(activity(.message, "a")))
        #expect(queue.count == 1)
        queue.apply(.retract(ActivityID(kind: .message, source: "a")))
        #expect(queue.isEmpty)
    }
}

@Suite("What may rest in the ears")
struct RestsInEarsTests {

    private func timer(idle: Bool, running: Bool = false) -> Activity {
        Activity(
            id: ActivityID(kind: .timer, source: idle ? "idle" : "session"),
            createdAt: 0,
            payload: .timer(TimerPayload(
                label: "Timer", remaining: 1500, total: 1500,
                isRunning: running, isIdle: idle
            ))
        )
    }

    @Test("A timer nobody started never rests, and never announces itself")
    func idleTimerStaysOut() {
        // Cancelling a countdown republishes the launcher card. It used to
        // reach the ears reading the default work length — a countdown for a
        // timer that does not exist.
        let launcher = timer(idle: true)
        #expect(launcher.restsInEars == false)
        #expect(launcher.isWorthAnnouncing == false)
    }

    @Test("A running or paused timer does both")
    func liveTimerRests() {
        #expect(timer(idle: false, running: true).restsInEars)
        #expect(timer(idle: false, running: false).restsInEars, "paused still counts — it has a linger")
        #expect(timer(idle: false, running: true).isWorthAnnouncing)
    }

    @Test("Control surfaces do not rest; the shelf still announces a drop")
    func controlSurfaces() {
        let shelf = Activity(
            id: ActivityID(kind: .shelf, source: "shelf"), createdAt: 0,
            payload: .shelf(ShelfPayload(items: [ShelfItem(path: "/tmp/a", name: "a")]))
        )
        let levels = Activity(
            id: ActivityID(kind: .levels, source: "levels"), createdAt: 0,
            payload: .levels(LevelsPayload(volume: 0.5, brightness: 0.5))
        )
        #expect(shelf.restsInEars == false)
        #expect(shelf.isWorthAnnouncing, "a file landing on the shelf is news")
        #expect(levels.restsInEars == false)
    }

    @Test("A calendar rests only inside the hour")
    func calendarNeedsAnImminentEvent() {
        func event(_ startsIn: TimeInterval, hasEvent: Bool = true) -> Activity {
            Activity(
                id: ActivityID(kind: .event, source: "calendar"), createdAt: 0,
                payload: .event(EventPayload(title: "Standup", location: "", startsIn: startsIn, hasEvent: hasEvent))
            )
        }
        #expect(event(15 * 60).restsInEars)
        #expect(event(3 * 60 * 60).restsInEars == false, "a meeting this afternoon is reference, not news")
        #expect(event(0, hasEvent: false).restsInEars == false)
    }

    @Test("The last resort earns its place; the live facts do not have to")
    func precedence() {
        let launcher = timer(idle: true)
        let music = Activity(
            id: ActivityID(kind: .nowPlaying, source: "spotify"), createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(title: "Track", artist: "Artist", isPlaying: true))
        )
        // The bug: with the launcher selected and any reason to rest, the ears
        // drew a 25:00 countdown.
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: nil, nowPlaying: nil, selected: launcher
        ) == nil)
        // A real resident still wins, and is never second-guessed.
        #expect(CompactRest.resolve(
            farewell: nil, playingNowPlaying: music, runningTimer: nil,
            closeEvent: nil, nowPlaying: music, selected: launcher
        ) == music)
    }
}

@Suite("Hovering opens what is shown")
struct HoverOpensShownTests {

    private func music(playing: Bool) -> Activity {
        Activity(
            id: ActivityID(kind: .nowPlaying, source: "spotify"), createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(title: "Track", artist: "Artist", isPlaying: playing))
        )
    }

    private var calendar: Activity {
        Activity(
            id: ActivityID(kind: .event, source: "calendar"), createdAt: 0,
            payload: .event(EventPayload(title: "Standup", location: "", startsIn: 4 * 3600, hasEvent: true))
        )
    }

    @Test("Paused music in the ears opens the music card, not the selected one")
    func pausedMusicOpensMusic() {
        // The bug: only *playing* music was recognised, so hovering a paused
        // track opened whatever card happened to be selected — the calendar.
        let paused = music(playing: false)
        let shown = CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: nil, nowPlaying: paused, selected: calendar
        )
        #expect(shown?.id == paused.id)
    }

    @Test("An imminent meeting in the ears opens the calendar")
    func closeEventOpensCalendar() {
        let event = calendar
        let shown = CompactRest.resolve(
            farewell: nil, playingNowPlaying: nil, runningTimer: nil,
            closeEvent: event, nowPlaying: nil, selected: music(playing: false)
        )
        #expect(shown?.id == event.id)
    }

    @Test("Playing music still outranks everything below it")
    func playingWins() {
        let playing = music(playing: true)
        let shown = CompactRest.resolve(
            farewell: nil, playingNowPlaying: playing, runningTimer: nil,
            closeEvent: calendar, nowPlaying: playing, selected: calendar
        )
        #expect(shown?.id == playing.id)
    }
}

/// What announces itself when it arrives, and what does not.
@Suite("Worth announcing")
struct WorthAnnouncingTests {

    @Test("A levels card never announces itself")
    func levelsStaySilent() {
        // Its card arrives the first time a level is touched. That arrival is
        // a side effect of the user pressing a key, and the readout they
        // pressed it for is already on screen — announcing it took the whole
        // compact view for that first press, while every press afterwards
        // showed as a companion beside the music.
        let levels = Activity(
            id: ActivityID(kind: .levels, source: "levels"),
            createdAt: 0,
            payload: .levels(LevelsPayload(volume: 0.4, brightness: 0.6))
        )
        #expect(!levels.isWorthAnnouncing)
    }

    @Test("The things that are news still are")
    func othersAnnounce() {
        let weather = Activity(
            id: ActivityID(kind: .weather, source: "weather"),
            createdAt: 0,
            payload: .weather(WeatherPayload(temperatureCelsius: 18))
        )
        #expect(weather.isWorthAnnouncing)

        let playing = Activity(
            id: ActivityID(kind: .nowPlaying, source: "com.spotify.client"),
            createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(title: "T", artist: "A"))
        )
        #expect(playing.isWorthAnnouncing)
    }

    @Test("A levels card is not a resident either")
    func levelsDoNotRest() {
        // The two rules agree: it is a control surface at both ends.
        let levels = Activity(
            id: ActivityID(kind: .levels, source: "levels"),
            createdAt: 0,
            payload: .levels(LevelsPayload(volume: 0.4, brightness: 0.6))
        )
        #expect(!levels.restsInEars)
    }
}

