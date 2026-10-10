import Foundation
import LedgeSystem
import Testing

@testable import LedgeShell

@Suite("A transport press only counts when it leaves the app")
@MainActor
struct MediaPressTests {

    @MainActor
    private final class Spy {
        var sent: [NowPlayingCommand] = []
        var expected = 0
        var answer: NowPlayingDispatch = .queued

        func press() -> MediaPress {
            MediaPress(
                send: { command in
                    self.sent.append(command)
                    return self.answer
                },
                expectChange: { self.expected += 1 }
            )
        }
    }

    @Test("A queued press asks the provider to look again")
    func queuedPressExpectsAChange() {
        let spy = Spy()
        spy.answer = .queued
        let moved = spy.press()(.playPause)

        #expect(moved, "the card may show what was asked for")
        #expect(spy.sent == [.playPause])
        #expect(spy.expected == 1)
    }

    @Test("An unconfirmed press still counts — something did leave the app")
    func unconfirmedPressCounts() {
        // Nothing comes back from MediaRemote to say it landed, but the
        // command was sent, so a change is a fair thing to wait for.
        let spy = Spy()
        spy.answer = .unconfirmed
        let moved = spy.press()(.next)

        #expect(moved)
        #expect(spy.expected == 1)
    }

    @Test("A refused press changes nothing at all")
    func refusedPressExpectsNothing() {
        // The player's queue was full, so it was never asked. Granting the
        // handover here left the card waiting for a track nobody had
        // requested, which is how Next comes to look unreliable.
        let spy = Spy()
        spy.answer = .refused
        let moved = spy.press()(.next)

        #expect(!moved, "and the card must not show what was asked for")
        #expect(spy.expected == 0, "nothing was asked, so nothing is expected")
    }
}
