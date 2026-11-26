import Foundation
import Testing

@testable import LedgeCore

/// The notch used to say the Finished card's whole sentence in one line the
/// width of the closed notch. "Ended at 15% battery so your Mac can sleep
/// before it runs out." showed its middle and nothing else. It says two short
/// lines now, in the row a device uses.
@Suite("What the notch says about Keep Awake")
struct KeepAwakeAnnouncedTests {

    private func finished(_ reason: KeepAwakeEndReason, lidClosed: Bool = false) -> NotchAnnouncement? {
        NotchAnnouncement.forKeepAwake(KeepAwakePayload(
            phase: .finished(reason), until: "17:40", batteryFloor: 15, lidClosed: lidClosed))
    }

    @Test("Every end the notch tells is two lines in the device row")
    func twoLines() {
        for reason in KeepAwakeEndReason.allCases where reason.isVisible {
            let said = finished(reason)
            #expect(said?.style == .device, "\(reason) is still one long line")
            #expect(said?.title == "Keep Awake ended")
            #expect(said?.subtitle?.isEmpty == false, "\(reason) gives no reason")
            #expect(said?.symbolName == "cup.and.saucer.fill")
            #expect(said?.batteries.isEmpty == true)
            #expect(said?.followsPeekDuration == false, "it holds for the fixed three seconds")
        }
    }

    @Test("Each reason has its own line under it")
    func reasons() {
        #expect(finished(.timeUp)?.subtitle == "Time up at 17:40")
        #expect(finished(.endedByYou)?.subtitle == "Your Mac can sleep again")
        #expect(finished(.batteryFloor)?.subtitle == "Battery at 15%")
        #expect(finished(.batteryUnreadable)?.subtitle == "Battery level unreadable")
        #expect(finished(.thermal)?.subtitle == "Your Mac is very hot")
        #expect(finished(.thermal, lidClosed: true)?.subtitle == "Too hot. Open the lid.")
        #expect(finished(.macRestarted)?.subtitle == "Your Mac restarted")
        #expect(finished(.ledgeNotRunning)?.subtitle == "Ledge was not running")
        #expect(finished(.sleepChangedElsewhere)?.subtitle == "Another app changed sleep")
    }

    @Test("No two reasons say the same thing")
    func distinct() {
        let lines = KeepAwakeEndReason.allCases.filter(\.isVisible).compactMap { finished($0)?.subtitle }
        #expect(Set(lines).count == lines.count)
    }

    @Test("An end with no surface left to say it on is not told")
    func notTold() {
        #expect(finished(.quit) == nil)
        #expect(finished(.turnedOff) == nil)
    }

    @Test("A time that is missing leaves no dangling word")
    func missingTime() {
        #expect(KeepAwakeCopy.announcedReason(.timeUp, at: "", floor: 15, lidClosed: false) == "Time up")
    }

    @Test("A hold picked up after a relaunch says so, with what is left under it")
    func resumed() {
        let timed = NotchAnnouncement.forKeepAwake(KeepAwakePayload(
            phase: .running, remaining: 2 * 3600 + 10 * 60, until: "16:40", resumed: true))
        #expect(timed?.title == "Keep Awake resumed")
        #expect(timed?.subtitle?.hasSuffix("left, until 16:40") == true)
        #expect(timed?.style == .device)

        let open = NotchAnnouncement.forKeepAwake(KeepAwakePayload(
            phase: .running, isIndefinite: true, resumed: true))
        #expect(open?.title == "Keep Awake resumed")
        #expect(open?.subtitle == "Until you switch it off")
    }

    @Test("The card keeps the whole sentence")
    func cardKeepsTheSentence() {
        #expect(KeepAwakeCopy.finished(.batteryFloor, at: "17:40", floor: 15, lidClosed: false)
            == "Ended at 15% battery so your Mac can sleep before it runs out.")
    }
}
