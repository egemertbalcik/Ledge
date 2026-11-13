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
