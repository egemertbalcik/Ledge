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
    public static let main = kAudioObjectPropertyElementMain

    /// The fallback channel list, for hardware that will not say how many
    /// channels it has. Stereo, because nearly everything is — but a device
    /// that *does* say gets asked: a six-channel interface controlled through
    /// elements 1 and 2 alone is four channels left at whatever they were,
    /// including unmuted.
    public static let assumedChannels: [UInt32] = [1, 2]
}

/// How completely a scalar write landed.
///
/// The distinction matters because of what happens next: unmuting after a
/// write that did *not* land means the output comes back at the old level,
/// which on the way down from 0.9 to 0.2 is a blast through somebody's
/// headphones. Only a level that is genuinely in force may be unmuted into.
public enum ScalarOutcome: Equatable, Sendable {

    /// The master control took it, and governs every channel.
    case master

    /// No master, and every channel that exists took it.
    case everyChannel

    /// Some channels took it and some refused — the output is now at a level
    /// nobody asked for, lopsided between channels.
    case partial

    /// A control exists and refused the write.
    case refused

    /// No settable control anywhere.
    case unsupported

    /// Whether the device is now at the level that was asked for.
    public var isComplete: Bool { self == .master || self == .everyChannel }

    /// Whether any part of the write was taken.
    public var accepted: Bool { isComplete || self == .partial }
}

/// How completely a mute write landed, with the same meanings `ScalarOutcome`
/// has — and for the same reason. A device half muted is a device still making
/// sound, and reporting that as muted left the mute key with nothing to do.
public enum MuteOutcome: Equatable, Sendable {

    /// The master control took it, and governs every channel.
    case master

    /// Every channel that needed changing took it.
    case everyChannel

    /// Some channels took it and some refused — the device is half muted,
    /// which is not muted.
    case partial

    /// A control exists and refused the write.
    case refused

    /// No settable mute control anywhere.
    case unsupported

    /// Nothing needed doing: every element was already as asked.
    case alreadySettled

    /// Whether the device is now in the state that was asked for.
    public var isComplete: Bool {
        self == .master || self == .everyChannel || self == .alreadySettled
    }

    /// Whether a write was taken. `alreadySettled` is complete without being
    /// an acceptance — nothing was written, so nothing changed.
    public var accepted: Bool {
        self == .master || self == .everyChannel || self == .partial
    }
}

/// What applying a level or a mute actually did, verified by reading the
/// hardware back afterwards.
///
/// The readback is the point. A device is free to clamp the scalar to its
/// nearest supported step, to refuse the write, or to have no mute control at
/// all, and the interface must show what happened rather than what was asked
/// for — a bar that moves when nothing moved is the control lying.
public struct VolumeWriteResult: Equatable, Sendable {

    /// The scalar as the hardware now reports it — the physical value, which
    /// a device is free to clamp.
    public let level: Double

    /// The level to *show*, and to step from.
    ///
    /// Zero when the output is silent because zero was asked for, whatever the
    /// hardware reads back. A device that clamps zero to 0.062 was displaying
    /// 6% on an output that had been turned all the way down — and the next
    /// volume-up stepped from 0.062 rather than from zero, losing a step.
    public let shownLevel: Double

    /// Whether the hardware now reports the output muted — silence, which is
    /// not the same question as whether the user asked for mute.
    public let isMuted: Bool

    /// Whether the interface should show the muted state: the user's own mute,
    /// and only once the hardware has actually taken it.
    public let showsMuted: Bool

    /// How completely the level write landed.
    public let scalarOutcome: ScalarOutcome

    /// How completely the mute write landed.
    public let muteOutcome: MuteOutcome

    /// The mute reasons after this operation, for the caller to store. Never
    /// claims a reason the hardware refused to honour.
    public let reasons: MuteReasons

    /// Whether a mute write was accepted. False when none was needed.
    public var muteAccepted: Bool { muteOutcome.accepted }

    /// Whether what the interface shows has changed. A mute pressed at a level
    /// of zero does this without the device's property moving at all: it was
    /// already muted for silence, and is now muted because the user said so.
    public let presentationChanged: Bool

    public var scalarAccepted: Bool { scalarOutcome.accepted }

    /// Whether the hardware or the presentation actually changed — never mere
    /// intent. A press that changed nothing must fall through rather than be
    /// swallowed: on a device whose controls are not settable, the system's own
    /// "locked" indicator is more use than a styled HUD over a dead key.
    public var didSomething: Bool { scalarAccepted || muteAccepted || presentationChanged }
}

