import Foundation

/// A newer copy of Ledge taking over from one that is running.
///
/// Keep Awake's session has to survive that quit, and the running copy decides
/// so the moment a quit reaches it. A quit from outside can't carry a reason,
/// so anything sent ahead of it leaves a gap in which the two can come apart.
/// There is no gap here: a copy that can answer is asked to go, and marks the
/// session and starts quitting in one step. Only a copy that can't answer is
/// quit from outside, and the person has been told what that means for Keep
/// Awake by then.
public struct ReplacementNames: Sendable {
    public let request: Notification.Name
    public let acknowledged: Notification.Name

    /// Named after this bundle, so a development build and the installed app
    /// cannot answer each other.
    public init(bundleIdentifier: String) {
        request = Notification.Name("\(bundleIdentifier).replacedByNewerCopy")
        acknowledged = Notification.Name("\(bundleIdentifier).replacementAcknowledged")
    }
}

/// The road between two copies, with one string carried along it.
@MainActor
public struct ReplacementChannel {
    public var post: (Notification.Name, String) -> Void
    public var observe: (Notification.Name, @escaping @MainActor (String) -> Void) -> any NSObjectProtocol
    public var remove: (any NSObjectProtocol) -> Void

    public init(
        post: @escaping (Notification.Name, String) -> Void,
        observe: @escaping (Notification.Name, @escaping @MainActor (String) -> Void) -> any NSObjectProtocol,
        remove: @escaping (any NSObjectProtocol) -> Void
    ) {
        self.post = post
        self.observe = observe
        self.remove = remove
    }

    /// Delivered at once in both directions: neither copy is the active app
    /// when it matters, and AppKit otherwise holds these back until it is.
    public static var distributed: ReplacementChannel {
        ReplacementChannel(
            post: { name, payload in
                DistributedNotificationCenter.default().postNotificationName(
                    name, object: payload, userInfo: nil, deliverImmediately: true
                )
            },
            observe: { name, handler in
                DistributedNotificationCenter.default().addObserver(
                    forName: name, object: nil, queue: .main
                ) { note in
                    guard let payload = note.object as? String else { return }
                    MainActor.assumeIsolated { handler(payload) }
                }
            },
            remove: { DistributedNotificationCenter.default().removeObserver($0) }
        )
    }
}

/// What goes along the road.
public enum ReplacementMessage {

    /// A clock both copies read alike, which keeps counting through sleep.
    public static func systemNanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    static func request(id: String, expiresAt: UInt64) -> String { "\(id) \(expiresAt)" }

    static func parseRequest(_ payload: String) -> (id: String, expiresAt: UInt64)? {
        let parts = payload.split(separator: " ")
        guard parts.count == 2, let expiry = UInt64(parts[1]) else { return nil }
        return (String(parts[0]), expiry)
    }

    static func acknowledgement(of id: String, from pid: pid_t) -> String { "\(id) \(pid)" }

    static func parseAcknowledgement(_ payload: String) -> (id: String, pid: pid_t)? {
        let parts = payload.split(separator: " ")
        guard parts.count == 2, let pid = pid_t(parts[1]) else { return nil }
        return (String(parts[0]), pid)
    }
}

/// The new copy's half: from "Quit and Open" to every copy being on its way out.
@MainActor
public final class CopyReplacement {

    /// One running copy, as much as this needs to know.
    public struct Rival {
        let pid: pid_t
        let mayAnswer: Bool
        let quit: @MainActor () -> Bool
        let isGone: @MainActor () -> Bool

        public init(
            pid: pid_t,
            running: URL?,
            runningBuild: @autoclosure () -> String?,
            own: URL,
            quit: @escaping @MainActor () -> Bool,
            isGone: @escaping @MainActor () -> Bool
        ) {
            self.pid = pid
            mayAnswer = RunningCopy.mayAnswerReplacement(running: running, runningBuild: runningBuild(), own: own)
            self.quit = quit
            self.isGone = isGone
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Every copy is leaving. Wait for them to have gone.
        case waitForExit
        /// A copy is staying. Show its Settings instead.
        case handOff
    }

