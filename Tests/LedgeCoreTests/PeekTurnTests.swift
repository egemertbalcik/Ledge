import Foundation
import Testing

@testable import LedgeCore

/// Who gets the stage when a keyboard fact arrives while another peek has it.
///
/// The reviewer's finding: a layout switch made while anything else was on
/// stage was never shown. It queued, its card expired a second later, and the
/// drain skipped any entry whose card had gone — so Caps Lock and then a
/// switch inside two seconds showed only Caps Lock.
@Suite("Peek turn")
struct PeekTurnTests {

    private func card(
        _ kind: ActivityKind, _ source: String, priority: Int? = nil,
        createdAt: TimeInterval = 0, expiresAfter: TimeInterval? = nil
    ) -> Activity {
        Activity(
            id: ActivityID(kind: kind, source: source), priority: priority,
            createdAt: createdAt, expiresAfter: expiresAfter,
            payload: .message(MessagePayload(title: source))
        )
    }

    private func layoutSwitch(_ code: String, at time: TimeInterval = 0) -> Activity {
        Activity(
            id: ActivityID(kind: .keyboard, source: "input"), createdAt: time, expiresAfter: 1,
            payload: .keyboard(KeyboardLayoutPayload(name: code, code: code))
        )
    }

    private var capsLock: Activity {
        Activity(
            id: ActivityID(kind: .keyboard, source: "capslock"), createdAt: 0, expiresAfter: 1.6,
            payload: .keyboard(KeyboardLayoutPayload(name: "Caps Lock On", code: "⇪"))
        )
    }

    // MARK: - Cutting in

    @Test("A layout switch takes over a Caps Lock peek, and any whisper below it")
    func keyboardTakesOverWhispers() throws {
        let input = layoutSwitch("EN")
        // Not the same card restarting itself — that path always worked.
        try #require(input.id != capsLock.id)
        #expect(PeekTurn.takesOver(input, from: capsLock, standingUp: false))
        #expect(PeekTurn.takesOver(input, from: card(.nowPlaying, "music"), standingUp: false))
        #expect(PeekTurn.takesOver(input, from: card(.device, "airpods"), standingUp: false))
        // Caps Lock over a layout switch, the same way round.
        #expect(PeekTurn.takesOver(capsLock, from: input, standingUp: false))
    }

    @Test("It does not cut off a notch standing up for news, or a card that outranks it")
    func keyboardWaitsForMoreImportant() throws {
        let input = layoutSwitch("EN")
        let finished = card(.timer, "session", priority: ActivityKind.timer.defaultPriority + 25)
        try #require(finished.priority <= input.priority, "fixture must rank below, so only standing up decides")
        #expect(!PeekTurn.takesOver(input, from: finished, standingUp: true))
        let recording = card(.privacy, "camera")
        try #require(recording.priority > input.priority)
        #expect(!PeekTurn.takesOver(input, from: recording, standingUp: false))
        // Nothing known on screen: nothing to weigh it against.
        #expect(!PeekTurn.takesOver(input, from: nil, standingUp: false))
    }

    @Test("Only keyboard facts cut in; everything else waits its turn")
    func othersStillQueue() throws {
        let device = card(.device, "airpods")
        // It outranks the music, so rank alone would have let it in.
        try #require(device.priority > ActivityKind.nowPlaying.defaultPriority)
        #expect(!PeekTurn.takesOver(device, from: card(.nowPlaying, "music"), standingUp: false))
        #expect(!PeekTurn.takesOver(card(.privacy, "camera"), from: capsLock, standingUp: false))
    }

    // MARK: - Waiting

    @Test("A queued layout switch is still shown when its card has expired")
    func queuedSwitchOutlivesItsCard() throws {
        // Behind something it may not cut off — the recording indicator's
        // peek — a switch half a second in.
        var queue = ActivityQueue()
        let input = layoutSwitch("TRF", at: 0.5)
        queue.upsert(input)
        var pending: [PendingPeek] = []
        PendingPeek.enqueue(PendingPeek(input, at: 0.5, byUser: false), into: &pending, limit: 3)
        let entry = try #require(pending.first)

        // The stage clears at the end of the two-second peek, by which time
        // the card is gone: the condition the old drain dropped it for.
        queue.removeExpired(at: 2.0)
        let live = queue.activities.first { $0.id == entry.id }
        try #require(live == nil)
        #expect(entry.card(live: live, publisherRunning: true) == input)
    }