/// The hardware operations a level write needs.
///
/// Separate from `AudioHardware`, which is about *watching*: this is the write
/// path, and it exists as a protocol for the same reason — a fake on it can
/// assert the order the writes went out in, and hold per-element state, which
/// is the half of this that no status code reports.
public protocol VolumeHardware: Sendable {
    func canWriteScalar(_ device: AudioObjectID, element: UInt32) -> Bool
    func writeScalar(_ value: Double, _ device: AudioObjectID, element: UInt32) -> Bool
    func canWriteMute(_ device: AudioObjectID, element: UInt32) -> Bool
    func writeMute(_ muted: Bool, _ device: AudioObjectID, element: UInt32) -> Bool
    func readScalar(_ device: AudioObjectID) -> Double?

    /// The mute flag for one element, or nil when that element has none.
    ///
    /// Per element because a channel-only device has no master mute to read:
    /// asking the master and taking its silence for "not muted" reported a
    /// successfully muted headset as live, which made the mute key one-way.
    func readMute(_ device: AudioObjectID, element: UInt32) -> Bool?

    /// The output channels this device actually has, or nil when it will not
    /// say.
    ///
    /// Asked rather than assumed: elements 1 and 2 cover almost everything
    /// and silently miss the rest, which on a six-channel interface means
    /// four channels left at whatever they were — including unmuted.
    func outputChannels(_ device: AudioObjectID) -> [UInt32]?
}

extension VolumeHardware {

    /// The channels to act on: what the device reports, or stereo if it will
    /// not say.
    public func channels(of device: AudioObjectID) -> [UInt32] {
        let reported = outputChannels(device) ?? []
        return reported.isEmpty ? VolumeElement.assumedChannels : reported
    }

    /// Whether the output is muted, by the same ladder a write uses.
    ///
    /// The master answers for the whole device when it has one. Otherwise the
    /// output is muted only when every channel that can be read says so —
    /// anything less is a half-muted device that is still making sound.
    public func isOutputMuted(_ device: AudioObjectID) -> Bool {
        if let master = readMute(device, element: VolumeElement.main) { return master }
        // Every *reported* channel must say muted — including the ones that
        // cannot be read. A six-channel interface with mute controls on two of
        // them is four channels still making sound, and skipping the unreadable
        // ones reported that device as silent.
        let reported = channels(of: device)
        guard !reported.isEmpty else { return false }
        return reported.allSatisfy { readMute(device, element: $0) == true }
    }
}

/// The one place a level or mute is written.
///
/// CoreAudio keeps volume and mute as separate controls, and a scalar of zero
/// is not silence — it is the quietest gain the device has. Measured on this
/// Mac's own speakers: scalar 0.0625 is −47.6 dB, scalar 0.0000 is −63.5 dB.
/// Low, and still playing. Only the mute property takes the output to nothing.
///
/// So turning the sound all the way down writes zero *and* mutes, and raising
/// it again writes the new scalar first and unmutes after — and only if that
/// scalar actually landed, because unmuting into a level that was refused
/// means the old, louder one comes back.
///
/// None of that reaches the interface as a mute: the red state follows the
/// user's own mute, which `VolumeMuteState` holds apart from the silence.
///
/// Five call sites used to do a version of this each: none muted at zero, and
/// two unmuted in the wrong order.
public struct VolumeWriter: Sendable {

    private let hardware: any VolumeHardware

    public init(hardware: any VolumeHardware) {
        self.hardware = hardware
    }

    /// Applies a level, keeping the device's mute consistent with it.
    ///
    /// - Parameter reasons: why this output is currently silent, if it is.
    ///   Raising the level clears both reasons — moving a slider up is a
    ///   request to hear something — but only when the new level is verifiably
    ///   in force. Reaching zero adds `zeroSilence` and leaves any user mute
    ///   exactly where it was.
    /// - Returns: nil only for a level that is not a number, which is never
    ///   handed to CoreAudio.
    public func apply(
        level: Double,
        to device: AudioObjectID,
        reasons: MuteReasons = .none
    ) -> VolumeWriteResult? {
        guard level.isFinite else { return nil }
        let target = min(max(level, 0), 1)
        let showsBefore = reasons.showsMuted && hardware.isOutputMuted(device)

        let outcome = writeScalar(target, to: device)

        var wanted = reasons
        if target == 0 {
            // Judged by what was *asked for*, never by the readback: a device
            // that clamps zero reports an audible scalar, and reading that
            // would lose the only reason the output is silent.
            wanted.zeroSilence = true
        } else if outcome.isComplete {
            // The level is really there, so neither reason stands: raising is
            // a request to hear something, and that includes clearing a mute
            // the user set.
            wanted = .none
        }
        // A refused or lopsided write leaves the old level in place, and
        // unmuting into that is the blast all of this guards against: `wanted`
        // keeps whatever was already holding the output silent.

        let muteOutcome = settle(wanted.deviceMuted, on: device)
        return readback(
            device, wanted: wanted,
            scalarOutcome: outcome, muteOutcome: muteOutcome, showsBefore: showsBefore
        )
    }

