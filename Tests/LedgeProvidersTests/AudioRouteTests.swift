import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

@MainActor
private final class FakeRoute: AudioRouteWatching {
    private var onChange: (@MainActor (String) -> Void)?
    private(set) var isWatching = false

    func startWatching(_ onChange: @escaping @MainActor (_ name: String) -> Void) {
        self.onChange = onChange
        isWatching = true
    }

    func stopWatching() {
        onChange = nil
        isWatching = false
    }

    func moveTo(_ name: String) { onChange?(name) }
}

@Suite("Saying where sound just went")
@MainActor
struct AudioRouteProviderTests {

    private func collect(
        _ provider: AudioRouteProvider,
        while body: (FakeRoute) -> Void,
        route: FakeRoute
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        body(route)
        // The card goes out after the Bluetooth read, not inside the callback.
        try? await Task.sleep(for: .milliseconds(80))
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("A route change publishes a card that expires on its own")
    func routeChangeAnnounces() async {
        let route = FakeRoute()
        let provider = AudioRouteProvider(source: route, now: { 1_000 }, bluetoothDevice: { _ in nil })
        let events = await collect(provider, while: { $0.moveTo("AirPods Pro") }, route: route)

        let published = events.compactMap { event -> Activity? in
            if case .publish(let activity) = event { return activity } else { return nil }
        }
        #expect(published.count == 1)
        #expect(published.first?.expiresAfter == AudioRouteProvider.lifetime)
        guard case .device(let payload)? = published.first?.payload else {
            Issue.record("expected a device card")
            return
        }
        #expect(payload.name == "AirPods Pro")
        #expect(payload.symbolName == "airpods.pro")
        // No Bluetooth device of that name: nothing to lend a ring.
        #expect(payload.batteryLevels.isEmpty)
    }

    private func published(_ events: [ProviderEvent]) -> [Activity] {
        events.compactMap { event -> Activity? in
            if case .publish(let activity) = event { return activity } else { return nil }
        }
    }

    private func earbuds(_ name: String, levels: [String: Double]) -> BluetoothDeviceSnapshot {
        BluetoothDeviceSnapshot(
            name: name, address: "80:AF:19:40:F9:B6", isConnected: true,
            batteryLevels: levels, symbolName: "airpods.pro", isApple: true
        )
    }

    @Test("Earbuds that stayed connected lend their battery, in one card")
    func stayedConnectedCarriesBattery() async {
        let route = FakeRoute()
        let buds = earbuds("only and one", levels: ["Left": 0.9, "Right": 0.8, "Case": 0.5])
        let provider = AudioRouteProvider(source: route, now: { 5_000 }, bluetoothDevice: { _ in buds })
        let cards = published(await collect(provider, while: { $0.moveTo("Only And One") }, route: route))
        #expect(cards.count == 1)
        guard case .device(let payload)? = cards.first?.payload else {
            Issue.record("expected a device card")
            return
        }
        #expect(payload.batteryLevels == ["Left": 0.9, "Right": 0.8, "Case": 0.5])
        #expect(payload.symbolName == "airpods.pro")
    }

    @Test("Earbuds still connecting leave the news to their Bluetooth hello")
    func connectingWithoutLevelsStaysQuiet() async {
        let route = FakeRoute()
        let buds = earbuds("only and one", levels: [:])
        let provider = AudioRouteProvider(source: route, now: { 6_000 }, bluetoothDevice: { _ in buds })
        let cards = published(await collect(provider, while: { $0.moveTo("only and one") }, route: route))
        #expect(cards.isEmpty)
    }

    @Test("A device that connected a moment ago is not told twice")
    func recentConnectionStaysQuiet() async {
        RecentConnections.noteConnected("Fresh Buds", at: 7_000)
        let route = FakeRoute()
        let buds = earbuds("Fresh Buds", levels: ["Left": 1, "Right": 1])
        let provider = AudioRouteProvider(source: route, now: { 7_001 }, bluetoothDevice: { _ in buds })
        let cards = published(await collect(provider, while: { $0.moveTo("Fresh Buds") }, route: route))
        #expect(cards.isEmpty)
    }

    /// It shares the device *kind* with the Bluetooth cards, so it needs its
    /// own source — otherwise a route change would quietly replace the card
    /// saying a device had just connected.
    @Test("It does not collide with the Bluetooth device cards")
    func ownsItsOwnActivity() {
        #expect(AudioRouteProvider.activityID.source == "audioroute")
        #expect(AudioRouteProvider.activityID.kind == .device)
    }

    @Test("Stopping the provider stops the watching")
    func stopReleasesTheListener() async {
        let route = FakeRoute()
        let provider = AudioRouteProvider(source: route, bluetoothDevice: { _ in nil })
        _ = await collect(provider, while: { _ in }, route: route)
        #expect(route.isWatching == false)
    }

    @Test("Apple's own gear keeps its tinted glyph")
    func appleGearIsTinted() {
        #expect(AudioRouteProvider.readsAsApple("AirPods Pro"))
        #expect(AudioRouteProvider.readsAsApple("MacBook Pro Speakers"))
        #expect(AudioRouteProvider.readsAsApple("Scarlett 2i2") == false)
    }

    @Test("The glyph follows the device's name, since macOS gives no icon")
    func symbolsFollowNames() {
        #expect(AudioDeviceSymbol.forName("AirPods Max") == "airpodsmax")
        #expect(AudioDeviceSymbol.forName("MacBook Pro Speakers") == "laptopcomputer")
        #expect(AudioDeviceSymbol.forName("Studio Display") == "display")
        #expect(AudioDeviceSymbol.forName("Some Interface") == "hifispeaker.fill")
    }
}
