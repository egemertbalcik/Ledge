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
