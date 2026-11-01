import Foundation
import LedgeHelperKit
import OSLog

/// When a daemon with nothing to do should stop existing.
///
/// Its own type so the rule can be read and tested without starting anything:
/// the one thing that must never happen is a daemon exiting while a claim of
/// its own is outstanding, because the next thing that would put the setting
/// back is a launchd restart nobody has asked for.
enum IdleExit {

    /// How long with nothing happening before the daemon lets go. Shared
    /// with the app, which waits this out after an update.
    static var after: TimeInterval { HelperLimits.idleExitAfter }

    /// - Parameter replaced: the file this process was started from is no
    ///   longer the one at its path — an update has swapped the bundle. A
    ///   clean daemon then leaves at once, connections or no connections:
    ///   nothing it answers can pass the app's check any more, and a client
    ///   that stays connected to it is exactly what kept the old copy alive
    ///   until a reboot. The client reconnects through launchd on its next
    ///   call and gets the new copy.
    ///
    ///   Never without `clean`. A daemon that exits with a claim outstanding
    ///   leaves the setting held with nobody watching the lease, and the new
    ///   copy does not inherit the hold — so the old one stays until it has
    ///   put everything back, replaced or not.
    static func shouldExit(clean: Bool, connections: Int, idleFor: TimeInterval,
                           replaced: Bool = false) -> Bool {
        guard clean else { return false }
        if replaced { return true }
        return connections == 0 && idleFor >= after
    }
}

