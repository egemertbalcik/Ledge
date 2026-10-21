import Foundation
import LedgeCore
import LedgeSystem
import Testing
import os

@testable import LedgeProviders

/// Two same-model sets of AirPods, one record.
///
/// An advertisement is attached to the paired device by model id, and the
/// air cannot say which set sent it: a neighbour's AirPods 4 land on the
/// user's own. That limit stands. What must not follow from it is the user
/// hearing about one low battery again and again, or reading the
/// neighbour's level as theirs while the system is reporting their own.
// Waits below are for events, not against a clock; a regression that never
// delivers is a hang, and the limit turns it into a failure. Ten minutes, so it
// only ever catches a hang: one minute was beaten by the full suite holding the
// main thread for most of that.
@Suite("Same-model sets", .serialized, .timeLimit(.minutes(10)))
@MainActor
struct SameModelSetTests {

    private final class Alerts: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [BatteryAlert]())
        func add(_ alerts: [BatteryAlert]) { state.withLock { $0.append(contentsOf: alerts) } }
        var lows: [BatteryAlert] { state.withLock { $0 }.filter { $0.kind == .low } }
        var chargeds: [BatteryAlert] { state.withLock { $0 }.filter { $0.kind == .charged } }
    }

    /// The owner's AirPods 4, as `system_profiler` lists them: product
    /// `0x201B`, advertised as model `0x1B20`.
    private static let own = PairedDevice(
        address: "08:5D:53:A9:D9:3E", name: "Ege AirPods",
        isConnected: true, vendorID: 0x004C, productID: 0x201B
    )

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-same-model-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("devices.json")
    }

    /// A store, the paired list it judges against, a clock it is told, and
    /// what it decided to announce.
    @MainActor
    private struct Rig {
        let registry: PairedDeviceRegistry
        let clock: OSAllocatedUnfairLock<Date>
        let store: DeviceCatalogueStore
        let alerts: Alerts
        let url: URL

        init(at start: Date, connected: Bool, url: URL = SameModelSetTests.tempURL()) async {
            var device = SameModelSetTests.own
            device.isConnected = connected
            let registry = PairedDeviceRegistry()
            registry.answer([device], at: start)
            let clock = OSAllocatedUnfairLock(initialState: start)
            let alerts = Alerts()
            self.registry = registry
            self.clock = clock
            self.alerts = alerts
            self.url = url
            store = DeviceCatalogueStore(
                url: url, now: { clock.withLock { $0 } }, paired: registry
            )
            _ = await store.subscribeToAlerts { alerts.add($0) }
        }

        /// One advertisement, through the real attribution. Throws if it
        /// was not filed under the owner's record, because then the test is
        /// not about what it says it is.
        func advert(
            left: Double?, right: Double?, caseLevel: Double? = nil, charging: Bool = false, at when: Date
        ) async throws {
            clock.withLock { $0 = when }
            var proximity = AirPodsProximity(
                model: 0x1B20, leftBattery: left, rightBattery: right, caseBattery: caseLevel,
                isChargingLeft: charging, isChargingRight: charging, isChargingCase: charging,
                lidCounter: 1
            )
            proximity.peripheralID = UUID()
            proximity.rssi = -70
            let observation = try #require(
                DeviceObservations.fromProximity(proximity, paired: registry.current, at: when)
            )
            try #require(observation.deviceID == SameModelSetTests.own.identity)
            await store.record(observation)
        }

        /// What the system's own ten-minute read says about the connected set.
        func systemReading(_ levels: [String: Double], at when: Date) async {
            clock.withLock { $0 = when }
            let device = BluetoothDeviceSnapshot(
                name: SameModelSetTests.own.name, address: SameModelSetTests.own.address,
                isConnected: true, batteryLevels: levels
            )
            await store.record(DeviceObservations.fromBluetooth(device, at: when, cause: .periodicRefresh))
        }

        func record() async throws -> DeviceRecord {
            let devices = await store.snapshot().devices
            return try #require(devices.first { $0.id == SameModelSetTests.own.identity })
        }
    }

    // MARK: - A real evening

    /// Every Left/Right sample the owner's catalogue kept for "Ege AirPods"
    /// on 2026-10-19 between 23:10 and 23:43, recorded by build 391. "a" is
    /// an advertisement and "p" the system's ten-minute read of the paired
    /// list. Two sets are interleaved in it: the 20/40% series is the
    /// owner's, connected throughout and matching `system_profiler`; the
    /// 70/80% series is another AirPods 4 in range.
    private static let evening: [(at: TimeInterval, component: String, level: Double, source: String)] = [
        (814133460.175775, "Left", 0.31, "p"),
        (814133460.175775, "Right", 0.55, "p"),
        (814133461.117078, "Left", 0.3, "a"),
        (814133461.117078, "Right", 0.5, "a"),
        (814133472.391941, "Left", 0.8, "a"),
        (814133472.391941, "Right", 0.8, "a"),
        (814133472.44802, "Left", 0.3, "a"),
        (814133472.44802, "Right", 0.5, "a"),
        (814133472.759286, "Left", 0.8, "a"),
        (814133472.759286, "Right", 0.8, "a"),
        (814133473.191558, "Left", 0.3, "a"),
        (814133473.191558, "Right", 0.5, "a"),
        (814133473.687075, "Left", 0.8, "a"),
        (814133473.687075, "Right", 0.8, "a"),
        (814133478.756385, "Left", 0.3, "a"),
        (814133478.756385, "Right", 0.5, "a"),
        (814133479.062459, "Left", 0.8, "a"),
        (814133479.062459, "Right", 0.8, "a"),
        (814133479.153164, "Left", 0.3, "a"),
        (814133479.153164, "Right", 0.5, "a"),
        (814133479.244124, "Left", 0.8, "a"),
        (814133479.244124, "Right", 0.8, "a"),
        (814133479.512729, "Left", 0.3, "a"),
        (814133479.512729, "Right", 0.5, "a"),
        (814133527.093367, "Left", 0.8, "a"),
        (814133527.093367, "Right", 0.8, "a"),
        (814133527.738778, "Left", 0.3, "a"),
        (814133527.738778, "Right", 0.5, "a"),
        (814133538.215187, "Left", 0.8, "a"),
        (814133538.215187, "Right", 0.8, "a"),
        (814133544.261022, "Left", 0.3, "a"),
        (814133544.261022, "Right", 0.5, "a"),
        (814133599.093424, "Left", 0.8, "a"),
        (814133599.093424, "Right", 0.8, "a"),
        (814133604.470747, "Left", 0.3, "a"),
        (814133604.470747, "Right", 0.5, "a"),
        (814133616.84537, "Left", 0.8, "a"),
        (814133616.84537, "Right", 0.8, "a"),
        (814133617.461284, "Left", 0.3, "a"),
        (814133617.461284, "Right", 0.5, "a"),
        (814133677.451661, "Left", 0.2, "a"),
        (814133754.800544, "Left", 0.8, "a"),
        (814133754.800544, "Right", 0.8, "a"),
        (814133755.144331, "Left", 0.2, "a"),
        (814133755.144331, "Right", 0.5, "a"),
        (814133935.478466, "Left", 0.8, "a"),
        (814133935.478466, "Right", 0.8, "a"),
        (814133941.361459, "Left", 0.2, "a"),
        (814133941.361459, "Right", 0.5, "a"),
        (814133949.863338, "Left", 0.8, "a"),
        (814133949.863338, "Right", 0.8, "a"),
        (814133950.450536, "Left", 0.2, "a"),
        (814133950.450536, "Right", 0.5, "a"),
        (814134006.839545, "Left", 0.8, "a"),
        (814134006.839545, "Right", 0.8, "a"),
        (814134007.464641, "Left", 0.2, "a"),
        (814134007.464641, "Right", 0.5, "a"),
        (814134060.127507, "Left", 0.26, "p"),
        (814134060.127507, "Right", 0.52, "p"),
        (814134061.12406, "Left", 0.2, "a"),
        (814134061.12406, "Right", 0.5, "a"),
        (814134156.628609, "Left", 0.8, "a"),
        (814134156.628609, "Right", 0.8, "a"),
        (814134157.647585, "Left", 0.2, "a"),
        (814134157.647585, "Right", 0.5, "a"),
        (814134180.502049, "Left", 0.8, "a"),
        (814134180.502049, "Right", 0.8, "a"),
        (814134181.357033, "Left", 0.2, "a"),
        (814134181.357033, "Right", 0.5, "a"),
        (814134348.490977, "Right", 0.4, "a"),
        (814134360.497952, "Left", 0.8, "a"),
        (814134360.497952, "Right", 0.8, "a"),
        (814134366.243417, "Left", 0.2, "a"),
        (814134366.243417, "Right", 0.4, "a"),
        (814134385.647531, "Left", 0.8, "a"),
        (814134385.647531, "Right", 0.8, "a"),
        (814134390.264994, "Left", 0.2, "a"),
        (814134390.264994, "Right", 0.4, "a"),
        (814134396.586963, "Left", 0.8, "a"),
        (814134396.586963, "Right", 0.8, "a"),
        (814134396.59557, "Left", 0.2, "a"),
        (814134396.59557, "Right", 0.4, "a"),
        (814134408.856753, "Left", 0.8, "a"),
        (814134408.856753, "Right", 0.8, "a"),
        (814134415.142602, "Left", 0.2, "a"),
        (814134415.142602, "Right", 0.4, "a"),
        (814134451.644134, "Left", 0.8, "a"),
        (814134451.644134, "Right", 0.8, "a"),
        (814134456.219264, "Left", 0.2, "a"),
        (814134456.219264, "Right", 0.4, "a"),
        (814134516.834445, "Left", 0.8, "a"),
        (814134516.834445, "Right", 0.8, "a"),
        (814134517.388287, "Left", 0.2, "a"),
        (814134517.388287, "Right", 0.4, "a"),
        (814134528.855969, "Left", 0.7, "a"),
        (814134528.855969, "Right", 0.8, "a"),
        (814134529.133048, "Left", 0.2, "a"),
        (814134529.133048, "Right", 0.4, "a"),
        (814134534.457391, "Left", 0.7, "a"),
        (814134534.457391, "Right", 0.8, "a"),
        (814134535.057789, "Left", 0.2, "a"),
        (814134535.057789, "Right", 0.4, "a"),
        (814134559.69022, "Left", 0.7, "a"),
        (814134559.69022, "Right", 0.8, "a"),
        (814134564.150888, "Left", 0.2, "a"),
        (814134564.150888, "Right", 0.4, "a"),
        (814134577.350159, "Left", 0.7, "a"),
        (814134577.350159, "Right", 0.8, "a"),
        (814134582.216941, "Left", 0.2, "a"),
        (814134582.216941, "Right", 0.4, "a"),
        (814134660.117741, "Right", 0.47, "p"),
        (814134660.117741, "Left", 0.24, "p"),
        (814134660.788201, "Left", 0.2, "a"),
        (814134660.788201, "Right", 0.4, "a"),
        (814134703.650449, "Left", 0.7, "a"),
        (814134703.650449, "Right", 0.8, "a"),
        (814134708.164067, "Left", 0.2, "a"),
        (814134708.164067, "Right", 0.4, "a"),
        (814134744.365153, "Left", 0.7, "a"),
        (814134744.365153, "Right", 0.8, "a"),
        (814134745.003109, "Left", 0.2, "a"),
        (814134745.003109, "Right", 0.4, "a"),
        (814134834.434435, "Left", 0.7, "a"),
        (814134834.434435, "Right", 0.8, "a"),
        (814134834.534276, "Left", 0.2, "a"),
        (814134834.534276, "Right", 0.4, "a"),
        (814134870.142946, "Left", 0.7, "a"),
        (814134870.142946, "Right", 0.7, "a"),
        (814134870.208648, "Left", 0.2, "a"),
        (814134870.208648, "Right", 0.4, "a"),
        (814134882.125848, "Left", 0.7, "a"),
        (814134882.125848, "Right", 0.7, "a"),
        (814134882.46405, "Left", 0.2, "a"),
        (814134882.46405, "Right", 0.4, "a"),
        (814135014.184823, "Left", 0.7, "a"),
        (814135014.184823, "Right", 0.7, "a"),
        (814135014.214729, "Left", 0.2, "a"),
        (814135014.214729, "Right", 0.4, "a"),
        (814135014.746871, "Left", 0.7, "a"),
        (814135014.746871, "Right", 0.7, "a"),
        (814135015.325786, "Left", 0.2, "a"),
        (814135015.325786, "Right", 0.4, "a"),
        (814135039.639024, "Left", 0.7, "a"),
        (814135039.639024, "Right", 0.7, "a"),
        (814135044.430792, "Left", 0.2, "a"),
        (814135044.430792, "Right", 0.4, "a"),
        (814135050.798204, "Left", 0.7, "a"),
        (814135050.798204, "Right", 0.7, "a"),
        (814135052.320814, "Left", 0.2, "a"),
        (814135052.320814, "Right", 0.4, "a"),
        (814135152.739404, "Left", 0.7, "a"),
        (814135152.739404, "Right", 0.7, "a"),
        (814135153.037518, "Left", 0.2, "a"),
        (814135153.037518, "Right", 0.4, "a"),
        (814135212.728064, "Left", 0.7, "a"),
        (814135212.728064, "Right", 0.7, "a"),
        (814135218.172624, "Left", 0.2, "a"),
        (814135218.172624, "Right", 0.4, "a"),
        (814135249.343457, "Left", 1, "a"),
        (814135249.402554, "Left", 0.2, "a"),
        (814135260.089589, "Left", 0.19, "p"),
        (814135260.089589, "Right", 0.43, "p"),
        (814135260.142147, "Left", 0.7, "a"),
        (814135260.142147, "Right", 0.7, "a"),
        (814135260.527524, "Left", 0.2, "a"),
        (814135260.527524, "Right", 0.4, "a"),
        (814135266.134596, "Left", 0.7, "a"),
        (814135266.134596, "Right", 0.7, "a"),
        (814135266.692645, "Left", 0.2, "a"),
        (814135266.692645, "Right", 0.4, "a"),
        (814135272.817815, "Left", 0.7, "a"),
        (814135272.817815, "Right", 0.7, "a"),
        (814135279.372559, "Left", 0.2, "a"),
        (814135279.372559, "Right", 0.4, "a"),
        (814135296.734348, "Left", 0.7, "a"),
        (814135296.734348, "Right", 0.7, "a"),
        (814135302.802503, "Left", 0.2, "a"),
        (814135302.802503, "Right", 0.4, "a"),
        (814135362.710511, "Left", 0.7, "a"),
        (814135362.710511, "Right", 0.7, "a"),
        (814135363.380219, "Left", 0.2, "a"),
        (814135363.380219, "Right", 0.4, "a"),
        (814135374.825516, "Left", 0.7, "a"),
        (814135374.825516, "Right", 0.7, "a"),
        (814135375.100192, "Left", 0.2, "a"),
        (814135375.100192, "Right", 0.4, "a"),
    ]

    @Test("A real evening with another set in range announces the owner's low battery once")
    func realEveningAlertsOnce() async throws {
        let start = Date(timeIntervalSinceReferenceDate: Self.evening[0].at - 120)
        let rig = await Rig(at: start, connected: true)

        var adverts = 0
        for row in Self.evening {
            let when = Date(timeIntervalSinceReferenceDate: row.at)
            if row.source == "a" {
                try await rig.advert(
                    left: row.component == "Left" ? row.level : nil,
                    right: row.component == "Right" ? row.level : nil,
                    at: when
                )
                adverts += 1
            } else {
                await rig.systemReading([row.component: row.level], at: when)
            }
        }
        // Reached the condition: both sets' advertisements were filed under
        // the owner's record, and the other set's were among them.
        try #require(adverts == 178)
        try #require(Self.evening.contains { $0.source == "a" && $0.level >= 0.7 })

        // Once, and from the system's own reading of the owner's set.
        let lows = rig.alerts.lows
        #expect(lows.count == 1, "one low battery was announced \(lows.count) times in half an hour")
        #expect(lows.first?.component == .left)
        #expect(lows.first?.level == 0.19)

        // What Settings and the chart show is the owner's set, not the other one.
        let record = try await rig.record()
        #expect(record.readings.first { $0.component == .left }?.level == 0.19)
        #expect(record.readings.first { $0.component == .right }?.level == 0.43)
        let history = await rig.store.history(for: Self.own.identity)
        try #require(!history.isEmpty)
        #expect(!history.contains { $0.level >= 0.7 }, "the other set's levels went into the owner's history")
    }

    // MARK: - Away from the Mac

    /// The audit's four live samples from 23:42:42–55, with no system reading
    /// to defer to: the owner's set is in use with the phone. The record
    /// cannot tell the two apart, and the alert must not be the casualty.
    @Test("Another set's high advertisement does not rearm the owner's low alert")
    func otherSetDoesNotRearm() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_146_162.710)
        let rig = await Rig(at: t0.addingTimeInterval(-60), connected: false)

        try await rig.advert(left: 0.7, right: 0.7, at: t0)
        try await rig.advert(left: 0.2, right: 0.4, at: t0.addingTimeInterval(0.670))
        try #require(rig.alerts.lows.count == 1, "the fixture's own crossing did not alert")
        try await rig.advert(left: 0.7, right: 0.7, at: t0.addingTimeInterval(12.115))
        try #require(try await rig.record().readings.first { $0.component == .left }?.level == 0.7)
        try await rig.advert(left: 0.2, right: 0.4, at: t0.addingTimeInterval(12.390))

        #expect(rig.alerts.lows.count == 1, "the same 20% was announced again")
    }

    @Test("A real discharge seen only over the air still alerts, once")
    func discharge() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let rig = await Rig(at: t0.addingTimeInterval(-60), connected: false)

        for (step, level) in [0.5, 0.4, 0.3, 0.2, 0.2, 0.1].enumerated() {
            try await rig.advert(left: level, right: nil, at: t0.addingTimeInterval(Double(step) * 600))
        }

        let lows = rig.alerts.lows
        #expect(lows.count == 1)
        #expect(lows.first?.level == 0.2)
    }

    @Test("Charging in the case rearms, and the next discharge alerts again")
    func rechargeRearms() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let rig = await Rig(at: t0.addingTimeInterval(-60), connected: false)

        try await rig.advert(left: 0.3, right: nil, at: t0)
        try await rig.advert(left: 0.2, right: nil, at: t0.addingTimeInterval(600))
        try #require(rig.alerts.lows.count == 1)

        try await rig.advert(left: 0.5, right: nil, charging: true, at: t0.addingTimeInterval(1200))
        try await rig.advert(left: 1.0, right: nil, at: t0.addingTimeInterval(1800))
        try await rig.advert(left: 0.2, right: nil, at: t0.addingTimeInterval(9000))

        #expect(rig.alerts.lows.count == 2, "a discharge after a real recharge was not announced")
    }

    @Test("A connected reading rearms too: the system is reporting this set")
    func connectedReadingRearms() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let rig = await Rig(at: t0.addingTimeInterval(-60), connected: false)

        try await rig.advert(left: 0.3, right: nil, at: t0)
        try await rig.advert(left: 0.2, right: nil, at: t0.addingTimeInterval(600))
        try #require(rig.alerts.lows.count == 1)

        // Charged somewhere Ledge did not see, then connected to this Mac.
        await rig.systemReading(["Left": 0.9], at: t0.addingTimeInterval(7200))
        await rig.systemReading(["Left": 0.18], at: t0.addingTimeInterval(14400))

        #expect(rig.alerts.lows.count == 2)
    }

    // MARK: - When the advertisement is all there is

    @Test("An advertisement is kept when the system's reading is too old to describe now")
    func staleSystemReadingDoesNotSilenceTheAir() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let rig = await Rig(at: t0.addingTimeInterval(-60), connected: true)

        await rig.systemReading(["Left": 0.4], at: t0)
        // Still connected, so a current system reading would win.
        try await rig.advert(left: 0.3, right: nil, at: t0.addingTimeInterval(60))
        try #require(try await rig.record().readings.first { $0.component == .left }?.level == 0.4)

        // Nothing has asked the system for longer than its reading is believed.
        try await rig.advert(left: 0.2, right: nil, at: t0.addingTimeInterval(31 * 60))

        #expect(try await rig.record().readings.first { $0.component == .left }?.level == 0.2)
        #expect(rig.alerts.lows.count == 1, "the owner's low battery was hidden behind a stale reading")
    }

    @Test("Once the set disconnects, its advertisements count again")
    func disconnectHandsBackToTheAir() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let rig = await Rig(at: t0.addingTimeInterval(-60), connected: true)

        await rig.systemReading(["Left": 0.4], at: t0)
        try await rig.advert(left: 0.3, right: nil, at: t0.addingTimeInterval(60))
        try #require(try await rig.record().readings.first { $0.component == .left }?.level == 0.4)

        // Off to the phone, a minute later; the system's 40% now describes the past.
        rig.clock.withLock { $0 = t0.addingTimeInterval(120) }
        await rig.store.record(DeviceObservations.disconnected(
            address: Self.own.address, name: Self.own.name, at: t0.addingTimeInterval(120)
        ))
        try #require(try await rig.record().presence == .disconnected)
        try await rig.advert(left: 0.2, right: nil, at: t0.addingTimeInterval(180))

        #expect(try await rig.record().readings.first { $0.component == .left }?.level == 0.2)
        #expect(rig.alerts.lows.count == 1, "the owner's low battery was hidden behind a connection that had ended")
    }

    // MARK: - Charging while connected

    /// The ordinary way to charge AirPods: back in the case with the lid
    /// open, still connected to the Mac. The system's reading never says
    /// "charging"; only the air does.
    @Test("Charging in the open case while connected: one charged alert per charge, and Settings keeps the control")
    func chargingWhileConnected() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let rig = await Rig(at: t0.addingTimeInterval(-60), connected: true)

        await rig.systemReading(["Left": 0.3], at: t0)
        await rig.store.setAlerts(
            DeviceAlertConfiguration(
                rules: [.defaultLow(), BatteryAlertRule(kind: .charged, threshold: 0.8)],
                isCustomised: true
            ),
            for: Self.own.identity
        )

        // Worn: the owner's own discharging advertisement adds nothing the
        // system is not saying, and the other set's is far off.
        try await rig.advert(left: 0.3, right: nil, at: t0.addingTimeInterval(30))
        try await rig.advert(left: 0.9, right: nil, at: t0.addingTimeInterval(31))
        try #require(try await rig.record().readings.first { $0.component == .left }?.level == 0.3)

        // Into the case, lid open, a step at a time.
        var at = t0.addingTimeInterval(60)
        for level in [0.3, 0.4, 0.5, 0.6] {
            try await rig.advert(left: level, right: nil, charging: true, at: at)
            at.addTimeInterval(60)
        }
        let charging = try await rig.record().readings.first { $0.component == .left }
        try #require(charging?.level == 0.6 && charging?.charging == .charging,
                     "the owner's charging set was not heard while connected")

        // The ten-minute read takes the cell, and says nothing about charging.
        await rig.systemReading(["Left": 0.62], at: at)
        let taken = try await rig.record()
        try #require(taken.readings.first { $0.component == .left }?.charging == .unknown)
        #expect(taken.reportsCharging(.left), "Settings would dim the charged alert while the set charges")
        #expect(taken.reportsCharging(nil))

        // Another set nearby, not charging and far off, cannot end the charge.
        at.addTimeInterval(30)
        try await rig.advert(left: 0.2, right: nil, at: at)
        for level in [0.6, 0.7, 0.8, 0.9, 1.0] {
            at.addTimeInterval(60)
            try await rig.advert(left: level, right: nil, charging: true, at: at)
            at.addTimeInterval(1)
            try await rig.advert(left: 0.2, right: nil, at: at)
        }

        let chargeds = rig.alerts.chargeds
        #expect(chargeds.count == 1, "the charged alert fired \(chargeds.count) times for one charge")
        #expect(chargeds.first?.level == 0.8)
        #expect(rig.alerts.lows.isEmpty, "another set's 20% raised a low alert over a charging set")

        // Out of the case: the end of the charge is heard, so the next one is news.
        at.addTimeInterval(60)
        try await rig.advert(left: 1.0, right: nil, at: at)
        try #require(try await rig.record().readings.first { $0.component == .left }?.charging == .notCharging)
        at.addTimeInterval(3 * 3600)
        await rig.systemReading(["Left": 0.6], at: at)
        for level in [0.6, 0.7, 0.8] {
            at.addTimeInterval(60)
            try await rig.advert(left: level, right: nil, charging: true, at: at)
        }
        #expect(rig.alerts.chargeds.count == 2, "a second charge while connected was never announced")
    }

    @Test("Going into the case at the threshold is not a low battery")
    func chargingAtTheThresholdIsNotLow() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let rig = await Rig(at: t0.addingTimeInterval(-60), connected: true)

        await rig.systemReading(["Left": 0.3], at: t0)
        await rig.systemReading(["Left": 0.26], at: t0.addingTimeInterval(600))
        // The air's 10% step for the same 26%, as the pods go into the case.
        try await rig.advert(left: 0.2, right: nil, charging: true, at: t0.addingTimeInterval(660))
        let left = try await rig.record().readings.first { $0.component == .left }
        try #require(left?.level == 0.2 && left?.charging == .charging,
                     "the charging advertisement never reached the alert decision")

        #expect(rig.alerts.lows.isEmpty, "a set going into its case was announced as running out")
    }

    // MARK: - Review round 2

    /// Charging proves that a set is charging, not whose. A neighbour's set in
    /// its case at 30% sits within reach of the owner's 20%.
    @Test("A charging set near the owner's level does not rearm the low alert while connected")
    func chargingStrangerNearTheLevel() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let rig = await Rig(at: t0.addingTimeInterval(-60), connected: true)

        await rig.systemReading(["Left": 0.26], at: t0)
        await rig.systemReading(["Left": 0.20], at: t0.addingTimeInterval(1))
        try #require(rig.alerts.lows.count == 1, "the fixture's own crossing did not alert")

        for n in 0..<4 {
            try await rig.advert(left: 0.30, right: nil, charging: true, at: t0.addingTimeInterval(Double(2 + n * 2)))
            if n == 0 {
                // Reached the condition: the neighbour's charging advertisement got in.
                let left = try await rig.record().readings.first { $0.component == .left }
                try #require(left?.level == 0.30 && left?.charging == .charging)
            }
            try await rig.advert(left: 0.20, right: nil, at: t0.addingTimeInterval(Double(3 + n * 2)))
        }

        #expect(rig.alerts.lows.count == 1, "one low battery was announced \(rig.alerts.lows.count) times")
    }

    /// The buds connect and are reported; the case is not, and what the
    /// record holds for it is yesterday's.
    @Test("A case the system is not reporting is measured against nothing, not yesterday")
    func freshConnectionStaleCase() async throws {
        let yesterday = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let rig = await Rig(at: yesterday.addingTimeInterval(-60), connected: true)
        try await rig.advert(left: nil, right: nil, caseLevel: 0.20, at: yesterday)

        let today = yesterday.addingTimeInterval(86_400)
        await rig.systemReading(["Left": 0.60, "Right": 0.60], at: today)
        let connected = try await rig.record()
        try #require(connected.presence == .connected)
        try #require(connected.readings.first { $0.component == .case }?.level == 0.20)

        try await rig.advert(left: nil, right: nil, caseLevel: 0.80, charging: true, at: today.addingTimeInterval(1))

        let held = try await rig.record().readings.first { $0.component == .case }
        #expect(held?.level == 0.80, "the case froze at yesterday's level for the whole connection")
        #expect(held?.charging == .charging)
    }

    /// A catalogue from before `chargingReported` was kept: the evidence is
    /// only in the readings, and the first system refresh replaces them.
    @Test("An older catalogue keeps its charging evidence through the first system refresh")
    func legacyCatalogueKeepsChargingCapability() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let first = await Rig(at: t0.addingTimeInterval(-60), connected: true)
        try await first.advert(left: 0.40, right: nil, at: t0)
        await first.store.flush()

        var root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: first.url)) as? [String: Any]
        )
        var devices = try #require(root["devices"] as? [[String: Any]])
        for index in devices.indices { devices[index].removeValue(forKey: "chargingReported") }
        root["devices"] = devices
        try JSONSerialization.data(withJSONObject: root).write(to: first.url)

        let legacy = await Rig(at: t0, connected: true, url: first.url)
        let before = try await legacy.record()
        try #require(before.chargingReported == nil && before.reportsCharging(.left),
                     "the fixture is not a legacy record with charging evidence")

        await legacy.systemReading(["Left": 0.40], at: t0.addingTimeInterval(60))

        let after = try await legacy.record()
        try #require(after.readings.first { $0.component == .left }?.charging == .unknown)
        #expect(after.reportsCharging(.left), "the first refresh dimmed the charged alert for a set that reports charging")
    }

    // MARK: - Review round 3: the witness has to arrive, and outlive a relaunch

    /// The system's own report of the owner's set, as the Bluetooth card hands it over.
    private static func systemObservation(_ levels: [String: Double], at when: Date) -> DeviceObservation {
        DeviceObservations.fromBluetooth(
            BluetoothDeviceSnapshot(name: own.name, address: own.address, isConnected: true, batteryLevels: levels),
            at: when, cause: .periodicRefresh
        )
    }

    /// One Left advertisement through the real attribution.
    private static func airObservation(
        _ level: Double, charging: Bool, paired: PairedDeviceRegistry, at when: Date
    ) throws -> DeviceObservation {
        var proximity = AirPodsProximity(
            model: 0x1B20, leftBattery: level, rightBattery: nil, caseBattery: nil,
            isChargingLeft: charging, isChargingRight: false, isChargingCase: false, lidCounter: 1
        )
        proximity.peripheralID = UUID()
        proximity.rssi = -70
        let observation = try #require(DeviceObservations.fromProximity(proximity, paired: paired.current, at: when))
        try #require(observation.deviceID == own.identity)
        return observation
    }

    /// Holds one delivery in the mailbox until told to let it go.
    private actor Hold {
        private var entered = false
        private var waiting: CheckedContinuation<Void, Never>?
        private var watchers: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            entered = true
            for watcher in watchers { watcher.resume() }
            watchers.removeAll()
            await withCheckedContinuation { waiting = $0 }
        }
        func release() { waiting?.resume(); waiting = nil }
        /// Returns once a delivery is being held.
        func untilEntered() async {
            if entered { return }
            await withCheckedContinuation { watchers.append($0) }
        }
    }

    /// Polls until `condition` holds, for as long as that takes. No deadline:
    /// the full suite holds the main thread for longer than any short one.
    ///
    /// Throws when cancelled. Swallowing the sleep's error turned the suite's
    /// time limit into a hot loop on the main actor: the condition went on
    /// being checked, and the test would have gone on as though it held.
    private func whenTrue(_ condition: () async throws -> Bool) async throws {
        while try await !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Codex's probe: one low alert, a relaunch, then the owner's system
    /// report and a neighbour's charging advertisement queued behind an
    /// unrelated delivery, through the real mailbox.
    @Test("A system report queued behind an advertisement still reaches the catalogue, across a relaunch")
    func systemReportSurvivesTheMailbox() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let first = await Rig(at: t0.addingTimeInterval(-60), connected: true)
        await first.systemReading(["Left": 0.26], at: t0)
        await first.systemReading(["Left": 0.20], at: t0.addingTimeInterval(1))
        try #require(first.alerts.lows.count == 1, "the fixture's own crossing did not alert")
        await first.store.flush()

        // Relaunched, the paired list already answered.
        let rig = await Rig(at: t0, connected: true, url: first.url)
        let hold = Hold()
        let delivered = OSAllocatedUnfairLock(initialState: [DeviceObservation]())
        let blocker = DeviceObservations.fromBluetooth(
            BluetoothDeviceSnapshot(name: "Keyboard", address: "12:34:56:78:9A:BC", isConnected: true,
                                    batteryLevels: ["Battery": 0.8]),
            at: t0.addingTimeInterval(2), cause: .periodicRefresh
        )
        let store = rig.store
        let mailbox = ObservationMailbox { observation in
            if observation.canonicalID == blocker.canonicalID { await hold.wait() }
            delivered.withLock { $0.append(observation) }
            await store.record(observation)
        }
        mailbox.submit(blocker)
        await hold.untilEntered()

        rig.clock.withLock { $0 = t0.addingTimeInterval(2) }
        mailbox.submit(Self.systemObservation(["Left": 0.20], at: t0.addingTimeInterval(2)))
        rig.clock.withLock { $0 = t0.addingTimeInterval(3) }
        mailbox.submit(try Self.airObservation(0.30, charging: true, paired: rig.registry, at: t0.addingTimeInterval(3)))
        await hold.release()
        await mailbox.close()

        let ours = delivered.withLock { $0 }.filter { $0.canonicalID == Self.own.identity }
        try #require(ours.contains { $0.cause == .advertisement }, "the neighbour's advertisement never got through")
        #expect(ours.contains { $0.cause != .advertisement }, "the system's report was coalesced away")

        try await rig.advert(left: 0.20, right: nil, at: t0.addingTimeInterval(4))
        #expect(first.alerts.lows.count + rig.alerts.lows.count == 1,
                "the same low battery was announced again after a relaunch")
    }

    /// The same relaunch with nothing queued at all: what was on disk has to
    /// say the system was reporting this battery a moment ago.
    @Test("After a relaunch a neighbour's charging set still cannot release the owner's low alert")
    func witnessSurvivesARelaunch() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let first = await Rig(at: t0.addingTimeInterval(-60), connected: true)
        await first.systemReading(["Left": 0.26], at: t0)
        await first.systemReading(["Left": 0.20], at: t0.addingTimeInterval(1))
        try #require(first.alerts.lows.count == 1)
        await first.store.flush()

        let rig = await Rig(at: t0, connected: true, url: first.url)
        try await rig.advert(left: 0.30, right: nil, charging: true, at: t0.addingTimeInterval(3))
        let left = try await rig.record().readings.first { $0.component == .left }
        try #require(left?.level == 0.30 && left?.charging == .charging, "the neighbour's advertisement never got in")
        try await rig.advert(left: 0.20, right: nil, at: t0.addingTimeInterval(4))

        #expect(rig.alerts.lows.isEmpty, "the same low battery was announced again after a relaunch")
    }

    /// The Bluetooth card switched off: the AirPods card reads the paired list
    /// itself, and has to hand on what the system said about the earbuds.
    @Test("With only the AirPods card running, its own read of the paired list vouches for the earbuds")
    func inventoryOnlyPathSeedsTheWitness() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        // A list read long enough ago that the AirPods card reads it again.
        let rig = await Rig(at: t0.addingTimeInterval(-700), connected: true)
        // Advertisements alone: a low alert, no system evidence at all.
        try await rig.advert(left: 0.30, right: nil, at: t0)
        try await rig.advert(left: 0.20, right: nil, at: t0.addingTimeInterval(10))
        try #require(rig.alerts.lows.count == 1)
        try #require(try await rig.record().lastConnected == nil, "something other than the air already reported this set")

        let inventory = FixedInventory(PairedListReading(
            devices: [BluetoothDeviceSnapshot(
                name: Self.own.name, address: Self.own.address, isConnected: true,
                batteryLevels: ["Left": 0.20], symbolName: "airpods", isApple: true,
                vendorID: 0x004C, productID: 0x201B
            ), BluetoothDeviceSnapshot(
                name: "Keyboard", address: "12:34:56:78:9A:BC", isConnected: true,
                batteryLevels: ["Battery": 0.8]
            )],
            readAt: t0.addingTimeInterval(20)
        ))
        rig.clock.withLock { $0 = t0.addingTimeInterval(20) }
        let mailbox = ObservationMailbox(store: rig.store)
        let provider = AirPodsProximityProvider(
            scanner: QuietScanner(), observations: mailbox, paired: rig.registry,
            inventory: inventory, now: { t0.addingTimeInterval(20).timeIntervalSinceReferenceDate }
        )
        _ = provider.start()
        try await whenTrue { provider.inventoryReadsHandled >= 1 }
        provider.stop()
        await mailbox.close()
        try #require(inventory.reads >= 1, "the AirPods card never read the paired list")
        #expect(try await rig.record().lastConnected != nil,
                "the system's report of the earbuds never reached the catalogue")
        // The rest of the list is the Bluetooth card's business.
        #expect(!(await rig.store.snapshot().devices.contains { $0.name == "Keyboard" }),
                "the AirPods card catalogued a keyboard")

        try await rig.advert(left: 0.30, right: nil, charging: true, at: t0.addingTimeInterval(30))
        try await rig.advert(left: 0.20, right: nil, at: t0.addingTimeInterval(40))
        #expect(rig.alerts.lows.count == 1, "the same low battery was announced again")
    }

    /// Runs the AirPods card's own read of the paired list once, and says
    /// whether anything the system reported reached the owner's record.
    private func batteryReachedTheRecord(
        rig: Rig, reading: PairedListReading, at now: Date
    ) async throws -> Bool {
        let inventory = FixedInventory(reading)
        rig.clock.withLock { $0 = now }
        let mailbox = ObservationMailbox(store: rig.store)
        let provider = AirPodsProximityProvider(
            scanner: QuietScanner(), observations: mailbox, paired: rig.registry,
            inventory: inventory, now: { now.timeIntervalSinceReferenceDate }
        )
        _ = provider.start()
        // Past the read and its answer, whatever the answer was.
        try await whenTrue { provider.inventoryReadsHandled >= 1 }
        provider.stop()
        await mailbox.close()
        try #require(inventory.reads >= 1, "the AirPods card never read the paired list")
        return try await rig.record().lastConnected != nil
    }

    private static func ownSnapshot(left: Double) -> BluetoothDeviceSnapshot {
        BluetoothDeviceSnapshot(
            name: own.name, address: own.address, isConnected: true,
            batteryLevels: ["Left": left], symbolName: "airpods", isApple: true,
            vendorID: 0x004C, productID: 0x201B
        )
    }

    @Test("A paired-list reading the registry refused as older reports no battery")
    func olderInventoryReportsNothing() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        // Read 650 s ago: stale enough to ask again, newer than what comes back.
        let rig = await Rig(at: t0.addingTimeInterval(-650), connected: true)
        try await rig.advert(left: 0.30, right: nil, at: t0.addingTimeInterval(-640))
        try #require(try await rig.record().lastConnected == nil)

        let reached = try await batteryReachedTheRecord(
            rig: rig,
            reading: PairedListReading(devices: [Self.ownSnapshot(left: 0.30)], readAt: t0.addingTimeInterval(-700)),
            at: t0
        )
        #expect(!reached, "a reading older than the list already held put its levels in the catalogue")
    }

    @Test("A paired-list reading the system has since contradicted reports no battery")
    func contradictedInventoryReportsNothing() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let rig = await Rig(at: t0.addingTimeInterval(-700), connected: true)
        try await rig.advert(left: 0.30, right: nil, at: t0.addingTimeInterval(-690))
        try #require(try await rig.record().lastConnected == nil)
        // Gone, a moment after the list was sampled.
        rig.registry.connectionChanged(address: Self.own.address, isConnected: false, at: t0.addingTimeInterval(-5))

        let reached = try await batteryReachedTheRecord(
            rig: rig,
            reading: PairedListReading(devices: [Self.ownSnapshot(left: 0.30)], readAt: t0.addingTimeInterval(-10)),
            at: t0
        )
        #expect(!reached, "a set the system said had left was reported connected with its levels")
    }

    @Test("A cancelled wait fails rather than carrying on")
    func cancelledWaitThrows() async {
        let checks = OSAllocatedUnfairLock(initialState: 0)
        // Comes true on its own eventually, so a wait that ignores
        // cancellation returns normally instead of hanging this test.
        let waiting = Task { @MainActor in
            try await whenTrue { checks.withLock { $0 += 1; return $0 > 1_000 } }
        }
        waiting.cancel()
        let result = await waiting.result
        #expect(throws: CancellationError.self, "a cancelled wait went on to report its condition as met") {
            try result.get()
        }
    }

    // MARK: - Review round 3: a catalogue from before the witness was kept

    /// Writes a real catalogue, then takes `systemReportedAt` out of it, as a
    /// file saved by the build before it was kept.
    private static func stripWitness(at url: URL) throws {
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var devices = try #require(root["devices"] as? [[String: Any]])
        try #require(devices.contains { $0["systemReportedAt"] != nil }, "the fixture never wrote a witness to take out")
        for index in devices.indices { devices[index].removeValue(forKey: "systemReportedAt") }
        root["devices"] = devices
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let records = try #require(written["devices"] as? [[String: Any]])
        try #require(!records.contains { $0["systemReportedAt"] != nil }, "the witness is still in the file")
    }

    @Test("The first launch with an older catalogue still keeps a neighbour from rearming the low alert")
    func olderCatalogueKeepsItsWitness() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let first = await Rig(at: t0.addingTimeInterval(-60), connected: true)
        await first.systemReading(["Left": 0.26], at: t0)
        await first.systemReading(["Left": 0.20], at: t0.addingTimeInterval(1))
        try #require(first.alerts.lows.count == 1, "the fixture's own crossing did not alert")
        await first.store.flush()
        try Self.stripWitness(at: first.url)

        // Upgraded and relaunched; no new system sample has landed yet.
        let rig = await Rig(at: t0, connected: true, url: first.url)
        try await rig.advert(left: 0.30, right: nil, charging: true, at: t0.addingTimeInterval(3))
        let left = try await rig.record().readings.first { $0.component == .left }
        try #require(left?.level == 0.30 && left?.charging == .charging, "the neighbour's advertisement never got in")
        try await rig.advert(left: 0.20, right: nil, at: t0.addingTimeInterval(4))

        #expect(rig.alerts.lows.isEmpty, "the same low battery was announced again on the first launch after the upgrade")
    }

    /// What the seeding may not claim: the case from a reading of the buds,
    /// or anything from a sample heard over the air.
    @Test("An older catalogue's witness covers only what the system itself read")
    func olderCatalogueWitnessIsNarrow() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let first = await Rig(at: t0.addingTimeInterval(-60), connected: true)
        await first.systemReading(["Left": 0.40, "Right": 0.40], at: t0)
        // The case only ever heard over the air.
        try await first.advert(left: nil, right: nil, caseLevel: 0.20, at: t0.addingTimeInterval(1))
        // And the right bud's cell taken over by an advertisement since.
        try await first.advert(left: nil, right: 0.40, charging: true, at: t0.addingTimeInterval(1))
        let written = try await first.record()
        try #require(written.readings.first { $0.component == .case }?.origin == .proximityName)
        try #require(written.readings.first { $0.component == .right }?.origin == .proximityName)
        try #require(written.readings.first { $0.component == .left }?.origin == nil)
        await first.store.flush()
        try Self.stripWitness(at: first.url)

        let rig = await Rig(at: t0, connected: true, url: first.url)
        let reloaded = try await rig.record()
        #expect(reloaded.systemReportedAt?[.left] == t0, "the system's own Left reading was not taken as its witness")
        #expect(reloaded.systemReportedAt?[.case] == nil, "a case heard over the air was taken for one the system reported")
        #expect(reloaded.systemReportedAt?[.right] == nil, "a cell an advertisement had taken over was taken for the system's")

        // And so the case is not measured against that old advertised level.
        try await rig.advert(left: nil, right: nil, caseLevel: 0.80, charging: true, at: t0.addingTimeInterval(2))
        #expect(try await rig.record().readings.first { $0.component == .case }?.level == 0.80)
    }

    @Test("A catalogue that already keeps its witness has it left alone")
    func savedWitnessIsKept() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let first = await Rig(at: t0.addingTimeInterval(-60), connected: true)
        await first.systemReading(["Left": 0.40, "Right": 0.40], at: t0)
        // The left cell taken over by the owner's charging set since.
        try await first.advert(left: 0.40, right: nil, charging: true, at: t0.addingTimeInterval(1))
        let written = try await first.record()
        try #require(written.readings.first { $0.component == .left }?.origin == .proximityName)
        try #require(written.systemReportedAt?[.left] == t0)
        await first.store.flush()

        let rig = await Rig(at: t0, connected: true, url: first.url)
        #expect(try await rig.record().systemReportedAt?[.left] == t0,
                "loading rebuilt a witness the file already held, and lost the left bud's")
    }

    @Test("An older catalogue's reading marked stale vouches for nothing")
    func staleReadingIsNoWitness() async throws {
        let t0 = Date(timeIntervalSinceReferenceDate: 814_000_000)
        let first = await Rig(at: t0.addingTimeInterval(-60), connected: true)
        await first.systemReading(["Left": 0.40], at: t0)
        await first.store.flush()
        try Self.stripWitness(at: first.url)

        // As a source that had stopped being believed would have left it.
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: first.url)) as? [String: Any])
        var devices = try #require(root["devices"] as? [[String: Any]])
        var readings = try #require(devices[0]["readings"] as? [[String: Any]])
        try #require(readings.count == 1)
        readings[0]["reliability"] = "stale"
        devices[0]["readings"] = readings
        root["devices"] = devices
        try JSONSerialization.data(withJSONObject: root).write(to: first.url)

        let rig = await Rig(at: t0, connected: true, url: first.url)
        let reloaded = try await rig.record()
        try #require(reloaded.readings.first?.reliability == .stale, "the fixture did not load as stale")
        #expect(reloaded.systemReportedAt == nil, "a reading nobody should act on was taken as a witness")
    }
}

/// A scanner that never reports anything.
@MainActor
private final class QuietScanner: ProximityScanning {
    var onUpdate: (AirPodsProximity) -> Void = { _ in }
    var isOurs: (AirPodsProximity) -> Bool = { _ in true }
    func start() {}
    func stop() {}
}

/// A paired-list read that always says the same thing.
private final class FixedInventory: BluetoothDeviceSource, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    private let reading: PairedListReading
    init(_ reading: PairedListReading) { self.reading = reading }
    var isAvailable: Bool { true }
    var reads: Int { state.withLock { $0 } }
    func pairedDevices() async -> PairedListReading? {
        state.withLock { $0 += 1 }
        return reading
    }
    func startWatching(
        onConnect: @escaping (BluetoothDeviceSnapshot) -> Void,
        onDisconnect: @escaping (String) -> Void
    ) {}
    func stopWatching() {}
}
