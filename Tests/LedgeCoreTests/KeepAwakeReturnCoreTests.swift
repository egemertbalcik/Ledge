import Foundation
import Testing

@testable import LedgeCore

/// The parts of "Espresso goes back to Coffee" that are plain values: what a
/// timed hold remembers, what an older record reads as, and what the notch
/// and the card say.
@Suite("Going back to the plain hold, in values")
struct KeepAwakeReturnCoreTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func session(lid: Bool, deadline: Date? = nil, returns: Bool? = nil) -> KeepAwakeSession {
        KeepAwakeSession(id: "A", startedAt: start, deadline: deadline, total: deadline == nil ? 0 : 60,
                         bootID: "boot", lidHoldRequested: lid, returnsToHold: returns)
    }

    @Test("A timed hold picked over Coffee remembers to go back")
    func overCoffee() {
        #expect(KeepAwakeSession.returnsToHold(after: session(lid: false)))
    }

    /// A plain hold with an end of its own comes from a record an earlier
    /// version wrote. Its time would be up as well.
    @Test("Over a plain hold that has an end of its own there is nothing to go back to")
    func overATimedPlainHold() {
        #expect(!KeepAwakeSession.returnsToHold(after: session(lid: false, deadline: start.addingTimeInterval(60))))
    }

    @Test("Changing the length of a timed hold keeps what it remembered")
    func carriedThroughALengthChange() {
        let later = start.addingTimeInterval(60)
        #expect(KeepAwakeSession.returnsToHold(after: session(lid: true, deadline: later, returns: true)))
        #expect(!KeepAwakeSession.returnsToHold(after: session(lid: true, deadline: later, returns: nil)))
        #expect(!KeepAwakeSession.returnsToHold(after: session(lid: true, deadline: later, returns: false)))
    }

    @Test("A session written before this reads as one that does not go back")
    func olderSessionDecodes() throws {
        let old = #"{"id":"A","startedAt":0,"deadline":60,"total":60,"bootID":"boot","lidHoldRequested":true}"#
        let decoded = try JSONDecoder().decode(KeepAwakeSession.self, from: Data(old.utf8))
        #expect(decoded.returnsToHold == nil)
        #expect(decoded.lidHoldRequested)
    }

    @Test("What it remembers survives being written down and read back")
    func roundTrip() throws {
        let original = session(lid: true, deadline: start.addingTimeInterval(60), returns: true)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(KeepAwakeSession.self, from: data) == original)
    }

    // MARK: What is said

    @Test("The notch says Back to Coffee once a timed hold has gone back")
    func notchSaysIt() {
        let returned = KeepAwakePayload(phase: .running, isIndefinite: true, returned: true)
        #expect(NotchAnnouncement.forKeepAwake(returned)?.title == "Back to Coffee")
        #expect(NotchAnnouncement.forKeepAwake(returned)?.subtitle == "Keep the lid open")
        let activity = Activity(id: ActivityID(kind: .keepAwake, source: "keepawake"),
                                createdAt: 0, payload: .keepAwake(returned))
        #expect(activity.isWorthAnnouncing)
    }

    @Test("A plain hold somebody started says nothing")
    func plainStartSaysNothing() {
        let started = KeepAwakePayload(phase: .running, isIndefinite: true)
        #expect(NotchAnnouncement.forKeepAwake(started) == nil)
        let activity = Activity(id: ActivityID(kind: .keepAwake, source: "keepawake"),
                                createdAt: 0, payload: .keepAwake(started))
        #expect(!activity.isWorthAnnouncing)
    }

    @Test("The line under the rail does not promise sleep when Coffee comes back")
    func cardLine() {
        #expect(KeepAwakeCopy.consequenceTimedThenAwake(until: "17:40") == "Ends at 17:40. Then back to Coffee.")
        #expect(KeepAwakeCopy.consequenceTimed(until: "17:40") == "Ends at 17:40. Then your Mac can sleep again.")
    }

    @Test("A payload written before this still reads")
    func olderPayloadDecodes() throws {
        let data = try JSONEncoder().encode(KeepAwakePayload(phase: .running))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["returned"] = nil
        object["returnsToHold"] = nil
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(KeepAwakePayload.self, from: stripped)
        #expect(decoded.returned == nil)
        #expect(decoded.returnsToHold == nil)
    }
}
