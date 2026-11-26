import Foundation
import LedgeCore
import Testing

/// What waits behind a peek is looked up again when its turn comes. Two
/// entries for one card can only replay that card. A sound output card
/// waiting behind a peek is the echo of a hello that has since been said.
@Suite("Cards waiting behind a peek")
struct PendingPeekSlotTests {

    private let route = ActivityID(kind: .device, source: "audioroute")
    private let buds = ActivityID(kind: .device, source: "80:AF:19:40:F9:B6")

    private func entry(_ id: ActivityID, _ name: String, at time: TimeInterval) -> PendingPeek {
        PendingPeek(
            Activity(id: id, createdAt: time, expiresAfter: 4, payload: .device(DevicePayload(name: name))),
            at: time, byUser: false)
    }

    /// Two sound output changes made behind one peek said the latest output
    /// twice: both entries fetched the same live card.
    @Test("The same card queued twice holds one slot, with the newer entry in it")
    func sameCardSharesASlot() {
        var queue: [PendingPeek] = []
        PendingPeek.enqueue(entry(route, "Speakers", at: 1), into: &queue, limit: 3)
        PendingPeek.enqueue(entry(buds, "AirPods", at: 2), into: &queue, limit: 3)
        PendingPeek.enqueue(entry(route, "Display", at: 3), into: &queue, limit: 3)
        #expect(queue.map(\.id) == [route, buds], "it keeps its place in the line")
        #expect(queue.first?.at == 3)
    }

    @Test("Different cards still each get a slot, up to the limit")
    func differentCardsQueue() {
        var queue: [PendingPeek] = []
        for index in 0..<5 {
            let id = ActivityID(kind: .device, source: "device-\(index)")
            PendingPeek.enqueue(entry(id, "Device", at: TimeInterval(index)), into: &queue, limit: 3)
        }
        #expect(queue.count == 3)
    }

    /// A slot already held is not a new entry, so a full queue still takes it.
    @Test("A full queue still lets a waiting card take its newer entry")
    func fullQueueStillReplaces() {
        var queue: [PendingPeek] = []
        PendingPeek.enqueue(entry(route, "Speakers", at: 1), into: &queue, limit: 1)
        PendingPeek.enqueue(entry(route, "Display", at: 2), into: &queue, limit: 1)
        #expect(queue.count == 1)
        #expect(queue.first?.at == 2)
    }

    @Test("Dropping takes out only the named card and only where asked")
    func dropTakesTheEcho() {
        var queue: [PendingPeek] = []
        PendingPeek.enqueue(entry(route, "AirPods", at: 1), into: &queue, limit: 3)
        PendingPeek.enqueue(entry(buds, "AirPods", at: 2), into: &queue, limit: 3)

        PendingPeek.drop(route, from: &queue) { _ in false }
        #expect(queue.map(\.id) == [route, buds], "the rule said no")

        PendingPeek.drop(route, from: &queue) { _ in true }
        #expect(queue.map(\.id) == [buds], "the route went and the other card stayed")
    }

    /// A low battery alert has an id for each device, so it is picked out by
    /// what it is and not by one id.
    @Test("Dropping by what a card is takes out every match and nothing else")
    func dropByRule() {
        let leftLow = ActivityID(kind: .device, source: "80:AF:19:40:F9:B6/low")
        var queue: [PendingPeek] = []
        PendingPeek.enqueue(entry(route, "AirPods", at: 1), into: &queue, limit: 3)
        PendingPeek.enqueue(entry(leftLow, "AirPods", at: 2), into: &queue, limit: 3)
        PendingPeek.enqueue(entry(buds, "AirPods", at: 3), into: &queue, limit: 3)

        PendingPeek.drop(from: &queue) { _ in false }
        #expect(queue.count == 3, "the rule said no")

        PendingPeek.drop(from: &queue) { $0.id == leftLow }
        #expect(queue.map(\.id) == [route, buds])
    }

    /// A low battery alert was waiting when its device's hello joined the
    /// line. The hello draws that battery in red, so it goes first.
    @Test("A card is let ahead of the waiting entries that yield to it and no others")
    func letAhead() {
        let leftLow = ActivityID(kind: .device, source: "80:AF:19:40:F9:B6/low")
        let rightLow = ActivityID(kind: .device, source: "80:AF:19:40:F9:B6/low2")
        let tail = ActivityID(kind: .device, source: "tail")
        var queue: [PendingPeek] = []
        for (index, id) in [leftLow, route, rightLow, buds, tail].enumerated() {
            PendingPeek.enqueue(entry(id, "AirPods", at: TimeInterval(index)), into: &queue, limit: 5)
        }

        PendingPeek.letAhead(buds, in: &queue) { $0.id == leftLow || $0.id == rightLow || $0.id == tail }
        #expect(queue.map(\.id) == [route, buds, leftLow, rightLow, tail],
                "the two in front step behind it in their order and what was behind stays put")
    }

    @Test("Nothing moves when nothing yields or the card is not waiting")
    func letAheadLeavesTheRest() {
        var queue: [PendingPeek] = []
        PendingPeek.enqueue(entry(route, "AirPods", at: 1), into: &queue, limit: 3)
        PendingPeek.enqueue(entry(buds, "AirPods", at: 2), into: &queue, limit: 3)

        PendingPeek.letAhead(buds, in: &queue) { _ in false }
        #expect(queue.map(\.id) == [route, buds])

        let absent = ActivityID(kind: .device, source: "absent")
        PendingPeek.letAhead(absent, in: &queue) { _ in true }
        #expect(queue.map(\.id) == [route, buds])
    }
}
