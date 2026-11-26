import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeShell
@testable import LedgeUI

/// Three things found reading the device code after it was merged.
///
/// A hello that waited behind another peek and expired there took its sound
/// output card with it, and with macOS's own card moved out of sight nothing
/// told the arrival. Every device card opened the banner hider's window, for
/// macOS cards that were never coming. A volume key pressed in the second
/// after an output change was applied and swallowed with nothing shown.
@Suite("What a hello answers for, and when the banner hider looks")
@MainActor
struct HelloShownAndBannerTests {

    private func card(_ source: String, _ payload: DevicePayload) -> Activity {
        Activity(id: ActivityID(kind: .device, source: source), createdAt: 0, expiresAfter: 4,
                 payload: .device(payload))
    }

    // MARK: When the banner hider looks

    @Test("A device connecting opens the long look back and sound moving the short one")
    func looksForTheTwoThatBringACard() {
        let hello = card("80:AF", DevicePayload(
            name: "AirPods Pro", isConnected: true, announcesConnection: true))
        #expect(LedgeCoordinator.bannerLookBack(for: hello) == SystemBannerHider.lookBack)

        let route = Activity(id: AudioRouteProvider.activityID, createdAt: 0, expiresAfter: 4,
                             payload: .device(DevicePayload(name: "AirPods Pro")))
        #expect(LedgeCoordinator.bannerLookBack(for: route) == SystemBannerHider.soundOutputLookBack)
        #expect(SystemBannerHider.soundOutputLookBack < SystemBannerHider.lookBack)
    }

    @Test("No other device card opens it")
    func nothingElseLooks() {
        let goodbye = card("80:AF", DevicePayload(
            name: "AirPods Pro", isConnected: false, announcesConnection: true))
        let alert = card("80:AF/low", DevicePayload(
            name: "AirPods Pro", batteryLevels: ["Left": 0.1], isConnected: true,
            alert: DevicePayload.Alert(kind: .low, component: "Left")))
        let caseOpening = card("airpods-proximity", DevicePayload(
            name: "AirPods Pro", batteryLevels: ["Case": 0.9], isConnected: nil))
        let radio = card("radio.bluetooth", DevicePayload(name: "Bluetooth", isConnected: false))
        for other in [goodbye, alert, caseOpening, radio] {
            #expect(LedgeCoordinator.bannerLookBack(for: other) == nil, "\(other.id.source) opened it")
        }
        let notADevice = Activity(id: ActivityID(kind: .keepAwake, source: "keepawake"), createdAt: 0,
                                  payload: .keepAwake(KeepAwakePayload(phase: .ready)))
        #expect(LedgeCoordinator.bannerLookBack(for: notADevice) == nil)
    }

    // MARK: A key in the second after an output change

    @Test("The level a new output reports stays down and a key pressed then does not")
    func keyIsNotQuieted() {
        let volume = HUDReadout(kind: .volume, level: 0.5)
        #expect(LedgeCoordinator.outputSwitchQuiets(volume, fromKey: false, switchedRecently: true))
        #expect(!LedgeCoordinator.outputSwitchQuiets(volume, fromKey: true, switchedRecently: true))
        #expect(!LedgeCoordinator.outputSwitchQuiets(volume, fromKey: false, switchedRecently: false))
        let brightness = HUDReadout(kind: .brightness, level: 0.5)
        #expect(!LedgeCoordinator.outputSwitchQuiets(brightness, fromKey: false, switchedRecently: true))
    }

    // MARK: Wiring, read from the source

    private static func code(_ path: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: path)
        let text = try String(contentsOf: url, encoding: .utf8)
        try #require(!text.isEmpty)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = String(line)
                guard let comment = text.range(of: "//") else { return text }
                return String(text[..<comment.lowerBound])
            }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func body(of function: String, in code: [String]) throws -> [String] {
        let first = try #require(code.firstIndex { $0.hasPrefix(function) }, "\(function) moved")
        let next = code[(first + 1)...].firstIndex {
            $0.hasPrefix("private func ") || $0.hasPrefix("static func ") || $0.hasPrefix("nonisolated static func ")
        }
        return Array(code[first..<(next ?? code.endIndex)])
    }

    @Test("The sound output echo is armed where the hello is shown and nowhere else")
    func echoArmedWhenShown() throws {
        let code = try Self.code("Sources/LedgeShell/Coordinator/LedgeCoordinator.swift")
        #expect(code.filter { $0.contains("routeEcho.arm(") }.count == 1)
        let shown = try Self.body(of: "private func helloShown(", in: code)
        #expect(shown.contains("routeEcho.arm(payload.name, at: now)"))
        #expect(shown.contains("PendingPeek.drop(AudioRouteProvider.activityID, from: &pendingPeeks) { entry in"))
        #expect(shown.contains("helloBatteries.note(payload, id: activity.id, at: now)"))
        // Shown in four places: three in `announce` and one when a waiting
        // card gets its turn.
        #expect(code.filter { $0 == "self.helloShown(activity)" }.count == 3)
        #expect(code.filter { $0 == "self.helloShown(card)" }.count == 1)
    }

    @Test("The longest a peek waits is the one number the hello's card is measured against")
    func oneNumberForTheWait() throws {
        let code = try Self.code("Sources/LedgeShell/Coordinator/LedgeCoordinator.swift")
        #expect(code.contains("private static let pendingPeekLifetime: TimeInterval = PendingPeek.longestWait"))
    }

    @Test("A hello joining the line goes ahead of its own waiting sound output card")
    func helloGoesAheadOfItsRoute() throws {
        let code = try Self.code("Sources/LedgeShell/Coordinator/LedgeCoordinator.swift")
        #expect(code.contains(
            "|| (entry.id == AudioRouteProvider.activityID && Self.isRouteEcho(card, of: hello))"))
    }

    @Test("The banner hider is asked through the rule and the readout gate knows a key")
    func hiderAndGateWiring() throws {
        let code = try Self.code("Sources/LedgeShell/Coordinator/LedgeCoordinator.swift")
        #expect(code.contains("if let lookBack = Self.bannerLookBack(for: activity) {"))
        #expect(!code.contains("if case .device = activity.payload { systemBannerHider.deviceHeard() }"))
        #expect(code.contains("readout, fromKey: self.hud.readoutFromKey,"))

        let hud = try Self.code("Sources/LedgeShell/Coordinator/HUDCoordinator.swift")
        #expect(hud.filter { $0.contains("fromKey: true)") }.count == 3,
                "the volume keys, the mute key and the brightness keys")
        #expect(hud.contains("self.show(readout)"), "a change seen from outside is not a key")
    }
}
