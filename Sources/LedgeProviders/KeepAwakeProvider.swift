import Foundation
import LedgeCore
import LedgeSystem
import OSLog

/// Keeps the Mac awake for a chosen length of time, and remembers that it did.
///
/// Everything it touches is injected, because almost every rule worth having
/// here is about what happens when something goes wrong: powerd refuses, the
/// disk refuses, the Mac restarts, the clock jumps, Ledge is killed. None of
/// those can be produced on demand against the real thing.
///
/// Two lifecycle calls, not one. `stop()` lets go of resources and writes
/// nothing — it is reached both when the card is switched off and when the app
/// is exiting, so it cannot tell those apart, and a function that cannot tell
/// them apart must not be the one that decides a session is over. `end(reason:)`
/// is the only way a session ends, and the caller awaits it.
@MainActor
public final class KeepAwakeProvider: ActivityProvider {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake")

    public let identifier = "keep-awake"

    /// How long powerd keeps holding past the deadline before letting go on its
    /// own.
    ///
    /// This is the backstop for a Ledge that hangs or is killed without
    /// releasing: the Mac is free to sleep two minutes after the deadline
    /// whatever state Ledge is in. The margin is there so powerd never
    /// pre-empts an ordinary, on-time End.
    public static let powerdMargin: TimeInterval = 120

    /// When a failed journal write is tried again.
    static let retryDelays: [TimeInterval] = [1, 5, 30]

    public struct Settings: Equatable, Sendable {
        public var defaultMinutes: Int
        public var batteryFloor: Int

        public init(defaultMinutes: Int = 60, batteryFloor: Int = 15) {
            self.defaultMinutes = defaultMinutes
            self.batteryFloor = batteryFloor
        }
    }

    // MARK: - Injected

    private let now: () -> Date
    private let assertion: SleepAssertion
    private let power: PowerSource
    private let thermal: ThermalSource
    private let journal: KeepAwakeJournalWorker
    /// The lid-closed hold, behind a protocol.
    ///
    /// The real one is an XPC connection to a root daemon, and the states
    /// worth building a card for — refused, silent, held by somebody else —
    /// cannot be produced on demand against one. The default holds nothing and
    /// says so, which is also the honest shipping answer until the daemon is
    /// installable.
    private let lid: any KeepAwakeLidHolding
    /// The lid-closed savings: darkened backlights, a muted output, and a
    /// journal that says how to put each of them back.
    ///
    /// Separate from `lid` on purpose. That one asks a root daemon to stop the
    /// Mac sleeping; this one is everything the hold then *costs*, and it
    /// needs no privilege at all. A Mac with no helper installed still has a
    /// lid, and a session whose hold was refused still wants its panel dark if
    /// somebody shuts it — which is why a refusal above does not reach here.
    private let conserve: LidConserveDriver?
    /// Turns App Nap off for the roster while a lid-closed session runs.
    ///
    /// Session-scoped rather than lid-scoped, unlike everything the conserve
    /// driver does, and the difference costs nothing: `NSAppSleepDisabled`
    /// only means anything for an app macOS considers invisible, so while the
    /// lid is up it is inert. Doing it at the start rather than at the close
    /// keeps the moment the lid comes down quiet — writing preferences into
    /// seventeen applications is work, and a shut lid is when the Mac is
    /// supposed to stop doing work.
    private let appNap: AppNapSuspending?
    /// This provider's place in the order of everything that has written to
    /// the journal. Writes from an owner the journal has moved past are
    /// refused, which is what stops a provider on its way out from replacing
    /// the record of the one that took over.
    private let owner: Int
    private let tombstone: KeepAwakeTombstone
    private let bootID: String?
    private let hasNotchPanel: () -> Bool
    private let settings: () -> Settings
    private let makeID: () -> String
    private let formatTime: (Date) -> String

    // MARK: - State

    /// Bumped on every state change, so work that suspended across one can
    /// tell that what it was finishing is no longer what is on screen.
    private var stateRevision = 0

    public private(set) var state: KeepAwakeState = .ready {
        didSet { stateRevision += 1 }
    }

    /// Bumped by `stop()`. Everything that was in flight before it belongs to
    /// a provider that has let go of its resources, and must not take any.
    private var lifecycle = 0

    /// The Start or Resume that currently holds the right to acquire, if any.
    ///
    /// One at a time, reserved before the first await. Two Starts arriving
    /// while the first was still waiting on the disk both passed a `state ==
    /// .ready` check — because neither had changed the state yet — and both
    /// went on to acquire.
    /// Bumped by every Start, Resume and End that actually does something.
    ///
    /// The state revision is not enough on its own: an End that cancels a
    /// Start still being written changes no state at all — the provider was
    /// Ready before it and is Ready after — so recovery, waiting on a slow
    /// read, found its guards intact and acquired the old session anyway.
    private var commandEpoch = 0

    private var pendingStart: Int?
    /// The session a pending Start is for, so an End arriving while it is
    /// still being written knows what it is cancelling.
    private var pendingSession: KeepAwakeSession?
    private var startTokens = 0
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var problem: KeepAwakePayload.Problem?
    private var chosenMinutes: Int
    /// Set when a session came back from the journal, so the announcement can
    /// say so. A resume the user did not ask for has to be visible.
    private var announcesResume = false
    private var summaryPending = false

    /// Consecutive failures to read the battery.
    private var batteryMisses = 0

    /// What the lid-closed mode last said about itself.
    ///
    /// The last *answer*, never what was asked for. Everything this card can
    /// usefully say about a privileged hold — that it is held, that it was
    /// refused, that the daemon has gone quiet and it is probably still held —
    /// is a reading, and a reading is the one thing a hopeful guess cannot
    /// stand in for.
    private var lidState: KeepAwakeLidState = .notInstalled
    /// Whether the session on the Finished card had asked for the lid hold,
    /// kept because the finish itself does not carry it and the thermal
    /// sentence changes with it.
    private var finishedWithLid = false

    // MARK: - The journal writer (§6.1.1)

    /// The record the disk is meant to hold, and how new it is.
    ///
    /// One writer, level-triggered: every write and every retry flushes
    /// *this*, never a record captured when the retry was scheduled. That is
    /// what stops a late retry from putting an old session back after a newer
    /// one has been written.
    private var desired: KeepAwakeRecord?
    private var desiredRevision = 0
    private var persistedRevision = 0
    private var revisionCounter = 0
    /// An end that is released but not recorded. The card says so.
    private var endUnrecorded = false
    private var retryWork: [DispatchWorkItem] = []

    // MARK: - Timers

