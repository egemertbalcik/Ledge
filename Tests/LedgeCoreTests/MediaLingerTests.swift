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
        linger.nothingRests(now: 1_000)
        // Past the grace it is a stranger again, which is the point of the
        // rule: a track that went away and comes back paused inherits nothing.
        let later = 1_000 + MediaLinger.unknownGrace + 1
        #expect(linger.paused(track, full: full, now: later) == .neverRested)
    }

    /// The gap between a track playing and the first paused reading of it. The
    /// source can go quiet in between — a native player with no scripting
    /// fallback does exactly this — and the pause that follows had no deadline
    /// to protect it.
    @Test("A track that went quiet a moment ago still gets its stay")
    func aBriefAbsenceKeepsTheClaim() {
        var linger = MediaLinger()
        linger.nowResting(track)
        linger.nothingRests(now: 1_000)
        #expect(linger.paused(track, full: full, now: 1_001) == .stays(full))
    }

    @Test("The grace is timed from the silence, not from when the track played")
    func theGraceRunsFromTheAbsence() {
        var linger = MediaLinger()
        linger.nowResting(track)
        // The track played for an hour before anything went quiet.
        linger.nothingRests(now: 4_600)
        #expect(linger.paused(track, full: full, now: 4_602) == .stays(full))
    }

    @Test("Playing again clears a pending absence")
    func playingClearsTheAbsence() {
        var linger = MediaLinger()
        linger.nowResting(track)
        linger.nothingRests(now: 1_000)
        // It came back playing rather than paused.
        linger.nowResting(track)
        // Long past the grace, but it has been resting the whole time since.
        #expect(linger.paused(track, full: full, now: 1_100) == .stays(full))
    }

    /// The blink: the player drops out of the running-application list for one
    /// poll, the card is retracted, the island is told nothing rests — and the
    /// track is back half a second later with 119 seconds still owed to it.
    @Test("A stay already running survives the island going quiet")
    func runningStaySurvivesABlink() {
        var linger = MediaLinger()
        linger.nowResting(track)
        #expect(linger.paused(track, full: full, now: 1_000) == .stays(120))

        linger.nothingRests(now: 1_000.5)
        #expect(linger.paused(track, full: full, now: 1_001) == .stays(119))
    }

    @Test("A stay that has run out is forgotten when nothing rests")
    func spentStayIsStillForgotten() {
        var linger = MediaLinger()
        linger.nowResting(track)
        #expect(linger.paused(track, full: full, now: 1_000) == .stays(120))

        // The stay ran out while the track sat there paused, and only then did
        // the island go quiet. Nothing is owed any more, so the same track
        // turning up hours later is a stranger again.
        linger.nothingRests(now: 1_200)
        #expect(linger.paused(track, full: full, now: 9_000) == .neverRested)
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
