import CoreAudio
import CoreMediaIO
import Foundation
import os

/// Whether anything is currently recording.
public struct RecordingState: Equatable, Sendable {
    public var camera: Bool
    public var microphone: Bool

    /// Whether the microphone is held by the system's own speech input rather
    /// than by an app.
    ///
    /// It is the same microphone and the same indicator underneath, but not
    /// the same event: an app recording you is worth a privacy dot, while
    /// dictation is something *you* just started and want confirmed. Told
    /// apart by who holds the input, because macOS publishes no "dictation is
    /// running" of its own.
    public var isSystemSpeech: Bool

    public init(camera: Bool = false, microphone: Bool = false, isSystemSpeech: Bool = false) {
        self.camera = camera
        self.microphone = microphone
        self.isSystemSpeech = isSystemSpeech
    }

    public var isActive: Bool { camera || microphone }
}

/// Where recording state comes from.
@MainActor
public protocol RecordingSource: AnyObject {
    func current() -> RecordingState
    func startWatching(_ onChange: @escaping () -> Void)
    func stopWatching()
}

/// Reads camera and microphone use from CoreAudio and CoreMediaIO.
///
/// Both are public frameworks, and *querying* a device's running state neither
/// starts a capture session nor triggers a TCC prompt — Ledge can tell that the
/// camera is on without ever being allowed to see through it.
///
/// Event-driven wherever possible: each device gets a property listener, with a
/// slow safety poll behind it because a device that appears while watching would
/// otherwise never be listened to. The CoreAudio idioms here are the same ones
/// `VolumeController` already uses.
@MainActor
public final class SystemRecordingSource: RecordingSource {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "privacy")

    private let queue = DispatchQueue(label: "com.egemert.ledge.privacy")
    private var audioListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var processListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var cmioListeners: [(CMIOObjectID, CMIOObjectPropertyAddress, CMIOObjectPropertyListenerBlock)] = []
    private var poll: DispatchSourceTimer?
    private var onChange: (() -> Void)?

    public init() {}

    // MARK: - Reading

    public func current() -> RecordingState {
        let holders = Self.inputHolders()
        return RecordingState(
            camera: isAnyCameraRunning(),
            microphone: !holders.isEmpty,
            isSystemSpeech: holders.contains(where: Self.isSystemSpeech)
        )
    }

    private func isAnyCameraRunning() -> Bool {
        Self.videoDevices().contains { Self.isVideoDeviceRunning($0) }
    }

    /// A cheap trigger for the expensive answer.
    ///
    /// Sweeping every audio process to see whether any is recording measures at
    /// ~13ms — far too much to poll often, which is why a microphone starting
    /// could go a minute unnoticed. The *device* has a running-somewhere
    /// property that is one read and has a listener, but it cannot be trusted
    /// on its own: a duplex device (AirPods, a USB headset) reports running
    /// during mere playback, which is what lit the dot for music before.
    ///
    /// So it is used as a doorbell rather than an answer. It fires, and the
    /// per-process sweep decides. Cheap when nothing is happening, immediate
    /// when something is.
    private func armInputDeviceListener() {
        guard let device = Self.defaultInputDevice() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
            audioListeners.append((device, address, block))
        }
    }

    nonisolated static func defaultInputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != 0 else { return nil }
        return device
    }

    // MARK: - CoreAudio

    /// Microphone use is read per *process*, not per device.
    ///
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` is device-wide: a duplex
    /// device (AirPods, USB headset) reports "running" during mere playback,
    /// which lit the mic dot whenever music played to a headset. The process
    /// object's `IsRunningInput` is scoped to actual capture, and skipping our
    /// own pid keeps any future in-process audio work from lighting our own
    /// dot.
    nonisolated static func isAnyProcessRecordingInput() -> Bool {
        !inputHolders().isEmpty
    }

    /// The bundle identifiers of everything currently holding the input.
    ///
    /// Logged when the set changes, which is how the identifier for a feature
    /// Apple documents nowhere gets discovered: use it once, read it back.
    public nonisolated static func inputHolders() -> [String] {
        processObjects()
            .filter { isProcessRecordingInput($0) && processPID($0) != getpid() }
            .map { bundleID($0) ?? "(unnamed)" }
    }

    /// Whether an identifier belongs to macOS's own speech input.
    ///
    /// A prefix-and-keyword test rather than an exact name: dictation is
    /// served by a handful of Apple daemons whose names have changed across
    /// releases and are documented nowhere, so matching the family is more
    /// durable than matching whichever one answers today. Anything not
    /// Apple's is an app recording you, which is the privacy dot's business.
    nonisolated static func isSystemSpeech(_ bundleID: String) -> Bool {
        guard bundleID.hasPrefix("com.apple.") else { return false }
        let lowered = bundleID.lowercased()
        return lowered.contains("speech")
            || lowered.contains("dictation")
            || lowered.contains("siri")
            || lowered.contains("assistant")
    }

    nonisolated static func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    nonisolated static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private nonisolated static func isProcessRecordingInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    private nonisolated static func processPID(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr else { return -1 }
        return pid
    }

    // MARK: - CoreMediaIO

    nonisolated static func videoDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &ids
        ) == noErr else { return [] }
        return ids
    }

    private nonisolated static func isVideoDeviceRunning(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(device, &address) else { return false }
        var running: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running
        )
        return status == noErr && running != 0
    }

    // MARK: - Watching

    public func startWatching(_ onChange: @escaping () -> Void) {
        stopWatching()
        self.onChange = onChange

        // The process-object list changes as apps appear and leave the audio
        // system; each change re-arms the per-process listeners below so a
        // recorder launched later is still watched.
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listBlock: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor [weak self] in
                self?.rearmProcessListeners()
                self?.onChange?()
            }
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        if AudioObjectAddPropertyListenerBlock(system, &listAddress, queue, listBlock) == noErr {
            audioListeners.append((system, listAddress, listBlock))
        }
        armProcessListeners()
        armInputDeviceListener()

        for device in Self.videoDevices() {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            guard CMIOObjectHasProperty(device, &address) else { continue }
            let block: CMIOObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            }
            if CMIOObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                cmioListeners.append((device, address, block))
            }
        }

        // A camera or microphone plugged in after this point has no listener, so
        // a slow poll backstops the event path. Deliberately slow: this is a
        // safety net, not the mechanism. Each tick re-enumerates both device
        // trees — measured at ~13ms of main-thread work per tick, which at a
        // 15s period was still a sixth of the whole app's idle cost, spent to
        // notice a webcam being plugged in.
        //
        // A minute, with half a minute of leeway so it almost always rides
        // along with another wake-up. The property listeners are what actually
        // report a camera or microphone starting; this only has to catch a
        // device tree that changed shape without telling anyone, and being a
        // minute late to notice a newly plugged-in webcam costs nothing.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        timer.resume()
        poll = timer

        Self.log.debug("""
            privacy: watching \(self.audioListeners.count, privacy: .public) mic + \
            \(self.cmioListeners.count, privacy: .public) camera properties
            """)
    }

    /// One `IsRunningInput` listener per current audio process, so a capture
    /// starting while the device is already running (music to the same
    /// headset) still fires an event instead of waiting for the safety poll.
    private func armProcessListeners() {
        for object in Self.processObjects() {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(object, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                processListeners.append((object, address, block))
            }
        }
    }

    private func rearmProcessListeners() {
        // A list-change Task queued before stopWatching() must not re-register
        // a fleet of listeners on a stopped watcher.
        guard onChange != nil else { return }
        for (object, address, block) in processListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        processListeners.removeAll()
        armProcessListeners()
    }

    public func stopWatching() {
        for (device, address, block) in audioListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        audioListeners.removeAll()

        for (object, address, block) in processListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        processListeners.removeAll()

        for (device, address, block) in cmioListeners {
            var address = address
            CMIOObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        cmioListeners.removeAll()

        poll?.cancel()
        poll = nil
        onChange = nil
    }

    deinit {
        poll?.cancel()
    }
}

/// Fixed state, for tests.
@MainActor
public final class StubRecordingSource: RecordingSource {
    private var value: RecordingState
    private var onChange: (() -> Void)?

    public init(value: RecordingState = RecordingState()) {
        self.value = value
    }

    public func current() -> RecordingState { value }

    public func set(_ value: RecordingState) {
        self.value = value
        onChange?()
    }

    public func startWatching(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    public func stopWatching() { onChange = nil }
}
