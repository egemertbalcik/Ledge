import Foundation
import LedgeCore
import os

/// Combines the MediaRemote adapter with the AppleScript source.
///
/// The split is deliberate and is what guarantees the two players that already
/// work keep working byte-for-byte:
///
/// - **Music and Spotify** are answered by AppleScript, exactly as before. Same
///   `trackKey`, same artwork URL, same reliable seek.
///   MediaRemote is used only to notice *that* they own playback.
/// - **Everything else** — a YouTube tab in any browser, VLC, IINA, Podcasts —
///   is answered by the adapter. That is the whole point of the feature.
///
/// And because no probe can distinguish "Apple closed the gate again" from
/// "nothing is playing", there is a runtime demotion: if the adapter stays
/// silent while AppleScript can plainly see a playing track, the composite sets
/// it aside for a while and the app degrades to exactly its previous behaviour.
///
/// The AppleScript answers are cached. Asking a player through `osascript` is
/// a fork, an exec, a script compile and an Apple event — every second while
/// Spotify plays, that was the single most expensive thing this app did at
/// idle. The adapter already tells us the track and the play state for free,
/// so the script is re-run only when one of those changes, when the user
/// touched the transport, or on a slow cadence; between runs the cached answer
/// is returned with its position projected forward.
@MainActor
public final class CompositeNowPlayingSource: NowPlayingSource, NowPlayingChangePublishing {

    /// What the app can currently see, for the one line in Settings that says
    /// so. A demotion used to be invisible: browser media simply stopped
    /// appearing, with nothing anywhere to explain it.
    public var status: MediaSourceStatus {
        guard let until = demotedUntil, now() < until else {
            return .systemWide(host: adapterHostName)
        }
        return .degraded(retryingInSeconds: Int((until - now()).rounded()))
    }

    /// Told whenever `status` changes, so the settings window can follow a
    /// demotion that happens while it is open.
    public var onStatusChanged: (() -> Void)?

    /// Named for the status line. The composite does not otherwise care which
    /// binary is doing the reading.
    private var adapterHostName: String {
        (adapter as? MediaRemoteAdapterSource)?.host.name ?? "a system component"
    }

