import CoreAudio
import Foundation
import LedgeCore
import Testing

@testable import LedgeSystem

/// Audio hardware that records what was written, in the order it arrived.
///
/// Order is the half of this that no status code reports: unmuting before the
/// new scalar lands plays a moment of the old, louder level, and nothing in
/// CoreAudio's return values would ever say so.
private final class FakeVolumeHardware: VolumeHardware, @unchecked Sendable {

    enum Write: Equatable {
        case scalar(Double, element: UInt32)
        case mute(Bool, element: UInt32)
    }

    /// How many output channels the device reports. Nil models hardware that
    /// will not say, which is the caller's cue to assume stereo.
    var channelCount: Int? = 2

    /// Which elements answer each control. The default is a well-behaved
    /// device with a master for both.
    var scalarElements: Set<UInt32> = [VolumeElement.main]
    var muteElements: Set<UInt32> = [VolumeElement.main]

    /// Elements that report the control and refuse the write — the digital
    /// output case, and a read-only master beside settable channels.
    var refusedScalarWrites: Set<UInt32> = []
    var refusedMuteWrites: Set<UInt32> = []

    /// Per element, so no test can pass against one global flag: a device
    /// muted on one channel and live on the other is a real state, and the one
    /// that used to be reported as simply "muted".
    private var muteByElement: [UInt32: Bool] = [:]

    var level: Double = 0.5
    var clampsTo: Double?

    private(set) var writes: [Write] = []

    /// Gives every element with a mute control the same flag, as a device
    /// whose master governs its channels would.
    var muted: Bool {
        get { isOutputMuted(0) }
        set { for element in muteElements { muteByElement[element] = newValue } }
    }

    func setMuted(_ muted: Bool, element: UInt32) {
        muteByElement[element] = muted
    }

    func readMute(_ device: AudioObjectID, element: UInt32) -> Bool? {
        guard muteElements.contains(element) else { return nil }
        return muteByElement[element] ?? false
    }

    func outputChannels(_ device: AudioObjectID) -> [UInt32]? {
        guard let channelCount, channelCount > 0 else { return nil }
        return (1...UInt32(channelCount)).map { $0 }
    }

    /// Hands every channel both controls — the channel-only device, at
    /// whatever width the test asked for.
    func makeChannelOnly(channels: Int) {
        channelCount = channels
        let elements = Set((1...UInt32(channels)).map { $0 })
        scalarElements = elements
        muteElements = elements
    }

    func canWriteScalar(_ device: AudioObjectID, element: UInt32) -> Bool {
        scalarElements.contains(element)
    }

    func writeScalar(_ value: Double, _ device: AudioObjectID, element: UInt32) -> Bool {
        writes.append(.scalar(value, element: element))
        guard !refusedScalarWrites.contains(element) else { return false }
        level = clampsTo ?? value
        return true
    }

    func canWriteMute(_ device: AudioObjectID, element: UInt32) -> Bool {
        muteElements.contains(element)
    }

    func writeMute(_ muted: Bool, _ device: AudioObjectID, element: UInt32) -> Bool {
        writes.append(.mute(muted, element: element))
        guard !refusedMuteWrites.contains(element) else { return false }
        muteByElement[element] = muted
        return true
    }

    func readScalar(_ device: AudioObjectID) -> Double? { level }
}

/// CoreAudio keeps volume and mute as separate controls, a scalar of zero is
/// not silence, and a write that was refused must not be unmuted into. Every
/// rule in `VolumeWriter` is here, against hardware that answers per element.
@Suite("Writing the output level")
struct VolumeWriteTests {

    private let device: AudioObjectID = 100

    private func writer(_ hardware: FakeVolumeHardware) -> VolumeWriter {
        VolumeWriter(hardware: hardware)
    }

    private var main: UInt32 { VolumeElement.main }

    /// Measured, not assumed: on this Mac's speakers a scalar of zero is
    /// −63.5 dB — the quietest gain the device has, and audible in a still
    /// room. Only the mute control is silence, so reaching zero writes both.
    /// What the *interface* shows is a separate question, settled in
    /// `HUDReadout`: an empty bar, never the red pill.
    @Test("Reaching zero writes the scalar and then mutes")
    func zeroSilencesTheOutput() {
        let hardware = FakeVolumeHardware()
        let result = writer(hardware).apply(level: 0, to: device)
        #expect(hardware.writes == [.scalar(0, element: main), .mute(true, element: main)])
        #expect(result?.level == 0)
        #expect(result?.isMuted == true, "the device is silenced")
        #expect(result?.didSomething == true)
    }

    /// A device that will not go below its lowest step is silenced by the mute
    /// anyway, and the readback still says where the level really landed.
    @Test("A device that clamps zero is silenced and reports the clamp")
    func clampingDeviceIsSilenced() {
        let hardware = FakeVolumeHardware()
        hardware.clampsTo = 0.05
        let result = writer(hardware).apply(level: 0, to: device)
        #expect(result?.level == 0.05, "the readback tells the truth about the clamp")
        #expect(result?.isMuted == true, "and mute makes it silent regardless")
    }

