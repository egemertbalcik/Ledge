import Foundation
import Testing

/// Sparkle's updater has to exist from launch, or nothing ever checks.
///
/// The app delegate lives in the executable target, which has no test seam
/// and builds a real Sparkle controller the moment it is touched. So, like
/// the self-view wiring tests, this reads how it is wired rather than running
/// it. Found by review: from 1.1.0 to 1.2.3 the controller was a lazy
/// property only "Check for Updates…" touched, so Sparkle never started and
/// no automatic check ever ran.
@Suite("Starting the updater")
struct UpdaterLaunchTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// The text of one function, from its declaration to the next one.
    private static func body(of declaration: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: declaration), "\(declaration) was renamed; this guard needs rewriting")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound
            ?? rest.range(of: "\n    func ")?.lowerBound
            ?? rest.endIndex
        return rest[..<end]
    }

    @Test("A normal launch builds the updater, before the app starts and after the guards")
    func normalLaunchStartsSparkle() throws {
        let delegate = try Self.source("Sources/LedgeApp/AppDelegate.swift")
        try #require(delegate.contains("startingUpdater: true"), "the controller must start itself when built")

        let launch = try Self.body(of: "private func startNormally()", in: delegate)
        let guardLine = try #require(launch.range(of: "guard !started else { return }"))
        let build = try #require(launch.range(of: "_ = updater"), "startNormally() no longer builds the updater")
        let start = try #require(launch.range(of: "coordinator.start()"))
        #expect(guardLine.upperBound <= build.lowerBound, "built before the started guard")
        #expect(build.upperBound <= start.lowerBound, "built after the app has already started")

        // Only through startNormally(), which runs after the single-instance
        // guard: a second copy that hands off and exits never starts one.
        let finished = try Self.body(of: "func applicationDidFinishLaunching", in: delegate)
        let single = try #require(finished.range(of: "guard enforceSingleInstance() else { return }"))
        let rest = try #require(finished.range(of: "continueLaunching()"))
        #expect(single.upperBound <= rest.lowerBound)
        #expect(!finished.contains("_ = updater"))
        #expect(!finished.contains("startNormally()"))

        let continuing = try Self.body(of: "private func continueLaunching()", in: delegate)
        let moved = try #require(continuing.range(of: "guard offerMoveToApplicationsIfNeeded() else { return }"))
        let normal = try #require(continuing.range(of: "startNormally()"))
        #expect(moved.upperBound <= normal.lowerBound)

        // The other way into the rest of a launch: after an older copy has
        // been asked to quit, and only once it has gone. A refusal hands off
        // at once; a copy that agreed is never handed off to, because it would
        // show Settings on its way out and leave nothing running.
        let replacing = try Self.body(of: "private func replace(", in: delegate)
        let refused = try #require(replacing.range(of: "guard RunningCopy.allAgreedToQuit(accepted) else {"))
        let fallback = try #require(replacing.range(of: "handOff()"))
        let waiting = try #require(replacing.range(of: "RunningCopy.waitForExit("))
        let carryOn = try #require(replacing.range(of: "self.continueLaunching()"))
        #expect(refused.upperBound <= fallback.lowerBound)
        #expect(fallback.upperBound <= waiting.lowerBound)
        #expect(waiting.upperBound <= carryOn.lowerBound)
        #expect(!replacing[waiting.lowerBound...].contains("handOff()"))
    }

    /// A copy waiting for an older one to quit has started nothing, so a
    /// reopen then must not build the coordinator.
    @Test("Reopening before the launch has started leaves the coordinator unbuilt")
    func reopenWaitsForStart() throws {
        let delegate = try Self.source("Sources/LedgeApp/AppDelegate.swift")
        let reopen = try Self.body(of: "func applicationShouldHandleReopen", in: delegate)
        let gate = try #require(reopen.range(of: "guard started else { return false }"))
        let show = try #require(reopen.range(of: "coordinator.showSettings()"))
        #expect(gate.upperBound <= show.lowerBound)
    }

    /// Starting it is only half: the shipped bundle has to say where to look
    /// and that looking on a schedule is wanted, or a started updater asks
    /// for permission instead, or checks nothing.
    @Test("The shipped Info.plist turns automatic checks on, with a feed and a key")
    func plistAsksForScheduledChecks() throws {
        let data = try Data(contentsOf: Self.root.appending(path: "Bundle/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
        // The default for somebody who has never chosen: updates install by
        // themselves. A choice made in Sparkle's own window still wins.
        #expect(plist["SUAutomaticallyUpdate"] as? Bool == true)
        let feed = try #require(plist["SUFeedURL"] as? String)
        #expect(feed.hasPrefix("https://"))
        #expect(feed.hasSuffix("appcast.xml"))
        #expect((plist["SUPublicEDKey"] as? String)?.isEmpty == false)
        // Absent means Sparkle's daily default; anything set must be sane.
        if let interval = plist["SUScheduledCheckInterval"] as? Double {
            #expect(interval >= 3600 && interval <= 7 * 86_400)
        }
    }
}