    private var deadlineWork: DispatchWorkItem?
    private var publishWork: DispatchWorkItem?
    private var lastPublishedLabel: String?

    /// Takes the journal's writer, rather than the journal.
    ///
    /// The writer is shared by every provider over one journal file, because
    /// which of them is allowed to write is a question that outlives all of
    /// them: switching Keep Awake off and on again builds a new provider while
    /// the old one may still be waiting on the disk.
    public init(
        now: @escaping () -> Date = Date.init,
        assertion: SleepAssertion,
        power: PowerSource,
        thermal: ThermalSource,
        journal: KeepAwakeJournalWorker,
        tombstone: KeepAwakeTombstone,
        bootID: String?,
        lid: any KeepAwakeLidHolding = KeepAwakeLidUnavailable(),
        conserve: LidConserveDriver? = nil,
        appNap: AppNapSuspending? = nil,
        hasNotchPanel: @escaping () -> Bool = { true },
        settings: @escaping () -> Settings = { Settings() },
        makeID: @escaping () -> String = { UUID().uuidString },
        formatTime: @escaping (Date) -> String = KeepAwakeProvider.defaultTimeFormat
    ) {
        self.now = now
        self.assertion = assertion
        self.power = power
        self.thermal = thermal
        self.journal = journal
        self.lid = lid
        self.conserve = conserve
        self.appNap = appNap
        self.owner = journal.claim()
        self.tombstone = tombstone
        self.bootID = bootID
        self.hasNotchPanel = hasNotchPanel
        self.settings = settings
        self.makeID = makeID
        self.formatTime = formatTime
        self.chosenMinutes = settings().defaultMinutes
    }

    /// For the one provider that has a journal to itself — a preview, or a
    /// test that builds exactly one.
    public convenience init(
        now: @escaping () -> Date = Date.init,
        assertion: SleepAssertion,
        power: PowerSource,
        thermal: ThermalSource,
        journal: any KeepAwakeJournal,
        tombstone: KeepAwakeTombstone,
        bootID: String?,
        lid: any KeepAwakeLidHolding = KeepAwakeLidUnavailable(),
        conserve: LidConserveDriver? = nil,
        appNap: AppNapSuspending? = nil,
        hasNotchPanel: @escaping () -> Bool = { true },
        settings: @escaping () -> Settings = { Settings() },
        makeID: @escaping () -> String = { UUID().uuidString },
        formatTime: @escaping (Date) -> String = KeepAwakeProvider.defaultTimeFormat
    ) {
        self.init(now: now, assertion: assertion, power: power, thermal: thermal,
                  journal: KeepAwakeJournalWorker(journal), tombstone: tombstone,
                  bootID: bootID, lid: lid, conserve: conserve, appNap: appNap,
                  hasNotchPanel: hasNotchPanel,
                  settings: settings, makeID: makeID, formatTime: formatTime)
    }

