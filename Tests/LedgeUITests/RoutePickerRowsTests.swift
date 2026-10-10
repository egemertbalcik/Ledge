import Foundation
import Testing

@testable import LedgeUI

/// What the open output list does when a device drops out of it.
///
/// Bluetooth and AirPlay make this ordinary: headphones go out of range, a
/// speaker sleeps, and the device stops being listed — often in the middle of
/// the drag that was reaching for its volume.
@Suite("An output list with a pointer down on it")
struct RoutePickerRowsTests {

    private func option(_ id: UInt32, _ name: String, current: Bool = false) -> AudioOutputOption {
        AudioOutputOption(id: id, name: name, isCurrent: current, level: 0.5)
    }

    private var shown: [AudioOutputOption] {
        [option(1, "MacBook Speakers", current: true), option(2, "AirPods"), option(3, "Studio Display")]
    }

    @Test("With nothing being dragged, the fresh reading is simply the list")
    func noDragMeansNoMerging() {
        let fresh = [option(1, "MacBook Speakers", current: true)]
        #expect(RoutePickerRows.merging(fresh, into: shown, dragging: []) == fresh)
    }

    @Test("A device that drops out under the pointer keeps its row")
    func draggedRowSurvivesItsDevice() {
        // Removing it takes its gesture with it, and a gesture removed that
        // way never ends — which left the card letting go of the shell's latch
        // on the device's behalf, closing the notch under a finger that was
        // still down.
        let fresh = [option(1, "MacBook Speakers", current: true), option(3, "Studio Display")]
        let rows = RoutePickerRows.merging(fresh, into: shown, dragging: [2])

        #expect(rows.map(\.id) == [1, 2, 3], "the row being dragged was pulled out from under the pointer")
        #expect(rows.first { $0.id == 2 }?.name == "AirPods")
    }

    @Test("It keeps the place it had, so the list does not reshuffle under the pointer")
    func keptRowHoldsItsPlace() {
        let fresh = [option(3, "Studio Display")]
        let rows = RoutePickerRows.merging(fresh, into: shown, dragging: [2])
        #expect(rows.map(\.id) == [3, 2])

        let last = [option(1, "MacBook Speakers", current: true), option(2, "AirPods")]
        let movedOff = RoutePickerRows.merging([option(1, "MacBook Speakers", current: true)], into: last, dragging: [2])
        #expect(movedOff.map(\.id) == [1, 2])
    }

    @Test("A device being dragged that is still there is not duplicated")
    func presentRowIsNotDoubled() {
        let fresh = [option(1, "MacBook Speakers", current: true), option(2, "AirPods", current: true)]
        let rows = RoutePickerRows.merging(fresh, into: shown, dragging: [2])
        #expect(rows.map(\.id) == [1, 2])
        #expect(
            rows.first { $0.id == 2 }?.isCurrent == true,
            "the fresh reading of a device that is still there must win"
        )
    }

    @Test("A device nobody is dragging goes when it goes")
    func undraggedRowsAreNotKept() {
        let fresh = [option(1, "MacBook Speakers", current: true)]
        let rows = RoutePickerRows.merging(fresh, into: shown, dragging: [2])
        #expect(rows.map(\.id) == [1, 2], "a row nobody had hold of was kept alive")
    }

    @Test("Two devices dragged and lost both keep their places")
    func severalKeptRows() {
        let rows = RoutePickerRows.merging([], into: shown, dragging: [1, 3])
        #expect(rows.map(\.id) == [1, 3])
    }

    @Test("A dragged device that was never in the list adds nothing")
    func unknownDraggedIdIsIgnored() {
        let fresh = [option(1, "MacBook Speakers", current: true)]
        #expect(RoutePickerRows.merging(fresh, into: shown, dragging: [99]) == fresh)
    }
}
