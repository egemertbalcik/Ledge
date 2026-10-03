import CoreAudio
import Foundation
import LedgeCore

/// Where a level or mute write can land.
///
/// The main element is the device's master control. Plenty of devices — most
/// USB interfaces, some Bluetooth headsets — expose no master at all and only
/// answer per channel, which is why reading already averages the channels.
/// Writing has to follow the same ladder, for mute as much as for level.
public enum VolumeElement: Sendable, Equatable {
    static let ladder: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]
}

/// What applying a level or a mute actually did, read back from the hardware.
///
/// The readback is the point. A device is free to clamp the scalar to its
/// nearest supported step, to refuse the write, or to have no mute control at
/// all, and the interface must show what happened rather than what was asked
/// for — a bar that moves when nothing moved is the control lying.
public struct VolumeWriteResult: Equatable, Sendable {

    /// The scalar as the hardware now reports it.
    public let level: Double

    /// The mute flag as the hardware now reports it — silence, which is not
    /// the same question as whether the user muted.
    public let isMuted: Bool

    /// Whether the interface should show the muted state. The user's own mute,
    /// confirmed by the hardware having taken it — see `VolumeMuteState`.
    public let showsMuted: Bool

    public let changedLevel: Bool
    public let changedMute: Bool

    /// Whether what the interface shows has changed, which a mute pressed at a
    /// level of zero does without the device's property moving at all: it was
    /// already muted for silence, and is now muted because the user said so.
    public let changedPresentation: Bool

    /// Whether anything took. A press or drag that changed nothing must fall
    /// through rather than be swallowed: on a device whose volume is genuinely
    /// not settable, the native "locked" indicator is more use than a styled
    /// HUD over a key that did nothing.
    public var didSomething: Bool { changedLevel || changedMute || changedPresentation }
}

/// The hardware operations a level write needs.
///
/// Separate from `AudioHardware`, which is about *watching*: this is the write
/// path, and it exists as a protocol for the same reason — a fake on it can
/// assert the order the writes went out in, which is the half of this that no
/// status code reports.
public protocol VolumeHardware: Sendable {
    func canWriteScalar(_ device: AudioObjectID, element: UInt32) -> Bool
    func writeScalar(_ value: Double, _ device: AudioObjectID, element: UInt32) -> Bool
    func canWriteMute(_ device: AudioObjectID, element: UInt32) -> Bool
    func writeMute(_ muted: Bool, _ device: AudioObjectID, element: UInt32) -> Bool
    func readScalar(_ device: AudioObjectID) -> Double?
    func readMute(_ device: AudioObjectID) -> Bool
}

/// The one place a level or mute is written.
///
/// CoreAudio keeps volume and mute as separate controls, and a scalar of zero
/// is not silence — it is the quietest gain the device has. Measured on this
/// Mac's own speakers: scalar 0.0625 is −47.6 dB, scalar 0.0000 is −63.5 dB.
/// Low, and still playing. Only the mute property takes the output to nothing.
///
/// So turning the sound all the way down writes zero *and* mutes, and raising
/// it again writes the new scalar first and unmutes after — unmuting first
/// plays a moment of the old, louder level.
///
/// None of that reaches the interface as a mute: `HUDReadout` presents a zero
/// level as an empty bar and the silent glyph, never as the red muted state,
/// which belongs to the mute key alone. The device is silenced; the user is
/// not told they pressed a button they did not press.
///
/// Five call sites used to do a version of this each: none muted at zero, and
/// two unmuted in the wrong order.
public struct VolumeWriter: Sendable {

    private let hardware: any VolumeHardware

    public init(hardware: any VolumeHardware) {
        self.hardware = hardware
    }

