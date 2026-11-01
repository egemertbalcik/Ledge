import Foundation
import LedgeSystem
import Testing

@testable import LedgeCore
@testable import LedgeProviders

@Suite("Keyboard layout")
@MainActor
struct KeyboardLayoutTests {

    private func makeProvider(
        _ source: StubKeyboardLayoutSource
    ) -> KeyboardLayoutProvider {
        KeyboardLayoutProvider(source: source, now: { 1000 })
    }

    /// Drains the stream after driving it, the same shape `BatteryTests` uses.
    private func collect(
        _ provider: KeyboardLayoutProvider,
        while body: () -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        body()
        provider.stop()

        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("The layout in use at launch is not announced")
    func noAnnounceOnStart() async {
        // Logging in is not a switch. Announcing the layout you were already
        // using would put a card on screen at every launch.
        let source = StubKeyboardLayoutSource(
            value: KeyboardLayoutSnapshot(name: "Turkish", code: "TR")
        )
        let provider = makeProvider(source)
        let events = await collect(provider) {}
        #expect(events.isEmpty)
    }

    @Test("Switching layouts publishes the new one")
    func announcesSwitch() async {
        let source = StubKeyboardLayoutSource(
            value: KeyboardLayoutSnapshot(name: "Turkish", code: "TR")
        )
        let provider = makeProvider(source)
        let events = await collect(provider) {
            source.set(KeyboardLayoutSnapshot(name: "ABC", code: "EN"))
        }

        #expect(events.count == 1)
        guard case .publish(let activity) = events.first else {
            Issue.record("expected a publish, got \(String(describing: events.first))")
            return
        }
        #expect(activity.id == ActivityID(kind: .keyboard, source: "input"))
        guard case .keyboard(let payload) = activity.payload else {
            Issue.record("expected a keyboard payload")
            return
        }
        #expect(payload.name == "ABC")
        #expect(payload.code == "EN")
        // Short-lived on purpose: it is a notification, not a status card.
        #expect(activity.expiresAfter == KeyboardLayoutProvider.lifetime)
    }

    @Test("Re-selecting the same layout publishes nothing")
    func ignoresNonSwitch() async {
        // The input-source notification also fires when the *list* of sources
        // changes, leaving the selection alone.
        let source = StubKeyboardLayoutSource(
            value: KeyboardLayoutSnapshot(name: "Turkish", code: "TR")
        )
        let provider = makeProvider(source)
        let events = await collect(provider) {
            source.set(KeyboardLayoutSnapshot(name: "Turkish", code: "TR"))
        }
        #expect(events.isEmpty)
    }

    @Test("Each distinct switch gets its own card")
    func announcesEverySwitch() async {
        let source = StubKeyboardLayoutSource(
            value: KeyboardLayoutSnapshot(name: "Turkish", code: "TR")
        )
        let provider = makeProvider(source)
        let events = await collect(provider) {
            source.set(KeyboardLayoutSnapshot(name: "ABC", code: "EN"))
            source.set(KeyboardLayoutSnapshot(name: "Turkish", code: "TR"))
        }
        #expect(events.count == 2)
    }

    @Test("A launch that found no layout still announces the first switch")
    func aBaselineOfNothingIsStillABaseline() async throws {
        // TIS not ready yet at login, or a source with no name: the baseline
        // reads nothing. Taken for "no baseline yet", the first real switch
        // became the baseline and was never shown.
        let source = StubKeyboardLayoutSource(value: nil)
        try #require(source.current() == nil)
        let provider = makeProvider(source)
        let events = await collect(provider) {
            source.set(KeyboardLayoutSnapshot(name: "ABC", code: "EN"))
            source.set(KeyboardLayoutSnapshot(name: "Turkish Q", code: "TR"))
        }
        // Two switches, two cards: the second proves the stub was delivering,
        // so the first is not missing for want of a notification.
        let names = events.compactMap { event -> String? in
            guard case .publish(let activity) = event, case .keyboard(let payload) = activity.payload
            else { return nil }
            return payload.name
        }
        #expect(names == ["ABC", "Turkish Q"])
    }

    @Test("A code that moves under the same layout is not a switch")
    func aCodeChangeIsNotASwitch() async {
        // Enabling Turkish F turns Turkish Q's badge from TR into TRQ, and the
        // list change can fire the selection notification with the selection
        // where it was.
        let source = StubKeyboardLayoutSource(
            value: KeyboardLayoutSnapshot(name: "Turkish Q", code: "TR")
        )
        let provider = makeProvider(source)
        let events = await collect(provider) {
            source.set(KeyboardLayoutSnapshot(name: "Turkish Q", code: "TRQ"))
            source.set(KeyboardLayoutSnapshot(name: "Turkish F", code: "TRF"))
        }
        // Only the real switch — which also proves the stub was delivering.
        #expect(events.count == 1)
        guard case .publish(let activity) = events.first,
              case .keyboard(let payload) = activity.payload else {
            Issue.record("expected a keyboard publish, got \(String(describing: events.first))")
            return
        }
        #expect(payload.name == "Turkish F")
        #expect(payload.code == "TRF")
    }

    @Test("Stopping resets every piece of state")
    func stopResets() async {
        let source = StubKeyboardLayoutSource(
            value: KeyboardLayoutSnapshot(name: "Turkish", code: "TR")
        )
        let provider = makeProvider(source)
        _ = provider.start()
        provider.stop()

        // After a restart the first observation is a baseline again, so a
        // relaunch cannot announce a switch that never happened.
        source.set(KeyboardLayoutSnapshot(name: "ABC", code: "EN"))
        let events = await collect(provider) {}
        #expect(events.isEmpty)
    }
}

/// Caps Lock, then a layout switch inside the peek it raised.
///
/// The reviewer's case, with the cards the real providers publish and their
/// real lifetimes: the switch queued behind the Caps Lock peek, its card
/// expired a second later, and the drain dropped it because it was gone. The
/// coordinator itself cannot be built in a test, so this drives the two
/// rules it asks — whether the switch may take the stage, and what a queued
/// one shows when its turn comes.
@Suite("A keyboard switch behind another peek")
@MainActor
struct KeyboardSwitchBehindPeekTests {

