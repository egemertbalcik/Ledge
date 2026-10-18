import Foundation
import Testing

@testable import LedgeSystem

/// A stand-in for a player's process, because a real running application
/// cannot be started in a test and the whole point here is the case where the
/// lookup and the process disagree.
private final class FakeProcess: PlayerProcess {
    var isTerminated: Bool
    init(isTerminated: Bool = false) { self.isTerminated = isTerminated }
}

/// `#expect` cannot call a mutating member, so every answer is taken first and
/// asserted after.
@Suite("Whether a player counts as running")
struct PlayerLivenessTests {

    private let spotify = "com.spotify.client"

    @Test("A player the lookup finds is running")
    func foundIsRunning() {
        var liveness = PlayerLiveness()
        let answer = liveness.isRunning(spotify, found: FakeProcess())
        #expect(answer)
    }

    @Test("A player never seen is not running")
    func unseenIsNotRunning() {
        var liveness = PlayerLiveness()
        let answer = liveness.isRunning(spotify, found: nil)
        #expect(!answer)
    }

    /// The blink: one empty answer in the middle of a run of good ones, while
    /// the process sits there untouched.
    @Test("An empty answer does not retire a process that is still alive")
    func blinkIsSurvived() {
        var liveness = PlayerLiveness()
        let process = FakeProcess()
        let seen = liveness.isRunning(spotify, found: process)
        let firstBlink = liveness.isRunning(spotify, found: nil)
        let secondBlink = liveness.isRunning(spotify, found: nil)
        let back = liveness.isRunning(spotify, found: process)
        #expect(seen)
        #expect(firstBlink)
        #expect(secondBlink)
        #expect(back)
    }

    @Test("An empty answer from a process that has quit is believed")
    func terminatedIsBelieved() {
        var liveness = PlayerLiveness()
        let process = FakeProcess()
        let seen = liveness.isRunning(spotify, found: process)
        process.isTerminated = true
        let afterQuitting = liveness.isRunning(spotify, found: nil)
        #expect(seen)
        #expect(!afterQuitting)
    }

    /// Once a player has genuinely gone, its dead process must not be the
    /// thing that answers for the next one — or for the rest of the session.
    @Test("A quit player is forgotten rather than answered by its dead process")
    func terminatedIsForgotten() {
        var liveness = PlayerLiveness()
        let old = FakeProcess()
        let seen = liveness.isRunning(spotify, found: old)
        old.isTerminated = true
        let afterQuitting = liveness.isRunning(spotify, found: nil)
        // Still gone, and not because the old object happens to say so.
        let stillGone = liveness.isRunning(spotify, found: nil)

        // The user opens Spotify again: a new process, remembered on its own
        // terms, and it survives a blink of its own.
        let reopened = liveness.isRunning(spotify, found: FakeProcess())
        let blinkAfterReopening = liveness.isRunning(spotify, found: nil)

        #expect(seen)
        #expect(!afterQuitting)
        #expect(!stillGone)
        #expect(reopened)
        #expect(blinkAfterReopening)
    }

    @Test("Players are remembered separately")
    func playersAreIndependent() {
        var liveness = PlayerLiveness()
        let spotifySeen = liveness.isRunning(spotify, found: FakeProcess())
        // Music has never been seen, so Spotify's process cannot vouch for it.
        let music = liveness.isRunning("com.apple.Music", found: nil)
        #expect(spotifySeen)
        #expect(!music)
    }
}
