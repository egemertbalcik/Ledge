import CoreGraphics
import Foundation
import LedgeCore
import Testing

/// What the duration rule does after the hand lets go.
@Suite("Ruler glide")
struct RulerGlideTests {

    private let fast = DurationDial.pointsPerMinute * 40   // 240 pt/s
    private let gentle = DurationDial.pointsPerMinute      // 6 pt/s

    // MARK: - What counts as a flick

    /// The common case, and the one worth protecting: somebody dialling
    /// carefully lets go at almost no speed, and the number must stay where
    /// they put it rather than drifting off it.
    @Test("A slow release does not glide at all")
    func slowReleaseStops() {
        var glide = RulerGlide(velocity: Double(gentle))
        #expect(!glide.isGliding)
        #expect(glide.step(0.1) == 0)
    }

    @Test("A flick glides")
    func flickGlides() {
        var glide = RulerGlide(velocity: Double(fast))
        #expect(glide.isGliding)
        #expect(glide.step(0.016) > 0)
    }

    @Test("Direction is kept")
    func directionKept() {
        var left = RulerGlide(velocity: -Double(fast))
        #expect(left.step(0.016) < 0)
    }

    // MARK: - How it ends

    @Test("It slows down and stops on its own")
    func settles() {
        var glide = RulerGlide(velocity: Double(fast))
        var steps = 0
        var total: CGFloat = 0
        while glide.isGliding, steps < 1_000 {
            total += glide.step(0.016)
            steps += 1
        }
        #expect(!glide.isGliding, "a glide that never ends is a rule that cannot be set")
        #expect(steps < 200, "and it is over in well under two seconds")
        #expect(total > 0)
    }

    @Test("Each step is shorter than the one before it")
    func decelerates() {
        var glide = RulerGlide(velocity: Double(fast))
        var previous = glide.step(0.016)
        for _ in 0..<20 {
            let next = glide.step(0.016)
            #expect(next <= previous, "speed only falls")
            previous = next
        }
    }

    /// The same flick must travel the same distance whether the caller steps
    /// it sixty times a second or six.
    @Test("Distance does not depend on how often it is stepped")
    func frameRateIndependent() {
        func travel(step: TimeInterval) -> CGFloat {
            var glide = RulerGlide(velocity: 240)
            var total: CGFloat = 0
            var elapsed: TimeInterval = 0
            while glide.isGliding, elapsed < 5 {
                total += glide.step(step)
                elapsed += step
            }
            return total
        }
        let fine = travel(step: 1.0 / 120)
        let coarse = travel(step: 1.0 / 15)
        #expect(abs(fine - coarse) / fine < 0.05, "\(fine) against \(coarse)")
    }

    @Test("Stopping it stops it")
    func stops() {
        var glide = RulerGlide(velocity: Double(fast))
        glide.stop()
        #expect(!glide.isGliding)
        #expect(glide.step(0.5) == 0)
    }

    @Test("Nonsense neither moves nor poisons it")
    func nonsense() {
        let nan = RulerGlide(velocity: .nan)
        #expect(!nan.isGliding)
        var glide = RulerGlide(velocity: Double(fast))
        #expect(glide.step(.nan) == 0)
        #expect(!glide.isGliding, "and it does not keep going afterwards")
        var backwards = RulerGlide(velocity: Double(fast))
        #expect(backwards.step(-1) == 0)
    }

    // MARK: - Reading the speed off a drag

    /// What the hand was doing at the *end* is what carries: a drag that
    /// wandered, paused, then flicked must glide on the flick.
    @Test("Speed comes from the end of the drag, not its average")
    func velocityFromTheEnd() {
        let samples: [(translation: CGFloat, time: TimeInterval)] = [
            (0, 0.0), (10, 0.5),          // slow wander
            (14, 0.52), (40, 0.56),       // then a flick
        ]
        let speed = RulerGlide.velocity(from: samples)
        #expect(speed > 300, "the flick, not the 20pt/s average: \(speed)")
    }

    @Test("A drag that stopped before lifting does not glide")
    func pausedBeforeRelease() {
        let samples: [(translation: CGFloat, time: TimeInterval)] = [
            (0, 0.0), (60, 0.2), (60, 0.30), (60, 0.40),
        ]
        var glide = RulerGlide(velocity: RulerGlide.velocity(from: samples))
        #expect(!glide.isGliding, "the hand had already stopped")
        #expect(glide.step(0.016) == 0)
    }

    @Test("One sample, or none, is no speed at all")
    func tooFewSamples() {
        #expect(RulerGlide.velocity(from: []) == 0)
        #expect(RulerGlide.velocity(from: [(10, 1.0)]) == 0)
        #expect(RulerGlide.velocity(from: [(10, 1.0), (20, 1.0)]) == 0, "no time passed")
    }

    // MARK: - Which account of the release to believe

    @Test("The platform's own velocity wins over the view's estimate")
    func reportedWins() {
        #expect(RulerGlide.release(reported: -900, measured: -40) == -900)
    }

    @Test("A flick the view could not measure still glides")
    func reportedRescuesACollapsedSample() {
        // The whole flick arrived in one update, so there is nothing to
        // measure a speed across. This is the case that stopped the rule dead.
        let velocity = RulerGlide.release(reported: -900, measured: 0)
        var glide = RulerGlide(velocity: velocity)
        #expect(glide.isGliding)
        #expect(glide.step(0.016) < 0, "and it carries on leftwards")
    }

    @Test("No reported velocity falls back to the measured one")
    func measuredFallback() {
        #expect(RulerGlide.release(reported: 0, measured: 350) == 350)
        #expect(RulerGlide.release(reported: .nan, measured: 350) == 350)
        #expect(RulerGlide.release(reported: .infinity, measured: 350) == 350)
    }

    @Test("Neither account is no release at all")
    func neitherAccount() {
        #expect(RulerGlide.release(reported: 0, measured: 0) == 0)
        #expect(RulerGlide.release(reported: .nan, measured: .nan) == 0)
        #expect(!RulerGlide(velocity: RulerGlide.release(reported: 0, measured: 0)).isGliding)
    }

    @Test("A hand that stopped is not rescued by the fallback")
    func stoppedHandStaysStopped() {
        // Both accounts agree the hand was at rest; the fallback must not
        // invent movement out of the stale end of the sample list.
        let samples: [(translation: CGFloat, time: TimeInterval)] = [
            (0, 0.0), (60, 0.2), (60, 0.30), (60, 0.40),
        ]
        let velocity = RulerGlide.release(
            reported: 0,
            measured: RulerGlide.velocity(from: samples)
        )
        #expect(!RulerGlide(velocity: velocity).isGliding)
    }
}
