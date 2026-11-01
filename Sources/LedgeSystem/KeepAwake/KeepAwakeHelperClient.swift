import Foundation
import LedgeHelperKit

/// What the daemon last said about this Mac.
///
/// `foreign` and `armed` are not fields the daemon sends; they are questions
/// the app asks of the fields it does send, and deriving them here keeps the
/// two definitions from drifting apart in a card and a settings pane.
public struct KeepAwakeHelperStatus: Sendable, Equatable {

    /// The daemon's launchd label, which is what tells the debug daemon from
    /// the release one.
    public let build: String
    /// The last reading of the setting, or -1 if the daemon has not read one.
    public let sleepDisabled: Int
    /// Ledge holds the claim that explains a reading of 1.
    public let ours: Bool
    /// No outstanding claim of this daemon's label, and nothing in flight.
    public let clean: Bool
    /// A claim of ours whose restoration has not been confirmed.
    public let cleanupPending: Bool
    /// The other build's daemon holds a live claim.
    public let otherLedgeHolds: Bool
    /// A Low Power Mode claim of ours is outstanding. Always false until 2b.
    public let lowPowerClaimed: Bool

    public init(build: String, sleepDisabled: Int, ours: Bool, clean: Bool,
                cleanupPending: Bool, otherLedgeHolds: Bool, lowPowerClaimed: Bool) {
        self.build = build
        self.sleepDisabled = sleepDisabled
        self.ours = ours
        self.clean = clean
        self.cleanupPending = cleanupPending
        self.otherLedgeHolds = otherLedgeHolds
        self.lowPowerClaimed = lowPowerClaimed
    }

    /// Sleep is disabled and nothing Ledge knows about explains it. The daemon
    /// will not touch it in this state and neither should the app: somebody
    /// else — Insomnia, Amphetamine, a `pmset` run by hand — set it, and
    /// taking it back would be Ledge undoing a choice it did not make.
    public var isForeign: Bool { sleepDisabled == 1 && !ours && !otherLedgeHolds }

    /// The lid-closed hold is live *and the Mac is actually held*.
    ///
    /// Not simply `ours`. A claim is journalled before the privileged write
    /// and says "Ledge may have changed this", so `ours` is true from the
    /// moment the daemon writes the record — including when the `pmset` that
    /// followed it was refused. Reading armed off the claim alone had the card
    /// telling the user their Mac was being held awake while the setting read
    /// 0 and the daemon was still retrying.
    public var isArmed: Bool { ours && sleepDisabled == 1 }

    /// Whether the daemon may be unregistered. `cleanupPending` is the reason
    /// this is not simply `clean`: a claim still waiting to be put back needs
    /// the daemon alive to put it back.
    public var mayUnregister: Bool { clean && !cleanupPending }
}

/// The daemon, as the app is allowed to see it.
///
/// A protocol rather than `NSXPCConnection` in the open, because every
/// interesting thing this client does is a response to the daemon being slow,
/// absent, or disagreeing, and a real connection cannot be made to do those
/// things on demand.
public protocol KeepAwakeHelperLink: Sendable {
    func status() async throws -> KeepAwakeHelperStatus
    func hold(session: String, generation: Int, until deadline: Date?,
              leaseSeconds: Double) async throws -> KeepAwakeHelperCode
    func release(session: String, generation: Int) async throws -> KeepAwakeHelperCode
    func setLowPowerMode(_ on: Bool, session: String,
                         generation: Int) async throws -> KeepAwakeHelperCode
}

/// Why the lid-closed hold is not simply on.
public enum KeepAwakeHelperTrouble: Sendable, Equatable {
    /// The daemon did not answer in time. Says nothing about whether the hold
    /// still stands — see `KeepAwakeHelperClient.temporarilyUnavailable`.
    case silent
    /// The daemon answered, and the answer was not `ok`.
    case refused(KeepAwakeHelperCode)
}

/// What the app shows for the lid-closed hold.
public enum KeepAwakeHelperState: Sendable, Equatable {
    /// Nothing is held and nothing is being attempted.
    case idle
    /// The daemon has taken the hold, the heartbeat is current, and the
    /// daemon says the setting is in force.
    case holding
    /// The lease is taken and the hold is not yet confirmed.
    ///
    /// Its own state because the daemon answers a hold once the lease is on
    /// disk and *before* it runs the privileged write — the ordering is
    /// deliberate, since a lease the file does not have is a hold nobody else
    /// can see the end of. So `ok` is an acceptance, not a confirmation, and
    /// everything between it and the readback belongs here.
    case pending
    /// The daemon has stopped answering a hold it had already accepted. The
    /// hold is probably still standing — the daemon drops it on its own
    /// lease, not on our silence — so this is a warning, not a death. The
    /// heartbeat keeps going.
    case temporarilyUnavailable
    /// A hold that got through and that nothing can now vouch for.
    ///
    /// Accepted and never confirmed, or confirmed longer ago than the lease
    /// it stands on. Deliberately neither of its neighbours: the daemon may
    /// be holding this Mac on a renewal whose reply was lost, and it may have
    /// let go an hour ago. `temporarilyUnavailable` claims the first,
    /// `unreachable` claims the second, and both were being said about a
    /// state that is neither.
    case unknownWhetherHeld
    /// The daemon has never answered at all, so nothing was ever held.
    ///
    /// The same silence as `temporarilyUnavailable` and the opposite fact.
    /// Read as that one, the card said the hold almost certainly still stood
    /// and the menu bar put up its badge — and somebody shut their lid on a
    /// Mac nothing was holding. There is no lease to outlive here, because
    /// there was never a hold.
    case unreachable
    /// The daemon answered and said no.
    case refused(KeepAwakeHelperCode)
    /// The daemon is the copy from before an update, and the client is
    /// waiting for it to make way for the new one.
    ///
    /// Not silence, and not a refusal. Every answer it sends fails the app's
    /// code signing check at once, so nothing it says can be heard — while
    /// everything the app sends it still lands. The hold has been given back
    /// and nothing is sent until it has had time to exit, so this is never a
    /// hold, whatever the last reading said.
    case handingOver
    /// The handover was tried and the old copy is still the one answering.
    ///
    /// A restart is the one thing sure to replace it, so that is what the
    /// card says. The client still asks once every few minutes, because the
    /// old copy can yet get clean and exit, and the first answer that comes
    /// through ends this by itself.
    case restartNeeded
    /// Every answer is refused, and the helper installed in this copy of
    /// Ledge would be refused too.
    ///
    /// Not a stale process, so not a handover. A restart starts the same
    /// helper again and changes nothing, and the release a handover begins
    /// with would only take away a hold that is very probably standing:
    /// everything the app sends still lands. So nothing is given back, the
    /// heartbeat goes on, and the card asks for a reinstall. Never a hold,
    /// because nothing can confirm one.
    case helperMismatch
}