    @Test("Raising from mute writes the new level before unmuting")
    func raisingFromMuteOrdersTheWrites() {
        let hardware = FakeVolumeHardware()
        hardware.muted = true
        hardware.level = 0.9
        let result = writer(hardware).apply(level: 0.2, to: device)
        #expect(
            hardware.writes == [.scalar(0.2, element: main), .mute(false, element: main)],
            "unmuting first would play a moment of the old, louder level"
        )
        #expect(result?.level == 0.2)
        #expect(result?.isMuted == false)
    }

    @Test("Raising an output that is not muted touches mute at all")
    func raisingUnmutedLeavesMuteAlone() {
        let hardware = FakeVolumeHardware()
        let result = writer(hardware).apply(level: 0.8, to: device)
        #expect(hardware.writes == [.scalar(0.8, element: main)])
        #expect(result?.muteAccepted == false)
    }

    /// Lowering to zero while the user has muted leaves their mute alone: they
    /// said mute, and a level write is not an answer to that.
    @Test("Reaching zero on an already muted output does not write mute twice")
    func zeroWhileMutedKeepsTheMute() {
        let hardware = FakeVolumeHardware()
        hardware.muted = true
        let result = writer(hardware).apply(level: 0, to: device)
        #expect(hardware.writes == [.scalar(0, element: main)])
        #expect(result?.isMuted == true, "and it stays muted")
        #expect(result?.muteAccepted == false)
    }

    /// Some digital outputs have no mute control anywhere. Ledge must not draw
    /// a red pill over a mute that never happened.
    @Test("A device with no mute control is never drawn as muted")
    func unsupportedMute() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0.5
        hardware.muteElements = []
        let result = writer(hardware).apply(userMuted: true, to: device, reasons: .none)
        #expect(hardware.writes.isEmpty)
        #expect(result.muteAccepted == false)
        #expect(result.isMuted == false, "the hardware cannot be muted")
        #expect(result.showsMuted == false, "so nothing claims it is")
    }

    /// Most USB interfaces and some Bluetooth headsets expose no master
    /// control and answer per channel — for mute exactly as for volume.
    @Test("A device with no master is muted channel by channel")
    func channelLevelMute() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0.5
        hardware.muteElements = [1, 2]
        let result = writer(hardware).apply(userMuted: true, to: device, reasons: .none)
        #expect(hardware.writes == [.mute(true, element: 1), .mute(true, element: 2)])
        #expect(result.isMuted == true)
        #expect(result.showsMuted == true)
    }

    @Test("A device with no master takes the level channel by channel")
    func channelLevelVolume() {
        let hardware = FakeVolumeHardware()
        hardware.scalarElements = [1, 2]
        let result = writer(hardware).apply(level: 0.3, to: device)
        #expect(hardware.writes == [.scalar(0.3, element: 1), .scalar(0.3, element: 2)])
        #expect(result?.level == 0.3)
    }

    @Test("A master control is not followed by redundant channel writes")
    func masterShortCircuits() {
        let hardware = FakeVolumeHardware()
        hardware.scalarElements = [main, 1, 2]
        hardware.muteElements = [main, 1, 2]
        _ = writer(hardware).apply(level: 0, to: device)
        #expect(hardware.writes == [.scalar(0, element: main), .mute(true, element: main)])
    }

    /// A control that reports itself and then refuses the write: the next
    /// element down the ladder is tried rather than the whole operation
    /// failing.
    @Test("A refused master write falls through to the channels")
    func refusedMasterFallsThrough() {
        let hardware = FakeVolumeHardware()
        hardware.scalarElements = [main, 1, 2]
        hardware.muteElements = [main, 1, 2]
        hardware.refusedScalarWrites = [main]
        hardware.refusedMuteWrites = [main]
        let level = writer(hardware).apply(level: 0, to: device)
        #expect(hardware.writes == [
            .scalar(0, element: main), .scalar(0, element: 1), .scalar(0, element: 2),
            .mute(true, element: main), .mute(true, element: 1), .mute(true, element: 2),
        ])
        #expect(level?.scalarAccepted == true)
        #expect(level?.muteAccepted == true)
    }

    /// The blast this guards against: muted at 0.9, asked for 0.2, and the
    /// scalar write refused. Unmuting then brings 0.9 back through somebody's
    /// headphones. The mute stays until the level it is unmuting into is
    /// verifiably there.
    @Test("A refused level write never unmutes")
    func refusedLevelKeepsTheMute() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0.9
        hardware.muted = true
        hardware.refusedScalarWrites = [main]
        let result = writer(hardware).apply(level: 0.2, to: device, reasons: MuteReasons(userMuted: true))
        #expect(hardware.writes == [.scalar(0.2, element: main)], "no unmute went out")
        #expect(result?.isMuted == true, "still silent")
        #expect(result?.showsMuted == true, "and still the user's mute")
        #expect(result?.level == 0.9, "the old level is what the device is at")
        #expect(result?.scalarOutcome == .refused)
        #expect(result?.scalarAccepted == false)
    }

    /// Half a stereo pair taking the write is worse than none: the output is
    /// now lopsided at a level nobody asked for, and unmuting into that is the
    /// same blast on one side.
    @Test("A partial channel write never unmutes")
    func partialChannelWriteKeepsTheMute() {
        let hardware = FakeVolumeHardware()
        hardware.scalarElements = [1, 2]
        hardware.muteElements = [1, 2]
        hardware.level = 0.9
        hardware.muted = true
        hardware.refusedScalarWrites = [2]
        let result = writer(hardware).apply(level: 0.2, to: device, reasons: MuteReasons(userMuted: true))
        #expect(result?.scalarOutcome == .partial)
        #expect(result?.isMuted == true, "still silent")
        #expect(result?.showsMuted == true)
        #expect(
            hardware.writes == [.scalar(0.2, element: 1), .scalar(0.2, element: 2)],
            "and no unmute was attempted"
        )
    }

    /// A device with no settable level at all: nothing landed, so nothing is
    /// unmuted into. The press falls through to the system rather than Ledge
    /// drawing a HUD over a key that did nothing.
    @Test("An unsupported level write never unmutes")
    func unsupportedLevelKeepsTheMute() {
        let hardware = FakeVolumeHardware()
        hardware.scalarElements = []
        hardware.level = 0.9
        hardware.muted = true
        let result = writer(hardware).apply(level: 0.2, to: device, reasons: MuteReasons(userMuted: true))
        #expect(result?.scalarOutcome == .unsupported)
        #expect(result?.isMuted == true)
        #expect(result?.didSomething == false)
    }

    /// And when it does land, the unmute follows — that is the whole point of
    /// raising a muted output.
    @Test("A level that lands does unmute")
    func completeWriteUnmutes() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0.9
        hardware.muted = true
        let result = writer(hardware).apply(level: 0.2, to: device, reasons: MuteReasons(userMuted: true))
        #expect(hardware.writes == [.scalar(0.2, element: main), .mute(false, element: main)])
        #expect(result?.isMuted == false)
        #expect(result?.showsMuted == false)
        #expect(result?.reasons.userMuted == false, "and the intent is cleared for the caller to store")
    }

    /// Every channel taking it counts as landed, on a device with no master.
    @Test("Every channel taking the write unmutes")
    func everyChannelUnmutes() {
        let hardware = FakeVolumeHardware()
        hardware.scalarElements = [1, 2]
        hardware.muteElements = [1, 2]
        hardware.level = 0.9
        hardware.muted = true
        let result = writer(hardware).apply(level: 0.2, to: device, reasons: MuteReasons(userMuted: true))
        #expect(result?.scalarOutcome == .everyChannel)
        #expect(result?.isMuted == false)
    }

    /// Nothing took: the press must fall through so the system's own "locked"
    /// indicator appears, rather than Ledge drawing a HUD over a key that did
    /// nothing.
    @Test("A device that answers neither control reports doing nothing")
    func nothingTakes() {
        let hardware = FakeVolumeHardware()
        hardware.scalarElements = []
        hardware.muteElements = []
        let result = writer(hardware).apply(level: 0.4, to: device)
        #expect(hardware.writes.isEmpty)
        #expect(result?.didSomething == false)
    }

    @Test("A level that is not a number is never written")
    func nonFiniteRefused() {
        let hardware = FakeVolumeHardware()
        #expect(writer(hardware).apply(level: .nan, to: device) == nil)
        #expect(writer(hardware).apply(level: .infinity, to: device) == nil)
        #expect(hardware.writes.isEmpty)
    }

    @Test("Levels outside the range are clamped before they reach the hardware")
    func clampsTheRequest() {
        let hardware = FakeVolumeHardware()
        _ = writer(hardware).apply(level: 4, to: device)
        _ = writer(hardware).apply(level: -3, to: device)
        #expect(hardware.writes.first == .scalar(1, element: main))
        #expect(hardware.writes.contains(.scalar(0, element: main)))
    }

    @Test("The mute key sets mute and leaves the level alone")
    func muteAlone() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0.6
        let result = writer(hardware).apply(userMuted: true, to: device, reasons: .none)
        #expect(hardware.writes == [.mute(true, element: main)])
        #expect(result.level == 0.6)
        #expect(result.isMuted)
        #expect(result.showsMuted, "and the interface says so")
        #expect(result.scalarAccepted == false)
    }

    /// The reported case: at a level of zero the output is already muted for
    /// silence, so pressing mute has nothing left to write — and must still
    /// turn the indicator red, because the user has now muted as well as
    /// turned it down. Reporting "nothing happened" is what made the key look
    /// dead down there.
    @Test("The mute key still works at a level of zero")
    func muteAtZeroShowsTheState() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0
        hardware.muted = true  // silenced by having reached zero
        let result = writer(hardware).apply(userMuted: true, to: device, reasons: .none)
        #expect(hardware.writes.isEmpty, "there is nothing left to silence")
        #expect(result.showsMuted, "but it is the user's mute now, and shows")
        #expect(result.presentationChanged)
        #expect(result.didSomething, "so the key is handled rather than falling through")
    }

    /// Blocker, measured on this Mac: the speakers clamp a zero scalar to
    /// 0.062 (−47.6 dB, audible). The sequence that broke was turn-down,
    /// mute, mute again — the second press took away the only reason the
    /// output was silent, and the clamped minimum came back.
    @Test("Mute, then unmute, at a clamped zero stays silent")
    func clampedZeroSurvivesAMuteRoundTrip() {
        let hardware = FakeVolumeHardware()
        hardware.clampsTo = 0.062   // this Mac's own lowest step
        hardware.level = 0.5
        let writer = writer(hardware)

        // a. and b. turn the sound all the way down.
        let down = writer.apply(level: 0, to: device)
        #expect(down?.isMuted == true, "zero has to be silent")
        #expect(down?.level == 0.062, "and the device clamped it")
        #expect(down?.showsMuted == false, "no red pill for the volume keys")

        // c. press mute: now both reasons hold.
        let muted = writer.apply(userMuted: true, to: device, reasons: down!.reasons)
        #expect(muted.showsMuted, "the user's own mute shows")
        #expect(muted.isMuted)

        // d. press mute again.
        let unmuted = writer.apply(userMuted: false, to: device, reasons: muted.reasons)
        // e. the red goes, and the output stays silent — the level is still
        // nominally zero, whatever the scalar reads back as.
        #expect(unmuted.showsMuted == false, "the red state should clear")
        #expect(unmuted.isMuted, "but the clamped minimum came back audible")
        #expect(unmuted.reasons.zeroSilence, "the silence has its own reason")
    }

    /// And raising the level afterwards does let the sound back, safely.
    @Test("Raising from a clamped zero unmutes")
    func raisingFromClampedZeroUnmutes() {
        let hardware = FakeVolumeHardware()
        hardware.clampsTo = 0.062
        let writer = writer(hardware)
        let down = writer.apply(level: 0, to: device)
        hardware.clampsTo = nil  // the device takes ordinary levels again

        let up = writer.apply(level: 0.4, to: device, reasons: down!.reasons)
        #expect(up?.isMuted == false, "the output stayed silent after being turned up")
        #expect(up?.reasons.isEmpty == true)
    }

    /// Pressing mute at zero and then turning the volume up clears both
    /// reasons: moving a slider up is a request to hear something.
    @Test("Raising the level clears a user mute set at zero")
    func raisingClearsBothReasons() {
        let hardware = FakeVolumeHardware()
        let writer = writer(hardware)
        let down = writer.apply(level: 0, to: device)
        let muted = writer.apply(userMuted: true, to: device, reasons: down!.reasons)
        #expect(muted.reasons == MuteReasons(userMuted: true, zeroSilence: true))

        let up = writer.apply(level: 0.3, to: device, reasons: muted.reasons)
        #expect(up?.isMuted == false)
        #expect(up?.showsMuted == false)
    }

    @Test("Setting mute to what it already shows writes nothing and says so")
    func muteNoOp() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0.5
        hardware.muted = true
        let result = writer(hardware).apply(userMuted: true, to: device, reasons: MuteReasons(userMuted: true))
        #expect(hardware.writes.isEmpty)
        #expect(result.didSomething == false)
    }

    /// Raising the level clears the user's mute, which is what every system
    /// slider does: moving it up is a request to hear something.
    @Test("Raising the level clears the user's own mute")
    func raisingClearsUserMute() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0
        hardware.muted = true
        let result = writer(hardware).apply(level: 0.3, to: device, reasons: MuteReasons(userMuted: true))
        #expect(hardware.writes == [.scalar(0.3, element: main), .mute(false, element: main)])
        #expect(result?.isMuted == false)
        #expect(result?.showsMuted == false)
    }

    /// Turning the sound down to nothing while muted keeps the mute, and the
    /// red state with it: the user said mute, and the volume keys are not an
    /// answer to that.
    @Test("Reaching zero under a user mute stays red")
    func zeroUnderUserMuteStaysRed() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0.5
        hardware.muted = true
        let result = writer(hardware).apply(level: 0, to: device, reasons: MuteReasons(userMuted: true))
        #expect(result?.isMuted == true)
        #expect(result?.showsMuted == true)
    }
}

