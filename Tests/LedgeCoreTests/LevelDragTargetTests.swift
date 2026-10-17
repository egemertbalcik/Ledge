import Foundation
import Testing

@testable import LedgeCore

/// Which device a level gesture writes to.
///
/// Rewritten from `LevelsTargetTests`, which pinned the same rule when the
/// card resolved its own target. The rule outlived the card: a drag owns the
/// device it started on, and everything outside a drag follows the system.
@Suite("Which device a level gesture is writing to")
struct LevelDragTargetTests {

    private let speakers: UInt32 = 1
    private let headphones: UInt32 = 2
    private func present(_ ids: UInt32...) -> (UInt32) -> Bool {
        { ids.contains($0) }
    }

    @Test("Outside a drag, the card follows whatever the system says")
    func outsideADragTheSystemWins() {
        // An output that changes under an open card brings its own level
        // along: the card is about that device now whether or not anybody
        // touched it.
        let target = LevelDragTarget<UInt32>()
        #expect(!target.isDragging)
        #expect(target.device(current: headphones, isStillPresent: present(speakers, headphones))
                    == headphones)
    }

    @Test("A drag holds the device it started on")
    func aDragHoldsItsDevice() {
        // The regression: plugging in headphones mid-drag moved the drag to
        // them. The number on screen went on moving, so there was nothing to
        // see, and the device being changed was not the one being looked at.
        var target = LevelDragTarget<UInt32>()
        target.began(on: speakers)
        #expect(target.isDragging)
        #expect(target.device(current: headphones, isStillPresent: present(speakers, headphones))
                    == speakers, "the drag was moved to a device nobody was touching")
    }

    @Test("Letting go gives the card back to the system")
    func endingReleasesIt() {
        var target = LevelDragTarget<UInt32>()
        target.began(on: speakers)
        target.ended()
        #expect(!target.isDragging)
        #expect(target.device(current: headphones, isStillPresent: present(headphones))
                    == headphones)
    }

    @Test("A held device that has gone is not written to")
    func anUnpluggedDeviceIsNotTheTarget() {
        // Unplugging the output mid-drag leaves nothing to write to, and
        // writing to a device that is gone is not better than not writing.
        var target = LevelDragTarget<UInt32>()
        target.began(on: headphones)
        #expect(target.device(current: speakers, isStillPresent: present(speakers)) == speakers)
    }

    @Test("A drag that started on nothing writes to whatever is current")
    func beganOnNothing() {
        // The card can be touched in the instant between an output going and
        // its replacement arriving. That is not a reason to refuse the press.
        var target = LevelDragTarget<UInt32>()
        target.began(on: nil)
        #expect(!target.isDragging)
        #expect(target.device(current: speakers, isStillPresent: present(speakers)) == speakers)
    }
}
