import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// Which shape the bars are drawing, as opposed to how much they are moving.
///
/// Playing used to decide both. The seed was cleared the moment a track
/// paused, so the bars had no levels and fell back to a plain sine — and
/// pressing Play ran that sine for as long as the player took to confirm,
/// then snapped to the track's own pattern. Two animations stitched together,
/// which is exactly what it looked like.
@Suite("A loaded track keeps its waveform")
@MainActor
struct WaveformSeedTests {

    private func song(_ title: String, playing: Bool) -> Activity {
        Activity(
            id: ActivityID(kind: .nowPlaying, source: "com.spotify.client"),
            createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(
                title: title,
                artist: "Murda",
                isPlaying: playing,
                sourceName: "Spotify",
                itemKey: "spotify:track:\(title)"
            ))
        )
    }

    @Test("A playing track has levels of its own")
    func playingHasLevels() {
        let presentation = NotchPresentation()
        presentation.nowPlaying = song("karambol", playing: true)
        #expect(presentation.simulatedAudioLevels(at: 1_000).count == 6)
    }

    /// The seam the owner noticed: Play is accepted and drawn before the
    /// player confirms, and during that window the payload is still paused.
    @Test("A paused track keeps the same levels, so Play has nothing to switch to")
    func pausedKeepsItsLevels() {
        let presentation = NotchPresentation()
        presentation.nowPlaying = song("karambol", playing: false)
        let whilePaused = presentation.simulatedAudioLevels(at: 1_000)
        #expect(whilePaused.count == 6)

        presentation.nowPlaying = song("karambol", playing: true)
        let whilePlaying = presentation.simulatedAudioLevels(at: 1_000)
        #expect(whilePlaying == whilePaused)
    }

    @Test("A different song gets a different shape")
    func eachSongHasItsOwnShape() {
        let presentation = NotchPresentation()
        presentation.nowPlaying = song("karambol", playing: true)
        let first = presentation.simulatedAudioLevels(at: 1_000)
        presentation.nowPlaying = song("Nereden", playing: true)
        let second = presentation.simulatedAudioLevels(at: 1_000)
        #expect(first.count == 6)
        #expect(second.count == 6)
        #expect(first != second)
    }

    @Test("With no track there is nothing to draw")
    func noTrackNoLevels() {
        let presentation = NotchPresentation()
        presentation.nowPlaying = song("karambol", playing: true)
        #expect(presentation.simulatedAudioLevels(at: 1_000).count == 6)
        presentation.nowPlaying = nil
        #expect(presentation.simulatedAudioLevels(at: 1_000).isEmpty)
    }
}

/// What the compact bars are drawing while they settle.
///
/// Pausing used to drop the live levels for the whole stop ramp, so the bars
/// did not sink from where they were: they jumped to the fallback sine and
/// sank from there. At a fixed clock the first bar read 4.42 pt immediately
/// before the pause and 13.49 pt on the very next frame — a swell, not a
/// settle. Whatever shape was last drawn is the shape that settles.
@Suite("The compact bars settle from where they were")
@MainActor
struct MiniWaveformSettleTests {

    private let levels: [Double] = [0.9, 0.1, 0.6, 0.2, 0.8, 0.3]
    private let at = Date(timeIntervalSinceReferenceDate: 1_000)

    private func waveform(isAnimating: Bool) -> MiniWaveform {
        MiniWaveform(isAnimating: isAnimating, tint: .white, levels: { self.levels })
    }

    @Test("Stopping does not change which shape is being drawn")
    func theShapeSurvivesThePause() {
        // Same amplitude on both sides, so any difference is the shape alone.
        let playing = waveform(isAnimating: true).heights(at: at, amplitude: 1)
        let settling = waveform(isAnimating: false).heights(at: at, amplitude: 1)
        #expect(playing == settling)
    }

    @Test("The bars follow the track's levels rather than a plain sine")
    func theLevelsAreWhatIsDrawn() {
        let drawn = waveform(isAnimating: true).heights(at: at, amplitude: 1)
        let expected = levels.map { 3 + CGFloat(min(max($0, 0), 1)) * 11 }
        #expect(drawn == expected)
    }

    @Test("Amplitude is what the settle moves")
    func amplitudeLowersTheSameShape() {
        let full = waveform(isAnimating: false).heights(at: at, amplitude: 1)
        let half = waveform(isAnimating: false).heights(at: at, amplitude: 0.5)
        // Every bar is nearer the resting line, and none has grown.
        #expect(zip(full, half).allSatisfy { $1 <= $0 })
        #expect(half != full)
    }

    @Test("At rest every bar is on the line")
    func zeroAmplitudeRests() {
        let resting = waveform(isAnimating: false).heights(at: at, amplitude: 0)
        #expect(resting.allSatisfy { $0 == 3 })
    }
}

/// Keep Awake is announced, not resident.
///
/// The owner's report, both halves: the cup stayed in the leading ear for the
/// whole hold, and a disc with the same cup appeared beside it — one fact said
/// twice. It came back through the last rung of `CompactRest`, because a hold
/// that has just been started is the selected card.
@Suite("Keep Awake is announced, then lives beside the island")
@MainActor
struct KeepAwakeRestTests {

    private func hold(running: Bool) -> Activity {
        Activity(
            id: ActivityID(kind: .keepAwake, source: "session"),
            createdAt: 0,
            payload: .keepAwake(KeepAwakePayload(
                phase: running ? .running : .ready,
                remaining: 600
            ))
        )
    }

    private func song() -> Activity {
        Activity(
            id: ActivityID(kind: .nowPlaying, source: "com.spotify.client"),
            createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(
                title: "karambol", artist: "Murda", isPlaying: true,
                sourceName: "Spotify", itemKey: "spotify:track:karambol"
            ))
        )
    }

    @Test("A running hold that is the selected card does not rest in the ears")
    func theSelectedHoldDoesNotComeBack() {
        let presentation = NotchPresentation()
        let session = hold(running: true)
        presentation.keepAwakeSession = session
        presentation.selected = session
        #expect(presentation.restingContent == nil)
    }

    @Test("The side readout carries a running hold")
    func theReadoutCarriesIt() {
        let presentation = NotchPresentation()
        presentation.keepAwakeSession = hold(running: true)
        #expect(presentation.liveKeepAwake != nil)
    }

    @Test("A hold that is not running is nowhere")
    func aReadyCardIsNowhere() {
        let presentation = NotchPresentation()
        presentation.keepAwakeSession = hold(running: false)
        #expect(presentation.liveKeepAwake == nil)
    }

    /// The cup beside the music is the case that should show: the island is
    /// held by something else and the hold is said once, in the readout.
    @Test("Beside music the hold takes the readout and the ears keep the music")
    func besideMusic() {
        let presentation = NotchPresentation()
        let session = hold(running: true)
        presentation.nowPlaying = song()
        presentation.keepAwakeSession = session
        presentation.selected = session
        #expect(presentation.restingContent?.id.kind == .nowPlaying)
        let readout = presentation.satellite(phase: .companion)
        #expect(readout == .keepAwake(remaining: 600))
    }

    /// The one time the ears do show a hold in the companion phase: the brief
    /// farewell after its card was open. Then the readout stays out of it.
    @Test("While the ears say goodbye to the hold, the readout does not repeat it")
    func theFarewellIsNotRepeated() {
        let presentation = NotchPresentation()
        let session = hold(running: true)
        presentation.keepAwakeSession = session
        presentation.farewell = session
        #expect(presentation.restingContent?.id.kind == .keepAwake)
        #expect(presentation.satellite(phase: .companion) == nil)
    }
}
