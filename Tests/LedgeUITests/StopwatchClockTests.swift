import Foundation
import Testing

@testable import LedgeUI

@Suite("Stopwatch digits")
struct StopwatchClockTests {

    @Test("m:ss with centiseconds a size down; hours join past sixty minutes")
    func format() {
        let short = TimerCardView.stopwatchClock(72.345)
        #expect(short.main == "1:12")
        #expect(short.fraction == ".34")
        let long = TimerCardView.stopwatchClock(3723.9)
        #expect(long.main == "1:02:03")
        #expect(long.fraction == ".90")
    }

    @Test("Zero, negatives and non-finite values all read as zero")
    func degenerate() {
        #expect(TimerCardView.stopwatchClock(0).main == "0:00")
        #expect(TimerCardView.stopwatchClock(-4).main == "0:00")
        #expect(TimerCardView.stopwatchClock(.nan).fraction == ".00")
        #expect(TimerCardView.stopwatchClock(.infinity).main == "0:00")
        #expect(TimerCardView.stopwatchClock(1_000_000).main == "99:59:59", "the clamp caps the display")
    }

    @Test("Chip labels: minutes under an hour, hours past it")
    func chipLabels() {
        #expect(TimerCardView.minutesLabel(15) == "15m")
        #expect(TimerCardView.minutesLabel(60) == "1h")
        #expect(TimerCardView.minutesLabel(90) == "1h 30m")
        #expect(TimerCardView.minutesLabel(0) == "1m")
    }
}