/// The root process, with everything it owns on one serial queue.
///
/// `@unchecked Sendable` because the queue is the whole of the promise: every
/// stored property below is read and written on `queue` and nowhere else, and
/// XPC calls — which arrive on whatever thread libxpc likes — do nothing but
/// hop onto it. The core it drives says why this is a queue and not an actor.
final class KeepAwakeDaemon: NSObject, NSXPCListenerDelegate, KeepAwakeHelperProtocol,
                             @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake-helper")

    private let queue = DispatchQueue(label: "com.egemert.ledge.keepawake.helper")
    /// A second queue, so the ninety-second bound does not depend on the first
    /// one being healthy.
    ///
    /// The control queue runs synchronous claim-store I/O, and a save that
    /// does not come back takes the lease expiry with it. The promise this
    /// daemon makes is about time, not about a disk answering, so the thing
    /// that keeps the promise cannot be queued behind the disk.
    private let watchQueue = DispatchQueue(label: "com.egemert.ledge.keepawake.watchdog",
                                           qos: .utility)
    private let arguments: HelperArguments
    private let core: HelperCore
    private let watchdog: LeaseWatchdog
    private var watchTimer: DispatchSourceTimer?
    private let timer: QueueTimer
    private let listener: NSXPCListener
    private let exitProcess: @Sendable (Int32) -> Void
    /// Which file this process was started from, so it can tell when an
    /// update has replaced it.
    private let runningCopy: RunningCopy

    private var tally = ConnectionTally()
    private var connections: Int { tally.live }
    /// Only ever read and written on the listener's own callbacks, which
    /// libxpc serialises per listener.
    private var nextConnectionID = 1
    private var lastActivity = Date()
    private var idleCheck: DispatchSourceTimer?
    private var terminationSignal: DispatchSourceSignal?
    private var terminating = false
    /// Whether `start` takes SIGTERM over. Always in the daemon; a test that
    /// runs the whole daemon in its own process must not leave that process
    /// ignoring SIGTERM afterwards.
    private let handlesTermination: Bool

    /// - Parameters:
    ///   - listener: the daemon's mach service in production. A test passes
    ///     an anonymous listener, so the exit paths that hang off connections
    ///     closing and releases landing can be driven without launchd.
    ///   - handlesTermination: false only in a test; see the property.
    init(arguments: HelperArguments,
         store: any ClaimStore,
         pmset: ProcessPmsetRunner,
         watchdogPmset: any PmsetRunner,
         bootID: String = BootSessionID.current(),
         runningCopy: RunningCopy = .atLaunch(),
         listener: NSXPCListener? = nil,
         handlesTermination: Bool = true,
         exitProcess: @escaping @Sendable (Int32) -> Void = { exit($0) }) {
        self.arguments = arguments
        self.store = store
        self.runningCopy = runningCopy
        self.exitProcess = exitProcess
        self.handlesTermination = handlesTermination
        self.listener = listener ?? NSXPCListener(machServiceName: arguments.label)
        let timer = QueueTimer(queue: queue)
        self.timer = timer
        // Its own runner, so a watchdog write is never queued behind whatever
        // the core has in flight — which, when this fires, is very likely the
        // thing that is stuck.
        let watchdog = LeaseWatchdog(clock: SystemHelperClock(),
                                     pmset: watchdogPmset,
                                     boot: bootID,
                                     log: OSLogHelperLog())
        self.watchdog = watchdog
        self.core = HelperCore(label: arguments.label, bootID: bootID,
                               clock: SystemHelperClock(), store: store, pmset: pmset,
                               timer: timer, log: OSLogHelperLog(), watchdog: watchdog)
        super.init()

        timer.onFire = { [weak self] in self?.core.tick() }
        // The watchdog's children report to the watchdog, on the watchdog's
        // own queue. A write it cannot read back is an attempt, not a restore.
        watchdogPmset.report(to: { [weak watchdog] opID, outcome in
            watchdog?.childFinished(opID: opID, outcome: outcome)
        })
        // And separately: a write it had already answered for, finishing.
        // The watchdog stops believing its own cached restore, and the core
        // stops believing a reading taken while that child was still alive —
        // which it would otherwise go on believing until the next
        // thirty-second re-verify.
        // And the window opening, before the failure that opens it. Both the
        // watchdog and the core have to know that an answered operation's
        // writer can still act: the watchdog so it does not admit another on
        // top, the core so it does not throw away the record of what Ledge
        // changed on the strength of a reading taken in the gap.
        watchdogPmset.reportUnsettled(to: { [weak self, weak watchdog] opID, _ in
            watchdog?.noticeLiveWriter(opID: opID)
            guard let self else { return }
            queue.async { self.core.noticeLiveWriter(opID: opID) }
        })
        watchdogPmset.reportSettled(to: { [weak self, weak watchdog] opID, _ in
            watchdog?.writerSettled(opID: opID)
            guard let self else { return }
            queue.async { self.core.noticeLateWrite(opID: opID) }
        })
        // The runner knows nothing about the core until here, because the core
        // had to be built with the runner in hand.
        pmset.report { [weak self] opID, outcome in
            guard let self else { return }
            queue.async {
                self.core.childExited(opID: opID, outcome: outcome)
                // A restore finishing is the moment a release's work is done
                // and the core can first be clean. Waiting for the next tick
                // would keep a replaced copy up to another minute for nothing.
                self.leaveIfReplaced()
            }
        }
        // The core's own children have the same gap: an operation answered
        // `.failed` over a child that is still alive, whose privileged write
        // lands afterwards.
        pmset.reportUnsettled { [weak self] opID, _ in
            guard let self else { return }
            queue.async { self.core.noticeLiveWriter(opID: opID) }
        }
        pmset.reportSettled { [weak self] opID, _ in
            guard let self else { return }
            queue.async { self.core.noticeLateWrite(opID: opID) }
        }
    }

    // MARK: - Running

    func start() {
        // A connecting process is checked before this object ever hears about
        // it: a peer that does not satisfy the requirement is refused by the
        // listener, and `shouldAcceptNewConnection` is not even called.
        listener.setConnectionCodeSigningRequirement(arguments.requirement)
        listener.delegate = self
        listener.resume()

        // The seed goes first, and the two queues run concurrently — which
        // is why `seed` fences itself on the core's publication count rather
        // than on the value it finds. Whichever gets there first, the core is
        // the authority and a seed answering after it is stale.
        watchQueue.async { [self] in
            watchdog.seed { try? store.load().claims[arguments.label] }
            watchTheLease()
        }
        queue.async { [self] in
            core.start()
            if handlesTermination { watchForTermination() }
            watchForIdleness()
        }
        Self.log.notice("keep awake helper: \(self.arguments.label, privacy: .public) is listening")
    }

    /// Asks the one question the control queue may be too stuck to ask.
    ///
    /// Every few seconds, on a queue that does no file I/O and talks to
    /// nothing: is this Mac past the instant it was promised it could sleep?
    private let store: any ClaimStore

    private func watchTheLease() {
        let source = DispatchSource.makeTimerSource(queue: watchQueue)
        source.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(2))
        source.setEventHandler { [weak self] in self?.watchdog.check() }
        source.resume()
        watchTimer = source
    }

    /// Stops everything `start` set going. For a test that runs a whole
    /// daemon inside its own process: the daemon itself only ever stops by
    /// exiting, and a test's daemons would otherwise go on ticking for the
    /// rest of the run.
    ///
    /// Marks the daemon as terminating too, so nothing still in flight can
    /// ask for an exit afterwards.
    func stop() {
        listener.invalidate()
        watchQueue.sync {
            watchTimer?.cancel()
            watchTimer = nil
        }
        queue.sync {
            terminating = true
            idleCheck?.cancel()
            idleCheck = nil
            terminationSignal?.cancel()
            terminationSignal = nil
            timer.wake(after: nil)
        }
    }

    private func watchForTermination() {
        // Ignored at the C level first, or the default disposition kills the
        // process before the source ever runs and whatever is claimed stays
        // claimed.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [weak self] in self?.handleTermination() }
        source.resume()
        terminationSignal = source
    }

    /// launchd is taking us down. Everything this label holds is given up, and
    /// then the restores are given what time there is.
    private func handleTermination() {
        guard !terminating else { return }
        terminating = true
        core.sigterm()
        waitForCleanliness(attemptsLeft: 60)
    }

    private func waitForCleanliness(attemptsLeft: Int) {
        if core.isClean {
            Self.log.notice("keep awake helper: clean; exiting")
            return exitProcess(0)
        }
        guard attemptsLeft > 0 else {
            // Out of time. Whatever is unfinished stays in the store, and the
            // next start — this one's or the other build's — picks it up.
            Self.log.error("keep awake helper: exiting with work outstanding")
            return exitProcess(0)
        }
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForCleanliness(attemptsLeft: attemptsLeft - 1)
        }
    }

    private func watchForIdleness() {
        let check = DispatchSource.makeTimerSource(queue: queue)
        check.schedule(deadline: .now() + HelperLimits.idleCheckEvery,
                       repeating: HelperLimits.idleCheckEvery)
        check.setEventHandler { [weak self] in
            guard let self, !terminating else { return }
            let replaced = runningCopy.reading() == .replaced
            guard IdleExit.shouldExit(clean: core.isClean, connections: connections,
                                      idleFor: Date().timeIntervalSince(lastActivity),
                                      replaced: replaced) else {
                return
            }
            if replaced {
                Self.log.notice("keep awake helper: the bundle this copy was started from has been replaced; clean, so exiting for the new one")
            } else {
                Self.log.notice("keep awake helper: nothing to do; exiting until asked again")
            }
            exitProcess(0)
        }
        check.resume()
        idleCheck = check
    }

    /// The replaced-bundle half of the exit rule, asked between ticks.
    ///
    /// Only that half. The ordinary idle rule stays on its tick, exactly as
    /// it was; these are the moments the core may just have become clean —
    /// a restore finishing, a release landing, a client going — and a copy
    /// nothing can hear any more has no reason to wait a minute for the next
    /// tick. On the queue, like everything that reads the core.
    ///
    /// The lease watchdog's children are the one thing `isClean` can see only
    /// late: they report to the core through `queue.async`, and only once an
    /// answered write turns out to be still alive. That is safe to exit
    /// across. The watchdog starts a write only for a published lease that
    /// has lapsed, and a clean core publishes none, so nothing new can start;
    /// and the only write it ever makes is `disablesleep 0`, the same
    /// direction as the restore the core has just finished. At worst one
    /// lands after the new copy's hold, which is the early-sleep case the
    /// watchdog already accepts and the holder's own re-read puts right — and
    /// the ordinary idle exit has always had this same window.
    private func leaveIfReplaced() {
        guard !terminating, core.isClean, runningCopy.reading() == .replaced else { return }
        Self.log.notice("keep awake helper: the bundle this copy was started from has been replaced; clean, so exiting for the new one")
        exitProcess(0)
    }

    // MARK: - Connections

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: KeepAwakeHelperProtocol.self)
        connection.exportedObject = self
        // One identity per accepted connection, and one terminal accounting
        // action for it. Both handlers fire for the same connection — an
        // interruption is not even necessarily its last word — and counting
        // each as a separate disconnection took two off the count for one
        // connection. With two clients connected that reaches zero while one
        // of them is still there, and a daemon that believes nobody is
        // connected is a daemon that idle-exits out from under them.
        let identity = nextConnectionID
        nextConnectionID += 1
        connection.invalidationHandler = { [weak self] in self?.noteClosed(identity) }
        connection.interruptionHandler = { [weak self] in self?.noteClosed(identity) }
        queue.async { [self] in
            tally.opened(identity)
            lastActivity = Date()
        }
        connection.resume()
        return true
    }

    private func noteClosed(_ identity: Int) {
        queue.async { [self] in
            guard tally.closed(identity) else { return }
            lastActivity = Date()
            // An app that has just heard this copy's answers refused drops
            // its connection, and that is when it next matters.
            leaveIfReplaced()
        }
    }

    /// How many clients the tally counts. For a test, which has to know a
    /// close has been counted before it can say what the close did.
    var liveConnections: Int { queue.sync { connections } }

    // MARK: - The protocol

    func status(reply: @escaping (String, Int, Bool, Bool, Bool, Bool, Bool) -> Void) {
        let reply = Reply(reply)
        queue.async { [self] in
            lastActivity = Date()
            let status = core.status
            reply.send(status)
        }
    }

    func hold(session: String, generation: Int, until deadline: Date?, leaseSeconds: Double,
              reply: @escaping (Int) -> Void) {
        let reply = Code(reply)
        queue.async { [self] in
            lastActivity = Date()
            core.hold(session: session, generation: generation, deadline: deadline,
                      leaseSeconds: leaseSeconds) { code in reply.send(code) }
        }
    }

    func release(session: String, generation: Int, reply: @escaping (Int) -> Void) {
        let reply = Code(reply)
        queue.async { [self] in
            lastActivity = Date()
            core.release(session: session, generation: generation) { code in reply.send(code) }
            // Usually not clean yet — the restore it set off is still
            // running, and its end is asked about when the child exits. A
            // release of something no longer held is clean already.
            //
            // The reply above is only queued, so an exit here can beat it out
            // of the process. That costs nothing. From a replaced copy the
            // reply would fail the app's check anyway, and the app ignores a
            // release's answer either way: a refusal starts its handover, an
            // interruption is an ordinary failure, and its next call reaches
            // the new copy through launchd. The one case where the reply
            // could have been heard is a bundle renamed over in place, and
            // there the app sees "interrupted" instead of "ok" for a release
            // that landed.
            leaveIfReplaced()
        }
    }

    func setLowPowerMode(_ on: Bool, session: String, generation: Int,
                         reply: @escaping (Int) -> Void) {
        let reply = Code(reply)
        queue.async { [self] in
            lastActivity = Date()
            core.setLowPowerMode(on, session: session, generation: generation) { code in
                reply.send(code)
            }
        }
    }

    /// An XPC reply block, carried onto the serial queue.
    ///
    /// libxpc hands these over as plain Objective-C blocks, which carry no
    /// promise about what thread they may be called on. Each is called exactly
    /// once, on the queue, which is the promise the unchecked conformance
    /// stands on.
    private final class Code: @unchecked Sendable {
        private let block: (Int) -> Void
        init(_ block: @escaping (Int) -> Void) { self.block = block }
        func send(_ code: KeepAwakeHelperCode) { block(code.rawValue) }
    }

    private final class Reply: @unchecked Sendable {
        private let block: (String, Int, Bool, Bool, Bool, Bool, Bool) -> Void
        init(_ block: @escaping (String, Int, Bool, Bool, Bool, Bool, Bool) -> Void) {
            self.block = block
        }
        func send(_ status: HelperStatus) {
            block(status.build, status.sleepDisabled, status.ours, status.clean,
                  status.cleanupPending, status.otherLedgeHolds, status.lowPowerClaimed)
        }
    }
}