    private final class StubCapsLock: CapsLockWatching {
        private var onChange: (@MainActor (Bool) -> Void)?
        func startWatching(_ onChange: @escaping @MainActor (Bool) -> Void) { self.onChange = onChange }
        func stopWatching() { onChange = nil }
        func toggle(_ isOn: Bool) { onChange?(isOn) }
    }

    /// The one card a provider published while `body` ran.
    private func published(
        by provider: some ActivityProvider, while body: () -> Void
    ) async throws -> Activity {
        let stream = provider.start()
        body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        let cards = events.compactMap { event -> Activity? in
            guard case .publish(let activity) = event else { return nil }
            return activity
        }
        try #require(events.count == 1 && cards.count == 1, "expected one publish, got \(events)")
        return cards[0]
    }

    private func capsLockToggled(at time: TimeInterval) async throws -> Activity {
        let caps = StubCapsLock()
        return try await published(by: CapsLockProvider(source: caps, now: { time })) {
            caps.toggle(true)
        }
    }

    private func layoutSwitched(at time: TimeInterval) async throws -> Activity {
        let layout = StubKeyboardLayoutSource(value: KeyboardLayoutSnapshot(name: "Turkish Q", code: "TR"))
        return try await published(by: KeyboardLayoutProvider(source: layout, now: { time })) {
            layout.set(KeyboardLayoutSnapshot(name: "ABC", code: "EN"))
        }
    }

    @Test("The switch takes the stage from the Caps Lock peek at once")
    func theSwitchShowsAtOnce() async throws {
        let caps = try await capsLockToggled(at: 0)
        let input = try await layoutSwitched(at: 0.5)
        // Two different cards — the same card restarting itself always worked.
        try #require(caps.id != input.id)
        // Inside the peek Caps Lock raised.
        try #require(input.createdAt - caps.createdAt < Prefs.peekDuration.defaultValue)
        #expect(PeekTurn.takesOver(input, from: caps, standingUp: false))
    }

