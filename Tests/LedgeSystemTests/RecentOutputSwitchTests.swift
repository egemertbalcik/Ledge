import Foundation
import Testing

@testable import LedgeSystem

/// Sound moving to another device makes that device report its level. That is
/// not the user turning the volume, so for a moment after a switch the
/// readout stays down.
@Suite("Whether the sound output changed a moment ago")
struct RecentOutputSwitchTests {

    @Test("Nothing has switched until something does")
    func quietAtFirst() {
        #expect(RecentOutputSwitch().happened(within: 1, of: 500) == false)
    }

    @Test("It is recent from the switch until the window closes")
    func insideTheWindow() {
        let recent = RecentOutputSwitch()
        recent.note(at: 100)
        #expect(recent.happened(within: 1, of: 100))
        #expect(recent.happened(within: 1, of: 100.9))
        #expect(recent.happened(within: 1, of: 101) == false)
        #expect(recent.happened(within: 1, of: 160) == false)
    }

    @Test("A clock that stepped back does not make an old switch recent")
    func beforeTheSwitch() {
        let recent = RecentOutputSwitch()
        recent.note(at: 100)
        #expect(recent.happened(within: 1, of: 99.5) == false)
    }

    @Test("A later switch replaces the earlier one")
    func latestWins() {
        let recent = RecentOutputSwitch()
        recent.note(at: 100)
        recent.note(at: 200)
        #expect(recent.happened(within: 1, of: 200.5))
        #expect(recent.happened(within: 1, of: 100.5) == false)
    }
}
