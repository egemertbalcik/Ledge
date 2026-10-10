import Foundation
import LedgeCore
import Testing

/// Where the scrub bar points between letting go and the player agreeing.
///
/// The reported symptom: the bar goes where you put it, jumps back to where it
/// started, and arrives a second later. The mechanism was a flat 600ms timer
/// from pointer release — which knows nothing about the player — after which
/// the bar followed the last reading, and the last reading was the position
/// before the drag.
@Suite("A scrub waits for the player, not for a clock")
struct SeekIntentTests {

    private let song = "com.apple.Music|song-1"
    private let other = "com.apple.Music|song-2"

    @Test("With nothing asked for, the player's own position is what shows")
    func idleFollowsThePlayer() {
        let intent = SeekIntent()
        #expect(intent.displayed(reported: 12, on: song, at: 100) == 12)
        #expect(!intent.isWaiting(at: 100))
    }

    @Test("An acknowledgement slower than the old timeout still holds the bar")
    func slowAcknowledgementHolds() {
        // The old rule let go after 600ms. Everything here happens later than
        // that, and the player has still not moved.
        var intent = SeekIntent()
        intent.asked(for: 150, from: 20, on: song, at: 100)

        for later in [100.7, 101.5, 103.0] {
            intent.reconcile(reported: 20, on: song, at: later)
            #expect(
                intent.displayed(reported: 20, on: song, at: later) == 150,
                "the bar fell back to the pre-seek position at \(later - 100)s"
            )
        }

        // And then the player arrives.
        intent.reconcile(reported: 150.4, on: song, at: 103.5)
        #expect(intent.displayed(reported: 150.4, on: song, at: 103.5) == 150.4)
        #expect(!intent.isWaiting(at: 103.5))
    }

    @Test("Arrival is remembered, so drifting on does not look like a miss")
    func arrivalIsSticky() {
        // Without remembering it, the player playing on past the target reads
        // as "not there yet" and the bar jumps backwards to the asked-for
        // position — the same backward jump, one second later.
        var intent = SeekIntent()
        intent.asked(for: 150, from: 20, on: song, at: 100)
        intent.reconcile(reported: 150, on: song, at: 101)
        intent.reconcile(reported: 156, on: song, at: 107)
        #expect(intent.displayed(reported: 156, on: song, at: 107) == 156)
    }

    @Test("A refused seek moves nothing")
    func refusalShowsNothing() {
        // The queue was full, so the player was never asked. A bar that moves
        // anyway is showing a position nothing is going to.
        var intent = SeekIntent()
        intent.asked(for: 150, from: 20, on: song, at: 100)
        intent.refused()
        #expect(intent.displayed(reported: 20, on: song, at: 100) == 20)
        #expect(!intent.isWaiting(at: 100))
    }

    @Test("Of two quick seeks the newer one wins, and the older cannot end it")
    func newerSeekWins() {
        var intent = SeekIntent()
        intent.asked(for: 30, from: 120, on: song, at: 100)
        intent.asked(for: 180, from: 30, on: song, at: 100.4)

        // The player answers the *first* seek. That is an old result, and it
        // must not clear the newer one.
        intent.reconcile(reported: 30, on: song, at: 101)
        #expect(
            intent.displayed(reported: 30, on: song, at: 101) == 180,
            "an older acknowledgement cleared a newer seek"
        )

        intent.reconcile(reported: 179, on: song, at: 102)
        #expect(intent.displayed(reported: 179, on: song, at: 102) == 179)
    }

    @Test("A song change clears the position, immediately")
    func itemChangeClearsAtOnce() {
        // Drawing the old song's position over its successor is how a skip
        // during a scrub showed the wrong place until a timer ran out.
        var intent = SeekIntent()
        intent.asked(for: 150, from: 20, on: song, at: 100)
        #expect(intent.displayed(reported: 3, on: other, at: 100.1) == 3)

        intent.reconcile(reported: 3, on: other, at: 100.1)
        #expect(!intent.isWaiting(at: 100.1))
    }

    @Test("An explicit song change clears it too")
    func explicitItemChange() {
        var intent = SeekIntent()
        intent.asked(for: 150, from: 20, on: song, at: 100)
        intent.itemChanged()
        #expect(intent.displayed(reported: 3, on: song, at: 100.1) == 3)
    }

    @Test("A seek nobody ever answers gives up, once")
    func deadlineEndsTheHold() {
        var intent = SeekIntent()
        intent.asked(for: 150, from: 20, on: song, at: 100)
        let justBefore = 100 + SeekIntent.deadline - 0.1
        #expect(intent.displayed(reported: 20, on: song, at: justBefore) == 150)

        let after = 100 + SeekIntent.deadline
        #expect(intent.displayed(reported: 20, on: song, at: after) == 20)
        intent.reconcile(reported: 20, on: song, at: after)
        #expect(!intent.isWaiting(at: after))
    }

    @Test("A nudge shorter than the tolerance is not held at all")
    func shortSeekIsNotHeld() {
        // The player is at 100 and the bar is nudged to 102. The first reading
        // back is the poll already in flight — still 100, because nothing has
        // happened yet — and it is inside the tolerance, so the hold ended
        // before the player moved and the bar snapped back to the start of the
        // drag. Two seconds of a three-minute track is a few pixels; showing
        // the player's own position from the outset cannot lie about them.
        var intent = SeekIntent()
        intent.asked(for: 102, from: 100, on: song, at: 1000)
        #expect(!intent.isWaiting(at: 1000))
        #expect(intent.displayed(reported: 100, on: song, at: 1000.2) == 100)
    }

    @Test("A seek just past the tolerance is still held")
    func seekJustPastTheToleranceHolds() {
        var intent = SeekIntent()
        intent.asked(for: 100 + SeekIntent.tolerance + 0.1, from: 100, on: song, at: 1000)
        #expect(intent.isWaiting(at: 1000))
        #expect(intent.displayed(reported: 100, on: song, at: 1000.2) != 100)
    }

    @Test("A backward nudge inside the tolerance is not held either")
    func shortBackwardSeekIsNotHeld() {
        var intent = SeekIntent()
        intent.asked(for: 98, from: 100, on: song, at: 1000)
        #expect(!intent.isWaiting(at: 1000))
    }

    @Test("A paused player is held exactly the same way")
    func pausedSeekIsNotSpecial() {
        // Nothing here reads the play state: a paused player moves its
        // position when asked and reports it on the next read, and the only
        // difference is that there is no drift afterwards.
        var intent = SeekIntent()
        intent.asked(for: 150, from: 20, on: song, at: 100)
        intent.reconcile(reported: 20, on: song, at: 102)
        #expect(intent.displayed(reported: 20, on: song, at: 102) == 150)
        intent.reconcile(reported: 150, on: song, at: 103)
        #expect(intent.displayed(reported: 150, on: song, at: 104) == 150)
    }
}
