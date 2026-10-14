import Foundation
import LedgeHelperKit
import Testing

@testable import LedgeSystem

/// The one property worth proving about the XPC bridge.
///
/// A connection to the root daemon can answer twice — the reply block and the
/// error handler both fire when a connection drops around the moment an answer
/// arrives — and a continuation resumed twice traps the process. It is the app
/// that dies, not the daemon, which makes it the most damaging thing in the
/// file and the least visible: it needs a daemon going away at exactly the
/// wrong moment, which is not something a user could report usefully.
@Suite("First answer only")
struct FirstAnswerOnlyTests {

    @Test("The first answer is delivered")
    func firstGetsThrough() {
        let delivered = Mailbox()
        let gate = FirstAnswerOnly<Int>(onFirst: { delivered.record($0) })
        gate.deliver(.success(7))
        #expect(delivered.values == [7])
    }

    @Test("A second answer is dropped")
    func secondIsDropped() {
        let delivered = Mailbox()
        let gate = FirstAnswerOnly<Int>(onFirst: { delivered.record($0) })
        gate.deliver(.success(1))
        gate.deliver(.success(2))
        gate.deliver(.failure(KeepAwakeXPCUnavailable()))
        #expect(delivered.values == [1], "more than one answer reached the continuation")
    }

    /// The reply and the error handler are the two real callers, and they
    /// arrive in whichever order the connection happens to drop in.
    @Test("An error after a reply is dropped, and a reply after an error")
    func eitherOrderIsSafe() {
        let afterReply = Mailbox()
        let one = FirstAnswerOnly<Int>(onFirst: { afterReply.record($0) })
        one.deliver(.success(5))
        one.deliver(.failure(KeepAwakeXPCUnavailable()))
        #expect(afterReply.values == [5])
        #expect(afterReply.failures == 0)

        let afterError = Mailbox()
        let two = FirstAnswerOnly<Int>(onFirst: { afterError.record($0) })
        two.deliver(.failure(KeepAwakeXPCUnavailable()))
        two.deliver(.success(5))
        #expect(afterError.values.isEmpty)
        #expect(afterError.failures == 1)
    }

    /// XPC makes no promise about which thread either answer arrives on, so
    /// the guard has to hold under genuine contention rather than merely in
    /// program order.
    @Test("Exactly one answer gets through when many arrive at once")
    func onlyOneUnderContention() {
        for _ in 0..<200 {
            let delivered = Mailbox()
            let gate = FirstAnswerOnly<Int>(onFirst: { delivered.record($0) })
            let start = DispatchSemaphore(value: 0)
            let done = DispatchGroup()
            for value in 0..<8 {
                DispatchQueue.global().async(group: done) {
                    start.wait()
                    gate.deliver(.success(value))
                }
            }
            for _ in 0..<8 { start.signal() }
            done.wait()
            #expect(delivered.count == 1, "\(delivered.count) answers reached the continuation")
        }
    }
}

/// The wire carries a bare `Int` so a daemon newer than the app can answer
/// something the app has never heard of without the call failing to decode.
/// What the app then *does* with that number is the whole of the decision.
@Suite("An answer the app does not know")
struct UnknownHelperCodeTests {

    @Test("Every code the app knows survives the trip")
    func knownCodesRoundTrip() {
        for code in KeepAwakeHelperCode.allCases {
            #expect(KeepAwakeXPCLink.code(code.rawValue) == code)
        }
    }

    /// Guessing `ok` would have the app believe a hold stands on the strength
    /// of a number it could not read. A refusal ends with the Mac allowed to
    /// sleep, which is the direction to be wrong in.
    @Test("A code from a newer daemon is treated as a refusal, never as success")
    func unknownIsNeverOk() {
        for raw in [-1, 9, 42, Int.max] {
            let read = KeepAwakeXPCLink.code(raw)
            #expect(read != .ok, "an unreadable answer \(raw) was taken as success")
        }
    }
}

/// Records what came through, from any thread.
private final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var succeeded: [Int] = []
    private var failed = 0

    func record(_ result: Result<Int, Error>) {
        lock.withLock {
            switch result {
            case .success(let value): succeeded.append(value)
            case .failure: failed += 1
            }
        }
    }

    var values: [Int] { lock.withLock { succeeded } }
    var failures: Int { lock.withLock { failed } }
    var count: Int { lock.withLock { succeeded.count + failed } }
}

/// A daemon that stays connected and stops answering is the worst shape of
/// trouble: every call parks in a continuation only the daemon can resume,
/// the caller gives up at its timeout, and the next heartbeat adds another.
/// Nothing releases them. The only lever is tearing the connection down,
/// because an abandoned XPC call cannot be cancelled.
/// A daemon that stays connected and stops answering is the worst shape of
/// trouble: every call parks in a continuation only the daemon can resume,
/// the caller gives up at its timeout, and the next heartbeat adds another.
/// Nothing releases them. The only lever is tearing the connection down,
/// because an abandoned XPC call cannot be cancelled.
///
/// The counting is what decides when to pull that lever, so these test the
/// counting rather than the constant. A test that only reads the limit back
/// passes just as happily when the limit controls nothing.
@Suite("Calls left in the air")
struct OutstandingCallsTests {

