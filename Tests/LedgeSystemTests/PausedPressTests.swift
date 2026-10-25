import Foundation
import Testing

@testable import LedgeSystem

/// Play on a paused card that can only be reached through MediaRemote.
///
/// Found by review: a paused card is read every fifteen seconds when the
/// adapter pushes its changes, but the system owner was only trusted for ten.
/// A press in the last five seconds of each beat was refused as aimed at the
/// wrong player, and pressing again inside the same window failed too.
@Suite("Pressing play on a paused card")
@MainActor
struct PausedPressTests {

    /// An adapter: answers reads, says what it holds without one, and says
    /// when that changed.
    private final class Adapter: NowPlayingSource, SystemOwnerReporting, NowPlayingChangePublishing {
        let identifier = "adapter"
        var isAvailable = true
        var onChange: (() -> Void)?
        var value: NowPlayingSnapshot?
        private(set) var reads = 0
        init(_ value: NowPlayingSnapshot?) { self.value = value }
        func snapshot() async -> NowPlayingSnapshot? {
            reads += 1
            return value
        }
        var heldSystemOwner: String? { isAvailable ? value?.appBundleID : nil }
    }

    /// Pushes its changes, but cannot say what it holds.
    private final class Publishing: NowPlayingSource, NowPlayingChangePublishing {
        let identifier = "adapter"
        var isAvailable = true
        var value: NowPlayingSnapshot?
        var onChange: (() -> Void)?
        init(_ value: NowPlayingSnapshot?) { self.value = value }
        func snapshot() async -> NowPlayingSnapshot? { value }
    }

    /// A source that can only be read — the shape every source had before.
    private final class ReadOnly: NowPlayingSource {
        let identifier: String
        var isAvailable = true
        var value: NowPlayingSnapshot?
        init(_ identifier: String, _ value: NowPlayingSnapshot? = nil) {
            self.identifier = identifier
            self.value = value
        }
        func snapshot() async -> NowPlayingSnapshot? { value }
    }

    private final class Clock { var now: TimeInterval = 50_000 }

    private static let vlc = "org.videolan.vlc"
    private static let safari = "com.apple.Safari"