/// Reading the mute flag has the same ladder as writing it. A channel-only
/// device has no master to ask, and taking that silence for "not muted"
/// reported a successfully muted headset as live — which made the mute key
/// one-way: every press tried to mute, and nothing ever unmuted.
@Suite("Reading whether an output is muted")
struct MuteReadbackTests {

    private let device: AudioObjectID = 100
    private var main: UInt32 { VolumeElement.main }

    @Test("A master answers for the whole device")
    func masterAnswers() {
        let hardware = FakeVolumeHardware()
        #expect(hardware.isOutputMuted(device) == false)
        hardware.setMuted(true, element: main)
        #expect(hardware.isOutputMuted(device))
    }

    @Test("A channel-only device is read channel by channel")
    func channelsAnswer() {
        let hardware = FakeVolumeHardware()
        hardware.muteElements = [1, 2]
        #expect(hardware.isOutputMuted(device) == false)
        hardware.setMuted(true, element: 1)
        hardware.setMuted(true, element: 2)
        #expect(hardware.isOutputMuted(device), "muted on every channel is muted")
    }

    /// Half muted is not muted: one channel still making sound is a device the
    /// user can hear, and reporting it as muted would leave the mute key with
    /// nothing to do.
    @Test("A half-muted device is not muted")
    func halfMutedIsLive() {
        let hardware = FakeVolumeHardware()
        hardware.muteElements = [1, 2]
        hardware.setMuted(true, element: 1)
        #expect(hardware.isOutputMuted(device) == false)
    }

