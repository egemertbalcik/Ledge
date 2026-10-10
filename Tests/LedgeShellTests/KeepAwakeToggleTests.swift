import Foundation
import LedgeCore
import Testing

@testable import LedgeShell

/// Ends that can be held open, the way a disk holds one open.
///
/// Every call waits on its own continuation. Keeping one and overwriting it
/// stranded the first caller forever — the tests still passed, and the
/// runtime said "leaked its continuation without resuming it", which is a fair
/// description of a fixture that quietly drops half of what it is modelling.
@MainActor
private final class HeldEnd {
    private var waiting: [() -> Void] = []
    private(set) var started = 0
    private(set) var finished = 0

    /// Called in place of the coordinator's `endKeepAwake`.
    func run() async {
        started += 1
        await withCheckedContinuation { continuation in
            waiting.append { continuation.resume() }
        }
        finished += 1
    }

    var isWaiting: Bool { !waiting.isEmpty }
    var waitingCount: Int { waiting.count }

    /// Lets the oldest held end finish, in the order they arrived.
    func finish() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst()()
    }

    /// Lets every held end finish.
    func finishAll() {
        while !waiting.isEmpty { finish() }
    }
}

@Suite("The Keep Awake switch keeps the user's last answer")
@MainActor
struct KeepAwakeToggleTests {

    private func rig() -> (toggle: KeepAwakeToggle, end: HeldEnd, applied: Applied) {
        let end = HeldEnd()
        let applied = Applied()
        let toggle = KeepAwakeToggle(
            end: { await end.run() },
            apply: { applied.values.append($0) }
        )
        return (toggle, end, applied)
    }

    @MainActor
    private final class Applied {
        var values: [Bool] = []
    }

    private func settle() async {
        for _ in 0 ..< 8 { await Task.yield() }
    }

    @Test("Switching it on while an off is still ending settles on, not off")
    func onSupersedesAPendingOff() async {
        // Off has to end the session before the provider is removed, and
        // ending waits on the disk. That wait is long enough to change your
        // mind — and the Off was still the newest request while you did.
        let r = rig()
        r.toggle.set(false)
        await settle()
        #expect(r.end.isWaiting, "the off is waiting on the end")

        r.toggle.set(true)
        #expect(r.applied.values == [true], "on has nothing to wait for")

        r.end.finish()
        await settle()

        #expect(r.applied.values == [true], "the overtaken off must not apply itself")
    }

    @Test("An off that was overtaken does not end the session anyway")
    func overtakenOffDoesNotEnd() async {
        // Ending is the destructive half. Checking the number only before
        // removing the provider left the session ended underneath a switch
        // the user had already turned back on.
        let r = rig()
        r.toggle.set(false)
        r.toggle.set(true)
        await settle()

        #expect(r.end.started == 0, "the overtaken off must not end anything")
        #expect(r.applied.values == [true])
    }

    @Test("Switching it off after an on still switches it off")
    func offAfterOnStillApplies() async {
        let r = rig()
        r.toggle.set(true)
        r.toggle.set(false)
        await settle()

        r.end.finishAll()
        await settle()

        #expect(r.end.finished == r.end.started, "every end that started also finished")
        #expect(r.applied.values == [true, false])
    }

    @Test("Of two offs around an on, only the last one lands")
    func theLastAnswerIsTheOneThatCounts() async {
        let r = rig()
        r.toggle.set(false)
        await settle()
        r.toggle.set(true)
        r.toggle.set(false)
        await settle()

        #expect(r.end.waitingCount == 2, "both offs are waiting on an end of their own")
        r.end.finishAll()
        await settle()

        #expect(r.end.finished == 2, "and both of them are let go, not just one")
        #expect(r.applied.values == [true, false],
                "the first off is retired by the on; the second one is the answer")
    }

    @Test("An end is always awaited before the provider is removed")
    func offNeverRemovesBeforeEnding() async {
        // Removal reaches only `stop()`, which writes nothing — so removing
        // first leaves the journal saying a session is running.
        let r = rig()
        r.toggle.set(false)
        await settle()

        #expect(r.end.started == 1)
        #expect(r.applied.values.isEmpty, "nothing is removed while the end is in flight")

        r.end.finish()
        await settle()
        #expect(r.applied.values == [false])
    }
}
