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
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("A route change publishes a card that expires on its own")
    func routeChangeAnnounces() async {
        let route = FakeRoute()
        let provider = AudioRouteProvider(source: route, now: { 1_000 })
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
        // No ring: a route change knows where sound goes, not how much charge
        // the thing has left.
        #expect(payload.batteryLevels.isEmpty)
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
        let provider = AudioRouteProvider(source: route)
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
