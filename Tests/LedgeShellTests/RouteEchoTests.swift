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

    /// macOS writes the apostrophe in "Someone's AirPods" curly in one place
    /// and straight in another.
    @Test("A curly apostrophe does not make a different device")
    func curlyApostrophe() {
        #expect(LedgeCoordinator.namesSameDevice("Ali\u{2019}s AirPods", "Ali's AirPods"))
        #expect(LedgeCoordinator.routeEchoes(route: "Ali\u{2019}s AirPods", connected: "Ali's AirPods", elapsed: 5))
    }
}

/// The hello arms one echo. The first route heard after it uses that up,
/// whichever device it names.
@Suite("The one route a connection may swallow")
struct RouteEchoTokenTests {

    @Test("The route to the device that just said hello is swallowed, once")
    func swallowsOnce() {
        var echo = RouteEcho()
        echo.arm("AirPods Pro", at: 100)
        let first = echo.swallows(route: "AirPods Pro", at: 101)
        let second = echo.swallows(route: "AirPods Pro", at: 102)
        #expect(first)
        #expect(!second, "a second route to it is somebody's choice")
    }

    /// Connected A, sound to B, then back to A a few seconds later. The
    /// return was swallowed as A's echo and the notch went on saying B.
    @Test("Sound going elsewhere first leaves nothing to swallow the return")
    func anotherDeviceClearsIt() {
        var echo = RouteEcho()
        echo.arm("AirPods Pro", at: 100)
        let away = echo.swallows(route: "MacBook Pro Speakers", at: 101)
        let back = echo.swallows(route: "AirPods Pro", at: 103)
        #expect(!away)
        #expect(!back)
    }

    @Test("Too late is not an echo and nothing stays armed after it")
    func tooLate() {
        var echo = RouteEcho()
        echo.arm("AirPods Pro", at: 100)
        let late = echo.swallows(route: "AirPods Pro", at: 100 + LedgeCoordinator.routeEchoWindow + 1)
        let later = echo.swallows(route: "AirPods Pro", at: 100 + LedgeCoordinator.routeEchoWindow + 2)
        #expect(!late)
        #expect(!later)
    }

    /// Armed again by a second hello, it swallows again: the control that
    /// shows the cases above are refusals and not a token that never works.
    @Test("A new hello arms it again")
    func rearms() {
        var echo = RouteEcho()
        echo.arm("AirPods Pro", at: 100)
        _ = echo.swallows(route: "MacBook Pro Speakers", at: 101)
        echo.arm("AirPods Pro", at: 110)
        let again = echo.swallows(route: "AirPods Pro", at: 111)
        #expect(again)
    }

    @Test("Nothing armed swallows nothing")
    func nothingArmed() {
        var echo = RouteEcho()
        let nothing = echo.swallows(route: "AirPods Pro", at: 5)
        #expect(!nothing)
    }
}
