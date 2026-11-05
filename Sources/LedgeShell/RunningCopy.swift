import Foundation

/// Whether a copy of Ledge that is already running should make way for this
/// one.
///
/// Opening Ledge while it runs used to always mean "show me the one that is
/// open": the new process asked the running copy for Settings and exited. That
/// is right for a second double-click. It is wrong when the copy being opened
/// is a different build. Somebody who opened a newer Ledge got the old one's
/// Settings and no sign the new one had ever started.
public enum RunningCopy {

    /// What a launch does about the copies already running.
    public enum Decision: Equatable, Sendable {
        /// Nothing in the way.
        case proceed
        /// Every running copy is stale: offer to quit them and open this one.
        case ask
        /// Show the running copy's Settings and exit, as always.
        case handOff
    }

    /// One running copy, as much as can be read about it from outside.
    public struct Rival: Sendable {
        public var bundleURL: URL?
        public var build: @Sendable () -> String?

        public init(bundleURL: URL?, build: @escaping @Sendable () -> String?) {
            self.bundleURL = bundleURL
            self.build = build
        }
    }

    public static func decide(rivals: [Rival], own: URL, ownBuild: String?) -> Decision {
        guard !rivals.isEmpty else { return .proceed }
        let stale = rivals.allSatisfy {
            shouldReplace(running: $0.bundleURL, runningBuild: $0.build(), own: own, ownBuild: ownBuild)
        }
        return stale ? .ask : .handOff
    }

    /// True when the running copy is the stale one.
    ///
    /// The same path counts as stale without reading a version. Opening an app
    /// that is already running only activates it, so a second process from the
    /// same path means the bundle was replaced underneath the first one, and
    /// reading the plist there would read the new copy's version, not the
    /// running one's. A copy elsewhere is stale only when its build is lower.
    /// An unreadable build is never stale: the old hand-off is the safe answer.
    ///
    /// The build is read from disk, not from the running process, so a copy
    /// elsewhere that was itself replaced while running reads as the new
    /// build. That case gets the old hand-off.
    public static func shouldReplace(running: URL?, runningBuild: @autoclosure () -> String?,
                                     own: URL, ownBuild: String?) -> Bool {
        guard let running else { return false }
        if running.resolvingSymlinksInPath().path == own.resolvingSymlinksInPath().path {
            return true
        }
        guard let theirs = runningBuild().flatMap({ Int($0) }),
              let ours = ownBuild.flatMap({ Int($0) })
        else { return false }
        return theirs < ours
    }

    /// Whether every copy that was asked to quit said it would.
    ///
    /// One refusal is enough to hand off: that copy is staying, and waiting
    /// for it to go would only ask "still closing" forever.
    public static func allAgreedToQuit(_ accepted: [Bool]) -> Bool {
        !accepted.isEmpty && accepted.allSatisfy { $0 }
    }

    /// How long an older copy gets to quit before the user is asked again.
    ///
    /// A quit can spend `keepAwakeTerminationBudget` (6 s) three times over
    /// ending a Keep Awake session and waiting for what that set in motion,
    /// then drain the rest. Thirty seconds covers that with room to spare.
    public static let exitDeadline: Duration = .seconds(30)

    /// Waits until every copy has gone, or the deadline passes.
    ///
    /// Time is counted in polls rather than read from a clock so the wait can
    /// be tested without waiting. `sleep` is the only thing that takes time.
    /// Runs on the caller's actor, so the checks it is handed can read
    /// main-actor state without being sent anywhere.
    public static func waitForExit(isolation: isolated (any Actor)? = #isolation,
                                   deadline: Duration = exitDeadline,
                                   poll: Duration = .milliseconds(100),
                                   allTerminated: () -> Bool,
                                   sleep: (Duration) async -> Void) async -> Bool {
        var waited: Duration = .zero
        while !allTerminated() {
            guard waited < deadline else { return false }
            await sleep(poll)
            waited += poll
        }
        return true
    }
}
