import Foundation
import Testing

@testable import LedgeCore

/// A level, as the thing every surface draws.
///
/// The rules here are the ones three drawings of one number used to disagree
/// about: what a row can do, what its value column says, and where a gesture
/// actually lands.
@Suite("A level row")
struct LevelRowTests {

    private func sound(_ level: Double, muted: Bool = false) -> LevelRow {
        LevelRow(id: "sound", kind: .sound, name: "MacBook Pro Speakers",
                 control: .level(level), isMuted: muted, canMute: true)
    }

    // MARK: - What the value column says

    @Test("A level is a number, and the two other states are not")
    func valueColumn() {
        #expect(sound(0.55).valueText == "55")
        #expect(sound(0).valueText == "0", "zero is a level, and it has a number")
        #expect(sound(1).valueText == "100")
        // A device whose volume macOS cannot set says so, rather than showing
        // a bar that does nothing.
        #expect(LevelRow(id: "s", kind: .sound, name: "LG HDR 4K", control: .fixed)
            .valueText == "Fixed")
        // And one that could not be read shows a dash, not a plausible 50% —
        // which is what the provider used to publish for an unreadable level.
        #expect(LevelRow(id: "d", kind: .display, name: "Built-in Display",
                         control: .unreadable).valueText == "—")
    }

    @Test("Rounding is to the nearest whole number, not toward zero")
    func rounding() {
        // 0.555 drawn as 55 and then set to 0.55 is a control that loses a
        // point every time it is touched.
        #expect(sound(0.555).valueText == "56")
        #expect(sound(0.554).valueText == "55")
        #expect(sound(0.005).valueText == "1")
    }

    // MARK: - What can be dragged

    @Test("Only a level can be dragged")
    func whatIsAdjustable() {
        #expect(sound(0.5).isAdjustable)
        #expect(!LevelRow(id: "s", kind: .sound, name: "x", control: .fixed).isAdjustable)
        #expect(!LevelRow(id: "d", kind: .display, name: "x", control: .unreadable).isAdjustable)
        // And a row with no line has no level to draw.
        #expect(LevelRow(id: "s", kind: .sound, name: "x", control: .fixed).drawnLevel == nil)
        #expect(sound(0.4).drawnLevel == 0.4)
    }

    @Test("A muted output keeps the level unmuting goes back to")
    func muteKeepsItsLevel() {
        // macOS keeps the scalar at its pre-mute value, and the card draws it
        // as a ghost so it is clear where unmuting lands. Zeroing it here
        // would lose the one fact the ghost exists to carry.
        let muted = sound(0.55, muted: true)
        #expect(muted.drawnLevel == 0.55)
        #expect(muted.isMuted)
    }

    // MARK: - The floor

    @Test("A gesture lands at the row's floor, never below it")
    func theFloorClampsTheGesture() {
        // An external display is dimmed with a gamma ramp rather than a
        // backlight, so below the floor the picture is unreadable and the
        // controller clamps there. The card used to draw an empty bar over a
        // screen sitting at 18%.
        let external = LevelRow(id: "d2", kind: .display, name: "Dell U2723QE",
                                control: .level(0.6), floor: 0.18)
        #expect(external.clamped(0) == 0.18)
        #expect(external.clamped(0.1) == 0.18)
        #expect(external.clamped(0.18) == 0.18)
        #expect(external.clamped(0.5) == 0.5)
        #expect(external.clamped(1.4) == 1, "and never above the top either")
    }

    @Test("A row with no floor reaches zero")
    func noFloorMeansNoFloor() {
        // The built-in panel has a real backlight and goes dark. Clamping it
        // at an external display's floor would take a quarter of its range
        // away for a reason that is not about it.
        #expect(sound(0.5).clamped(0) == 0)
        #expect(LevelRow(id: "d", kind: .display, name: "Built-in Display",
                         control: .level(0.8)).clamped(0) == 0)
    }

    // MARK: - What a row says

    @Test("Every note has a sentence, and each says what would change it")
    func everyNoteSpeaks() {
        let notes: [LevelRow.Note] = [
            .refused, .partial, .gamma(floor: 0.18), .fixedElsewhere,
            .unreadable, .setsItsOwn, .unavailable, .noOutput
        ]
        for note in notes {
            let text = LevelCopy.note(note)
            #expect(!text.isEmpty, "\(note) has nothing to say")
            #expect(text.hasSuffix("."), "\(note) is not a sentence")
            #expect(text.count < 80, "\(note) is too long for a card 275 points wide")
        }
    }

    @Test("The gamma sentence names the floor it is about")
    func theGammaSentenceNamesItsFloor() {
        // A sentence that said "there is a floor" without saying where would
        // leave somebody dragging at the stop wondering what was wrong.
        #expect(LevelCopy.note(.gamma(floor: 0.18)).contains("18%"))
        #expect(LevelCopy.note(.gamma(floor: 0.25)).contains("25%"))
    }
}
