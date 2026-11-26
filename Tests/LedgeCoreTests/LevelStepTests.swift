import Foundation
import Testing

@testable import LedgeCore

/// The readout is drawn in sixteen segments. A key used to add one step to
/// wherever the level was, so a level between two lines stayed between two
/// lines: every press left one segment part filled and part filled the next.
@Suite("Where a volume or brightness key takes the level")
struct LevelStepTests {

    private let step = 0.0625

    private func up(_ level: Double, fine: Bool = false, floor: Double = 0) -> Double {
        LevelStep.target(from: level, direction: 1, step: step, fine: fine, floor: floor)
    }

    private func down(_ level: Double, fine: Bool = false, floor: Double = 0) -> Double {
        LevelStep.target(from: level, direction: -1, step: step, fine: fine, floor: floor)
    }

    // MARK: A plain press

    @Test("From a line, a press moves one whole segment")
    func wholeSegmentFromALine() {
        #expect(up(0.5) == 0.5625)
        #expect(down(0.5) == 0.4375)
    }

    @Test("From between two lines, up fills the segment and down empties it")
    func fillsOrEmptiesThePartSegment() {
        #expect(up(0.53) == 0.5625)
        #expect(down(0.53) == 0.5)
        #expect(up(0.501 + 0.01) == 0.5625)
        #expect(down(0.5625 - 0.011) == 0.5)
    }

    /// Hardware answers 0.4999 for a half. Taken as off the line, up would go
    /// to the half it is already at and the key would do nothing.
    @Test("A reading a hair off a line is on that line")
    func aHairOffIsOnTheLine() {
        #expect(up(0.4999) == 0.5625)
        #expect(up(0.5001) == 0.5625)
        #expect(down(0.4999) == 0.4375)
        #expect(down(0.5001) == 0.4375)
    }

    @Test("Sixteen presses up from nothing land on every line and sixteen down come back")
    func everyLine() {
        var level = 0.0
        for line in 1...16 {
            level = up(level)
            #expect(level == Double(line) / 16)
        }
        for line in (0..<16).reversed() {
            level = down(level)
            #expect(level == Double(line) / 16)
        }
    }

    @Test("The ends hold")
    func ends() {
        #expect(up(1) == 1)
        #expect(down(0) == 0)
        #expect(up(0.97) == 1)
        #expect(down(0.03) == 0)
    }

    /// The step is a setting. Its lines are its own multiples.
    @Test("A step the user chose has its own lines")
    func chosenStep() {
        #expect(LevelStep.target(from: 0.25, direction: 1, step: 0.1) == 0.1 * 3)
        #expect(LevelStep.target(from: 0.25, direction: -1, step: 0.1) == 0.1 * 2)
        #expect(LevelStep.target(from: 0.95, direction: 1, step: 0.1) == 1)
    }

    // MARK: A fine press

    @Test("A fine press moves a quarter of a step from exactly where the level is")
    func fineMovesAQuarter() {
        #expect(up(0.5, fine: true) == 0.5 + step / 4)
        #expect(down(0.5, fine: true) == 0.5 - step / 4)
        #expect(up(0.53, fine: true) == 0.53 + step / 4, "it does not go to a line")
        #expect(down(0.53, fine: true) == 0.53 - step / 4)
    }

    @Test("Four fine presses make one step and the next plain press goes on from there")
    func fourFineMakeOne() {
        var level = 0.5
        for _ in 0..<4 { level = up(level, fine: true) }
        #expect(level == 0.5625)
        #expect(up(level) == 0.625)
    }

    /// One fine press leaves the level a quarter of a step from a line. If
    /// that counted as on the line, the plain press after it would jump a
    /// whole segment past where the level is.
    @Test("A level left by fine presses is never taken for a line")
    func fineIsNotALine() {
        let oneUp = up(0.5, fine: true)
        #expect(up(oneUp) == 0.5625)
        #expect(down(oneUp) == 0.5)
        let threeUp = up(up(oneUp, fine: true), fine: true)
        #expect(up(threeUp) == 0.5625, "not the line after it")
        #expect(down(threeUp) == 0.5)
    }

    @Test("A fine press stops at the ends")
    func fineEnds() {
        #expect(up(0.995, fine: true) == 1)
        #expect(down(0.005, fine: true) == 0)
        #expect(down(0.18, fine: true, floor: 0.18) == 0.18)
    }

    // MARK: A floor above nothing

    /// An external display stops at 0.18 and the line above it is 0.1875. A
    /// press between those two changes nothing anyone can see.
    @Test("The floor takes the place of the line just above it")
    func floorIsAStop() {
        #expect(up(0.18, floor: 0.18) == 0.25)
        #expect(down(0.25, floor: 0.18) == 0.18)
        #expect(down(0.18, floor: 0.18) == 0.18)
        #expect(up(0.2, floor: 0.18) == 0.25)
        #expect(down(0.3125, floor: 0.18) == 0.25)
        #expect(down(0.2, floor: 0.18) == 0.18)
    }

