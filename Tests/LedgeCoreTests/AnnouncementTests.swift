import CoreGraphics
import Foundation
import LedgeCore
import Testing

@Suite("When the notch raises its voice")
struct NotchAnnouncementTests {

    private func timer(
        finished: Bool, isBreak: Bool = false, isCustom: Bool = false, label: String = "Focus"
    ) -> TimerPayload {
        TimerPayload(
            label: label, remaining: 0, total: 1500, isRunning: false,
            isFinished: finished, isBreak: isBreak, isCustom: isCustom
        )
    }

    /// The case that prompted this: twenty-five minutes of not looking at the
    /// notch, and the one moment it had something to say went by in the same
    /// two-second whisper as a keyboard layout change.
    @Test("A finished focus session says the break has started")
    func finishedWorkAnnounces() throws {
        // Named for what happens next, not for what stopped: someone who has
        // not looked at the notch in half an hour needs to know what to do.
        let announcement = try #require(NotchAnnouncement.forTimer(timer(finished: true)))
        #expect(announcement.title == "Break time")
    }

    @Test("A finished break says to come back")
    func finishedBreakAnnounces() throws {
        let announcement = try #require(
            NotchAnnouncement.forTimer(timer(finished: true, isBreak: true, label: "Break"))
        )
        #expect(announcement.title == "Back to work")
    }

    @Test("A one-off countdown does not borrow the pomodoro's wording")
    func customTimerHasItsOwnWords() throws {
        let announcement = try #require(
            NotchAnnouncement.forTimer(timer(finished: true, isCustom: true, label: "Timer"))
        )
        #expect(announcement.title == "Timer done")
    }

    /// Starting a timer is something the user just did and is looking at.
    /// Only an ending is worth standing up for.
    @Test("Nothing else stands the notch up")
    func onlyEndingsAnnounce() {
        #expect(NotchAnnouncement.forTimer(timer(finished: false)) == nil)
        #expect(NotchAnnouncement.forTimer(TimerPayload(label: "Timer", remaining: 1500, total: 1500)) == nil)
    }

    /// The dots are the one structural flourish, and they carry something
    /// true: at the end of a session, how many you have done is the other
    /// thing worth knowing.
    @Test("A pomodoro carries its cycle; a one-off countdown has none")
    func cycleTravelsWithThePomodoro() throws {
        var payload = timer(finished: true)
        payload.completedSessions = 3
        #expect(try #require(NotchAnnouncement.forTimer(payload)).completedSessions == 3)

        var custom = timer(finished: true, isCustom: true, label: "Timer")
        custom.completedSessions = 3
        #expect(try #require(NotchAnnouncement.forTimer(custom)).completedSessions == 0)
    }

    @Test("It stands up for a couple of seconds, not a glance and not a card")
    func durationIsBetween() {
        #expect(NotchAnnouncement.duration > 1.5)
        #expect(NotchAnnouncement.duration < 4)
    }
}

@Suite("The shape when it stands up")
struct AnnouncingLayoutTests {

    private let geometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 180, height: 32),
        notchCenterX: 735,
        isHardwareNotch: true
    )

    private func height(announcing: Bool) -> CGFloat {
        NotchLayout.layout(
            for: .peek,
            geometry: geometry,
            expandedSize: CGSize(width: 320, height: 160),
            bottomRadius: 12,
            closedBottomRadius: 10,
            gutterRadius: 10,
            isAnnouncing: announcing
        ).bodySize.height
    }

    /// Nearly double, and nowhere near a card: the notch raising its voice for
    /// a second, not opening.
    @Test("Announcing very nearly doubles the resting height")
    func announcingDoubles() {
        let resting = height(announcing: false)
        let standing = height(announcing: true)
        #expect(standing > resting)
        #expect(standing - resting == geometry.notchSize.height)
        #expect(standing < 160, "still far short of a card")
    }

    @Test("An ordinary peek is untouched")
    func ordinaryPeekUnchanged() {
        #expect(height(announcing: false) == geometry.notchSize.height + NotchLayout.compactExtraHeight)
    }

    /// Taken from the hardware, so it holds on a machine with a different
    /// cutout.
    @Test("The extra height follows the cutout")
    func extraFollowsTheHardware() {
        let taller = NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 200, height: 40),
            notchCenterX: 735,
            isHardwareNotch: true
        )
        #expect(NotchLayout.announceExtraHeight(for: taller) == 40)
    }
}