    public static let defaultTimeFormat: (Date) -> String = { date in
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - ActivityProvider

    public func start() -> AsyncStream<ProviderEvent> {
        streamGeneration &+= 1
        let generation = streamGeneration
        return AsyncStream { continuation in
            self.continuation = continuation
            // Nothing is published until recovery has had its say. Publishing
            // Ready first and correcting it to Running afterwards made the
            // resumed session an *update* to a card that already existed, and
            // the coordinator announces arrivals, not updates — so a session
            // that came back on its own did so in silence.
            let recovering = Task { @MainActor [weak self] in
                guard let self, self.streamGeneration == generation else { return }
                // Before the session is recovered, and whether or not there is
                // one. A record left here belongs to a process that is gone —
                // force-quit, crashed, or replaced by an update with the lid
                // shut and the panel at zero — and it is restored for exactly
                // that reason: nobody is left who could be relying on it.
                self.conserve?.recover()
                // Whatever a crash left in other applications' preferences,
                // put back — and unconditionally, like the conserve recovery
                // beside it. The user who turns Keep Awake off after a crash
                // is exactly the one whose other apps would otherwise keep a
                // setting Ledge wrote and nothing would ever undo.
                if let appNap = self.appNap {
                    // Tracked like every other producer. A launch recovery
                    // that puts another application's preference back is work
                    // a quit has to wait for, and an untracked Task is work
                    // the barrier cannot see.
                    self.track { await appNap.restoreOutstanding() }
                }
                await self.recoverFromJournal(generation: generation)
                guard self.streamGeneration == generation else { return }
                self.publish()
            }
            self.recovering = recovering
            continuation.onTermination = { _ in
                Task { @MainActor [weak self] in
                    // Only if this is still the current stream. A provider
                    // restarted while the old stream was being torn down would
                    // otherwise have its new session stopped by the old one's
                    // termination.
                    guard let self, self.streamGeneration == generation else { return }
                    self.stop()
                }
            }
        }
    }

    /// Which stream is the live one.
    private var streamGeneration = 0

    /// Recovery, while it is still going on.
    ///
    /// An End arriving before it has spoken has nothing to end *yet*, and used
    /// to simply return — leaving the record on the disk for recovery, or the
    /// next launch, to pick up again. The user had switched the thing off.
    private var recovering: Task<Void, Never>?

    /// An End that arrived before recovery had said what was running.
    ///
    /// Recovery honours it instead of resuming: the session is ended and named
    /// rather than acquired and then released, so a process that stops in the
    /// middle still leaves something saying it is over.
    private var endBeforeRecovery: (token: Int, reason: KeepAwakeEndReason, landed: Int)?
    private var endRequests = 0

    /// Lets go of everything held in this process, and writes nothing.
    ///
    /// Reached when the card is switched off *and* when the app is exiting, so
    /// it cannot tell those apart. Writing an end here would record a session
    /// as finished every time Ledge quits, including the quits that are meant
    /// to leave it running. The coordinator awaits `end(reason:)` first when it
    /// knows which one this is.
    public func stop() {
        // Synchronously, before anything else: work that is mid-await must
        // find out it has been superseded without having to wait its turn.
        lifecycle += 1
        pendingStart = nil
        pendingSession = nil
        cancelDeadline()
        cancelPublish()
        assertion.release()
        power.stopWatching()
        thermal.stopWatching()
        disarmLid()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - The session

    /// Starts a session, if the disk agrees to remember it.
    ///
    /// The order is the whole safety rule: write first, acquire second. A hold
    /// nobody wrote down is a hold nobody can release after a crash; a record
    /// of a hold that was never taken is merely wrong, and the next launch
    /// corrects it.
    /// Switches it on. Holds until it is switched off, or a floor ends it.
    @discardableResult
    public func begin() async -> Bool {
        await begin { boot in
            KeepAwakeReducer.start(from: .ready, now: now(), id: makeID(), bootID: boot)?.session
        }
    }

    /// Switches it on for a set length. The lid-closed mode's entry point.
    ///
    /// `lidClosed` is the whole difference between the two timed starts, and
    /// it is why this one takes a length at all: an indefinite hold through a
    /// shut lid is the shape of session that flattens a battery or cooks a Mac
    /// in a bag, so the mode that can survive a shut lid is the one mode that
    /// always has an end.
    @discardableResult
    public func begin(minutes: Int, lidClosed: Bool = false) async -> Bool {
        await begin { boot in
            KeepAwakeReducer.start(
                from: .ready, minutes: minutes, now: now(), id: makeID(), bootID: boot,
                lidHoldRequested: lidClosed
            )?.session
        }
    }

    private func begin(_ make: (String) -> KeepAwakeSession?) async -> Bool {
        guard case .ready = state, pendingStart == nil else { return false }
        guard let boot = bootID else {
            problem = .assertionRefused
            publish()
            return false
        }
        guard let session = make(boot) else { return false }
        return await claim(session)
    }

    /// Writes a session down and, if it is still wanted by the time the disk
    /// answers, takes the assertion for it.
    ///
    /// The ownership is reserved *before* the first await and checked again
    /// after it. Without that, two things went wrong that no amount of care
    /// inside the function could catch: a second Start slipped through the
    /// `state == .ready` guard while the first was still writing, and a Start
    /// that was in flight when `stop()` ran went on to acquire an assertion
    /// for a provider that had already let everything go.
    private func claim(_ session: KeepAwakeSession) async -> Bool {
        // The room to say "this one is over" is taken before the session is.
        // A session that starts with nowhere to leave its name can only be
        // cancelled by forgetting somebody else's, and the one forgotten is as
        // likely as any to be the session the journal is still holding.
        guard hasRoomForAnotherSession else {
            Self.log.error("keep awake: too many sessions are still waiting to be written down")
            problem = .tooManyUnsaved
            publish()
            return false
        }
        // Counted here, where the session actually becomes one. Counting it in
        // `begin` meant a start refused for want of room still told recovery
        // to stand down — and recovery was the thing that would have given the
        // room back.
        commandEpoch += 1
        startTokens += 1
        let token = startTokens
        let era = lifecycle
        pendingStart = token
        pendingSession = session

        let wrote = await writeStart(KeepAwakeRecord(running: session))

        guard lifecycle == era, pendingStart == token else {
            // Somebody else owns this now, or the provider has stopped. If the
            // record landed, take it back so no later launch resumes a session
            // that was abandoned before it ever held anything.
            if wrote {
                await abandonStart(session)
            } else {
                // Nothing reached the disk under this session's name, so a
                // note naming it has nothing left to warn about. Everything
                // else on the list stays: it is protecting other records.
                try? tombstone.keepOnly(tombstone.endedSessionIDs().filter { $0 != session.id })
            }
            return false
        }
        pendingStart = nil
        pendingSession = nil

        guard wrote else {
            problem = .startNotSaved
            publish()
            return false
        }

        guard acquire(for: session) else {
            // Nothing is held, so the record has to stop claiming otherwise.
            let settled = stateRevision
            let issued = commandEpoch
            await abandonStart(session)
            // And taking it back is a trip to the disk, which is long enough
            // for another Start to have succeeded. Reporting the refusal over
            // that one left the card saying nothing was running while an
            // assertion was held — and End, finding nothing to end, let it
            // stay held.
            // The state revision alone cannot tell two failed attempts apart:
            // both leave Ready, so both leave it unchanged. The command
            // generation can, and the newer attempt's own explanation is the
            // one the user is owed.
            guard lifecycle == era, stateRevision == settled,
                  commandEpoch == issued else { return false }
            problem = .assertionRefused
            state = .ready
            publish()
            return false
        }

        problem = nil
        endUnrecorded = false
        announcesResume = false
        state = .running(session)
        beginWatching()
        armDeadline()
        armLid(for: session)
        beginConserving(for: session)
        publish()
        return true
    }

    // MARK: - The lid-closed hold

    /// Asks the helper to hold this session through a shut lid.
    ///
    /// After the session is running, and never as a condition of it. The
    /// ordinary hold is already taken by the time this runs, so a refusal from
    /// the daemon costs the user nothing they had: the Mac still stays awake
    /// with the lid open, and the card says what the lid part could not do.
    /// Failing the whole start over it would throw away the half that worked.
    private func armLid(for session: KeepAwakeSession) {
        guard session.lidHoldRequested, let deadline = session.deadline else { return }
        let era = lifecycle
        let issued = commandEpoch
        // Owned from here, not from the answer: the release has to be able to
        // name this session even if the arm is still in the air.
        armedSessionID = session.id
        track { @MainActor [weak self] in
            guard let self else { return }
            // Fenced before acting, not only before publishing. A stale arm
            // landing after a release would recreate ownership of a hold
            // nobody wants.
            guard self.lifecycle == era, self.commandEpoch == issued,
                  self.state.session?.id == session.id else { return }
            let reading = await self.lid.arm(session: session.id, until: deadline)
            // The answer can be seconds old by the time it lands — a daemon
            // behind a `pmset` transaction takes its time — and in those
            // seconds the user may have ended this session and started
            // another. Publishing a refusal over that one would explain the
            // wrong session's trouble.
            guard self.lifecycle == era, self.commandEpoch == issued,
                  self.state.session?.id == session.id else { return }
            self.lidState = reading
            self.publish()
        }
    }

    /// Starts the savings a shut lid is supposed to buy.
    ///
    /// Only for a session that asked to survive a shut lid. An ordinary
    /// session sleeps when the lid comes down, so there is nothing to darken
    /// and nobody to darken it for.
    ///
    /// Not conditional on the daemon having said yes. The hold and the savings
    /// fail independently — a Mac with no helper installed still has a lid,
    /// and a user who shuts one on a refused hold has exactly the lit panel
    /// inside a closed machine that this exists to turn off.
    private func beginConserving(for session: KeepAwakeSession) {
        guard session.lidHoldRequested else { return }
        conserve?.begin(sessionID: session.id)
        if let appNap {
            // Tracked, and fenced before it acts: a Begin delayed past the
            // End that was supposed to cancel it would otherwise disable
            // another application's App Nap for a session that is over.
            let era = lifecycle
            let issued = commandEpoch
            track { @MainActor [weak self] in
                guard let self, self.lifecycle == era, self.commandEpoch == issued,
                      self.state.session?.id == session.id
                else { return }
                await appNap.beginIfWanted()
            }
        }
    }

    /// Gives the lid-closed hold back.
    ///
    /// Unconditional, and never awaited. A release is never refused by the
    /// daemon and everything about one moves the Mac towards being allowed to
    /// sleep, so there is no state in which skipping it — because we believe
    /// nothing is held — is the safer answer; the belief is the thing most
    /// likely to be wrong. If the process dies before this lands, the daemon's
    /// own lease ends the hold within ninety seconds.
    private func disarmLid() {
        // Before the hold, and synchronously. Everything the savings changed
        // is a thing the user can see the moment they open the lid, and a
        // restore that waited on an XPC round trip would be a panel that
        // stayed dark for as long as a silent daemon takes to time out.
        conserve?.end()
        // Tracked, not fired and forgotten. Returning from `end(reason:)` has
        // only ever said the session is *recorded*; another application's
        // preference being put back is a separate piece of work, and a quit
        // that exits here leaves it changed.
        if let appNap {
            track { await appNap.end() }
        }
        let era = lifecycle
        // Named, because this task can be delayed past the point where a
        // replacement provider has taken a hold of its own, and an unnamed
        // release would end that one instead. The publication guard below
        // cannot undo a release that has already gone out.
        // A provider that armed nothing releases nothing. Clearing it here
        // also makes the `stop()` that follows an End a no-op rather than a
        // second, now-nameless release.
        guard let releasing = armedSessionID else { return }
        armedSessionID = nil
        track { @MainActor [weak self] in
            guard let self else { return }
            await self.lid.disarm(session: releasing)
            guard self.lifecycle == era, self.state.session == nil else { return }
            await self.refreshLid()
        }
    }

    /// Everything started on this provider's behalf that outlives the call
    /// that started it.
    ///
    /// Returning from `end(reason:)` says the session is written down. It has
    /// never said the hold was given back, the savings put away, or another
    /// application's preference restored — those are tasks nobody was holding
    /// on to, and a quit that exits here leaves all three outstanding.
    private var sideEffects: [Int: Task<Void, Never>] = [:]
    private var nextSideEffect = 0

    /// The session this provider actually armed, held until its release has
    /// gone out.
    ///
    /// `state.session?.id` is not it. The first End reads that while the state
    /// is still running and gets the right answer; the `stop()` that follows
    /// reads it after the state has become Finished and gets nil — which means
    /// "whatever is held", and ended the session that had replaced it. A
    /// provider that armed nothing releases nothing.
    private var armedSessionID: String?

    /// Keeps a handle only while the work is live.
    ///
    /// Removing merely cancelled tasks kept every completed one for the
    /// provider's lifetime — normal completion does not set `isCancelled` —
    /// so a provider left enabled accumulated handles for every session it
    /// ever ran.
    private func track(_ body: @escaping @Sendable () async -> Void) {
        nextSideEffect += 1
        let token = nextSideEffect
        sideEffects[token] = Task { @MainActor [weak self] in
            await body()
            self?.sideEffects[token] = nil
        }
    }

    /// How much work is still live. For a test, and for a quit that wants to
    /// know whether its barrier actually drained anything.
    public var liveSideEffectCount: Int { sideEffects.count }

    /// Waits for every side effect still running, and for anything they start.
    ///
    /// Loops because the work being joined can enqueue more — a release that
    /// finishes asks for a fresh reading — and a barrier that returned with
    /// that still outstanding is not a barrier.
    public func joinSideEffects() async {
        for _ in 0..<8 {
            let live = sideEffects.values
            guard !live.isEmpty else { return }
            for task in live { await task.value }
        }
    }

    /// Reads the lid-closed mode without changing anything.
    ///
    /// Published only when the reading has actually moved. A status call is
    /// answered from the daemon's memory and costs nothing, but redrawing the
    /// card every minute to say the same sentence is the kind of noise the
    /// recipe's quiet operation rules out.
    public func refreshLid() async {
        let era = lifecycle
        let reading = await lid.state()
        guard lifecycle == era, reading != lidState else { return }
        lidState = reading
        publish()
    }

    /// The reading the card needs, for a settings pane or a test.
    public var lidReading: KeepAwakeLidState { lidState }

    /// Whether another session may be started.
    ///
    /// Counted against the names already taken *and* every start whose write
    /// has not been answered, because each of those may yet need a name of its
    /// own. Asking the list alone let two providers over the same journal both
    /// pass on the last place, and the second one's cancellation then had
    /// nowhere to go.
    private var hasRoomForAnotherSession: Bool {
        let named = tombstone.endedSessionIDs()
        let unnamed = Set(journal.admittedSessionIDs()).subtracting(named)
        return named.count + unnamed.count < KeepAwakeTombstoneCapacity.limit
    }

    /// Ends the session recovery is about to find, if it is still looking.
    ///
    /// Waiting is safe here in the one way that matters: recovery not having
    /// finished means nothing has been acquired yet, so nothing is keeping the
    /// Mac awake while this waits. The coordinator's quit path bounds it.
    private func endWhateverRecoveryFinds(reason: KeepAwakeEndReason) async {
        guard let recovering, !recovering.isCancelled else { return }
        endRequests += 1
        let token = endRequests
        endBeforeRecovery = (token, reason, journal.writesLanded())
        await recovering.value
        // Only its own request. Clearing whatever is there took away the one
        // belonging to an End that arrived while this was waiting, and the
        // recovery that End was waiting for then resumed the session.
        if endBeforeRecovery?.token == token { endBeforeRecovery = nil }
    }

    /// Takes back the right to acquire from a Start that is still being
    /// written, and leaves a note that survives this process.
    ///
    /// Synchronous on purpose. The claim being cancelled is somewhere inside an
    /// await, and the only way to be ahead of it is to need nothing from the
    /// disk: revoking the token is what `claim` checks when it comes back, and
    /// it checks it before acquiring anything.
    ///
    /// The tombstone is the part that outlives the process. The record may
    /// already be on the disk, and a quit is one of the reasons to be here, so
    /// the continuation that would take it back may never run. Naming the
    /// session is what stops the next launch resuming a session that was
    /// cancelled before it ever held anything.
    private func cancelPendingStart() {
        guard pendingStart != nil, let session = pendingSession else { return }
        pendingStart = nil
        pendingSession = nil
        // Added, never substituted. The write being cancelled may or may not
        // have reached the disk, so either this session or the one it was
        // replacing is the one the journal will be found holding — and from
        // here there is no way to know which. Both are named; the one that
        // turns out not to be on the disk is dropped by the next write that
        // lands.
        do {
            try tombstone.add(session.id)
        } catch {
            Self.log.error("keep awake: a cancelled start could not be named")
        }
    }

    /// Marks a written-but-never-started session as over.
    ///
    /// Only if the record is still that session's. A newer start may already
    /// have replaced it, and writing this one's ending over that would hand the
    /// next launch an ended record for a session that is running right now.
    private func abandonStart(_ session: KeepAwakeSession) async {
        guard desired?.id == session.id, desired?.state == .running else { return }
        desired = KeepAwakeRecord(running: session)
            .ended(.turnedOff, at: now(), summaryPending: false)
        desiredRevision = nextRevision()
        if await flushDesired().isSettled { return }

        // The disk kept the start and then refused to take it back, which is
        // the one combination that outlives this process: the file says a
        // session is running and nothing anywhere says it is not. The
        // tombstone names it, so the next launch reads the record and declines
        // to resume it, and the retries keep trying to replace the record
        // itself. The summary flag is left alone — this session never started,
        // so there is no card for it to be wrong about.
        do {
            try tombstone.add(session.id)
        } catch {
            Self.log.error("keep awake: a cancelled start could not be taken back")
        }
        scheduleRetries()
    }

    /// The only way a session ends.
    ///
    /// Releasing never waits on the disk. If the write fails everything is let
    /// go anyway and the failure is recorded somewhere else, because the
    /// alternative — holding the Mac awake until a disk recovers — is the one
    /// outcome nobody would choose.
    public func end(reason: KeepAwakeEndReason) async {
        guard let session = state.session else {
            // Nothing is running — but something may be on its way to it. A
            // Start waiting on the disk is still a Start, and an End that
            // walked past it left the user's Off, or a quit, undone by a
            // session that arrived afterwards and took an assertion.
            if pendingStart != nil { commandEpoch += 1 }
            cancelPendingStart()
            await endWhateverRecoveryFinds(reason: reason)
            return
        }
        commandEpoch += 1
        let at = now()
        let era = lifecycle
        // Remembered before the session goes, because the finish does not
        // carry it and the thermal sentence turns on it.
        finishedWithLid = session.lidHoldRequested
        // Released first, always. Whether the disk takes the record is a
        // separate question from whether the Mac is free to sleep, and the
        // Mac's answer must not wait on the disk's.
        releaseEverything()
        state = .finished(KeepAwakeReducer.finish(session, reason: reason, at: at))
        let settled = stateRevision
        publish()

        await recordEnd(for: session, reason: reason, at: at, silently: false)

        // The card may have been dismissed, or a new session started, while the
        // disk was thinking. Re-stating the Finished card here put it back on
        // screen after the user had pressed Done.
        guard lifecycle == era, stateRevision == settled else { return }
        state = .finished(
            KeepAwakeReducer.finish(session, reason: reason, at: at, endUnrecorded: endUnrecorded)
        )
        publish()
    }

    /// The same end, without the await.
    ///
    /// Nothing about ending is actually asynchronous — the release and the
    /// write are both synchronous — so the floors and the wake handler end a
    /// session here and now rather than posting a task that runs some time
    /// later. `end(reason:)` stays `async` because the coordinator awaits it as
    /// a contract before tearing the provider down.
    private func endNow(reason: KeepAwakeEndReason) {
        guard state.session != nil else { return }
        Task { @MainActor [weak self] in await self?.end(reason: reason) }
    }

    /// Picks up a session the user ended by mistake.
    @discardableResult
    public func resume() async -> Bool {
        guard pendingStart == nil, let boot = bootID,
              case .running(let session)? = KeepAwakeReducer.resume(
                  from: state, now: now(), id: makeID(), bootID: boot
              )
        else { return false }
        return await claim(session)
    }

    public func dismiss() {
        guard let next = KeepAwakeReducer.dismiss(state) else { return }
        state = next
        problem = nil
        endUnrecorded = false
        summaryPending = false
        // The record is deliberately left where it is. Clearing it from here
        // meant a detached write racing the next session's start — which won,
        // and left the disk holding nothing for a session that was running.
        // A finished record is harmless: the next start replaces it, and
        // Settings reads it for the "last session" line in the meantime.
        publish()
    }

    public func setMinutes(_ minutes: Int) {
        chosenMinutes = KeepAwakeReducer.clamp(minutes: minutes)
        publish()
    }

    // MARK: - System events

    /// The Mac woke up.
    ///
    /// The assertion is re-armed rather than assumed intact, and the deadline
    /// is checked before anything else: sleeping through the end of a session
    /// is the ordinary case, not the exception.
    public func systemDidWake() {
        guard let session = state.session else { return }
        if session.hasExpired(at: now()) {
            deadlineTick()
            return
        }
        rearmBackstop(for: session)
        armDeadline()
        publish()
    }

    /// The wall clock moved.
    ///
    /// The deadline is an absolute time, so a clock change moves how long is
    /// left. Re-arming is unconditional: a timer that was going to fire at the
    /// old distance is now wrong in either direction, and a timer that is
    /// merely re-armed costs nothing.
    public func clockDidChange() {
        guard state.isRunning else { return }
        deadlineTick()
        guard let session = state.session else { return }
        // powerd is holding a timeout measured from when the assertion was
        // taken. Moving the wall clock moves the deadline relative to it, so
        // the backstop has to be re-armed too — otherwise a clock pushed
        // forward leaves powerd holding for hours past the end.
        rearmBackstop(for: session)
        armDeadline()
        publish()
    }

    /// Runs the deadline check now, without waiting out a real timer.
    public func deadlineTick() {
        guard KeepAwakeReducer.tick(state, now: now()) != nil else {
            // Fired early — a clock change, or a timer the system ran ahead of
            // schedule. Returning without re-arming is how a session silently
            // never ends at all, which is the bug this is modelled against.
            if state.isRunning { armDeadline() }
            return
        }
        endNow(reason: .timeUp)
    }

    /// Runs any outstanding journal retry now.
    public func retryTick() async {
        await flushDesired()
    }

    // MARK: - Floors

    private func beginWatching() {
        batteryMisses = 0
        power.startWatching { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFloors() }
        }
        thermal.startWatching { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFloors() }
        }
        // Read them once now. Waiting for a change notification means a
        // session started on a Mac that is already too hot, or already below
        // the floor, runs until something happens to move — which on a Mac
        // sitting at 9% unplugged may be a long time.
        checkFloors()
    }