    /// 0.18 is so near its line that it would pass for being on it. A floor a
    /// little lower would not, and the line just above it is still no stop.
    @Test("The line just above a floor is skipped however far under it the floor is")
    func floorWellUnderItsLine() {
        #expect(up(0.17, floor: 0.17) == 0.25)
        #expect(down(0.25, floor: 0.17) == 0.17)
        #expect(up(0.16, floor: 0.16) == 0.25)
        #expect(up(0.15, floor: 0.15) == 0.1875, "a line more than half a step above the floor is a stop")
    }

    @Test("A floor of nothing changes nothing")
    func noFloor() {
        #expect(up(0.17) == 0.1875)
        #expect(down(0.25) == 0.1875)
        #expect(down(0.0625) == 0)
    }

    // MARK: Values that are not levels

    @Test("Nothing that is not a number is ever sent on")
    func garbage() {
        #expect(LevelStep.target(from: .nan, direction: 1, step: step) == 0)
        #expect(LevelStep.target(from: .nan, direction: 1, step: step, floor: 0.18) == 0.18)
        #expect(LevelStep.target(from: 0.5, direction: 1, step: .nan) == 0.5)
        #expect(LevelStep.target(from: 0.5, direction: 1, step: 0) == 0.5)
        #expect(LevelStep.target(from: 0.5, direction: 0, step: step) == 0.5)
        #expect(LevelStep.target(from: 7, direction: 0, step: step) == 1)
        #expect(LevelStep.target(from: 0.5, direction: 1, step: step, floor: .nan) == 0.5625)
    }

    // MARK: Where to step from

    private func from(_ reading: Double, _ last: LevelStep.Landing?, settling: Bool = false, _ direction: Int = 1) -> Double {
        LevelStep.start(reading: reading, last: last, settling: settling, step: step, direction: direction)
    }

    @Test("With no press of our own before it, a press steps from the reading")
    func fromTheReading() {
        #expect(from(0.53, nil) == 0.53)
        #expect(from(0.53, nil, settling: true) == 0.53)
    }

    /// A write comes back as a ramp. A key held down reads a level on its way
    /// to the line it was just sent to, and stepping from that reading goes
    /// to the same line again.
    @Test("A held key moves one whole segment at each repeat while the reading lags behind")
    func heldKey() {
        var last: LevelStep.Landing?
        var sent: [Double] = []
        for reading in [0.5, 0.53, 0.59, 0.66] {
            let target = up(from(reading, last, settling: last != nil))
            sent.append(target)
            last = LevelStep.Landing(direction: 1, target: target, shown: target)
        }
        #expect(sent == [0.5625, 0.625, 0.6875, 0.75])
    }

    /// Sent to a half, the device says 0.49. From the reading the next press
    /// up would be sent to the half again and nothing would move.
    @Test("A device that reads back a little short still moves at the next press the same way")
    func readsBackShort() {
        let last = LevelStep.Landing(direction: 1, target: 0.5, shown: 0.49)
        #expect(from(0.49, last) == 0.5)
        #expect(up(from(0.49, last)) == 0.5625)
    }

    /// Pushed up against a level the output would not pass, then back down:
    /// the steps that never happened are not undone one press at a time.
    @Test("A press the other way steps from what the hardware said")
    func theOtherWay() {
        let last = LevelStep.Landing(direction: 1, target: 0.5625, shown: 0.5)
        #expect(from(0.5, last, -1) == 0.5)
        #expect(down(from(0.5, last, -1)) == 0.4375)
        #expect(from(0.53, last, settling: true, -1) == 0.5, "and not from a reading still on its way")
    }

    /// A volume limit: sent to three quarters, the device stays at a half.
    @Test("A device that would not go where it was sent is where it says it is")
    func wouldNotGo() {
        let last = LevelStep.Landing(direction: 1, target: 0.75, shown: 0.5)
        #expect(from(0.5, last) == 0.5)
        #expect(from(0.6, last, settling: true) == 0.5)
    }

    @Test("Up to two steps short still counts as on the way and more than that does not")
    func howFarShort() {
        #expect(from(0.5, LevelStep.Landing(direction: 1, target: 0.625, shown: 0.5)) == 0.625)
        #expect(from(0.5, LevelStep.Landing(direction: 1, target: 0.6875, shown: 0.5)) == 0.5)
    }

    @Test("A level changed somewhere else since is stepped from as read")
    func changedElsewhere() {
        let last = LevelStep.Landing(direction: 1, target: 0.5, shown: 0.5)
        #expect(from(0.31, last) == 0.31)
        #expect(from(0.5, last) == 0.5)
    }

