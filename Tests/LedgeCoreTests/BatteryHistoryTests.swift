import Foundation
import Testing

@testable import LedgeCore

@Suite("Battery history")
struct BatteryHistoryTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func sample(
        _ level: Double,
        at seconds: TimeInterval,
        component: BatteryComponent = .left,
        charging: ChargingState = .unknown,
        connected: Bool = true
    ) -> BatterySample {
        BatterySample(
            component: component, level: level, charging: charging,
            at: t0.addingTimeInterval(seconds), isConnected: connected
        )
    }

    @Test("The first sample is always kept")
    func firstIsKept() {
        #expect(BatteryHistory.isWorthKeeping(Self.sample(0.5, at: 0), after: nil))
    }

    @Test("A repeat of the same level moments later is dropped")
    func repeatsCoalesce() {
        let first = Self.sample(0.50, at: 0)
        // What a duty-cycled scanner produces: the same value, over and over.
        for tick in 1...20 {
            let repeated = Self.sample(0.50, at: Double(tick) * 3)
            #expect(
                !BatteryHistory.isWorthKeeping(repeated, after: first),
                "an identical reading \(tick * 3)s later was stored"
            )
        }
    }

    @Test("A jitter below the significant step is dropped")
    func jitterCoalesces() {
        let first = Self.sample(0.50, at: 0)
        #expect(!BatteryHistory.isWorthKeeping(Self.sample(0.52, at: 60), after: first))
        #expect(BatteryHistory.isWorthKeeping(Self.sample(0.44, at: 60), after: first))
    }

    @Test("A change in charging or connection is always kept, however small")
    func stateChangesAreKept() {
        let first = Self.sample(0.50, at: 0, charging: .notCharging)
        #expect(BatteryHistory.isWorthKeeping(
            Self.sample(0.50, at: 5, charging: .charging), after: first
        ))
        #expect(BatteryHistory.isWorthKeeping(
            Self.sample(0.50, at: 5, charging: .notCharging, connected: false), after: first
        ))
    }

    @Test("An unchanged battery still gets a heartbeat point")
    func heartbeatKeepsFlatLinesHonest() {
        let first = Self.sample(0.50, at: 0)
        #expect(!BatteryHistory.isWorthKeeping(Self.sample(0.50, at: 1800), after: first))
        #expect(BatteryHistory.isWorthKeeping(Self.sample(0.50, at: 3600), after: first))
    }

    @Test("Different components never coalesce into each other")
    func componentsAreSeparate() {
        let left = Self.sample(0.50, at: 0, component: .left)
        let right = Self.sample(0.50, at: 1, component: .right)
        #expect(BatteryHistory.isWorthKeeping(right, after: left))
    }

    @Test("Samples older than the retention age are pruned")
    func ageIsPruned() {
        let now = Self.t0.addingTimeInterval(BatteryHistory.maximumAge + 10 * 86_400)
        let samples = [
            Self.sample(0.5, at: 0),                                   // far too old
            Self.sample(0.5, at: BatteryHistory.maximumAge),           // inside, just
            Self.sample(0.5, at: BatteryHistory.maximumAge + 9 * 86_400),
        ]
        let kept = BatteryHistory.pruned(samples, now: now)
        #expect(kept.count == 2, "kept \(kept.count)")
        #expect(!kept.contains { $0.at == Self.t0 })
    }

    @Test("The count is bounded, and it is the newest that survive")
    func countIsBounded() {
        let extra = 500
        let samples = (0..<(BatteryHistory.maximumSamplesPerDevice + extra)).map {
            Self.sample(0.5, at: Double($0) * 60)
        }
        let now = Self.t0.addingTimeInterval(Double(samples.count) * 60)
        let kept = BatteryHistory.pruned(samples, now: now)

        #expect(kept.count == BatteryHistory.maximumSamplesPerDevice)
        #expect(
            kept.first?.at == Self.t0.addingTimeInterval(Double(extra) * 60),
            "pruning dropped the newest samples instead of the oldest"
        )
    }

    @Test("Windows select the right span")
    func windowsSelect() {
        let now = Self.t0.addingTimeInterval(30 * 86_400)
        let samples = (0...30).map { Self.sample(0.5, at: Double($0) * 86_400) }
        #expect(BatteryHistory.samples(samples, in: .day, now: now).count == 2)
        #expect(BatteryHistory.samples(samples, in: .week, now: now).count == 8)
        #expect(BatteryHistory.samples(samples, in: .month, now: now).count == 31)
    }

    @Test("Not enough history is reported rather than drawn")
    func thinHistoryIsRefused() {
        let now = Self.t0.addingTimeInterval(86_400)
        // Two points, minutes apart, inside a 24-hour window.
        let thin = [Self.sample(0.5, at: 86_000), Self.sample(0.4, at: 86_100)]
        #expect(!BatteryHistory.hasEnoughHistory(thin, in: .day, now: now))

        let spread = (0...10).map { Self.sample(0.5, at: Double($0) * 3600) }
        #expect(BatteryHistory.hasEnoughHistory(spread, in: .day, now: now))
    }
}
