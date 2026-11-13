import CoreGraphics
import Foundation
import LedgeCore
import Testing

/// A device coming or going is said by the notch growing, not by a capsule
/// hanging below it — and only when the card really is that news.
@Suite("When a device makes the notch stand up")
struct DeviceAnnouncementTests {

    private func hello(_ levels: [String: Double] = [:]) -> DevicePayload {
        DevicePayload(
            name: "Ali's AirPods Pro", symbolName: "airpodspro",
            batteryLevels: levels, isConnected: true, isApple: true,
            announcesConnection: true
        )
    }

    @Test("A connection says the full name and every battery, earbuds first")
    func connectionCarriesBatteries() throws {
        let a = try #require(NotchAnnouncement.forDevice(hello(["Case": 0.4, "Right": 0.75, "Left": 0.8])))
        #expect(a.title == "Ali's AirPods Pro")
        #expect(a.batteries.map(\.label) == ["Left", "Right", "Case"])
        #expect(a.batteries.map(\.level) == [0.8, 0.75, 0.4])
        #expect(a.detail == nil)
        #expect(a.isWide)
    }

    @Test("With no battery to show, it says whether the device came or went")
    func connectionWordsWithoutBatteries() throws {
        #expect(try #require(NotchAnnouncement.forDevice(hello())).detail == "Connected")
        var goodbye = hello(["Left": 0.5])
        goodbye.isConnected = false
        let a = try #require(NotchAnnouncement.forDevice(goodbye))
        #expect(a.detail == "Disconnected")
        #expect(a.batteries.isEmpty, "a device that has gone has no live reading")
    }

    /// The two cards that used to bring up "Connected" and "Disconnected":
    /// a low-battery alert about a connected device, and a case opening on
    /// the desk with whatever the paired list last said.
    @Test("A battery alert or an opening case is not a connection")
    func lookalikesStayQuiet() {
        let alert = DevicePayload(
            name: "AirPods Pro", batteryLevels: ["Left": 0.1], isConnected: true
        )
        let caseOpening = DevicePayload(
            name: "AirPods Pro", batteryLevels: ["Case": 0.9], isConnected: false
        )
        let unknown = DevicePayload(name: "AirPods Pro", isConnected: nil)
        #expect(NotchAnnouncement.forDevice(alert) == nil)
        #expect(NotchAnnouncement.forDevice(caseOpening) == nil)
        #expect(NotchAnnouncement.forDevice(unknown) == nil)
    }

    @Test("Sound moving says where it went, in full")
    func soundOutput() throws {
        let route = DevicePayload(name: "MacBook Pro Speakers", symbolName: "laptopcomputer",
                                  statusText: "Speakers")
        let a = try #require(NotchAnnouncement.forSoundOutput(route))
        #expect(a.title == "MacBook Pro Speakers")
        #expect(a.isWide)
        #expect(a.batteries.isEmpty)
    }

    /// The "Announcement" setting is how long the user wants arrivals held.
    /// Device news follows it; the end of a pomodoro keeps its own length.
    @Test("Device news lasts as long as the Announcement setting says")
    func durationFollowsSetting() throws {
        let device = try #require(NotchAnnouncement.forDevice(hello()))
        #expect(device.duration(peek: 1.2) == 1.2)
        #expect(device.duration(peek: 5) == 5)
        let timer = try #require(NotchAnnouncement.forTimer(TimerPayload(
            label: "Focus", remaining: 0, total: 1500, isRunning: false, isFinished: true
        )))
        #expect(timer.duration(peek: 1.2) == NotchAnnouncement.duration)
    }

    @Test("Batteries are kept inside 0…1 and a broken reading is dropped")
    func batteriesSanitised() throws {
        let a = try #require(NotchAnnouncement.forDevice(hello(["Left": 1.4, "Right": .nan, "Case": -0.2])))
        #expect(a.batteries.map(\.label) == ["Left", "Case"])
        #expect(a.batteries.map(\.level) == [1, 0])
    }
}

@Suite("The device payload's connection flag")
struct DevicePayloadConnectionFlagTests {

    @Test("A payload from before the flag is not a connection")
    func missingKeyIsFalse() throws {
        let json = #"{"name":"AirPods","isConnected":true}"#.data(using: .utf8)!
        let payload = try JSONDecoder().decode(DevicePayload.self, from: json)
        #expect(payload.announcesConnection == false)
        #expect(payload.isConnected == true)
    }

    @Test("The flag survives the round trip")
    func roundTrip() throws {
        let payload = DevicePayload(name: "AirPods", announcesConnection: true)
        let back = try JSONDecoder().decode(DevicePayload.self, from: JSONEncoder().encode(payload))
        #expect(back == payload)
    }
}

@Suite("The shape when a device stands it up")
struct WideAnnouncingLayoutTests {

    private let geometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 180, height: 32),
        notchCenterX: 735,
        isHardwareNotch: true
    )

    private func size(announcing: Bool, wide: Bool) -> CGSize {
        NotchLayout.layout(
            for: .peek, geometry: geometry,
            expandedSize: CGSize(width: 320, height: 160),
            bottomRadius: 12, closedBottomRadius: 10, gutterRadius: 10,
            isAnnouncing: announcing, isAnnouncingWide: wide
        ).bodySize
    }

    @Test("Wide stands up as tall as any announcement, and wider")
    func wideIsWider() {
        let standard = size(announcing: true, wide: false)
        let wide = size(announcing: true, wide: true)
        #expect(wide.height == standard.height)
        #expect(wide.width > standard.width)
        #expect(wide.width == geometry.notchSize.width + NotchLayout.wideAnnounceEarWidth * 2)
    }

    @Test("Wide means nothing when nothing is being announced")
    func wideNeedsAnnouncement() {
        #expect(size(announcing: false, wide: true) == size(announcing: false, wide: false))
    }
}
