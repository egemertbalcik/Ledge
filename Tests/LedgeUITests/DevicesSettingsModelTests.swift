import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// The pane's states, driven entirely from fake data. No store, no hardware,
/// no notification authorisation.
@Suite("Devices settings model")
@MainActor
struct DevicesSettingsModelTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private static func record(
        _ name: String,
        id: DeviceIdentity,
        presence: DevicePresence = .connected,
        level: Double? = 0.8,
        reliability: ReadingReliability = .fresh,
        lastSeen: TimeInterval = 0,
        pinned: Bool = false,
        hidden: Bool = false
    ) -> DeviceRecord {
        DeviceRecord(
            id: id, name: name, presence: presence,
            readings: level.map {
                [BatteryReading(
                    component: .left, level: $0,
                    observedAt: t0.addingTimeInterval(lastSeen), reliability: reliability
                )]
            } ?? [],
            firstSeen: t0, lastSeen: t0.addingTimeInterval(lastSeen),
            isPinned: pinned, isHidden: hidden
        )
    }

    private static func model(
        _ catalogue: DeviceCatalogue,
        history: [BatterySample] = [],
        now: TimeInterval = 0
    ) -> DevicesSettingsModel {
        DevicesSettingsModel(
            actions: .init(
                load: { catalogue },
                history: { _ in history }
            ),
            now: { t0.addingTimeInterval(now) }
        )
    }

    /// Waits for the model to finish loading rather than sleeping a guessed
    /// interval. A fixed sleep is a bet on how fast the machine is, and under
    /// a parallel suite that bet loses often enough to be useless.
    private func settle(
        _ model: DevicesSettingsModel,
        upTo seconds: TimeInterval = 5
    ) async throws {
        try await waitUntil(upTo: seconds) { model.hasLoaded }
    }

    /// Waits for whatever the test is actually about.
    private func waitUntil(
        upTo seconds: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A new installation shows an empty state, distinct from not-yet-loaded")
    func emptyState() async throws {
        let model = Self.model(DeviceCatalogue())
        #expect(!model.hasLoaded, "an unloaded model must not look like an empty one")
        model.load()
        try await settle(model)
        #expect(model.hasLoaded)
        #expect(model.rows.isEmpty)
    }

    @Test("Pinned devices sort first, then the most recently seen")
    func sortOrder() async throws {
        var catalogue = DeviceCatalogue()
        catalogue.devices = [
            Self.record("Old", id: .bluetooth("aa"), lastSeen: -3600),
            Self.record("Recent", id: .bluetooth("bb"), lastSeen: -60),
            Self.record("Pinned", id: .bluetooth("cc"), lastSeen: -7200, pinned: true),
        ]
        let model = Self.model(catalogue)
        model.load()
        try await settle(model)
        #expect(model.rows.map(\.name) == ["Pinned", "Recent", "Old"])
    }

    @Test("Hidden devices do not appear")
    func hiddenAreOmitted() async throws {
        var catalogue = DeviceCatalogue()
        catalogue.devices = [
            Self.record("Shown", id: .bluetooth("aa")),
            Self.record("Hidden", id: .bluetooth("bb"), hidden: true),
        ]
        let model = Self.model(catalogue)
        model.load()
        try await settle(model)
        #expect(model.rows.map(\.name) == ["Shown"])
    }

    /// The window belongs to the source, so the test asks the source for it
    /// rather than hard-coding a number that would drift.
    private var staleAge: TimeInterval {
        DeviceIdentity.bluetooth("bb").freshnessInterval + 60
    }

    @Test("An old reading is marked stale rather than shown as current")
    func staleIsMarked() async throws {
        var catalogue = DeviceCatalogue()
        catalogue.devices = [
            Self.record("Fresh", id: .bluetooth("aa"), lastSeen: -60),
            Self.record("Old", id: .bluetooth("bb"), lastSeen: -staleAge),
        ]
        let model = Self.model(catalogue)
        model.load()
        try await settle(model)

        #expect(model.rows.first { $0.name == "Fresh" }?.isStale == false)
        #expect(
            model.rows.first { $0.name == "Old" }?.isStale == true,
            "a device last heard from an hour ago was presented as current"
        )
    }

    @Test("A pinned device that is offline still shows, with its last state")
    func pinnedOfflineShowsStale() async throws {
        var catalogue = DeviceCatalogue()
        catalogue.devices = [Self.record(
            "Pinned AirPods", id: .bluetooth("aa"),
            presence: .unknown, level: 0.42,
            lastSeen: -staleAge, pinned: true
        )]
        let model = Self.model(catalogue)
        model.load()
        try await settle(model)

        let row = try #require(model.rows.first)
        #expect(row.isPinned)
        #expect(row.presence == .unknown)
        #expect(row.lowestLevel == 0.42)
        #expect(row.isStale, "a pinned offline device presented an old level as current")
    }

    @Test("A device with no battery reports none rather than zero")
    func neverObservedBattery() async throws {
        var catalogue = DeviceCatalogue()
        catalogue.devices = [Self.record("Keyboard", id: .bluetooth("aa"), level: nil)]
        let model = Self.model(catalogue)
        model.load()
        try await settle(model)
        #expect(model.rows.first?.lowestLevel == nil, "a device with no battery was drawn at 0%")
    }

    @Test("Selecting a device loads its history; the list does not")
    func historyIsLazy() async throws {
        var catalogue = DeviceCatalogue()
        let id = DeviceIdentity.bluetooth("aa")
        catalogue.devices = [Self.record("AirPods", id: id)]
        let samples = [BatterySample(
            component: .left, level: 0.5, charging: .unknown, at: paneT0, isConnected: true
        )]

        let model = Self.model(catalogue, history: samples)
        model.load()
        try await settle(model)
        #expect(model.history.isEmpty, "the list loaded history for a device nobody opened")

        model.select(id)
        // `hasLoaded` is already true here, so wait for the selection itself.
        try await waitUntil { model.selected != nil }
        #expect(model.selected?.id == id)
        #expect(model.history.count == 1)

        model.clearSelection()
        #expect(model.history.isEmpty)
    }

    /// Cancelling must stop the result being applied, which is checkable: the
    /// load is held open, cancelled, then released — and the model must not
    /// have taken the value.
    ///
    /// An earlier version waited five seconds for `hasLoaded` on a load it had
    /// just cancelled and then asserted `true`, which proved nothing at all.
    @Test("Cancelling stops the result reaching the model")
    func cancelStopsWork() async throws {
        let release = OSAllocatedUnfairLockBoxUI()
        let catalogue: DeviceCatalogue = {
            var c = DeviceCatalogue()
            c.devices = [DeviceRecord(
                id: .bluetooth("aa"), name: "AirPods", presence: .connected,
                firstSeen: paneT0, lastSeen: paneT0
            )]
            return c
        }()

        let model = DevicesSettingsModel(
            actions: .init(load: {
                // Held until the test lets it go, so the cancellation lands
                // while the load is genuinely in flight.
                while release.count == 0 {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                return catalogue
            }),
            now: { paneT0 }
        )

        model.load()
        model.cancel()
        release.bump()

        // Give the released load every chance to apply itself.
        try await Task.sleep(for: .milliseconds(200))
        #expect(!model.hasLoaded, "a cancelled load still applied its result")
        #expect(model.rows.isEmpty)
    }

    @Test("Notification delivery stays off when authorisation is denied")
    func deniedAuthorizationLeavesDeliveryOff() async {
        let model = DevicesSettingsModel(
            actions: .init(
                load: { DeviceCatalogue() },
                requestNotificationAuthorization: { false }
            ),
            now: { paneT0 }
        )
        let granted = await model.requestNotificationAuthorization()
        #expect(!granted)

        var rule = BatteryAlertRule(kind: .low, threshold: 0.2)
        if granted { rule.delivery.insert(.notification) }
        #expect(
            !rule.delivery.contains(.notification),
            "a denied prompt still switched notification delivery on"
        )
        #expect(rule.delivery.contains(.notch))
    }

    @Test("Previewing does not change the rule")
    func previewIsInert() async {
        let previewed = OSAllocatedUnfairLockBoxUI()
        let model = DevicesSettingsModel(
            actions: .init(
                load: { DeviceCatalogue() },
                preview: { _, _ in previewed.bump() }
            ),
            now: { paneT0 }
        )
        let rule = BatteryAlertRule(kind: .low, threshold: 0.2)
        model.preview(rule, deviceName: "AirPods")
        #expect(previewed.count == 1)
        #expect(rule.threshold == 0.2, "previewing mutated the rule")
    }
}

