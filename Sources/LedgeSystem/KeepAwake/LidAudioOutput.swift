import CoreAudio
import Foundation
import LedgeCore

/// Audio output addressed by device uid, over CoreAudio.
///
/// Everything here is public CoreAudio, so none of it needs a permission and
/// none of it can be refused for the reasons the private frameworks can.
/// The writes go through `VolumeController.apply`, which is the one write path
/// in this app: volume and mute are separate controls, a scalar of zero is not
/// silence, and the order the two go out in is audible. A second writer here
/// would get one of those wrong.
public struct CoreAudioLidOutput: LidAudioOutput {

    public init() {}

    public func currentOutput() -> AudioOutputReading? {
        guard let device = VolumeController.defaultOutputDevice() else { return nil }
        return reading(of: device)
    }

    public func observe(uid: String, governed: [UInt32]?) -> AudioOutputReading? {
        guard let device = Self.device(uid: uid) else { return nil }
        guard let uid = Self.uid(of: device) else { return nil }
        // Through the journalled controls and nothing else. Asking the
        // hardware again which controls govern it is how a master that Ledge
        // never managed to write — or one whose capability query has since
        // changed its mind — came to certify channels that were still silent.
        //
        // A record with no plan answers *unknown*, never free: it is present,
        // so the restore runs, and the record is kept until one lands.
        return AudioOutputReading(
            uid: uid,
            name: VolumeController.deviceName(device),
            volume: VolumeController.level(of: device),
            muted: governed.flatMap { Self.mutedState(device, within: $0) },
            governed: governed,
            reasons: VolumeController.muteReasons(device),
            intentRevision: VolumeController.lastIntentDeclaration(of: device),
            intentIncarnation: VolumeController.intentIncarnation
        )
    }

    public func setMuted(_ muted: Bool, uid: String, governed: [UInt32]?) -> LidRestoreOutcome {
        guard let device = Self.device(uid: uid) else { return .incomplete }
        return Self.restoreMute(muted, on: device, within: governed,
                                using: VolumeController.writer)
    }

    /// Silences a device, or lets it speak, without touching why.
    ///
    /// Two things were wrong with going through `VolumeController.apply(muted:)`
    /// here. It sets the *user's* mute intent, so a device that was silent
    /// only because its level was zero came back as a device the user had
    /// muted — the red pill, which they never pressed. And it reported the
    /// set operation's status rather than the device's: an acknowledged but
    /// ineffective unmute answered `.master` while the output stayed silent,
    /// and the conserver discarded the only record of it.
    ///
    /// Confined to the plan the journal carries. Falling back onto a control
    /// the record does not name would be a change with no undo entry behind
    /// it, which is the one thing this file refuses to do — so a plan that
    /// cannot be honoured keeps the obligation instead of moving it.
    static func restoreMute(_ muted: Bool,
                            on device: AudioObjectID,
                            within governed: [UInt32]?,
                            using writer: VolumeWriter) -> LidRestoreOutcome {
        let answer = writer.restoreMuteOnly(muted, to: device, within: governed)
        let outcome = LidRestoreOutcome(mute: answer.outcome)
        guard outcome.isSettled else { return .incomplete }
        // Topology *and* every governed element agreeing. The aggregate flag
        // answered "is it muted everywhere", and false is also what a
        // half-muted device and an unreadable one say — so it could show that
        // a mute took and never that an unmute did.
        guard answer.agrees else { return .incomplete }
        return outcome
    }

    public func restoreReasons(_ reasons: MuteReasons, uid: String) {
        guard let device = Self.device(uid: uid) else { return }
        VolumeController.restoreReasons(reasons, for: device)
    }