    /// The master wins when it exists, even over channel flags, because it is
    /// what governs the device.
    @Test("A master beside channels still wins")
    func masterWinsOverChannels() {
        let hardware = FakeVolumeHardware()
        hardware.muteElements = [main, 1, 2]
        hardware.setMuted(true, element: 1)
        hardware.setMuted(true, element: 2)
        #expect(hardware.isOutputMuted(device) == false, "the master says live")
        hardware.setMuted(true, element: main)
        #expect(hardware.isOutputMuted(device))
    }

    @Test("A device with no mute control anywhere is not muted")
    func noControlIsNotMuted() {
        let hardware = FakeVolumeHardware()
        hardware.muteElements = []
        #expect(hardware.isOutputMuted(device) == false)
    }

    /// The round trip the old reader broke: mute a channel-only device, read
    /// it back as muted, and the next press unmutes it.
    @Test("Muting a channel-only device is not one-way")
    func channelOnlyMuteRoundTrips() {
        let hardware = FakeVolumeHardware()
        hardware.muteElements = [1, 2]
        hardware.level = 0.5
        let writer = VolumeWriter(hardware: hardware)

        let muted = writer.apply(userMuted: true, to: device, reasons: .none)
        #expect(muted.isMuted, "read back as muted")
        #expect(muted.showsMuted)

        let unmuted = writer.apply(userMuted: false, to: device, reasons: MuteReasons(userMuted: true))
        #expect(unmuted.isMuted == false, "and the next press lets it go")
        #expect(unmuted.muteAccepted)
    }
}

/// Reconciling mute is per element, not per aggregate. A half-muted stereo
/// device reads as unmuted, so deciding "nothing to do" from the aggregate left
/// one channel silent — and a partial write reported success for a device that
/// was still making sound.
@Suite("Reconciling mute channel by channel")
struct ChannelMuteTests {

    private let device: AudioObjectID = 100
    private var main: UInt32 { VolumeElement.main }

    private func channelOnly(_ channels: Int) -> FakeVolumeHardware {
        let hardware = FakeVolumeHardware()
        hardware.makeChannelOnly(channels: channels)
        hardware.level = 0.5
        return hardware
    }