import os

final class OSAllocatedUnfairLockBoxUI: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    func bump() { lock.withLock { $0 += 1 } }
    var count: Int { lock.withLock { $0 } }
}

/// Rule editing: a slider produces a mutation per frame, and the last value
/// the user chose must be the one that lands.
@Suite("Device rule writes", .serialized)
@MainActor
struct DeviceRuleWriteTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private static let id = DeviceIdentity.bluetooth("aa:bb")

    private final class Writes: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [Double]())
        func record(_ threshold: Double) { state.withLock { $0.append(threshold) } }
        var thresholds: [Double] { state.withLock { $0 } }

        /// Waits for a condition rather than sleeping a guessed interval.
        ///
        /// A fixed sleep is a bet on how fast the machine is, and under a
        /// parallel suite that bet loses: this asserted after 300ms on a write
        /// that normally takes 30, and failed about one run in six.
        func wait(
            upTo seconds: TimeInterval = 5,
            until condition: @escaping @Sendable ([Double]) -> Bool
        ) async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition(thresholds) { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @Test("The newest configuration is what lands, in order")
    func newestWins() async throws {
        let writes = Writes()
        let model = DevicesSettingsModel(
            actions: .init(
                load: { DeviceCatalogue() },
                setAlerts: { _, configuration in
                    // Slow enough that the next edits queue behind it.
                    try? await Task.sleep(for: .milliseconds(20))
                    writes.record(configuration.rules.first?.threshold ?? -1)
                }
            ),
            now: { paneT0 }
        )

        // A drag: twenty values in a row.
        for step in 1...20 {
            let threshold = Double(step) / 100.0 + 0.05
            model.setAlerts(
                DeviceAlertConfiguration(
                    rules: [BatteryAlertRule(kind: .low, threshold: threshold)],
                    isCustomised: true
                ),
                for: paneID
            )
        }

        // The last value of the drag is 0.25; wait for it rather than for a
        // fixed interval.
        await writes.wait { $0.last == 0.25 }

        let landed = writes.thresholds
        #expect(!landed.isEmpty)
        #expect(
            landed.count < 20,
            "every frame of a drag reached the store: \(landed.count) writes"
        )
        #expect(
            landed.last == 0.25,
            "an older value landed last: \(String(describing: landed.last))"
        )
    }

    @Test("A pending write survives the pane closing")
    func writesSurviveClose() async throws {
        let writes = Writes()
        let model = DevicesSettingsModel(
            actions: .init(
                load: { DeviceCatalogue() },
                setAlerts: { _, configuration in
                    try? await Task.sleep(for: .milliseconds(30))
                    writes.record(configuration.rules.first?.threshold ?? -1)
                }
            ),
            now: { paneT0 }
        )
        model.setAlerts(
            DeviceAlertConfiguration(
                rules: [BatteryAlertRule(kind: .low, threshold: 0.3)], isCustomised: true
            ),
            for: paneID
        )
        // The user closes the window immediately afterwards.
        model.cancel()

        await writes.wait { $0.contains(0.3) }
        #expect(
            writes.thresholds.contains(0.3),
            "closing the pane threw away a rule change the user had just made"
        )
    }

    /// Turning notifications off while the system prompt is still up must not
    /// be undone by answering it.
    @Test("A permission answer cannot re-enable delivery that was switched off")
    func permissionAnswerIsDisowned() async {
        let model = DevicesSettingsModel(
            actions: .init(
                load: { DeviceCatalogue() },
                requestNotificationAuthorization: {
                    try? await Task.sleep(for: .milliseconds(60))
                    return true
                }
            ),
            now: { paneT0 }
        )

        async let answer = model.requestNotificationAuthorization()
        try? await Task.sleep(for: .milliseconds(10))
        // The user switches it back off while the prompt is up.
        model.notificationDeliveryWasDisabled()

        let granted = await answer
        #expect(!granted, "answering the prompt turned notifications back on after the user disabled them")
    }
}

