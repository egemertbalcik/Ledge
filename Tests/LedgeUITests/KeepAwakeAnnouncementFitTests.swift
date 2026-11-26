import CoreGraphics
import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// The two lines the notch says about Keep Awake are drawn in the device row,
/// whose text is cut at the end past a cap. A reason cut short is the problem
/// this replaced, so every one of them has to fit whole.
@Suite("Keep Awake's two lines fit the row")
@MainActor
struct KeepAwakeAnnouncementFitTests {

    /// The widest way a time is written here, and a three-digit floor.
    private func all() -> [NotchAnnouncement] {
        var said: [NotchAnnouncement] = []
        for reason in KeepAwakeEndReason.allCases where reason.isVisible {
            for lidClosed in [false, true] {
                if let one = NotchAnnouncement.forKeepAwake(KeepAwakePayload(
                    phase: .finished(reason), until: "10:30 PM", batteryFloor: 100, lidClosed: lidClosed)) {
                    said.append(one)
                }
            }
        }
        said.append(contentsOf: [
            NotchAnnouncement.forKeepAwake(KeepAwakePayload(
                phase: .running, remaining: 11 * 3600 + 59 * 60, until: "10:30 PM", resumed: true)),
            NotchAnnouncement.forKeepAwake(KeepAwakePayload(phase: .running, isIndefinite: true, resumed: true)),
            NotchAnnouncement.forKeepAwake(KeepAwakePayload(phase: .running, isIndefinite: true, returned: true)),
        ].compactMap { $0 })
        return said
    }

    @Test("Nothing the notch says about Keep Awake is cut")
    func nothingIsCut() {
        let said = all()
        #expect(said.count >= 19, "the list above lost its cases")
        for one in said {
            let needs = DeviceAnnouncementMetrics.naturalTextWidth(for: one)
            #expect(needs <= DeviceAnnouncementMetrics.maximumTextWidth,
                    "\"\(one.subtitle ?? one.title)\" needs \(needs) pt")
        }
    }

    @Test("The shape is sized to the two lines and not to the closed notch")
    func sizedToContent() {
        let battery = NotchAnnouncement.forKeepAwake(KeepAwakePayload(
            phase: .finished(.batteryFloor), until: "17:40", batteryFloor: 15))!
        let size = DeviceAnnouncementMetrics.size(for: battery, bottomRadius: 30)
        #expect(size.height == DeviceAnnouncementMetrics.height)
        #expect(size.width < 275, "narrower than the compact view it used to overflow")
        #expect(size.width > 150)
    }
}
