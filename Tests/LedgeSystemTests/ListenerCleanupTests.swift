import CoreAudio
import Foundation
import Testing
import os

@testable import LedgeSystem

/// Cleanup has to finish whether or not anyone is still holding the listener.
///
/// This is the failure the second review reproduced in an isolated fixture: a
/// removal that failed once was retried only if something still held the
/// wrapper. Dropped from an array — the ordinary case — the retry captured a
/// dead object, gave up, and left the registration installed. One attempt, one
/// live registration.
@Suite("Listener cleanup", .serialized)
struct ListenerCleanupTests {

    /// Stands in for the HAL: fails the first `failures` removals, then works.
    private final class FakeRemover: @unchecked Sendable {
        private let state: OSAllocatedUnfairLock<(failures: Int, attempts: Int, removed: Bool, abandoned: Bool)>

        init(failures: Int) {
            state = OSAllocatedUnfairLock(initialState: (failures, 0, false, false))
        }

        var attempts: Int { state.withLock { $0.attempts } }
        var removed: Bool { state.withLock { $0.removed } }
        var abandoned: Bool { state.withLock { $0.abandoned } }

        var remove: @Sendable (ListenerToken, ListenerTree) -> OSStatus {
            { [self] _, _ in
                state.withLock { s in
                    s.attempts += 1
                    if s.failures > 0 {
                        s.failures -= 1
                        return OSStatus(kAudioHardwareUnspecifiedError)
                    }
                    s.removed = true
                    return noErr
                }
            }
        }

        var abandon: @Sendable (ListenerToken, ListenerTree) -> Void {
            { [self] _, _ in state.withLock { $0.abandoned = true } }
        }
    }

    /// A pointer that is never dereferenced: every path through the cleanup is
    /// substituted, so the token is only ever an identity.
    private static func dummyToken() -> ListenerToken {
        ListenerToken(raw: OpaquePointer(bitPattern: 0xDEAD_BEEF)!)
    }

    /// Near-zero, so the whole retry budget costs milliseconds rather than
    /// seconds. A suite that sleeps for real seconds destabilises every
    /// clock-sensitive test running alongside it.
    private static let quickBackoff: @Sendable (Int) -> TimeInterval = { _ in 0.005 }

    private static func settle(_ queue: DispatchQueue) {
        for _ in 0..<12 {
            queue.sync {}
            Thread.sleep(forTimeInterval: 0.01)
        }
        queue.sync {}
    }

    @Test("A removal that fails once is retried until it succeeds")
    func retriesUntilSuccess() {
        let queue = DispatchQueue(label: "test.cleanup.retry")
        let remover = FakeRemover(failures: 1)
        ListenerCleanup(
            token: Self.dummyToken(), tree: .audio, queue: queue, describe: "test",
            remove: remover.remove, abandon: remover.abandon, backoff: Self.quickBackoff
        ).begin()

        Self.settle(queue)
        #expect(remover.attempts == 2, "attempts was \(remover.attempts), expected a retry")
        #expect(remover.removed, "the registration was never removed")
    }

    @Test("Cleanup finishes even with nothing holding it")
    func survivesItsOwnerBeingReleased() {
        let queue = DispatchQueue(label: "test.cleanup.unowned")
        let remover = FakeRemover(failures: 1)

        // Started and immediately forgotten, which is what happens when a
        // listener is dropped from an array.
        do {
            let cleanup = ListenerCleanup(
                token: Self.dummyToken(), tree: .audio, queue: queue, describe: "test",
                remove: remover.remove, abandon: remover.abandon, backoff: Self.quickBackoff
            )
            cleanup.begin()
        }

        Self.settle(queue)
        #expect(remover.attempts == 2, "cleanup gave up when its owner went away")
        #expect(remover.removed, "the registration was left installed")
    }

    @Test("A vanished object is abandoned rather than retried")
    func vanishedObjectIsNotRetried() {
        let queue = DispatchQueue(label: "test.cleanup.vanished")
        final class Gone: @unchecked Sendable {
            let state = OSAllocatedUnfairLock(initialState: (attempts: 0, abandoned: false))
        }
        let gone = Gone()
        ListenerCleanup(
            token: Self.dummyToken(), tree: .audio, queue: queue, describe: "test",
            remove: { _, _ in
                gone.state.withLock { $0.attempts += 1 }
                return kAudioHardwareBadObjectError
            },
            abandon: { _, _ in gone.state.withLock { $0.abandoned = true } },
            backoff: Self.quickBackoff
        ).begin()

        Self.settle(queue)
        let (attempts, abandoned) = gone.state.withLock { ($0.attempts, $0.abandoned) }
        #expect(attempts == 1, "a vanished object was retried \(attempts) times")
        #expect(abandoned, "its storage was never reclaimed")
    }

    @Test("Removal that never succeeds stops after its budget and is quarantined")
    func terminalFailureIsBounded() {
        ListenerQuarantine.shared.resetForTesting()
        let queue = DispatchQueue(label: "test.cleanup.terminal")
        let remover = FakeRemover(failures: .max)
        ListenerCleanup(
            token: Self.dummyToken(), tree: .audio, queue: queue, describe: "test",
            remove: remover.remove, abandon: remover.abandon, backoff: Self.quickBackoff
        ).begin()

        Self.settle(queue)
        #expect(
            remover.attempts == ListenerCleanup.maximumAttempts,
            "attempts was \(remover.attempts), expected exactly the budget"
        )
        #expect(!remover.removed)
        #expect(ListenerQuarantine.shared.count == 1, "the stuck registration was not quarantined")
        ListenerQuarantine.shared.resetForTesting()
    }

    @Test("A filling quarantine stops the watchers making replacements")
    func quarantineGatesReplacements() {
        ListenerQuarantine.shared.resetForTesting()
        #expect(ListenerQuarantine.shared.acceptsReplacements)

        let queue = DispatchQueue(label: "test.cleanup.budget")
        for _ in 0..<ListenerQuarantine.replacementBudget {
            let remover = FakeRemover(failures: .max)
            ListenerCleanup(
                token: Self.dummyToken(), tree: .audio, queue: queue, describe: "test",
                remove: remover.remove, abandon: remover.abandon, backoff: Self.quickBackoff
            ).begin()
            Self.settle(queue)
        }

        #expect(
            !ListenerQuarantine.shared.acceptsReplacements,
            "replacements are still allowed with \(ListenerQuarantine.shared.count) stuck registrations"
        )
        ListenerQuarantine.shared.resetForTesting()
        #expect(ListenerQuarantine.shared.acceptsReplacements)
    }
}