    @Test("Unmuting a half-muted device clears every channel")
    func unmutingClearsEveryChannel() {
        let hardware = channelOnly(2)
        hardware.setMuted(true, element: 1)   // left silent, right live
        #expect(hardware.isOutputMuted(device) == false, "half muted is not muted")

        let result = VolumeWriter(hardware: hardware)
            .apply(userMuted: false, to: device, reasons: MuteReasons(userMuted: true))
        #expect(
            hardware.readMute(device, element: 1) == false,
            "the muted channel was left muted, because the aggregate said unmuted"
        )
        #expect(result.muteOutcome == .everyChannel)
    }

    @Test("Muting a channel-only device writes every channel")
    func mutingWritesEveryChannel() {
        let hardware = channelOnly(2)
        let result = VolumeWriter(hardware: hardware)
            .apply(userMuted: true, to: device, reasons: .none)
        #expect(hardware.writes == [.mute(true, element: 1), .mute(true, element: 2)])
        #expect(result.isMuted)
        #expect(result.muteOutcome == .everyChannel)
    }

    /// One channel refusing is a device still making sound. It must not be
    /// reported as muted, and must not swallow the key as though it were.
    @Test("One channel refusing mute is a partial result")
    func oneChannelRefusingMute() {
        let hardware = channelOnly(2)
        hardware.refusedMuteWrites = [2]
        let result = VolumeWriter(hardware: hardware)
            .apply(userMuted: true, to: device, reasons: .none)
        #expect(result.muteOutcome == .partial)
        #expect(result.muteOutcome.isComplete == false)
        #expect(result.isMuted == false, "half muted was reported as muted")
        #expect(result.showsMuted == false, "and drawn as the user's mute")
        #expect(result.reasons.isEmpty, "a reason the hardware refused is not a reason")
    }

    @Test("One channel refusing unmute is a partial result")
    func oneChannelRefusingUnmute() {
        let hardware = channelOnly(2)
        hardware.muted = true
        hardware.refusedMuteWrites = [2]
        let result = VolumeWriter(hardware: hardware)
            .apply(userMuted: false, to: device, reasons: MuteReasons(userMuted: true))
        #expect(result.muteOutcome == .partial)
        #expect(hardware.readMute(device, element: 1) == false, "the channel that could unmute did")
        #expect(hardware.readMute(device, element: 2) == true, "and the one that could not did not")
    }

    @Test("A device already in the state asked for is not written again")
    func alreadySettledWritesNothing() {
        let hardware = channelOnly(2)
        hardware.muted = true
        let result = VolumeWriter(hardware: hardware)
            .apply(userMuted: true, to: device, reasons: MuteReasons(userMuted: true))
        #expect(hardware.writes.isEmpty)
        #expect(result.muteOutcome == .alreadySettled)
        #expect(result.muteAccepted == false, "nothing was written, so nothing was accepted")
        #expect(result.isMuted, "and it is still muted")
    }

    /// The channels are asked for, not assumed: a six-channel interface
    /// controlled through elements 1 and 2 alone is four channels left at
    /// whatever they were, including unmuted.
    @Test("Every reported channel is reconciled", arguments: [4, 6, 8])
    func everyChannelIsReconciled(count: Int) {
        let hardware = channelOnly(count)
        let result = VolumeWriter(hardware: hardware)
            .apply(userMuted: true, to: device, reasons: .none)
        let expected = (1...UInt32(count)).map { FakeVolumeHardware.Write.mute(true, element: $0) }
        #expect(hardware.writes == expected, "only \(hardware.writes.count) of \(count) channels")
        #expect(result.isMuted)
    }

    @Test("A level write also covers every reported channel", arguments: [4, 6])
    func levelCoversEveryChannel(count: Int) {
        let hardware = channelOnly(count)
        let result = VolumeWriter(hardware: hardware).apply(level: 0.3, to: device)
        let scalars = hardware.writes.filter {
            if case .scalar = $0 { return true } else { return false }
        }
        #expect(scalars.count == count)
        #expect(result?.scalarOutcome == .everyChannel)
    }

    /// Hardware that will not say how many channels it has is treated as
    /// stereo, which is what nearly everything is.
    @Test("Silence about the channel count means stereo")
    func unknownChannelCountAssumesStereo() {
        let hardware = FakeVolumeHardware()
        hardware.channelCount = nil
        hardware.scalarElements = [1, 2]
        hardware.muteElements = [1, 2]
        _ = VolumeWriter(hardware: hardware).apply(userMuted: true, to: device, reasons: .none)
        #expect(hardware.writes == [.mute(true, element: 1), .mute(true, element: 2)])
    }

    @Test("A master still short-circuits the channels")
    func masterShortCircuitsMute() {
        let hardware = FakeVolumeHardware()
        hardware.makeChannelOnly(channels: 6)
        hardware.scalarElements.insert(main)
        hardware.muteElements.insert(main)
        let result = VolumeWriter(hardware: hardware)
            .apply(userMuted: true, to: device, reasons: .none)
        #expect(hardware.writes == [.mute(true, element: main)])
        #expect(result.muteOutcome == .master)
    }
}

/// Mute reasons are per output and compose. One latch for the whole Mac meant
/// turning an AirPlay speaker down to nothing changed what the built-in
/// speakers claimed about themselves; one *reason* meant pressing mute at a
/// level of zero replaced the silence rather than adding to it, and pressing it
/// again let the clamped minimum back.
@Suite("Mute reasons, per output")
struct MuteIntentLedgerTests {

    private let speakers: UInt32 = 100
    private let airplay: UInt32 = 200

    @Test("Nothing is remembered to begin with")
    func startsEmpty() {
        let ledger = MuteIntentLedger()
        #expect(ledger.reasons(for: speakers) == .none)
        #expect(ledger.showsMuted(for: speakers) == false)
    }

    @Test("The two reasons compose rather than replace each other")
    func reasonsCompose() {
        var reasons = MuteReasons(zeroSilence: true)
        #expect(reasons.deviceMuted, "zero is silence")
        #expect(reasons.showsMuted == false, "and not the user's mute")

        reasons.userMuted = true
        #expect(reasons.showsMuted, "now it is both")

        reasons.userMuted = false
        #expect(reasons.deviceMuted, "and letting go of the mute leaves the silence")
        #expect(reasons.showsMuted == false)

        reasons.zeroSilence = false
        #expect(reasons.deviceMuted == false)
        #expect(reasons.isEmpty)
    }

    @Test("One output's reasons leave the others alone")
    func reasonsAreIndependent() {
        var ledger = MuteIntentLedger()
        ledger.set(MuteReasons(zeroSilence: true), for: airplay)
        #expect(ledger.reasons(for: airplay).zeroSilence)
        #expect(ledger.reasons(for: speakers) == .none, "the speakers were not touched")

        ledger.set(MuteReasons(userMuted: true), for: speakers)
        #expect(ledger.showsMuted(for: speakers))
        #expect(ledger.showsMuted(for: airplay) == false, "and still are not")
    }

