import Foundation
import LedgeCore
import LedgeProviders
import Testing

@testable import LedgeShell

@Suite("Sound moving is said in the banner, not the ear")
@MainActor
struct RouteBannerTests {

    private func route(_ name: String) -> Activity {
        Activity(
            id: AudioRouteProvider.activityID,
            createdAt: 0,
            payload: .device(DevicePayload(name: name, symbolName: "laptopcomputer", isApple: true))
        )
    }

    @Test("The banner carries the full name and says what it is")
    func fullNameWithCaption() {
        let banner = LedgeCoordinator.routeBannerPayload(for: route("MacBook Pro Speakers"))
        #expect(banner?.name == "MacBook Pro Speakers")
        #expect(banner?.statusText == LedgeCoordinator.routeBannerCaption)
        #expect(banner?.batteryLevels.isEmpty == true)
        #expect(banner?.symbolName == "laptopcomputer")
    }

    /// "Connected" would be wrong, and it would also arm the echo check that
    /// swallows the next route change to a device of the same name.
    @Test("A route change claims no connection")
    func noConnectionState() {
        let banner = LedgeCoordinator.routeBannerPayload(for: route("MacBook Pro Speakers"))
        #expect(banner?.isConnected == nil)
    }

    @Test("A nameless route puts nothing below the island")
    func namelessRoute() {
        #expect(LedgeCoordinator.routeBannerPayload(for: route("")) == nil)
    }

    /// The connection banner's own filter would have read the route card —
    /// connected by default, no status word now — as a device arriving.
    @Test("The route card is not mistaken for a connection")
    func routeIsNotAConnection() {
        let card = route("MacBook Pro Speakers")
        let banner = LedgeCoordinator.routeBannerPayload(for: card)
        #expect(banner != LedgeCoordinator.bannerPayload(for: card))
    }
}
