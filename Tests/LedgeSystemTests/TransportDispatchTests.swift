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
                #expect(confirmed == .refused, "a dropped command was reported as sent")
                #expect(confirmed.wasSent == false)
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
                #expect(commander.send(.next, to: Self.music) == .refused)
            }
            #expect(NowPlayingCommander.lastCommandAt == before)
        }
    }

    /// The two ways of not being confirmed used to share one `false`, and
    /// everything downstream read that single answer as "carry on": the card
    /// animated a press it had been refused, the source was told to expect a
    /// change nobody had asked for, and a handover was granted on the strength
    /// of a command that never left the app.
    @Test("A refusal and an unconfirmed send are not the same answer")
    func refusalIsNotUnconfirmed() {
        let sent = Dispatches()
        let commander = sent.commander(owner: Self.browser)
        Self.withFullQueue {
            let refused = commander.send(.playPause, to: Self.spotify)
            #expect(refused == .refused)
            #expect(refused.wasSent == false, "nothing was sent, and nothing may act as though it was")
        }
        let unconfirmed = commander.send(.playPause, to: Self.browser)
        #expect(unconfirmed == .unconfirmed)
        #expect(unconfirmed.wasSent, "a browser's press did go out — it just cannot be confirmed")
    }

    @Test("An unscriptable player still moves the stamp, because it does dispatch")
    func unsupportedPlayerStillDispatches() {
        let sent = Dispatches()
        let commander = sent.commander(owner: Self.browser)
        let before = NowPlayingCommander.lastCommandAt
        #expect(
            commander.send(.playPause, to: Self.browser) == .unconfirmed,
            "the MediaRemote fallback cannot confirm anything, and must say so"
        )
        #expect(sent.commands == [.playPause])
        #expect(
            NowPlayingCommander.lastCommandAt > before,
            "the fallback path dispatched but did not mark the reading stale"
        )
    }
}

/// When the freshness stamp moves.
///
/// It tells the now-playing source that its cached answer is about to be
/// wrong. Moved at *admission*, it said so while the player had not yet been
/// spoken to — eight commands may be waiting and a player that has stopped
/// answering holds each for up to five seconds — so the source re-read, got
/// the state from before the press, and cached that as fresh.
@Suite("When a transport command marks the reading stale", .serialized)
@MainActor
struct TransportDispatchTimingTests {

    private static let spotify = "com.spotify.client"

    @Test("A queued command stamps when it runs, not when it is admitted")
    func stampedAtDispatchNotAdmission() async {
        let gate = ScriptGate()
        let originalScript = NowPlayingCommander.runScript
        let originalQueue = NowPlayingCommander.commands
        NowPlayingCommander.runScript = { _ in await gate.wait() }
        NowPlayingCommander.commands = SerialCommandRunner(capacity: 8, now: { 0 })
        defer {
            NowPlayingCommander.runScript = originalScript
            NowPlayingCommander.commands = originalQueue
        }

        let commander = NowPlayingCommander()
        #expect(commander.send(.playPause, to: Self.spotify) == .queued)
        for _ in 0..<10_000 where !gate.isWaiting { await Task.yield() }
        #expect(gate.isWaiting, "the first command never reached the player")

        // A second press queues behind a player that is not answering.
        let whileWaiting = NowPlayingCommander.lastCommandAt
        #expect(commander.send(.next, to: Self.spotify) == .queued)
        #expect(
            NowPlayingCommander.lastCommandAt == whileWaiting,
            "being admitted to the queue moved the stamp, before anything was sent"
        )

        gate.open()
        await NowPlayingCommander.commands.drain()
        #expect(
            NowPlayingCommander.lastCommandAt > whileWaiting,
            "the stamp never moved, so the source was never told to re-read"
        )
    }
}

/// Holds a transport script open until the test lets it go.
private final class ScriptGate: @unchecked Sendable {

    private struct State {
        var open = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isWaiting: Bool { state.withLock { !$0.waiting.isEmpty } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let passThrough = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiting.append(continuation)
                return false
            }
            if passThrough { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiting = [] }
            return s.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// Records what actually went out globally, so the paths that must send
/// nothing can be held to it.
@MainActor
private final class Dispatches {

    private(set) var commands: [NowPlayingCommand] = []

    func commander(owner: String?) -> NowPlayingCommander {
        NowPlayingCommander(
            systemOwner: { owner },
            dispatchGlobally: { self.commands.append($0) }
        )
    }
}

/// Where an unaddressed command lands.
///
/// A player with no scripting dictionary can only be reached through
/// MediaRemote, and MediaRemote does not take an address: it acts on whichever
/// player the system currently considers now-playing. That is the player on the
/// card exactly when the system agrees with the card — and the card is
/// deliberately steadier than the system, holding a native player while a
/// browser tab takes the slot. Every press in that window went to the tab.
@Suite("Where an unaddressed transport command lands", .serialized)
@MainActor
struct GlobalTransportTargetingTests {

    private static let browser = "com.apple.Safari"
    private static let otherPlayer = "com.colliderli.iina"
    private static let spotify = "com.spotify.client"

    @Test("It goes out when the system is pointing at the player on the card")
    func dispatchesWhenTheOwnerMatches() {
        let sent = Dispatches()
        let commander = sent.commander(owner: Self.browser)
        #expect(commander.send(.playPause, to: Self.browser) == .unconfirmed)
        #expect(sent.commands == [.playPause])
    }

    @Test("It is refused when the system is pointing at somebody else")
    func refusesWhenTheOwnerDiffers() {
        // The card holds a player with no scripting dictionary while a browser
        // tab owns the system's slot. An unaddressed press here pauses the tab
        // and leaves the card's player running.
        let sent = Dispatches()
        let commander = sent.commander(owner: Self.browser)
        let answer = commander.send(.playPause, to: Self.otherPlayer)

        #expect(answer == .wrongPlayer)
        #expect(answer.wasSent == false)
        #expect(sent.commands.isEmpty, "a command was aimed at a player nobody asked for")
    }

    @Test("It is refused when nobody can say who owns the slot")
    func refusesWhenTheOwnerIsUnknown() {
        // No adapter, an adapter set aside, or a reading too old to stand
        // behind. A guess about who owns the slot is the one thing that must
        // not be acted on.
        let sent = Dispatches()
        let commander = sent.commander(owner: nil)
        #expect(commander.send(.next, to: Self.otherPlayer) == .wrongPlayer)
        #expect(sent.commands.isEmpty)
    }

    @Test("A refusal to aim leaves the reading stamp alone")
    func refusalDoesNotMarkReadingsStale() {
        // The stamp tells the source its cached answer is about to be wrong.
        // Nothing was sent, so nothing is about to be wrong.
        let sent = Dispatches()
        let commander = sent.commander(owner: Self.browser)
        let before = NowPlayingCommander.lastCommandAt
        _ = commander.send(.playPause, to: Self.otherPlayer)
        #expect(NowPlayingCommander.lastCommandAt == before)
    }

    @Test("A scriptable player is addressed directly and never consults the owner")
    func scriptablePlayersAreUnaffected() {
        // Spotify takes an addressed command, so who holds the system's slot
        // is beside the point — and must not be allowed to refuse it.
        let sent = Dispatches()
        let commander = sent.commander(owner: Self.browser)
        #expect(commander.send(.playPause, to: Self.spotify) == .queued)
        #expect(sent.commands.isEmpty, "an addressed command was sent globally as well")
    }
}