    // MARK: An output with a few levels

    /// What an output with `levels` evenly spaced levels answers when sent
    /// `sent`: the nearest one it has. A tie goes up, which is the hard case
    /// on the way down.
    private func snapped(_ sent: Double, levels: Int) -> Double {
        (sent * Double(levels - 1)).rounded() / Double(levels - 1)
    }

    /// One plain press the way the key handler makes it: step, write, and
    /// once more a whole step on if the output did not move.
    private func press(_ reading: Double, _ direction: Int, levels: Int, last: inout LevelStep.Landing?) -> Double {
        var target = LevelStep.target(from: from(reading, last, direction), direction: direction, step: step)
        var shown = snapped(target, levels: levels)
        if let again = LevelStep.secondTry(
            reading: reading, shown: shown, target: target, direction: direction, step: step, fine: false) {
            target = again
            shown = snapped(again, levels: levels)
        }
        last = LevelStep.Landing(direction: direction, target: target, shown: shown)
        return shown
    }

    /// An output with nine levels answers a third when sent to 0.375, the
    /// line above a third. Every press up from there was sent to 0.375 again
    /// and the key did nothing for ever.
    @Test("No level of an output with five to fifty levels is a place a key cannot leave",
          arguments: 5...50)
    func coarseOutputsAlwaysMove(levels: Int) {
        for index in 0..<levels {
            let level = Double(index) / Double(levels - 1)
            for direction in [1, -1] where direction > 0 ? index < levels - 1 : index > 0 {
                var last: LevelStep.Landing?
                var now = level
                var presses = 0
                while now == level, presses < 3 { now = press(now, direction, levels: levels, last: &last); presses += 1 }
                #expect(direction > 0 ? now > level : now < level,
                        "\(levels) levels: three presses from \(level) did nothing")
            }
        }
    }

    /// Where the next line is not a tie between two of its levels, the first
    /// press already moves it.
    @Test("An output with ten levels moves at the first press from every level")
    func tenLevelsMoveAtOnce() {
        for index in 0..<10 {
            let level = Double(index) / 9
            var last: LevelStep.Landing?
            if index < 9 { #expect(press(level, 1, levels: 10, last: &last) > level) }
            last = nil
            if index > 0 { #expect(press(level, -1, levels: 10, last: &last) < level) }
        }
    }

    @Test("An output with a few levels gets from one end to the other and back")
    func coarseOutputsCrossTheWholeRange() {
        for levels in [5, 7, 9, 10, 12, 15, 17, 21, 33] {
            var last: LevelStep.Landing?
            var level = 0.0
            var presses = 0
            while level < 1, presses < 80 { level = press(level, 1, levels: levels, last: &last); presses += 1 }
            #expect(level == 1, "\(levels) levels never reached the top")
            presses = 0
            while level > 0, presses < 80 { level = press(level, -1, levels: levels, last: &last); presses += 1 }
            #expect(level == 0, "\(levels) levels never reached the bottom")
        }
    }

    @Test("A press that moved the level is not sent again")
    func noSecondTryWhenItMoved() {
        #expect(LevelStep.secondTry(
            reading: 0.5, shown: 0.5625, target: 0.5625, direction: 1, step: step, fine: false) == nil)
    }

    @Test("At an end there is nothing further to send")
    func noSecondTryAtAnEnd() {
        #expect(LevelStep.secondTry(reading: 1, shown: 1, target: 1, direction: 1, step: step, fine: false) == nil)
        #expect(LevelStep.secondTry(reading: 0, shown: 0, target: 0, direction: -1, step: step, fine: false) == nil)
    }

    @Test("A fine press that the output cannot hold is not made a whole step")
    func noSecondTryForFine() {
        #expect(LevelStep.secondTry(
            reading: 0.3, shown: 0.3, target: 0.3 + step / 4, direction: 1, step: step, fine: true) == nil)
    }

    @Test("A press that left the level where it was is sent once more, a whole step on")
    func secondTryIsAWholeStep() {
        let third = 1.0 / 3
        #expect(LevelStep.secondTry(
            reading: third, shown: third, target: 0.375, direction: 1, step: step, fine: false) == third + step)
        #expect(LevelStep.secondTry(
            reading: third, shown: third, target: 0.3125, direction: -1, step: step, fine: false) == third - step)
    }

    /// The first write had already gone on from an earlier press. A whole
    /// step from the reading is nearer than that and would take it back.
    @Test("The second try never sends less far than the first")
    func secondTryOnlyGoesFurther() {
        #expect(LevelStep.secondTry(
            reading: 1, shown: 1, target: 0.8125, direction: -1, step: step, fine: false) == nil)
    }
}
