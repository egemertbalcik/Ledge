import Foundation
import LedgeCore
import Testing
import os

@testable import LedgeSystem

/// Where a transport command goes when the scripting queue is full.
///
/// `send` used to read every falsy answer from the scripting path as "this
/// player cannot be scripted" and fall back to MediaRemote. Once the queue
/// gained a bound, a saturated queue started producing that same answer — so
/// mashing pause on a Spotify card until its queue filled would begin sending
/// commands through MediaRemote, which acts on whatever the system considers
/// now-playing. That is a browser tab, or another app entirely: the exact
/// failure the targeted scripting path exists to prevent.
@Suite("Transport dispatch", .serialized)
@MainActor
struct TransportDispatchTests {

    private static let spotify = "com.spotify.client"
    private static let music = "com.apple.Music"
    private static let browser = "com.apple.Safari"

    /// Swaps in a runner that refuses everything, which is exactly what a
    /// player whose queue has filled looks like from here — and unlike holding
    /// real work open, it cannot drift as a consumer drains behind the test.
    private static func withFullQueue(_ body: () -> Void) {
        let original = NowPlayingCommander.commands
        NowPlayingCommander.commands = SerialCommandRunner(capacity: 0)
        defer { NowPlayingCommander.commands = original }
        body()
    }

    @Test("A saturated queue reports busy, not unsupported")
    func saturatedQueueReportsBusy() {
        let commander = NowPlayingCommander()
        Self.withFullQueue {
            #expect(
                commander.sendViaScripting(.playPause, to: Self.spotify)
                    == NowPlayingCommander.ScriptingDispatch.busy,
                "a full queue must not be reported as an unscriptable player"
            )
            #expect(
                commander.sendViaScripting(.next, to: Self.music)
                    == NowPlayingCommander.ScriptingDispatch.busy
            )
        }
    }

    @Test("A player with no scripting dictionary is unsupported, whatever the queue")
    func browserIsUnsupported() {
        let commander = NowPlayingCommander()
        #expect(
            commander.sendViaScripting(.playPause, to: Self.browser)
                == NowPlayingCommander.ScriptingDispatch.unsupported
        )
        Self.withFullQueue {
            #expect(
                commander.sendViaScripting(.playPause, to: Self.browser)
                    == NowPlayingCommander.ScriptingDispatch.unsupported,
                "a full queue changed the answer for a player that was never scriptable"
            )
        }
    }

    /// `lastCommandAt` moves only when something was actually dispatched, and on
    /// the unsupported path it moves in the same breath as the MediaRemote
    /// fallback. So an unmoved stamp is proof the fallback was not taken.
    @Test("A saturated Spotify queue never reaches MediaRemote")
    func saturatedQueueNeverFallsBack() {
        let commander = NowPlayingCommander()
        Self.withFullQueue {
            let before = NowPlayingCommander.lastCommandAt
            for _ in 0..<20 {
                let confirmed = commander.send(.playPause, to: Self.spotify)
                #expect(confirmed == false, "a dropped command was reported as sent")
            }
            #expect(
                NowPlayingCommander.lastCommandAt == before,
                """
                something was dispatched for a command that was never queued — \
                the MediaRemote fallback was taken, and it can control a different player
                """
            )
        }
    }

    @Test("A saturated Music queue never reaches MediaRemote either")
    func saturatedMusicQueueNeverFallsBack() {
        let commander = NowPlayingCommander()
        Self.withFullQueue {
            let before = NowPlayingCommander.lastCommandAt
            for _ in 0..<20 {
                #expect(commander.send(.next, to: Self.music) == false)
            }
            #expect(NowPlayingCommander.lastCommandAt == before)
        }
    }

    @Test("An unscriptable player still moves the stamp, because it does dispatch")
    func unsupportedPlayerStillDispatches() {
        let commander = NowPlayingCommander()
        let before = NowPlayingCommander.lastCommandAt
        _ = commander.send(.playPause, to: Self.browser)
        #expect(
            NowPlayingCommander.lastCommandAt > before,
            "the fallback path dispatched but did not mark the reading stale"
        )
    }
}
