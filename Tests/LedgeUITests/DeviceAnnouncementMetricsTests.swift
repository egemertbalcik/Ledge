import CoreGraphics
import LedgeCore
import Testing

@testable import LedgeUI

/// The notch is sized to the device row before the row is drawn, so the
/// measurement has to follow the text: a short name must not sit in a field
/// of empty black, and a long one must not run past the shape.
@Suite("Sizing the device row")
struct DeviceAnnouncementMetricsTests {

    private func announcement(_ name: String, batteries: [String: Double] = [:]) -> NotchAnnouncement {
        NotchAnnouncement.forDevice(DevicePayload(
            name: name, symbolName: "airpodspro", batteryLevels: batteries,
            isConnected: true, announcesConnection: true
        ))!
    }

    @Test("A longer name makes a wider row, up to the cap")
    func widthFollowsName() {
        let short = DeviceAnnouncementMetrics.size(for: announcement("Pods"), bottomRadius: 12)
        let long = DeviceAnnouncementMetrics.size(for: announcement("Ali Emre's AirPods Pro"), bottomRadius: 12)
        let huge = DeviceAnnouncementMetrics.size(
            for: announcement(String(repeating: "Very Long Device Name ", count: 6)), bottomRadius: 12)
        #expect(long.width > short.width)
        #expect(DeviceAnnouncementMetrics.textWidth(for: announcement(String(repeating: "W", count: 80)))
                == DeviceAnnouncementMetrics.maximumTextWidth)
        #expect(huge.width <= long.width + DeviceAnnouncementMetrics.maximumTextWidth)
    }

    @Test("Each battery adds its ring and its number")
    func batteriesAddWidth() {
        let none = DeviceAnnouncementMetrics.size(for: announcement("AirPods Pro"), bottomRadius: 12)
        let three = DeviceAnnouncementMetrics.size(
            for: announcement("AirPods Pro", batteries: ["Left": 0.82, "Right": 0.15, "Case": 0.41]),
            bottomRadius: 12)
        #expect(three.width - none.width > 3 * DeviceAnnouncementMetrics.ringSize)
        #expect(three.height == none.height)
    }

    /// The percentage sits under its ring. Beside it, earbuds with three
    /// batteries stood the notch up at about 394 points on a Mac whose closed
    /// notch is 275.
    @Test("Earbuds with three batteries stay near the width of the closed notch")
    func threeBatteriesStayNarrow() {
        let buds = announcement("Ege's AirPods Pro", batteries: ["Left": 0.82, "Right": 0.79, "Case": 0.64])
        let size = DeviceAnnouncementMetrics.size(for: buds, bottomRadius: 30)
        let cells = [0.82, 0.79, 0.64].map(DeviceAnnouncementMetrics.cellWidth).reduce(0, +)
        let expected = DeviceAnnouncementMetrics.glyphSize + DeviceAnnouncementMetrics.spacing
            + DeviceAnnouncementMetrics.textWidth(for: buds)
            + DeviceAnnouncementMetrics.spacing + DeviceAnnouncementMetrics.cellsLead
            + cells + DeviceAnnouncementMetrics.cellSpacing * 2
            + DeviceAnnouncementMetrics.sideInset(bottomRadius: 30) * 2
        #expect(size.width == expected.rounded(.up))
        #expect((300...345).contains(size.width), "about 323; the number beside the ring made it about 394")
        // A cell is never narrower than its ring nor than its number.
        #expect(DeviceAnnouncementMetrics.cellWidth(0.05) >= DeviceAnnouncementMetrics.ringSize)
        #expect(DeviceAnnouncementMetrics.cellWidth(1) >= DeviceAnnouncementMetrics.numberWidth(1))
    }

    @Test("A name past the cap is as wide as the cap and no wider")
    func longNameStopsAtTheCap() {
        let long = announcement("Living Room Conference Speakerphone Pro Max")
        #expect(DeviceAnnouncementMetrics.textWidth(for: long) == DeviceAnnouncementMetrics.maximumTextWidth)
        #expect(DeviceAnnouncementMetrics.maximumTextWidth == 150)
        // The names the cap was chosen for fit whole.
        #expect(DeviceAnnouncementMetrics.textWidth(for: announcement("Ege Mert's AirPods Pro"))
                < DeviceAnnouncementMetrics.maximumTextWidth)
    }

    /// The complaint this came from: "MacBook Pro Speakers" sat in a strip
    /// sized for three batteries.
    @Test("A sound output with no batteries stays close to its words")
    func soundOutputIsSnug() throws {
        let route = try #require(NotchAnnouncement.forSoundOutput(DevicePayload(
            name: "MacBook Pro Speakers", symbolName: "laptopcomputer")))
        let size = DeviceAnnouncementMetrics.size(for: route, bottomRadius: 12)
        let words = DeviceAnnouncementMetrics.textWidth(for: route)
        let slack = size.width - words - DeviceAnnouncementMetrics.glyphSize - DeviceAnnouncementMetrics.spacing
        #expect(slack == DeviceAnnouncementMetrics.sideInset(bottomRadius: 12) * 2
                || abs(slack - DeviceAnnouncementMetrics.sideInset(bottomRadius: 12) * 2) < 1)
        #expect(size.width < 300)
    }
}
