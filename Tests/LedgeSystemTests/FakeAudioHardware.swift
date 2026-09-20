import CoreAudio
import Foundation
import LedgeCore
import os

@testable import LedgeSystem

/// A stand-in for the audio hardware that counts what actually reached it.
///
/// The bug this exists for could not be seen from Swift: registrations piled up
/// inside CoreAudio while every Swift-side collection looked balanced and every
/// status said noErr. So the thing worth counting is the calls that cross the
/// boundary — adds, removes, and which registrations are still live by identity
/// — not how many objects an array happens to hold.
///
/// Handlers are delivered on the queue they were registered with, as CoreAudio
/// does, because the watcher's callbacks assume they are already on it.
final class FakeAudioHardware: AudioHardware, @unchecked Sendable {

    struct Live: Sendable {
        let id: Int
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let element: UInt32
    }

    private struct State {
        /// Device IDs start well clear of `kAudioObjectSystemObject`, which is
        /// 1 — a device numbered 1 is indistinguishable from the system object
        /// and made every device listener look like a system one.
        var defaultDevice: AudioObjectID? = 100
        /// Devices that answer `hasProperty` for the volume properties.
        var devicesWithProperties: Set<AudioObjectID> = [100, 200]
        var levels: [AudioObjectID: Double] = [100: 0.5, 200: 0.7]

        var addCount = 0
        var addsRefused = 0
        var removeCount = 0
        var nextID = 1
        var live: [Int: Live] = [:]
        var handlers: [Int: @Sendable () -> Void] = [:]
        var queues: [Int: DispatchQueue] = [:]

        /// Refuse the next N registrations, to exercise an incomplete bind.
        var refuseNext = 0
        /// Refuse every registration, for the "nothing registers" case.
        var refuseAll = false
        /// Refuse the next N removals. The registration stays live, which is
        /// what CoreAudio does when it cannot match the block it was given —
        /// the failure this whole boundary exists for.
        var failRemovals = 0
        var removalsFailed = 0
        /// Refuse which listeners by selector, for a partial bind.
        var refuseSelectors: Set<AudioObjectPropertySelector> = []

        var sawMainThread = false
        var callsOffMain = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - What the test drives

    func setDefaultDevice(_ device: AudioObjectID?) {
        state.withLock { $0.defaultDevice = device }
    }

    func setDeviceHasProperties(_ device: AudioObjectID, _ has: Bool) {
        state.withLock {
            if has { $0.devicesWithProperties.insert(device) }
            else { $0.devicesWithProperties.remove(device) }
        }
    }

    func refuseNextRegistrations(_ count: Int) {
        state.withLock { $0.refuseNext = count }
    }

    func setRefusesAll(_ refuse: Bool) {
        state.withLock { $0.refuseAll = refuse }
    }

    /// The next `count` removals report failure and leave the registration in
    /// place, as CoreAudio does when it cannot match the block.
    func failNextRemovals(_ count: Int) {
        state.withLock { $0.failRemovals = count }
    }

    func refuseSelector(_ selector: AudioObjectPropertySelector) {
        state.withLock { _ = $0.refuseSelectors.insert(selector) }
    }

    func stopRefusingSelectors() {
        state.withLock { $0.refuseSelectors.removeAll() }
    }

    var removalsFailed: Int { state.withLock { $0.removalsFailed } }

    func setLevel(_ level: Double, on device: AudioObjectID) {
        state.withLock { $0.levels[device] = level }
    }

    // MARK: - What the test reads

    var addCount: Int { state.withLock { $0.addCount } }
    var removeCount: Int { state.withLock { $0.removeCount } }
    var addsRefused: Int { state.withLock { $0.addsRefused } }
    var liveRegistrations: [Live] { state.withLock { Array($0.live.values) } }
    var liveCount: Int { state.withLock { $0.live.count } }
    /// True if any call from the watcher arrived on the main thread. The whole
    /// point of the backend queue is that this stays false.
    var everRanOnMainThread: Bool { state.withLock { $0.sawMainThread } }
    var callsOffMain: Int { state.withLock { $0.callsOffMain } }

    var systemRegistrations: [Live] {
        liveRegistrations.filter { $0.object == AudioObjectID(kAudioObjectSystemObject) }
    }

    var deviceRegistrations: [Live] {
        liveRegistrations.filter { $0.object != AudioObjectID(kAudioObjectSystemObject) }
    }

    /// Invokes every live listener for a selector, on its own queue.
    func fire(selector: AudioObjectPropertySelector) {
        let targets = state.withLock { s -> [(DispatchQueue, @Sendable () -> Void)] in
            s.live.values
                .filter { $0.selector == selector }
                .compactMap { live in
                    guard let q = s.queues[live.id], let h = s.handlers[live.id] else { return nil }
                    return (q, h)
                }
        }
        for (queue, handler) in targets { queue.async { handler() } }
    }

    func fireDefaultDeviceChanged() {
        fire(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    // MARK: - AudioHardware

    private func noteThread() {
        let onMain = Thread.isMainThread
        state.withLock {
            if onMain { $0.sawMainThread = true } else { $0.callsOffMain += 1 }
        }
    }

    func defaultOutputDevice() -> AudioObjectID? {
        noteThread()
        return state.withLock { $0.defaultDevice }
    }

    func hasProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        noteThread()
        return state.withLock { $0.devicesWithProperties.contains(object) }
    }

    func readout(for device: AudioObjectID) -> HUDReadout? {
        noteThread()
        guard let level = state.withLock({ $0.levels[device] }) else { return nil }
        return HUDReadout(kind: .volume, level: level, isMuted: false, deviceName: "Fake \(device)")
    }

    func listen(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioRegistration? {
        noteThread()
        let id: Int? = state.withLock { s in
            s.addCount += 1
            if s.refuseSelectors.contains(address.mSelector) {
                s.addsRefused += 1
                return nil
            }
            if s.refuseAll || s.refuseNext > 0 {
                if s.refuseNext > 0 { s.refuseNext -= 1 }
                s.addsRefused += 1
                return nil
            }
            let id = s.nextID
            s.nextID += 1
            s.live[id] = Live(
                id: id, object: object, selector: address.mSelector, element: address.mElement
            )
            s.handlers[id] = handler
            s.queues[id] = queue
            return id
        }
        guard let id else { return nil }
        return FakeRegistration(id: id, hardware: self)
    }

    /// - Returns: false when the removal "failed" — the registration is still
    ///   live, exactly as it would be inside CoreAudio.
    @discardableResult
    fileprivate func remove(_ id: Int) -> Bool {
        state.withLock { s in
            guard s.live[id] != nil else { return true }
            if s.failRemovals > 0 {
                s.failRemovals -= 1
                s.removalsFailed += 1
                return false
            }
            s.live[id] = nil
            s.handlers[id] = nil
            s.queues[id] = nil
            s.removeCount += 1
            return true
        }
    }
}

private final class FakeRegistration: AudioRegistration, @unchecked Sendable {
    private let id: Int
    private let hardware: FakeAudioHardware
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(id: Int, hardware: FakeAudioHardware) {
        self.id = id
        self.hardware = hardware
    }

    func cancel() {
        let first = cancelled.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        // Retry the way the real cleanup does, so a fixture that fails a
        // removal once still ends with nothing live.
        for _ in 0..<4 where !hardware.remove(id) { continue }
    }

    deinit { cancel() }
}
