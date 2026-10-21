import Foundation
import Testing

@testable import LedgeSystem

@Suite("AppleScript missing value")
@MainActor
struct ScriptingMissingValueTests {

    private let separator = "\u{1F}"

    private var spotify: ScriptingNowPlayingSource.Player {
        ScriptingNowPlayingSource.players.first { $0.bundleID == "com.spotify.client" }!
    }

    private var music: ScriptingNowPlayingSource.Player {
        ScriptingNowPlayingSource.players.first { $0.bundleID == "com.apple.Music" }!
    }

    private func line(_ fields: String...) -> String {
        fields.joined(separator: separator)
    }

    @Test("A missing artist or album is empty, not the literal text")
    func missingTextFields() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "missing value", "missing value", "1000", "0", "playing", "id", ""),
            player: spotify
        ))
        #expect(snapshot.artist == "")
        #expect(snapshot.album == "")
    }

    @Test("A missing duration stays unknown rather than filling the bar")
    func missingDuration() throws {
        // A stream with no duration used to parse to 0 and then be clamped up
        // to the position — a full progress bar for something with no end.
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "missing value", "42", "playing", "id"),
            player: music
        ))
        #expect(snapshot.duration == 0)
        #expect(snapshot.elapsed == 42)
    }

    @Test("A missing track id falls back to the metadata key")
    func missingTrackID() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "1000", "0", "playing", "missing value", ""),
            player: spotify
        ))
        #expect(snapshot.trackKey == "com.spotify.client|Artist|Album|Title")
    }

    @Test("A missing artwork URL yields none")
    func missingArtwork() throws {
        let snapshot = try #require(ScriptingNowPlayingSource.parse(
            line("Title", "Artist", "Album", "1000", "0", "playing", "id", "missing value"),
            player: spotify
        ))
        #expect(snapshot.artworkURL == nil)
    }

    @Test("A missing title is still empty, and a real one is left alone")
    func missingTitleAndOrdinaryText() throws {
        let missing = try #require(ScriptingNowPlayingSource.parse(
            line("missing value", "Artist", "Album", "1000", "0", "playing", "id", ""),
            player: spotify
        ))
        #expect(missing.title == "")

        let ordinary = try #require(ScriptingNowPlayingSource.parse(
            line("Missing Values (Live)", "Artist", "Album", "1000", "0", "playing", "id", ""),
            player: spotify
        ))
        #expect(ordinary.title == "Missing Values (Live)")
    }
}

@Suite("Automation denial latch")
struct AutomationDenialLatchTests {

    @Test("A denial is remembered for the cooldown, then forgotten")
    func deniedThenCleared() {
        var latch = AutomationDenialLatch()
        let cooldown = AutomationDenialLatch.cooldown
        let untouched = latch.isDenied("com.apple.Music", now: 0)
        #expect(untouched == false)

        latch.recordDenial("com.apple.Music", now: 0)
        let justAfter = latch.isDenied("com.apple.Music", now: 1)
        let nearEnd = latch.isDenied("com.apple.Music", now: cooldown - 1)
        let atEnd = latch.isDenied("com.apple.Music", now: cooldown)
        // And having lapsed, it stays clear until denied again.
        let afterEnd = latch.isDenied("com.apple.Music", now: cooldown + 1)
        #expect(justAfter)
        #expect(nearEnd)
        #expect(atEnd == false)
        #expect(afterEnd == false)
    }

    @Test("A player is known to allow Automation only once it has answered")
    func allowedOnlyAfterAnAnswer() {
        var latch = AutomationDenialLatch()
        let undecided = latch.isKnownAllowed("com.spotify.client", now: 0)
        #expect(undecided == false, "a player never heard from counted as allowed")
        latch.recordAnswer("com.spotify.client")
        let answered = latch.isKnownAllowed("com.spotify.client", now: 0)
        let other = latch.isKnownAllowed("com.apple.Music", now: 0)
        #expect(answered)
        #expect(other == false)
    }

