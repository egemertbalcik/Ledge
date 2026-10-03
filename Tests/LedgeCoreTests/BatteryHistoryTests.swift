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

/// A chart that joins across a disconnection invents a battery level for
/// hours nobody observed. Tested on the series model rather than on a bitmap:
/// a non-empty image says nothing about whether the line lies.
@Suite("Chart segments")
struct ChartSegmentTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func sample(
        _ level: Double,
        at minutes: TimeInterval,
        component: BatteryComponent = .left,
        connected: Bool = true
    ) -> BatterySample {
        BatterySample(
            component: component, level: level, charging: .unknown,
            at: t0.addingTimeInterval(minutes * 60), isConnected: connected
        )
    }

    @Test("An unbroken run is one segment")
    func unbrokenRun() {
        let segments = BatteryHistory.segments([
            Self.sample(0.9, at: 0), Self.sample(0.8, at: 10), Self.sample(0.7, at: 20),
        ])
        #expect(segments.count == 1)
        #expect(segments.first?.samples.count == 3)
    }

    /// The boundary sample closes the run it belongs to, so the line stops at
    /// the moment the device left rather than before it.
    ///
    /// Deliberately a *short* absence: five minutes, well inside the silence
    /// rule. If only the gap rule were doing the work, this would be one
    /// continuous line through a device that was in its case.
    @Test("A brief disconnection still ends the run")
    func disconnectionBreaksTheLine() {
        let segments = BatteryHistory.segments([
            Self.sample(0.9, at: 0),
            Self.sample(0.85, at: 10, connected: false),
            Self.sample(0.5, at: 15),
        ])
        #expect(segments.count == 2, "the line was drawn straight through the gap")
        #expect(segments.first?.samples.count == 2)
        #expect(segments.first?.samples.last?.isConnected == false)
        #expect(segments.last?.samples.count == 1)
    }

    /// And a long absence breaks it whether or not a boundary was recorded —
    /// Ledge not running leaves no boundary at all.
    @Test("A long absence ends the run without a boundary")
    func longAbsenceBreaksTheLine() {
        let segments = BatteryHistory.segments([
            Self.sample(0.9, at: 0),
            Self.sample(0.85, at: 10, connected: false),
            Self.sample(0.5, at: 300),
        ])
        #expect(segments.count == 2)
    }

    @Test("A long silence ends the run even without a boundary")
    func longSilenceBreaksTheLine() {
        let segments = BatteryHistory.segments([
            Self.sample(0.9, at: 0),
            Self.sample(0.4, at: 600),  // ten hours later
        ])
        #expect(segments.count == 2)
    }

    @Test("A silence shorter than the gap stays one run")
    func shortSilenceIsJoined() {
        let segments = BatteryHistory.segments([
            Self.sample(0.9, at: 0),
            Self.sample(0.85, at: 20),
        ])
        #expect(segments.count == 1)
    }

    @Test("Each component gets its own runs, and keeps its own identity")
    func componentsAreSeparate() {
        let segments = BatteryHistory.segments([
            Self.sample(0.9, at: 0, component: .left),
            Self.sample(0.9, at: 0, component: .right),
            Self.sample(0.85, at: 10, component: .left, connected: false),
            Self.sample(0.5, at: 300, component: .left),
        ])
        #expect(segments.filter { $0.component == .left }.count == 2)
        #expect(segments.filter { $0.component == .right }.count == 1)
        #expect(Set(segments.map(\.id)).count == segments.count, "two runs shared one line")
    }

    @Test("Samples arriving out of order are still segmented by time")
    func outOfOrderSamples() {
        let segments = BatteryHistory.segments([
            Self.sample(0.5, at: 300),
            Self.sample(0.85, at: 10, connected: false),
            Self.sample(0.9, at: 0),
        ])
        #expect(segments.count == 2)
        #expect(segments.first?.samples.first?.level == 0.9)
    }

    @Test("Nothing to draw is no segments")
    func emptyHistory() {
        #expect(BatteryHistory.segments([]).isEmpty)
    }
}

