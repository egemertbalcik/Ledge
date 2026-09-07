import Foundation
import Testing

@testable import LedgeCore

@Suite("HUD readout")
struct HUDReadoutTests {

    @Test("The level is clamped rather than trusted")
    func levelClamped() {
        // A device that reports slightly over 1.0 must not draw a bar wider
        // than its own track.
        #expect(HUDReadout(kind: .volume, level: 1.4).level == 1)
        #expect(HUDReadout(kind: .volume, level: -0.2).level == 0)
    }

    @Test("Percentage rounds rather than truncates")
    func percentageRounds() {
        #expect(HUDReadout(kind: .volume, level: 0.666).percentage == 67)
        #expect(HUDReadout(kind: .volume, level: 0.0625).percentage == 6)
        #expect(HUDReadout(kind: .volume, level: 1).percentage == 100)
    }

    @Test("The speaker glyph fills up with the level")
    func volumeGlyphFollowsLevel() {
        #expect(HUDReadout(kind: .volume, level: 0.2).symbolName == "speaker.wave.1.fill")
        #expect(HUDReadout(kind: .volume, level: 0.5).symbolName == "speaker.wave.2.fill")
        #expect(HUDReadout(kind: .volume, level: 0.9).symbolName == "speaker.wave.3.fill")
    }

    @Test("Silence and mute both show the crossed-out speaker")
    func mutedGlyph() {
        #expect(HUDReadout(kind: .volume, level: 0).symbolName == "speaker.slash.fill")
        // Muted at a non-zero level still reads as muted, which is the state
        // the user actually cares about.
        #expect(HUDReadout(kind: .volume, level: 0.8, isMuted: true).symbolName == "speaker.slash.fill")
    }

    @Test("Brightness and backlight have their own glyphs")
    func otherGlyphs() {
        #expect(HUDReadout(kind: .brightness, level: 0.2).symbolName == "sun.min.fill")
        #expect(HUDReadout(kind: .brightness, level: 0.8).symbolName == "sun.max.fill")
        #expect(HUDReadout(kind: .keyboardBacklight, level: 0).symbolName == "keyboard")
        #expect(HUDReadout(kind: .keyboardBacklight, level: 0.5).symbolName == "keyboard.fill")
    }

    @Test("Mute is ignored for kinds where it has no meaning")
    func muteOnlyAffectsVolume() {
        let brightness = HUDReadout(kind: .brightness, level: 0.8, isMuted: true)
        #expect(brightness.symbolName == "sun.max.fill")
    }
}

@Suite("Level glyph ladders")
struct LevelGlyphTests {

    @Test("Brightness climbs two rungs, both solid")
    func brightnessLadder() {
        let dim = HUDReadout.brightnessSymbol(level: 0.1)
        let full = HUDReadout.brightnessSymbol(level: 0.95)
        #expect(dim == "sun.min.fill")
        #expect(full == "sun.max.fill")
        #expect(dim != full, "the rungs have to look different or the glyph says nothing")
        // The outlined sun is deliberately not a rung: it read as a different
        // kind of glyph rather than a dimmer one.
        #expect(HUDReadout.brightnessSymbol(level: 0.2) != "sun.min")
    }

    @Test("Brightness turns at the speaker's middle")
    func laddersStepTogether() {
        // The two bars sit one above the other; a glyph that changed nowhere
        // near the other's steps read as one of them being wrong.
        #expect(HUDReadout.brightnessSymbol(level: 0.49) != HUDReadout.brightnessSymbol(level: 0.51))
        #expect(HUDReadout.volumeSymbol(level: 0.66, isMuted: false)
                != HUDReadout.volumeSymbol(level: 0.68, isMuted: false))
    }

    @Test("A display is never off, so brightness has no slashed rung")
    func brightnessHasNoOffState() {
        #expect(HUDReadout.brightnessSymbol(level: 0) == "sun.min.fill")
        #expect(HUDReadout.volumeSymbol(level: 0, isMuted: false) == "speaker.slash.fill")
    }

    @Test("Muted wins over whatever the scalar says")
    func mutedWins() {
        #expect(HUDReadout.volumeSymbol(level: 0.9, isMuted: true) == "speaker.slash.fill")
    }

    @Test("The readout's own glyph comes from the same ladders")
    func readoutUsesTheLadders() {
        #expect(HUDReadout(kind: .brightness, level: 0.2).symbolName == "sun.min.fill")
        #expect(HUDReadout(kind: .volume, level: 0.8).symbolName == "speaker.wave.3.fill")
    }
}
