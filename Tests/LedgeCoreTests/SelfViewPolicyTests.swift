import Foundation
import Testing

@testable import LedgeCore

/// The self-view's rules: which face a reading implies, what a press means,
/// how long is left, and which single sentence is shown.
@Suite("The self-view's rules")
struct SelfViewPolicyTests {

    // MARK: - Faces

    @Test("Every access reading has a face, and being allowed is not yet live")
    func facesForAccess() {
        #expect(SelfViewPolicy.phase(for: .allowed) == .waking)
        #expect(SelfViewPolicy.phase(for: .notAsked) == .asking)
        #expect(SelfViewPolicy.phase(for: .refused) == .refused)
        #expect(SelfViewPolicy.phase(for: .blocked) == .blocked)
        #expect(SelfViewPolicy.phase(for: .missing) == .noCamera)
    }

    @Test("Only three faces hold the notch open, and only two run a camera")
    func holdsAndCameras() {
        let holding = SelfViewPhase.allCases.filter(\.holdsNotchOpen)
        #expect(holding == [.asking, .waking, .live])
        let running = SelfViewPhase.allCases.filter(\.isRunningCamera)
        #expect(running == [.waking, .live])
        // Asking holds without running: macOS's dialog is up, the pointer has
        // to travel to it, and no camera is on until it is answered.
        #expect(SelfViewPhase.asking.holdsNotchOpen)
        #expect(SelfViewPhase.asking.isRunningCamera == false)
    }

    @Test("Off is the only face without a frame")
    func framesShow() {
        for phase in SelfViewPhase.allCases {
            #expect(phase.showsFrame == (phase != .off))
        }
    }

    // MARK: - Presses

    @Test("What a press does, from every face")
    func presses() {
        #expect(SelfViewPolicy.press(on: .off) == .open)
        // Something is running, or a dialog is up on its behalf.
        #expect(SelfViewPolicy.press(on: .asking) == .close)
        #expect(SelfViewPolicy.press(on: .waking) == .close)
        #expect(SelfViewPolicy.press(on: .live) == .close)
        // Nothing is running behind these, so nothing is given up.
        #expect(SelfViewPolicy.press(on: .refused) == .backToMonth)
        #expect(SelfViewPolicy.press(on: .blocked) == .backToMonth)
        #expect(SelfViewPolicy.press(on: .noCamera) == .backToMonth)
        #expect(SelfViewPolicy.press(on: .failed) == .backToMonth)
    }

    @Test("Only the two faces with something to offer get a button")
    func actions() {
        #expect(SelfViewPolicy.action(for: .refused) == .openSettings)
        #expect(SelfViewPolicy.action(for: .failed) == .tryAgain)
        // A profile's refusal and a Mac without a camera cannot be fixed from
        // here, and a button that cannot help is worse than the sentence.
        #expect(SelfViewPolicy.action(for: .blocked) == nil)
        #expect(SelfViewPolicy.action(for: .noCamera) == nil)
        #expect(SelfViewPolicy.action(for: .live) == nil)
        #expect(SelfViewPolicy.action(for: .off) == nil)
    }

    // MARK: - The two clocks

    @Test("With the pointer on the notch only the five-minute cap runs")
    func capAlone() {
        let left = SelfViewPolicy.secondsLeft(startedAt: 100, awaySince: nil, now: 160)
        #expect(left == SelfViewTiming.totalCap - 60)
    }

    @Test("The nearer of the two deadlines wins")
    func nearerWins() {
        // Thirty seconds into a session, and ten seconds since the pointer
        // left: fifty seconds of the minute are left, and four and a half
        // minutes of the cap.
        let left = SelfViewPolicy.secondsLeft(startedAt: 0, awaySince: 20, now: 30)
        #expect(left == 50)
        // Four and three-quarter minutes in, with the pointer just gone: the
        // cap is the nearer one now.
        let late = SelfViewPolicy.secondsLeft(startedAt: 0, awaySince: 285, now: 285)
        #expect(late == 15)
    }