/// This Mac's battery is read from the power source, which announces changes
/// and says nothing while a charged battery sits on the charger. Judging it by
/// elapsed time marked the one device that is certainly present as doubtful
/// after fifteen quiet minutes.
@Suite("Freshness of a source that only reports changes")
struct ReportsOnlyOnChangeTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private static func record(_ id: DeviceIdentity, level: Double = 1.0) -> DeviceRecord {
        DeviceRecord(
            id: id, name: "This Mac", presence: .connected,
            readings: [BatteryReading(component: .main, level: level, observedAt: t0)],
            firstSeen: t0, lastSeen: t0
        )
    }

    @Test("This Mac is the kind of source that speaks only on change")
    func thisMacReportsOnlyOnChange() {
        #expect(DeviceIdentity.thisMac.reportsOnlyOnChange)
        #expect(DeviceIdentity.bluetooth("aa:bb").reportsOnlyOnChange == false)
    }

    /// A charged battery on the charger says nothing for hours. While its
    /// provider is running, that silence is not staleness.
    @Test("A quiet hour does not make This Mac stale while its provider runs")
    func stableMacStaysFreshWhileLive() {
        let mac = Self.record(.thisMac)
        let later = Self.t0.addingTimeInterval(3600)
        #expect(mac.isFresh(now: later, sourceIsLive: true))
        #expect(mac.isStale(now: later, sourceIsLive: true) == false)
        let reading = try! #require(mac.readings.first)
        #expect(mac.isCurrent(reading, now: later, sourceIsLive: true))
        #expect(mac.displayedLowestInUse(now: later, sourceIsLive: true).isHistorical == false)
    }

    /// And "fresh for ever" is the other mistake: switch the Battery provider
    /// off and the stored record must stop claiming a live reading.
    @Test("A stopped provider makes the stored reading historical")
    func stoppedProviderIsNotFresh() {
        let mac = Self.record(.thisMac)
        let later = Self.t0.addingTimeInterval(3600)
        #expect(mac.isFresh(now: later, sourceIsLive: false) == false)
        #expect(mac.isStale(now: later, sourceIsLive: false))
        let reading = try! #require(mac.readings.first)
        #expect(mac.isCurrent(reading, now: later, sourceIsLive: false) == false)
        #expect(mac.displayedLowestInUse(now: later, sourceIsLive: false).isHistorical)
    }

    /// Even a reading taken a moment ago is not "current" once nothing is
    /// reporting it: there is no longer anything behind the claim.
    @Test("A fresh reading from a stopped provider is still not current")
    func freshReadingFromStoppedProvider() {
        let mac = Self.record(.thisMac)
        let reading = try! #require(mac.readings.first)
        #expect(mac.isCurrent(reading, now: Self.t0, sourceIsLive: false) == false)
    }

    /// And a device that does repeat itself is judged as before — silence from
    /// those really is evidence, and the provider's liveness is irrelevant.
    @Test("A Bluetooth device still goes stale")
    func bluetoothStillGoesStale() {
        let device = Self.record(.bluetooth("aa:bb"))
        #expect(device.isStale(now: Self.t0.addingTimeInterval(3600), sourceIsLive: true))
        #expect(device.isFresh(now: Self.t0.addingTimeInterval(60), sourceIsLive: false))
    }

    /// Disconnection still wins: This Mac is never disconnected, but the rule
    /// must not be a blanket exemption.
    @Test("A disconnected record is not current whatever its source")
    func disconnectionStillCounts() {
        var mac = Self.record(.thisMac)
        mac.presence = .disconnected
        let reading = try! #require(mac.readings.first)
        #expect(mac.isCurrent(reading, now: Self.t0, sourceIsLive: true) == false)
    }
}