    @Test("A refusal outlives its cooldown as undecided, not allowed")
    func refusalForgetsTheAnswer() {
        var latch = AutomationDenialLatch()
        let cooldown = AutomationDenialLatch.cooldown
        latch.recordAnswer("com.apple.Music")
        latch.recordDenial("com.apple.Music", now: 0)
        // Reached: the refusal has lapsed, so the latch no longer says denied.
        let lapsed = latch.isDenied("com.apple.Music", now: cooldown + 1)
        #expect(lapsed == false)
        // The grant was taken back; only a new answer can restore it, or a
        // play button would send an Apple Event to a player that said no.
        let allowed = latch.isKnownAllowed("com.apple.Music", now: cooldown + 1)
        #expect(allowed == false)
    }

    @Test("A grant clears refusals and keeps what has answered")
    func forgettingDenialsKeepsAnswers() {
        var latch = AutomationDenialLatch()
        latch.recordAnswer("com.spotify.client")
        latch.recordDenial("com.apple.Music", now: 0)
        latch.forgetDenials()
        let music = latch.isDenied("com.apple.Music", now: 1)
        let spotify = latch.isKnownAllowed("com.spotify.client", now: 1)
        #expect(music == false)
        #expect(spotify)
    }

    @Test("Denying one player does not silence the other")
    func perPlayer() {
        var latch = AutomationDenialLatch()
        latch.recordDenial("com.apple.Music", now: 0)
        let other = latch.isDenied("com.spotify.client", now: 1)
        #expect(other == false)
    }

    @Test("Only a TCC refusal reads as a denial")
    func recognisesDenial() {
        #expect(ScriptingNowPlayingSource.indicatesAutomationDenial(
            "execution error: Not authorized to send Apple events to Music. (-1743)"
        ))
        #expect(ScriptingNowPlayingSource.indicatesAutomationDenial("Music got an error: -1743"))
        #expect(ScriptingNowPlayingSource.indicatesAutomationDenial(
            "execution error: Music got an error: Can’t get current track. (-1728)"
        ) == false)
        #expect(ScriptingNowPlayingSource.indicatesAutomationDenial("") == false)
    }
}

@Suite("Scripting onboarding gate")
@MainActor
struct ScriptingOnboardingGateTests {
    @MainActor
    private final class Probe {
        var allowed = false
        var reads = 0
        var enumerations = 0
    }

    @Test("Both scripting paths stay silent until explicitly allowed, then work without rebuilding")
    func gateAppliesAtTheSource() async {
        let probe = Probe()
        let source = ScriptingNowPlayingSource(
            mayQueryPlayers: { probe.allowed },
            availablePlayers: { probe.enumerations += 1; return ScriptingNowPlayingSource.players },
            readPlayer: { player in
                probe.reads += 1
                return .answered(NowPlayingSnapshot(
                    title: "Track", artist: "Artist", isPlaying: true,
                    appName: player.displayName, appBundleID: player.bundleID
                ))
            }
        )
        #expect(!source.isAvailable)
        #expect(await source.snapshot() == nil)
        #expect(await source.snapshot(forBundleID: "com.apple.Music") == nil)
        #expect(probe.reads == 0)
        #expect(probe.enumerations == 0)
        probe.allowed = true
        #expect(source.isAvailable)
        #expect(await source.snapshot()?.isPlaying == true)
        #expect(await source.snapshot(forBundleID: "com.apple.Music")?.appBundleID == "com.apple.Music")
        #expect(probe.reads == 2)
        #expect(await source.snapshot(forBundleID: "unknown") == nil)
        #expect(probe.reads == 2)
    }
}

/// What happens when the player does not answer, which is not the same as the
/// player saying nothing is playing. The difference closed a visible gap: one
/// `osascript` past its three-second deadline, measured against Spotify, used
/// to retract the card and shut the island in the middle of a pause.
@Suite("A player that does not answer")
@MainActor
struct ScriptingUnreadableReadTests {

    @MainActor
    private final class Script {
        var reading: ScriptingNowPlayingSource.PlayerReading = .nothing
        var clock: TimeInterval = 1_000
    }

    private static let spotify = ScriptingNowPlayingSource.players.first {
        $0.bundleID == "com.spotify.client"
    }!

