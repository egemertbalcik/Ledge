import Foundation
import LedgeHelperKit
import os

/// The real connection to the root daemon.
///
/// Everything here exists because an XPC connection has two ways of answering
/// and no promise about how many times: the reply block, and the error handler
/// that fires when the connection is interrupted or invalidated. A naive bridge
/// to `async` resumes a continuation from whichever arrives — and crashes the
/// app, not the daemon, when both do. That is the single most likely way this
/// file could hurt somebody, so it is the thing it is built around.
public final class KeepAwakeXPCLink: @unchecked Sendable, KeepAwakeHelperLink {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake-xpc")

    private let serviceName: String
    private let requirement: String
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// Which connection is current.
    ///
    /// A connection's invalidation and interruption handlers can fire long
    /// after it has been replaced — teardown is asynchronous and the old
    /// object outlives its usefulness. An unqualified `forget()` from one of
    /// them clears whatever is in the slot, which by then is somebody else's
    /// perfectly good connection, and the next call quietly builds a third.
    private var epoch = 0
    /// Calls sent and not yet answered by anything, including by failure.
    private var outstanding = 0

    /// - Parameters:
    ///   - serviceName: the daemon's mach service, which is its launchd label.
    ///   - requirement: what the daemon must satisfy to be talked to. Written
    ///     into the app's Info.plist at signing time by `helper-plist.sh`,
    ///     derived from the identity that signed this very build — so a debug
    ///     app cannot be answered by a release daemon, or either by anything
    ///     signed with another certificate.
    public init(serviceName: String, requirement: String) {
        self.serviceName = serviceName
        self.requirement = requirement
    }

    /// Reads both halves out of the running bundle.
    ///
    /// Returns nil when this build has no requirement recorded, which is how a
    /// locally built, ad-hoc signed app says so: `helper-plist.sh` removes the
    /// key rather than writing a requirement that could never match. A link is
    /// then not merely unused, it is impossible, and the caller shows the
    /// feature as unavailable instead of offering a button that cannot work.
    public static func fromBundle(_ bundle: Bundle = .main) -> KeepAwakeXPCLink? {
        guard let identifier = bundle.bundleIdentifier,
              let requirement = bundle.object(forInfoDictionaryKey: "LedgeHelperRequirement") as? String,
              !requirement.isEmpty
        else { return nil }
        return KeepAwakeXPCLink(serviceName: "\(identifier).keepawake", requirement: requirement)
    }

    // MARK: - The connection

    /// One connection, made on demand and kept.
    ///
    /// `.privileged` is not a preference: without it the lookup goes to the
    /// user's own launchd domain, where a root daemon does not live, and every
    /// call fails with an error that looks like the daemon being absent.
    private func proxy(
        onFailure: @escaping @Sendable (Error) -> Void
    ) -> KeepAwakeHelperProtocol? {
        let live: NSXPCConnection = lock.withLock {
            if let connection { return connection }
            let made = NSXPCConnection(machServiceName: serviceName, options: .privileged)
            made.remoteObjectInterface = NSXPCInterface(with: KeepAwakeHelperProtocol.self)
            // Before resume, never after: a connection that has been resumed
            // may already have carried a message.
            // Not wrapped in a `do`/`catch`: this does not throw on this SDK,
            // it raises an Objective-C exception that Swift cannot catch, so
            // the catch would be unreachable and the comfort it offered
            // false. What actually keeps a malformed requirement from
            // reaching here is `helper-plist.sh`, which compiles both strings
            // with `csreq` at build time and fails the build instead.
            made.setCodeSigningRequirement(requirement)
            epoch += 1
            let mine = epoch
            made.invalidationHandler = { [weak self] in self?.forget(mine) }
            made.interruptionHandler = { [weak self] in self?.forget(mine) }
            made.resume()
            connection = made
            return made
        }
        return live.remoteObjectProxyWithErrorHandler(onFailure) as? KeepAwakeHelperProtocol
    }

    /// Drops the connection so the next call makes a fresh one.
    ///
    /// Both handlers lead here. An interrupted connection can be reused by
    /// AppKit's rules, but a daemon that was interrupted has also, from the
    /// core's point of view, possibly restarted — and a restarted daemon never
    /// inherits its own previous hold. Starting again is the honest thing, and
    /// the client above re-holds under a new generation anyway.
    private func forget(_ which: Int) {
        lock.withLock {
            // Only its own. A late handler from a connection that has already
            // been replaced says nothing about the one in the slot now.
            guard which == epoch else { return }
            connection = nil
        }
    }

    public func invalidate() {
        let old: NSXPCConnection? = lock.withLock {
            let held = connection
            connection = nil
            // Retired, so the handlers this invalidation is about to fire
            // cannot reach whatever replaces it.
            epoch += 1
            return held
        }
        old?.invalidate()
    }

    // MARK: - The calls

    public func status() async throws -> KeepAwakeHelperStatus {
        try await once { resume in
            guard let proxy = self.proxy(onFailure: { resume(.failure($0)) }) else {
                resume(.failure(KeepAwakeXPCUnavailable()))
                return
            }
            proxy.status { build, sleepDisabled, ours, clean, pending, otherLedge, lowPower in
                resume(.success(KeepAwakeHelperStatus(
                    build: build, sleepDisabled: sleepDisabled, ours: ours,
                    clean: clean, cleanupPending: pending,
                    otherLedgeHolds: otherLedge, lowPowerClaimed: lowPower)))
            }
        }
    }