    private func checkFloors() {
        guard state.isRunning else { return }
        let snapshot = power.snapshot()
        if power.isAvailable, snapshot == nil {
            batteryMisses += 1
        } else {
            batteryMisses = 0
        }
        let battery = KeepAwakeBattery(
            // `PowerSnapshot.percentage` is 0...1. Rounding it straight to an
            // Int turned 80% into 1, which is under every floor worth having —
            // the first unplugged reading ended the session.
            percentage: snapshot.map { Int(($0.percentage * 100).rounded()) },
            charging: snapshot.map { $0.isCharging || $0.isPluggedIn },
            isPresent: power.isAvailable
        )
        // What the user *asked for*, not what the daemon last confirmed. If
        // they asked for a lid-closed hold they have very likely shut the lid,
        // and a helper that has gone quiet is no reason to relax the floors
        // that exist because nobody can see the Mac — the hold is still
        // standing on its lease, and the Mac is still shut.
        let lidClosed = state.session?.lidHoldRequested == true
        let decision = KeepAwakeFloors.decide(
            battery: battery,
            floor: settings().batteryFloor,
            missCount: batteryMisses,
            thermal: thermal.state,
            lidClosed: lidClosed,
            // With the lid open the user can see their own battery, and ending
            // their session over a failed read would be Ledge being jumpy
            // about a number it did not need. With it shut, that number is the
            // only thing standing between a held-awake Mac and a flat one.
            enforcesUnreadable: lidClosed
        )
        guard case .end(let reason) = decision else { return }
        endNow(reason: reason)
    }