    /// Sets the user's own mute, which does not touch the level.
    ///
    /// The two reasons compose: pressing mute at a level of zero adds the
    /// user's own reason to the silence already in force, and pressing it again
    /// takes only that reason away. The output stays muted, because the level
    /// is still zero — which is what stops a clamped minimum coming back
    /// audible.
    public func apply(
        userMuted: Bool,
        to device: AudioObjectID,
        reasons: MuteReasons
    ) -> VolumeWriteResult {
        let showsBefore = reasons.showsMuted && hardware.isOutputMuted(device)
        var wanted = reasons
        wanted.userMuted = userMuted
        let muteOutcome = settle(wanted.deviceMuted, on: device)
        return readback(
            device, wanted: wanted,
            scalarOutcome: .unsupported,  // no level was asked for
            muteOutcome: muteOutcome, showsBefore: showsBefore
        )
    }

    /// The hardware's own account of where it ended up.
    private func readback(
        _ device: AudioObjectID,
        wanted: MuteReasons,
        scalarOutcome: ScalarOutcome,
        muteOutcome: MuteOutcome,
        showsBefore: Bool
    ) -> VolumeWriteResult {
        let muted = hardware.isOutputMuted(device)
        // A reason the hardware refused to honour is not a reason: a device
        // with no mute control, or one that took the write on only half its
        // channels, is still making sound and must not be drawn — or
        // remembered — as silent.
        let honoured: MuteReasons = muted ? wanted : .none
        let raw = hardware.readScalar(device) ?? 0
        return VolumeWriteResult(
            level: raw,
            // Logical zero, kept apart from the physical scalar: a clamped
            // zero is still zero as far as everything above here is concerned.
            shownLevel: honoured.zeroSilence ? 0 : raw,
            isMuted: muted,
            showsMuted: honoured.showsMuted,
            scalarOutcome: scalarOutcome,
            muteOutcome: muteOutcome,
            reasons: honoured,
            presentationChanged: honoured.showsMuted != showsBefore
        )
    }

    /// Brings every applicable element to the mute state wanted.
    ///
    /// Deliberately not "is the aggregate already right": a half-muted stereo
    /// device reads as unmuted, so unmuting it looked like a no-op and left one
    /// channel silent. Each element is compared and written on its own.
    private func settle(_ muted: Bool, on device: AudioObjectID) -> MuteOutcome {
        if hardware.canWriteMute(device, element: VolumeElement.main) {
            if hardware.readMute(device, element: VolumeElement.main) == muted {
                return .alreadySettled
            }
            if hardware.writeMute(muted, device, element: VolumeElement.main) { return .master }
            // A master that refuses is not the end of it: some devices expose
            // a read-only master beside settable channels.
        }

        // Every reported channel, not just the ones with controls. Filtering
        // the uncontrollable ones out and calling the remainder complete is
        // how a six-channel device with mute on channels 1–2 came to be
        // reported as muted while four channels played on.
        let reported = hardware.channels(of: device)
        guard !reported.isEmpty else { return .unsupported }

        let unsettled = reported.filter { hardware.readMute(device, element: $0) != muted }
        guard !unsettled.isEmpty else { return .alreadySettled }

        let writable = unsettled.filter { hardware.canWriteMute(device, element: $0) }
        guard !writable.isEmpty else { return .unsupported }

        let taken = writable.filter { hardware.writeMute(muted, device, element: $0) }
        // Complete only when every channel that was *not already there* took
        // it — the ones already in the right state need nothing, and the ones
        // with no control were counted into `unsettled` above precisely so
        // they cannot be quietly dropped from the reckoning.
        if taken.count == unsettled.count { return .everyChannel }
        return taken.isEmpty ? .refused : .partial
    }

    /// Main element first; a device without one is written per channel.
    private func writeScalar(_ value: Double, to device: AudioObjectID) -> ScalarOutcome {
        if hardware.canWriteScalar(device, element: VolumeElement.main) {
            if hardware.writeScalar(value, device, element: VolumeElement.main) { return .master }
            // A master that refuses is not the end of it: some devices expose
            // a read-only master beside settable channels.
        }
        // Judged against every channel the device reports, not against the
        // subset that happens to have a writable control: lowering two of six
        // channels and then unmuting all six is the failure this prevents.
        let reported = hardware.channels(of: device)
        let writable = reported.filter { hardware.canWriteScalar(device, element: $0) }
        guard !writable.isEmpty else {
            return hardware.canWriteScalar(device, element: VolumeElement.main) ? .refused : .unsupported
        }
        let taken = writable.filter { hardware.writeScalar(value, device, element: $0) }
        // Complete only if every reported channel is now at the level asked
        // for. Anything less is a device at a level nobody requested, and
        // unmuting into that is the blast all of this guards against.
        if taken.count == reported.count { return .everyChannel }
        return taken.isEmpty ? .refused : .partial
    }

}
