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
        hasNotchPanel: @escaping () -> Bool = { true },
        settings: @escaping () -> Settings = { Settings() },
        makeID: @escaping () -> String = { UUID().uuidString },
        formatTime: @escaping (Date) -> String = KeepAwakeProvider.defaultTimeFormat
    ) {
        self.init(now: now, assertion: assertion, power: power, thermal: thermal,
                  journal: KeepAwakeJournalWorker(journal), tombstone: tombstone,
                  bootID: bootID, hasNotchPanel: hasNotchPanel, settings: settings,
                  makeID: makeID, formatTime: formatTime)
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
    @discardableResult
    public func begin(minutes: Int) async -> Bool {
        guard case .ready = state, pendingStart == nil else { return false }
        guard let boot = bootID else {
            problem = .assertionRefused
            publish()
            return false
        }
        let session = KeepAwakeReducer.start(
            from: .ready, minutes: minutes, now: now(), id: makeID(), bootID: boot
        )?.session
        guard let session else { return false }
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
        publish()
        return true
    }

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
        let decision = KeepAwakeFloors.decide(
            battery: battery,
            floor: settings().batteryFloor,
            missCount: batteryMisses,
            thermal: thermal.state,
            lidClosed: false,
            // Phase 1 never holds the lid closed, so a failed battery read is
            // not a reason to cut a session the user can see for themselves.
            enforcesUnreadable: false
        )
        guard case .end(let reason) = decision else { return }
        endNow(reason: reason)
    }

    // MARK: - Assertion

    private func acquire(for session: KeepAwakeSession) -> Bool {
        assertion.acquire(
            name: IOPMSleepAssertion.assertionName,
            details: "until \(formatTime(session.deadline))",
            timeout: session.remaining(at: now()) + Self.powerdMargin
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
        let timeout = session.remaining(at: now()) + Self.powerdMargin
        if assertion.rearm(timeout: timeout) { return }
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
        }
    }

    // MARK: - Timers and publishing

    private func armDeadline() {
        cancelDeadline()
        guard let session = state.session else { return }
        let left = session.remaining(at: now())
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.deadlineTick() }
        }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(left, 0.02), execute: work)
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
        let left = session.remaining(at: now())
        let delay: TimeInterval = left <= 60
            ? max(0.2, left.truncatingRemainder(dividingBy: 1) + 0.02)
            : left.truncatingRemainder(dividingBy: 60) + 0.02
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.publish()
                self?.armPublish()
            }
        }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.2), execute: work)
    }

    private func cancelPublish() {
        publishWork?.cancel()
        publishWork = nil
    }

    public var payload: KeepAwakePayload {
        let floor = settings().batteryFloor
        switch state {
        case .ready:
            return KeepAwakePayload(phase: .ready, minutes: chosenMinutes,
                                    batteryFloor: floor, problem: problem)
        case .running(let session):
            return KeepAwakePayload(
                phase: .running,
                remaining: session.remaining(at: now()),
                until: formatTime(session.deadline),
                minutes: chosenMinutes,
                batteryFloor: floor,
                resumed: announcesResume
            )
        case .finished(let finish):
            return KeepAwakePayload(
                phase: .finished(finish.reason),
                remaining: 0,
                until: formatTime(finish.deadline),
                minutes: chosenMinutes,
                batteryFloor: floor,
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
