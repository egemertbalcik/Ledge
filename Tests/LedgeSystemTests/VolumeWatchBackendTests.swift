import CoreAudio
import Foundation
import os
import Testing

@testable import LedgeSystem

/// What the volume watcher is allowed to ask the hardware for.
///
/// These count calls that crossed the boundary rather than objects held on this
/// side of it, because the failure being guarded against was invisible to the
/// Swift side: registrations accumulated inside CoreAudio while every array
/// looked balanced and every status said noErr.
@Suite("Volume watch backend")
struct VolumeWatchBackendTests {

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private func started() -> (VolumeWatchBackend, FakeAudioHardware) {
        let hardware = FakeAudioHardware()
        let backend = VolumeWatchBackend(hardware: hardware)
        backend.start { _ in }
        backend.settleForTesting()
        return (backend, hardware)
    }

    // MARK: - Starting

    @Test("Arming holds one system listener and at most four device listeners")
    func armingIsBounded() {
        let (backend, hardware) = started()
        #expect(hardware.systemRegistrations.count == 1)
        #expect(hardware.deviceRegistrations.count <= VolumeWatchBackend.maximumDeviceListeners)
        #expect(hardware.liveCount == backend.registrationCount())
        backend.stop()
    }

    @Test("Arming again touches the hardware not at all")
    func repeatedStartsDoNothing() {
        let (backend, hardware) = started()
        let adds = hardware.addCount
        let removes = hardware.removeCount

        for _ in 0..<50 {
            backend.start { _ in }
        }
        backend.settleForTesting()

        #expect(hardware.addCount == adds, "a repeated start registered something")
        #expect(hardware.removeCount == removes, "a repeated start unregistered something")
        backend.stop()
    }

    // MARK: - Notifications

    @Test("A hundred thousand notifications about an unchanged device cause no churn")
    func unchangedNotificationsDoNotChurn() {
        let (backend, hardware) = started()
        let adds = hardware.addCount
        let removes = hardware.removeCount

        for _ in 0..<100_000 {
            hardware.fireDefaultDeviceChanged()
        }
        backend.settleForTesting()
        // The reconcile is deferred, so let the coalescing window pass and
        // settle again rather than assuming it has run.
        Thread.sleep(forTimeInterval: 0.2)
        backend.settleForTesting()

        #expect(hardware.addCount == adds, "\(hardware.addCount - adds) registrations from notifications alone")
        #expect(hardware.removeCount == removes, "\(hardware.removeCount - removes) removals from notifications alone")
        #expect(hardware.liveCount == backend.registrationCount())
        backend.stop()
    }

    @Test("A real switch replaces only the device listeners")
    func switchReplacesOnlyDeviceListeners() {
        let (backend, hardware) = started()
        let systemBefore = hardware.systemRegistrations.map(\.id)
        let deviceBefore = hardware.deviceRegistrations.map(\.id)
        #expect(!deviceBefore.isEmpty)

        hardware.setDefaultDevice(200)
        hardware.fireDefaultDeviceChanged()
        Thread.sleep(forTimeInterval: 0.2)
        backend.settleForTesting()

        #expect(hardware.systemRegistrations.map(\.id) == systemBefore, "the system listener was replaced")
        let deviceAfter = hardware.deviceRegistrations.map(\.id)
        #expect(Set(deviceAfter).isDisjoint(with: Set(deviceBefore)), "device listeners were not replaced")
        #expect(hardware.deviceRegistrations.allSatisfy { $0.object == 200 })
        #expect(hardware.deviceRegistrations.count <= VolumeWatchBackend.maximumDeviceListeners)
        #expect(backend.boundDeviceForTesting() == 200)
        backend.stop()
    }

    // MARK: - Things going away and coming back

    @Test("Losing every output keeps the listener that notices one returning")
    func lostOutputKeepsRecovery() {
        let (backend, hardware) = started()

        hardware.setDefaultDevice(nil)
        hardware.fireDefaultDeviceChanged()
        Thread.sleep(forTimeInterval: 0.2)
        backend.settleForTesting()

        #expect(hardware.systemRegistrations.count == 1, "nothing is left to notice a device coming back")
        #expect(hardware.deviceRegistrations.isEmpty)

        hardware.setDefaultDevice(100)
        hardware.fireDefaultDeviceChanged()
        Thread.sleep(forTimeInterval: 0.2)
        backend.settleForTesting()

        #expect(!hardware.deviceRegistrations.isEmpty, "did not rebind when a device came back")
        #expect(hardware.systemRegistrations.count == 1)
        backend.stop()
    }

