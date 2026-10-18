import LedgeCore
import Testing

@testable import LedgeShell

/// Who may stand the notch up while a Focus is on.
///
/// Codex's finding: switching coffee on during Focus showed nothing at all.
/// Quiet During Focus is on by default and Keep Awake is not on the short list
/// of what may peek through it, so the confirmation of the user's own press
/// was filed with the interruptions and dropped.
@Suite("Focus quiets interruptions, not answers")
@MainActor
struct FocusAdmissionTests {

    private func admits(_ kind: ActivityKind, byUser: Bool, greeting: Bool = false,
                        quiet: Bool = true, focus: Bool = true) -> Bool {
        LedgeCoordinator.admitsPeek(kind: kind, byUser: byUser, greeting: greeting,
                                    quietDuringFocus: quiet, focusActive: focus)
    }

    @Test("Switching coffee on is confirmed during Focus")
    func theUsersOwnStartShows() {
        #expect(admits(.keepAwake, byUser: true))
    }

    @Test("A Keep Awake card nobody just asked for stays quiet during Focus")
    func anAmbientKeepAwakeStaysQuiet() {
        #expect(!admits(.keepAwake, byUser: false))
    }

    @Test("Other arrivals are still held back during Focus")
    func ambientArrivalsStayQuiet() {
        #expect(!admits(.nowPlaying, byUser: false))
        #expect(!admits(.device, byUser: false))
    }

    @Test("Without Focus, or with the setting off, everything may peek")
    func noFocusNoFilter() {
        #expect(admits(.keepAwake, byUser: false, focus: false))
        #expect(admits(.keepAwake, byUser: false, quiet: false))
    }

    @Test("Nothing interrupts the hello, not even an answer")
    func theGreetingHoldsForEveryone() {
        #expect(!admits(.keepAwake, byUser: true, greeting: true, focus: false))
    }
}