    /// Applies a level, taking mute with it, and reports what the hardware
    /// says afterwards.
    ///
    /// - Returns: nil only for a level that is not a number — never handed to
    ///   CoreAudio, which would take it verbatim.
    /// Applies a level, keeping the device's mute consistent with it.
    ///
    /// - Parameter userMuted: whether the user's own mute is in force. It is
    ///   not changed here — the volume keys are not a mute key — except that
    ///   raising the level clears it, which is what every system slider does:
    ///   moving it up is a request to hear something.
    /// - Returns: nil only for a level that is not a number, which is never
    ///   handed to CoreAudio.
    public func apply(
        level: Double,
        to device: AudioObjectID,
        userMuted: Bool = false
    ) -> VolumeWriteResult? {
        guard level.isFinite else { return nil }
        let target = min(max(level, 0), 1)
        let before = VolumeMuteState(userMuted: userMuted, level: hardware.readScalar(device) ?? 0)
        let after = VolumeMuteState(userMuted: userMuted && target <= 0, level: target)

        let changedLevel = writeScalar(target, to: device)
        // Always after the scalar: muting after it leaves the scalar at zero
        // for Control Centre to agree with, and unmuting after it means the
        // old, louder level is never heard on the way up.
        let changedMute = settle(after, on: device)

        return readback(
            device, state: after,
            changedLevel: changedLevel, changedMute: changedMute,
            changedPresentation: before.showsMuted != after.showsMuted
        )
    }

    /// Sets the user's own mute, which does not touch the level.
    ///
    /// At a level of zero the device is already muted for silence, so nothing
    /// is written — but what the interface shows changes, and the result says
    /// so, which is what stops the mute key looking dead down there.
    public func apply(userMuted: Bool, to device: AudioObjectID, wasUserMuted: Bool) -> VolumeWriteResult {
        let level = hardware.readScalar(device) ?? 0
        let before = VolumeMuteState(userMuted: wasUserMuted, level: level)
        let after = VolumeMuteState(userMuted: userMuted, level: level)
        let changedMute = settle(after, on: device)
        return readback(
            device, state: after,
            changedLevel: false, changedMute: changedMute,
            changedPresentation: before.showsMuted != after.showsMuted
        )
    }

    /// Brings the device's mute property to what the two intents require.
    private func settle(_ state: VolumeMuteState, on device: AudioObjectID) -> Bool {
        guard hardware.readMute(device) != state.deviceMuted else { return false }
        return writeMute(state.deviceMuted, to: device)
    }

    /// The hardware's own account of where it ended up.
    private func readback(
        _ device: AudioObjectID,
        state: VolumeMuteState,
        changedLevel: Bool,
        changedMute: Bool,
        changedPresentation: Bool
    ) -> VolumeWriteResult {
        let muted = hardware.readMute(device)
        return VolumeWriteResult(
            level: hardware.readScalar(device) ?? 0,
            isMuted: muted,
            // A device with no mute control cannot be muted, whatever was
            // asked of it, and must not be drawn as though it were.
            showsMuted: state.showsMuted && muted,
            changedLevel: changedLevel,
            changedMute: changedMute,
            changedPresentation: changedPresentation
        )
    }

    /// Main element first; a device without one is written per channel.
    private func writeScalar(_ value: Double, to device: AudioObjectID) -> Bool {
        var wroteAny = false
        for element in VolumeElement.ladder {
            guard hardware.canWriteScalar(device, element: element) else { continue }
            guard hardware.writeScalar(value, device, element: element) else { continue }
            wroteAny = true
            // The main element controls everything; the channels after it
            // would be redundant.
            if element == kAudioObjectPropertyElementMain { break }
        }
        return wroteAny
    }

    /// The same ladder for mute, which some devices expose only per channel.
    /// A device with no mute control anywhere is not an error: the readback
    /// will say the output is not muted, and the caller decides what to do
    /// with a key press that changed nothing.
    private func writeMute(_ muted: Bool, to device: AudioObjectID) -> Bool {
        var wroteAny = false
        for element in VolumeElement.ladder {
            guard hardware.canWriteMute(device, element: element) else { continue }
            guard hardware.writeMute(muted, device, element: element) else { continue }
            wroteAny = true
            if element == kAudioObjectPropertyElementMain { break }
        }
        return wroteAny
    }
}
