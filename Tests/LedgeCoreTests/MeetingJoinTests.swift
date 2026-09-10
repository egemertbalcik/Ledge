import Foundation
import LedgeCore
import Testing

@Suite("Offering a meeting link")
struct MeetingJoinTests {

    private let hour: TimeInterval = 3_600

    @Test("Not offered while the meeting is still hours away")
    func tooEarly() {
        #expect(!MeetingJoin.isOffered(startsIn: 2 * hour, endsIn: 3 * hour, hasLink: true))
        #expect(!MeetingJoin.isOffered(startsIn: 31 * 60, endsIn: 90 * 60, hasLink: true))
    }

    @Test("Offered from half an hour out")
    func leadTime() {
        #expect(MeetingJoin.isOffered(startsIn: 30 * 60, endsIn: 90 * 60, hasLink: true))
        #expect(MeetingJoin.isOffered(startsIn: 5 * 60, endsIn: 65 * 60, hasLink: true))
    }

    @Test("Offered while it is running")
    func during() {
        // Twenty minutes in, forty to go.
        #expect(MeetingJoin.isOffered(startsIn: -20 * 60, endsIn: 40 * 60, hasLink: true))
    }

    /// The bug this rule was written for: a start time alone cannot say that a
    /// meeting is over, so the button never left.
    @Test("Withdrawn the moment it ends")
    func afterTheEnd() {
        #expect(!MeetingJoin.isOffered(startsIn: -61 * 60, endsIn: -1, hasLink: true))
        #expect(!MeetingJoin.isOffered(startsIn: -8 * hour, endsIn: -7 * hour, hasLink: true))
    }

    @Test("Without an end time, an hour is assumed rather than forever")
    func unknownEnd() {
        #expect(MeetingJoin.isOffered(startsIn: -30 * 60, endsIn: nil, hasLink: true))
        #expect(!MeetingJoin.isOffered(startsIn: -61 * 60, endsIn: nil, hasLink: true))
    }

    @Test("No link, no button")
    func noLink() {
        #expect(!MeetingJoin.isOffered(startsIn: 0, endsIn: hour, hasLink: false))
        #expect(!MeetingJoin.isOffered(startsIn: -60, endsIn: nil, hasLink: false))
    }

    /// An all-day event reports a start far behind and an end far ahead. It is
    /// not a meeting anybody joins at a moment, but if it carries a link the
    /// rule should still behave: the end is what governs.
    @Test("A long event with a link is offered until it ends")
    func allDay() {
        #expect(MeetingJoin.isOffered(startsIn: -6 * hour, endsIn: 6 * hour, hasLink: true))
        #expect(!MeetingJoin.isOffered(startsIn: -30 * hour, endsIn: -6 * hour, hasLink: true))
    }
}