    /// How long a copy gets to answer. A healthy one takes milliseconds; past
    /// this its main thread is stuck, and the person gets to decide. A copy
    /// that first sees the request after this ignores it, so it can't quit
    /// long after somebody chose Not Now.
    public nonisolated static let answerDeadline: Duration = .seconds(2)

    private let id = UUID().uuidString
    private let names: ReplacementNames
    private let channel: ReplacementChannel
    private let stamp: () -> UInt64

    public init(
        names: ReplacementNames,
        channel: ReplacementChannel,
        stamp: @escaping () -> UInt64 = ReplacementMessage.systemNanoseconds
    ) {
        self.names = names
        self.channel = channel
        self.stamp = stamp
    }

    /// - Parameters:
    ///   - alreadyWarned: whether the person has been told Keep Awake may stop.
    ///     They hear that once.
    ///   - askAnyway: a copy that can answer hasn't, and nobody has warned them.
    ///     Handed a check for that copy having answered or gone meanwhile, so
    ///     the question can take itself down.
    public func run(
        rivals: [Rival],
        alreadyWarned: Bool,
        askAnyway: (_ isSettled: @escaping @MainActor () -> Bool) -> Bool,
        deadline: Duration = answerDeadline,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Outcome {
        var heard = Set<pid_t>()
        let id = self.id
        // Listening starts before asking, so an answer can't arrive unheard.
        let token = channel.observe(names.acknowledged) { payload in
            guard let answer = ReplacementMessage.parseAcknowledgement(payload), answer.id == id else { return }
            heard.insert(answer.pid)
        }
        defer { channel.remove(token) }

        let expecting = rivals.filter(\.mayAnswer)
        let isSettled: @MainActor () -> Bool = {
            expecting.allSatisfy { heard.contains($0.pid) || $0.isGone() }
        }
        channel.post(
            names.request,
            ReplacementMessage.request(id: id, expiresAt: stamp() + UInt64(deadline.nanoseconds))
        )
        let settled = await RunningCopy.wait(
            until: isSettled, deadline: deadline, poll: .milliseconds(20), now: now, sleep: sleep
        )
        if !settled, !alreadyWarned, !askAnyway(isSettled), !isSettled() {
            return .handOff
        }
        // Whoever answered is already quitting itself, and must not be quit a
        // second time. Everyone else gets it from outside.
        let silent = rivals.filter { !heard.contains($0.pid) && !$0.isGone() }
        let accepted = silent.map { $0.quit() }
        guard silent.isEmpty || RunningCopy.allAgreedToQuit(accepted) else { return .handOff }
        return .waitForExit
    }
}

private extension Duration {
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}

/// The running copy's half.
///
/// The session is marked, the answer sent and the quit begun in one turn of the
/// main thread, so nothing can come between them and no promise is left open.
/// A second request while this copy is leaving gets the answer alone.
@MainActor
public final class ReplacementListener {

    private let names: ReplacementNames
    private let channel: ReplacementChannel
    private let pid: pid_t
    private let stamp: () -> UInt64
    private let markSession: @MainActor () -> Void
    private let quit: @MainActor () -> Void
    private var token: (any NSObjectProtocol)?
    private var isLeaving = false

    public init(
        names: ReplacementNames,
        channel: ReplacementChannel,
        pid: pid_t = ProcessInfo.processInfo.processIdentifier,
        stamp: @escaping () -> UInt64 = ReplacementMessage.systemNanoseconds,
        markSession: @escaping @MainActor () -> Void,
        quit: @escaping @MainActor () -> Void
    ) {
        self.names = names
        self.channel = channel
        self.pid = pid
        self.stamp = stamp
        self.markSession = markSession
        self.quit = quit
    }

    public func start() {
        stop()
        token = channel.observe(names.request) { [weak self] payload in
            self?.heard(payload)
        }
    }

    public func stop() {
        if let token { channel.remove(token) }
        token = nil
    }

    private func heard(_ payload: String) {
        // Unreadable means an older sender's; nothing here can answer that.
        guard let request = ReplacementMessage.parseRequest(payload), request.expiresAt >= stamp() else { return }
        let first = !isLeaving
        if first {
            isLeaving = true
            markSession()
        }
        channel.post(names.acknowledged, ReplacementMessage.acknowledgement(of: request.id, from: pid))
        if first { quit() }
    }
}
