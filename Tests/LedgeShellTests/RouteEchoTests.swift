import Foundation
import Testing

@testable import LedgeShell

/// Sound moving to the earbuds that have just said hello is the same news
/// twice. Only that: a different device, or the same one later, is news.
@Suite("A route change that echoes a connection")
struct RouteEchoTests {

    @Test("The same device inside the window is an echo")
    func sameDeviceIsEcho() {
        #expect(LedgeCoordinator.routeEchoes(route: "Ali's AirPods Pro", connected: "Ali's AirPods Pro", elapsed: 1))
        #expect(LedgeCoordinator.routeEchoes(route: "AirPods Pro", connected: "Ali's AirPods Pro", elapsed: 2))
    }

    @Test("Another device, or the same one too late, is news")
    func otherwiseNews() {
        #expect(!LedgeCoordinator.routeEchoes(route: "MacBook Pro Speakers", connected: "Ali's AirPods Pro", elapsed: 1))
        #expect(!LedgeCoordinator.routeEchoes(
            route: "AirPods Pro", connected: "AirPods Pro", elapsed: LedgeCoordinator.routeEchoWindow + 0.1))
        #expect(!LedgeCoordinator.routeEchoes(route: "AirPods Pro", connected: "AirPods Pro", elapsed: -1))
        #expect(!LedgeCoordinator.routeEchoes(route: "", connected: "AirPods Pro", elapsed: 1))
    }
}
