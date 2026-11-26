import Foundation
import LedgeCore
import Testing

@testable import LedgeShell

/// Going back to Coffee keeps the card running under the same id, and a
/// running card republishes every second. It is news at the first reading
/// that carries it and at none after.
@Suite("Back to Coffee is announced once")
struct KeepAwakeReturnAnnouncedTests {

    @Test("The first reading that says it is news and the next ones are not")
    func once() {
        let returned = KeepAwakePayload(phase: .running, isIndefinite: true, returned: true)
        #expect(ActivityCoordinator.keepAwakeJustReturned(returned, sawItBefore: false))
        #expect(!ActivityCoordinator.keepAwakeJustReturned(returned, sawItBefore: true))
    }

    @Test("A hold that has not gone back, or is not running, is not this news")
    func otherwiseNot() {
        #expect(!ActivityCoordinator.keepAwakeJustReturned(
            KeepAwakePayload(phase: .running, isIndefinite: true), sawItBefore: false))
        #expect(!ActivityCoordinator.keepAwakeJustReturned(
            KeepAwakePayload(phase: .ready, returned: true), sawItBefore: false))
    }
}