    @Test("Time up is time up, on either clock")
    func expiry() {
        #expect(SelfViewPolicy.hasExpired(startedAt: 0, awaySince: 0, now: 59.9) == false)
        #expect(SelfViewPolicy.hasExpired(startedAt: 0, awaySince: 0, now: 60))
        // The pointer never left, and five minutes passed anyway. A cursor
        // parked on the notch must not hold a camera on all afternoon.
        #expect(SelfViewPolicy.hasExpired(startedAt: 0, awaySince: nil, now: 299) == false)
        #expect(SelfViewPolicy.hasExpired(startedAt: 0, awaySince: nil, now: 300))
    }

    // MARK: - The count

    @Test("The count is only ever over a live picture")
    func countdownOnlyLive() {
        for phase in SelfViewPhase.allCases where phase != .live {
            #expect(
                SelfViewPolicy.countdown(phase: phase, startedAt: 0, awaySince: 0, now: 55) == nil,
                "\(phase) must not count anything down"
            )
        }
    }

    @Test("The count appears for the last ten seconds, and is rounded up")
    func countdownWindow() {
        func count(at now: TimeInterval) -> Int? {
            SelfViewPolicy.countdown(phase: .live, startedAt: 0, awaySince: 0, now: now)
        }
        #expect(count(at: 49.9) == nil, "too early to say anything")
        #expect(count(at: 50) == 10)
        #expect(count(at: 52.5) == 8, "7.5 seconds left reads as 8, not 7")
        // Never nought while the picture is still there: a person reading
        // "0s" over a live face has been told the wrong thing.
        #expect(count(at: 59.99) == 1)
    }

    @Test("The cap gets counted out loud too")
    func countdownOnTheCap() {
        let left = SelfViewPolicy.countdown(phase: .live, startedAt: 0, awaySince: nil, now: 295)
        #expect(left == 5)
    }

    // MARK: - The sentence ladder

    @Test("A short wait says nothing; a long one says it is waking")
    func patience() {
        #expect(SelfViewPolicy.sentence(phase: .waking, waitedFor: 0) == nil)
        #expect(SelfViewPolicy.sentence(phase: .waking, waitedFor: 0.59) == nil)
        #expect(SelfViewPolicy.sentence(phase: .waking, waitedFor: 0.6) == SelfViewCopy.waking)
    }

    @Test("Every face that blocks has its own sentence")
    func blockingSentences() {
        #expect(SelfViewPolicy.sentence(phase: .noCamera) == SelfViewCopy.noCamera)
        #expect(SelfViewPolicy.sentence(phase: .blocked) == SelfViewCopy.blocked)
        #expect(SelfViewPolicy.sentence(phase: .refused) == SelfViewCopy.refused)
        #expect(SelfViewPolicy.sentence(phase: .failed) == SelfViewCopy.didNotStart)
        #expect(SelfViewPolicy.sentence(phase: .asking) == SelfViewCopy.asking)
        #expect(SelfViewPolicy.sentence(phase: .off) == nil)
    }

    @Test("A blocking face outranks the count, which can only meet a picture")
    func ladderPrecedence() {
        // The count is passed in on every face; only the live one takes it.
        for phase in SelfViewPhase.allCases where phase != .live && phase != .off {
            let sentence = SelfViewPolicy.sentence(phase: phase, waitedFor: 5, countdown: 3)
            #expect(sentence != SelfViewCopy.closesIn(3), "\(phase) must not count")
        }
        #expect(
            SelfViewPolicy.sentence(phase: .live, countdown: 3) == SelfViewCopy.closesIn(3)
        )
        #expect(SelfViewPolicy.sentence(phase: .live, countdown: nil) == nil)
    }

    @Test("A payload says the same thing the policy would")
    func payloadSentence() {
        #expect(SelfViewPayload(phase: .waking).sentence == nil)
        #expect(SelfViewPayload(phase: .waking, waitHasLasted: true).sentence == SelfViewCopy.waking)
        #expect(SelfViewPayload(phase: .live, countdown: 4).sentence == "Closes in 4s")
        #expect(SelfViewPayload.off.sentence == nil)
    }
}