    private func reading(of device: AudioObjectID) -> AudioOutputReading? {
        guard let uid = Self.uid(of: device) else { return nil }
        let planned = Self.plan(device)
        return AudioOutputReading(
            uid: uid,
            name: VolumeController.deviceName(device),
            // For the log. Nothing restores it: the conserve never moves a
            // level, so the restore has no level of its own to put back.
            volume: VolumeController.level(of: device),
            // Unknown stays unknown all the way to the policy. Reading a
            // failed query as "not muted" made it look like the user had
            // unmuted the device themselves, and `LidRestore.audio` then
            // dropped the whole undo record before any restore ran.
            muted: planned.muted,
            // And which controls that answer came from, so the restore writes
            // the same ones rather than whichever the hardware nominates next
            // time it is asked.
            governed: planned.governed,
            reasons: VolumeController.muteReasons(device),
            intentRevision: VolumeController.lastIntentDeclaration(of: device),
            intentIncarnation: VolumeController.intentIncarnation
        )
    }

    /// The controls Ledge may touch on this device, and what they read as now.
    ///
    /// Both halves at once because they belong together: the state is only
    /// meaningful as the state *of those controls*, and the record needs both
    /// before anything is silenced. `VolumeController.isMuted` collapses "no"
    /// and "could not tell" into false, which is right for a bar on screen
    /// and wrong for a record somebody's audio depends on.
    static func plan(_ device: AudioObjectID,
                     hardware: any VolumeHardware = SystemVolumeHardware())
        -> (governed: [UInt32], muted: Bool?) {
        // The elements Ledge can actually change, which is the same decision
        // the write makes. Reading an independent *read-only* master instead
        // reported a device as unmuted while every channel Ledge had silenced
        // was still silenced — and `LidRestore.audio` reads that as the user
        // having freed the device and throws the undo record away.
        //
        // And a control that exists but will not answer stays unknown rather
        // than borrowing a reassuring answer from somewhere else.
        let governed = VolumeWriter(hardware: hardware).mutedElements(of: device)
        guard !governed.isEmpty else { return ([], nil) }

        var seen: [Bool] = []
        for element in governed {
            guard let value = hardware.readMute(device, element: element) else {
                return (governed, nil)
            }
            seen.append(value)
        }
        // Half muted is not muted, and it is not unmuted either.
        guard seen.allSatisfy({ $0 == seen[0] }) else { return (governed, nil) }
        return (governed, seen[0])
    }

    /// Whether Ledge's silence is still in force on the controls it used.
    ///
    /// Not the same question as "is this device muted", and the difference is
    /// the whole of the fix. `false` here means every control in the plan has
    /// been let go — the user freed the device, and the entry may be
    /// discarded. One control still muted means the silence Ledge made is
    /// still partly there, which is still Ledge's to undo. A control that
    /// will not answer is unknown, and unknown keeps the obligation.
    static func mutedState(_ device: AudioObjectID,
                           within governed: [UInt32],
                           hardware: any VolumeHardware = SystemVolumeHardware()) -> Bool? {
        guard !governed.isEmpty else { return nil }
        var unreadable = false
        for element in governed {
            guard let value = hardware.readMute(device, element: element) else {
                unreadable = true
                continue
            }
            // Half muted is not freed. Finding one silent control is enough
            // to know the user has not taken this device back.
            if value { return true }
        }
        return unreadable ? nil : false
    }

    // MARK: - Uids

    /// `kAudioDevicePropertyDeviceUID`, the one name for a device that
    /// survives it being unplugged.
    ///
    /// The `AudioObjectID` does not: it is an index into the current set of
    /// devices, and CoreAudio hands the same number out again for a different
    /// device after one goes away. A restore that trusted an id could land on
    /// a webcam.
    static func uid(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        let text = uid as String
        return text.isEmpty ? nil : text
    }

    /// The device with this uid, or nil when it is not attached.
    ///
    /// Asked by walking every device rather than through
    /// `kAudioHardwarePropertyTranslateUIDToDevice`, which answers with
    /// `kAudioObjectUnknown` for an absent device on some releases and with an
    /// error on others — two ways of saying the same thing, and the walk says
    /// it once.
    static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0
        else { return nil }

        var ids = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
        else { return nil }

        return ids.first { Self.uid(of: $0) == uid }
    }
}