    // MARK: - Assertion

    /// How long powerd's own backstop runs for a hold with no deadline.
    ///
    /// The assertion dies with the process, so this is not about a crash: it is
    /// about a Ledge that is still running and has stopped thinking. An hour,
    /// re-armed every half hour while the session is healthy, bounds that
    /// without the user ever seeing it.
    private static let openEndedBackstop: TimeInterval = 3600
    private static let openEndedRearm: TimeInterval = 1800

    private func backstop(for session: KeepAwakeSession) -> TimeInterval {
        guard let remaining = session.remaining(at: now()) else {
            return Self.openEndedBackstop
        }
        return remaining + Self.powerdMargin
    }

    private func acquire(for session: KeepAwakeSession) -> Bool {
        assertion.acquire(
            name: IOPMSleepAssertion.assertionName,
            details: session.deadline.map { "until \(formatTime($0))" } ?? "until switched off",
            timeout: backstop(for: session)
        )
    }

    /// Gives powerd a fresh timeout for what is left.
    ///
    /// A refusal is not cosmetic: the backstop is the only thing bounding a
    /// hung Ledge, and without it the assertion would be held until the process
    /// dies. Taking the assertion again from scratch is the honest repair, and
    /// if even that fails the session ends rather than carrying on holding
    /// something nobody can account for.
    private func rearmBackstop(for session: KeepAwakeSession) {
        if assertion.rearm(timeout: backstop(for: session)) { return }
        Self.log.error("keep awake: the backstop could not be re-armed")
        guard acquire(for: session) else {
            endNow(reason: .timeUp)
            problem = .assertionRefused
            return
        }
    }

