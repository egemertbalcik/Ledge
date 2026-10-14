import Foundation
import Testing

@testable import LedgeCore

@Suite("A Keep Awake length, in the units it is set in")
struct KeepAwakeSpanTests {

    @Test("A span splits into days, hours and minutes and adds back up")
    func roundTrip() {
        let span = KeepAwakeSpan(totalMinutes: 2 * 24 * 60 + 3 * 60 + 25)
        #expect(span.days == 2)
        #expect(span.hours == 3)
        #expect(span.minutes == 25)
        #expect(span.totalMinutes == 2 * 24 * 60 + 3 * 60 + 25)
    }

    @Test("One field moves on its own")
    func fieldsMoveIndependently() {
        // The pointer is on one number. Moving another one underneath it would
        // be the card changing something nobody can see themselves changing.
        let span = KeepAwakeSpan(days: 1, hours: 2, minutes: 30)
        let later = span.moving(.hours, by: 3)

        #expect(later.days == 1)
        #expect(later.hours == 5)
        #expect(later.minutes == 30)
    }

    @Test("A field stops at its own edge instead of carrying into the next")
    func fieldsDoNotCarry() {
        let span = KeepAwakeSpan(days: 0, hours: 1, minutes: 50)
        let pushed = span.moving(.minutes, by: 30)

        #expect(pushed.minutes == 59, "minutes stop at 59")
        #expect(pushed.hours == 1, "and the hour does not roll over by itself")
    }

    @Test("The whole span still stops at seven days")
    func theCeilingHolds() {
        let span = KeepAwakeSpan(days: 7, hours: 0, minutes: 0)
        #expect(span.totalMinutes == KeepAwakeReducer.maximumMinutes)
        #expect(span.startableMinutes == KeepAwakeReducer.maximumMinutes)

        let pushed = span.moving(.days, by: 5)
        #expect(pushed.totalMinutes == KeepAwakeReducer.maximumMinutes)
        #expect(pushed.days == 7)
    }

    @Test("A span says what it holds; only starting one holds it to the floor")
    func theFloorAppliesToStarting() {
        // The boxes are filled a number at a time, so while the question is
        // open the span is routinely below anything startable. Clamping there
        // would have the card type numbers back at the user.
        let span = KeepAwakeSpan(days: 0, hours: 0, minutes: 1)
        #expect(span.totalMinutes == 1, "one minute is what is in the boxes")
        #expect(span.startableMinutes == KeepAwakeReducer.minimumMinutes,
                "and the floor is what it would actually run for")
    }

    @Test("Empty boxes are nothing to start")
    func emptyIsEmpty() {
        #expect(KeepAwakeSpan(days: 0, hours: 0, minutes: 0).isEmpty)
        #expect(!KeepAwakeSpan(days: 0, hours: 0, minutes: 1).isEmpty)
    }

    @Test("Each field knows what one detent is worth")
    func stepsAreWholeUnits() {
        #expect(KeepAwakeSpan.Field.days.step == 24 * 60)
        #expect(KeepAwakeSpan.Field.hours.step == 60)
        #expect(KeepAwakeSpan.Field.minutes.step == 1)
    }
}

@Suite("What is left, written out")
struct KeepAwakeRemainingLabelTests {

    @Test("A session over a day is counted in days, not in hours")
    func daysComeOut() {
        // Fifty-one hours is true and useless: nobody holds that in their head.
        let seconds: Int = 2 * 24 * 3600 + 3 * 3600 + 15 * 60
        let label = KeepAwakeCopy.remainingLabel(TimeInterval(seconds))
        #expect(label == "2d 03h 15m")
    }

    @Test("Under a day the days are left off")
    func daysAreLeftOffWhenEmpty() {
        let seconds: Int = 3 * 3600 + 5 * 60
        #expect(KeepAwakeCopy.remainingLabel(TimeInterval(seconds)) == "3h 05m")
    }

    @Test("Under an hour it is only minutes")
    func minutesAlone() {
        let seconds: Int = 25 * 60
        #expect(KeepAwakeCopy.remainingLabel(TimeInterval(seconds)) == "25m")
    }

    @Test("The last minute is counted in seconds")
    func theLastMinuteCountsDown() {
        // "0m" for fifty-nine seconds said the session was over while the Mac
        // was still being held awake.
        #expect(KeepAwakeCopy.remainingLabel(59) == "0:59")
        #expect(KeepAwakeCopy.remainingLabel(5) == "0:05")
    }

    @Test("Nothing left reads as nothing, not as a negative")
    func zeroIsHonest() {
        #expect(KeepAwakeCopy.remainingLabel(0) == "0:00")
        #expect(KeepAwakeCopy.remainingLabel(-30) == "0:00")
    }

    @Test("The ear says a week as a week, not as ninety-nine hours")
    func compactSaysDays() {
        let week = TimeInterval(7 * 24 * 3600)
        #expect(KeepAwakeCopy.compactRemainingLabel(week) == "7d")
        let twoDaysThree = TimeInterval(2 * 24 * 3600 + 3 * 3600)
        #expect(KeepAwakeCopy.compactRemainingLabel(twoDaysThree) == "2d 3h")
    }
}
