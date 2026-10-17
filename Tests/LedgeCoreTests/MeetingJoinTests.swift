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

/// The one rule two layers read: the card draws Join from it, and the shell
/// reads it for a card that is off screen behind a readout.
@Suite("Whether a payload offers a join")
struct EventPayloadJoinTests {

    private func payload(
        startsIn: TimeInterval = 300,
        endsIn: TimeInterval? = 3_000,
        link: String? = "https://zoom.us/j/1",
        hasEvent: Bool = true
    ) -> EventPayload {
        EventPayload(
            title: "Design review",
            startsIn: startsIn,
            endsIn: endsIn,
            hasEvent: hasEvent,
            meetingURL: link
        )
    }

    @Test("A meeting about to start has a link to join")
    func offered() {
        #expect(payload().joinLink?.absoluteString == "https://zoom.us/j/1")
    }

    @Test("A meeting that has ended does not")
    func ended() {
        #expect(payload(startsIn: -4_000, endsIn: -400).joinLink == nil)
    }

    @Test("A meeting too far off does not")
    func tooEarly() {
        #expect(payload(startsIn: 4 * 3_600).joinLink == nil)
    }

    @Test("Nothing without an event, a link, or a usable one")
    func unusable() {
        #expect(payload(hasEvent: false).joinLink == nil)
        #expect(payload(link: nil).joinLink == nil)
        #expect(payload(link: "room 2, upstairs").joinLink == nil)
    }
}
