import Foundation
import LedgeCore
import Testing

@testable import LedgeShell

/// What replacing one press with another leaves behind.
///
/// Every case here was a defect at some point in one afternoon: a handoff
/// abandoned by an ordinary prompt, and then a guide torn down by the very
/// button that had just put it up.
@Suite("One press replacing another")
struct PermissionAttemptsTests {

    @Test("The first press of all changes nothing")
    func nothingToReplace() {
        let change = PermissionAttempts.replacing(
            nil, with: .accessibility, handingOff: true, guideShows: .accessibility
        )
        #expect(change == .nothing)
    }

    @Test("A handoff replaced by an ordinary prompt is retired in full")
    func handoffReplacedByAPrompt() {
        // Accessibility is out in System Settings; Calendar's Allow… is
        // pressed. Nothing will ever come back for the Accessibility press —
        // its ending is fenced by a token that is no longer current — so the
        // lock and the guide have to go here, or Stop Waiting has nothing
        // left to press.
        let change = PermissionAttempts.replacing(
            (kind: .accessibility, handedOff: true),
            with: .calendars,
            handingOff: false,
            guideShows: .accessibility
        )
        #expect(change.endWaitFor == .accessibility)
        #expect(change.clearsTheLock)
        #expect(change.endsTheGuide)
    }

    @Test("Another go at the same permission keeps the guide it just put up")
    func sameKindRetry() {
        // "Open System Settings Again" is a second attempt at the same
        // permission. The row's wait and the guide are the *new* press's by
        // the time the shell hears about it.
        let change = PermissionAttempts.replacing(
            (kind: .accessibility, handedOff: true),
            with: .accessibility,
            handingOff: true,
            guideShows: .accessibility
        )
        #expect(change.endWaitFor == nil)
        #expect(!change.endsTheGuide)
        // The lock is republished by the press itself, so retracting the old
        // one is harmless and keeps one publisher in charge of it.
        #expect(change.clearsTheLock)
    }

    @Test("A handoff replaced by a handoff for something else hands over cleanly")
    func handoffReplacedByAnotherHandoff() {
        let change = PermissionAttempts.replacing(
            (kind: .accessibility, handedOff: true),
            with: .bluetooth,
            handingOff: true,
            guideShows: .bluetooth
        )
        #expect(change.endWaitFor == .accessibility)
        #expect(change.clearsTheLock)
        // The guide is already the new press's; ending it would undo the
        // thing the button was pressed for.
        #expect(!change.endsTheGuide)
    }

    @Test("A prompt replaced by anything leaves no lock or guide to clear")
    func promptReplaced() {
        let change = PermissionAttempts.replacing(
            (kind: .location, handedOff: false),
            with: .calendars,
            handingOff: false,
            guideShows: nil
        )
        #expect(change.endWaitFor == .location)
        #expect(!change.clearsTheLock)
        #expect(!change.endsTheGuide)
    }

    @Test("A stale guide for a third permission is not kept by a same-kind retry")
    func guideForSomethingElse() {
        // The guide is showing Calendar while the press being replaced was
        // Accessibility and the new press is Accessibility again. Nothing
        // here owns that guide, so it goes.
        let change = PermissionAttempts.replacing(
            (kind: .accessibility, handedOff: true),
            with: .accessibility,
            handingOff: true,
            guideShows: .calendars
        )
        #expect(change.endsTheGuide)
    }
}
