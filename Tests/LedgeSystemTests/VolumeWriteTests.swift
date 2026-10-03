import CoreAudio
import Foundation
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

    /// Which elements answer each control. The default is a well-behaved
    /// device with a master for both.
    var scalarElements: Set<UInt32> = [kAudioObjectPropertyElementMain]
    var muteElements: Set<UInt32> = [kAudioObjectPropertyElementMain]

    /// Elements that report the control and refuse the write — the digital
    /// output case.
    var refusedScalarWrites: Set<UInt32> = []
    var refusedMuteWrites: Set<UInt32> = []

    /// What the device reports back. A real one is free to clamp.
    var level: Double = 0.5
    var muted = false
    var clampsTo: Double?

    private(set) var writes: [Write] = []

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
        self.muted = muted
        return true
    }

    func readScalar(_ device: AudioObjectID) -> Double? { level }
    func readMute(_ device: AudioObjectID) -> Bool { muted }
}

/// CoreAudio keeps volume and mute as separate controls, and the two mean
/// different things to the person at the keyboard: turning the sound all the
/// way down is a level of zero, and only the mute key claims the Mac is muted.
/// So a level write clears mute and never sets it — and the order it clears it
/// in is audible.
@Suite("Writing the output level")
struct VolumeWriteTests {

    private let device: AudioObjectID = 100

    private func writer(_ hardware: FakeVolumeHardware) -> VolumeWriter {
        VolumeWriter(hardware: hardware)
    }

    private var main: UInt32 { kAudioObjectPropertyElementMain }

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
        #expect(result?.changedMute == false)
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
        #expect(result?.changedMute == false)
    }

    /// Some digital outputs have no mute control anywhere. Ledge must not draw
    /// a red pill over a mute that never happened.
    @Test("A device with no mute control is never drawn as muted")
    func unsupportedMute() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0.5
        hardware.muteElements = []
        let result = writer(hardware).apply(userMuted: true, to: device, wasUserMuted: false)
        #expect(hardware.writes.isEmpty)
        #expect(result.changedMute == false)
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
        let result = writer(hardware).apply(userMuted: true, to: device, wasUserMuted: false)
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
        #expect(level?.changedLevel == true)
        #expect(level?.changedMute == true)
    }

    /// Raising a muted output whose level will not move: the unmute still
    /// took, so the press did something and is worth swallowing and showing.
    @Test("A level that will not take but an unmute that will still counts as acting")
    func partialFailureStillActs() {
        let hardware = FakeVolumeHardware()
        hardware.muted = true
        hardware.refusedScalarWrites = [main]
        let result = writer(hardware).apply(level: 0.5, to: device)
        #expect(result?.changedLevel == false)
        #expect(result?.changedMute == true)
        #expect(result?.didSomething == true)
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
        let result = writer(hardware).apply(userMuted: true, to: device, wasUserMuted: false)
        #expect(hardware.writes == [.mute(true, element: main)])
        #expect(result.level == 0.6)
        #expect(result.isMuted)
        #expect(result.showsMuted, "and the interface says so")
        #expect(result.changedLevel == false)
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
        let result = writer(hardware).apply(userMuted: true, to: device, wasUserMuted: false)
        #expect(hardware.writes.isEmpty, "there is nothing left to silence")
        #expect(result.showsMuted, "but it is the user's mute now, and shows")
        #expect(result.changedPresentation)
        #expect(result.didSomething, "so the key is handled rather than falling through")
    }

    /// And pressing it again clears the red without letting the sound back:
    /// the level is still zero, so the device stays muted.
    @Test("Unmuting at a level of zero keeps the silence")
    func unmuteAtZeroStaysSilent() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0
        hardware.muted = true
        let result = writer(hardware).apply(userMuted: false, to: device, wasUserMuted: true)
        #expect(hardware.writes.isEmpty)
        #expect(result.isMuted, "still silent at zero")
        #expect(result.showsMuted == false, "and the red state is gone")
        #expect(result.didSomething)
    }

    @Test("Setting mute to what it already shows writes nothing and says so")
    func muteNoOp() {
        let hardware = FakeVolumeHardware()
        hardware.level = 0.5
        hardware.muted = true
        let result = writer(hardware).apply(userMuted: true, to: device, wasUserMuted: true)
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
        let result = writer(hardware).apply(level: 0.3, to: device, userMuted: true)
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
        let result = writer(hardware).apply(level: 0, to: device, userMuted: true)
        #expect(result?.isMuted == true)
        #expect(result?.showsMuted == true)
    }
}
