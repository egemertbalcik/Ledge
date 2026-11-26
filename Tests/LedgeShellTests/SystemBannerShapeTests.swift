import CoreGraphics
import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeShell

/// The banner is recognised by shape, by when it turns up and by whether the
/// notch would tell the same arrival. Each of the three has to be narrow:
/// Control Center draws its own menus in windows of much the same kind.
@Suite("Recognising macOS's device banner")
struct SystemBannerShapeTests {

    private let screen: CGFloat = 1_512

    @Test("The banner as Control Center draws it, at the top right")
    func theBanner() {
        #expect(SystemBannerHider.looksLikeBanner(
            CGRect(x: 1_140, y: 30, width: 352, height: 152), screenWidth: screen))
    }

    @Test("The same shape on the left half of the screen is something else")
    func leftHalfIsNotTheBanner() {
        #expect(!SystemBannerHider.looksLikeBanner(
            CGRect(x: 200, y: 30, width: 352, height: 152), screenWidth: screen))
    }

    @Test("A window already moved away is not chased again")
    func alreadyAway() {
        #expect(!SystemBannerHider.looksLikeBanner(
            CGRect(x: -4_000, y: -4_000, width: 352, height: 152), screenWidth: screen))
    }

    @Test("Taller, wider, narrower or lower windows are left alone")
    func otherShapes() {
        // Control Center's main panel.
        #expect(!SystemBannerHider.looksLikeBanner(
            CGRect(x: 1_140, y: 30, width: 330, height: 430), screenWidth: screen))
        #expect(!SystemBannerHider.looksLikeBanner(
            CGRect(x: 800, y: 30, width: 700, height: 152), screenWidth: screen))
        #expect(!SystemBannerHider.looksLikeBanner(
            CGRect(x: 1_140, y: 30, width: 200, height: 152), screenWidth: screen))
        #expect(!SystemBannerHider.looksLikeBanner(
            CGRect(x: 1_140, y: 30, width: 352, height: 60), screenWidth: screen))
        #expect(!SystemBannerHider.looksLikeBanner(
            CGRect(x: 1_140, y: 300, width: 352, height: 152), screenWidth: screen))
    }
}

/// A menu the user opened a while ago, or opens later, must never be asked
/// whether it is the banner. Only a window created around a device being
/// heard is.
@Suite("When a window may be the device banner")
struct SystemBannerTimingTests {

    @Test("Created just before the device was heard, or soon after")
    func aroundTheDevice() {
        #expect(SystemBannerHider.isDue(created: 99, heard: 100))
        #expect(SystemBannerHider.isDue(created: 100, heard: 100))
        #expect(SystemBannerHider.isDue(created: 100 + SystemBannerHider.lookAhead, heard: 100))
    }

    @Test("A window from well before, or long after, is not looked at")
    func outsideTheWindow() {
        #expect(!SystemBannerHider.isDue(created: 100 - SystemBannerHider.lookBack - 0.1, heard: 100))
        #expect(!SystemBannerHider.isDue(created: 100 + SystemBannerHider.lookAhead + 0.1, heard: 100))
        #expect(!SystemBannerHider.isDue(created: 5, heard: -.infinity), "no device has been heard at all")
    }

    /// An output is often picked from Control Center's Sound menu, which has
    /// been open for a moment by then.
    @Test("A change of sound output looks back less far than a connection")
    func soundOutputLooksBackLess() {
        #expect(SystemBannerHider.soundOutputLookBack < SystemBannerHider.lookBack)
        let menuOpenedAt: TimeInterval = 99
        #expect(SystemBannerHider.isDue(created: menuOpenedAt, heard: 100))
        #expect(!SystemBannerHider.isDue(
            created: menuOpenedAt, heard: 100, lookBack: SystemBannerHider.soundOutputLookBack))
    }
}

/// Hiding macOS's banner is only right while the notch would tell the same
/// arrival. Otherwise the banner is the one word the user gets.
@Suite("Whether macOS's device banner may be hidden")
struct SystemBannerGateTests {

    @Test("Only with the device card on, Bluetooth granted and device news admitted")
    func allThree() {
        #expect(SystemBannerHider.mayHide(deviceCardOn: true, bluetoothGranted: true, admitsDeviceNews: true))
    }

    /// Without the Bluetooth grant Ledge hears no connection as it happens.
    /// It used to hide the banner anyway and then say nothing itself.
    @Test("Not without the Bluetooth grant")
    func needsBluetooth() {
        #expect(!SystemBannerHider.mayHide(deviceCardOn: true, bluetoothGranted: false, admitsDeviceNews: true))
    }

    @Test("Not with the device card off or while a Focus keeps the notch quiet")
    func needsTheCardAndAdmission() {
        #expect(!SystemBannerHider.mayHide(deviceCardOn: false, bluetoothGranted: true, admitsDeviceNews: true))
        #expect(!SystemBannerHider.mayHide(deviceCardOn: true, bluetoothGranted: true, admitsDeviceNews: false))
    }
}

/// A sound output card waiting behind another peek is dropped when the
/// device it names says hello.
@Suite("A waiting sound output card and the hello that replaces it")
@MainActor
struct WaitingRouteEchoTests {

    private func route(_ name: String) -> Activity {
        Activity(id: AudioRouteProvider.activityID, createdAt: 0, expiresAfter: 2,
                 payload: .device(DevicePayload(name: name)))
    }

    private let hello = DevicePayload(
        name: "Ali's AirPods Pro", isConnected: true, announcesConnection: true)

    @Test("The same device, under either spelling of its name, is the echo")
    func sameDevice() {
        #expect(LedgeCoordinator.isRouteEcho(route("Ali's AirPods Pro"), of: hello))
        #expect(LedgeCoordinator.isRouteEcho(route("Ali\u{2019}s AirPods Pro"), of: hello))
    }

    @Test("Another output, or a card that has already gone, is not")
    func otherwiseNot() {
        #expect(!LedgeCoordinator.isRouteEcho(route("MacBook Pro Speakers"), of: hello))
        #expect(!LedgeCoordinator.isRouteEcho(nil, of: hello))
    }
}