    private static func paused(_ bundleID: String, _ title: String) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title, artist: "", isPlaying: false, elapsed: 600, duration: 5400,
            appName: bundleID, appBundleID: bundleID
        )
    }

    private func make(_ adapter: any NowPlayingSource, clock: Clock) -> CompositeNowPlayingSource {
        CompositeNowPlayingSource(
            adapter: adapter, scripting: ReadOnly("scripting"),
            scriptedSnapshot: { _ in nil }, scriptingHandles: { _ in false },
            now: { clock.now }, lastTransportAt: { 0 }
        )
    }

    /// Inside the provider's fifteen-second paused beat, past the owner's
    /// freshness: the window in which presses were refused.
    private static var pastFreshness: TimeInterval {
        CompositeNowPlayingSource.systemOwnerFreshness + 1
    }

    @Test("A press after the owner reading has aged still reaches the player on the card")
    func agedReadingIsAskedAgain() async throws {
        let clock = Clock()
        let adapter = Adapter(Self.paused(Self.vlc, "Film"))
        let composite = make(adapter, clock: clock)
        _ = await composite.snapshot()
        let readsAfterPoll = adapter.reads
        try #require(readsAfterPoll >= 1)

        var sent: [NowPlayingCommand] = []
        let commander = NowPlayingCommander(
            systemOwner: { composite.systemOwnerBundleID },
            dispatchGlobally: { sent.append($0) },
            automationAllows: { _ in false }
        )
        // Reached the condition this is about: the poll's reading is now
        // older than the owner is trusted for, and nothing has read since.
        clock.now += Self.pastFreshness

        #expect(commander.send(.playPause, to: Self.vlc) == .unconfirmed)
        #expect(sent == [.playPause])
        #expect(adapter.reads == readsAfterPoll, "the held answer, not a new read")
        // And again straight after: the press that failed used to keep failing.
        #expect(commander.send(.playPause, to: Self.vlc) == .unconfirmed)
    }

    @Test("Asked again, a system now pointing at someone else still refuses")
    func agedReadingStillGuardsTheWrongPlayer() async throws {
        let clock = Clock()
        let adapter = Adapter(Self.paused(Self.vlc, "Film"))
        let composite = make(adapter, clock: clock)
        _ = await composite.snapshot()
        try #require(composite.systemOwnerBundleID == Self.vlc)

        var sent: [NowPlayingCommand] = []
        let commander = NowPlayingCommander(
            systemOwner: { composite.systemOwnerBundleID },
            dispatchGlobally: { sent.append($0) },
            automationAllows: { _ in false }
        )
        // A browser tab took the system's slot since the last poll.
        adapter.value = Self.paused(Self.safari, "A video")
        clock.now += Self.pastFreshness
        #expect(commander.send(.playPause, to: Self.vlc) == .wrongPlayer)
        #expect(sent.isEmpty, "play must never go to the tab")
    }

    /// Found by review (R1): the composite read paused VLC, and a second
    /// later the adapter heard Safari take the slot. A press on the VLC card
    /// before the next read went out on the strength of the one-second-old
    /// recording — and MediaRemote aimed it at Safari.
    @Test("A takeover the adapter has heard is refused, however recent the recorded owner")
    func freshTakeoverRefused() async throws {
        let clock = Clock()
        let adapter = Adapter(Self.paused(Self.vlc, "Film"))
        let composite = make(adapter, clock: clock)
        _ = await composite.snapshot()
        try #require(composite.systemOwnerBundleID == Self.vlc)
        var changes = 0
        composite.onChange = { changes += 1 }

        clock.now += 1
        adapter.value = NowPlayingSnapshot(
            title: "A video", artist: "", isPlaying: true, elapsed: 0, duration: 500,
            appName: "Safari", appBundleID: Self.safari
        )
        adapter.onChange?()
        // Reached: the takeover was delivered, well inside the freshness
        // window, and no read has run since.
        try #require(changes == 1)
        try #require(adapter.heldSystemOwner == Self.safari)
        try #require(clock.now - 50_000 < CompositeNowPlayingSource.systemOwnerFreshness)

        var sent: [NowPlayingCommand] = []
        let commander = NowPlayingCommander(
            systemOwner: { composite.systemOwnerBundleID },
            dispatchGlobally: { sent.append($0) },
            automationAllows: { _ in false }
        )
        #expect(commander.send(.playPause, to: Self.vlc) == .wrongPlayer)
        #expect(commander.send(.seek(30, item: nil), to: Self.vlc) == .wrongPlayer)
        #expect(sent.isEmpty, "nothing may go to the tab that just took the slot")
    }

    /// The two guards stand separately: the held answer is asked before the
    /// recording even when no change notice has arrived to void it.
    @Test("The held answer outranks a fresh recording before any change notice")
    func heldAnswerFirst() async throws {
        let clock = Clock()
        let adapter = Adapter(Self.paused(Self.vlc, "Film"))
        let composite = make(adapter, clock: clock)
        _ = await composite.snapshot()
        try #require(composite.systemOwnerBundleID == Self.vlc)
        clock.now += 1
        adapter.value = Self.paused(Self.safari, "A video")
        try #require(adapter.heldSystemOwner == Self.safari, "the adapter already holds the takeover")
        #expect(composite.systemOwnerBundleID == Self.safari)
    }

    @Test("A change from a source that cannot say what it holds voids the recorded owner")
    func changeVoidsRecording() async throws {
        let clock = Clock()
        let adapter = Publishing(Self.paused(Self.vlc, "Film"))
        let composite = make(adapter, clock: clock)
        _ = await composite.snapshot()
        try #require(composite.systemOwnerBundleID == Self.vlc)
        clock.now += 1
        adapter.onChange?()
        #expect(composite.systemOwnerBundleID == nil, "unknown until the next read, so refused")
        _ = await composite.snapshot()
        #expect(composite.systemOwnerBundleID == Self.vlc, "and known again after it")
    }

    @Test("A helper gone quiet, or a source that cannot say, refuses as before")
    func unknownStillRefuses() async throws {
        let clock = Clock()
        let adapter = Adapter(Self.paused(Self.vlc, "Film"))
        let composite = make(adapter, clock: clock)
        _ = await composite.snapshot()
        adapter.isAvailable = false
        clock.now += Self.pastFreshness
        #expect(composite.systemOwnerBundleID == nil)

        let plainClock = Clock()
        let plain = make(ReadOnly("adapter", Self.paused(Self.vlc, "Film")), clock: plainClock)
        _ = await plain.snapshot()
        try #require(plain.systemOwnerBundleID == Self.vlc)
        plainClock.now += Self.pastFreshness
        #expect(plain.systemOwnerBundleID == nil)
    }

    /// While the adapter is set aside it is the source known to be wrong
    /// about who is playing, so its held answer is not asked for.
    @Test("A demoted adapter's held answer is not trusted")
    func demotedAdapterNotAsked() async throws {
        let clock = Clock()
        let adapter = Adapter(nil)
        let spotify = NowPlayingSnapshot(
            title: "Song", artist: "Artist", isPlaying: true, elapsed: 30, duration: 240,
            appName: "Spotify", appBundleID: "com.spotify.client"
        )
        let composite = CompositeNowPlayingSource(
            adapter: adapter, scripting: ReadOnly("scripting", spotify),
            scriptedSnapshot: { _ in nil }, scriptingHandles: { _ in false },
            now: { clock.now }, lastTransportAt: { 0 }
        )
        // Silent while a player plays, enough times to be set aside.
        for _ in 0..<CompositeNowPlayingSource.demotionThreshold {
            _ = await composite.snapshot()
            clock.now += 1
        }
        try #require(composite.isDemoted)

        adapter.value = Self.paused(Self.vlc, "Film")
        clock.now += Self.pastFreshness
        try #require(composite.isDemoted, "still inside the cooldown")
        #expect(composite.systemOwnerBundleID == nil)
    }

    @Test("The adapter names the owner from its held line, and nothing once it has stopped")
    func adapterHeldOwner() {
        let source = MediaRemoteAdapterSource(dylibURL: URL(fileURLWithPath: "/nonexistent"))
        var line = AdapterPayload()
        line.kind = .now
        line.playing = false
        line.title = "A video"
        line.bundleID = "com.apple.WebKit.GPU"
        line.parentBundleID = Self.safari
        source.receive([line], from: 0)
        // Reached: the line is held. No helper is running in a test, so the
        // source is not available, and the held owner must say nothing.
        #expect(source.latest?.parentBundleID == Self.safari)
        #expect(!source.isAvailable)
        #expect(source.heldSystemOwner == nil)
    }
}