    private func releaseEverything() {
        cancelDeadline()
        cancelPublish()
        assertion.release()
        power.stopWatching()
        thermal.stopWatching()
        disarmLid()
    }

    // MARK: - Journal

    /// Writes a start, and says whether the disk took it.
    ///
    /// On failure the desired record is left exactly as it was. That matters
    /// for the case where an earlier end is still waiting to be recorded: the
    /// failed start must not become what the retries are trying to write, or a
    /// session that never started would be persisted as running.
    private func writeStart(_ record: KeepAwakeRecord) async -> Bool {
        // Kept, so a start the disk refuses can put back whatever was waiting
        // to be written before it. Otherwise an unrecorded end that was still
        // retrying would be replaced by a session that never began.
        let previous = desired
        let previousRevision = desiredRevision
        let revision = nextRevision()
        desired = record
        desiredRevision = revision
        let token = journal.admit(record.id)
        defer { journal.resolve(token) }
        do {
            guard try await journal.write(record, revision: revision, owner: owner) else {
                // Something newer reached the disk first. Nothing to undo.
                return false
            }
            let isNewest = revision > persistedRevision
            persistedRevision = max(persistedRevision, revision)
            cancelRetries()
            endUnrecorded = false
            // Its own name stays if it is there, which is how a start
            // cancelled while this write was in flight keeps the protection it
            // asked for — and so does every write still waiting behind it. See
            // `flushDesired` for why both are needed.
            if isNewest {
                try? tombstone.keepOnly([record.id] + journal.mayStillReachDisk(excluding: token))
            }
            return true
        } catch {
            Self.log.error("keep awake: the start could not be saved")
            if desiredRevision == revision {
                // Only an *ended* record is worth putting back. That is what
                // this exists for: an unrecorded end that was still retrying
                // must not be replaced by a session that never began. A
                // running record here belongs to an earlier start that also
                // failed — restoring it made a cancelled session the thing the
                // retries were trying to write.
                desired = previous?.state == .ended ? previous : nil
                desiredRevision = previousRevision
            }
            return false
        }
    }

    /// Records an end. Everything has already been released by the time this
    /// runs, so nothing here can keep the Mac awake.
    private func recordEnd(
        for session: KeepAwakeSession,
        reason: KeepAwakeEndReason,
        at date: Date,
        silently: Bool
    ) async {
        let pending = !silently && !hasNotchPanel()
        summaryPending = pending
        let record = KeepAwakeRecord(running: session)
            .ended(reason, at: date, summaryPending: pending)
        desired = record
        desiredRevision = nextRevision()

        // Named *before* the disk is asked, not after it refuses. The
        // assertion is already released and the record still says the session
        // is running, so a Mac that stops while the write is in the air would
        // otherwise read that record back with nothing to contradict it. The
        // write landing takes the name away again.
        var named = false
        do {
            try tombstone.add(session.id)
            named = true
        } catch {
            Self.log.error("keep awake: an ended session could not be named")
        }

        if await flushDesired().isSettled { return }

        // The journal refused, and the name is what is standing in for it.
        endUnrecorded = !named
        if !named {
            Self.log.error("keep awake: neither the journal nor the tombstone took the end")
        }
        scheduleRetries()
    }

    /// What became of a write.
    ///
    /// Superseded is deliberately not the same as landed. Both mean there is
    /// nothing left to retry, but only landed means *this* record is the one
    /// on disk — and the tombstone, which exists to say "do not resume this
    /// session", may only be given up on the strength of that.
    private enum WriteOutcome {
        /// This record is what the disk holds.
        case landed
        /// Something newer has the file, so this record is not wanted.
        case superseded
        /// The disk refused it. Something is still outstanding.
        case failed

