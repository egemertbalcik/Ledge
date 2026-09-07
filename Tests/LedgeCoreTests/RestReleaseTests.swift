import Foundation
import LedgeCore
import Testing

@Suite("A rest waits for the guest beside it")
struct RestReleaseTests {

    @Test("With the island to itself, a finished rest ends immediately")
    func aloneReleasesAtOnce() {
        var release = RestRelease()
        let ended = release.release(hasGuest: false)
        #expect(ended)
        #expect(release.isPending == false)
    }

    /// The reported sequence: a paused track resting, a brightness readout
    /// beside it, and the linger running out underneath — which took the track
    /// away mid-readout and left the next keypress drawing the readout across
    /// the whole compact view.
    @Test("With a guest beside it, the rest is deferred until the guest leaves")
    func guestDefersTheRelease() {
        var release = RestRelease()
        let endedAtOnce = release.release(hasGuest: true)
        #expect(endedAtOnce == false)
        #expect(release.isPending)
        // Repeat key presses keep the readout up; the rest keeps waiting.
        let endedWhileGuestStayed = release.flush(hasGuest: true)
        #expect(endedWhileGuestStayed == false)
        #expect(release.isPending)
        // The readout goes, and the two leave together.
        let endedWithTheGuest = release.flush(hasGuest: false)
        #expect(endedWithTheGuest)
        #expect(release.isPending == false)
    }

    @Test("Deferring twice does not owe two releases")
    func deferralIsIdempotent() {
        var release = RestRelease()
        _ = release.release(hasGuest: true)
        _ = release.release(hasGuest: true)
        let paid = release.flush(hasGuest: false)
        #expect(paid)
        let paidTwice = release.flush(hasGuest: false)
        #expect(paidTwice == false, "the debt was already paid")
    }

    @Test("Nothing is owed when nothing was deferred")
    func flushWithoutDeferralIsANoOp() {
        var release = RestRelease()
        let owed = release.flush(hasGuest: false)
        #expect(owed == false)
    }

    @Test("A guest that never leaves cannot hold a finished rest forever")
    func backstopForcesTheRelease() {
        var release = RestRelease()
        _ = release.release(hasGuest: true)
        let forced = release.flush(hasGuest: true, force: true)
        #expect(forced)
        #expect(release.isPending == false)
    }

    @Test("A newer fact cancels what the older one was waiting for")
    func cancelForgetsTheDebt() {
        var release = RestRelease()
        _ = release.release(hasGuest: true)
        release.cancel()
        let stillOwed = release.flush(hasGuest: false)
        #expect(stillOwed == false)
    }

    @Test("A rest that ends with no guest clears any older debt as it goes")
    func immediateReleaseClearsPending() {
        var release = RestRelease()
        _ = release.release(hasGuest: true)
        let endedCleanly = release.release(hasGuest: false)
        #expect(endedCleanly)
        #expect(release.isPending == false, "otherwise the next flush would fire a second time")
    }
}