/// Whether the helper inside this copy of Ledge passes the check its answers
/// are held to.
///
/// Asked once, on the first refused answer, to tell the two causes of a
/// refusal apart. A copy on disk that passes leaves one explanation: the
/// process answering was started from a bundle that has since been replaced.
/// A copy that fails means the installation itself is wrong.
public enum KeepAwakeInstalledHelper: Sendable, Equatable {
    case passes
    case fails
    /// The check could not be made — no file there, a requirement that would
    /// not compile. Treated as `passes`: the handover is the rescue the field
    /// needs, and a check that could not run is no evidence against it.
    case unchecked
}

/// Keeps one lid-closed hold alive.
///
/// The whole of this type is the difference between "we asked" and "it is
/// still true". A hold is a lease: the daemon drops it 90 s after the last
/// heartbeat it managed to write down, whatever the app believes, and whatever
/// the app believes is the thing most likely to be wrong — the app may have
/// been suspended, the Mac may have slept, the daemon may have been restarted
/// underneath us. So nothing here reasons from what was asked for. Every
/// decision comes from what the daemon last answered.
public actor KeepAwakeHelperClient {

    /// How often the hold is renewed. A third of the lease, so two heartbeats
    /// can be lost entirely before anything is at risk.
    public static let heartbeat: TimeInterval = 30
    /// The lease asked for. The daemon clamps this to 30–120 s; 90 is chosen
    /// inside that range rather than at its edge so a clamp is never a
    /// surprise.
    public static let lease: TimeInterval = 90

    /// How long silence is read as "very probably still held".
    ///
    /// The lease the daemon goes by, and nothing more generous. A hold is
    /// renewed every heartbeat; if nothing has been accepted for a whole
    /// lease, the daemon has either let go or is not there, and either way
    /// the Mac is not being held by anything we can point to.
    static var confidenceWindow: TimeInterval { lease }
    /// How long to wait for one call.
    ///
    /// Deliberately longer than the heartbeat interval. The daemon answers a
    /// renewal only once it is on disk, and that write may queue behind a
    /// `pmset` transaction holding the lock, so a reply can honestly take ~20 s
    /// — treating that as failure would turn a healthy slow daemon into a
    /// reported outage. Shorter than the lease, so a daemon that has genuinely
    /// stopped answering is noticed with time left to do something about it.
    public static let callTimeout: TimeInterval = 45

    /// How long the client says nothing at all while an out-of-date daemon
    /// lets go.
    ///
    /// The old daemon cannot be told to exit — it is code already on the
    /// user's Mac — and its own rule is the only way out: clean, nobody
    /// connected, and quiet for `idleExitAfter`, asked every `idleCheckEvery`.
    /// So the worst case is the two added together, from the last word the
    /// app said. The margin is for launchd reaping it and for the restore the
    /// release set off, which has to finish before the daemon counts as
    /// clean.
    ///
    /// Read from the daemon's own constants rather than written down here a
    /// second time. Those are pinned by a test, because the daemon being
    /// waited out was built before this one.
    ///
    /// It stays this long while helpers without the replaced-bundle check
    /// are still installed. A helper built with that check leaves within
    /// seconds of its restore, but the app cannot tell which kind is
    /// answering until one of them is heard — and a question asked early of
    /// an old one resets its idle clock and costs another whole round. Once
    /// every installed helper has the check, this can shrink to a few
    /// seconds.
    ///
    /// Counted on a clock that stops while the Mac sleeps, as the daemon's
    /// own idle tick does. See `sleepWhileAwake`.
    public static var handoverSilence: TimeInterval {
        HelperLimits.idleExitAfter + HelperLimits.idleCheckEvery + handoverMargin
    }
    static let handoverMargin: TimeInterval = 10
    /// How many silences before saying a restart is needed. The second
    /// covers a restore that took longer than the margin.
    static let handoverRounds = 2
    /// How often the client asks again once a restart is needed.
    ///
    /// Longer than `handoverSilence` on purpose. Each question resets the old
    /// daemon's idle clock, and only a gap longer than its whole exit rule
    /// lets that rule fire between two questions. The link drops every
    /// refused connection at once, so the gap really is a gap.
    static let restartProbeEvery: TimeInterval = 5 * 60

    /// The silence's own sleep: on the clock that stops while the Mac sleeps.
    ///
    /// The daemon being waited out ticks on uptime. A silence counted on the
    /// continuous clock — which is what `Task.sleep(for:)` uses — runs down
    /// while the lid is shut, which is the natural thing to do right after
    /// clicking Install, and the first question on waking reaches an old
    /// daemon that has not ticked once since. Two of those in a row would
    /// read as "restart needed" over a helper that would have left by itself
    /// a minute later.
    public static let sleepWhileAwake: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(for: .seconds($0), clock: .suspending)
    }

    private let link: KeepAwakeHelperLink
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// The handover's waits, apart from the heartbeat's and the timeouts'.
    /// Those are about the app's own clock; this one is about the daemon's.
    private let silence: @Sendable (TimeInterval) async throws -> Void
    /// Whether the helper inside this copy of Ledge would pass the check its
    /// answers fail. Asked at most once, on the first refusal.
    private let installedHelper: @Sendable () -> KeepAwakeInstalledHelper

    /// The session being held, and the generation it is being held under.
    ///
    /// The generation exists because a lease can lapse without anybody
    /// noticing at the time: the Mac sleeps, the app is suspended, the daemon
    /// restarts. When it does, the daemon retires that generation, and a
    /// heartbeat still carrying it is answered `stale` on purpose. Carrying on
    /// with the same number would retry a request the daemon has already
    /// decided about, forever.
    /// Whether this session has ever had a hold accepted.
    ///
    /// The difference between "we cannot reach the daemon that is holding
    /// this Mac" and "we have never reached it at all" — the same silence,
    /// opposite facts, and only one of them is survivable.
    /// A `begin` the daemon answered with ok.
    ///
    /// Acceptance, which is not application: the daemon writes its lease and
    /// answers, and runs the privileged write after. So this says a request
    /// got through and says nothing about the Mac.
    private var everAccepted = false
    /// When the daemon last told us the setting was actually on.
    ///
    /// The only thing that ever justified "the hold almost certainly still
    /// stands". Acceptance was standing in for it, so a hold that was
    /// accepted and never applied — status reporting SleepDisabled=0, the
    /// renewal then failing — read as very probably holding a Mac that
    /// nothing was holding.
    private var lastConfirmed: Date?
    /// When the daemon last told us the setting was *not* on.
    ///
    /// Negative evidence, kept beside the positive and compared by age. A
    /// status reporting the setting off did not clear the older confirmation
    /// it contradicted, so a renewal that then went unanswered produced "it
    /// almost certainly still stands" out of evidence a newer reading had
    /// already refuted.
    private var lastDenied: Date?
    /// Whether a request has ever gone out for this session at all.
    ///
    /// Not the same as one having been accepted. The daemon can take a lease
    /// and lose the reply, so a first request that was never answered is an
    /// unknown outcome — and reading it as "nothing is being held" put a
    /// sentence on the card promising that shutting the lid would sleep the
    /// Mac, over a Mac that was being held.
    private var everIssued = false
    /// When the daemon last said yes.
    ///
    /// `everHeld` alone says a hold was once accepted and never says how long
    /// ago. Silence was therefore read as "very probably still standing" for
    /// ever, including long past the lease the daemon itself goes by — so a
    /// daemon that died an hour ago still read as almost certainly holding
    /// this Mac. The lease is the only thing that was ever keeping it awake,
    /// and once it has run out, saying so is not pessimism.


    /// What silence means, given how long it has lasted.
    ///
    /// Three answers, not two. Never accepted: nothing is held, and saying
    /// otherwise is the worst thing this file can do. Accepted recently: the
    /// daemon lets go on its own lease rather than on our inability to reach
    /// it, so the hold is very likely standing and the next heartbeat may
    /// well land. Accepted, but longer ago than the lease: the lease it was
    /// standing on has run out, and `stale` is the sentence that says so and
    /// says what to do about it.
    private func silenceReading() -> KeepAwakeHelperState {
        // Nothing was ever even sent: there is nothing for the daemon to be
        // holding, and saying otherwise is the worst thing this file can do.
        guard everIssued else { return .unreachable }
        return confidence()
    }

    /// What the newest evidence supports, as of now.
    ///
    /// Asked at every reading rather than computed once when a call came
    /// back. Confidence that only expired when the *next* request finished
    /// meant a client whose daemon had gone away kept answering "almost
    /// certainly still stands" for as long as nothing else happened — and
    /// nothing else happening is exactly the case.
    private func confidence() -> KeepAwakeHelperState {
        guard let confirmed = lastConfirmed else { return .unknownWhetherHeld }
        // Newest wins. A status that reported the setting off is a fact about
        // a later moment than the confirmation before it.
        if let denied = lastDenied, denied >= confirmed { return .unknownWhetherHeld }
        guard now().timeIntervalSince(confirmed) <= Self.confidenceWindow else {
            return .unknownWhetherHeld
        }
        // Confirmed inside the lease it stands on: the daemon lets go on its
        // own lease rather than on our inability to reach it, so the hold is
        // very likely standing and the next heartbeat may well land.
        return .temporarilyUnavailable
    }

    private var session: String?
    private var generation = 0
    private var deadline: Date?

    /// Bumped by every `begin` and every `end`.
    ///
    /// Every await in this type is a place the session can change underneath
    /// the thing that is waiting, and each of those was a way to lose a hold:
    /// an `end` during the first pending hold saw generation 0, sent no
    /// release and forgot — and then the hold's own late reply set `holding`
    /// and started the heartbeat again, for a session nobody was running.
    /// Nothing may write state it was told to produce for an era that is over.
    private var lifecycle = 0

    /// The highest generation actually *sent*, as opposed to acknowledged.
    ///
    /// A release has to name something the daemon will recognise, and a hold
    /// still in flight has already told the daemon a number this client had
    /// not yet heard back about. Releasing with the acknowledged generation
    /// left that one outstanding.
    private var issuedGeneration = 0

    /// What the app last asked Low Power Mode to be, or nil if it never has.
    ///
    /// Re-sent after every renewal rather than once, for the same reason the
    /// hold itself is a lease: the daemon may have restarted since, and a
    /// daemon that has restarted remembers nothing anybody asked it. A want
    /// stated once would be a Mac that quietly came off Low Power Mode in the
    /// middle of a session and nothing that could notice.
    ///
    /// It also keeps the generation current. The daemon refuses a request
    /// carrying a generation it has retired, and every heartbeat retires the
    /// one before it, so a request sent once would be answered `stale` within
    /// thirty seconds of being sent.
    private var lowPowerWanted: Bool?

    private var beat: Task<Void, Never>?
    private var state: KeepAwakeHelperState = .idle

    /// The handover under way, if there is one, including the slow questions
    /// asked once a restart is needed.
    ///
    /// While it runs the client sends nothing on anybody's behalf: no
    /// heartbeat, no status, no Low Power Mode, no hold for a session that
    /// began in the meantime. Each of those would reach the old daemon,
    /// reset its idle clock, and keep it alive for another two minutes.
    private var handover: Task<Void, Never>?
    /// Both silences ended on the old copy. The handover goes on asking, far
    /// less often, and the card says a restart is needed meanwhile.
    private var needsRestart = false

    /// What the client must say while it is keeping quiet, or nil when it is
    /// free to talk.
    private var quiet: KeepAwakeHelperState? {
        guard handover != nil else { return nil }
        return needsRestart ? .restartNeeded : .handingOver
    }

    /// What the helper on disk last said, and when it was asked.
    ///
    /// A pass is kept: nothing about an installation that checked out is
    /// going to start failing in a way a handover gets wrong. A fail is not
    /// kept, because a fail is also what a helper reads as while it is being
    /// written — Finder's Replace, `ditto`, an installer copying over the
    /// app in place — and the copy finishing a second later leaves exactly
    /// the stale process the handover exists for. Pinned, that one read said
    /// "reinstall" until Ledge was relaunched, through the reinstall itself,
    /// while the heartbeat kept the stale helper alive.
    private var installedVerdict: KeepAwakeInstalledHelper?
    private var installedCheckedAt: Date?
    /// How old a fail may be before a refusal asks the disk again.
    ///
    /// Under the heartbeat, so every renewal a mismatched helper refuses
    /// looks again and a finished copy is noticed within one beat. Over a
    /// burst, so several refusals arriving together hash the file once. The
    /// check reads one small binary and is cheap at that rate; it only runs
    /// while answers are being refused.
    static let installedRecheckAfter: TimeInterval = 15
    /// Every answer is refused and the installed helper would be too.
    ///
    /// A flag laid over the state rather than a state of its own, because
    /// nothing about the client's ordinary bookkeeping stops: the heartbeat
    /// goes on landing, and its silence is read exactly as before underneath.
    /// The first answer that is heard takes the flag off.
    private var mismatched = false

    /// The last thing the daemon actually said, if it has said anything.
    private var lastStatus: KeepAwakeHelperStatus?

    /// - Parameters:
    ///   - silence: the handover's waits. Defaults to a sleep that stops
    ///     while the Mac sleeps, like the daemon's idle tick.
    ///   - installedHelper: whether the helper inside this copy of Ledge
    ///     passes the check its answers are held to. Defaults to `.passes`,
    ///     which is what every refusal was taken to mean before the check
    ///     existed; the app passes the real one.
    public init(link: KeepAwakeHelperLink,
                now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(for: .seconds($0))
                },
                silence: @escaping @Sendable (TimeInterval) async throws -> Void
                    = KeepAwakeHelperClient.sleepWhileAwake,
                installedHelper: @escaping @Sendable () -> KeepAwakeInstalledHelper = { .passes }) {
        self.link = link
        self.now = now
        self.sleep = sleep
        self.silence = silence
        self.installedHelper = installedHelper
    }

    /// What this client believes, as of being asked.
    ///
    /// Derived rather than stored for the one state whose truth is a function
    /// of the clock. A reassurance that only expired when the *next* request
    /// finished stood for ever on a client whose daemon had gone away —
    /// nothing else happening is exactly the case it is supposed to cover.
    ///
    /// The handover and a mismatched helper are laid over whatever is stored:
    /// both say nothing the daemon answers can be heard, and that outranks
    /// any reading taken from it.
    public var currentState: KeepAwakeHelperState {
        if let quiet { return quiet }
        if mismatched { return .helperMismatch }
        guard state == .temporarilyUnavailable else { return state }
        return confidence()
    }
    public var status: KeepAwakeHelperStatus? { lastStatus }

    /// Takes the hold and starts renewing it.
    ///
    /// `until` is fixed by this first call and can never be pushed out again —
    /// not by a later call, not by this session resuming. Passing nil asks for
    /// a hold bounded only by the lease, which is what the switch wants: it
    /// ends when the user ends it, and if Ledge dies the lease ends it instead.
    @discardableResult
    public func begin(session id: String, until wanted: Date? = nil) async -> KeepAwakeHelperState {
        lifecycle += 1
        let era = lifecycle
        if session != id {
            session = id
            deadline = wanted
            generation = 0
            issuedGeneration = 0
            lowPowerWanted = nil
        }
        // Remembered and not sent. The handover holds this session itself
        // once the new daemon answers, and a hold sent now would reach the
        // old one and keep it alive.
        if let quiet { return quiet }
        _ = await renew()
        // A `begin` that was overtaken by an `end`, or by another `begin`, has
        // nothing left to start a heartbeat for.
        guard lifecycle == era else { return currentState }
        startBeating()
        // The state as anybody else would read it now, not the bare outcome:
        // a refusal from a mismatched helper is laid over a renewal that
        // otherwise reads as silence, and returning the silence would tell
        // the card "can't tell" instead of what to do.
        return currentState
    }

    /// Gives the hold back.
    ///
    /// A release is never refused and never queued by the daemon — everything
    /// about one moves the Mac towards being allowed to sleep again, so there
    /// is no state in which refusing it is the safer answer. The heartbeat
    /// stops first: a renewal landing after the release would take the hold
    /// straight back.
    /// - Parameter session: the session giving the hold back, or nil for
    ///   whatever is held. A named end that does not match the session now
    ///   running does nothing at all: a provider on its way out can be
    ///   delayed past the point where its replacement has taken a hold, and
    ///   releasing then would end the live one.
    public func end(session named: String? = nil) async {
        if let named, session != named { return }
        stopBeating()
        lifecycle += 1
        // Forgotten *before* the await, not after. Forgetting afterwards meant
        // a `begin` that arrived in the middle was wiped out by the completion
        // of the end that preceded it — a live session with no client state
        // behind it and no release ever sent for it.
        let id = session
        let sent = issuedGeneration
        forget()

        // Nothing to send while a handover runs. Its own release went out
        // when it began and nothing has been held since, so a second one
        // would only reset the old daemon's idle clock.
        guard quiet == nil else { return }
        // `issuedGeneration`, not `generation`: a hold still in flight has
        // already named a number to the daemon, and releasing the one this
        // client had heard back about would leave that one holding the Mac.
        guard let id, sent > 0 else { return }
        do {
            _ = try await withTimeout { [link] in
                try await link.release(session: id, generation: sent)
            }
        } catch is KeepAwakeHelperOutOfDate {
            // The release landed. Its answer is the news that nothing the
            // daemon says can be heard, and that is still worth acting on
            // with no session left: the next reading would otherwise say
            // "off" over a daemon nothing can be heard from.
            heardRefusal()
        } catch {}
    }

    /// Asks for Low Power Mode, or gives it back.
    ///
    /// The agents this is for are network-bound, so the throttle costs them
    /// almost nothing and the battery saving is real. That is the trade, and
    /// it is the only reason to slow down a Mac nobody is watching.
    ///
    /// `false` does not mean "turn it off". It means "Ledge is finished with
    /// it", and the daemon puts the setting back to the value it journalled
    /// before it touched anything — which for a user who had Low Power Mode
    /// on, or on for battery only, is not off at all.
    ///
    /// - Returns: what the daemon answered, or nil if it did not. Nil is not
    ///   failure: the request is remembered and goes again with the next
    ///   heartbeat, and the daemon's own lease puts the setting back if this
    ///   app never manages to say another word.
    @discardableResult
    public func setLowPowerMode(_ on: Bool) async -> KeepAwakeHelperCode? {
        lowPowerWanted = on
        return await pushLowPower()
    }

    /// Sends the standing want, if there is one and there is a hold to hang
    /// it on.
    /// The answer is discarded at two of the three call sites on purpose: the
    /// want is re-sent with every heartbeat, so a refusal here is a thing to
    /// try again in thirty seconds rather than a thing to report. Marked
    /// rather than left to a warning, so the discard reads as a decision.
    @discardableResult
    private func pushLowPower() async -> KeepAwakeHelperCode? {
        // Kept, not sent. The re-hold at the end of a handover pushes it
        // again behind the new hold, like every renewal does.
        guard quiet == nil else { return nil }
        guard let id = session, let on = lowPowerWanted, generation > 0 else { return nil }
        do {
            return try await withTimeout { [link, generation] in
                try await link.setLowPowerMode(on, session: id, generation: generation)
            }
        } catch is KeepAwakeHelperOutOfDate {
            heardRefusal()
            return nil
        } catch {
            return nil
        }
    }

    /// Asks the daemon what it believes, without changing anything.
    ///
    /// A status call never spawns anything and is answered from the daemon's
    /// memory, so this is cheap enough to drive a settings pane.
    @discardableResult
    public func refreshStatus() async -> KeepAwakeHelperStatus? {
        // Not asked during a handover. A status call is the cheapest thing
        // this client sends and still enough to keep the old daemon alive,
        // and the card reads the handover from `currentState` regardless.
        guard quiet == nil else { return nil }
        // Whose observation this is, taken before the call. A status held in
        // flight while its session ended and another began came back and
        // filed itself as the *new* session's evidence, so B read as
        // "almost certainly still stands" on the strength of something only
        // ever true of A.
        let era = lifecycle
        let id = session
        let answer: KeepAwakeHelperStatus?
        do {
            answer = try await withTimeout { [link] in try await link.status() }
        } catch is KeepAwakeHelperOutOfDate {
            // Not dropped with the rest. This was a `try?`, so a daemon that
            // refused every answer at once looked exactly like one that had
            // timed out — and with no session that read as "off", offering a
            // mode nothing could confirm.
            heardRefusal()
            return nil
        } catch {
            answer = nil
        }
        guard let answer else { return nil }
        guard lifecycle == era, session == id else { return answer }
        lastStatus = answer
        // Through the same bookkeeping as every other observation. This
        // cached the status and nothing else, so the card could ask for a
        // fresh reading, be told the setting was off, and go on saying the
        // hold almost certainly still stood.
        record(armed: answer.isArmed)
        return answer
    }

    /// Files an observation of whether the Mac is actually held.
    ///
    /// One place, so positive and negative evidence are always comparable by
    /// age. Scattered, the negative kind was simply dropped.
    private func record(armed: Bool) {
        guard session != nil else { return }
        if armed {
            lastConfirmed = now()
            // Reconciled, not merely filed. Evidence that only changed what a
            // *later* silence would conclude left the card saying Checking
            // over a hold a fresh reading had just confirmed.
            if state == .pending || state == .temporarilyUnavailable
                || state == .unknownWhetherHeld {
                state = .holding
            }
        } else {
            lastDenied = now()
            // And the other way: a reading that says the setting is off must
            // take the card off `holding` now, not at the next heartbeat.
            if state == .holding { state = .pending }
        }
    }

    // MARK: - The heartbeat

    private func startBeating() {
        guard beat == nil else { return }
        beat = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.pause(Self.heartbeat) } catch { return }
                guard !Task.isCancelled else { return }
                await self.beatOnce()
            }
        }
    }

    private func stopBeating() {
        beat?.cancel()
        beat = nil
    }

    private func pause(_ seconds: TimeInterval) async throws {
        try await sleep(seconds)
    }

    private func beatOnce() async {
        guard session != nil, quiet == nil else { return }
        _ = await renew()
    }

    /// One hold, and what its answer means.
    @discardableResult
    private func renew() async -> KeepAwakeHelperState {
        guard let id = session else { return .idle }
        let era = lifecycle

        // Never backwards, and never reused across a gap: the daemon has
        // retired any generation whose lease it has already let go.
        let attempt = generation + 1
        issuedGeneration = max(issuedGeneration, attempt)
        // Recorded before the call, not after it. What makes an outcome
        // unknown rather than absent is that the request left the building.
        everIssued = true
        let asked = deadline

        let answer: KeepAwakeHelperCode?
        do {
            answer = try await withTimeout { [link] in
                try await link.hold(session: id, generation: attempt,
                                    until: asked, leaseSeconds: Self.lease)
            }
        } catch is KeepAwakeHelperOutOfDate {
            // Before the era check, not after it. The refusal is a fact about
            // the daemon rather than about this session, and the hold it
            // refused to answer has landed all the same — `issuedGeneration`
            // already names it, so a handover's release covers it whoever is
            // running by then.
            //
            // Then read like any unanswered call. A handover has moved the
            // era on, so the check below writes nothing; a mismatched helper
            // has not, and its renewal is exactly what silence is: sent,
            // probably taken, not heard.
            heardRefusal()
            answer = nil
        } catch {
            answer = nil
        }

        // The session can have ended, or been replaced, while this was out.
        // Anything decided for an era that is over is decided about nothing.
        guard lifecycle == era, session == id else { return state }

        guard let answer else {
            // Silence after a hold that was once accepted is not death: the
            // daemon lets go on its own lease, not on our inability to reach
            // it, so the hold is very likely still standing and the next
            // heartbeat may well land. Keep the generation — nothing has told
            // us it was retired.
            //
            // Silence before any hold was ever accepted is the opposite fact,
            // and reading it the same way was the worst bug in this file.
            state = silenceReading()
            return state
        }

        generation = attempt

        switch answer {
        case .ok:
            // The first acceptance this session has had. Until now there was
            // nothing to be uncertain *about*.
            everAccepted = true
            let settled = await confirm(era: era, session: id)
            // Behind the hold, never instead of it, and only once the hold
            // has been answered: the daemon refuses a Low Power Mode request
            // from a session that is not the one holding this Mac, so there
            // is no point asking before it has agreed who that is.
            await pushLowPower()
            // Re-checked *here*, at the assignment, and not only before the
            // awaits that produced it. An end during either of them leaves a
            // perfectly good answer about a session that no longer exists,
            // and writing it to the shared state brings that session back.
            guard lifecycle == era, session == id else { return state }
            state = settled
        case .stale:
            let settled = await resynchronise(era: era, session: id, from: attempt)
            guard lifecycle == era, session == id else { return state }
            state = settled
        default:
            guard lifecycle == era, session == id else { return state }
            state = .refused(answer)
        }
        return state
    }

    /// Whether the Mac is actually held, as opposed to the lease being taken.
    ///
    /// `ok` means the lease is on disk. The daemon then runs the privileged
    /// write and reads it back, and that can fail — a refused `pmset` still
    /// leaves an `ok` behind it. One extra call, answered from the daemon's
    /// memory without spawning anything, is the difference between a card that
    /// says the Mac is held and a card that is right.
    private func confirm(era: Int, session id: String) async -> KeepAwakeHelperState {
        let status: KeepAwakeHelperStatus?
        do {
            status = try await withTimeout { [link] in try await link.status() }
        } catch is KeepAwakeHelperOutOfDate {
            // Read as no answer, like the renewal's refusal: the era check
            // stops a handover's, and a mismatch is an unconfirmed acceptance.
            heardRefusal()
            status = nil
        } catch {
            status = nil
        }
        guard lifecycle == era, session == id else { return state }
        guard let status else { return .pending }
        lastStatus = status
        record(armed: status.isArmed)
        return status.isArmed ? .holding : .pending
    }

    /// How many doublings a catch-up may take before it gives up for this beat.
    static let staleCatchUpAttempts = 14

    /// Finds a generation the daemon will take, now rather than over an hour.
    ///
    /// A relaunched app starts counting at one while the daemon still holds
    /// the generation the previous run reached — a session recovered at 100
    /// would spend fifty minutes being refused at one step per heartbeat, and
    /// reconnecting that often keeps the daemon alive to go on refusing. A
    /// `stale` answer costs the daemon nothing, being decided from memory
    /// without a transaction, so the catch-up doubles its way up here instead
    /// of creeping over the next hour. Fourteen doublings reach past any
    /// generation a real session could have produced.
    private func resynchronise(era: Int, session id: String,
                               from refused: Int) async -> KeepAwakeHelperState {
        var jump = 1
        for _ in 0..<Self.staleCatchUpAttempts {
            jump *= 2
            let attempt = refused + jump
            issuedGeneration = max(issuedGeneration, attempt)
            everIssued = true

            let answer: KeepAwakeHelperCode?
            do {
                answer = try await withTimeout { [link] in
                    try await link.hold(session: id, generation: attempt,
                                        until: self.deadline, leaseSeconds: Self.lease)
                }
            } catch is KeepAwakeHelperOutOfDate {
                heardRefusal()
                answer = nil
            } catch {
                answer = nil
            }
            guard lifecycle == era, session == id else { return state }
            // The same bookkeeping as an ordinary renewal. Catching up used
            // to answer `temporarilyUnavailable` whatever had happened, which
            // put the reassuring sentence over a Mac that had never accepted
            // anything — and its successes never recorded themselves, so the
            // silence right after a confirmed catch-up read as nothing held.
            guard let answer else { return silenceReading() }

            generation = attempt
            switch answer {
            case .ok:
                everAccepted = true
                let settled = await confirm(era: era, session: id)
                await pushLowPower()
                // The catch-up's own awaits are as long as any other, and an
                // end during the Low Power Mode push used to come back as a
                // confirmed hold for a session that had already gone.
                guard lifecycle == era, session == id else { return state }
                return settled
            case .stale:
                continue
            default:
                return .refused(answer)
            }
        }
        // Still refused after every doubling. The next heartbeat tries again
        // from here, which is already far above where it started.
        return .refused(.stale)
    }

    private func forget() {
        everAccepted = false
        everIssued = false
        lastConfirmed = nil
        lastDenied = nil
        session = nil
        deadline = nil
        generation = 0
        issuedGeneration = 0
        lowPowerWanted = nil
        // A session ending says nothing about the daemon. The handover is
        // still under way, or still waiting on a restart, and the card must
        // go on saying so rather than "off".
        state = quiet ?? .idle
    }

    // MARK: - The handover

    /// What a refused answer means.
    ///
    /// Every refusal comes here, and asks whether the helper inside this copy
    /// of Ledge would pass the same check. If it would, the process answering
    /// can only be one started from a bundle that has since been replaced,
    /// and the handover is the cure. If it would not, the installation looks
    /// wrong: no release goes out, nothing goes quiet, and the client goes on
    /// as before with the card saying to reinstall.
    ///
    /// "Looks", because a fail is asked again once it is
    /// `installedRecheckAfter` old. A fail is the safe thing to act on while
    /// it is wrong — it keeps the hold rather than giving it up — so the
    /// first one is believed at once, which is what a broken installation
    /// deserves, and it is never believed for long. A pass that follows it
    /// goes straight into the handover, as if the fail had never been read.
    private func heardRefusal() {
        if installedVerdict == nil || failIsOld { checkInstalledHelper() }
        if installedVerdict == .fails {
            mismatched = true
            return
        }
        mismatched = false
        beginHandover()
    }

    private func checkInstalledHelper() {
        installedVerdict = installedHelper()
        installedCheckedAt = now()
    }

    /// Whether a fail on record is old enough to ask about again. A clock
    /// that has gone backwards counts as old: an age that cannot be trusted
    /// is no reason to keep believing a fail.
    private var failIsOld: Bool {
        guard installedVerdict == .fails, let checked = installedCheckedAt else { return false }
        let age = now().timeIntervalSince(checked)
        return age < 0 || age >= Self.installedRecheckAfter
    }

    /// Starts waiting out a daemon that is the copy from before an update.
    ///
    /// Synchronous on purpose: everything the handover owes is decided here,
    /// in the same turn of the actor that heard the refusal, before anything
    /// else can run. In particular the release is captured now, naming the
    /// highest generation this session has sent — an `end` arriving a moment
    /// later finds the client already quiet and sends nothing of its own.
    private func beginHandover() {
        guard quiet == nil else { return }
        stopBeating()
        // Every request still in the air belongs to an era that is over, so
        // whatever it hears back — a refusal, a timeout — is written nowhere.
        lifecycle += 1
        let owed: (session: String, generation: Int)? = session.flatMap { id in
            issuedGeneration > 0 ? (id, issuedGeneration) : nil
        }
        // What the old copy said about this hold ends here. The release takes
        // it down, and a confirmation from before it must not make a silence
        // after the handover read as "almost certainly still stands".
        everAccepted = false
        everIssued = false
        lastConfirmed = nil
        lastDenied = nil
        // Above everything sent, so the hold after the handover is a new
        // generation whichever daemon receives it. A fresh one has never
        // heard of this session; the old one, if it is somehow still there,
        // has retired every generation up to the one released.
        generation = issuedGeneration
        state = .handingOver
        handover = Task { [weak self] in await self?.handOver(releasing: owed) }
    }

    /// The handover itself: one release, silence, and a question.
    ///
    /// The release lands even though nothing can be heard back from it, and
    /// it makes the old copy clean now rather than ninety seconds from now
    /// when its lease would have run out. Then nothing at all for
    /// `handoverSilence`. Then one status call, which launchd answers by
    /// starting the daemon from the new bundle if the old one has gone.
    ///
    /// Two refused questions and the card says a restart is needed — but the
    /// asking does not stop. A restore that took its time, or a Mac that
    /// slept through more than the clock could allow for, can still end with
    /// the old copy leaving by itself, so a question goes out every
    /// `restartProbeEvery` until one is answered.
    private func handOver(releasing owed: (session: String, generation: Int)?) async {
        if let owed {
            _ = try? await withTimeout { [link] in
                try await link.release(session: owed.session, generation: owed.generation)
            }
        }
        var refused = 0
        while true {
            // Counted from after the release, because the release is the
            // last thing the old copy heard and its idle clock starts there.
            // A sleep cut short still asks. Returning here instead would
            // leave the client quiet for good, and one question too early
            // costs at most another round.
            try? await silence(needsRestart ? Self.restartProbeEvery : Self.handoverSilence)
            // Cancelled is not cut short. Every sleep in a cancelled task
            // throws at once, and carrying on would ask as fast as the old
            // copy can refuse — which keeps it alive, the one thing this
            // loop is for undoing. Nothing cancels the handover today; this
            // is the line that keeps that from mattering.
            if Task.isCancelled { return }
            do {
                let answer = try await withTimeout { [link] in try await link.status() }
                return await finishHandover(answer)
            } catch is KeepAwakeHelperOutOfDate {
                // Still the old copy. The status call it just refused was
                // the last word again, so the next silence starts from it.
                refused += 1
                if refused >= Self.handoverRounds, !needsRestart {
                    needsRestart = true
                    state = .restartNeeded
                }
            } catch {
                // Not refused, which is all the handover was for. Silence or
                // an absent daemon is ordinary trouble, and the ordinary
                // rules read it from here.
                return await finishHandover(nil)
            }
        }
    }

    /// The new daemon answered. Holds again if a session still wants it.
    private func finishHandover(_ answer: KeepAwakeHelperStatus?) async {
        handover = nil
        needsRestart = false
        if let answer { lastStatus = answer }
        guard session != nil else {
            state = .idle
            return
        }
        // Still the handover's state while this goes out: the session has
        // nothing held until the new daemon says so, and "off" for the
        // length of one call would be a flicker that says the opposite.
        lifecycle += 1
        let era = lifecycle
        _ = await renew()
        guard lifecycle == era else { return }
        startBeating()
    }

    /// Runs one call under the timeout, or throws.
    ///
    /// Not a task group, and that is the whole point. A group waits for its
    /// cancelled children before it returns, and the losing child here is an
    /// XPC call parked in a continuation that cancellation cannot resume —
    /// only the daemon answering can, and a daemon that has stopped answering
    /// is exactly the case this timeout exists for. So the group's `next()`
    /// would hand back the timeout and then the group itself would sit there
    /// waiting for the thing that timed out. The timeout was not a bound.
    ///
    /// Instead: one continuation, two possible answers, first one wins, and
    /// the loser is simply dropped on the floor. The abandoned call still
    /// finishes in its own time and its answer goes nowhere, which costs one
    /// held connection and is what "timed out" has to mean.
    ///
    /// Cancelling does not unsend a command the daemon has already received.
    /// Nothing here pretends otherwise; the generation and lease rules are
    /// what make a command that lands late harmless.
    private func withTimeout<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let seconds = Self.callTimeout
        let sleeper = sleep
        let answer: T = try await withCheckedThrowingContinuation { continuation in
            let gate = FirstAnswerOnly(continuation)
            let timing = Task {
                // The injected sleeper, so tests drive this rather than wait
                // out forty-five real seconds.
                try? await sleeper(seconds)
                gate.deliver(.failure(KeepAwakeHelperTimeout()))
            }
            Task {
                do { gate.deliver(.success(try await body())) }
                catch { gate.deliver(.failure(error)) }
                timing.cancel()
            }
        }
        // Heard. Whatever made answers fail the check is not doing so now,
        // so a mismatch read from earlier refusals no longer stands.
        mismatched = false
        return answer
    }
}

/// The daemon did not answer in time.
public struct KeepAwakeHelperTimeout: Error, Sendable {}