    @Test("A copy does not play once its provider is off")
    func noCopyAfterTheSettingIsOff() throws {
        let input = layoutSwitch("TRF")
        let entry = PendingPeek(input, at: 0, byUser: false)
        try #require(entry.copy == input)
        // Switched off in Settings: the provider is gone, and with it the
        // card, so nothing is live either.
        #expect(entry.card(live: nil, publisherRunning: false) == nil)
        // A live card is its provider's by definition, and still plays.
        #expect(entry.card(live: input, publisherRunning: false) == input)
    }

    @Test("Anything else whose card has gone is still dropped")
    func goneMeansGoneForOthers() throws {
        var queue = ActivityQueue()
        let device = card(.device, "airpods", expiresAfter: 1)
        queue.upsert(device)
        let entry = PendingPeek(device, at: 0, byUser: false)
        queue.removeExpired(at: 2.0)
        let live = queue.activities.first { $0.id == entry.id }
        try #require(live == nil)
        #expect(entry.card(live: live, publisherRunning: true) == nil)
        #expect(entry.copy == nil)
    }

    @Test("A live card wins over the copy")
    func liveCardFirst() {
        let entry = PendingPeek(layoutSwitch("EN"), at: 0, byUser: false)
        let fresher = layoutSwitch("TRQ", at: 0.2)
        #expect(entry.card(live: fresher, publisherRunning: true) == fresher)
    }

    @Test("Two switches behind one peek replay only the newer layout")
    func newerCopyReplacesOlder() throws {
        var pending: [PendingPeek] = []
        let music = card(.nowPlaying, "music")
        PendingPeek.enqueue(PendingPeek(music, at: 0, byUser: false), into: &pending, limit: 3)
        PendingPeek.enqueue(PendingPeek(layoutSwitch("EN", at: 0.2), at: 0.2, byUser: false), into: &pending, limit: 3)
        try #require(pending.count == 2)
        PendingPeek.enqueue(PendingPeek(layoutSwitch("TR", at: 0.4), at: 0.4, byUser: false), into: &pending, limit: 3)
        #expect(pending.count == 2)
        let keyboard = try #require(pending.first { $0.id.kind == .keyboard })
        #expect(keyboard.copy?.payload == .keyboard(KeyboardLayoutPayload(name: "TR", code: "TR")))
        #expect(keyboard.at == 0.4)
    }

    @Test("Keyboard facts wait at the front; the rest keep their order")
    func keyboardWaitsAtTheFront() {
        var pending: [PendingPeek] = []
        let music = card(.nowPlaying, "music")
        let device = card(.device, "airpods")
        PendingPeek.enqueue(PendingPeek(music, at: 0, byUser: false), into: &pending, limit: 3)
        PendingPeek.enqueue(PendingPeek(device, at: 0.1, byUser: false), into: &pending, limit: 3)
        PendingPeek.enqueue(PendingPeek(layoutSwitch("EN", at: 0.2), at: 0.2, byUser: false), into: &pending, limit: 3)
        #expect(pending.map(\.id) == [ActivityID(kind: .keyboard, source: "input"), music.id, device.id])
    }

    @Test("A full queue takes nothing new, but an update to a waiting switch still lands")
    func limitHolds() throws {
        var pending: [PendingPeek] = []
        PendingPeek.enqueue(PendingPeek(layoutSwitch("EN"), at: 0, byUser: false), into: &pending, limit: 2)
        PendingPeek.enqueue(PendingPeek(card(.device, "a"), at: 0, byUser: false), into: &pending, limit: 2)
        try #require(pending.count == 2)
        PendingPeek.enqueue(PendingPeek(card(.device, "b"), at: 0, byUser: false), into: &pending, limit: 2)
        #expect(pending.count == 2)
        PendingPeek.enqueue(PendingPeek(layoutSwitch("TR", at: 1), at: 1, byUser: false), into: &pending, limit: 2)
        #expect(pending.first?.copy?.payload == .keyboard(KeyboardLayoutPayload(name: "TR", code: "TR")))
    }

    // MARK: - What a cut-in cuts short

    private func resume(
        _ onScreen: Activity?, by arrival: Activity, live: Bool = true, at time: TimeInterval = 1,
        into queue: inout [PendingPeek], limit: Int = 3
    ) {
        PendingPeek.resume(onScreen, cutShortBy: arrival, isLive: live, at: time, into: &queue, limit: limit)
    }