    /// Passed through from the adapter, which is the side that hears about a
    /// change without being asked. The scripting side has its own notifier and
    /// the provider already listens to that one directly.
    public var onChange: (() -> Void)?

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "nowplaying")

    public let identifier = "composite"

    /// Consecutive polls where the adapter said nothing but AppleScript saw a
    /// playing track, before the adapter is set aside.
    static let demotionThreshold = 3

    /// How long a demotion lasts. Not for the run: the silence that triggers
    /// it has legitimate causes — Spotify Connect plays on another device with
    /// no local MediaRemote client at all — and a browser tab opened after that
    /// would otherwise stay invisible until relaunch.
    static let demotionCooldown: TimeInterval = 120

    /// While demoted, how often the adapter is still peeked at. Its `snapshot()`
    /// is a cache read, so this costs nothing; the point is that a helper that
    /// comes back to life is noticed long before the cooldown ends.
    static let demotedProbeInterval: TimeInterval = 10

    /// How old a cached AppleScript answer may get before it is re-read even
    /// though nothing seems to have changed. Playing: keeps the exact position,
    /// artwork URL and track key honest against drift. Paused: nothing moves,
    /// so this is only a safety net for a missed change notification.
    static let scriptingCadenceWhilePlaying: TimeInterval = 10
    static let scriptingCadenceWhilePaused: TimeInterval = 30

    /// How often the scripting side is asked when the adapter is healthy and
    /// says nothing is loaded at all.
    ///
    /// Every one of these is a subprocess: a fork, an exec, a script compile
    /// and an Apple event. At the paused cadence an idle Mac spawned one every
    /// thirty seconds, for ever, to be told again that nothing is playing.
    ///
    /// The adapter sees every player the system knows about, Music and Spotify
    /// included — the composite only *prefers* the scripted answer for those
    /// two, it does not depend on it to notice them. So while the adapter is
    /// healthy and silent, there is nothing to find, and the only thing this
    /// slow beat is really watching for is Spotify Connect playing on another
    /// device, which registers no local client at all.
    static let scriptingCadenceWhileAdapterIdle: TimeInterval = 5 * 60

    /// How recently the adapter must have spoken for that five-minute beat to
    /// be safe.
    ///
    /// The reasoning above rests on the adapter being able to *notice* things,
    /// and that is an assumption about a private framework in a borrowed host.
    /// When it is wrong the five minutes are not thrift, they are five minutes
    /// of a playing track going unmentioned. The helper polls every one to
    /// three seconds and heartbeats every thirty, so a gap past this means it
    /// has stopped watching, whatever its process table entry says — and then
    /// AppleScript goes back to the ordinary beat.
    static let adapterLivelinessWindow: TimeInterval = 45

    /// After a transport command or a player's own change notification, every
    /// poll re-scripts for this long. The players answer AppleScript with their
    /// new state a moment *after* announcing it, and the provider reads three
    /// times in the first second for exactly that reason — a single re-read
    /// could cache the old state for a whole cadence.
    static let rescriptBurst: TimeInterval = 2

    /// How far the adapter's position may stray from where it should have
    /// moved to since the last poll before it is taken as a seek. Catches a
    /// scrub in the player's own window, which posts no notification.
    static let seekTolerance: TimeInterval = 3

    private let adapter: any NowPlayingSource
    private let scripting: any NowPlayingSource
    /// Asks the scripting side about one specific player. Injected rather than
    /// called on a concrete type so the routing can be tested without spawning
    /// `osascript` — and therefore without depending on which players happen to
    /// be running on the machine.
    private let scriptedSnapshot: (String) async -> NowPlayingSnapshot?
    private let scriptingHandles: (String) -> Bool
    private let now: () -> TimeInterval
    /// When a transport command was last dispatched — see
    /// `NowPlayingCommander.lastCommandAt`. Injected so tests can issue one.
    private let lastTransportAt: @MainActor () -> TimeInterval
    private let playbackWatcher: PlaybackChangeWatcher?

    // MARK: Demotion state

    private var silentWhileScriptingPlaying = 0
    private var demotedUntil: TimeInterval?
    private var lastDemotedProbeAt: TimeInterval = 0

    var isDemoted: Bool {
        guard let demotedUntil else { return false }
        return now() < demotedUntil
    }

    // MARK: Scripting cache

    /// One cached AppleScript answer, with what the adapter said at the time
    /// so a change on its side can be noticed without re-scripting.
    private struct ScriptedEntry {
        var snapshot: NowPlayingSnapshot
        var at: TimeInterval
        var adapterTrackKey: String
        var adapterIsPlaying: Bool
    }

    /// Per player, for the path where the adapter names the player.
    private var scriptedByPlayer: [String: ScriptedEntry] = [:]
    /// The scripting source's own answer, for the paths where the adapter is
    /// silent or set aside and only cadence and notifications can refresh it.
    private var scriptedFallback: (snapshot: NowPlayingSnapshot?, at: TimeInterval)?
    /// Until when every poll re-scripts regardless of the cache.
    private var rescriptUntil: TimeInterval = 0
    private var seenTransportAt: TimeInterval = 0
    /// What the adapter said last poll, to spot a position jump.
    private var previousAdapter: (bundleID: String, elapsed: TimeInterval, isPlaying: Bool, at: TimeInterval)?

    public init(
        adapter: any NowPlayingSource,
        scripting: any NowPlayingSource,
        scriptedSnapshot: @escaping (String) async -> NowPlayingSnapshot?,
        scriptingHandles: @escaping (String) -> Bool,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        lastTransportAt: @escaping @MainActor () -> TimeInterval = { NowPlayingCommander.lastCommandAt },
        allowsMedia: @escaping @MainActor (NowPlayingSnapshot) -> Bool = { _ in true },
        playbackWatcher: PlaybackChangeWatcher? = nil
    ) {
        self.adapter = adapter
        self.scripting = scripting
        self.scriptedSnapshot = scriptedSnapshot
        self.scriptingHandles = scriptingHandles
        self.now = now
        self.lastTransportAt = lastTransportAt
        self.allowsMedia = allowsMedia
        self.playbackWatcher = playbackWatcher
        // The players announce play, pause and track changes themselves. That
        // is the signal that makes a cached answer safe: anything the adapter
        // would not show us — Spotify Connect, a demoted adapter — still
        // reaches us here and forces a fresh read.
        playbackWatcher?.startWatching { [weak self] in self?.playbackChanged() }
        // Weak on both sides: the adapter is held here, and a strong closure
        // back would be a cycle that outlives every source swap.
        (adapter as? any NowPlayingChangePublishing)?.onChange = { [weak self] in
            guard let self else { return }
            // The cached scripted answer is about to be wrong too: a browser
            // taking over, or Spotify starting, changes who owns playback.
            self.rescriptUntil = max(self.rescriptUntil, self.now() + Self.rescriptBurst)
            self.onChange?()
        }
    }

    /// The production wiring.
    public convenience init(
        adapter: any NowPlayingSource,
        scripting: ScriptingNowPlayingSource,
        allowsMedia: @escaping @MainActor (NowPlayingSnapshot) -> Bool = { _ in true }
    ) {
        self.init(
            adapter: adapter,
            scripting: scripting,
            scriptedSnapshot: { [weak scripting] bundleID in
                await scripting?.snapshot(forBundleID: bundleID)
            },
            scriptingHandles: { ScriptingNowPlayingSource.handles($0) },
            allowsMedia: allowsMedia,
            playbackWatcher: PlaybackChangeWatcher()
        )
    }

    public var isAvailable: Bool {
        adapter.isAvailable || scripting.isAvailable
    }

    // MARK: - Who the system is pointing at

    /// What the system itself last said was playing, and when it said it.
    private var systemOwner: (bundleID: String?, at: TimeInterval)?

    /// How recently the system must have been read for its answer to be worth
    /// aiming an unaddressed command by.
    ///
    /// The card is read every one to four seconds while it is up, so a reading
    /// older than this means the media machinery is not running — and a guess
    /// about who owns the slot is exactly what must not be acted on.
    public static let systemOwnerFreshness: TimeInterval = 10

    /// Which player the system considers now-playing, as last actually read —
    /// raw, with none of this type's holding rules applied.
    ///
    /// Those rules exist to keep the card still while a browser shuffles its
    /// now-playing slot around, and they are right for a card and wrong for a
    /// command. A command with no address goes wherever the system is
    /// pointing, not where the card is, so the transport has to ask this
    /// question rather than the card's one.
    ///
    /// Nil means "not known", which covers nothing playing, no adapter, an
    /// adapter set aside, and a reading too old to stand behind.
    public var systemOwnerBundleID: String? {
        guard let systemOwner, now() - systemOwner.at < Self.systemOwnerFreshness
        else { return nil }
        return systemOwner.bundleID
    }

    private func noteSystemOwner(_ bundleID: String?, at now: TimeInterval) {
        systemOwner = (bundleID, now)
    }

    // MARK: - Reading, one pass at a time

    /// The pass reading right now, and the one pass waiting to read next.
    ///
    /// Two slots, never more. See `snapshot()`.
    private var activePass: ReadPass?
    private var pendingPass: ReadPass?
    private var activeTask: Task<Void, Never>?

    /// How many passes have run. The bound this queue exists to keep — a
    /// burst of demand costing a fixed number of reads rather than one each —
    /// cannot be seen in the answers, so it is counted here for the tests that
    /// assert it.
    private(set) var passesBegun = 0

    /// Callers waiting for a pass that has not started yet. Never more than
    /// one pass's worth, by construction.
    var waitingForNextPass: Int { pendingPass?.waiterCount ?? 0 }

    /// Reads are taken one pass at a time, and demand for a fresh one is
    /// coalesced into a single waiting pass.
    ///
    /// A read is not one await but several — the adapter, then `osascript`,
    /// then sometimes `osascript` again — and it reads, mutates and re-reads
    /// the caches in between. The provider overlaps reads on purpose: the
    /// steady poll, the burst after a transport press and an immediate refresh
    /// all ask this same source. Overlapped, their steps interleaved, and the
    /// one that started earlier could finish later and commit its older
    /// answer — a cached position and play state from before the press — over
    /// the newer one. The provider's own ordering cannot undo that: by then
    /// the stale reading *is* the cache, and the next several polls project
    /// from it. So passes take their turn, and ordering follows from that:
    /// only one pass is ever inside `read`, and it commits before the next
    /// begins.
    ///
    /// Taking turns is not enough on its own, though. A queue of callers each
    /// waiting to start their own read is a backlog, and the thing filling it
    /// is `refreshSoon`, which cancels and replaces its own work every time a
    /// player announces something. Chained one-per-caller, those cancelled
    /// replacements still had a read of their own waiting behind the slow one,
    /// so fifty abandoned notifications meant fifty `osascript` runs after the
    /// fact — reads nobody was waiting for any more, delaying the fresh state
    /// behind obsolete work and carrying on past `stop`. Everyone who arrives
    /// while a pass is running wants the same thing — the state after it — so
    /// they share one pass, and a pass nobody is still waiting for is never
    /// started at all.
    public func snapshot() async -> NowPlayingSnapshot? {
        // Already given up before asking: no pass, no subprocess, nothing.
        guard !Task.isCancelled else { return nil }
        let (pass, ticket) = enlist()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pass.attach(continuation, to: ticket)
            }
        } onCancel: {
            // Deliberately synchronous: a waiter that has to hop to the main
            // actor to take its name off the list is a waiter the queue can
            // still decide to spawn an `osascript` for.
            guard pass.leave(ticket) == .lastOneOut else { return }
            Task { @MainActor [weak self] in self?.abandon(pass) }
        }
    }

    /// Puts the caller on the pass whose answer it should get: the one running,
    /// if nothing is running yet, and otherwise the one that will run next.
    private func enlist() -> (pass: ReadPass, ticket: Int) {
        if activePass == nil {
            let pass = ReadPass()
            let ticket = pass.reserve()
            activePass = pass
            begin(pass)
            return (pass, ticket)
        }
        let pass = pendingPass ?? ReadPass()
        pendingPass = pass
        return (pass, pass.reserve())
    }

    private func begin(_ pass: ReadPass) {
        passesBegun += 1
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return pass.finish(with: nil) }
            let answer = self.keepingOneNamePerSong(await self.read())
            pass.finish(with: answer)
            self.activePass = nil
            self.activeTask = nil
            self.advance()
        }
    }

    /// Hands the turn to the waiting pass — unless everyone who asked for it
    /// has gone, in which case there is nothing left to read for.
    private func advance() {
        guard activePass == nil, let next = pendingPass else { return }
        pendingPass = nil
        guard next.hasWaiters else { return next.finish(with: nil) }
        activePass = next
        begin(next)
    }

    /// Nobody is waiting on this pass any more.
    ///
    /// A pass still waiting its turn is simply dropped. A pass that is already
    /// reading owns a subprocess exclusively at this point, so that is
    /// cancelled too — but only once the *last* waiter has left. Several live
    /// callers share one pass, and one of them losing interest is no reason to
    /// take the answer away from the others.
    private func abandon(_ pass: ReadPass) {
        guard !pass.hasWaiters else { return }
        if pendingPass === pass {
            pendingPass = nil
            pass.finish(with: nil)
            return
        }
        if activePass === pass { activeTask?.cancel() }
    }

    /// What this composite last called each player's current song.
    ///
    /// One per player, and only the song that is playing now: this is a way of
    /// keeping a name, not a history.
    private var namedSongs: [String: (key: String, song: String)] = [:]

    /// Keeps one name for one song.
    ///
    /// Two sources answer here and they name the same song differently. The
    /// script knows the player's own track id; the adapter has only metadata,
    /// and falls back to composing a name out of it. So the published name
    /// changed whenever the *answer* came from the other one — a scripted read
    /// that timed out, a track id the player did not give this time — and
    /// everything downstream reads a changed name as a changed song. On the
    /// card that is the cover turning over for a song that never changed.
    ///
    /// The song itself is what settles it: same title, artist and album from
    /// the same player means the same song, whatever it has been called this
    /// time, so the name already in use is kept. A real track change brings
    /// different metadata and takes a new name with it.
    private func keepingOneNamePerSong(_ snapshot: NowPlayingSnapshot?) -> NowPlayingSnapshot? {
        guard var snapshot else { return nil }
        let song = "\(snapshot.title)\u{1F}\(snapshot.artist)\u{1F}\(snapshot.album)"
        let player = snapshot.appBundleID
        if let known = namedSongs[player], known.song == song {
            snapshot.trackKey = known.key
            return snapshot
        }
        namedSongs[player] = (snapshot.trackKey, song)
        return snapshot
    }

    private func read() async -> NowPlayingSnapshot? {
        // Nobody is waiting for this any more — see `abandon`. Checked again
        // before each piece of real work below, because the expensive parts of
        // a read are subprocesses and the point of cancelling is not to spawn
        // them.
        guard !Task.isCancelled else { return nil }
        let now = now()
        noteTransportCommands(at: now)

        if DebugSwitches.tracing("media") {
            let state = demotedUntil.map { "demoted for \(Int($0 - now))s" } ?? "live"
            Self.log.notice("media/composite: adapter \(state, privacy: .public) available=\(self.adapter.isAvailable, privacy: .public)")
        }

        if let until = demotedUntil {
            if now >= until {
                // Cooldown over: give the adapter a clean slate. If it is still
                // blind while a player plays, the counter demotes it again.
                demotedUntil = nil
                silentWhileScriptingPlaying = 0
                onStatusChanged?()
                Self.log.notice("now playing: adapter demotion expired — trying it again")
            } else if now - lastDemotedProbeAt >= Self.demotedProbeInterval {
                lastDemotedProbeAt = now
                let probed = await adapter.snapshot()
                noteSystemOwner(probed?.appBundleID, at: now)
                if let fromAdapter = probed {
                    demotedUntil = nil
                    silentWhileScriptingPlaying = 0
                    onStatusChanged?()
                    Self.log.notice("now playing: adapter answered while demoted — restoring it")
                    return await answer(fromAdapter, at: now)
                }
                return await fallback(at: now)
            } else {
                return await fallback(at: now)
            }
        }

        let fromSystem = await adapter.snapshot()
        // Who the *system* says owns playback, recorded raw, before any of the
        // holding rules below get to disagree with it. See `systemOwnerBundleID`.
        noteSystemOwner(fromSystem?.appBundleID, at: now)

        if let fromAdapter = fromSystem {
            silentWhileScriptingPlaying = 0
            return await keepingIncumbent(over: answer(fromAdapter, at: now), at: now)
        }
        previousAdapter = nil

        if DebugSwitches.tracing("media") {
            Self.log.notice("media/composite: adapter silent (available=\(self.adapter.isAvailable, privacy: .public))")
        }

        // The adapter is silent. That is either a genuinely idle machine or the
        // entitlement trick having stopped working — and only AppleScript can
        // tell the difference.
        let scripted = await fallback(at: now)

        // An adapter that is not even available — helper restarting, or the
        // first seconds after wake before its heartbeat arrives — is not
        // *silent*, it is absent. Counting those polls demoted a healthy
        // helper for something it never had the chance to answer.
        guard adapter.isAvailable else { return scripted }

        if let scripted, scripted.isPlaying {
            // Only *playing* counts. A paused Spotify still answers AppleScript
            // while the adapter rightly reports nothing — counting that pushed
            // the counter to the threshold during any long pause and demoted a
            // perfectly healthy adapter, killing browser media for the run
            // (eight wrongful demotions in one evening's log).
            silentWhileScriptingPlaying += 1
            if silentWhileScriptingPlaying >= Self.demotionThreshold {
                silentWhileScriptingPlaying = 0
                demotedUntil = now + Self.demotionCooldown
                lastDemotedProbeAt = now
                onStatusChanged?()
                Self.log.error("""
                    now playing: adapter silent while a player was playing — \
                    demoting to AppleScript for \(Int(Self.demotionCooldown), privacy: .public)s
                    """)
            }
        } else {
            silentWhileScriptingPlaying = 0
        }
        if DebugSwitches.tracing("media") {
            let what = scripted.map { "\($0.appBundleID) playing=\($0.isPlaying)" } ?? "nothing"
            Self.log.notice("media/composite: scripting says \(what, privacy: .public)")
        }
        return scripted
    }

    /// Which player the notch is holding, and since when it started playing.
    /// Cleared by a pause: seniority is continuous play, not mere presence.
    private var incumbent: (bundleID: String, since: TimeInterval)?

    /// The last answer that was actually playing, kept so a different item
    /// arriving *paused* cannot take its place.
    private var heldPlaying: (snapshot: NowPlayingSnapshot, at: TimeInterval)?

    /// How long after last being seen playing a track keeps the notch against
    /// anything else the system names.
    ///
    /// Measured on a real session: Safari changed its mind about which item is
    /// "now playing" eighty times in nine minutes — roughly every six seconds
    /// — as autoplaying videos in a Twitter timeline took the slot from the
    /// video actually being watched. Each of those claimed to be playing, so
    /// nothing short of "the one that was here first, while it lasts" keeps
    /// the notch still.
    ///
    /// Fifteen seconds is measured against that: comfortably longer than the
    /// gap between sightings of the real track, so it is continually renewed
    /// while it plays, and short enough that when it genuinely stops the notch
    /// moves on promptly.
    static let heldGrace: TimeInterval = 15

    /// How long an application's own media keeps the notch against a web page
    /// claiming the slot.
    ///
    /// Separate from `heldGrace`, and longer, because the two windows measure
    /// different things. `heldGrace` is about churn *within* a source, where
    /// the real track is re-sighted every few seconds. This one covers a page
    /// holding the system's single now-playing slot while a player keeps
    /// playing unseen: the scripting fallback is what confirms the player is
    /// still going, and where that is unavailable — Automation not granted —
    /// a minute of no sighting whatsoever is where the page is finally let
    /// through. A track whose length is known expires earlier than that, on
    /// `hasFinished`.
    static let appHoldAgainstPage: TimeInterval = 60

    /// The user asked for a track change, so the next different item is theirs
    /// and must not be resisted.
    public func expectChange() {
        heldPlaying = nil
        challenger = nil
    }

    /// A different item, seen once, waiting to be seen again.
    private var challenger: (trackKey: String, at: TimeInterval)?

    /// How long a challenger must persist before it takes the seat.
    ///
    /// The churn this guards against flickers: the browser hands its slot to
    /// an autoplaying video, then back, then to another — measured at eighty
    /// changes in nine minutes, rarely the same interloper twice in a row. A
    /// track the user actually chose does not flicker; it is simply there, and
    /// still there a moment later.
    ///
    /// So corroboration replaced waiting. The old rule refused *any* different
    /// item for fifteen seconds, which is right for churn and badly wrong for
    /// the user pressing Next in the card: the card kept the old title,
    /// artwork and duration while the new song played underneath it.
    static let challengerCorroboration: TimeInterval = 1.2

    /// Lets whoever was playing first keep the notch.
    ///
    /// The system reports exactly one now-playing item and it is whichever
    /// player spoke last, so starting a video with music already going handed
    /// the compact view straight to the video — the thing the user did *not*
    /// just choose to look at replaced the thing they had been listening to
    /// for half an hour. First come, first served is the rule people already
    /// expect from a radio: a second source does not take the speaker.
    ///
    /// Pausing gives up the seat. A track paused and resumed is a new arrival,
    /// so it cannot reclaim the notch from whatever took over meanwhile.
    ///
    /// The incumbent has to be *visible* to be kept, which in practice means
    /// scriptable: once the system names another player, Music and Spotify can
    /// still be asked directly, and a browser cannot be asked at all. So a
    /// browser holding the seat yields to a player that arrives after it —
    /// not a policy, a limit of what can be seen. It is also the harmless
    /// direction: what replaces it is something the user just started.
    private func keepingIncumbent(
        over answered: NowPlayingSnapshot,
        at now: TimeInterval
    ) async -> NowPlayingSnapshot {
        // A different item does not displace one that is still playing —
        // whatever it claims about itself.
        //
        // Every browser tab shares one bundle identifier and one now-playing
        // slot, and the browser hands that slot around: to a tab brought
        // forward, to a muted video autoplaying in a timeline, to a paused tab
        // that happens to be in front. None of those is the user choosing
        // something, and each of them took the notch from the thing they were
        // actually watching — measured at eighty times in nine minutes, and
        // most of them claiming to be playing.
        //
        // The item on screen stays master of its own state: pausing what you
        // are watching arrives under the same identity, is honoured at once,
        // and is what then lets something else through.
        if let held = heldPlaying,
           held.snapshot.trackKey != answered.trackKey,
           !Self.hasFinished(held.snapshot, at: now, since: held.at),
           // A page the user cannot see must not hold the notch against
           // anything: nothing is drawn for it, so holding meant the notch
           // showed nothing at all while a player was waiting behind it.
           allowsMedia(held.snapshot) {
            let catalogue = BrowserCatalogue.shared
            let pageOverApp = catalogue.isOpenableApp(bundleID: held.snapshot.appBundleID)
                && catalogue.isWebOwner(bundleID: answered.appBundleID)
            if pageOverApp {
                // A page does not corroborate its way past an app's own media.
                // Persistence is what the corroboration window measures, and a
                // video autoplaying in a timeline is nothing *but* persistent —
                // it keeps playing, so it keeps qualifying, and it took the
                // notch from the track the user chose. An app's media holds the
                // notch until it stops; then the page is welcome to it.
                //
                // Longer than `heldGrace` because the app is no longer being
                // *seen*: the system names one now-playing item, the page has
                // it, and the player is only sighted again through the
                // scripting fallback below. A minute without any sighting at
                // all is where this gives up.
                if now - held.at < Self.appHoldAgainstPage,
                   await stillPlaying(held.snapshot, at: now) {
                    return Self.projecting(held.snapshot, from: held.at, to: now)
                }
            } else if now - held.at < Self.heldGrace,
                      !corroborated(answered, heldBundleID: held.snapshot.appBundleID, at: now) {
                return Self.projecting(held.snapshot, from: held.at, to: now)
            }
        }
        challenger = nil
        defer { rememberIfPlaying(answered, at: now) }

        // The same player as before, or the first one we have seen: it holds
        // the seat for as long as it keeps playing.
        if incumbent == nil || incumbent?.bundleID == answered.appBundleID {
            incumbent = answered.isPlaying
                ? (answered.appBundleID, incumbent?.since ?? now)
                : nil
            return answered
        }

        // Someone else has the system's attention. If the player that was here
        // first is still going, it keeps the notch and the newcomer waits —
        // unless the newcomer is the thing the user has just started, which is
        // what two players sounding at once nearly always means.
        if let held = await fallback(at: now),
           held.isPlaying,
           held.appBundleID == incumbent?.bundleID {
            guard handsOver(from: held, to: answered, at: now) else { return held }
            Self.log.notice("now playing: \(answered.appBundleID, privacy: .public) took the notch from \(held.appBundleID, privacy: .public) — both playing")
        }

        incumbent = answered.isPlaying ? (answered.appBundleID, now) : nil
        return answered
    }

    /// Whether a newcomer that is playing should take the notch from an
    /// incumbent that is also still playing. The rule — and the reasons behind
    /// each half of it — is `CrossAppHandover`.
    private func handsOver(
        from held: NowPlayingSnapshot,
        to newcomer: NowPlayingSnapshot,
        at now: TimeInterval
    ) -> Bool {
        handover.handsOver(
            from: held.appBundleID,
            to: newcomer.appBundleID,
            newcomerIsPlaying: newcomer.isPlaying,
            at: now,
            isApp: { BrowserCatalogue.shared.isOpenableApp(bundleID: $0) }
        )
    }

    private var handover = CrossAppHandover()

    /// Whether a snapshot's media is allowed to appear at all.
    ///
    /// Injected rather than looked up: this type knows about *sources*, not
    /// about the user's website rules. It needs the answer because a page
    /// nobody can see must not hold the notch either — a hidden page kept as
    /// the incumbent delayed a native player's card by the length of the
    /// corroboration window, and the user would have seen nothing at all in
    /// the meantime.
    private let allowsMedia: @MainActor (NowPlayingSnapshot) -> Bool

    /// Whether this different item has been seen before, long enough ago to
    /// mean it is still there rather than passing through.
    private func corroborated(
        _ answered: NowPlayingSnapshot,
        heldBundleID: String,
        at now: TimeInterval
    ) -> Bool {
        // Only something that is playing may take the seat. Switching to a
        // paused tab names it repeatedly, which is corroboration of a sort and
        // still not a reason to hand the card over: nothing was pressed, and
        // the thing making sound is the other one.
        guard answered.isPlaying else {
            challenger = nil
            return false
        }
        // A page nobody can see has nothing to corroborate: letting it take
        // the seat would replace a visible card with no card at all.
        guard allowsMedia(answered) else {
            challenger = nil
            return false
        }
        // The player that holds the seat, changing its own track, is taken at
        // its word straight away.
        //
        // The churn corroboration exists for is web content — a browser
        // handing its now-playing slot between autoplaying videos, eighty
        // times in nine minutes — and it is still resisted here, including
        // when it comes from the browser already holding the seat. But an
        // application moving to its next track is not churn: when Spotify says
        // the track changed, the track changed.
        //
        // Measured cost of not drawing that line: pressing Next left the old
        // title, artwork and elapsed time on the card for two seconds while
        // the new song played underneath. That is the whole of the "compact
        // view is slow" report — the player announced the change in under a
        // tenth of a second and the card sat on it.
        //
        // Only the incumbent gets this. A *different* player arriving is a
        // handover, and handovers keep their own rules.
        if answered.appBundleID == heldBundleID,
           BrowserCatalogue.shared.isOpenableApp(bundleID: answered.appBundleID) {
            challenger = nil
            return true
        }
        if let challenger, challenger.trackKey == answered.trackKey {
            return now - challenger.at >= Self.challengerCorroboration
        }
        challenger = (answered.trackKey, now)
        return false
    }

    /// Whether the held track has played itself out, in which case whatever
    /// comes next is its successor rather than an interloper.
    ///
    /// Without this, the last seconds of every track were followed by up to
    /// fifteen seconds of the finished one still on screen while the next one
    /// played.
    static func hasFinished(
        _ snapshot: NowPlayingSnapshot,
        at now: TimeInterval,
        since: TimeInterval
    ) -> Bool {
        guard snapshot.duration > 0 else { return false }
        return snapshot.elapsed + max(0, now - since) >= snapshot.duration - 1
    }

    /// Whether the app that holds the notch is still actually playing.
    ///
    /// Asked of the scripting fallback, which is the one source that can see a
    /// player the system has stopped naming. Three answers:
    ///
    /// - it names this player and says playing: hold the notch;
    /// - it names this player and says paused: the user paused it, and the
    ///   page is welcome to the notch now;
    /// - it says nothing useful (no Automation permission, or a player it
    ///   cannot script): no information, so the hold stands until
    ///   `appHoldAgainstPage` runs out.
    private func stillPlaying(_ held: NowPlayingSnapshot, at now: TimeInterval) async -> Bool {
        guard let scripted = await fallback(at: now),
              scripted.appBundleID == held.appBundleID
        else { return true }
        return scripted.isPlaying
    }

    /// Keeps the last playing answer, which is what a paused newcomer is
    /// measured against. A pause of the *same* item replaces it, so pausing
    /// what you are watching is honoured immediately.
    private func rememberIfPlaying(_ snapshot: NowPlayingSnapshot, at now: TimeInterval) {
        if snapshot.isPlaying {
            // Only something that may actually appear is worth holding the
            // seat for.
            heldPlaying = allowsMedia(snapshot) ? (snapshot, now) : nil
        } else if heldPlaying?.snapshot.trackKey == snapshot.trackKey {
            heldPlaying = nil
        }
    }


    /// A held snapshot with its position moved forward, so the scrub bar keeps
    /// running while the system is looking somewhere else.
    private static func projecting(
        _ snapshot: NowPlayingSnapshot,
        from: TimeInterval,
        to now: TimeInterval
    ) -> NowPlayingSnapshot {
        var moved = snapshot
        var elapsed = snapshot.elapsed + max(0, now - from)
        if snapshot.duration > 0 { elapsed = min(elapsed, snapshot.duration) }
        moved.elapsed = elapsed
        return moved
    }

    // MARK: - The adapter named a player

    /// The adapter's answer, or — for a player AppleScript already handles —
    /// the path that is known-good for it, falling back to the adapter only if
    /// the app quit between the two questions.
    private func answer(_ fromAdapter: NowPlayingSnapshot, at now: TimeInterval) async -> NowPlayingSnapshot {
        let bundleID = fromAdapter.appBundleID
        guard scriptingHandles(bundleID) else {
            previousAdapter = nil
            return fromAdapter
        }

        // A position that is not where the last poll said it would be is a
        // seek — from the player's own scrub bar, a keyboard, another device.
        // Only comparable against the same player: a hand-over from Chrome to
        // Spotify is a different track altogether and re-scripts anyway.
        var seeked = false
        if let previous = previousAdapter, previous.bundleID == bundleID {
            let expected = previous.elapsed + (previous.isPlaying ? now - previous.at : 0)
            seeked = abs(fromAdapter.elapsed - expected) > Self.seekTolerance
        }
        previousAdapter = (bundleID, fromAdapter.elapsed, fromAdapter.isPlaying, now)

        if let entry = scriptedByPlayer[bundleID],
           !seeked,
           !mustRescript(entry, given: fromAdapter, at: now) {
            return withAdapterArtwork(project(entry, to: now), from: fromAdapter)
        }

        guard !Task.isCancelled else { return fromAdapter }
        if let scripted = await scriptedSnapshot(bundleID) {
            scriptedByPlayer[bundleID] = ScriptedEntry(
                snapshot: scripted,
                at: now,
                adapterTrackKey: fromAdapter.trackKey,
                adapterIsPlaying: fromAdapter.isPlaying
            )
            return withAdapterArtwork(scripted, from: fromAdapter)
        }

        // Nothing to cache: the player quit, or is not ours to script.
        scriptedByPlayer[bundleID] = nil
        return fromAdapter
    }

    private func mustRescript(_ entry: ScriptedEntry, given fromAdapter: NowPlayingSnapshot, at now: TimeInterval) -> Bool {
        if now < rescriptUntil { return true }
        if entry.adapterTrackKey != fromAdapter.trackKey { return true }
        if entry.adapterIsPlaying != fromAdapter.isPlaying { return true }
        // The burst reads after a command can catch the player's own state a
        // beat before it flips; a scripted "paused" cached against an adapter
        // that says playing would otherwise be trusted for the whole paused
        // cadence.
        if entry.snapshot.isPlaying != fromAdapter.isPlaying { return true }
        return now - entry.at >= Self.cadence(for: entry.snapshot)
    }

    /// The scripted answer moved forward to `now`. Rate 1 while playing, 0
    /// while paused — the same projection the adapter does for its own stream,
    /// and what keeps the scrub bar moving between real reads.
    private func project(_ entry: ScriptedEntry, to now: TimeInterval) -> NowPlayingSnapshot {
        var snapshot = entry.snapshot
        guard snapshot.isPlaying else { return snapshot }
        var elapsed = snapshot.elapsed + max(0, now - entry.at)
        if snapshot.duration > 0 { elapsed = min(elapsed, snapshot.duration) }
        snapshot.elapsed = elapsed
        return snapshot
    }

    /// Music's scripting dictionary exposes no artwork URL, so its scripted
    /// answer used to arrive with no cover at all — while the adapter, whose
    /// answer we had just declined, was holding the very bytes. Borrow them.
    /// The scripted `trackKey` stays, so the artwork cache is keyed exactly as
    /// before.
    private func withAdapterArtwork(_ scripted: NowPlayingSnapshot, from fromAdapter: NowPlayingSnapshot) -> NowPlayingSnapshot {
        guard scripted.artworkURL == nil,
              scripted.artworkData == nil,
              let data = fromAdapter.artworkData,
              !Self.contradict(scripted, fromAdapter)
        else { return scripted }
        var merged = scripted
        merged.artworkData = data
        merged.artworkID = fromAdapter.artworkID
        return merged
    }

    /// Whether two readings are plainly about different things.
    ///
    /// Asked before one of them lends the other its cover. The two sides are
    /// never in step for the moment after a skip — the script already names the
    /// new song while the adapter still names the old one — and borrowing
    /// across that gap produced exactly new metadata with the previous song's
    /// art, which then got cached under the new song and stayed.
    ///
    /// Not "are these the same item": their ids come from unrelated
    /// namespaces and would never match, so comparing them would refuse every
    /// borrow including the ones that are the whole point. The question that
    /// can be answered is the negative one — does the evidence *disagree* —
    /// and a field one side has not filled in is not disagreement. Where it
    /// does disagree, no cover at all is the honest answer.
    static func contradict(_ a: NowPlayingSnapshot, _ b: NowPlayingSnapshot) -> Bool {
        differ(a.title, b.title) || differ(a.artist, b.artist) || differ(a.album, b.album)
    }

    private static func differ(_ a: String, _ b: String) -> Bool {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.caseInsensitiveCompare(right) != .orderedSame
    }

    // MARK: - The adapter is silent or set aside

    /// The scripting source's own answer, cached: with no adapter to say what
    /// changed, only cadence and the players' notifications refresh it.
    private func fallback(at now: TimeInterval) async -> NowPlayingSnapshot? {
        if let cached = scriptedFallback,
           now >= rescriptUntil,
           now - cached.at < fallbackCadence(cached.snapshot) {
            guard let snapshot = cached.snapshot else { return nil }
            return project(
                ScriptedEntry(snapshot: snapshot, at: cached.at, adapterTrackKey: "", adapterIsPlaying: false),
                to: now
            )
        }
        guard !Task.isCancelled else { return nil }
        let fresh = await scripting.snapshot()
        scriptedFallback = (fresh, now)
        return fresh
    }

    private static func cadence(for snapshot: NowPlayingSnapshot?) -> TimeInterval {
        snapshot?.isPlaying == true ? scriptingCadenceWhilePlaying : scriptingCadenceWhilePaused
    }

    /// The cadence for the silent-adapter path. Nothing scripted is known to
    /// exist, and the adapter — which sees everything — has nothing either, so
    /// the question can be asked far less often. A demoted adapter is not
    /// healthy and keeps the ordinary cadence, since then AppleScript is the
    /// only source there is.
    private func fallbackCadence(_ cached: NowPlayingSnapshot?) -> TimeInterval {
        if isDemoted || !adapter.isAvailable { return Self.cadence(for: cached) }
        guard adapter.secondsSinceLastLine < Self.adapterLivelinessWindow else {
            return Self.cadence(for: cached)
        }
        guard cached == nil || cached?.isPlaying == false else {
            return Self.cadence(for: cached)
        }
        return Self.scriptingCadenceWhileAdapterIdle
    }

    // MARK: - Invalidation

    /// A transport command went out since the last poll: whatever AppleScript
    /// said before it is about to be wrong.
    private func noteTransportCommands(at now: TimeInterval) {
        let transport = lastTransportAt()
        guard transport != seenTransportAt else { return }
        seenTransportAt = transport
        rescriptUntil = max(rescriptUntil, now + Self.rescriptBurst)
    }

    private func playbackChanged() {
        rescriptUntil = max(rescriptUntil, now() + Self.rescriptBurst)
    }
}

