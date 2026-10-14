import Foundation
import LedgeHelperKit
import OSLog

/// How a child that will not finish is ended: asked first, then made to.
///
/// Its own type so the order and the gap between the two can be checked
/// without a child to practise on. SIGTERM first because `pmset` given the
/// chance to finish leaves the setting in a state it meant to leave it in;
/// SIGKILL after, because a root daemon that can be held open by a child that
/// will not die is a daemon that never gets to the restore it owes.
struct Escalation {

    let limit: TimeInterval
    let grace: TimeInterval

    /// - Returns: the two scheduled steps, to be cancelled once the child has
    ///   been reaped.
    func schedule(on queue: DispatchQueue,
                  send: @escaping @Sendable (Int32) -> Void) -> [DispatchWorkItem] {
        let ask = DispatchWorkItem { send(SIGTERM) }
        let make = DispatchWorkItem { send(SIGKILL) }
        queue.asyncAfter(deadline: .now() + limit, execute: ask)
        queue.asyncAfter(deadline: .now() + limit + grace, execute: make)
        return [ask, make]
    }
}

/// Runs `/usr/bin/pmset` as a child, and never waits for it where it matters.
///
/// There is no public API for the sleep setting, so this is the whole
/// privileged act of the feature: one command, with an argument array and no
/// shell. Everything else in the daemon exists to decide whether to run it and
/// to make sure it gets undone.
///
/// The core is never blocked by any of this. It starts an operation and goes
/// back to handling events — a lease expiry, a release, a SIGTERM — and the
/// result arrives later as `childExited`, which is the only thing that makes
/// "the lease lapses on time even while a write is hung" true.
final class ProcessPmsetRunner: PmsetRunner, @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake-helper")

    /// How long the output drains are given, once the escalation has had its
    /// full run at the child.
    ///
    /// The escalation sends SIGTERM at `limit` and SIGKILL `grace` later, so
    /// by `limit + grace` a child that can be killed is dead and its pipes are
    /// closed. The extra second is for the drains to notice.
    static func drainBudget(after limit: TimeInterval, grace: TimeInterval) -> TimeInterval {
        limit + grace + 1
    }

    /// The real tool. Named here and passed in by `main`, so that a caller
    /// that forgets to say which tool it wants does not get this one: nothing
    /// in a test may ever change this Mac's power settings.
    static let pmset = "/usr/bin/pmset"

    private let tool: String
    private let readLimit: TimeInterval
    private let writeLimit: TimeInterval
    private let killGrace: TimeInterval
    private let work: DispatchQueue
    private let signals: DispatchQueue
    /// Where a child whose pipes outlasted its operation is collected.
    ///
    /// Its own queue, so a zombie nobody is waiting for cannot hold the one
    /// that owes the next restore. `Child.reap` is bounded, so this is too.
    private let reaping: DispatchQueue
    /// How much work this runner may have in flight at once, counting the
    /// children it has abandoned.
    ///
    /// Taken before a child is spawned, so saturation refuses the *work*
    /// rather than abandoning something already created. Each outstanding
    /// operation costs a child, two blocking reads and two descriptors; the
    /// abandoned ones cost them for as long as whatever inherited the pipe
    /// lives, which is why the budget is held until the drains are done and
    /// not merely until the child is collected.
    private let outstanding: Permits
    /// The syscalls a child is collected and signalled through.
    ///
    /// Injectable for one reason: a child that cannot be collected is the
    /// case where the runner's resource ownership matters most, and there is
    /// no benign way to produce an uncollectable process.
    private let syscalls: Child.Syscalls

    /// Children nobody could collect, kept so that somebody still can.
    ///
    /// Holding a permit for an uncollected child is right: the pid is still
    /// ours and the resources it stands for are still spoken for. But "still
    /// ours" is a state that *ends* — the obstruction clears, the child
    /// exits, the pid becomes collectable — and nothing was watching for
    /// that. The counter had been decremented and the `Child` thrown away, so
    /// eight transient failures emptied the runner for the life of the
    /// process: a root helper owing a sleep or Low Power Mode restore could
    /// no longer start the very work that would discharge it, long after
    /// every child had exited. A bounded refusal had quietly become a stuck
    /// Mac.
    ///
    /// So the obligation is retained rather than abandoned, and asked again
    /// on a slow cadence of its own — never on the command queue, which has a
    /// restore to get back to. The permit comes back only when the child is
    /// established as collected (or as no longer ours) *and* the drains that
    /// still hold its descriptors have finished. Nothing here admits an extra
    /// child to compensate: the registry is bounded by the permits themselves,
    /// one entry per permit it is waiting to return.
    private let salvage: Salvage

    final class Salvage: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [(child: Child, drains: DispatchGroup?,
                              command: PmsetCommand, opID: Int)] = []
        private var timer: DispatchSourceTimer?
        private let queue: DispatchQueue
        private let permits: Permits
        private let interval: TimeInterval

        private let settled: SettleSink

        init(queue: DispatchQueue, permits: Permits, interval: TimeInterval,
             settled: SettleSink) {
            self.queue = queue
            self.permits = permits
            self.interval = interval
            self.settled = settled
        }

        /// Takes ownership of a child whose permit is still held.
        ///
        /// Identity travels with it. Capacity was only ever half of what the
        /// registry owes: the other half is that somebody asked for this
        /// write, was told it failed, and acted on that — so when the child
        /// finally stops, the thing that asked has to be told which of its
        /// writes it was.
        func keep(_ child: Child, drains: DispatchGroup?,
                  command: PmsetCommand, opID: Int) {
            lock.withLock {
                pending.append((child, drains, command, opID))
                guard timer == nil else { return }
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now() + interval, repeating: interval)
                source.setEventHandler { [weak self] in _ = self?.sweep() }
                timer = source
                source.resume()
            }
        }

        /// One pass over everything outstanding.
        ///
        /// Each attempt is a single non-blocking question, not the bounded
        /// poll an operation waits on: this runs on a timer and must not
        /// occupy anything.
        /// - Returns: how many permits came back this pass.
        @discardableResult
        func sweep() -> Int {
            let candidates = lock.withLock { pending }
            guard !candidates.isEmpty else { return 0 }

            var taken: [ObjectIdentifier] = []
            var freed = 0
            for entry in candidates where entry.child.collect() {
                taken.append(ObjectIdentifier(entry.child))
                freed += 1
                Self.log.notice("keep awake helper: collected a pmset child that had been stuck")
                // The write is over, whichever way it went, and that is the
                // news. Resource accounting was never the whole obligation:
                // the operation reported `.failed` while this child was still
                // alive, and anything that read a power setting in the gap
                // read it before this write landed.
                settled.deliver(entry.opID, entry.command)
                // The descriptors are the other half of the obligation, and
                // only their readers can say when they are done with them.
                // Waited for away from this pass, so one child holding a pipe
                // open cannot stall the collection of the next — but a child
                // whose drains were already finished owes nothing further,
                // and its slot comes back here rather than one hop later.
                if let drains = entry.drains {
                    queue.async { [permits] in
                        drains.wait()
                        permits.give()
                    }
                } else {
                    permits.give()
                }
            }
            guard !taken.isEmpty else { return 0 }

            lock.withLock {
                pending.removeAll { taken.contains(ObjectIdentifier($0.child)) }
                if pending.isEmpty {
                    timer?.cancel()
                    timer = nil
                }
            }
            return freed
        }

        var outstandingCount: Int { lock.withLock { pending.count } }

        private static let log = Logger(subsystem: "com.egemert.ledge.keepawake",
                                        category: "pmset")
    }

    /// A fixed number of permits, taken and given back.
    final class Permits: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        init(_ count: Int) { left = count }
        func take() -> Bool {
            lock.withLock {
                guard left > 0 else { return false }
                left -= 1
                return true
            }
        }
        func give() { lock.withLock { left += 1 } }
        var available: Int { lock.withLock { left } }
    }

    /// Where results go. Set once, during composition, because the core needs
    /// the runner before the runner can know the core.
    private let sink = Sink()
    private let settled = SettleSink()
    /// The other half of the pair: a writer that can still act, announced
    /// before its operation is answered for.
    private let unsettled = SettleSink()

    /// - Parameter outstandingLimit: how many operations may be in flight at
    ///   once, counting those whose pipes outlived their child. Past it a new
    ///   operation is refused before it creates anything.
    /// How often a child nobody could collect is asked again.
    ///
    /// Slow on purpose. The thing it is waiting for — a wedged process
    /// finally leaving the kernel — happens on its own schedule, and polling
    /// it hard would spend the helper's cycles to learn nothing sooner.
    static let salvageInterval: TimeInterval = 5

    init(tool: String,
         readLimit: TimeInterval = 5,
         writeLimit: TimeInterval = 10,
         killGrace: TimeInterval = 2,
         outstandingLimit: Int = 8,
         salvageInterval: TimeInterval = ProcessPmsetRunner.salvageInterval,
         syscalls: Child.Syscalls = .real) {
        let permits = Permits(outstandingLimit)
        self.outstanding = permits
        self.syscalls = syscalls
        self.tool = tool
        self.readLimit = readLimit
        self.writeLimit = writeLimit
        self.killGrace = killGrace
        self.work = DispatchQueue(label: "com.egemert.ledge.keepawake.pmset", qos: .userInitiated)
        self.signals = DispatchQueue(label: "com.egemert.ledge.keepawake.pmset.timeout",
                                     qos: .userInitiated)
        // Concurrent: collection is bounded and independent per child, and a
        // serial one meant the first orphan's collector was the only one
        // there was.
        self.reaping = DispatchQueue(label: "com.egemert.ledge.keepawake.pmset.reaping",
                                     qos: .utility, attributes: .concurrent)
        self.salvage = Salvage(queue: reaping, permits: permits, interval: salvageInterval,
                               settled: settled)
    }

    /// One salvage pass, now, on the calling thread.
    ///
    /// The timer's work, exposed so a test can say *when* it happened. A
    /// sweep that can only be waited for is a sweep a loaded machine turns
    /// into a sleep-and-hope, and the claim being made here — that capacity
    /// comes back once collection becomes possible — needs a positive
    /// barrier rather than a plausible interval.
    @discardableResult
    func salvageNow() -> Int { salvage.sweep() }

    /// How many children are still waiting to be collected.
    var unsalvagedCount: Int { salvage.outstandingCount }

    /// How much capacity this runner has left.
    ///
    /// The number the whole finding is about: a slot that is spoken for by a
    /// child nobody could collect must come back when that changes, and
    /// "the next operation was not refused" is a weaker statement than this.
    var availableSlots: Int { outstanding.available }

    func report(to receiver: @escaping @Sendable (Int, PmsetOutcome) -> Void) {
        sink.set(receiver)
    }

    func reportSettled(to receiver: @escaping @Sendable (Int, PmsetCommand) -> Void) {
        settled.set(receiver)
    }

    func reportUnsettled(to receiver: @escaping @Sendable (Int, PmsetCommand) -> Void) {
        unsettled.set(receiver)
    }

    func start(_ command: PmsetCommand, opID: Int) {
        work.async { [self] in
            let outcome = run(command, opID: opID)
            sink.deliver(opID, outcome)
        }
    }

    // MARK: - One child

    private func run(_ command: PmsetCommand, opID: Int) -> PmsetOutcome {
        // Taken before anything is created, and held until the child *and*
        // both of its drains have finished. Taking it after the spawn bounded
        // only the collectors: the children, the two blocking reads and the
        // descriptors behind them were already made by then, and giving the
        // permit back while the drains still held them bounded nothing at all.
        guard outstanding.take() else {
            Self.log.error("keep awake helper: too much is already outstanding to start another")
            return .failed("too many pmset operations are already outstanding")
        }
        var permitHeld = true
        defer { if permitHeld { outstanding.give() } }

        let arguments = Self.arguments(for: command)
        let limit = command.isWrite ? writeLimit : readLimit

        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { return .failed("no pipe (\(errno))") }
        guard pipe(&err) == 0 else {
            close(out[0]); close(out[1])
            return .failed("no pipe (\(errno))")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        // The child starts with no signal blocked and every handler back at
        // its default. Both halves are load-bearing. A spawn inherits the
        // *calling thread's* mask, and the dispatch queue this runs on blocks
        // most signals, so a child left with that mask would hold our SIGTERM
        // pending forever and only ever die to SIGKILL. And an ignored signal
        // survives exec, so the daemon's own `signal(SIGTERM, SIG_IGN)` — which
        // is how it hears launchd at all — would otherwise be handed straight
        // to `pmset`.
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        // Everything but the three descriptors named above is closed in the
        // child. The one that matters is the claim store's lock: a copy of it
        // in a process we are about to lose control of is a lock we can no
        // longer account for.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGMASK
                                                    | POSIX_SPAWN_SETSIGDEF))

        var pid: pid_t = 0
        // The child is given an environment, not ours. A root process passing
        // on whatever launchd handed it would be passing on `DYLD_*` and the
        // rest along with it; passing nothing at all is worse than it sounds,
        // because a program with no environment at all is a program running in
        // conditions nobody tests for.
        let spawned = Self.withArgv([tool] + arguments) { argv in
            Self.withArgv(Self.childEnvironment) { environment in
                posix_spawn(&pid, tool, &actions, &attributes, argv, environment)
            }
        }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(out[1])
        close(err[1])

        guard spawned == 0 else {
            close(out[0]); close(err[0])
            return .failed("could not start \(tool) (\(spawned))")
        }

        let child = Child(pid: pid, syscalls: syscalls)
        let ending = Escalation(limit: limit, grace: killGrace)
            .schedule(on: signals) { number in child.signal(number, timedOut: true) }

        // Both pipes are drained while the child is still running. A child that
        // fills one and blocks writing to it would otherwise never exit, and
        // the kill would be the only thing that ever ended it.
        let group = DispatchGroup()
        let collected = Drained()
        let outRead = out[0]
        let errRead = err[0]
        DispatchQueue.global(qos: .utility).async(group: group) {
            collected.set(standardOutput: Self.drain(outRead))
        }
        DispatchQueue.global(qos: .utility).async(group: group) {
            collected.set(standardError: Self.drain(errRead))
        }

        // Bounded, because the reap below is bounded and a bound downstream of
        // an unbounded wait is not a bound. These drains read to end of file,
        // and end of file arrives when the last writer closes — which is the
        // child, *or* anything the child handed the descriptor to. A child
        // that is stuck with its pipes open, or that spawned something which
        // outlives it, would otherwise hold this queue for ever, and this
        // queue is the one that owes the restore.
        if group.wait(timeout: .now() + Self.drainBudget(after: limit, grace: killGrace)) == .timedOut {
            // Ask it to go, then give it one more moment.
            child.signal(SIGKILL, timedOut: true)
            if group.wait(timeout: .now() + killGrace) == .timedOut {
                for step in ending { step.cancel() }
                // The *pipes* are what could not be waited for. The child is a
                // separate obligation and is still ours: very often it has
                // already exited and only a descendant holds stdout, and
                // abandoning it there leaves a zombie behind on every failure.
                // So collection carries on somewhere else, under the same lock
                // that guards the signalling, and the descriptors go with it
                // — a reader still holds them, and closing one out from under
                // it is the worse bug.
                Self.log.error("keep awake helper: a pmset child would not let go of its pipes")
                // Said before the failure is. This operation is about to be
                // answered `.failed`, and the child behind it has not been
                // waited for — it may be running right now with a privileged
                // write ahead of it. Everything downstream has to know that
                // before it acts on the answer, because the dangerous thing
                // is not a stale cache: it is a *fresh* reading being used to
                // throw away the record of what Ledge changed.
                unsettled.deliver(opID, command)
                // Collection only. The *pipes* are what could not be waited
                // for, and waiting for them here is what occupied the one
                // collector: a descendant holding stdout open for ever kept
                // the first orphan's block running, and every child after it
                // stayed a zombie. Collection is bounded; EOF is not, so EOF
                // is not something a collector may be made to wait for.
                //
                // The descriptors stay with the drains that still hold them —
                // closing one under a reader is the worse bug — and the only
                // thing that bounds those is how many of these can be
                // outstanding at once.
                // The permit goes with the work, not with this call. The
                // child is collected now; the drains are left to finish in
                // their own time, and only when they have does the budget
                // come back. Until then this runner will not create another
                // child, another pair of drains or another zombie.
                permitHeld = false
                reaping.async { [outstanding, salvage, settled] in
                    let finished = child.reap()
                    guard finished.collected else {
                        // Not collected, so not finished with. The slot stays
                        // taken, and nothing here claims otherwise — but it
                        // is kept rather than dropped, so that the slot can
                        // come back when collection becomes possible. The
                        // drains go with it: the descriptors are still held
                        // by whatever inherited them, and the permit stands
                        // for those too.
                        salvage.keep(child, drains: group, command: command, opID: opID)
                        Self.log.error("""
                            keep awake helper: an abandoned pmset child could not be \
                            collected; its slot is held
                            """)
                        return
                    }
                    Self.log.notice("""
                        keep awake helper: collected an abandoned child \
                        (status \(finished.status, privacy: .public))
                        """)
                    // The same obligation the registry carries, on the branch
                    // that never reaches it. This operation was answered
                    // `.failed` the moment its pipes timed out, while the
                    // child was still running — and the write it carried has
                    // only now finished. Returning the slot without saying so
                    // left the setting moved and nothing told.
                    settled.deliver(opID, command)
                    // Unbounded in time, bounded in number: this is the one
                    // thing holding the descriptors, and the permit is what
                    // stops them accumulating.
                    group.wait()
                    outstanding.give()
                }
                return .failed("pmset held its output open past \(limit)s")
            }
        }

        // Reaped under the same lock the signals are sent under, so a pid that
        // has been reused cannot be sent a signal meant for this child.
        let finished = child.reap()
        for step in ending { step.cancel() }
        if !finished.collected {
            // Nothing collected this pid, so it is still ours and its slot
            // stays taken. Eight of these and the runner stops starting work
            // — which is the honest bound, and far better than quietly
            // admitting more children nobody can account for.
            //
            // Held, but not abandoned. The child goes to the registry that
            // keeps asking, so that when the obstruction clears the slot
            // comes back instead of being gone for the life of the helper.
            // The drains are already finished on this path — the group was
            // waited out above — so there is nothing else to wait for.
            permitHeld = false
            // Announced *before* the child becomes visible to salvage, not
            // after. Salvage runs on its own queue and can collect and report
            // settlement the instant it can see the child — overtaking this
            // announcement, so the core would be told the writer finished and
            // then told it had started. The pipe-timeout path above already
            // has this order; this one did not.
            unsettled.deliver(opID, command)
            salvage.keep(child, drains: nil, command: command, opID: opID)
            Self.log.error("keep awake helper: a pmset child could not be collected; its slot is held")
        }

        let output = collected.text

        if finished.timedOut {
            Self.log.error("keep awake helper: pmset did not finish in \(limit, privacy: .public)s")
            return .failed("pmset did not finish within \(limit)s")
        }
        // Collected is not answered. If something outside this runner took
        // the child — a stray process-wide reaper, anything calling `wait`
        // on behalf of the whole process — `waitpid` answers `ECHILD` and
        // leaves the status buffer untouched. Reading that zero as an exit
        // of zero reports a `pmset` write that failed as one that worked,
        // and the daemon then believes a setting it never set.
        guard finished.known else {
            Self.log.error("keep awake helper: a pmset child was collected by something else")
            return .failed("pmset's exit status could not be established")
        }
        guard finished.status == 0 else {
            let message = output.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed("pmset exited \(finished.status)\(message.isEmpty ? "" : ": \(message)")")
        }
        guard !command.isWrite else { return .wrote }
        return command.isLowPower
            ? Self.readLowPowerMode(from: output.out)
            : Self.readSleepDisabled(from: output.out)
    }

    // MARK: - Reading the answer

    /// What `pmset -g` says about SleepDisabled.
    ///
    /// A missing line is a 0, not an unknown: `pmset -g` prints the settings
    /// that are in force, and the setting is listed once it has been turned on.
    /// Calling it unknown instead would leave the daemon unable to act on any
    /// Mac where nobody had ever set it — which is every Mac, until the first
    /// time Ledge sets it.
    static func readSleepDisabled(from output: String) -> PmsetOutcome {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("pmset said nothing")
        }
        for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
            guard let last = line.split(whereSeparator: \.isWhitespace).last,
                  let value = Int(last) else {
                return .failed("could not read SleepDisabled from \(line)")
            }
            return .read(value == 0 ? 0 : 1)
        }
        return .read(0)
    }

    /// What `pmset -g custom` says about Low Power Mode, per power source.
    ///
    /// Two sections, "Battery Power:" and "AC Power:", and a Mac may have one
    /// or both — a desktop has no battery. A missing section comes back nil
    /// rather than false, because the two mean different things to a restore:
    /// false is something to put back, absent is something that was never
    /// there and must never have `pmset -b` run at it.
    ///
    /// Within a section a missing `lowpowermode` line is a 0, for the same
    /// reason `SleepDisabled` is: `pmset` prints the settings that are in
    /// force, and calling the absence unknown would leave the daemon unable to
    /// act on any Mac where nobody had ever set it.
    static func readLowPowerMode(from output: String) -> PmsetOutcome {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("pmset said nothing")
        }

        enum Source { case battery, charger }
        var current: Source?
        var battery: Bool?
        var charger: Bool?

        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Battery Power") {
                current = .battery
                battery = false
                continue
            }
            if line.hasPrefix("AC Power") {
                current = .charger
                charger = false
                continue
            }
            guard line.hasPrefix("lowpowermode") else { continue }
            guard let last = line.split(whereSeparator: \.isWhitespace).last,
                  let value = Int(last)
            else { return .failed("could not read lowpowermode from \(line)") }
            // A value with no section above it is output this parser does not
            // understand, and filing it under a guess is how a laptop's
            // battery setting gets written to its charger.
            switch current {
            case .battery: battery = value != 0
            case .charger: charger = value != 0
            case nil: return .failed("lowpowermode appeared before any power source")
            }
        }

        guard battery != nil || charger != nil else {
            return .failed("pmset named no power source")
        }
        return .lowPower(LowPowerSetting(battery: battery, charger: charger))
    }

    /// Everything the child is told about the world.
    static let childEnvironment = ["PATH=/usr/bin:/bin"]

    static func arguments(for command: PmsetCommand) -> [String] {
        switch command {
        case .readSleepDisabled:
            ["-g"]
        case .writeSleepDisabled(let on):
            ["-a", "disablesleep", on ? "1" : "0"]
        case .readLowPowerMode:
            // Both sources, not just the one in force: the value that has to
            // be put back is the one for the source the Mac is *not* on as
            // much as the one it is.
            ["-g", "custom"]
        case .writeLowPowerMode(let on, let source):
            [source.rawValue, "lowpowermode", on ? "1" : "0"]
        }
    }

    // MARK: - Plumbing

    private static func drain(_ descriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                // Kept up to a point, but read to the end whatever happens: a
                // reader that stops reading gives the child SIGPIPE, which
                // would turn "said too much" into "was killed by a signal" and
                // lose whatever it had already said.
                if data.count < 1 << 20 { data.append(contentsOf: buffer[0..<count]) }
            } else if count == 0 || errno != EINTR {
                break
            }
        }
        close(descriptor)
        return data
    }

    private static func withArgv<T>(_ arguments: [String],
                                    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers where pointer != nil { free(pointer) } }
        return body(&pointers)
    }

    /// What the two pipes gave up, written by two queues and read by one.
    private final class Drained: @unchecked Sendable {
        private let lock = NSLock()
        private var standardOutput = Data()
        private var standardError = Data()

        func set(standardOutput data: Data) { lock.withLock { standardOutput = data } }
        func set(standardError data: Data) { lock.withLock { standardError = data } }

        var text: (out: String, err: String) {
            lock.withLock {
                (String(decoding: standardOutput, as: UTF8.self),
                 String(decoding: standardError, as: UTF8.self))
            }
        }
    }

    /// One child, and the two things that can happen to it.
    ///
    /// ## Why the reap is not a blocking `waitpid`
    ///
    /// A pid is the kernel's to reuse the instant `waitpid` collects it. The
    /// obvious shape — block on `waitpid` outside the lock, then take the lock
    /// to mark the child reaped — leaves a window between those two steps in
    /// which the escalation can still pass the `reaped` check and call `kill`.
    /// The pid it names is no longer this child's. In a process running as
    /// root that is a SIGKILL delivered to whatever the system started next.
    ///
    /// So the collection and the retirement happen in the *same* critical
    /// section, with a non-blocking `waitpid`: nothing can be signalled after
    /// the kernel has let go of the pid, because the only path that signals
    /// takes the lock this holds.
    ///
    /// The wait itself is a poll outside the lock, which is the other half of
    /// the rule — holding the lock across a blocking wait would stop the
    /// escalation ever running, and a child that will not die is exactly when
    /// the escalation is needed. The poll backs off to 20 ms, and the ordinary
    /// case does not reach it at all: both pipes are at end of file by the
    /// time this is called, so the child has almost always already exited.
    final class Child: @unchecked Sendable {

        /// The syscalls, injected so a test can hold one open at the exact
        /// instant the other would be unsafe. There is no other way to
        /// exercise an interleaving that lives between two machine
        /// instructions.
        struct Syscalls: Sendable {
            var wait: @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t
            var kill: @Sendable (pid_t, Int32) -> Int32
            var pause: @Sendable (UInt32) -> Void

            static let real = Syscalls(
                wait: { pid, status, flags in waitpid(pid, status, flags) },
                kill: { pid, number in Darwin.kill(pid, number) },
                pause: { usleep($0) }
            )
        }

        private let lock = NSLock()
        private let pid: pid_t
        private let syscalls: Syscalls
        private var reaped = false
        private var timedOut = false
        private(set) var signalsSentAfterReaping = 0

        init(pid: pid_t, syscalls: Syscalls = .real) {
            self.pid = pid
            self.syscalls = syscalls
        }

        func signal(_ number: Int32, timedOut: Bool) {
            lock.withLock {
                guard !reaped else {
                    // Not an error and not rare: the child finished while the
                    // escalation was already on its way. Counted rather than
                    // logged, because the only thing worth knowing is that it
                    // was refused.
                    signalsSentAfterReaping += 1
                    return
                }
                if timedOut { self.timedOut = true }
                _ = syscalls.kill(pid, number)
            }
        }

        /// How long the poll waits between attempts, in microseconds.
        static let pollBackoff: [UInt32] = [200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]

        /// How long the poll will wait in total before it gives up.
        ///
        /// A bound rather than a loop, because the loop has no other end: a
        /// child that neither exits nor dies to its escalation — because the
        /// signals are being refused, or the process is wedged in the kernel —
        /// would spin this queue for the life of the daemon, and the queue has
        /// a restore to get back to. Generous enough that it is never reached
        /// by a `pmset` that is merely slow: the escalation has already sent
        /// SIGTERM and then SIGKILL long before this.
        static let maximumWaitMicroseconds: UInt64 = 60_000_000

        /// One non-blocking question: has this pid become collectable?
        ///
        /// Asked by the registry that owns children the bounded poll gave up
        /// on. It is deliberately not `reap()`: that one waits, which is
        /// right for an operation that needs an answer and wrong for a timer
        /// whose only job is to notice that something changed.
        ///
        /// Exactly the same ownership rule as `reap`: the pid is this child's
        /// until somebody says otherwise, and `ECHILD` is somebody saying so.
        func collect() -> Bool {
            var raw: Int32 = 0
            return lock.withLock {
                let answer = syscalls.wait(pid, &raw, WNOHANG)
                if answer == pid { reaped = true; return true }
                if answer < 0 && errno != EINTR { reaped = true; return true }
                return false
            }
        }

        /// An unreaped child is left to launchd, and is deliberately **not**
        /// marked reaped: nothing collected its pid, so the pid is still the
        /// child's and the escalation may still have it.
        /// - Returns: the exit status, whether the escalation had to be used,
        ///   whether the child was actually *collected*, and whether the
        ///   status is one this child actually reported.
        ///
        ///   Giving up on the poll is not collection: the pid is still this
        ///   child's, and freeing the resources that stand for it is how
        ///   stuck children stopped being bounded at all. And collected is
        ///   not the same as *answered*: `ECHILD` says somebody else has the
        ///   child, so there is no status here to read — the zero that comes
        ///   back with it is an absence, and reporting it as an exit of zero
        ///   turns a write that failed into a write that succeeded.
        func reap() -> (status: Int32, timedOut: Bool, collected: Bool, known: Bool) {
            var attempt = 0
            var waited: UInt64 = 0
            while true {
                var raw: Int32 = 0
                var answered = false
                let collected: Bool = lock.withLock {
                    let answer = syscalls.wait(pid, &raw, WNOHANG)
                    if answer == pid { reaped = true; answered = true; return true }
                    // -1 and not EINTR means there is no such child to
                    // collect — somebody else already did, or it never
                    // existed. Either way this pid is not ours to signal,
                    // and whatever `raw` holds is not this child's status.
                    if answer < 0 && errno != EINTR { reaped = true; return true }
                    return false
                }
                if collected {
                    let exited = (raw & 0x7f) == 0
                    let status = exited ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
                    return lock.withLock {
                        (answered ? Int32(status) : 0, timedOut, true, answered)
                    }
                }
                let pause = Self.pollBackoff[min(attempt, Self.pollBackoff.count - 1)]
                guard waited < Self.maximumWaitMicroseconds else {
                    // Gave up. Reported as a failure, which is what it is: the
                    // operation it belonged to has no answer, and the core
                    // retries from a fresh read rather than believing this
                    // one. Crucially *not* collected — the pid is still this
                    // child's, and whatever stands for it stays held.
                    return lock.withLock { (Int32(128 + SIGKILL), true, false, false) }
                }
                syscalls.pause(pause)
                waited += UInt64(pause)
                attempt += 1
            }
        }
    }

    /// Where the news goes that a write already answered for has finished.
    ///
    /// Its own sink, not the reply sink. The reply was delivered long ago and
    /// the identity it carried has been retired by everything downstream, so
    /// a second ordinary reply would land in the "nobody is waiting on this"
    /// branch and change nothing. This is not a reply.
    final class SettleSink: @unchecked Sendable {
        private let lock = NSLock()
        private var receiver: (@Sendable (Int, PmsetCommand) -> Void)?
        func set(_ receiver: @escaping @Sendable (Int, PmsetCommand) -> Void) {
            lock.withLock { self.receiver = receiver }
        }
        func deliver(_ opID: Int, _ command: PmsetCommand) {
            // Reads change nothing, however late they are.
            guard command.isWrite else { return }
            let receiver = lock.withLock { self.receiver }
            receiver?(opID, command)
        }
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var receiver: (@Sendable (Int, PmsetOutcome) -> Void)?
        func set(_ receiver: @escaping @Sendable (Int, PmsetOutcome) -> Void) {
            lock.withLock { self.receiver = receiver }
        }
        func deliver(_ opID: Int, _ outcome: PmsetOutcome) {
            let receiver = lock.withLock { self.receiver }
            receiver?(opID, outcome)
        }
    }
}

