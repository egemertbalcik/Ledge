import CoreGraphics
import Foundation
import LedgeCore
import Testing

@Suite("Dialling a duration")
struct DurationDialTests {

    private let step = DurationDial.pointsPerMinute

    @Test("A drag of one tick moves one minute")
    func oneTick() {
        // Leftwards brings larger numbers under the marker, like a dial.
        #expect(DurationDial.minutes(anchor: 25, translation: -step) == 26)
        #expect(DurationDial.minutes(anchor: 25, translation: step) == 24)
    }

    @Test("The ruler and the number move at the same rate")
    func sameRate() {
        // Ten ticks of travel is ten minutes, whichever way and wherever from.
        #expect(DurationDial.minutes(anchor: 30, translation: -10 * step) == 40)
        #expect(DurationDial.minutes(anchor: 90, translation: 10 * step) == 80)
    }

    @Test("Half a tick rounds as the marker crosses it, not after")
    func rounding() {
        #expect(DurationDial.minutes(anchor: 10, translation: -step * 0.49) == 10)
        #expect(DurationDial.minutes(anchor: 10, translation: -step * 0.5) == 11)
    }

    @Test("A drag cannot leave the range, however far it goes")
    func clamped() {
        #expect(DurationDial.minutes(anchor: 5, translation: 10_000) == 1)
        #expect(DurationDial.minutes(anchor: 5, translation: -10_000) == 180)
        #expect(DurationDial.minutes(anchor: 180, translation: -step) == 180)
        #expect(DurationDial.minutes(anchor: 1, translation: step) == 1)
    }

    /// Dragging to the end and back must return, rather than banking the
    /// overshoot and needing that distance dragged back before anything moves.
    @Test("Overshooting an end does not bank travel")
    func noBankedOvershoot() {
        let position = DurationDial.position(anchor: 175, translation: -50 * step)
        #expect(position == 180)
        #expect(DurationDial.minutes(anchor: 175, translation: -50 * step + 5 * step) == 180)
    }

    @Test("The position stays continuous between ticks")
    func continuousPosition() {
        let half = DurationDial.position(anchor: 20, translation: -step / 2)
        #expect(abs(half - 20.5) < 0.0001, "the ruler slides rather than jumping")
    }

    @Test("Spoken durations read as someone would say them")
    func spoken() {
        #expect(DurationDial.spoken(1) == "1 min")
        #expect(DurationDial.spoken(45) == "45 min")
        #expect(DurationDial.spoken(60) == "1 hr")
        #expect(DurationDial.spoken(90) == "1 hr 30 min")
        #expect(DurationDial.spoken(120) == "2 hr")
        #expect(DurationDial.spoken(135) == "2 hr 15 min")
    }

    @Test("Clamping is the same rule everywhere")
    func clampRule() {
        #expect(DurationDial.clamp(0) == 1)
        #expect(DurationDial.clamp(-30) == 1)
        #expect(DurationDial.clamp(999) == 180)
        #expect(DurationDial.clamp(25) == 25)
    }
}

/// Scrolling the rule a whole minute at a time.
@Suite("Scrolling the timer's rule")
struct DurationDialScrollTests {

    @Test("A scroll moves the value by its minutes, more for positive")
    func moves() {
        #expect(DurationDial.scroll(25, by: 3, dragging: false, gliding: false)
                == .init(catchesGlide: false, landed: 28))
        #expect(DurationDial.scroll(25, by: -2, dragging: false, gliding: false).landed == 23)
    }

    @Test("A scroll stops at either end, and past it moves nothing")
    func clamps() {
        #expect(DurationDial.scroll(178, by: 5, dragging: false, gliding: false).landed == 180)
        #expect(DurationDial.scroll(180, by: 1, dragging: false, gliding: false).landed == nil,
                "no change, so no tick under the finger")
        #expect(DurationDial.scroll(1, by: -1, dragging: false, gliding: false).landed == nil)
    }

    @Test("A hand dragging the rule keeps it")
    func dragWins() {
        #expect(DurationDial.scroll(25, by: 3, dragging: true, gliding: false)
                == .init(catchesGlide: false, landed: nil))
    }

    @Test("A scroll catches a glide, then moves from where it caught it")
    func catchesGlide() {
        #expect(DurationDial.scroll(40, by: 1, dragging: true, gliding: true)
                == .init(catchesGlide: true, landed: 41))
    }
}