/// One pass over the sources, and everybody waiting on its answer.
///
/// The waiter list is behind a lock rather than on the main actor on purpose.
/// A cancelled task's handler runs wherever the cancellation happened, and if
/// taking your name off the list costs a hop to the main actor then the queue
/// can still decide, in the meantime, to spawn an `osascript` for a caller who
/// has already gone. Under the lock the answer to "is anyone still waiting for
/// this?" is true at the moment it is asked.
///
/// A ticket is reserved before the caller suspends, so a pass always knows it
/// has someone waiting even in the turn between being chosen and being joined.
private final class ReadPass: @unchecked Sendable {

    typealias Waiter = CheckedContinuation<NowPlayingSnapshot?, Never>

    /// What a departing waiter left behind.
    enum Departure {
        /// Others are still waiting: the read goes on for them.
        case othersRemain
        /// That was the last one. Whatever this pass owns is now owed to
        /// nobody.
        case lastOneOut
    }

    private struct State {
        /// Tickets handed out and not yet answered — whether or not their
        /// caller has suspended yet.
        var waiting: Set<Int> = []
        var attached: [Int: Waiter] = [:]
        var nextTicket = 0
        /// The answer, once there is one. Doubly optional: the outer layer is
        /// "has this pass finished", the inner one "was anything playing".
        var answer: NowPlayingSnapshot??
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var hasWaiters: Bool { state.withLock { !$0.waiting.isEmpty } }