    /// The clamped-readback trap: a device that will not go below its lowest
    /// step reports 0.062 while muted, which looks exactly like somebody
    /// muting at an audible level. Ours is not promoted to theirs.
    @Test("A clamped zero readback does not become a user mute")
    func clampedZeroStaysOurs() {
        var ledger = MuteIntentLedger()
        ledger.set(MuteReasons(zeroSilence: true), for: speakers)
        ledger.observed(muted: true, level: 0.062, for: speakers, isSelfWrite: false)
        #expect(ledger.reasons(for: speakers) == MuteReasons(zeroSilence: true))
        #expect(ledger.showsMuted(for: speakers) == false, "no red pill for our own silence")
    }

    @Test("An echo of our own write says nothing about intent")
    func selfWriteEchoIgnored() {
        var ledger = MuteIntentLedger()
        ledger.observed(muted: true, level: 0.5, for: speakers, isSelfWrite: true)
        #expect(ledger.reasons(for: speakers) == .none)
    }

    @Test("A mute from outside Ledge above zero is the user's")
    func outsideMuteIsAdopted() {
        var ledger = MuteIntentLedger()
        ledger.observed(muted: true, level: 0.4, for: speakers, isSelfWrite: false)
        #expect(ledger.showsMuted(for: speakers))
    }

    /// The case the watcher used to undo: mute pressed while the level sits at
    /// zero. Every echo afterwards reports muted at zero, which must not be
    /// read as our own silence and strip the red.
    @Test("An explicit mute at zero survives the watcher")
    func explicitMuteAtZeroSurvives() {
        var ledger = MuteIntentLedger()
        ledger.set(MuteReasons(userMuted: true, zeroSilence: true), for: speakers)
        for _ in 0..<5 {
            ledger.observed(muted: true, level: 0, for: speakers, isSelfWrite: false)
        }
        #expect(ledger.showsMuted(for: speakers), "still the user's mute")
    }

    @Test("Unmuting from outside clears every reason")
    func outsideUnmuteClears() {
        var ledger = MuteIntentLedger()
        ledger.set(MuteReasons(userMuted: true, zeroSilence: true), for: speakers)
        ledger.observed(muted: false, level: 0.4, for: speakers, isSelfWrite: false)
        #expect(ledger.reasons(for: speakers) == .none, "the hardware is the last word on silence")
    }

    @Test("Outputs that have gone away are forgotten")
    func vanishedRoutesPruned() {
        var ledger = MuteIntentLedger()
        ledger.set(MuteReasons(userMuted: true), for: speakers)
        ledger.set(MuteReasons(userMuted: true), for: airplay)
        #expect(ledger.count == 2)
        ledger.keepOnly([speakers])
        #expect(ledger.count == 1)
        #expect(ledger.reasons(for: airplay) == .none)
        #expect(ledger.showsMuted(for: speakers), "and the one still here is untouched")
    }
}

/// Self-write suppression is per output. One window for the whole Mac meant a
/// write to an AirPlay speaker silenced the news from the built-in output —
/// and a window opened for a write the hardware refused hid the fact that
/// nothing had happened.
@Suite("Self-write windows", .serialized)
@MainActor
struct SelfWriteWindowTests {

    private let speakers: AudioObjectID = 9_100
    private let airplay: AudioObjectID = 9_200

    private func clear() {
        // Windows are 150ms; a time far in the future is "long expired" from
        // the perspective of a window opened now.
        VolumeController.reconcileIntents(with: .devices([]))
    }

    @Test("A write to one output does not suppress another")
    func windowsAreIndependent() {
        let now: TimeInterval = 1_000
        VolumeController.noteSelfWrite(on: airplay, now: now)
        #expect(VolumeController.selfWriteRemaining(on: airplay, now: now) > 0)
        #expect(
            VolumeController.selfWriteRemaining(on: speakers, now: now) == 0,
            "the built-in output's observations were suppressed by an AirPlay write"
        )
    }

    @Test("A window expires on its own")
    func windowExpires() {
        let now: TimeInterval = 2_000
        VolumeController.noteSelfWrite(on: speakers, now: now)
        #expect(VolumeController.selfWriteRemaining(on: speakers, now: now + 1) == 0)
    }

    /// The controller is what decides whether a window opens at all: a refused
    /// write has no ramp to ignore, and ignoring its echo would hide that
    /// nothing happened.
    @Test("An observed mute during our own window is not adopted")
    func ownEchoIsIgnored() {
        clear()
        VolumeController.noteSelfWrite(on: speakers)
        VolumeController.noteObservedMute(true, level: 0.5, device: speakers)
        #expect(
            VolumeController.userMuted(speakers) == false,
            "our own echo was adopted as the user muting"
        )
    }

    @Test("An observed mute on another output is adopted")
    func otherOutputIsAdopted() {
        clear()
        VolumeController.noteSelfWrite(on: speakers)
        VolumeController.noteObservedMute(true, level: 0.5, device: airplay)
        #expect(
            VolumeController.userMuted(airplay),
            "a real mute elsewhere was swallowed by our window on another device"
        )
        clear()
    }
}

/// A device that reports six channels and offers controls on two of them is
/// not fully handled by writing those two. Filtering the uncontrollable
/// channels out and calling the remainder complete is how Ledge came to lower
/// two channels of six and then unmute all six.
@Suite("Partly controllable multichannel hardware")
struct PartialMultichannelTests {

    private let device: AudioObjectID = 100
    private var main: UInt32 { VolumeElement.main }

    /// Six reported channels; scalar and mute controls on 1 and 2 only.
    private func partlyControllable() -> FakeVolumeHardware {
        let hardware = FakeVolumeHardware()
        hardware.channelCount = 6
        hardware.scalarElements = [1, 2]
        hardware.muteElements = [1, 2]
        hardware.level = 0.9
        return hardware
    }

    @Test("A scalar write that reaches two of six channels is partial")
    func scalarIsPartial() {
        let hardware = partlyControllable()
        let result = VolumeWriter(hardware: hardware).apply(level: 0.2, to: device)
        #expect(result?.scalarOutcome == .partial, "two of six channels was called complete")
        #expect(result?.scalarOutcome.isComplete == false)
    }

