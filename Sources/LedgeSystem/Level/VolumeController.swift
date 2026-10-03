import CoreAudio
import Foundation
import LedgeCore
import os

/// Reads, sets, and watches the system output volume.
///
/// Uses public CoreAudio, so none of this needs a permission — which is the
/// whole reason the HUD can work out of the box. Watching a property is a real
/// notification, not a poll, so a volume change from any source (keys, Control
/// Centre, another app) shows up immediately.
@MainActor
public final class VolumeController {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "volume")

    /// Fires with the new level whenever volume or mute changes.
    public var onChange: (HUDReadout) -> Void = { _ in }

    /// Everything about watching lives here, on its own serial queue.
    ///
    /// Registration, removal and the hardware reads behind a readout are
    /// synchronous calls into coreaudiod. The queue handed to CoreAudio governs
    /// where callbacks are *delivered*, not where an Add or Remove runs, so
    /// doing this from the main actor is what turned a listener problem into a
    /// frozen interface.
    private let backend: VolumeWatchBackend

    /// Diagnostics only, behind LEDGE_TRACE_LEVELS.
    @MainActor static var notified = 0
    @MainActor static var delivered = 0

    /// Two frames. Long enough to gather the several notifications a single
    /// volume step produces, short enough that nobody can perceive it — and it
    /// delays nothing the user did themselves: a key press paints its own
    /// readout synchronously on the way through, so this window only ever
    /// governs the echo behind it and changes made by other apps.
    private static let coalesceWindow = Duration.milliseconds(33)

    /// How long after writing the volume ourselves to ignore the echo.
    ///
    /// macOS ramps a volume change rather than stepping it, so one write comes
    /// back as a stream of intermediate values. We already know where it is
    /// going — we sent it there, and drew it — so the ramp is redraw with
    /// nothing to say. One readout is taken at the end of the ramp, which is
    /// also what catches a device clamping the value we asked for.
    private nonisolated static let selfWriteQuiet: TimeInterval = 0.15

    /// When each output's last write of our own settles.
    ///
    /// Per device. One window for the whole Mac meant a write to an AirPlay
    /// speaker suppressed a simultaneous change on the built-in output — the
    /// echo of one device's ramp silenced the news from another's.
    ///
    /// Written from the main actor and read from the watch's own queue, so it
    /// is behind a lock rather than an isolation domain.
    private nonisolated static let selfWrites =
        OSAllocatedUnfairLock<[AudioObjectID: TimeInterval]>(initialState: [:])

    /// Called by the paths that set the level themselves, *after* the write,
    /// so an operation the hardware refused opens no window at all: there is
    /// no ramp to ignore, and ignoring the echo would hide the fact that
    /// nothing happened.
    public nonisolated static func noteSelfWrite(
        on device: AudioObjectID,
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) {
        selfWrites.withLock { writes in
            writes[device] = now + selfWriteQuiet
            // Bounded: windows are 150ms, so anything in the past is finished
            // and the map has no reason to remember it.
            writes = writes.filter { $0.value > now }
        }
    }

    /// How long this output's current self-write still has to settle, or zero.
    nonisolated static func selfWriteRemaining(
        on device: AudioObjectID,
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) -> TimeInterval {
        max(0, (selfWrites.withLock { $0[device] } ?? 0) - now)
    }

    public init(hardware: (any AudioHardware)? = nil) {
        backend = VolumeWatchBackend(hardware: hardware ?? SystemAudioHardware())
    }

    // MARK: - Device

    /// The current default output device, or nil if there is none (no audio
    /// hardware, or the device disappeared mid-call).
    public nonisolated static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    // MARK: - Reading

    /// Current output level, 0...1.
    ///
    /// Tries the main element first. Plenty of devices — most USB interfaces,
    /// and some Bluetooth headsets — expose no master control at all and only
    /// answer per channel, so the per-channel average is a real fallback rather
    /// than defensive padding.
    public nonisolated static func level(of device: AudioObjectID) -> Double? {
        if let main = scalar(device, element: kAudioObjectPropertyElementMain) {
            return main
        }

        let channels = [UInt32(1), UInt32(2)].compactMap { scalar(device, element: $0) }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Double(channels.count)
    }

    private nonisolated static func scalar(_ device: AudioObjectID, element: UInt32) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }

        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        // A device can report garbage. Anything non-finite must be rejected
        // here rather than propagated into a level readout.
        guard status == noErr, value.isFinite else { return nil }
        return Double(value)
    }

    /// Whether the output is muted, by the same element ladder a write uses.
    ///
    /// The master answers for the whole device when it has one; otherwise
    /// every readable channel must say so. A channel-only device used to read
    /// as unmuted however thoroughly it had been muted, which made the mute
    /// key one-way.
    public nonisolated static func isMuted(_ device: AudioObjectID) -> Bool {
        SystemVolumeHardware().isOutputMuted(device)
    }

    public func readout() -> HUDReadout? {
        guard let device = Self.defaultOutputDevice(),
              let level = Self.level(of: device)
        else { return nil }
        return HUDReadout(
            kind: .volume,
            level: Self.shownLevel(device, raw: level),
            isMuted: Self.showsMuted(device, level: level),
            deviceName: Self.deviceName(device)
        )
    }

    // MARK: - Writing

    /// The one write path, for every caller. See `VolumeWriter`: volume and
    /// mute are separate controls in CoreAudio, a scalar of zero is not
    /// silence, and the order the two go out in is audible.
    public nonisolated static let writer = VolumeWriter(hardware: SystemVolumeHardware())

    /// Why each output is muted — the user, silence at zero, or both.
    ///
    /// Held here because CoreAudio cannot answer it: the device has one mute
    /// property and Ledge sets it for two reasons, which compose. Per output,
    /// because one latch for the whole Mac meant turning an AirPlay speaker
    /// down to nothing changed what the built-in speakers claimed about
    /// themselves. See `MuteReasons`, which holds every rule.
    private nonisolated static let intents = OSAllocatedUnfairLock(initialState: MuteIntentLedger())

    /// Why this output is silent, as far as Ledge is concerned.
    public nonisolated static func muteReasons(_ device: AudioObjectID) -> MuteReasons {
        intents.withLock { $0.reasons(for: device) }
    }

    /// Whether the user's own mute is in force for this output.
    public nonisolated static func userMuted(_ device: AudioObjectID) -> Bool {
        muteReasons(device).userMuted
    }

    /// Adopts a mute that arrived from outside Ledge — Control Centre, a
    /// headset button, another app. Ignored while one of *this output's* own
    /// writes is still settling, since the echo of that says nothing about
    /// intent.
    public nonisolated static func noteObservedMute(
        _ muted: Bool,
        level: Double,
        device: AudioObjectID
    ) {
        let settling = selfWriteRemaining(on: device) > 0
        intents.withLock {
            $0.observed(muted: muted, level: level, for: device, isSelfWrite: settling)
        }
    }

    /// Forgets outputs that have gone away — and keeps everything when the
    /// system could not say what exists.
    ///
    /// Reconciled against every output CoreAudio knows about, not the picker's
    /// list: that one hides virtual and aggregate devices, and a conference
    /// app's output being current would have had its reasons forgotten by a
    /// refresh of the route list. A *failed* enumeration prunes nothing — see
    /// `DeviceInventory`.
    nonisolated static func reconcileIntents(with inventory: DeviceInventory) {
        intents.withLock { $0.reconcile(with: inventory) }
    }

    /// Applies a level, keeping the device's mute consistent with it, and
    /// reports what the hardware says afterwards — which is what the interface
    /// should draw.
    public nonisolated static func apply(
        level: Double,
        on device: AudioObjectID
    ) -> VolumeWriteResult? {
        let before = muteReasons(device)
        guard let result = writer.apply(level: level, to: device, reasons: before)
        else { return nil }
        intents.withLock { $0.set(result.reasons, for: device) }
        // Only a write that was actually taken has an echo worth ignoring.
        if result.scalarAccepted || result.muteAccepted { noteSelfWrite(on: device) }
        return result
    }

    /// Sets the user's own mute, leaving the level where it is.
    public nonisolated static func apply(
        muted: Bool,
        on device: AudioObjectID
    ) -> VolumeWriteResult {
        let result = writer.apply(
            userMuted: muted, to: device, reasons: muteReasons(device)
        )
        intents.withLock { $0.set(result.reasons, for: device) }
        if result.muteAccepted { noteSelfWrite(on: device) }
        return result
    }

    /// The level to show for this output, and to step from.
    ///
    /// Zero whenever the output is silent because zero was asked for: a device
    /// that clamps a zero scalar to its lowest step reads back an audible
    /// number, and showing that number meant a bar at 6% on an output that had
    /// been turned all the way down — and a first volume-up that stepped from
    /// 0.062 instead of from zero.
    public nonisolated static func shownLevel(_ device: AudioObjectID, raw: Double) -> Double {
        muteReasons(device).zeroSilence ? 0 : raw
    }

    /// The level to show for this output, read fresh.
    public nonisolated static func shownLevel(of device: AudioObjectID) -> Double? {
        guard let raw = level(of: device) else { return nil }
        return shownLevel(device, raw: raw)
    }

    /// Whether a readout for this device should show the muted state.
    public nonisolated static func showsMuted(_ device: AudioObjectID, level: Double) -> Bool {
        intents.withLock { $0.showsMuted(for: device) } && isMuted(device)
    }

    /// Every audio object the system reports, or nil when the enumeration
    /// failed.
    ///
    /// Nil and empty are different answers. A Mac with no audio devices is a
    /// fact; a HAL that would not answer is not, and treating the two alike
    /// threw away the mute reasons of every live output on a transient
    /// failure — so an output turned all the way down came back showing its
    /// clamped minimum, with the next step starting from there.
    nonisolated static func allDeviceIDs() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return nil }
        return ids
    }

    /// One selectable audio output.
    public struct OutputDevice: Equatable, Sendable {
        public let id: AudioObjectID
        public let name: String
    }

    /// Every device capable of output, for the routing picker.
    public nonisolated static func outputDevices() -> [OutputDevice] {
        // One enumeration, two answers: the picker's filtered list, and the
        // complete set of output-capable ids the mute ledger is kept against.
        // Asking twice was waste and a second chance to fail.
        guard let ids = allDeviceIDs() else {
            // The system would not say what exists. The picker shows nothing
            // — and, the point, nothing established is forgotten: a transient
            // failure used to drop every mute reason, so an output turned all
            // the way down came back at its clamped minimum.
            reconcileIntents(with: .unavailable)
            return []
        }

        // Classified exactly once per device, and both decisions read that one
        // classification. Querying twice let the picker and the retention set
        // disagree about the same device on two different reads.
        var capabilities: [AudioObjectID: OutputCapability] = [:]
        for id in ids { capabilities[id] = outputCapability(id) }

        let outputs = ids.compactMap { id -> OutputDevice? in
            guard capabilities[id] == .output,
                  isRealHardware(id),
                  let name = deviceName(id)
            else { return nil }
            return OutputDevice(id: id, name: name)
        }
        // Everything except a confirmed non-output: the picker hides virtual
        // and aggregate devices, and a conference app's output being the
        // current route would have had its reasons forgotten by a refresh of
        // the route list — and a device whose query failed proves nothing.
        reconcileIntents(with: .retaining(capabilities))
        return outputs
    }

    /// Whether the device is an actual audio route rather than a software one.
    ///
    /// Conference and loopback drivers (Teams, BlackHole, Loopback…) register
    /// virtual output devices; CoreAudio marks those with a `Virtual` transport,
    /// and aggregates are stitched-together composites. Filtering on the
    /// transport type keeps the list to hardware automatically — no name lists
    /// to maintain.
    private nonisolated static func isRealHardware(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
        else { return true }  // unreadable: assume hardware rather than hide it

        switch transport {
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate:
            return false
        default:
            return true
        }
    }

    /// The device's own output level, for the faded bars of non-current routes.
    public nonisolated static func outputLevel(of device: AudioObjectID) -> Double? {
        level(of: device)
    }

    /// The name of the device sound currently goes to, for the panel's title.
    public nonisolated static func defaultOutputName() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        return deviceName(device)
    }

    /// Routes system output to the given device.
    @discardableResult
    public nonisolated static func setDefaultOutputDevice(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &id
        ) == noErr
    }

    /// Whether this device can play sound — or whether the question could not
    /// be answered, which is a third answer and not a "no".
    ///
    /// A failed property query used to read as "no outputs", so one transient
    /// failure during a route-list refresh erased that device's mute reasons.
    nonisolated static func outputCapability(_ device: AudioObjectID) -> OutputCapability {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr
        else { return .unknown }
        return size > 0 ? .output : .notOutput
    }

    nonisolated static func deviceName(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        let text = name as String
        return text.isEmpty ? nil : text
    }

    // MARK: - Watching

    public func startWatching() {
        // The backend delivers on the main queue here, so assuming that
        // isolation is sound — and it is asserted at exactly one place rather
        // than inside the backend, which does not know where it was pointed.
        backend.start { [weak self] readout in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.delivered += 1
                self.onChange(readout)
            }
        }
    }

    public func stopWatching() {
        backend.stop()
    }

    /// Re-reads and offers the current level without touching a registration.
    /// For the caller that has just written one itself.
    public func refreshReadout() {
        backend.refresh()
    }

    /// How many registrations the watch holds. A test and diagnostic seam; it
    /// waits on the backend's queue, so it does not belong on a path the
    /// interface is waiting for.
    var installedListenerCount: Int { backend.registrationCount() }

    func settleForTesting() { backend.settleForTesting() }

    deinit {
        // Nothing to do: each registration is owned by an `AudioListener`, and
        // releasing this object releases those, which takes them off. That is
        // the point of holding them as objects rather than as entries in a list
        // some other method has to remember to walk.
    }
}