    @Test("An incomplete bind is repaired, not left half-listening forever")
    func incompleteBindRecovers() {
        let hardware = FakeAudioHardware()
        // Refuse everything the first bind asks for except the system listener.
        let backend = VolumeWatchBackend(hardware: hardware)
        hardware.refuseNextRegistrations(0)
        backend.start { _ in }
        backend.settleForTesting()
        let healthy = hardware.deviceRegistrations.count
        backend.stop()
        backend.settleForTesting()

        let hardware2 = FakeAudioHardware()
        let backend2 = VolumeWatchBackend(hardware: hardware2)
        hardware2.refuseNextRegistrations(1 + healthy)   // system + every device listener
        backend2.start { _ in }
        backend2.settleForTesting()
        #expect(hardware2.addsRefused > 0)

        // A later notification must be allowed to try again, even though the
        // device ID has not changed: an unchanged ID is not proof the binding
        // is sound.
        hardware2.fireDefaultDeviceChanged()
        backend2.start { _ in }
        backend2.settleForTesting()
        #expect(hardware2.deviceRegistrations.count == healthy, "the incomplete bind was never repaired")
        backend2.stop()
    }

    @Test("Registration refused everywhere leaves nothing live and does not spin")
    func totalRefusal() {
        let hardware = FakeAudioHardware()
        hardware.setRefusesAll(true)
        let backend = VolumeWatchBackend(hardware: hardware)
        backend.start { _ in }
        backend.settleForTesting()
        #expect(hardware.liveCount == 0)
        #expect(backend.registrationCount() == 0)
        let adds = hardware.addCount
        Thread.sleep(forTimeInterval: 0.2)
        backend.settleForTesting()
        #expect(hardware.addCount == adds, "it kept retrying on its own")
        backend.stop()
    }

    // MARK: - Stopping

    @Test("Stopping takes every registration off")
    func stopReleasesEverything() {
        let (backend, hardware) = started()
        #expect(hardware.liveCount > 0)
        backend.stop()
        backend.settleForTesting()
        #expect(hardware.liveCount == 0, "\(hardware.liveCount) registrations survived a stop")
        #expect(hardware.addCount == hardware.removeCount, "adds and removes did not balance")
    }

    @Test("A callback queued before a stop cannot revive the watcher")
    func staleCallbackCannotResurrect() {
        let (backend, hardware) = started()
        let adds = hardware.addCount

        // Fire, then stop before the deferred reconcile can run.
        hardware.fireDefaultDeviceChanged()
        hardware.setDefaultDevice(200)
        backend.stop()
        Thread.sleep(forTimeInterval: 0.2)
        backend.settleForTesting()

        #expect(hardware.liveCount == 0, "a stale callback rebuilt a stopped watcher")
        #expect(hardware.addCount == adds, "a stale callback registered something new")
        #expect(backend.registrationCount() == 0)
    }

    @Test("Stop and start repeatedly leaves the count where it began")
    func stopStartIsBounded() {
        let (backend, hardware) = started()
        let live = hardware.liveCount
        for _ in 0..<25 {
            backend.stop()
            backend.start { _ in }
        }
        backend.settleForTesting()
        #expect(hardware.liveCount == live, "\(hardware.liveCount) live after 25 rounds, began with \(live)")
        #expect(hardware.addCount == hardware.removeCount + hardware.liveCount)
        backend.stop()
    }

    // MARK: - Where the work happens

    @Test("The hardware is never touched on the main thread")
    func administrationStaysOffMain() {
        let (backend, hardware) = started()
        hardware.setDefaultDevice(200)
        hardware.fireDefaultDeviceChanged()
        Thread.sleep(forTimeInterval: 0.2)
        backend.settleForTesting()
        backend.stop()
        backend.settleForTesting()

        #expect(hardware.callsOffMain > 0, "the fake was never called at all")
        #expect(
            !hardware.everRanOnMainThread,
            "registration or a hardware read ran on the main thread — that is what froze the app"
        )
    }
}

