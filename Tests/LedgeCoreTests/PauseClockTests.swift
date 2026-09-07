import Foundation
import LedgeCore
import Testing

/// The pause is dated once, and the date outlives the card.
@Suite("When a paused track was paused")
struct PauseClockTests {

    private let track = "com.spotify.client|track-1"
    private let other = "com.spotify.client|track-2"

    @Test("A pause is dated when it starts, and keeps that date while it lasts")
    func datedOnce() {
        var clock = PauseClock()
        #expect(clock.pausedSince(track, continuing: false, now: 1_000) == 1_000)
        // Still the same pause, read again a minute later.
        #expect(clock.pausedSince(track, continuing: true, now: 1_060) == 1_000)
        #expect(clock.pausedSince(track, continuing: true, now: 1_600) == 1_000)
    }

    /// The reels report: the browser takes the now-playing slot and gives it
    /// back, the card is retracted and republished, and the pause used to be
    /// re-dated each time — so it never aged out of the cycle.
    @Test("An interruption does not re-date the pause")
    func interruptionKeepsTheDate() {
        var clock = PauseClock()
        #expect(clock.pausedSince(track, continuing: false, now: 1_000) == 1_000)

        for gap in stride(from: 1_100, through: 1_400, by: 100) {
            // The card goes away and comes back; `continuing` is false because
            // the provider's last-seen track was cleared with the card.
            clock.cardWentAway()
            #expect(clock.pausedSince(track, continuing: false, now: TimeInterval(gap)) == 1_000)
        }
    }

    @Test("Playing again buys a fresh date")
    func playingResets() {
        var clock = PauseClock()
        #expect(clock.pausedSince(track, continuing: false, now: 1_000) == 1_000)
        clock.playing(track)
        #expect(clock.pausedSince(track, continuing: false, now: 1_500) == 1_500)
    }

    @Test("A retired card starts over next time")
    func retiredForgets() {
        var clock = PauseClock()
        _ = clock.pausedSince(track, continuing: false, now: 1_000)
        clock.retired(track)
        #expect(clock.pausedSince(track, continuing: false, now: 2_000) == 2_000)
    }

    @Test("Two tracks are dated separately")
    func perTrack() {
        var clock = PauseClock()
        #expect(clock.pausedSince(track, continuing: false, now: 1_000) == 1_000)
        #expect(clock.pausedSince(other, continuing: false, now: 1_200) == 1_200)
        // Coming back to the first one does not inherit the second one's date,
        // nor the other way round.
        #expect(clock.pausedSince(track, continuing: false, now: 1_300) == 1_000)
        #expect(clock.pausedSince(other, continuing: false, now: 1_400) == 1_200)
    }

    @Test("A track skipped to while paused is a new pause, not the old one")
    func skippingWhilePausedIsNew() {
        var clock = PauseClock()
        _ = clock.pausedSince(track, continuing: false, now: 1_000)
        // Somebody at the keyboard: a different track, still paused. It is not
        // continuing anything.
        #expect(clock.pausedSince(other, continuing: false, now: 1_050) == 1_050)
    }
}
