import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// Which device the Levels card writes to.
///
/// The card snapshots an output when it opens and aims every adjustment at
/// that id. Arriving readouts moved the number on screen and never the
/// identity behind it, so plugging in headphones while the card stayed open
/// left it showing one device's volume and moving another's — invisible at the
/// time, because both look like a slider that works.
@Suite("Levels write target")
struct LevelsTargetTests {

    private func speakers(current: Bool, level: Double = 0.3) -> AudioOutputOption {
        AudioOutputOption(id: 1, name: "MacBook Speakers", isCurrent: current, level: level)
    }

    private func headphones(current: Bool, level: Double = 0.8) -> AudioOutputOption {
        AudioOutputOption(id: 2, name: "AirPods Pro", isCurrent: current, level: level)
    }

    /// The regression: the system's output changes underneath an open card.
    @Test("An output switch moves the target, and brings its level along")
    func switchWhileOpen() {
        let opened = speakers(current: true)
        let after = LevelsCardView.retarget(
            current: opened,
            outputs: [speakers(current: false), headphones(current: true)]
        )
        #expect(after.output?.id == 2, "the card now writes to the headphones")
        #expect(after.adoptLevel, "and shows their level, not the speakers'")
        #expect(after.output?.level == 0.8)
    }

    /// The other half: nothing changed, so the live readout keeps the number
    /// and this must not overwrite it mid-animation.
    @Test("The same device does not reclaim the level")
    func sameDeviceKeepsTheLiveLevel() {
        let opened = speakers(current: true, level: 0.3)
        let after = LevelsCardView.retarget(
            current: opened,
            outputs: [speakers(current: true, level: 0.45), headphones(current: false)]
        )
        #expect(after.output?.id == 1)
        #expect(!after.adoptLevel, "the readout owns the number while the device is unchanged")
    }

    @Test("A device that goes away leaves the card pointed at what is left")
    func deviceDisappears() {
        let opened = headphones(current: true)
        let after = LevelsCardView.retarget(
            current: opened,
            outputs: [speakers(current: true)]
        )
        #expect(after.output?.id == 1)
        #expect(after.adoptLevel)
    }

    /// Unplugging the last output: there is nothing to write to, and the card
    /// must not go on aiming at an id that no longer exists.
    @Test("With no outputs at all the card points at nothing")
    func noOutputs() {
        let after = LevelsCardView.retarget(current: speakers(current: true), outputs: [])
        #expect(after.output == nil)
        #expect(after.adoptLevel, "so the bar drops rather than showing a dead device's level")
    }

    @Test("With nothing marked current, the first output is the one")
    func noCurrentFlag() {
        let after = LevelsCardView.retarget(
            current: nil,
            outputs: [speakers(current: false), headphones(current: false)]
        )
        #expect(after.output?.id == 1)
    }

    /// Opening on a machine whose devices are not enumerated yet, then having
    /// them arrive.
    @Test("A card that opened on nothing adopts the first device that appears")
    func adoptsAfterEmptyStart() {
        let after = LevelsCardView.retarget(current: nil, outputs: [headphones(current: true)])
        #expect(after.output?.id == 2)
        #expect(after.adoptLevel)
    }

    // MARK: - The gap polling leaves

    /// The reported race, as the rule it is made of: the output switches, and
    /// an adjustment begins before the next poll. Beginning re-reads, so the
    /// first write of that interaction belongs to the device that is current
    /// now — not to the one the card last looked at.
    @Test("An interaction beginning before the next poll reads the devices first")
    func beginningRefreshesTheTarget() {
        var enumerations = 0
        let after = LevelsCardView.interactionTarget(holding: nil) {
            enumerations += 1
            // The switch has already happened; the timer has not ticked.
            return [self.speakers(current: false), self.headphones(current: true)]
        }
        #expect(enumerations == 1, "beginning reads")
        #expect(after?.id == 2, "and the first write of the drag lands on the new output")
    }

    /// The other half of the same rule. Re-reading *during* a drag would move
    /// the target under the hand, which is the same failure seen from the
    /// other side.
    @Test("A drag in progress keeps its target and reads nothing")
    func dragHoldsItsTarget() {
        var enumerations = 0
        let held = headphones(current: true)
        let after = LevelsCardView.interactionTarget(holding: held) {
            enumerations += 1
            return [self.speakers(current: true), self.headphones(current: false)]
        }
        #expect(enumerations == 0, "a gesture in flight does not re-read")
        #expect(after?.id == held.id, "and writes where it started")
    }

    @Test("Beginning with nothing plugged in targets nothing")
    func beginningWithNoDevices() {
        let after = LevelsCardView.interactionTarget(holding: nil) { [] }
        #expect(after == nil)
    }
}

/// A bar that moves when nothing moved is the control lying. The device is
/// free to clamp a scalar to its nearest step or refuse it outright, so what
/// the bar shows after a write is the hardware's answer, not the gesture's.
@Suite("Adopting what the device answered")
@MainActor
struct LevelFeedbackAdoptionTests {

    @Test("A clamped write shows where the output really landed")
    func clampedWriteShows() {
        let shown = LevelsCardView.adopting(
            LevelFeedback(level: 0.062, isMuted: false), requested: 0, wasMuted: false
        )
        #expect(shown.level == 0.062)
        #expect(shown.isMuted == false)
    }

    @Test("A refused write leaves the bar at the level the device kept")
    func refusedWriteShows() {
        let shown = LevelsCardView.adopting(
            LevelFeedback(level: 0.9, isMuted: true), requested: 0.2, wasMuted: true
        )
        #expect(shown.level == 0.9, "the old level, because the write did not take")
        #expect(shown.isMuted, "and it is still muted")
    }

    @Test("A muted answer shows as muted")
    func mutedAnswerShows() {
        let shown = LevelsCardView.adopting(
            LevelFeedback(level: 0.5, isMuted: true), requested: 0.5, wasMuted: false
        )
        #expect(shown.isMuted)
    }

    /// No answer at all — no such output — keeps the gesture's own value
    /// rather than snapping the bar to zero under the pointer.
    @Test("No answer keeps the gesture's value")
    func noAnswerKeepsTheGesture() {
        let shown = LevelsCardView.adopting(nil, requested: 0.4, wasMuted: true)
        #expect(shown.level == 0.4)
        #expect(shown.isMuted == false, "raising unmutes, as it always did")
    }

    @Test("Out-of-range requests are clamped either way")
    func clampsRequests() {
        #expect(LevelsCardView.adopting(nil, requested: 4, wasMuted: false).level == 1)
        #expect(LevelsCardView.adopting(nil, requested: -1, wasMuted: false).level == 0)
        #expect(LevelFeedback(level: .nan, isMuted: false).level == 0)
    }
}
