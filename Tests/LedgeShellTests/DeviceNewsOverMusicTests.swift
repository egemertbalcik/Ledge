import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeShell

/// While music rests in the island, small arrivals show as a glyph beside it
/// rather than taking the island over. A device arriving, leaving, becoming
/// the sound output or running low is not one of those: it grows the notch
/// and says so in full, music or no music.
@Suite("Device news while music rests")
@MainActor
struct DeviceNewsOverMusicTests {

    private func card(_ id: ActivityID, _ payload: DevicePayload) -> Activity {
        Activity(id: id, createdAt: 0, expiresAfter: 4, payload: .device(payload))
    }

    private let buds = ActivityID(kind: .device, source: "80:AF:19:40:F9:B6")

    @Test("A connection grows the notch instead of sitting beside the music")
    func connectionStandsUp() {
        let hello = card(buds, DevicePayload(
            name: "AirPods Pro", symbolName: "airpods.pro", batteryLevels: ["Left": 0.8],
            isConnected: true, announcesConnection: true))
        #expect(LedgeCoordinator.announcement(for: hello)?.subtitle == "Connected")
        #expect(LedgeCoordinator.transientSatellite(for: hello) == nil)
    }

    @Test("A sound output change grows the notch too")
    func soundOutputStandsUp() {
        let route = card(AudioRouteProvider.activityID, DevicePayload(
            name: "MacBook Pro Speakers", symbolName: "laptopcomputer", statusText: "Speakers"))
        #expect(LedgeCoordinator.announcement(for: route)?.subtitle == "Sound Output")
        #expect(LedgeCoordinator.transientSatellite(for: route) == nil)
    }

    @Test("A departure has never been a glyph beside the music")
    func departureStandsUp() {
        let goodbye = card(buds, DevicePayload(
            name: "AirPods Pro", symbolName: "airpods.pro", isConnected: false, announcesConnection: true))
        #expect(LedgeCoordinator.announcement(for: goodbye)?.subtitle == "Disconnected")
        #expect(LedgeCoordinator.transientSatellite(for: goodbye) == nil)
    }

    @Test("A battery alert grows the notch too")
    func batteryAlertStandsUp() {
        let alert = card(ActivityID(kind: .device, source: "aa:bb/low"), DevicePayload(
            name: "AirPods Pro", symbolName: "airpods.pro", batteryLevels: ["Left": 0.1], isConnected: true,
            alert: DevicePayload.Alert(kind: .low, component: "Left")))
        #expect(LedgeCoordinator.announcement(for: alert)?.subtitle == "Battery Low")
        #expect(LedgeCoordinator.transientSatellite(for: alert) == nil)
    }

    /// Not news with words of its own, so it keeps the quiet treatment
    /// beside the music.
    @Test("A case opening on the desk still shows beside the music")
    func caseOpeningStaysBeside() {
        let caseOpening = card(ActivityID(kind: .device, source: "proximity"), DevicePayload(
            name: "AirPods Pro", symbolName: "airpods.pro", batteryLevels: ["Case": 0.9], isConnected: nil))
        #expect(LedgeCoordinator.announcement(for: caseOpening) == nil)
        #expect(LedgeCoordinator.transientSatellite(for: caseOpening) != nil)
    }
}
