import Testing

@testable import LedgeUI

/// An open Levels card re-reads the rows when the panel's brightness moves,
/// because a brightness key macOS handled tells Ledge nothing.
@Suite("The open Levels card follows brightness")
@MainActor
struct LevelsBrightnessFollowTests {

    /// Runs the loop over scripted readings, one per beat, and ends it when
    /// the script runs out. Answers how many times it asked for fresh rows.
    private func pulls(for readings: [Double?]) async -> (pulls: Int, beats: Int) {
        var script = readings[...]
        var pulls = 0
        var beats = 0
        await LevelsCardView.followBrightness(
            probe: { script.popFirst() ?? nil },
            sleep: {
                beats += 1
                // The script is spent: end the loop the way the card going
                // away does.
                if script.isEmpty { withUnsafeCurrentTask { $0?.cancel() } }
            },
            onChange: { pulls += 1 }
        )
        return (pulls, beats)
    }

    @Test("A move pulls once; the same level, a failed read and a hair's change do not")
    func pullsOnlyOnAMove() async {
        let result = await pulls(for: [0.5, 0.5, 0.5004, 0.5625, 0.5625, nil, 0.5625, 0.5, 0.5])
        // 0.5 → 0.5625 and 0.5625 → 0.5: two moves, two pulls.
        #expect(result.pulls == 2)
    }

    @Test("A panel with no brightness to read is never looked at again")
    func noBrightnessNoLoop() async {
        let result = await pulls(for: [nil, 0.3, 0.9])
        #expect(result.pulls == 0)
        #expect(result.beats == 0)
    }

    @Test("Each move is measured from the last level pulled, not the first")
    func measuresFromTheLastPull() async {
        // Three key steps down, then back to where the second one was.
        let result = await pulls(for: [0.75, 0.6875, 0.625, 0.5625, 0.625])
        #expect(result.pulls == 4)
    }
}
