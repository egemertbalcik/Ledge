import CoreAudio
import CoreMediaIO
import Foundation
import os

/// Whether anything is currently recording.
public struct RecordingState: Equatable, Sendable {
    public var camera: Bool
    public var microphone: Bool

    public init(camera: Bool = false, microphone: Bool = false) {
        self.camera = camera
        self.microphone = microphone
    }

    public var isActive: Bool { camera || microphone }
}

/// Where recording state comes from.
@MainActor
public protocol RecordingSource: AnyObject {
    func current() -> RecordingState
    /// `@Sendable` because the watcher notices changes on its own queue.
    /// It is nonetheless **always called on the main actor** — the watcher
    /// hands it across through a mailbox that delivers there — so a caller may
    /// assume that isolation.
    func startWatching(_ onChange: @escaping @Sendable () -> Void)
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

    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "privacy")

    /// Registration, device enumeration and reconciliation all happen here.
    /// The queue handed to CoreAudio governs where callbacks arrive, not where
    /// an Add or Remove runs, so this work would otherwise sit on the main
    /// actor in front of the interface.
    private let queue = DispatchQueue(label: "com.egemert.ledge.privacy")

    private nonisolated(unsafe) var audioListeners: [AudioListener] = []
    /// Keyed by process object, so a change in the process list can keep the
    /// listeners it already has instead of replacing all of them. The audio
    /// process list changes whenever any app starts or stops playing anything,
    /// which is often; rebuilding the whole fleet each time was a registration
    /// storm in its own right.
    private nonisolated(unsafe) var processListeners: [AudioObjectID: AudioListener] = [:]
    private nonisolated(unsafe) var cmioListeners: [AudioListener] = []
    private var poll: DispatchSourceTimer?

    /// How often the safety poll re-checks the device trees. A minute in the
    /// app; tests shorten it so the timer path can actually be exercised —
    /// waiting a real minute is why the isolation trap above went unnoticed.
    private let pollInterval: TimeInterval
    /// Only ever touched on `queue`. The safety poll used to read it from a
    /// main-queue timer while a start or stop wrote it here, which
    /// `nonisolated(unsafe)` and `MainActor.assumeIsolated` do nothing to
    /// synchronise — the timer now runs on `queue` like everything else.
    private nonisolated(unsafe) var onChange: (() -> Void)?

    /// Bumped on every start and stop. The HAL can deliver a callback it had
    /// already queued after a stop, so the session a callback was registered
    /// with is what disqualifies it — cancellation cannot reach CoreAudio's
    /// own queue.
    private nonisolated(unsafe) var generation = 0
    /// One pending reconcile of the process list, and one pending notification,
    /// rather than a task per callback. The audio process list changes whenever
    /// any app starts or stops a sound.
    private nonisolated(unsafe) var reconcilePending = false
    private nonisolated(unsafe) var notifyPending = false

    /// One outstanding main-actor delivery, with the session re-checked there.
    private struct Tick: Sendable, Equatable {}
    private let mailbox = MainMailbox<Tick>(isEqual: { _, _ in false })

    /// Which lifecycle command is the latest, so a stop cannot be overtaken by
    /// a start already queued behind it.
    private let lifecycle = OSAllocatedUnfairLock(initialState: 0)

    public convenience init() {
        self.init(pollInterval: 60)
    }

    init(pollInterval: TimeInterval) {
        self.pollInterval = pollInterval
    }

    // MARK: - Reading

    public func current() -> RecordingState {
        return RecordingState(
            camera: isAnyCameraRunning(),
            microphone: Self.microphoneHeld(by: Self.inputHolders())
        )
    }

    /// Whether any of these holders is worth an indicator.
    ///
    /// Everything except the system's own speech input counts. Dictation is
    /// the system transcribing for the user, at the user's own keystroke, and
    /// the menu bar already says so while it runs; a second indicator in the
    /// notch reports the user to themselves. Ledge shows nothing for
    /// dictation — not a dictation state, and not a microphone state *because*
    /// of dictation.
    ///
    /// A filter rather than a short circuit: dictation running does not excuse
    /// an app recording at the same time, and that app still lights the dot.
    nonisolated static func microphoneHeld(by holders: [String]) -> Bool {
        holders.contains { !isSystemSpeech($0) }
    }

    /// Whether this bundle identifier is the system's own speech input.
    ///
    /// Apple's own identifiers only. A third-party app with "speech" in its
    /// name is an app recording you, and is reported as one. The processes
    /// that actually hold the input for dictation are not documented anywhere,
    /// so the match is by family rather than by a list of exact ids — which
    /// `inputHolders()` logging is for: use it once, read the name back.
    nonisolated static func isSystemSpeech(_ bundleID: String) -> Bool {
        guard bundleID.hasPrefix("com.apple.") else { return false }
        let name = bundleID.lowercased()
        return name.contains("speech")
            || name.contains("dictation")
            || name.contains("siri")
            || name.contains("assistant")
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
    private nonisolated func armInputDeviceListener(session: Int) {
        guard let device = Self.defaultInputDevice() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return }
        let listener = AudioListener(object: device, address: address, queue: queue) { [weak self] in
            self?.notifyChanged(session: session)
        }
        if let listener { audioListeners.append(listener) }
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

    /// The bundle identifiers of everything currently holding the input.
    ///
    /// Logged when the set changes, which is how the identifier for a feature
    /// Apple documents nowhere gets discovered: use it once, read it back.
    ///
    /// Read per *process*, not per device.
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` is device-wide: a duplex
    /// device (AirPods, USB headset) reports "running" during mere playback,
    /// which lit the mic dot whenever music played to a headset. The process
    /// object's `IsRunningInput` is scoped to actual capture, and skipping our
    /// own pid keeps any future in-process audio work from lighting our own
    /// dot.
    ///
    /// The raw list, unfiltered: `microphoneHeld(by:)` is the one place that
    /// decides which of these is worth an indicator, so the two readings
    /// cannot drift apart.
    public nonisolated static func inputHolders() -> [String] {
        processObjects()
            .filter { isProcessRecordingInput($0) && processPID($0) != getpid() }
            .map { bundleID($0) ?? "(unnamed)" }
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

    public func startWatching(_ onChange: @escaping @Sendable () -> Void) {
        stopWatching()
        let command = lifecycle.withLock { c -> Int in c &+= 1; return c }
        let session = mailbox.open { _ in MainActor.assumeIsolated { onChange() } }
        queue.async { [self] in
            guard lifecycle.withLock({ $0 }) == command else { return }
            self.onChange = onChange
            generation = session

            // The process-object list changes as apps appear and leave the
            // audio system; each change reconciles the per-process listeners
            // below so a recorder launched later is still watched.
            let listAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let system = AudioObjectID(kAudioObjectSystemObject)
            let listListener = AudioListener(
                object: system, address: listAddress, queue: queue
            ) { [weak self] in
                self?.noteProcessListChanged(session: session)
            }
            if let listListener { audioListeners.append(listListener) }

            armProcessListeners(Self.processObjects())
            armInputDeviceListener(session: session)

            for device in Self.videoDevices() {
                var address = CMIOObjectPropertyAddress(
                    mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                    mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
                )
                guard CMIOObjectHasProperty(device, &address) else { continue }
                let listener = AudioListener(
                    cmioObject: device, address: address, queue: queue
                ) { [weak self] in
                    self?.notifyChanged(session: session)
                }
                if let listener { cmioListeners.append(listener) }
            }

            Self.log.debug("""
                privacy: watching \(self.audioListeners.count, privacy: .public) mic + \
                \(self.cmioListeners.count, privacy: .public) camera properties
                """)
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
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + pollInterval,
            repeating: pollInterval,
            leeway: .milliseconds(Int(max(0.05, pollInterval / 2) * 1000))
        )
        // `@Sendable` is load-bearing, not decoration.
        //
        // `setEventHandler` takes a closure that is *not* Sendable, so one
        // written inline here inherits this method's MainActor isolation. That
        // was true and harmless while this timer ran on the main queue. Moving
        // it to `queue` made the inherited isolation a lie, and Swift checks:
        // the first tick tripped a runtime isolation assertion and took the
        // whole app down with SIGTRAP. Sixty seconds after watching started,
        // so it looked like a crash out of nowhere.
        //
        // Declaring the closure `@Sendable` is what stops it inheriting the
        // isolation it cannot honour.
        let tick: @Sendable () -> Void = { [weak self] in
            // On `queue`, so the callback state it reads is the state this
            // object owns rather than a copy raced from another thread.
            self?.notifyChanged(session: session)
        }
        timer.setEventHandler(handler: tick)
        timer.resume()
        poll = timer
    }

    /// The process list changed. Sets a flag and asks for one pass; it does not
    /// create work per callback.
    private nonisolated func noteProcessListChanged(session: Int) {
        // Already on `queue`: this is the queue the listener was registered with.
        guard session == generation, onChange != nil else { return }
        guard !reconcilePending else { return }
        reconcilePending = true
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            reconcilePending = false
            guard session == generation, onChange != nil else { return }
            reconcileProcessListeners()
            notifyChanged(session: session)
        }
    }

    /// Tells the caller something happened, at most once per coalescing window
    /// and at most one delivery outstanding on the main actor.
    private nonisolated func notifyChanged(session: Int) {
        guard session == generation, onChange != nil else { return }
        guard !notifyPending else { return }
        notifyPending = true
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            notifyPending = false
            guard session == generation, onChange != nil else { return }
            // The session is checked again at the far end: a stop cannot reach
            // a hop already enqueued on the main queue.
            mailbox.post(Tick(), generation: session)
        }
    }

    /// One `IsRunningInput` listener per current audio process, so a capture
    /// starting while the device is already running (music to the same
    /// headset) still fires an event instead of waiting for the safety poll.
    /// Adds a listener for any audio process in `objects` that has none yet.
    ///
    /// Takes the snapshot as an argument rather than enumerating: a reconcile
    /// needs exactly one enumeration, and asking twice could see two different
    /// lists and act on the wrong one.
    private nonisolated func armProcessListeners(_ objects: [AudioObjectID]) {
        let session = generation
        for object in objects where processListeners[object] == nil {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(object, &address) else { continue }
            let listener = AudioListener(
                object: object, address: address, queue: queue
            ) { [weak self] in
                self?.notifyChanged(session: session)
            }
            if let listener { processListeners[object] = listener }
        }
    }

    /// Follows the process list: drops what has gone, adds what is new, and
    /// leaves the rest alone.
    ///
    /// The list changes whenever any app touches audio, so this runs often. It
    /// used to unregister every process listener and register them all again
    /// each time — which, with removal silently failing, is precisely how a
    /// listener list grows into the hundreds of thousands. Even with removal
    /// working, replacing a fleet to learn that one member joined is work
    /// nobody asked for.
    private nonisolated func reconcileProcessListeners() {
        guard onChange != nil else { return }
        // One enumeration for the whole pass.
        let snapshot = Self.processObjects()
        let live = Set(snapshot)
        for object in processListeners.keys where !live.contains(object) {
            processListeners.removeValue(forKey: object)
        }
        armProcessListeners(snapshot)
    }

    public func stopWatching() {
        _ = lifecycle.withLock { c -> Int in c &+= 1; return c }
        poll?.cancel()
        poll = nil
        // Disqualifies anything already on its way to main.
        mailbox.close()
        queue.async { [self] in
            // Anything the HAL had already queued is now from a dead session.
            generation &+= 1
            // Each registration is owned by its listener object, so dropping
            // the collections is what takes them all off.
            audioListeners.removeAll()
            processListeners.removeAll()
            cmioListeners.removeAll()
            reconcilePending = false
            notifyPending = false
            onChange = nil
        }
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