/// The five probes the second review reproduced, as permanent tests.
///
/// Each one failed before the corrections: a readout arriving after stop, forty
/// deliveries against a held main thread, a system listener that stayed missing,
/// two hundred registration attempts on a refused binding, and three hundred
/// hardware reads for a hundred notifications.
@Suite("Volume watch backend under stress", .serialized)
struct VolumeWatchBackendStressTests {

    /// Deliveries land here rather than on the main queue, so a test can hold
    /// the consumer still without starving every other test in the run.
    private static func deliveryQueue() -> DispatchQueue {
        DispatchQueue(label: "test.volume.delivery")
    }

    private static func drain(_ queue: DispatchQueue) {
        for _ in 0..<3 {
            queue.sync {}
            Thread.sleep(forTimeInterval: 0.1)
        }
        queue.sync {}
    }

    @Test("No readout arrives after a stop")
    func noDeliveryAfterStop() {
        let hardware = FakeAudioHardware()
        let ui = Self.deliveryQueue()
        let backend = VolumeWatchBackend(hardware: hardware, deliveryQueue: ui)
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let afterStop = OSAllocatedUnfairLock(initialState: 0)

        backend.start { _ in
            delivered.withLock { $0 += 1 }
            if stopped.withLock({ $0 }) { afterStop.withLock { $0 += 1 } }
        }
        backend.settleForTesting()
        Self.drain(ui)

        backend.stop()
        stopped.withLock { $0 = true }
        backend.settleForTesting()
        Self.drain(ui)

        #expect(afterStop.withLock { $0 } == 0, "a readout was delivered after the watcher stopped")
    }

    @Test("A held main thread accumulates one delivery, not one per refresh")
    func mailboxIsBoundedThroughMain() {
        let hardware = FakeAudioHardware()
        let ui = Self.deliveryQueue()
        let backend = VolumeWatchBackend(hardware: hardware, deliveryQueue: ui)
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        backend.start { _ in delivered.withLock { $0 += 1 } }
        backend.settleForTesting()
        Self.drain(ui)
        delivered.withLock { $0 = 0 }

        // Hold the consumer still while the backend produces forty readouts.
        let release = DispatchSemaphore(value: 0)
        let holding = DispatchSemaphore(value: 0)
        ui.async {
            holding.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        _ = holding.wait(timeout: .now() + 5)

        for i in 0..<40 {
            hardware.setLevel(Double(i) / 100.0, on: 100)
            backend.refresh()
        }
        backend.settleForTesting()
        release.signal()
        Self.drain(ui)

        let count = delivered.withLock { $0 }
        #expect(count <= 1, "\(count) deliveries queued behind a stalled consumer; expected at most one")
        backend.stop()
    }

    @Test("A refused system listener is put back, not left missing")
    func systemListenerIsRepaired() {
        let hardware = FakeAudioHardware()
        hardware.refuseSelector(kAudioHardwarePropertyDefaultOutputDevice)
        let backend = VolumeWatchBackend(hardware: hardware)
        backend.start { _ in }
        backend.settleForTesting()
        #expect(hardware.systemRegistrations.isEmpty, "the fixture did not refuse it")
        #expect(!hardware.deviceRegistrations.isEmpty, "device listeners should still be healthy")

        hardware.stopRefusingSelectors()
        backend.start { _ in }
        backend.settleForTesting()
        #expect(
            hardware.systemRegistrations.count == 1,
            "the recovery listener was never re-armed, so nothing would notice a device change again"
        )
        backend.stop()
    }

    @Test("A binding that keeps being refused does not retry without limit")
    func incompleteBindingHasABudget() {
        let hardware = FakeAudioHardware()
        hardware.refuseSelector(kAudioDevicePropertyVolumeScalar)
        let backend = VolumeWatchBackend(hardware: hardware)
        backend.start { _ in }
        backend.settleForTesting()

        let afterFirst = hardware.addCount
        for _ in 0..<50 {
            backend.start { _ in }
        }
        backend.settleForTesting()
        let spent = hardware.addCount - afterFirst

        // Three repairs at most, each trying the handful of missing addresses.
        #expect(spent <= 3 * 4, "\(spent) registration attempts across 50 starts — the budget is not bounded")
        backend.stop()
    }