    @Test("Queued instead, the switch is still shown when the stage clears")
    func aQueuedSwitchIsShown() async throws {
        let caps = try await capsLockToggled(at: 0)
        let input = try await layoutSwitched(at: 0.5)
        var queue = ActivityQueue()
        queue.upsert(caps)
        queue.upsert(input)
        var pending: [PendingPeek] = []
        PendingPeek.enqueue(PendingPeek(input, at: input.createdAt, byUser: false), into: &pending, limit: 3)
        let entry = try #require(pending.first)

        // The Caps Lock peek retires and the stage clears. By then the
        // switch's own card has expired — the condition it was dropped for.
        let cleared = caps.createdAt + Prefs.peekDuration.defaultValue
        queue.removeExpired(at: cleared)
        let live = queue.activities.first { $0.id == entry.id }
        try #require(live == nil, "the switch's card outlived the peek; the fixture no longer shows the bug")

        let shown = try #require(entry.card(live: live, publisherRunning: true))
        guard case .keyboard(let payload) = shown.payload else {
            Issue.record("expected the keyboard card, got \(shown.payload)")
            return
        }
        #expect(payload.code == "EN")
    }
}

/// A queued keyboard copy after the indicator is switched off.
///
/// The copy does not need its live card, which is the point of it — and also
/// why switching the indicator off, which takes the provider's cards away,
/// did not stop it: it could flash once more within its eight seconds.
@Suite("A queued keyboard switch after the indicator is turned off", .timeLimit(.minutes(10)))
@MainActor
struct KeyboardCopyAfterRemovalTests {

    /// Until something holds, for as long as that takes: the hub consumes the
    /// provider's stream on its own task.
    private func until(_ condition: () -> Bool) async throws {
        while !condition() { try await Task.sleep(for: .milliseconds(1)) }
    }

    @Test("Expired, the copy still plays; with its provider removed, it does not")
    func removalDropsTheCopy() async throws {
        let hub = ProviderHub()
        let layout = StubKeyboardLayoutSource(value: KeyboardLayoutSnapshot(name: "Turkish Q", code: "TR"))
        let provider = KeyboardLayoutProvider(source: layout, now: { 0 })
        hub.add(provider)
        hub.start()
        layout.set(KeyboardLayoutSnapshot(name: "ABC", code: "EN"))
        let id = ActivityID(kind: .keyboard, source: "input")
        try await until { hub.queue.activities.contains { $0.id == id } }
        let card = try #require(hub.queue.activities.first { $0.id == id })
        let entry = PendingPeek(card, at: 0, byUser: false)

        // Its card expires, the way the coordinator's timer retracts it.
        hub.mutate { $0.removeExpired(at: KeyboardLayoutProvider.lifetime + 1) }
        try #require(!hub.queue.activities.contains { $0.id == id })
        // Expiry leaves the card its provider's, so the copy still plays.
        #expect(hub.isPublishing(id))
        #expect(entry.card(live: nil, publisherRunning: hub.isPublishing(id)) == card)

        // Switched off in Settings: the hub removes the provider.
        hub.remove(provider.identifier)
        #expect(!hub.isPublishing(id))
        #expect(entry.card(live: nil, publisherRunning: hub.isPublishing(id)) == nil)
    }

    @Test("A hub that has stopped stands behind nothing")
    func aStoppedHubPublishesNothing() async throws {
        let hub = ProviderHub()
        let layout = StubKeyboardLayoutSource(value: KeyboardLayoutSnapshot(name: "Turkish Q", code: "TR"))
        hub.add(KeyboardLayoutProvider(source: layout, now: { 0 }))
        hub.start()
        layout.set(KeyboardLayoutSnapshot(name: "ABC", code: "EN"))
        let id = ActivityID(kind: .keyboard, source: "input")
        try await until { hub.queue.activities.contains { $0.id == id } }
        try #require(hub.isPublishing(id))
        // Stopped but still registered: nothing is running behind the card.
        hub.stop()
        try #require(hub.registeredIdentifiers.contains("keyboard"))
        #expect(!hub.isPublishing(id))
    }
}
