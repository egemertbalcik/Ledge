import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeShell

/// Earbuds that connect already under a fifth said "Connected" and then
/// "Battery Low", one after the other. The hello draws that battery in red,
/// so it is told alone. An alert about anything the hello did not draw in
/// red is still told.
@Suite("A low battery the hello has already shown")
@MainActor
struct HelloBatteriesTests {

    private let buds = ActivityID(kind: .device, source: "80:AF:19:40:F9:B6")
    private let budsLow = ActivityID(kind: .device, source: "80:AF:19:40:F9:B6/low")

    private let name = "Ali's AirPods Pro"

    private func hello(_ levels: [String: Double], connected: Bool = true) -> DevicePayload {
        hello(name, levels, connected: connected)
    }

    private func hello(_ name: String, _ levels: [String: Double], connected: Bool = true) -> DevicePayload {
        DevicePayload(
            name: name, symbolName: "airpods.pro", batteryLevels: levels,
            isConnected: connected, announcesConnection: true)
    }

    private func alert(
        _ levels: [String: Double], about component: String, kind: AlertKind = .low
    ) -> DevicePayload {
        alert(name, levels, about: component, kind: kind)
    }

    private func alert(
        _ name: String, _ levels: [String: Double], about component: String, kind: AlertKind = .low
    ) -> DevicePayload {
        DevicePayload(
            name: name, symbolName: "airpods.pro", batteryLevels: levels, isConnected: true,
            alert: DevicePayload.Alert(kind: kind, component: component))
    }

    private func card(_ id: ActivityID, _ payload: DevicePayload) -> Activity {
        Activity(id: id, createdAt: 0, expiresAfter: 4, payload: .device(payload))
    }

    // MARK: What counts as shown

    @Test("A battery the hello drew in red is told by the hello")
    func redRingTellsIt() {
        let levels = ["Left": 0.12, "Right": 0.8, "Case": 0.6]
        #expect(HelloBatteries.tells(hello(levels), alert(levels, about: "Left")))
    }

    /// The readings come from two places and need not agree to the percent.
    @Test("The two readings may differ while both are under a fifth")
    func readingsMayDiffer() {
        #expect(HelloBatteries.tells(hello(["Left": 0.14]), alert(["Left": 0.11], about: "Left")))
    }

    @Test("A hello that came without levels showed nothing")
    func bareHelloTellsNothing() {
        #expect(!HelloBatteries.tells(hello([:]), alert(["Left": 0.12], about: "Left")))
    }

    /// A rule fires at its threshold and a rule can be set above a fifth.
    /// The ring is green in both cases and green says nothing.
    @Test("A ring that was still green told nothing")
    func greenRingTellsNothing() {
        #expect(!HelloBatteries.tells(hello(["Left": 0.2]), alert(["Left": 0.2], about: "Left")))
        #expect(!HelloBatteries.tells(hello(["Left": 0.28]), alert(["Left": 0.28], about: "Left")))
    }

    /// Connected at 21%, down to 19% a few seconds later.
    @Test("A battery that ran down after the hello is news")
    func ranDownAfterwards() {
        #expect(!HelloBatteries.tells(hello(["Left": 0.21]), alert(["Left": 0.19], about: "Left")))
    }

    @Test("Another battery being red does not answer for this one")
    func otherBatteryDoesNotCount() {
        let levels = ["Left": 0.1, "Right": 0.28]
        #expect(!HelloBatteries.tells(hello(levels), alert(levels, about: "Right")))
    }