/// The core's one wake-up, on the core's own queue.
final class QueueTimer: HelperTimer {

    private let queue: DispatchQueue
    private var source: DispatchSourceTimer?
    var onFire: (() -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    func wake(after nanoseconds: UInt64?) {
        source?.cancel()
        source = nil
        guard let nanoseconds else { return }
        let next = DispatchSource.makeTimerSource(queue: queue)
        next.schedule(deadline: .now() + .nanoseconds(Int(min(nanoseconds, UInt64(Int.max)))),
                      leeway: .milliseconds(50))
        next.setEventHandler { [weak self] in self?.onFire?() }
        next.resume()
        source = next
    }
}

/// What the core has to say, where the system log can keep it.
struct OSLogHelperLog: HelperLog {
    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake-helper")
    func note(_ message: String) {
        Self.log.notice("keep awake helper: \(message, privacy: .public)")
    }
}

/// How many clients are connected, counted by identity rather than by
/// callbacks.
///
/// An `NSXPCConnection` reports its end twice — interruption *and*
/// invalidation — and an interruption is not even necessarily its last word.
/// Counting each callback as a disconnection took two off the count for one
/// connection, so with two clients attached the daemon believed nobody was
/// there and idle-exited out from under the one that was.
///
/// Its own type because the rule is one line and the consequence is a root
/// daemon leaving while somebody is relying on it.
struct ConnectionTally {

    private var open: Set<Int> = []

    var live: Int { open.count }

    mutating func opened(_ identity: Int) { open.insert(identity) }

    /// - Returns: whether this was the connection's *first* terminal callback,
    ///   which is the only one that counts.
    @discardableResult
    mutating func closed(_ identity: Int) -> Bool {
        open.remove(identity) != nil
    }
}