        /// Whether anything is left to retry.
        var isSettled: Bool { self != .failed }
    }

    /// Writes whatever the disk is currently meant to hold.
    ///
    /// A retry that finds the desired record already persisted does nothing.
    /// That is the guard against a superseded retry: End A fails, Start B
    /// succeeds, A's retry fires and finds `running(B)` already on disk at the
    /// current revision, so it writes nothing.
    @discardableResult
    private func flushDesired() async -> WriteOutcome {
        guard let record = desired else { return .landed }
        let revision = desiredRevision
        guard persistedRevision < revision else { return .landed }
        // Admitted before the suspension, so anything queued behind this one
        // is already on record as something that may still reach the disk.
        let token = journal.admit(record.id)
        defer { journal.resolve(token) }
        do {
            // The writer refuses anything older than what it has already
            // written, so a retry queued behind a newer start simply does not
            // land. Superseded is not a failure — there is nothing left to do.
            let landed = try await journal.write(record, revision: revision, owner: owner)
            // Asked before the count moves: whether this is the newest write
            // this provider has landed. Two writes can be waiting on the disk
            // at once, and the order their continuations get back to the main
            // actor is not the order the disk took them in — so the older one
            // must not be the one that says what the disk is holding.
            let isNewest = revision > persistedRevision
            persistedRevision = max(persistedRevision, revision)
            cancelRetries()
            guard landed else { return .superseded }
            // A write that landed settles what the journal holds *for now* —
            // but only for as long as nothing else is on its way. Every write
            // still admitted may yet become the record, so its name stays.
            // Pruning on what this caller happens to know, while the queue
            // behind it is unanswered, is how a session that was explicitly
            // cancelled came back.
            //
            // An ended record cannot be resumed by anybody, so its own name
            // goes; a running one keeps its own, which is there exactly when
            // that session was cancelled while this write was in flight.
            let queued = journal.mayStillReachDisk(excluding: token)
            if record.state == .ended {
                endUnrecorded = false
                if isNewest { try? tombstone.keepOnly(queued) }
            } else if isNewest {
                try? tombstone.keepOnly([record.id] + queued)
            }
            return .landed
        } catch {
            return .failed
        }
    }

    private func nextRevision() -> Int {
        revisionCounter += 1
        return revisionCounter
    }

    private func scheduleRetries() {
        cancelRetries()
        for delay in Self.retryDelays {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { @MainActor in _ = await self.flushDesired() }
                }
            }
            retryWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelRetries() {
        retryWork.forEach { $0.cancel() }
        retryWork.removeAll()
    }

    /// Everything outstanding, one last time, on the way out.
    public func flushPendingWrites() async {
        await flushDesired()
    }

    // MARK: - Recovery

    private func recoverFromJournal(generation: Int) async {
        let era = lifecycle
        // Taken before the read, because a session can begin and end while the
        // disk is being read, and recovery's answer would then be about a
        // world that no longer exists — it acquired again for a session that
        // had just been ended.
        let settled = stateRevision
        let intent = commandEpoch
        let writesBefore = journal.writesLanded()
        let read: KeepAwakeJournalWorker.JournalRead
        do {
            // Read and quarantine together, so a record written while this was
            // waiting cannot be the one put aside.
            read = try await journal.readOrQuarantine()
        } catch {
            guard streamGeneration == generation, lifecycle == era,
                  stateRevision == settled, commandEpoch == intent else { return }
            problem = .journalUnreadable
            return
        }
        let record = read.record

        // Reclaiming first, and on its own terms. Nothing was written on
        // either side of the read and nothing is in the air, so this answer
        // describes the disk as it stands — which makes it the one moment a
        // name can be shown to be protecting nothing. It comes before the
        // protection below so the room is there to leave one, and before the
        // ownership checks because which names are needed is a fact about the
        // disk, not about whether this provider still gets to act.
        if journal.writesLanded() == writesBefore, journal.admittedSessionIDs().isEmpty {
            let stillNeeded = record.map { $0.state == .running ? [$0.id] : [] } ?? []
            try? tombstone.keepOnly(stillNeeded)
        }

        // Named before the checks, not after them. The checks decide whether
        // this provider still gets to act; they do not decide whether the
        // session is still meant to end. An End asked for while this read was
        // out is owed its protection even if this provider has stopped since
        // — otherwise the record stays on the disk, unnamed, for the next
        // launch or the replacement provider to pick up and resume.
        //
        // Only a record this provider may still speak for. One written by a
        // newer owner belongs to a session somebody else started, and naming
        // that would end a session nobody asked to end.
        // Scoped to the record, not to the commands. A Start submitted after
        // the End can reach the disk before this read does, and the record
        // found is then a session nobody asked to end — so what matters is
        // whether anything has actually *landed* since the End was asked for.
        // A Start that was attempted and refused changes nothing, and the
        // protection the End is owed must survive it.
        if let pending = endBeforeRecovery, read.landed == pending.landed, let record,
           record.state == .running, read.writtenBy <= owner {
            let reason = pending.reason
            do {
                try tombstone.add(record.id)
            } catch {
                // Nowhere to leave a note. Leave the end itself instead: a
                // replaced record needs no annotation, and the writer refuses
                // it anyway if a newer owner has since written.
                Self.log.error("keep awake: no room to name an ended session, writing the end")
                await recordEnd(for: record.session, reason: reason,
                                at: now(), silently: true)
            }
        }

        // Checked on this side of the read for *every* outcome, not only the
        // running one. A summary published into a provider that has been
        // stopped, or restarted onto a newer stream, is as wrong as an
        // assertion taken for one.
        // The owner check belongs with the others, not only with the naming
        // above: a record a newer owner wrote is not this provider's to end,
        // resume, or show a summary for either.
        guard streamGeneration == generation, lifecycle == era,
              stateRevision == settled, commandEpoch == intent,
              read.writtenBy <= owner else { return }

        // And the read has to still be worth acting on. `writtenBy` describes
        // who owned the file when the read ran, not who owns it now: a newer
        // provider's write can land while this continuation is waiting its
        // turn on the main actor, and acquiring on the strength of the older
        // answer is how two assertions come to be held for one Mac. Kept apart
        // from the protection above on purpose — that is owed whatever has
        // happened since, this is not.
        guard journal.writesLanded() == read.landed,
              journal.admittedSessionIDs().isEmpty else { return }

        guard let record, record.state == .running else {
            // An ended record is the last session's summary. It is shown once
            // if nobody has seen it yet.
            if let record, record.summaryPending, let reason = record.endReason {
                state = .finished(
                    KeepAwakeReducer.finish(record.session, reason: reason,
                                            at: record.endedAt ?? now())
                )
                summaryPending = false
                var cleared = record
                cleared.summaryPending = false
                desired = cleared
                desiredRevision = nextRevision()
                await flushDesired()
            }
            return
        }
        guard let boot = bootID else { return }
        let recovery = KeepAwakeReducer.recover(
            record.session, bootID: boot, now: now(),
            tombstoned: tombstone.endedSessionIDs().contains(record.id)
        )
        switch recovery {
        case .nothing:
            return
        case .ended(let finish):
            state = .finished(finish)
            // The tombstone is cleared by the write that replaces the record,
            // and only by it. Clearing it here as well threw away the only
            // note saying "do not resume this" in exactly the case it was
            // written for — the one where that replacement was refused.
            await recordEnd(for: record.session, reason: finish.reason,
                            at: finish.endedAt, silently: true)
        case .resume(let session):
            if let reason = endBeforeRecovery?.reason {
                // Switched off while this was being read. Ending it here is
                // the only chance to write that down: acquiring first and
                // releasing afterwards would leave a window with nothing on
                // the disk saying the session is over.
                let finish = KeepAwakeReducer.finish(record.session, reason: reason, at: now())
                state = .finished(finish)
                await recordEnd(for: record.session, reason: reason,
                                at: finish.endedAt, silently: true)
                return
            }
            guard acquire(for: session) else {
                state = .ready
                problem = .assertionRefused
                return
            }
            state = .running(session)
            announcesResume = true
            beginWatching()
            armDeadline()
            // The hold, as well as the savings. A resumed session that darkens
            // the panel without re-arming the daemon is the worst of both: it
            // looks held, the screen is dark, and the Mac sleeps the moment the
            // lid comes down. The daemon never inherits a hold across its own
            // restart, so a resume has to ask again — under a new generation,
            // which `arm` takes care of.
            armLid(for: session)
            beginConserving(for: session)
        }
    }

