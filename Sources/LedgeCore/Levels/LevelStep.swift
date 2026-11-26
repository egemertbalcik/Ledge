import Foundation

/// Where a volume or brightness key takes the level.
///
/// The readout is drawn in segments and a key used to add one step to
/// wherever the level happened to be. A level that was between two lines,
/// after a drag, a change made elsewhere or an external display's floor,
/// stayed between two lines for ever: every press left one segment part
/// filled and part filled the next.
///
/// A plain press now goes to the next line. From between two lines, up fills
/// the segment the level is in and down empties it. From a line it moves one
/// whole step. The lines are multiples of the step the user chose, which is
/// one segment unless they changed it.
///
/// A fine press, Option and Shift held, moves a quarter of a step from
/// exactly where the level is and lands on no line.
public enum LevelStep {

    /// How many fine presses make one plain step.
    public static let finePerStep: Double = 4

    /// How close to a line counts as being on it, as a share of a step.
    ///
    /// Hardware reads back 0.4999 for a half. That has to count as the half
    /// or the press up from it would move nothing. A fine press leaves the
    /// level a quarter of a step from a line at the nearest, so an eighth
    /// tells the two apart with the same room on either side.
    public static let onLine: Double = 1.0 / 8

    /// The level a press goes to.
    ///
    /// - Parameters:
    ///   - current: where the level is, 0...1.
    ///   - direction: positive for up, negative for down. Zero moves nothing.
    ///   - step: one plain step. Not finite or not positive moves nothing.
    ///   - fine: a quarter step with no lines.
    ///   - floor: the lowest level there is. An external display dimmed
    ///     through its gamma ramp stops above zero, and the floor is then a
    ///     stop of its own: see below.
    public static func target(
        from current: Double, direction: Int, step: Double, fine: Bool = false, floor: Double = 0
    ) -> Double {
        let lowest = floor.isFinite ? min(max(floor, 0), 1) : 0
        func kept(_ level: Double) -> Double { min(max(level, lowest), 1) }
        guard current.isFinite else { return lowest }
        guard direction != 0, step.isFinite, step > 0 else { return kept(current) }
        let up = direction > 0

        if fine {
            return kept(current + (up ? 1 : -1) * step / finePerStep)
        }

        let slack = step * onLine
        var line = up
            ? ((current + slack) / step).rounded(.down) + 1
            : ((current - slack) / step).rounded(.up) - 1
        // A floor that is not zero takes the place of any line less than half
        // a step above it. The floor of a gamma display is 0.18 and the line
        // above it is 0.1875: a press between those two would change nothing
        // anyone could see. Up from the floor goes to the line after that
        // one and down from that line goes to the floor.
        if lowest > 0 {
            if up {
                while line * step < lowest + step / 2 { line += 1 }
            } else if line * step < lowest + step / 2 {
                return lowest
            }
        }
        return kept(line * step)
    }

    /// What the last press of our own did: which way it went, where it was
    /// sent and what the hardware then said it was at.
    public struct Landing: Equatable, Sendable {
        public var direction: Int
        public var target: Double
        public var shown: Double

        public init(direction: Int, target: Double, shown: Double) {
            self.direction = direction
            self.target = target
            self.shown = shown
        }
    }

    /// How far a reading may be from the last one shown and still be it.
    public static let sameReading: Double = 0.002

    /// How far short of where it was sent an output may read back, in steps,
    /// and the next press the same way still goes on from where it was sent.
    ///
    /// An output with few levels snaps to the nearest one it has, so a press
    /// or two can leave it where it was. Going on from where the last press
    /// was sent is what gets it to the next level. Past two steps the output
    /// is not snapping, it is refusing, a volume limit say, and it is where
    /// it says it is.
    public static let carriesOn: Double = 2

    /// The level to step from.
    ///
    /// Not always the reading. A write of our own comes back as a ramp, so a
    /// key held down reads a level that is still on its way: stepping from
    /// that lands on the line already being travelled to and the repeat is
    /// lost. A device may also read back short of what it was sent. The next
    /// press would then be sent to the same line again and the key would do
    /// nothing. In both cases a press the same way steps from where the last
    /// one was sent.
    ///
    /// A press the other way steps from what the hardware said. Coming back
    /// down after pushing up against a level the output would not pass, it
    /// would otherwise spend presses undoing steps that never happened.
    ///
    /// - Parameters:
    ///   - reading: what the hardware says now.
    ///   - last: the last press of our own on this device, if any.
    ///   - settling: whether that write is still coming back as a ramp.
    ///   - direction: which way this press goes.
    public static func start(
        reading: Double, last: Landing?, settling: Bool, step: Double, direction: Int
    ) -> Double {
        guard let last, step.isFinite, step > 0 else { return reading }
        let sameWay = (last.direction > 0) == (direction > 0) && last.direction != 0 && direction != 0
        let carries = sameWay && abs(last.target - last.shown) <= step * carriesOn + sameReading
        let landed = carries ? last.target : last.shown
        if settling { return landed }
        return abs(reading - last.shown) < sameReading ? landed : reading
    }

    /// Where to send a plain press again when the first write left the level
    /// where it was, or nil when there is nothing more to try.
    ///
    /// An output that holds only a few levels snaps what it is sent to the
    /// nearest one. The next line can be nearer the level it is on than the
    /// level after it, so the output snaps back and the key has done nothing.
    /// A whole step from the reading is what the key always sent before there
    /// were lines, and it moves every output that one did.
    ///
    /// Not for a fine press: a quarter of a step is meant to be small, and an
    /// output that cannot hold it is not sent a whole one in its place.
    ///
    /// - Parameters:
    ///   - reading: the level before the press.
    ///   - shown: what the hardware said after the write.
    ///   - target: where the write was sent.
    public static func secondTry(
        reading: Double, shown: Double, target: Double, direction: Int, step: Double, fine: Bool
    ) -> Double? {
        guard !fine, direction != 0, step.isFinite, step > 0,
              reading.isFinite, shown.isFinite, target.isFinite,
              abs(shown - reading) < sameReading
        else { return nil }
        let whole = min(max(reading + (direction > 0 ? 1 : -1) * step, 0), 1)
        // Only if it goes further than the first write did. At an end it
        // does not, and neither does it when the first write had already
        // gone on from an earlier press.
        let further = direction > 0 ? whole - target : target - whole
        guard further >= sameReading else { return nil }
        return whole
    }
}
