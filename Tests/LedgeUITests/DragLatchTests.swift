import Foundation
import Testing

@testable import LedgeUI

/// Letting go of a drag latch is where the bugs are.
///
/// A gesture releases it in `onEnded`, and a view taken off screen mid-drag
/// never gets one — the media card is replaced on every track change, and a
/// route row goes away with its device. The latch left set keeps the notch
/// open and swallowing clicks. The obvious fix is worse than the fault: a
/// disappearing view saying "let go" releases whatever is latched, including a
/// drag that has just begun somewhere else.
@Suite("Who may let go of a drag latch")
@MainActor
struct DragLatchTests {

    /// Records what the latch asked the shell to do, so "nothing happened" is
    /// an assertion rather than an absence.
    private final class Shell {
        var calls: [Bool] = []
        var isLatched: Bool { calls.last ?? false }
    }

    @Test("Taking it latches, and giving it back releases")
    func beginAndEnd() {
        let shell = Shell()
        let latch = DragLatch()

        let token = latch.begin { shell.calls.append($0) }
        #expect(shell.calls == [true])
        #expect(latch.isHeld)

        latch.end(token) { shell.calls.append($0) }
        #expect(shell.calls == [true, false])
        #expect(!latch.isHeld)
    }

    @Test("A view that has been replaced cannot release the drag that replaced it")
    func staleHolderCannotRelease() {
        let shell = Shell()
        let latch = DragLatch()

        // The card is replaced mid-drag: the new view takes the latch, and the
        // old view's teardown arrives afterwards.
        let old = latch.begin { shell.calls.append($0) }
        let current = latch.begin { shell.calls.append($0) }
        latch.end(old) { shell.calls.append($0) }

        #expect(latch.isHeld, "an old view let go of a drag that was still in flight")
        #expect(shell.isLatched)

        latch.end(current) { shell.calls.append($0) }
        #expect(!latch.isHeld)
    }

    @Test("A second drag does not latch the shell twice")
    func takingOverDoesNotRelatch() {
        // The shell's latch is a flag, not a count. Setting it again is
        // harmless but it is also noise, and noise here resyncs the hover
        // tracker for no reason.
        let shell = Shell()
        let latch = DragLatch()
        _ = latch.begin { shell.calls.append($0) }
        _ = latch.begin { shell.calls.append($0) }
        #expect(shell.calls == [true])
    }

    @Test("Letting go twice releases once")
    func releasingTwiceIsHarmless() {
        let shell = Shell()
        let latch = DragLatch()
        let token = latch.begin { shell.calls.append($0) }
        latch.end(token) { shell.calls.append($0) }
        latch.end(token) { shell.calls.append($0) }
        #expect(shell.calls == [true, false])
    }

    @Test("A token from a latch that was never taken releases nothing")
    func unknownTokenReleasesNothing() {
        let shell = Shell()
        let latch = DragLatch()
        latch.end(0) { shell.calls.append($0) }
        latch.end(99) { shell.calls.append($0) }
        #expect(shell.calls.isEmpty)
        #expect(!latch.isHeld)
    }

    @Test("Tokens are never reused, so a stale one cannot come round again")
    func tokensAreNotReused() {
        let latch = DragLatch()
        var seen: Set<Int> = []
        for _ in 0..<100 {
            let token = latch.begin { _ in }
            #expect(seen.insert(token).inserted, "token \(token) was handed out twice")
            latch.end(token) { _ in }
        }
    }
}
