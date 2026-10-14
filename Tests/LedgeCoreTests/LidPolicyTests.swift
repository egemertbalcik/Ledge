import Foundation
import LedgeCore
import Testing

/// A closed lid means two opposite things, and everything else here follows
/// from telling them apart: put down with nobody looking, or sat on a desk in
/// clamshell with an external display and somebody working at it.
@Suite("What a closed lid means")
struct LidReadingTests {

    @Test("Shut with nothing else attached is put away")
    func shutAloneIsPutAway() {
        #expect(LidReading(state: .closed, builtInIsOnlyDisplay: true).isPutAway)
    }

    /// The Mac is on a desk, the user is looking at the other screen. Dimming
    /// and muting it would be an unpleasant surprise, and the built-in panel is
    /// already off anyway.
    @Test("Shut with an external display is somebody working")
    func clamshellWithExternalIsNotPutAway() {
        #expect(!LidReading(state: .closed, builtInIsOnlyDisplay: false).isPutAway)
    }

    @Test("An open lid is never put away, whatever is attached")
    func openIsNeverPutAway() {
        #expect(!LidReading(state: .open, builtInIsOnlyDisplay: true).isPutAway)
        #expect(!LidReading(state: .open, builtInIsOnlyDisplay: false).isPutAway)
    }

    /// A desktop has no lid, and a reading nobody could take is not evidence
    /// that nobody is there.
    @Test("A lid nobody can read is never treated as shut")
    func unknownIsNeverPutAway() {
        #expect(!LidReading(state: .unknown, builtInIsOnlyDisplay: true).isPutAway)
        #expect(!LidReading.unknown.isPutAway)
    }

    /// DisplayServices reports nothing for a panel in clamshell, and the value
    /// read as the lid comes down is not the user's: the lid covers the ambient
    /// light sensor, so auto-brightness has already pulled the panel down
    /// before the close is even reported.
    @Test("Brightness is only worth sampling while the lid is up")
    func onlySampleWhileOpen() {
        #expect(LidReading(state: .open, builtInIsOnlyDisplay: true).canSampleBrightness)
        #expect(!LidReading(state: .closed, builtInIsOnlyDisplay: true).canSampleBrightness)
        #expect(!LidReading(state: .unknown, builtInIsOnlyDisplay: true).canSampleBrightness)
    }
}

@Suite("What the lid should cause")
struct LidPolicyTests {

    private func action(_ state: LidState, external: Bool = false,
                        session: Bool, conserving: Bool) -> LidAction {
        LidPolicy.action(
            for: LidReading(state: state, builtInIsOnlyDisplay: !external),
            sessionRunning: session, conserving: conserving
        )
    }

    @Test("A session on a Mac that has just been shut starts conserving")
    func shuttingStartsIt() {
        #expect(action(.closed, session: true, conserving: false) == .conserve)
    }

    @Test("Opening the lid puts everything back, mid-session or not")
    func openingRestores() {
        #expect(action(.open, session: true, conserving: true) == .restore)
        #expect(action(.open, session: false, conserving: true) == .restore)
    }

    /// The session ending while the lid is still shut is the case a policy
    /// keyed only on the lid would miss: the Mac stays closed, so nothing
    /// changes, and the screen stays dark after the hold has gone.
    @Test("A session ending under a closed lid puts everything back")
    func sessionEndRestores() {
        #expect(action(.closed, session: false, conserving: true) == .restore)
    }

    /// An external display appearing means somebody has sat down at it.
    @Test("Plugging in a display mid-session puts everything back")
    func externalDisplayRestores() {
        #expect(action(.closed, external: true, session: true, conserving: true) == .restore)
    }

    @Test("A lid that stops being readable puts everything back")
    func unknownRestores() {
        #expect(action(.unknown, session: true, conserving: true) == .restore)
    }

    /// The reading that arrives on every wake, and after every registry
    /// notification that had nothing to do with the lid. Doing the work again
    /// each time would mean re-journalling a brightness that is already 0.
    @Test("Nothing happens when nothing has changed")
    func idempotent() {
        #expect(action(.closed, session: true, conserving: true) == .none)
        #expect(action(.open, session: true, conserving: false) == .none)
        #expect(action(.open, session: false, conserving: false) == .none)
    }

    /// A Mac that wakes for Power Nap with the lid still shut has a lit panel
    /// again, and nobody there to see it. The policy answers `conserve` for
    /// exactly that reading, so a wake that finds nothing in place puts it back.
    @Test("A wake under a shut lid with nothing in place conserves again")
    func wakeReapplies() {
        #expect(action(.closed, session: true, conserving: false) == .conserve)
    }

    /// Nothing is ever conserved without a session, however the Mac is sitting.
    @Test("No session, nothing to conserve")
    func noSessionNoConserving() {
        for state in LidState.allCases {
            for external in [true, false] {
                let answer = action(state, external: external, session: false, conserving: false)
                #expect(answer == .none, "\(state) external=\(external) acted without a session")
            }
        }
    }
}
