import Foundation
import Testing

@testable import LedgeSystem

/// Telling a panel the Mac drives from a picture drawn somewhere else.
///
/// This matters because CoreGraphics cannot be asked. Setting a gamma ramp on
/// a Sidecar display *succeeds*, and reading it back returns the value that was
/// set — measured at 0.45 on a connected iPad, with no visible change on the
/// iPad at all. So the ramp is not evidence, and the display's identity has to
/// be.
@Suite("Displays the Mac can actually dim")
struct DisplayRealityTests {

    /// Vendor identifiers read off this Mac, which is where the rule comes
    /// from: EDID packs three letters into sixteen bits, so a real display's
    /// number cannot exceed 0xFFFF.
    @Test("Real panels answer with an EDID vendor")
    func realDisplays() {
        #expect(!DisplayReality.isVirtual(vendorNumber: 1552), "Apple built-in")
        #expect(!DisplayReality.isVirtual(vendorNumber: 4268), "Dell U2713H, 0x10AC")
        #expect(!DisplayReality.isVirtual(vendorNumber: 0xFFFF), "the largest an EDID vendor can be")
    }

    @Test("A Sidecar iPad does not")
    func sidecar() {
        #expect(DisplayReality.isVirtual(vendorNumber: 1_633_775_724))
    }

    @Test("Anything past sixteen bits is something composited elsewhere")
    func boundary() {
        #expect(!DisplayReality.isVirtual(vendorNumber: 0x1_0AC))
        #expect(DisplayReality.isVirtual(vendorNumber: 0x1_0000))
    }
}