    /// And therefore it must not unmute: four channels are still at the old,
    /// louder level.
    @Test("A partial scalar write never unmutes")
    func partialScalarDoesNotUnmute() {
        let hardware = partlyControllable()
        hardware.muted = true   // channels 1 and 2 muted; 3–6 have no control
        let result = VolumeWriter(hardware: hardware).apply(
            level: 0.2, to: device, reasons: MuteReasons(userMuted: true)
        )
        #expect(hardware.readMute(device, element: 1) == true, "a channel was unmuted")
        #expect(hardware.readMute(device, element: 2) == true)
        #expect(result?.reasons.userMuted == false, "nothing may claim a mute this device cannot hold")
    }

    @Test("A mute write that reaches two of six channels is partial")
    func muteIsPartial() {
        let hardware = partlyControllable()
        let result = VolumeWriter(hardware: hardware)
            .apply(userMuted: true, to: device, reasons: .none)
        #expect(result.muteOutcome == .partial, "two of six channels was called complete")
        #expect(result.isMuted == false, "a device with four live channels was reported muted")
        #expect(result.showsMuted == false)
    }

    /// The aggregate read has to agree: unreadable channels count against
    /// "muted", rather than being skipped.
    @Test("A device with unreadable channels is never reported muted")
    func unreadableChannelsAreNotMuted() {
        let hardware = partlyControllable()
        hardware.setMuted(true, element: 1)
        hardware.setMuted(true, element: 2)
        #expect(
            hardware.isOutputMuted(device) == false,
            "four channels with no mute control were treated as muted"
        )
    }

    /// A device whose every reported channel is controllable still reports
    /// complete — the rule tightened, it did not break.
    @Test("Fully controllable multichannel hardware is still complete", arguments: [4, 6, 8])
    func fullyControllableIsComplete(count: Int) {
        let hardware = FakeVolumeHardware()
        hardware.makeChannelOnly(channels: count)
        let level = VolumeWriter(hardware: hardware).apply(level: 0.3, to: device)
        #expect(level?.scalarOutcome == .everyChannel)
        let mute = VolumeWriter(hardware: hardware)
            .apply(userMuted: true, to: device, reasons: .none)
        #expect(mute.muteOutcome == .everyChannel)
        #expect(mute.isMuted)
    }

    /// And a device that reports more channels than it has controls for, but is
    /// *already* in the state asked for on every channel, needs no write.
    @Test("Already-settled is judged across every reported channel")
    func alreadySettledAcrossReportedChannels() {
        let hardware = partlyControllable()
        for element in UInt32(1)...6 { hardware.muteElements.insert(element) }
        hardware.muted = true
        let result = VolumeWriter(hardware: hardware)
            .apply(userMuted: true, to: device, reasons: MuteReasons(userMuted: true))
        #expect(result.muteOutcome == .alreadySettled)
        #expect(result.isMuted)
    }
}

/// Logical zero is not the physical scalar. On hardware that clamps a zero
/// request to its lowest step — this Mac's speakers read back 0.062 — the bar
/// showed 6% on an output that had been turned all the way down, and the next
/// volume-up stepped from 0.062 instead of from zero, losing a step.
@Suite("Logical zero")
struct LogicalZeroTests {

    private let device: AudioObjectID = 100

    private func clamping() -> FakeVolumeHardware {
        let hardware = FakeVolumeHardware()
        hardware.clampsTo = 0.062
        hardware.level = 0.5
        return hardware
    }

    @Test("A clamped zero shows as zero, while the hardware value stays visible")
    func clampedZeroShowsZero() {
        let hardware = clamping()
        let result = VolumeWriter(hardware: hardware).apply(level: 0, to: device)
        #expect(result?.level == 0.062, "the physical scalar is still reported")
        #expect(result?.shownLevel == 0, "the bar would have shown 6% on a silent output")
        #expect(result?.isMuted == true)
    }

    /// The step the user takes next: one configured step up from zero, not
    /// 0.062 plus a step.
    @Test("The first step up starts from zero, not from the clamp")
    func firstStepStartsFromZero() {
        let hardware = clamping()
        let writer = VolumeWriter(hardware: hardware)
        let down = writer.apply(level: 0, to: device)
        let base = try! #require(down?.shownLevel)
        let step = 0.0625
        hardware.clampsTo = nil

        let up = writer.apply(level: base + step, to: device, reasons: down!.reasons)
        #expect(up?.level == step, "the step started from the clamped 0.062, skipping one")
        #expect(up?.shownLevel == step)
    }

    /// Above zero the two are the same number: the logical level is only ever
    /// different where zero was asked for.
    @Test("Above zero the shown level is the hardware level")
    func aboveZeroTheyAgree() {
        let hardware = FakeVolumeHardware()
        let result = VolumeWriter(hardware: hardware).apply(level: 0.4, to: device)
        #expect(result?.level == 0.4)
        #expect(result?.shownLevel == 0.4)
    }

    /// A clamp that is *not* a zero request is reported honestly: the device
    /// landed somewhere else, and the bar must say where.
    @Test("A clamp above zero is shown as the clamp")
    func clampAboveZeroIsShown() {
        let hardware = FakeVolumeHardware()
        hardware.clampsTo = 0.33
        let result = VolumeWriter(hardware: hardware).apply(level: 0.4, to: device)
        #expect(result?.shownLevel == 0.33, "the bar must show where the device actually is")
    }

    /// And the user's own mute is independent of all of this.
    @Test("User mute at a clamped zero still shows as muted")
    func userMuteIsIndependent() {
        let hardware = clamping()
        let writer = VolumeWriter(hardware: hardware)
        let down = writer.apply(level: 0, to: device)
        let muted = writer.apply(userMuted: true, to: device, reasons: down!.reasons)
        #expect(muted.showsMuted)
        #expect(muted.shownLevel == 0, "and the level is still logically zero")
    }
}

/// "No devices" and "the question could not be answered" are different facts.
/// Conflating them cost real state: a transient CoreAudio enumeration failure
/// read as an empty Mac, every mute reason was dropped, and an output that had
/// been turned all the way down came back showing its clamped minimum with
/// the next step starting from there.
@Suite("Reconciling intent against a device inventory")
struct DeviceInventoryTests {

