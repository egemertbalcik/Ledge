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

    /// The mute flag for one element, or nil when the device has none there.
    ///
    /// Nil and false are different answers, and conflating them is what made
    /// the mute key one-way on channel-only devices: a missing master read as
    /// "not muted", so a successfully muted headset was reported live and the
    /// next press tried to mute it again.
    public func readMute(_ device: AudioObjectID, element: UInt32) -> Bool? {
        var address = Self.address(kAudioDevicePropertyMute, element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr
        else { return nil }
        return muted != 0
    }

    /// Present *and* writable. A device that reports the property but refuses
    /// to be set is the digital-output case: the write would return an error
    /// and the key would look dead, so it is skipped and the next element
    /// tried instead.
    /// How many output channels the device has, from its stream
    /// configuration. Nil when it will not say, which is the caller's cue to
    /// assume stereo.
    public func outputChannels(_ device: AudioObjectID) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return nil }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr
        else { return nil }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        let count = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard count > 0 else { return nil }
        // CoreAudio numbers channel elements from 1; the main element is 0.
        return (1...UInt32(count)).map { $0 }
    }

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
