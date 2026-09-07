import Foundation
import LedgeCore
import Testing

/// The three failures this rule was learned from, one test each.
@Suite("A paused track's place in the ears")
struct MediaLingerTests {

    private let track = "com.spotify.client|track-1"
    private let other = "com.spotify.client|track-2"
    private let full: TimeInterval = 120

    @Test("A track that was never resting gets nothing")
    func neverRestedIsRefused() {
        var linger = MediaLinger()
        // Something else was resting — or nothing was.
        linger.nowResting(other)
        #expect(linger.paused(track, full: full, now: 1_000) == .neverRested)

        var fresh = MediaLinger()
        #expect(fresh.paused(track, full: full, now: 1_000) == .neverRested)
    }

    @Test("The track that was resting keeps the ears when it stops")
    func theRestingTrackStays() {
        var linger = MediaLinger()
        linger.nowResting(track)
        #expect(linger.paused(track, full: full, now: 1_000) == .stays(full))
    }

    /// The reels report: the browser hands the now-playing slot back between
    /// clips, the paused card is republished on every hand-back, and each of
    /// those used to start the whole stay again.
    @Test("Interruptions resume the same stay rather than restarting it")
    func interruptionsResumeTheStay() {
        var linger = MediaLinger()
        linger.nowResting(track)
        #expect(linger.paused(track, full: full, now: 1_000) == .stays(120))

        // Forty seconds later, republished.
        #expect(linger.paused(track, full: full, now: 1_040) == .stays(80))
        // And again, thirty after that.
        #expect(linger.paused(track, full: full, now: 1_070) == .stays(50))
        // Past the deadline it has had its turn, however many times it comes
        // back.
        #expect(linger.paused(track, full: full, now: 1_121) == .spent)
        #expect(linger.paused(track, full: full, now: 1_200) == .spent)
        #expect(linger.paused(track, full: full, now: 2_000) == .spent)
    }

    @Test("Playing again buys a fresh stay")
    func playingAgainRefills() {
        var linger = MediaLinger()
        linger.nowResting(track)
        #expect(linger.paused(track, full: full, now: 1_000) == .stays(120))
        #expect(linger.paused(track, full: full, now: 1_200) == .spent)

        // The user presses play, listens, and pauses again.
        linger.nowResting(track)
        #expect(linger.paused(track, full: full, now: 1_300) == .stays(120))
    }

    @Test("When nothing rests, the last resting track is forgotten")
    func nothingRestingForgets() {
        var linger = MediaLinger()
        linger.nowResting(track)
        linger.nothingRests()
        #expect(linger.paused(track, full: full, now: 1_000) == .neverRested)
    }

    @Test("Two tracks keep their own clocks")
    func perTrackDeadlines() {
        var linger = MediaLinger()
        linger.nowResting(track)
        #expect(linger.paused(track, full: full, now: 1_000) == .stays(120))

        // A different track plays and pauses; the first one's spent stay is
        // not what the second one inherits.
        linger.nowResting(other)
        #expect(linger.paused(other, full: full, now: 1_500) == .stays(120))
        // And the first one is no longer the resting track at all.
        #expect(linger.paused(track, full: full, now: 1_500) == .neverRested)
    }
}