    /// Bluetooth writes a keyboard's battery as "Battery" and the alert names
    /// the same one "Main".
    @Test("A single battery is the same battery under either label")
    func singleBatteryLabels() {
        #expect(HelloBatteries.tells(
            hello("Magic Keyboard", ["Battery": 0.08]),
            alert("Magic Keyboard", ["Main": 0.08], about: "Main")))
    }

    @Test("A battery that finished charging is not this")
    func chargedIsNotThis() {
        let levels = ["Left": 0.1, "Case": 1.0]
        #expect(!HelloBatteries.tells(hello(levels), alert(levels, about: "Left", kind: .charged)))
    }

    @Test("A goodbye shows no rings and answers for nothing")
    func goodbyeTellsNothing() {
        let levels = ["Left": 0.1]
        #expect(!HelloBatteries.tells(hello(levels, connected: false), alert(levels, about: "Left")))
    }

    @Test("A card that only looks like a connection answers for nothing")
    func notAConnection() {
        let levels = ["Left": 0.1]
        let caseOpening = DevicePayload(
            name: "Ali's AirPods Pro", symbolName: "airpods.pro", batteryLevels: levels, isConnected: true)
        #expect(!HelloBatteries.tells(caseOpening, alert(levels, about: "Left")))
    }

    // MARK: Which device

    @Test("Another device's hello does not answer for this one's battery")
    func anotherDevice() {
        let levels = ["Left": 0.1]
        #expect(!HelloBatteries.tells(hello("Beats Studio Buds", levels), alert(levels, about: "Left")))
    }

    /// A sound output is matched by a looser rule. Here a wrong match loses
    /// a warning that does not come back until the battery is charged.
    @Test("One name containing the other is not the same device")
    func containingNameIsNotEnough() {
        let levels = ["Left": 0.1]
        #expect(!HelloBatteries.tells(hello("AirPods", levels), alert("AirPods Pro", levels, about: "Left")))
        #expect(!HelloBatteries.tells(hello("AirPods Pro", levels), alert("AirPods", levels, about: "Left")))
    }

    @Test("A curly apostrophe does not make a different device")
    func curlyApostrophe() {
        let levels = ["Left": 0.1]
        #expect(HelloBatteries.tells(
            hello("Ali\u{2019}s AirPods Pro", levels), alert("Ali's AirPods Pro", levels, about: "Left")))
    }

    // MARK: For how long

    @Test("An alert soon after the hello is told and one long after is news")
    func window() {
        let levels = ["Left": 0.1]
        var told = HelloBatteries()
        told.note(hello(levels), id: buds, at: 100)
        #expect(told.told(alert(levels, about: "Left"), at: 100))
        #expect(told.told(alert(levels, about: "Left"), at: 100 + HelloBatteries.window - 0.1))
        #expect(!told.told(alert(levels, about: "Left"), at: 100 + HelloBatteries.window))
        #expect(!told.told(alert(levels, about: "Left"), at: 99))
    }

    @Test("Nothing is told before any hello")
    func nothingNoted() {
        #expect(!HelloBatteries().told(alert(["Left": 0.1], about: "Left"), at: 100))
    }

    /// Both earbuds low on one arrival set off an alert each.
    @Test("One hello answers for every battery it drew in red")
    func bothEarbuds() {
        let levels = ["Left": 0.1, "Right": 0.15]
        var told = HelloBatteries()
        told.note(hello(levels), id: buds, at: 100)
        #expect(told.told(alert(levels, about: "Left"), at: 101))
        #expect(told.told(alert(levels, about: "Right"), at: 101.2))
        #expect(told.told(alert(levels, about: "Left"), at: 102), "asking uses nothing up")
    }

    @Test("Two devices saying hello close together each answer for their own")
    func twoDevices() {
        let keyboard = ActivityID(kind: .device, source: "AA:BB:CC:DD:EE:FF")
        var told = HelloBatteries()
        told.note(hello(["Left": 0.1]), id: buds, at: 100)
        told.note(hello("Magic Keyboard", ["Battery": 0.05]), id: keyboard, at: 101)
        #expect(told.told(alert(["Left": 0.1], about: "Left"), at: 102))
        #expect(told.told(alert("Magic Keyboard", ["Main": 0.05], about: "Main"), at: 102))
    }

    /// A link that drops and comes back says hello again. If the second
    /// hello has no levels it showed no rings.
    @Test("A device saying hello again replaces what it said before")
    func helloAgain() {
        let levels = ["Left": 0.1]
        var told = HelloBatteries()
        told.note(hello(levels), id: buds, at: 100)
        told.note(hello([:]), id: buds, at: 102)
        #expect(!told.told(alert(levels, about: "Left"), at: 103))
    }

    // MARK: The alert that got there first

    @Test("A waiting alert that the hello shows is its repeat")
    func waitingAlert() {
        let levels = ["Left": 0.1]
        let waiting = card(budsLow, alert(levels, about: "Left"))
        #expect(LedgeCoordinator.isToldBattery(waiting, by: hello(levels)))
        #expect(!LedgeCoordinator.isToldBattery(waiting, by: hello([:])))
        #expect(!LedgeCoordinator.isToldBattery(nil, by: hello(levels)), "a card that has gone is no repeat")
        #expect(!LedgeCoordinator.isToldBattery(card(buds, hello(levels)), by: hello(levels)),
                "a hello is not an alert")
    }

    @Test("The hello takes the place of an alert on screen that it shows")
    func replacesAlertOnScreen() {
        let levels = ["Left": 0.1]
        let onScreen = card(budsLow, alert(levels, about: "Left"))
        #expect(LedgeCoordinator.helloReplaces(onScreen, with: card(buds, hello(levels))))
        #expect(!LedgeCoordinator.helloReplaces(onScreen, with: card(buds, hello([:]))),
                "a hello without rings waits its turn and the alert is seen out")
        #expect(!LedgeCoordinator.helloReplaces(onScreen, with: card(buds, hello(levels, connected: false))))
    }

    @Test("The hello still takes the place of its own sound output card")
    func replacesRouteOnScreen() {
        let route = card(AudioRouteProvider.activityID, DevicePayload(
            name: "AirPods Pro", symbolName: "airpods.pro", statusText: "Headphones"))
        let arrival = card(buds, hello(["Left": 0.8]))
        #expect(LedgeCoordinator.helloReplaces(route, with: arrival))
        #expect(!LedgeCoordinator.helloReplaces(route, with: card(buds, hello("Magic Keyboard", [:]))))
        #expect(!LedgeCoordinator.helloReplaces(route, with: route), "a sound output card replaces nothing")
        #expect(!LedgeCoordinator.helloReplaces(
            route, with: card(buds, hello("AirPods Pro", [:], connected: false))), "a goodbye waits its turn")
        let caseOpening = DevicePayload(
            name: "AirPods Pro", symbolName: "airpods.pro", batteryLevels: ["Case": 0.9], isConnected: true)
        #expect(!LedgeCoordinator.helloReplaces(route, with: card(buds, caseOpening)),
                "a card that only looks like a connection waits too")
    }

    @Test("A hello leaves any other card on screen alone")
    func leavesOthersAlone() {
        let other = card(ActivityID(kind: .device, source: "11:22:33:44:55:66"), hello("Magic Keyboard", [:]))
        #expect(!LedgeCoordinator.helloReplaces(other, with: card(buds, hello(["Left": 0.1]))))
    }
}
