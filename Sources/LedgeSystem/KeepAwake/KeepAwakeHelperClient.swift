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
    /// The daemon has stopped answering. The hold is probably still standing —
    /// the daemon drops it on its own lease, not on our silence — so this is a
    /// warning, not a death. The heartbeat keeps going.
    case temporarilyUnavailable
    /// The daemon answered and said no.
    case refused(KeepAwakeHelperCode)
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
    /// How long to wait for one call.
    ///
    /// Deliberately longer than the heartbeat interval. The daemon answers a
    /// renewal only once it is on disk, and that write may queue behind a
    /// `pmset` transaction holding the lock, so a reply can honestly take ~20 s
    /// — treating that as failure would turn a healthy slow daemon into a
    /// reported outage. Shorter than the lease, so a daemon that has genuinely
    /// stopped answering is noticed with time left to do something about it.
    public static let callTimeout: TimeInterval = 45

    private let link: KeepAwakeHelperLink
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// The session being held, and the generation it is being held under.
    ///
    /// The generation exists because a lease can lapse without anybody
    /// noticing at the time: the Mac sleeps, the app is suspended, the daemon
    /// restarts. When it does, the daemon retires that generation, and a
    /// heartbeat still carrying it is answered `stale` on purpose. Carrying on
    /// with the same number would retry a request the daemon has already
    /// decided about, forever.
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

    /// The last thing the daemon actually said, if it has said anything.
    private var lastStatus: KeepAwakeHelperStatus?

    public init(link: KeepAwakeHelperLink,
                now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(for: .seconds($0))
                }) {
        self.link = link
        self.now = now
        self.sleep = sleep
    }

    public var currentState: KeepAwakeHelperState { state }
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
        let outcome = await renew()
        // A `begin` that was overtaken by an `end`, or by another `begin`, has
        // nothing left to start a heartbeat for.
        guard lifecycle == era else { return state }
        startBeating()
        return outcome
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

        // `issuedGeneration`, not `generation`: a hold still in flight has
        // already named a number to the daemon, and releasing the one this
        // client had heard back about would leave that one holding the Mac.
        guard let id, sent > 0 else { return }
        _ = try? await withTimeout { [link] in
            try await link.release(session: id, generation: sent)
        }
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
        guard let id = session, let on = lowPowerWanted, generation > 0 else { return nil }
        do {
            return try await withTimeout { [link, generation] in
                try await link.setLowPowerMode(on, session: id, generation: generation)
            }
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
        let answer = try? await withTimeout { [link] in try await link.status() }
        if let answer { lastStatus = answer }
        return answer
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
        guard session != nil else { return }
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
        let asked = deadline

        let answer: KeepAwakeHelperCode?
        do {
            answer = try await withTimeout { [link] in
                try await link.hold(session: id, generation: attempt,
                                    until: asked, leaseSeconds: Self.lease)
            }
        } catch {
            answer = nil
        }

        // The session can have ended, or been replaced, while this was out.
        // Anything decided for an era that is over is decided about nothing.
        guard lifecycle == era, session == id else { return state }

        guard let answer else {
            // Silence is not death. The daemon lets go on its own lease, not
            // on our inability to reach it, so the hold is very likely still
            // standing — and the next heartbeat may well land. Keep the
            // generation: nothing has told us it was retired.
            state = .temporarilyUnavailable
            return state
        }

        generation = attempt

        switch answer {
        case .ok:
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
        let status = try? await withTimeout { [link] in try await link.status() }
        guard lifecycle == era, session == id else { return state }
        guard let status else { return .pending }
        lastStatus = status
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

            let answer = try? await withTimeout { [link] in
                try await link.hold(session: id, generation: attempt,
                                    until: self.deadline, leaseSeconds: Self.lease)
            }
            guard lifecycle == era, session == id else { return state }
            guard let answer else { return .temporarilyUnavailable }

            generation = attempt
            switch answer {
            case .ok:
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
        session = nil
        deadline = nil
        generation = 0
        issuedGeneration = 0
        lowPowerWanted = nil
        state = .idle
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
        return try await withCheckedThrowingContinuation { continuation in
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
    }
}

/// The daemon did not answer in time.
public struct KeepAwakeHelperTimeout: Error, Sendable {}