/// Selection, refresh and quit-time draining.
/// Outside the actor, so the store-facing closures can read them.
private let paneT0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
private let paneID = DeviceIdentity.bluetooth("aa:bb")
private let paneOther = DeviceIdentity.bluetooth("cc:dd")

private func paneCatalogue(includingOther: Bool = false) -> DeviceCatalogue {
    var c = DeviceCatalogue()
    c.devices = [DeviceRecord(
        id: paneID, name: "AirPods", presence: .connected,
        readings: [BatteryReading(component: .left, level: 0.5, observedAt: paneT0)],
        firstSeen: paneT0, lastSeen: paneT0
    )]
    if includingOther {
        c.devices.append(DeviceRecord(
            id: paneOther, name: "Mouse", presence: .connected,
            firstSeen: paneT0, lastSeen: paneT0
        ))
    }
    return c
}

@Suite("Devices pane lifecycle", .serialized)
@MainActor
struct DevicesPaneLifecycleTests {

    /// The list refresh and a selection shared one task handle, so a refresh
    /// landing while history loaded cancelled the selection — the click did
    /// nothing and looked broken.
    @Test("A list refresh does not cancel a selection in flight")
    func refreshDoesNotCancelSelection() async throws {
        let model = DevicesSettingsModel(
            actions: .init(
                load: { paneCatalogue() },
                history: { _ in
                    // Slow, so a refresh can land on top of it.
                    try? await Task.sleep(for: .milliseconds(120))
                    return [BatterySample(
                        component: .left, level: 0.5, charging: .unknown,
                        at: paneT0, isConnected: true
                    )]
                }
            ),
            now: { paneT0 }
        )

        model.select(paneID)
        // A refresh arrives mid-selection, exactly as the five-second one does.
        model.load(showingProgress: false)

        for _ in 0..<80 where model.selected == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.selected?.id == paneID, "the refresh cancelled the selection")