    @Test("A partial refusal keeps the listeners that did register")
    func partialRefusalPreservesHealthyListeners() {
        let hardware = FakeAudioHardware()
        hardware.refuseSelector(kAudioDevicePropertyVolumeScalar)
        let backend = VolumeWatchBackend(hardware: hardware)
        backend.start { _ in }
        backend.settleForTesting()

        let healthy = hardware.deviceRegistrations.map(\.id)
        #expect(!healthy.isEmpty, "mute should have registered")

        backend.start { _ in }
        backend.settleForTesting()
        let after = hardware.deviceRegistrations.map(\.id)
        #expect(
            Set(healthy).isSubset(of: Set(after)),
            "a repair discarded listeners that were already working"
        )
        backend.stop()
    }

    @Test("A hundred level notifications do not make a hundred hardware reads")
    func levelNotificationsCoalesce() {
        let hardware = FakeAudioHardware()
        let ui = Self.deliveryQueue()
        let backend = VolumeWatchBackend(hardware: hardware, deliveryQueue: ui)
        backend.start { _ in }
        backend.settleForTesting()
        Self.drain(ui)

        let before = hardware.callsOffMain
        for _ in 0..<100 {
            hardware.fire(selector: kAudioDevicePropertyVolumeScalar)
        }
        backend.settleForTesting()
        Self.drain(ui)
        let reads = hardware.callsOffMain - before

        // Three registered scalar elements means 300 callbacks. Coalesced,
        // that is a handful of reads rather than one per callback.
        #expect(reads < 100, "\(reads) hardware calls for 100 notifications — they are not coalescing")
        backend.stop()
    }
}

/// Transitions: the states a watcher passes *through*, which is where the last
/// round of blockers lived. Each of these failed before the corrections.
@Suite("Volume watch transitions", .serialized)
struct VolumeWatchTransitionTests {

    private static func deliveryQueue() -> DispatchQueue {
        DispatchQueue(label: "test.volume.transitions")
    }

    private static func drain(_ queue: DispatchQueue) {
        for _ in 0..<3 {
            queue.sync {}
            Thread.sleep(forTimeInterval: 0.1)
        }
        queue.sync {}
    }

    @Test("Arming twice does not silence later updates")
    func repeatedStartKeepsDelivering() {
        let hardware = FakeAudioHardware()
        let ui = Self.deliveryQueue()
        let backend = VolumeWatchBackend(hardware: hardware, deliveryQueue: ui)
        let seen = OSAllocatedUnfairLock(initialState: [Double]())

        backend.start { readout in seen.withLock { $0.append(readout.level) } }
        backend.settleForTesting()
        Self.drain(ui)

        // HUDCoordinator does this on settings and permission changes.
        backend.start { readout in seen.withLock { $0.append(readout.level) } }
        backend.settleForTesting()
        Self.drain(ui)
        seen.withLock { $0.removeAll() }

        hardware.setLevel(0.77, on: 100)
        hardware.fire(selector: kAudioDevicePropertyVolumeScalar)
        backend.settleForTesting()
        Self.drain(ui)

        #expect(
            seen.withLock({ $0 }).contains(0.77),
            "no delivery after a repeated start — the live listeners were orphaned by a new session"
        )
        backend.stop()
    }

    @Test("Going away and back again does not deliver the value in between")
    func returningToTheDisplayedValueDropsTheIntermediate() {
        let ui = Self.deliveryQueue()
        let mailbox = MainMailbox<Int>(isEqual: ==, deliveryQueue: ui)
        let seen = OSAllocatedUnfairLock(initialState: [Int]())
        let session = mailbox.open { value in seen.withLock { $0.append(value) } }

        // Let 1 land, so it is what main is displaying.
        mailbox.post(1, generation: session)
        Self.drain(ui)
        seen.withLock { $0.removeAll() }

        // Hold main, move to 2, then back to 1 before anything is delivered.
        let release = DispatchSemaphore(value: 0)
        let holding = DispatchSemaphore(value: 0)
        ui.async {
            holding.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        _ = holding.wait(timeout: .now() + 5)

        mailbox.post(2, generation: session)
        mailbox.post(1, generation: session)

        release.signal()
        Self.drain(ui)

        #expect(
            !seen.withLock({ $0 }).contains(2),
            "delivered the intermediate value after the state had returned to what was displayed"
        )
        mailbox.close()
    }

    @Test("A route name cannot arrive after the watcher stopped")
    func routeDeliveryIsGatedAtTheEndpoint() {
        let ui = Self.deliveryQueue()
        let mailbox = MainMailbox<String>(isEqual: ==, deliveryQueue: ui)
        let afterClose = OSAllocatedUnfairLock(initialState: 0)
        let closed = OSAllocatedUnfairLock(initialState: false)

        let session = mailbox.open { _ in
            if closed.withLock({ $0 }) { afterClose.withLock { $0 += 1 } }
        }

        // Hold main so the hop is enqueued but not yet run, then close.
        let release = DispatchSemaphore(value: 0)
        let holding = DispatchSemaphore(value: 0)
        ui.async {
            holding.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        _ = holding.wait(timeout: .now() + 5)

        mailbox.post("AirPods", generation: session)
        mailbox.close()
        closed.withLock { $0 = true }

        release.signal()
        Self.drain(ui)

        #expect(
            afterClose.withLock { $0 } == 0,
            "a route name was delivered after the session closed"
        )
    }
}