    @Test("There is a stated limit, and it is small enough to matter")
    func thereIsALimit() {
        #expect(KeepAwakeXPCLink.outstandingLimit > 0)
        // Small enough that a wedged daemon is noticed within a few minutes
        // of 30-second heartbeats rather than after an afternoon of them.
        #expect(KeepAwakeXPCLink.outstandingLimit <= 16,
                "a limit this high is not a bound on anything a user would live through")
    }

    @Test("A link with nothing in flight says so")
    func startsEmpty() {
        let link = KeepAwakeXPCLink(serviceName: "test.invalid.keepawake",
                                    requirement: "anchor apple generic")
        #expect(link.callsInFlight == 0)
    }

    /// The bug: the count was kept beside the exactly-once gate rather than
    /// inside it. A reply decremented, and a later duplicate error for the
    /// same request decremented again — so a call that was still parked
    /// vanished from the count, and the limit could no longer tell that the
    /// connection was wedged.
    @Test("A duplicate answer is counted once, however it arrives")
    func duplicateCountsOnce() {
        for arrivals in [[true, false], [false, true], [true, true], [false, false]] {
            let counted = DeliveryCount()
            let gate = FirstAnswerOnly<Int>(onFirst: { _ in counted.bump() })
            for success in arrivals {
                gate.deliver(success ? .success(1) : .failure(KeepAwakeXPCUnavailable()))
            }
            #expect(counted.value == 1,
                    "\(arrivals) was counted \(counted.value) times")
        }
    }

    /// Under contention too: the gate is what serialises this, and the
    /// accounting now rides inside it.
    @Test("Many answers at once are still counted once")
    func duplicateUnderContention() {
        for _ in 0..<200 {
            let counted = DeliveryCount()
            let gate = FirstAnswerOnly<Int>(onFirst: { _ in counted.bump() })
            let start = DispatchSemaphore(value: 0)
            let done = DispatchGroup()
            for value in 0..<6 {
                DispatchQueue.global().async(group: done) {
                    start.wait()
                    gate.deliver(value % 2 == 0
                                 ? .success(value)
                                 : .failure(KeepAwakeXPCUnavailable()))
                }
            }
            for _ in 0..<6 { start.signal() }
            done.wait()
            #expect(counted.value == 1, "counted \(counted.value) times")
        }
    }
}

/// Counts from any thread.
private final class DeliveryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func bump() { lock.withLock { stored += 1 } }
    var value: Int { lock.withLock { stored } }
}

/// The accounting as the link actually does it.
///
/// The suite above exercises `FirstAnswerOnly` on its own, and that is not
/// enough: the bug was never in the gate, it was in where the link put the
/// counting relative to it. Moving the decrement back outside left every one
/// of those tests passing. So these drive the real `once`.
@Suite("Counting a call the way the link does", .serialized)
struct LinkAccountingTests {

    private func link() -> KeepAwakeXPCLink {
        KeepAwakeXPCLink(serviceName: "test.invalid.keepawake",
                         requirement: "anchor apple generic")
    }

    @Test("One call answered once leaves nothing in flight")
    func oneCallOneAnswer() async throws {
        let link = link()
        let value: Int = try await link.once { deliver in deliver(.success(7)) }
        #expect(value == 7)
        #expect(link.callsInFlight == 0)
    }

    /// The bug, at the place it actually lived. A reply decremented, and a
    /// later duplicate error for the same request decremented again — so a
    /// call still parked vanished from the count, and the limit could no
    /// longer tell the connection was wedged.
    @Test("A duplicate answer does not discount another call still in flight")
    func duplicateDoesNotStealFromAnother() async throws {
        let link = link()

        // One call that nobody will ever answer.
        let parked = Parked()
        Task {
            try? await link.once { (deliver: @escaping @Sendable (Result<Int, Error>) -> Void) in
                parked.hold(deliver)
            }
        }
        for _ in 0 ..< 400 where link.callsInFlight < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(link.callsInFlight == 1, "the parked call was never admitted")

        // A second call that answers twice, as a dropped connection does.
        let answered = Answering()
        _ = try await link.once { (deliver: @escaping @Sendable (Result<Int, Error>) -> Void) in
            answered.hold(deliver)
            deliver(.success(1))
        }
        answered.deliverAgain()

        #expect(link.callsInFlight == 1,
                "a duplicate answer discounted a call that is still parked")
        parked.release()
    }
}

/// A call nobody answers.
private final class Parked: @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable (Result<Int, Error>) -> Void)?
    func hold(_ block: @escaping @Sendable (Result<Int, Error>) -> Void) {
        lock.withLock { deliver = block }
    }
    func release() {
        let block = lock.withLock { deliver }
        block?(.failure(KeepAwakeXPCUnavailable()))
    }
}

/// A call that answers more than once, the way a connection dropping around
/// an arriving reply does.
private final class Answering: @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable (Result<Int, Error>) -> Void)?
    func hold(_ block: @escaping @Sendable (Result<Int, Error>) -> Void) {
        lock.withLock { deliver = block }
    }
    func deliverAgain() {
        let block = lock.withLock { deliver }
        block?(.failure(KeepAwakeXPCUnavailable()))
    }
}
