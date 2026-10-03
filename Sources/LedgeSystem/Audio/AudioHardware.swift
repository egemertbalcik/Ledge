import CoreAudio
import Foundation
import LedgeCore

/// One registration with the audio hardware, for as long as it is held.
public protocol AudioRegistration: AnyObject, Sendable {
    /// Takes the listener off. Doing it twice is not an error and does not
    /// unregister anything else.
    func cancel()
}

/// Everything the volume watcher needs from the audio hardware.
///
/// It exists so the watcher can be tested without a Mac's audio system in the
/// loop. That matters more than usual here: the bug this boundary was drawn
/// for — registrations that accumulated because CoreAudio could not match them
/// for removal — is invisible to a test that can only count Swift objects. A
/// fake on this protocol can count the calls that actually reached the
/// hardware, which is the number that ran away.
///
/// Reads are here too, not only registration, so a test can move the default
/// device and watch what the watcher does about it.
public protocol AudioHardware: Sendable {

    func defaultOutputDevice() -> AudioObjectID?

    func hasProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool

    /// Level, mute and name for a device, as one reading.
    func readout(for device: AudioObjectID) -> HUDReadout?

    /// - Returns: nil when the hardware refused, which is ordinary for a
    ///   property a device does not have.
    func listen(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioRegistration?
}

/// The real one: CoreAudio, through the C shim that can actually unregister.
public struct SystemAudioHardware: AudioHardware {

    public init() {}

    public func defaultOutputDevice() -> AudioObjectID? {
        VolumeController.defaultOutputDevice()
    }

    public func hasProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    public func readout(for device: AudioObjectID) -> HUDReadout? {
        guard let level = VolumeController.level(of: device) else { return nil }
        let muted = VolumeController.isMuted(device)
        // A mute that arrived from outside Ledge — Control Centre, a headset
        // button — is the user muting, and the watch is where we find out.
        // Only above zero, where a muted output cannot be our own silence.
        VolumeController.noteObservedMute(muted, level: level)
        return HUDReadout(
            kind: .volume,
            level: level,
            isMuted: VolumeController.showsMuted(device, level: level),
            deviceName: VolumeController.deviceName(device)
        )
    }

    public func listen(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioRegistration? {
        AudioListener(object: object, address: address, queue: queue, handler: handler)
    }
}
