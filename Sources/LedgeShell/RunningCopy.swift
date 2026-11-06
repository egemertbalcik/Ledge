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

    /// The first build that answers a `CopyReplacement`. Earlier ones treat
    /// being asked to quit as any other quit, which ends a Keep Awake session.
    public static let firstBuildAnsweringReplacement = 423

    /// Whether this running copy leaves its Keep Awake session for the new copy
    /// to resume. The hold itself is let go in between, as in an update.
    ///
    /// Only a build that can be read and is new enough. At the same path the
    /// plist on disk is ours and says nothing about the one running, so that
    /// gets the warning too: a warning that wasn't needed costs nothing.
    public static func keepsKeepAwake(running: URL?, runningBuild: @autoclosure () -> String?, own: URL) -> Bool {
        guard let running,
              running.resolvingSymlinksInPath().path != own.resolvingSymlinksInPath().path,
              let build = runningBuild().flatMap({ Int($0) })
        else { return false }
        return build >= firstBuildAnsweringReplacement
    }

    /// Whether it is worth waiting for this copy to answer. At the same path
    /// its build can't be read, so it might.
    public static func mayAnswerReplacement(running: URL?, runningBuild: @autoclosure () -> String?, own: URL) -> Bool {
        guard let running else { return false }
        if running.resolvingSymlinksInPath().path == own.resolvingSymlinksInPath().path { return true }
        guard let build = runningBuild().flatMap({ Int($0) }) else { return false }
        return build >= firstBuildAnsweringReplacement
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
    /// Runs on the caller's actor, so the checks it is handed can read
    /// main-actor state without being sent anywhere.
    public static func waitForExit(isolation: isolated (any Actor)? = #isolation,
                                   deadline: Duration = exitDeadline,
                                   poll: Duration = .milliseconds(100),
                                   now: () -> ContinuousClock.Instant = { ContinuousClock.now },
                                   allTerminated: () -> Bool,
                                   sleep: (Duration) async -> Void) async -> Bool {
        await wait(until: allTerminated, deadline: deadline, poll: poll, now: now, sleep: sleep)
    }

    /// Polls until the condition holds or the deadline passes.
    ///
    /// Real time, read from a clock: a poll can take far longer than it asked
    /// for when the main actor is busy, and a count of polls would run on past
    /// the deadline. The last look comes after the last sleep, so something
    /// that finished during it still counts.
    static func wait(isolation: isolated (any Actor)? = #isolation,
                     until condition: () -> Bool,
                     deadline: Duration,
                     poll: Duration,
                     now: () -> ContinuousClock.Instant,
                     sleep: (Duration) async -> Void) async -> Bool {
        let started = now()
        while !condition() {
            guard now() - started < deadline else { return false }
            await sleep(poll)
        }
        return true
    }
}