    private func source(_ script: Script) -> ScriptingNowPlayingSource {
        ScriptingNowPlayingSource(
            mayQueryPlayers: { true },
            availablePlayers: { [Self.spotify] },
            readPlayer: { _ in script.reading },
            now: { script.clock }
        )
    }

    private func paused(_ title: String) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title, artist: "Murda", isPlaying: false,
            appName: "Spotify", appBundleID: "com.spotify.client"
        )
    }

    @Test("An unanswered read keeps the last answer instead of taking the card away")
    func unreadableHoldsTheLastAnswer() async {
        let script = Script()
        let source = source(script)

        script.reading = .answered(paused("karambol"))
        #expect(await source.snapshot()?.title == "karambol")

        // The next poll's script misses its deadline.
        script.reading = .unreadable
        script.clock += 1
        #expect(await source.snapshot()?.title == "karambol")

        // And the one after it gets through.
        script.reading = .answered(paused("karambol"))
        script.clock += 1
        #expect(await source.snapshot()?.title == "karambol")
    }

    @Test("A player that says nothing is playing takes its card with it")
    func nothingIsBelievedAtOnce() async {
        let script = Script()
        let source = source(script)

        script.reading = .answered(paused("karambol"))
        #expect(await source.snapshot()?.title == "karambol")

        // Not a missed deadline: the player answered, and it has stopped.
        script.reading = .nothing
        script.clock += 1
        #expect(await source.snapshot() == nil)
    }

    @Test("The held answer is not allowed to go stale")
    func theHeldAnswerExpires() async {
        let script = Script()
        let source = source(script)

        script.reading = .answered(paused("karambol"))
        #expect(await source.snapshot()?.title == "karambol")

        script.reading = .unreadable
        script.clock += 9
        #expect(await source.snapshot()?.title == "karambol")
        script.clock += 2
        #expect(await source.snapshot() == nil)
    }

    @Test("Nothing is held for a player that has never answered")
    func nothingToHoldAtFirst() async {
        let script = Script()
        let source = source(script)
        script.reading = .unreadable
        #expect(await source.snapshot() == nil)
    }

    @Test("A stopped player cannot be covered by an answer it gave before")
    func nothingClearsTheHeldAnswer() async {
        let script = Script()
        let source = source(script)

        script.reading = .answered(paused("karambol"))
        #expect(await source.snapshot()?.title == "karambol")
        script.reading = .nothing
        script.clock += 1
        #expect(await source.snapshot() == nil)

        // The player stops answering now. There is nothing left to show: the
        // card went away for a reason, and a held answer must not bring it
        // back.
        script.reading = .unreadable
        script.clock += 1
        #expect(await source.snapshot() == nil)
    }

    @Test("The single-player path follows the same rule")
    func theByBundlePathHoldsToo() async {
        let script = Script()
        let source = source(script)

        script.reading = .answered(paused("karambol"))
        #expect(await source.snapshot(forBundleID: "com.spotify.client")?.title == "karambol")

        script.reading = .unreadable
        script.clock += 1
        #expect(await source.snapshot(forBundleID: "com.spotify.client")?.title == "karambol")

        script.reading = .nothing
        script.clock += 1
        #expect(await source.snapshot(forBundleID: "com.spotify.client") == nil)
    }
}

/// Which `osascript` outcomes count as the player having answered. The whole
/// unanswered-read rule rests on this mapping, so each outcome is pinned.
@Suite("What one osascript run means")
@MainActor
struct ScriptingReadingTests {

    private let separator = "\u{1F}"

    private var spotify: ScriptingNowPlayingSource.Player {
        ScriptingNowPlayingSource.players.first { $0.bundleID == "com.spotify.client" }!
    }

    private func isUnreadable(_ reading: ScriptingNowPlayingSource.PlayerReading) -> Bool {
        if case .unreadable = reading { return true }
        return false
    }

    private func isNothing(_ reading: ScriptingNowPlayingSource.PlayerReading) -> Bool {
        if case .nothing = reading { return true }
        return false
    }

    @Test("A missed deadline is not the player saying it has nothing")
    func failedIsUnreadable() {
        #expect(isUnreadable(ScriptingNowPlayingSource.reading(from: .failed, player: spotify)))
    }

