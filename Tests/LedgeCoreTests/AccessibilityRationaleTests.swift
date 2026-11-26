import Testing

@testable import LedgeCore

/// Ledge moves macOS's headphone banner out of sight on macOS 26 only. The
/// text that asks for Accessibility used to promise one announcement in place
/// of two on every version, which was not true on macOS 15.
@Suite("What Accessibility is asked for")
struct AccessibilityRationaleTests {

    @Test("The headphones sentence is said only where the banner is moved")
    func headphonesOnlyWhereTrue() {
        let moved = PermissionKind.accessibilityRationale(movesHeadphoneBanner: true)
        let left = PermissionKind.accessibilityRationale(movesHeadphoneBanner: false)
        #expect(moved.contains("headphones"))
        #expect(!left.contains("headphones"))
        #expect(left.contains("volume and brightness"))
        #expect(moved.contains("volume and brightness"))
    }

    @Test("The permission says what this macOS does")
    func followsThisMac() {
        #expect(PermissionKind.accessibility.rationale
            == PermissionKind.accessibilityRationale(movesHeadphoneBanner: PermissionKind.movesHeadphoneBanner))
    }

    /// "Ledge shows none" is about the readout. Said after the headphones
    /// sentence it read as if the notch said nothing about headphones.
    @Test("What is lost without it is said about the readout, before headphones come up")
    func lossComesBeforeHeadphones() throws {
        let moved = PermissionKind.accessibilityRationale(movesHeadphoneBanner: true)
        let loss = try #require(moved.range(of: "Ledge shows none"))
        let headphones = try #require(moved.range(of: "headphones"))
        #expect(loss.lowerBound < headphones.lowerBound)
    }
}