        for _ in 0..<80 where model.history.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.history.isEmpty, "the selection's history never arrived")
    }

    @Test("A history read for a device no longer open is discarded")
    func staleHistoryIsDiscarded() async throws {
        let other = paneOther
        let model = DevicesSettingsModel(
            actions: .init(
                load: { paneCatalogue(includingOther: true) },
                history: { id in
                    // The first device's history is slow; the second's is not.
                    if id == paneID { try? await Task.sleep(for: .milliseconds(150)) }
                    return [BatterySample(
                        component: id == paneID ? .left : .main,
                        level: 0.5, charging: .unknown, at: paneT0, isConnected: true
                    )]
                }
            ),
            now: { paneT0 }
        )

        model.select(paneID)
        model.select(other)                      // the user moves on

        // Waited for, not slept through: a fixed interval is a bet on how
        // fast the machine is, and under a parallel suite that bet loses.
        let deadline = Date().addingTimeInterval(5)
        while model.selected?.id != other, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.selected?.id == other)

        // And give the slow first read every chance to land wrongly.
        try await Task.sleep(for: .milliseconds(250))
        #expect(
            model.history.allSatisfy { $0.component == .main },
            "the first device's history landed on the second"
        )
    }

    /// Pin, hide, forget and delete-history were untracked tasks, so quitting
    /// immediately could flush the store before they arrived.
    @Test("Quitting waits for a pin that is still in flight")
    func drainWaitsForOneShotEdits() async throws {
        let landed = OSAllocatedUnfairLockBoxUI()
        let model = DevicesSettingsModel(
            actions: .init(
                load: { paneCatalogue() },
                setPinned: { _, _ in
                    try? await Task.sleep(for: .milliseconds(80))
                    landed.bump()
                }
            ),
            now: { paneT0 }
        )

        model.setPinned(true, for: paneID)
        await model.drainPendingWrites()
        #expect(landed.count == 1, "the quit flush did not wait for the pin")
    }

    @Test("Draining with nothing outstanding returns at once")
    func drainWithNothingPending() async {
        let model = DevicesSettingsModel(actions: .init(load: { DeviceCatalogue() }), now: { paneT0 })
        await model.drainPendingWrites()
        #expect(Bool(true))
    }
}

/// Durable edits must land in the order they were made.
@Suite("Devices pane edit ordering", .serialized)
@MainActor
struct DevicesPaneEditOrderingTests {

    private final class Log: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [String]())
        func add(_ s: String) { state.withLock { $0.append(s) } }
        var all: [String] { state.withLock { $0 } }
    }

    /// Pin then unpin, quickly. Independent tasks could reach the store in
    /// either order, persisting the pin — the older choice landing last.
    @Test("Rapid pin and unpin persist in the order they were made")
    func pinOrderIsPreserved() async {
        let log = Log()
        let model = DevicesSettingsModel(
            actions: .init(
                load: { paneCatalogue() },
                setPinned: { _, pinned in
                    // The first write is slow, so an unordered second could
                    // overtake it.
                    if pinned { try? await Task.sleep(for: .milliseconds(60)) }
                    log.add(pinned ? "on" : "off")
                }
            ),
            now: { paneT0 }
        )

        model.setPinned(true, for: paneID)
        model.setPinned(false, for: paneID)
        await model.drainPendingWrites()

        #expect(log.all == ["on", "off"], "edits landed as \(log.all)")
    }

    @Test("A mix of edit kinds keeps its order")
    func mixedEditsKeepOrder() async {
        let log = Log()
        let model = DevicesSettingsModel(
            actions: .init(
                load: { paneCatalogue() },
                setPinned: { _, on in
                    try? await Task.sleep(for: .milliseconds(40))
                    log.add("pin:\(on)")
                },
                setHidden: { _, on in log.add("hide:\(on)") },
                deleteAllHistory: { log.add("deleteHistory") }
            ),
            now: { paneT0 }
        )

        model.setPinned(true, for: paneID)
        model.hide(paneID)
        model.deleteAllHistory()
        await model.drainPendingWrites()

        #expect(log.all == ["pin:true", "hide:true", "deleteHistory"], "order was \(log.all)")
    }

    /// Forgetting must clear the observation mailbox's memory too, or an
    /// unchanged device will not be reported again until the heartbeat.
    @Test("Forgetting a device clears the mailbox as well as the record")
    func forgettingClearsTheMailbox() async {
        let log = Log()
        let model = DevicesSettingsModel(
            actions: .init(
                load: { paneCatalogue() },
                forget: { _, keep in log.add("forget:keep=\(keep)") }
            ),
            now: { paneT0 }
        )
        model.forget(paneID, keepingHistory: true)
        await model.drainPendingWrites()
        #expect(log.all == ["forget:keep=true"])
    }
}