    @Test("A refused Automation prompt teaches us nothing about what is playing")
    func deniedIsUnreadable() {
        #expect(isUnreadable(ScriptingNowPlayingSource.reading(
            from: .denied("-1743"), player: spotify
        )))
    }

    @Test("An empty answer is the player saying nothing is playing")
    func emptyOutputIsNothing() {
        #expect(isNothing(ScriptingNowPlayingSource.reading(from: .output(""), player: spotify)))
        // osascript puts a newline after the result.
        #expect(isNothing(ScriptingNowPlayingSource.reading(from: .output("\n"), player: spotify)))
    }

    @Test("Output that will not parse is not an answer either")
    func corruptOutputIsUnreadable() {
        #expect(isUnreadable(ScriptingNowPlayingSource.reading(
            from: .output("two" + separator + "fields"), player: spotify
        )))
    }

    @Test("A well-formed line is an answer")
    func goodOutputIsAnswered() throws {
        let fields = ["karambol", "Murda", "Album", "180000", "151", "paused", "id", ""]
        let reading = ScriptingNowPlayingSource.reading(
            from: .output(fields.joined(separator: separator)), player: spotify
        )
        guard case .answered(let snapshot) = reading else {
            Issue.record("expected an answer, got \(reading)")
            return
        }
        #expect(snapshot.title == "karambol")
        #expect(snapshot.isPlaying == false)
    }
}

/// One player's answer must never stand in for another's. A shared held answer
/// put Spotify's paused track on a card asking about Music — and every
/// transport button on that card then addressed Spotify.
@Suite("A held answer belongs to the player that gave it")
@MainActor
struct ScriptingHeldAnswerIsolationTests {

    @MainActor
    private final class Script {
        var byPlayer: [String: ScriptingNowPlayingSource.PlayerReading] = [:]
        var clock: TimeInterval = 1_000
    }

    private static let spotify = ScriptingNowPlayingSource.players.first {
        $0.bundleID == "com.spotify.client"
    }!
    private static let music = ScriptingNowPlayingSource.players.first {
        $0.bundleID == "com.apple.Music"
    }!

    private func source(_ script: Script) -> ScriptingNowPlayingSource {
        ScriptingNowPlayingSource(
            mayQueryPlayers: { true },
            availablePlayers: { [Self.spotify, Self.music] },
            readPlayer: { player in script.byPlayer[player.bundleID] ?? .nothing },
            now: { script.clock }
        )
    }