    var waiterCount: Int { state.withLock { $0.waiting.count } }

    /// Claims a place on this pass.
    func reserve() -> Int {
        state.withLock { s in
            let ticket = s.nextTicket
            s.nextTicket += 1
            s.waiting.insert(ticket)
            return ticket
        }
    }

    /// Hands over the continuation to resume when the pass is done — or
    /// straight away, if the pass finished or the caller gave up first.
    func attach(_ continuation: Waiter, to ticket: Int) {
        let answerNow = state.withLock { s -> NowPlayingSnapshot?? in
            if let answer = s.answer {
                s.waiting.remove(ticket)
                return .some(answer)
            }
            guard s.waiting.contains(ticket) else { return .some(nil) }
            s.attached[ticket] = continuation
            return nil
        }
        if let answerNow { continuation.resume(returning: answerNow) }
    }

    /// Takes one waiter off the pass, answering it with nothing.
    @discardableResult
    func leave(_ ticket: Int) -> Departure {
        let (continuation, remaining) = state.withLock { s -> (Waiter?, Bool) in
            s.waiting.remove(ticket)
            return (s.attached.removeValue(forKey: ticket), !s.waiting.isEmpty)
        }
        continuation?.resume(returning: nil)
        return remaining ? .othersRemain : .lastOneOut
    }

    /// The pass is over. Everyone still waiting gets the same answer, and
    /// anyone who joins afterwards gets it immediately rather than hanging.
    func finish(with answer: NowPlayingSnapshot?) {
        let waiters = state.withLock { s -> [Waiter] in
            s.answer = .some(answer)
            s.waiting.removeAll()
            defer { s.attached.removeAll() }
            return Array(s.attached.values)
        }
        for waiter in waiters { waiter.resume(returning: answer) }
    }
}
