import Foundation
import LedgeCore
import Testing

/// A fraction is a position in a particular song's length. Carried without the
/// song it was measured against, it goes on being drawn against the next one —
/// which is a position that means nothing about anything.
@Suite("A scrub holds on to the song it grabbed")
struct ScrubGripTests {

    private let song = "com.apple.Music|song-1"
    private let next = "com.apple.Music|song-2"

    @Test("With no pointer on it, the bar shows nothing of its own")
    func idleDrawsNothing() {
        let grip = ScrubGrip()
        #expect(grip.displayed(on: song) == nil)
        #expect(!grip.isHeld)
        #expect(grip.grabbedItem == nil)
    }

    @Test("A drag follows the finger, and says which song it is about")
    func followsTheFinger() {
        var grip = ScrubGrip()
        grip.moved(to: 0.25, on: song)
        #expect(grip.displayed(on: song) == 0.25)
        #expect(grip.grabbedItem == song)
        grip.moved(to: 0.6, on: song)
        #expect(grip.displayed(on: song) == 0.6)
        #expect(grip.isHeld)
    }

    @Test("A fraction off the ends of the bar is clamped")
    func clamped() {
        var grip = ScrubGrip()
        grip.moved(to: -0.4, on: song)
        #expect(grip.displayed(on: song) == 0)
        grip.moved(to: 1.8, on: song)
        #expect(grip.displayed(on: song) == 1)
    }

    @Test("A track change under the pointer stops the bar drawing the old position")
    func itemChangeStopsDrawing() {
        // The track ran out while it was being scrubbed. The fraction was a
        // position in the old song's length; drawn against the new one it is
        // simply a lie, and it used to stay there until the finger lifted.
        var grip = ScrubGrip()
        grip.moved(to: 0.8, on: song)
        grip.itemChanged()

        #expect(grip.displayed(on: next) == nil, "the old song's position was drawn against the new one")
        #expect(grip.displayed(on: song) == nil)
        #expect(grip.isHeld, "the pointer is still down")
    }

    @Test("Letting go after a track change seeks nothing")
    func releaseAfterItemChangeActsOnNothing() {
        var grip = ScrubGrip()
        grip.moved(to: 0.8, on: song)
        grip.itemChanged()
        #expect(grip.released(on: next) == nil, "the new song was seeked to a place nobody chose")
        #expect(!grip.isHeld)
    }

    @Test("A drag that outlives its song is not handed to the next one")
    func abandonedGripDoesNotResume() {
        // The pointer keeps moving after the track changed. That is still the
        // drag the user began on the song before — not a request to scrub the
        // one that replaced it.
        var grip = ScrubGrip()
        grip.moved(to: 0.8, on: song)
        grip.itemChanged()
        grip.moved(to: 0.3, on: next)

        #expect(grip.displayed(on: next) == nil)
        #expect(grip.released(on: next) == nil)
    }

    @Test("A move arriving under a different song abandons the grip by itself")
    func unseenItemChangeIsStillCaught() {
        var grip = ScrubGrip()
        grip.moved(to: 0.8, on: song)
        grip.moved(to: 0.85, on: next)
        #expect(grip.displayed(on: next) == nil)
        #expect(grip.released(on: next) == nil)
    }

    @Test("Letting go on the song it grabbed gives back the position")
    func releaseGivesBackTheFraction() {
        var grip = ScrubGrip()
        grip.moved(to: 0.42, on: song)
        #expect(grip.released(on: song) == 0.42)
        #expect(!grip.isHeld)
        #expect(grip.displayed(on: song) == nil)
    }

    @Test("Letting go against a song the grip never grabbed gives nothing back")
    func releaseAgainstAnotherSongActsOnNothing() {
        // The pointer lifts in the same turn the track changes, and the card
        // reads the song from the payload it is drawing. Which of the two
        // arrives first is SwiftUI's business, so the release has to be able
        // to say no on its own rather than trusting that `itemChanged` was
        // seen first.
        var grip = ScrubGrip()
        grip.moved(to: 0.8, on: song)
        #expect(grip.released(on: next) == nil, "the new song was seeked to a place nobody chose")
        #expect(!grip.isHeld)
    }

    @Test("Letting go twice gives nothing back the second time")
    func releaseIsOnce() {
        var grip = ScrubGrip()
        grip.moved(to: 0.42, on: song)
        _ = grip.released(on: song)
        #expect(grip.released(on: song) == nil)
    }

    @Test("A pointer that is down is visible to anything else that would move the bar")
    func heldIsVisibleToOtherWaysIn() {
        // VoiceOver's step is the other way in. Running while a drag is in
        // flight, the two disagreed: the step moved the player while the drag
        // went on drawing the finger, and the drag's own seek then landed on
        // top of it.
        var grip = ScrubGrip()
        #expect(!grip.isHeld)
        grip.moved(to: 0.5, on: song)
        #expect(grip.isHeld)
        grip.itemChanged()
        #expect(grip.isHeld, "the song went, but the finger is still down")
        _ = grip.released(on: next)
        #expect(!grip.isHeld)
    }
}
