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
        #expect(a.subtitle == "Connected")
        #expect(a.style == .device)
    }

    @Test("Under the name it says whether the device came or went")
    func connectionWords() throws {
        #expect(try #require(NotchAnnouncement.forDevice(hello())).subtitle == "Connected")
        var goodbye = hello(["Left": 0.5])
        goodbye.isConnected = false
        let a = try #require(NotchAnnouncement.forDevice(goodbye))
        #expect(a.subtitle == "Disconnected")
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
        #expect(a.subtitle == "Sound Output")
        #expect(a.style == .device)
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

/// A battery alert used to be two ears: a glyph and one ring, with no name
/// and no words. It stands the notch up in the same row a connection uses.
@Suite("When a battery alert makes the notch stand up")
struct BatteryAlertAnnouncementTests {

    private func alert(
        _ kind: AlertKind, _ component: String, levels: [String: Double], name: String = "Ege's AirPods Pro"
    ) -> DevicePayload {
        DevicePayload(
            name: name, symbolName: "airpods.pro", batteryLevels: levels, isConnected: true,
            alert: DevicePayload.Alert(kind: kind, component: component)
        )
    }

    private func emphasis(_ a: NotchAnnouncement) -> [String: NotchAnnouncement.Battery.Emphasis] {
        Dictionary(uniqueKeysWithValues: a.batteries.map { ($0.label, $0.emphasis) })
    }

    @Test("It says Battery Low, brighter than Connected, without naming the part")
    func lowWording() throws {
        let a = try #require(NotchAnnouncement.forBatteryAlert(
            alert(.low, "Left", levels: ["Left": 0.10, "Right": 0.64, "Case": 0.80])))
        #expect(a.title == "Ege's AirPods Pro")
        #expect(a.subtitle == "Battery Low")
        #expect(a.subtitleIsBright)
        #expect(a.style == .device)
        #expect(a.followsPeekDuration)
        let connected = try #require(NotchAnnouncement.forDevice(DevicePayload(
            name: "Ege's AirPods Pro", batteryLevels: ["Left": 0.8], isConnected: true, announcesConnection: true)))
        #expect(!connected.subtitleIsBright, "Connected stays quiet, which is how the two are told apart")
    }

    @Test("Every battery keeps its place; the low one is lit and the rest are faded")
    func oneLowCell() throws {
        let a = try #require(NotchAnnouncement.forBatteryAlert(
            alert(.low, "Left", levels: ["Case": 0.80, "Right": 0.64, "Left": 0.10])))
        #expect(a.batteries.map(\.label) == ["Left", "Right", "Case"])
        #expect(emphasis(a) == ["Left": .low, "Right": .dimmed, "Case": .dimmed])
    }

    /// Two batteries crossing together arrive as two alerts under one card,
    /// so only one of them is ever named as the cause. The other is just as
    /// low and must not be faded as if it were fine.
    @Test("Another battery that is also low stays lit")
    func twoLowCells() throws {
        let a = try #require(NotchAnnouncement.forBatteryAlert(
            alert(.low, "Left", levels: ["Left": 0.12, "Right": 0.09, "Case": 0.80])))
        #expect(emphasis(a) == ["Left": .low, "Right": .low, "Case": .dimmed])
    }

    /// A rule can fire at 30%. The ring's own colour would be green there.
    @Test("The battery the alert is about is marked low whatever its level")
    func customThreshold() throws {
        let a = try #require(NotchAnnouncement.forBatteryAlert(
            alert(.low, "Battery", levels: ["Battery": 0.30], name: "Magic Keyboard")))
        #expect(a.batteries.map(\.emphasis) == [.low])
        #expect(a.subtitle == "Battery Low")
    }

    @Test("A charged part is named and a single battery just says Charged")
    func chargedWording() throws {
        let buds = try #require(NotchAnnouncement.forBatteryAlert(
            alert(.charged, "Case", levels: ["Left": 0.82, "Right": 0.79, "Case": 1.0])))
        #expect(buds.subtitle == "Case Charged")
        #expect(emphasis(buds) == ["Left": .dimmed, "Right": .dimmed, "Case": .charged])
        let keyboard = try #require(NotchAnnouncement.forBatteryAlert(
            alert(.charged, "Battery", levels: ["Battery": 1.0], name: "Magic Keyboard")))
        #expect(keyboard.subtitle == "Charged")
        #expect(keyboard.batteries.map(\.emphasis) == [.charged])
    }

    @Test("A card that is not an alert, or has no name, says nothing")
    func othersStayQuiet() {
        #expect(NotchAnnouncement.forBatteryAlert(
            DevicePayload(name: "AirPods Pro", batteryLevels: ["Left": 0.1], isConnected: true)) == nil)
        #expect(NotchAnnouncement.forBatteryAlert(alert(.low, "Left", levels: ["Left": 0.1], name: "")) == nil)
    }

    @Test("The alert survives the round trip and a payload from before it has none")
    func roundTrip() throws {
        let payload = alert(.charged, "Case", levels: ["Case": 1.0])
        let back = try JSONDecoder().decode(DevicePayload.self, from: JSONEncoder().encode(payload))
        #expect(back == payload)
        let old = try JSONDecoder().decode(
            DevicePayload.self, from: #"{"name":"AirPods","isConnected":true}"#.data(using: .utf8)!)
        #expect(old.alert == nil)
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
struct SizedAnnouncingLayoutTests {

    private let geometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 180, height: 32),
        notchCenterX: 735,
        isHardwareNotch: true
    )

    private func size(announcing: Bool, content: CGSize?) -> CGSize {
        NotchLayout.layout(
            for: .peek, geometry: geometry,
            expandedSize: CGSize(width: 320, height: 160),
            bottomRadius: 12, closedBottomRadius: 10, gutterRadius: 10,
            isAnnouncing: announcing, announceContent: content
        ).bodySize
    }

    @Test("It is exactly as big as what it says, below the hardware")
    func sizedToContent() {
        let s = size(announcing: true, content: CGSize(width: 430, height: 50))
        #expect(s.width == 430)
        #expect(s.height == geometry.notchSize.height + NotchLayout.compactExtraHeight + 50)
    }

    @Test("A short message still shows a margin either side of the cutout")
    func neverNarrowerThanTheCutout() {
        let s = size(announcing: true, content: CGSize(width: 60, height: 50))
        #expect(s.width == geometry.notchSize.width + NotchLayout.announceMinimumMargin * 2)
    }

    @Test("A size means nothing when nothing is being announced")
    func sizeNeedsAnnouncement() {
        #expect(size(announcing: false, content: CGSize(width: 430, height: 50))
                == size(announcing: false, content: nil))
    }
}
