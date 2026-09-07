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

    private var listeningDevice: AudioObjectID?
    private var listenerBlocks: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// Diagnostics only, behind LEDGE_TRACE_LEVELS.
    @MainActor static var notified = 0
    @MainActor static var delivered = 0

    /// Collapses a burst of notifications into one readout.
    private var coalesce: Task<Void, Never>?

    /// The last readout handed on, so a notification that changes nothing the
    /// user can see costs nothing.
    private var lastDelivered: HUDReadout?

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
    private static let selfWriteQuiet: TimeInterval = 0.15

    /// When the last write of our own settles.
    @MainActor private static var selfWriteUntil: TimeInterval = 0

    /// Called by the paths that set the level themselves.
    @MainActor
    public static func noteSelfWrite(now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        selfWriteUntil = now + selfWriteQuiet
    }
    private let queue = DispatchQueue(label: "com.egemert.ledge.volume")

    public init() {}

    // MARK: - Device

    /// The current default output device, or nil if there is none (no audio
    /// hardware, or the device disappeared mid-call).
    public static func defaultOutputDevice() -> AudioObjectID? {
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
    public static func level(of device: AudioObjectID) -> Double? {
        if let main = scalar(device, element: kAudioObjectPropertyElementMain) {
            return main
        }

        let channels = [UInt32(1), UInt32(2)].compactMap { scalar(device, element: $0) }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Double(channels.count)
    }

    private static func scalar(_ device: AudioObjectID, element: UInt32) -> Double? {
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

    public static func isMuted(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }

        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return status == noErr && muted != 0
    }

    /// A change arrived. Measured on this Mac: **one** volume step produces
    /// about four of these — CoreAudio notifies per element, so the main
    /// scalar, each channel and mute all fire — and every one of them used to
    /// run the whole chain behind `onChange`: a fresh readout, the satellite or
    /// the HUD ears summoned again, their animations restarted, their dismissal
    /// timers rescheduled. Four times the work per press, and while a key
    /// auto-repeats those pile onto the main actor faster than they drain.
    ///
    /// That is the difference between this and brightness, which has no
    /// notification at all and is polled: brightness could never produce a
    /// burst, and never felt slow.
    ///
    /// So the burst is collapsed into one readout a frame, and a readout that
    /// matches the last one is dropped entirely.
    @MainActor
    private func noteChange() {
        Self.notified += 1
        guard coalesce == nil else { return }
        // Inside our own ramp: wait for it to finish and read once, rather than
        // redrawing every value it passes through on the way.
        let remaining = Self.selfWriteUntil - Date().timeIntervalSinceReferenceDate
        let wait = remaining > 0
            ? Duration.milliseconds(Int(remaining * 1000))
            : Self.coalesceWindow
        coalesce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard let self else { return }
            self.coalesce = nil
            guard let readout = self.readout() else { return }
            guard readout != self.lastDelivered else { return }
            self.lastDelivered = readout
            Self.delivered += 1
            if DebugSwitches.isOn("LEDGE_TRACE_LEVELS") {
                Self.log.debug("""
                    volume notify=\(Self.notified, privacy: .public) \
                    delivered=\(Self.delivered, privacy: .public) \
                    listeners=\(self.listenerBlocks.count, privacy: .public)
                    """)
            }
            self.onChange(readout)
        }
    }

    public func readout() -> HUDReadout? {
        guard let device = Self.defaultOutputDevice(),
              let level = Self.level(of: device)
        else { return nil }
        return HUDReadout(kind: .volume, level: level, isMuted: Self.isMuted(device), deviceName: Self.deviceName(device))
    }

    // MARK: - Writing

    @discardableResult
    public static func setLevel(_ level: Double, on device: AudioObjectID) -> Bool {
        // NaN passes min/max unchanged; never hand it to CoreAudio.
        guard level.isFinite else { return false }
        var value = Float32(min(max(level, 0), 1))
        var wroteAny = false

        for element in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }

            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue
            else { continue }

            let status = AudioObjectSetPropertyData(
                device, &address, 0, nil,
                UInt32(MemoryLayout<Float32>.size), &value
            )
            if status == noErr {
                wroteAny = true
                // The main element controls everything; writing channels after
                // it would be redundant.
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return wroteAny
    }

    /// One selectable audio output.
    public struct OutputDevice: Equatable, Sendable {
        public let id: AudioObjectID
        public let name: String
    }

    /// Every device capable of output, for the routing picker.
    public static func outputDevices() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
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

        return ids.compactMap { id in
            guard hasOutputStreams(id), isRealHardware(id), let name = deviceName(id) else { return nil }
            return OutputDevice(id: id, name: name)
        }
    }

    /// Whether the device is an actual audio route rather than a software one.
    ///
    /// Conference and loopback drivers (Teams, BlackHole, Loopback…) register
    /// virtual output devices; CoreAudio marks those with a `Virtual` transport,
    /// and aggregates are stitched-together composites. Filtering on the
    /// transport type keeps the list to hardware automatically — no name lists
    /// to maintain.
    private static func isRealHardware(_ device: AudioObjectID) -> Bool {
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
    public static func outputLevel(of device: AudioObjectID) -> Double? {
        level(of: device)
    }

    /// The name of the device sound currently goes to, for the panel's title.
    public static func defaultOutputName() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        return deviceName(device)
    }

    /// Routes system output to the given device.
    @discardableResult
    public static func setDefaultOutputDevice(_ device: AudioObjectID) -> Bool {
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

    private static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
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

    /// Sets the device mute flag. Returns whether it took.
    @discardableResult
    public static func setMuted(_ muted: Bool, on device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }

        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else { return false }

        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        )
        return status == noErr
    }

    // MARK: - Watching

    public func startWatching() {
        stopWatching()

        // The default-device listener is installed *before* the per-device
        // guard: it is the recovery path. Returning early without it — launch
        // with no output device, or the only device unplugged (whose change
        // notification re-enters here) — left watching dead for the session,
        // with nothing to notice the device coming back.
        installDefaultDeviceListener()

        guard let device = Self.defaultOutputDevice() else {
            Self.log.notice("no default output device to watch")
            return
        }
        listeningDevice = device

        // Watch mute and every element that exists: a device answering only per
        // channel would otherwise change without ever notifying.
        var addresses: [AudioObjectPropertyAddress] = [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
        ]
        for element in [kAudioObjectPropertyElementMain, UInt32(1), UInt32(2)] {
            addresses.append(AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            ))
        }

        for var address in addresses {
            guard AudioObjectHasProperty(device, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.noteChange()
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
            if status == noErr {
                listenerBlocks.append((device, address, block))
            }
        }

        Self.log.debug("watching \(self.listenerBlocks.count) volume properties")
    }

    /// The default device itself changes when headphones are plugged in, at
    /// which point every per-device listener is attached to the wrong object —
    /// this one re-runs the whole arm.
    private func installDefaultDeviceListener() {
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.startWatching()
            }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceAddress, queue, deviceBlock
        ) == noErr {
            listenerBlocks.append((AudioObjectID(kAudioObjectSystemObject), deviceAddress, deviceBlock))
        }
    }

    public func stopWatching() {
        coalesce?.cancel()
        coalesce = nil
        lastDelivered = nil
        for (object, address, block) in listenerBlocks {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        listenerBlocks.removeAll()
        listeningDevice = nil
    }

    deinit {
        // Listener blocks hold a weak self, so leaving them attached would leak
        // the registration rather than the object. Cleared explicitly by
        // `stopWatching`; nothing to do here that is safe from `deinit`.
    }
}