    // MARK: - Timers and publishing

    private func armDeadline() {
        cancelDeadline()
        guard let session = state.session else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.deadlineTick() }
        }
        deadlineWork = work
        // A hold with no deadline has nothing to fire *for*, but powerd's
        // backstop still expires, so the same timer re-arms it instead.
        let after = session.remaining(at: now()).map { max($0, 0.02) } ?? Self.openEndedRearm
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
        armPublish()
    }

    private func cancelDeadline() {
        deadlineWork?.cancel()
        deadlineWork = nil
    }

    /// Publishes once per displayed unit and no faster.
    ///
    /// A card reading "1h 12m" has nothing new to say for another minute, and
    /// waking the main actor every second for an hour to redraw the same
    /// characters is exactly the kind of cost the recipe's "quiet operation"
    /// rules out.
    private func armPublish() {
        cancelPublish()
        guard let session = state.session else { return }
        // Counting up rather than down when there is no deadline: the card
        // shows how long it has been holding, which changes once a minute.
        let left = session.remaining(at: now()) ?? session.elapsed(at: now())
        let delay: TimeInterval = left <= 60
            ? max(0.2, left.truncatingRemainder(dividingBy: 1) + 0.02)
            : left.truncatingRemainder(dividingBy: 60) + 0.02
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.publish()
                self?.armPublish()
                // The client renews every thirty seconds; this asks what came
                // of it. A minute behind the truth is the worst the card can
                // be, which is close enough for a sentence and far cheaper
                // than a second timer of its own.
                self?.refreshLidWhileHeld()
            }
        }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.2), execute: work)
    }

    private func cancelPublish() {
        publishWork?.cancel()
        publishWork = nil
    }

    /// Re-reads the lid-closed mode, but only for a session that asked for it.
    ///
    /// A session with the lid open has no helper to ask about, and asking
    /// anyway would put a daemon's troubles on a card they have nothing to do
    /// with.
    private func refreshLidWhileHeld() {
        guard state.session?.lidHoldRequested == true else { return }
        Task { @MainActor [weak self] in await self?.refreshLid() }
    }

    public var payload: KeepAwakePayload {
        let floor = settings().batteryFloor
        switch state {
        case .ready:
            return KeepAwakePayload(phase: .ready, minutes: chosenMinutes,
                                    batteryFloor: floor, lid: lidState,
                                    problem: problem)
        case .running(let session):
            return KeepAwakePayload(
                phase: .running,
                remaining: session.remaining(at: now()) ?? 0,
                held: session.elapsed(at: now()),
                isIndefinite: session.isIndefinite,
                until: session.deadline.map(formatTime) ?? "",
                minutes: chosenMinutes,
                batteryFloor: floor,
                // Derived here and nowhere else, so the flag and the reading
                // it comes from cannot disagree on the card.
                lidHeld: lidState.isLive,
                lidClosed: session.lidHoldRequested,
                lid: lidState,
                resumed: announcesResume
            )
        case .finished(let finish):
            return KeepAwakePayload(
                phase: .finished(finish.reason),
                remaining: 0,
                held: finish.ran,
                isIndefinite: finish.deadline == nil,
                until: finish.deadline.map(formatTime) ?? "",
                minutes: chosenMinutes,
                batteryFloor: floor,
                // The session is over, so nothing is held — but whether it was
                // a lid-closed one still decides which sentence the end gets:
                // "open the lid and give it air" is advice for a Mac that is
                // shut, and nonsense for one that is not.
                lidClosed: finishedWithLid,
                lid: lidState,
                resumable: finish.canResume(at: now()) ? finish.remaining : nil,
                endUnrecorded: finish.endUnrecorded,
                // A Resume that was refused leaves the card where it was, so
                // the sentence explaining why has to be readable from here —
                // otherwise pressing Resume and having nothing happen is the
                // whole of the feedback.
                problem: problem
            )
        }
    }

    private func publish() {
        lastPublishedLabel = nil
        continuation?.yield(.publish(activity))
    }

    /// The activity as published, for tests that care about its shelf life.
    public var activityForTesting: Activity { activity }

    private var activity: Activity {
        Activity(
            id: ActivityID(kind: .keepAwake, source: identifier),
            createdAt: now().timeIntervalSinceReferenceDate,
            // Only a Finished card is news with a shelf life. Ready is a
            // control the user came looking for, and expiring it took the card
            // off screen twelve seconds after it appeared.
            expiresAfter: {
                if case .finished = state { return 12 }
                return nil
            }(),
            payload: .keepAwake(payload)
        )
    }

    /// Whether the next publish should be announced rather than left to be
    /// found. A resume nobody asked for has to be seen.
    public var announcesResumeOnce: Bool {
        defer { announcesResume = false }
        return announcesResume
    }
}