    private let speakers: UInt32 = 100
    private let airplay: UInt32 = 200
    private let virtualOutput: UInt32 = 300

    private func ledger() -> MuteIntentLedger {
        var ledger = MuteIntentLedger()
        ledger.set(MuteReasons(zeroSilence: true), for: speakers)
        ledger.set(MuteReasons(userMuted: true), for: airplay)
        ledger.set(MuteReasons(userMuted: true, zeroSilence: true), for: virtualOutput)
        return ledger
    }

    @Test("A failed enumeration prunes nothing")
    func failureKeepsEverything() {
        var ledger = self.ledger()
        ledger.reconcile(with: .unavailable)
        #expect(ledger.count == 3, "a transient failure threw away established state")
        #expect(ledger.reasons(for: speakers).zeroSilence, "the silent output lost its reason")
        #expect(ledger.showsMuted(for: airplay), "and the muted one lost its red")
    }

    @Test("A successful inventory prunes what has gone")
    func successPrunesDisappearedDevices() {
        var ledger = self.ledger()
        ledger.reconcile(with: .devices([speakers, virtualOutput]))
        #expect(ledger.count == 2)
        #expect(ledger.reasons(for: airplay) == .none, "a device that left kept its reasons")
        #expect(ledger.reasons(for: speakers).zeroSilence)
    }

    /// Virtual and aggregate outputs are hidden from the route picker and can
    /// still be the current route, so they belong in the retention set.
    @Test("A virtual output stays in the retention set")
    func virtualOutputIsRetained() {
        var ledger = self.ledger()
        // What the picker would show is only the real hardware; the inventory
        // is every output-capable device.
        ledger.reconcile(with: .devices([speakers, airplay, virtualOutput]))
        #expect(
            ledger.showsMuted(for: virtualOutput),
            "a conference app's output lost its mute on a route-list refresh"
        )
    }

    @Test("An empty inventory is a fact and does prune")
    func emptyInventoryPrunes() {
        var ledger = self.ledger()
        ledger.reconcile(with: .devices([]))
        #expect(ledger.count == 0)
    }

    /// The consequence the state exists for: a clamped zero preserved through
    /// a failed enumeration still shows zero and still steps from zero.
    @Test("A preserved clamped zero still shows and steps from zero")
    func preservedZeroStillShowsZero() {
        let hardware = FakeVolumeHardware()
        hardware.clampsTo = 0.062
        let writer = VolumeWriter(hardware: hardware)
        let down = writer.apply(level: 0, to: 100)
        var ledger = MuteIntentLedger()
        ledger.set(down!.reasons, for: 100)

        // A HAL hiccup: the enumeration fails, and nothing is forgotten.
        ledger.reconcile(with: .unavailable)
        let kept = ledger.reasons(for: 100)
        #expect(kept.zeroSilence)

        hardware.clampsTo = nil
        let step = 0.0625
        let up = writer.apply(level: 0 + step, to: 100, reasons: kept)
        #expect(up?.shownLevel == step, "the first step started from the clamped minimum")
    }
}

/// Output capability is three answers, not two. A failed per-device query used
/// to read as "no outputs", so a successful device list followed by one
/// transient failure erased that device's mute reasons — the same mistake as
/// reading a failed enumeration as an empty Mac, one level down.
@Suite("Classifying outputs")
struct OutputCapabilityTests {

    private let speakers: UInt32 = 100
    private let airplay: UInt32 = 200
    private let microphoneOnly: UInt32 = 300

    private func ledger() -> MuteIntentLedger {
        var ledger = MuteIntentLedger()
        ledger.set(MuteReasons(zeroSilence: true), for: speakers)
        ledger.set(MuteReasons(userMuted: true), for: airplay)
        return ledger
    }

    @Test("A device whose query failed keeps its reasons")
    func unknownCapabilityIsRetained() {
        var ledger = self.ledger()
        // The device list came back; this device's stream query did not.
        ledger.reconcile(with: .retaining([speakers: .output, airplay: .unknown]))
        #expect(
            ledger.showsMuted(for: airplay),
            "one failed per-device query erased an established mute"
        )
        #expect(ledger.reasons(for: speakers).zeroSilence)
    }

    @Test("A confirmed non-output is pruned")
    func notOutputIsPruned() {
        var ledger = self.ledger()
        ledger.set(MuteReasons(userMuted: true), for: microphoneOnly)
        ledger.reconcile(with: .retaining([
            speakers: .output, airplay: .output, microphoneOnly: .notOutput,
        ]))
        #expect(ledger.reasons(for: microphoneOnly) == .none, "an input-only device was kept")
        #expect(ledger.count == 2)
    }

    @Test("A device missing from the list entirely is pruned")
    func missingDeviceIsPruned() {
        var ledger = self.ledger()
        ledger.reconcile(with: .retaining([speakers: .output]))
        #expect(ledger.reasons(for: airplay) == .none)
    }

    /// The property that two separate reads broke: anything the picker would
    /// show is in the retention set, always. One classification, both
    /// decisions.
    @Test("Everything the picker shows is retained")
    func pickerIsAlwaysRetained() {
        let capabilities: [UInt32: OutputCapability] = [
            speakers: .output, airplay: .unknown, microphoneOnly: .notOutput, 400: .output,
        ]
        guard case .devices(let retained) = DeviceInventory.retaining(capabilities) else {
            Issue.record("a classification pass produced no inventory")
            return
        }
        let shown = capabilities.filter { $0.value == .output }.keys
        for id in shown {
            #expect(retained.contains(id), "the picker would show \(id) while retention dropped it")
        }
        #expect(retained.contains(airplay), "an unanswered query must not prune")
        #expect(!retained.contains(microphoneOnly))
    }

    @Test("An empty classification prunes everything, because it is an answer")
    func emptyClassificationPrunes() {
        var ledger = self.ledger()
        ledger.reconcile(with: .retaining([:]))
        #expect(ledger.count == 0)
    }
}
