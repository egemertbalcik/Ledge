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

    /// When the last write of our own settles.
    ///
    /// Written from the main actor and read from the watch's own queue, so it
    /// is behind a lock rather than an isolation domain.
    private nonisolated static let selfWrite = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    /// Called by the paths that set the level themselves.
    public nonisolated static func noteSelfWrite(
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) {
        selfWrite.withLock { $0 = now + selfWriteQuiet }
    }

    /// How long the current self-write still has to settle, or zero.
    nonisolated static func selfWriteRemaining(
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) -> TimeInterval {
        max(0, selfWrite.withLock { $0 } - now)
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

    public nonisolated static func isMuted(_ device: AudioObjectID) -> Bool {
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

    public func readout() -> HUDReadout? {
        guard let device = Self.defaultOutputDevice(),
              let level = Self.level(of: device)
        else { return nil }
        return HUDReadout(kind: .volume, level: level, isMuted: Self.isMuted(device), deviceName: Self.deviceName(device))
    }

    // MARK: - Writing

    @discardableResult
    public nonisolated static func setLevel(_ level: Double, on device: AudioObjectID) -> Bool {
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
    public nonisolated static func outputDevices() -> [OutputDevice] {
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

    private nonisolated static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
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

    /// Sets the device mute flag. Returns whether it took.
    @discardableResult
    public nonisolated static func setMuted(_ muted: Bool, on device: AudioObjectID) -> Bool {
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