    private func snapshot(_ bundleID: String, _ title: String, playing: Bool) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            title: title, artist: "Artist", isPlaying: playing,
            appName: bundleID == "com.spotify.client" ? "Spotify" : "Music",
            appBundleID: bundleID
        )
    }

    @Test("A targeted read of a silent player is not answered with the other one's track")
    func targetedReadStaysWithItsPlayer() async {
        let script = Script()
        let source = source(script)

        // Spotify has been paused for a while, so it has a held answer.
        script.byPlayer["com.spotify.client"] = .answered(snapshot("com.spotify.client", "karambol", playing: false))
        #expect(await source.snapshot()?.appBundleID == "com.spotify.client")

        // Music is asked and does not reply. It has never answered, so there
        // is nothing of its own to fall back on.
        script.clock += 1
        script.byPlayer["com.apple.Music"] = .unreadable
        let targeted = await source.snapshot(forBundleID: "com.apple.Music")
        #expect(targeted == nil)
    }

    @Test("An unreadable player is covered only by its own last answer")
    func eachPlayerCoversItself() async {
        let script = Script()
        let source = source(script)

        script.byPlayer["com.apple.Music"] = .answered(snapshot("com.apple.Music", "Sonata", playing: false))
        #expect(await source.snapshot()?.title == "Sonata")

        // Music goes quiet; Spotify answers that it has nothing.
        script.clock += 1
        script.byPlayer["com.apple.Music"] = .unreadable
        script.byPlayer["com.spotify.client"] = .nothing
        let held = await source.snapshot()
        #expect(held?.appBundleID == "com.apple.Music")
        #expect(held?.title == "Sonata")
    }

    @Test("A player answering nothing does not spend the other player's cover")
    func nothingClearsOnlyItsOwn() async {
        let script = Script()
        let source = source(script)

        script.byPlayer["com.spotify.client"] = .answered(snapshot("com.spotify.client", "karambol", playing: false))
        #expect(await source.snapshot()?.title == "karambol")

        // Music says it has nothing. Spotify then misses its deadline: its own
        // answer is still the one that covers it.
        script.clock += 1
        script.byPlayer["com.apple.Music"] = .nothing
        script.byPlayer["com.spotify.client"] = .unreadable
        #expect(await source.snapshot()?.title == "karambol")
    }

    /// The discriminating case: Spotify quits, so it is never read again and
    /// its held answer just sits there, while Music misses its deadline. Only
    /// Music's own answer may cover Music — and it has none.
    @Test("A player that has quit cannot cover a different player's silence")
    func aQuitPlayersAnswerCoversNobodyElse() async {
        let script = Script()
        var running = [Self.spotify, Self.music]
        let source = ScriptingNowPlayingSource(
            mayQueryPlayers: { true },
            availablePlayers: { running },
            readPlayer: { player in script.byPlayer[player.bundleID] ?? .nothing },
            now: { script.clock }
        )

        script.byPlayer["com.spotify.client"] = .answered(snapshot("com.spotify.client", "karambol", playing: false))
        #expect(await source.snapshot()?.title == "karambol")

        // Spotify quits: it drops out of the running list and is never asked
        // again, so nothing ever retires the answer it left behind.
        running = [Self.music]
        script.clock += 1
        script.byPlayer["com.apple.Music"] = .unreadable
        #expect(await source.snapshot() == nil)
    }

    @Test("A player that says it stopped takes its own card away")
    func nothingRetiresItsOwnAnswer() async {
        let script = Script()
        let source = source(script)

        script.byPlayer["com.spotify.client"] = .answered(snapshot("com.spotify.client", "karambol", playing: false))
        #expect(await source.snapshot()?.title == "karambol")

        script.clock += 1
        script.byPlayer["com.spotify.client"] = .nothing
        #expect(await source.snapshot() == nil)

        // And having answered, it has nothing held to come back on.
        script.clock += 1
        script.byPlayer["com.spotify.client"] = .unreadable
        #expect(await source.snapshot() == nil)
    }

    /// The stop is the player's word, whichever read heard it, and it stands
    /// until the player says something else. A read of every player stops at
    /// the first one playing, so it must not forget a stop it never asked
    /// about; and silence, or not being allowed to ask, is not something else.
    @Test("A stop is kept for its player until that player answers again")
    func stopIsKeptUntilThePlayerAnswers() async throws {
        let script = Script()
        var mayAsk = true
        let source = ScriptingNowPlayingSource(
            mayQueryPlayers: { mayAsk },
            availablePlayers: { [Self.spotify, Self.music] },
            readPlayer: { player in script.byPlayer[player.bundleID] ?? .nothing },
            now: { script.clock }
        )
        script.byPlayer["com.apple.Music"] = .nothing
        script.byPlayer["com.spotify.client"] = .answered(snapshot("com.spotify.client", "karambol", playing: true))

        #expect(await source.snapshot(forBundleID: "com.apple.Music") == nil)
        try #require(source.answeredNothing == ["com.apple.Music"], "reached: the targeted read heard Music stop")

        let everyone = await source.snapshot()
        try #require(everyone?.appBundleID == "com.spotify.client", "reached: the scan stopped at Spotify")
        #expect(source.answeredNothing == ["com.apple.Music"], "and did not forget Music")

        script.byPlayer["com.apple.Music"] = .unreadable
        _ = await source.snapshot(forBundleID: "com.apple.Music")
        mayAsk = false
        _ = await source.snapshot()
        #expect(source.answeredNothing == ["com.apple.Music"], "nor did silence, or not being allowed to ask")

        mayAsk = true
        script.byPlayer["com.apple.Music"] = .answered(snapshot("com.apple.Music", "Sonata", playing: true))
        _ = await source.snapshot(forBundleID: "com.apple.Music")
        #expect(source.answeredNothing.isEmpty, "Music answering again is what retires it")
    }
}