/// Lifecycle commands that overtake each other.
///
/// Both `start` and `stop` hand their real work to the backend queue, so a stop
/// issued before a queued start has run used to be overtaken: the start block
/// executed afterwards, opened a fresh session, installed listeners and
/// published — after the caller had stopped.
@Suite("Volume watch lifecycle races", .serialized)
struct VolumeWatchLifecycleTests {

    /// Start and stop with nothing in between, as the reviewer's repro has it.
    ///
    /// The assertion about delivery is deliberately "nothing arrives once
    /// `stop` has returned" rather than "nothing is ever delivered". Whether
    /// the queued start runs before or after the stop is genuine scheduling
    /// latitude — if it runs first, a readout published while the watcher was
    /// legitimately running is not a defect. What must never happen is a
    /// readout landing on the consumer after the caller has stopped watching,
    /// and that is ordering-independent, so it is what this checks. An earlier
    /// version asserted the stronger thing and failed about one run in ten on
    /// the benign ordering.
    @Test("Start then immediately stop registers nothing and delivers nothing afterwards")
    func stopImmediatelyAfterStart() async {
        let hardware = FakeAudioHardware()
        let ui = DispatchQueue(label: "test.volume.lifecycle")
        let backend = VolumeWatchBackend(hardware: hardware, deliveryQueue: ui)
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let afterStop = OSAllocatedUnfairLock(initialState: 0)

        // No settling in between: this is the whole point.
        backend.start { _ in
            if stopped.withLock({ $0 }) { afterStop.withLock { $0 += 1 } }
        }
        backend.stop()
        backend.settleForTesting()
        stopped.withLock { $0 = true }

        for _ in 0..<3 {
            ui.sync {}
            try? await Task.sleep(for: .milliseconds(50))
        }
        ui.sync {}

        #expect(
            hardware.liveCount == 0,
            "\(hardware.liveCount) registrations survived a stop that overtook the start"
        )
        #expect(backend.registrationCount() == 0)
        #expect(
            afterStop.withLock { $0 } == 0,
            "\(afterStop.withLock { $0 }) readouts arrived after stop returned"
        )
    }

    @Test("A stop that overtakes a start leaves a later start working")
    func laterStartStillWorks() {
        let hardware = FakeAudioHardware()
        let ui = DispatchQueue(label: "test.volume.lifecycle.after")
        let backend = VolumeWatchBackend(hardware: hardware, deliveryQueue: ui)
        let seen = OSAllocatedUnfairLock(initialState: [Double]())

        backend.start { _ in }
        backend.stop()
        backend.settleForTesting()

        backend.start { readout in seen.withLock { $0.append(readout.level) } }
        backend.settleForTesting()
        for _ in 0..<3 { ui.sync {}; Thread.sleep(forTimeInterval: 0.1) }

        #expect(hardware.systemRegistrations.count == 1, "the later start did not arm")
        #expect(!seen.withLock { $0 }.isEmpty, "the later start delivered nothing")
        backend.stop()
    }
}