    @Test("The whisper a keyboard fact cuts short plays after it")
    func theCutShortCardComesBack() throws {
        let airpods = card(.device, "airpods")
        let input = layoutSwitch("EN")
        // The case under test is the cut-in, not a queue.
        try #require(PeekTurn.takesOver(input, from: airpods, standingUp: false))
        var pending: [PendingPeek] = []
        resume(airpods, by: input, at: 4.5, into: &pending)
        let entry = try #require(pending.first)
        #expect(pending.count == 1)
        #expect(entry.id == airpods.id)
        #expect(entry.copy == nil, "a live entry: it needs its card at its turn like any other")
        #expect(entry.at == 4.5, "its lifetime runs from losing the stage")
    }

    @Test("It goes back ahead of the other waiting cards, behind the keyboard facts")
    func itKeepsItsPlace() {
        let music = card(.nowPlaying, "music")
        let caps = capsLock
        var pending: [PendingPeek] = []
        PendingPeek.enqueue(PendingPeek(music, at: 0, byUser: false), into: &pending, limit: 3)
        PendingPeek.enqueue(PendingPeek(caps, at: 0.1, byUser: false), into: &pending, limit: 3)
        let message = card(.message, "message")
        resume(message, by: layoutSwitch("EN"), into: &pending)
        #expect(pending.map(\.id) == [caps.id, message.id, music.id])
    }

    @Test("Nothing comes back when there is nothing to bring back")
    func nothingToResume() {
        let input = layoutSwitch("EN")
        let airpods = card(.device, "airpods")
        var pending: [PendingPeek] = []
        // The same card restarting itself — a keyboard one, and one that is
        // not: a second Focus flip restarts its own peek through the same
        // branch, and must not queue a replay of itself.
        resume(input, by: layoutSwitch("TR"), into: &pending)
        resume(card(.focus, "focus"), by: card(.focus, "focus", createdAt: 1), into: &pending)
        // Its card already gone from the activity queue.
        resume(airpods, by: input, live: false, into: &pending)
        // Nothing known on screen.
        resume(nil, by: input, into: &pending)
        #expect(pending.isEmpty)
    }

    @Test("Keyboard facts do not bounce each other back")
    func noKeyboardPingPong() throws {
        // Caps Lock over a layout switch, then a switch over Caps Lock: each
        // cut-in is legitimate, and neither puts the other back.
        let input = layoutSwitch("EN")
        try #require(PeekTurn.takesOver(capsLock, from: input, standingUp: false))
        var pending: [PendingPeek] = []
        resume(input, by: capsLock, into: &pending)
        resume(capsLock, by: layoutSwitch("TR", at: 0.5), into: &pending)
        #expect(pending.isEmpty)
    }

    @Test("Already waiting, or no room: it is not queued twice, and the unseen keep their places")
    func capAndDuplicates() throws {
        let airpods = card(.device, "airpods")
        let input = layoutSwitch("EN")
        var pending: [PendingPeek] = []
        PendingPeek.enqueue(PendingPeek(airpods, at: 0, byUser: false), into: &pending, limit: 3)
        resume(airpods, by: input, into: &pending)
        #expect(pending.count == 1)

        var full: [PendingPeek] = []
        for source in ["a", "b", "c"] {
            PendingPeek.enqueue(PendingPeek(card(.device, source), at: 0, byUser: false), into: &full, limit: 3)
        }
        try #require(full.count == 3)
        resume(card(.message, "message"), by: input, into: &full)
        #expect(full.map(\.id.source) == ["a", "b", "c"])
    }

    @Test("A run of switches over one whisper puts it back once, and it plays when they stop")
    func noLoopAcrossSwitches() throws {
        // AirPods on screen. A switch cuts in; a second switch restarts the
        // keyboard flash in place (same card); then Caps Lock cuts in over
        // the layout. The AirPods card waits once, and nothing else is added.
        let airpods = card(.device, "airpods")
        var onScreen = airpods
        var pending: [PendingPeek] = []
        for (time, arrival) in [(0.2, layoutSwitch("EN", at: 0.2)), (0.6, layoutSwitch("TR", at: 0.6)),
                                (1.0, capsLock)] {
            let sameCard = onScreen.id == arrival.id
            try #require(sameCard || PeekTurn.takesOver(arrival, from: onScreen, standingUp: false))
            resume(onScreen, by: arrival, at: time, into: &pending)
            onScreen = arrival
        }
        #expect(pending.map(\.id) == [airpods.id])
        #expect(pending.first?.at == 0.2)
    }
}
