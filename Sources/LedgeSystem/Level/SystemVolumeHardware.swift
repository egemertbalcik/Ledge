import CoreAudio
import Foundation

/// `VolumeHardware` against the real CoreAudio.
///
/// Every call is one synchronous property access, which is what the rest of
/// this file's callers already do; the type exists so the decisions above it
/// can be tested without a Mac's audio system in the loop.
public struct SystemVolumeHardware: VolumeHardware {

    public init() {}

    public func canWriteScalar(_ device: AudioObjectID, element: UInt32) -> Bool {
        settable(device, kAudioDevicePropertyVolumeScalar, element)
    }

    public func writeScalar(_ value: Double, _ device: AudioObjectID, element: UInt32) -> Bool {
        var address = Self.address(kAudioDevicePropertyVolumeScalar, element)
        var scalar = Float32(value)
        return AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &scalar
        ) == noErr
    }

    public func canWriteMute(_ device: AudioObjectID, element: UInt32) -> Bool {
        settable(device, kAudioDevicePropertyMute, element)
    }

    public func writeMute(_ muted: Bool, _ device: AudioObjectID, element: UInt32) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute, element)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }

    public func readScalar(_ device: AudioObjectID) -> Double? {
        VolumeController.level(of: device)
    }

    public func readMute(_ device: AudioObjectID) -> Bool {
        VolumeController.isMuted(device)
    }

    /// Present *and* writable. A device that reports the property but refuses
    /// to be set is the digital-output case: the write would return an error
    /// and the key would look dead, so it is skipped and the next element
    /// tried instead.
    private func settable(
        _ device: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ element: UInt32
    ) -> Bool {
        var address = Self.address(selector, element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ element: UInt32
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }
}