    public func hold(session: String, generation: Int, until deadline: Date?,
                     leaseSeconds: Double) async throws -> KeepAwakeHelperCode {
        try await once { resume in
            guard let proxy = self.proxy(onFailure: { resume(.failure($0)) }) else {
                resume(.failure(KeepAwakeXPCUnavailable()))
                return
            }
            proxy.hold(session: session, generation: generation, until: deadline,
                       leaseSeconds: leaseSeconds) { code in
                resume(.success(Self.code(code)))
            }
        }
    }

    public func release(session: String, generation: Int) async throws -> KeepAwakeHelperCode {
        try await once { resume in
            guard let proxy = self.proxy(onFailure: { resume(.failure($0)) }) else {
                resume(.failure(KeepAwakeXPCUnavailable()))
                return
            }
            proxy.release(session: session, generation: generation) { code in
                resume(.success(Self.code(code)))
            }
        }
    }

    public func setLowPowerMode(_ on: Bool, session: String,
                                generation: Int) async throws -> KeepAwakeHelperCode {
        try await once { resume in
            guard let proxy = self.proxy(onFailure: { resume(.failure($0)) }) else {
                resume(.failure(KeepAwakeXPCUnavailable()))
                return
            }
            proxy.setLowPowerMode(on, session: session, generation: generation) { code in
                resume(.success(Self.code(code)))
            }
        }
    }

    /// A code the daemon does not know about arrives as a number.
    ///
    /// The wire carries `Int` precisely so a daemon newer than this app can
    /// answer something this app has never heard of without the call failing
    /// to decode. An unknown number is treated as a refusal, which is the safe
    /// direction: it ends with the Mac allowed to sleep.
    static func code(_ raw: Int) -> KeepAwakeHelperCode {
        guard let known = KeepAwakeHelperCode(rawValue: raw) else {
            log.error("keep awake: the daemon answered with an unknown code \(raw, privacy: .public)")
            return .pmsetFailed
        }
        return known
    }

    /// Bridges a reply-block call to `async`, resuming exactly once.
    /// Internal rather than private so a test can drive the real thing.
    ///
    /// The accounting lives inside `FirstAnswerOnly`'s winning transition, and
    /// a test that exercises the gate directly cannot tell whether this
    /// function puts it there — moving it back outside left those tests
    /// passing. The bug was never in the gate; it was in this placement, so
    /// this is what has to be reachable.
    func once<T: Sendable>(
        _ body: @escaping @Sendable (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        beganOne()
        return try await withCheckedThrowingContinuation { continuation in
            let gate = FirstAnswerOnly(continuation,
                                       accounting: { [weak self] in self?.finishedOne() })
            body { gate.deliver($0) }
        }
    }

    // MARK: - How many calls are still in the air

    /// A connection that stays up and stops answering is the worst shape of
    /// trouble here: every call is parked in a continuation only the daemon
    /// can resume, the caller above gives up at its timeout, and the next
    /// heartbeat adds another. Nothing ever releases them, so they pile up
    /// one per call for as long as the session lasts.
    ///
    /// Invalidating the connection is what releases them — XPC calls every
    /// pending reply's error handler on teardown — so past this many the
    /// connection is torn down and the next call builds a fresh one. That is
    /// the only lever there is: an abandoned XPC call cannot be cancelled.
    static let outstandingLimit = 8

    private func beganOne() {
        let tooMany: Bool = lock.withLock {
            outstanding += 1
            return outstanding > Self.outstandingLimit
        }
        guard tooMany else { return }
        Self.log.error("keep awake: more than \(Self.outstandingLimit, privacy: .public) calls unanswered; dropping the connection to release them")
        invalidate()
    }

    private func finishedOne() {
        lock.withLock { outstanding = max(0, outstanding - 1) }
    }

    /// For tests, and for anything that wants to know the daemon is wedged.
    public var callsInFlight: Int { lock.withLock { outstanding } }
}

/// Lets exactly one answer through to a continuation.
///
/// XPC may call the reply block, or the error handler, or — when a connection
/// drops around the moment an answer arrives — both, and it makes no promise
/// about which thread either arrives on. A continuation resumed twice traps
/// the process, so this is not a tidiness measure: it is the difference
/// between a daemon that goes away and an app that dies with it.
///
/// Its own type so the property can be tested. Inside a method that also
/// builds an `NSXPCConnection`, the one thing worth proving would need a root
/// daemon to prove it against.
final class FirstAnswerOnly<T: Sendable>: @unchecked Sendable {

    private let state = OSAllocatedUnfairLock(initialState: false)
    private let onFirst: @Sendable (Result<T, Error>) -> Void

    init(_ continuation: CheckedContinuation<T, Error>,
         accounting: (@Sendable () -> Void)? = nil) {
        // The continuation is not Sendable, and under strict concurrency it
        // cannot be stored. Captured in a closure it is reached exactly once,
        // which is the invariant this type exists to hold anyway.
        let box = UncheckedBox(continuation)
        onFirst = { result in
            // Inside the winning transition, not beside it. Counting the
            // answer outside this gate meant a reply and a later duplicate
            // error for the same request both decremented, so other calls
            // still parked vanished from the count and the limit stopped
            // being able to notice a wedged connection.
            accounting?()
            box.value.resume(with: result)
        }
    }

    /// For tests, which have no continuation to resume.
    init(onFirst: @escaping @Sendable (Result<T, Error>) -> Void) {
        self.onFirst = onFirst
    }

    /// Delivers the first answer and silently drops every later one.
    func deliver(_ result: Result<T, Error>) {
        let first = state.withLock { already -> Bool in
            if already { return false }
            already = true
            return true
        }
        guard first else { return }
        onFirst(result)
    }
}

private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// No connection could be made at all.
public struct KeepAwakeXPCUnavailable: Error, Sendable {}
