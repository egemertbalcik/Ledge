import Foundation
import Testing

@testable import LedgeShell

/// Which copy of Ledge gets the screen when a second one is opened.
@Suite("A second copy of Ledge")
struct RunningCopyTests {

    private static let applications = URL(fileURLWithPath: "/Applications/Ledge.app")
    private static let downloads = URL(fileURLWithPath: "/Users/someone/Downloads/Ledge.app")

    @Test("An older build elsewhere makes way")
    func olderBuildIsReplaced() {
        #expect(RunningCopy.shouldReplace(running: Self.applications, runningBuild: "414",
                                          own: Self.downloads, ownBuild: "416"))
    }

    /// The double-click case, and a newer copy already running: both keep the
    /// old hand-off.
    @Test("The same build, or a newer one, keeps running", arguments: ["416", "417"])
    func sameOrNewerBuildStays(running: String) {
        #expect(!RunningCopy.shouldReplace(running: Self.applications, runningBuild: running,
                                           own: Self.downloads, ownBuild: "416"))
    }

    /// Opening a running app from its own path only activates it, so a second
    /// process there means the bundle was swapped. The version on disk is the
    /// new copy's and says nothing about the running one.
    @Test("The same path counts as replaced whatever the plist says")
    func samePathIsReplaced() {
        #expect(RunningCopy.shouldReplace(running: Self.applications, runningBuild: "416",
                                          own: Self.applications, ownBuild: "416"))
    }

    @Test("Builds that cannot be read never replace anything",
          arguments: [(String?.none, String?("416")), ("416", nil), ("1.2.5", "416"), (nil, nil)])
    func unreadableBuildStays(running: String?, own: String?) {
        #expect(!RunningCopy.shouldReplace(running: Self.applications, runningBuild: running,
                                           own: Self.downloads, ownBuild: own))
    }

    @Test("A copy with no bundle location is never replaced")
    func missingLocationStays() {
        #expect(!RunningCopy.shouldReplace(running: nil, runningBuild: "1",
                                           own: Self.downloads, ownBuild: "416"))
    }
}

/// What a launch does with every running copy at once, and how long it waits.
@Suite("Making way for a newer copy")
struct RunningCopyDecisionTests {

    private static let own = URL(fileURLWithPath: "/Users/someone/Downloads/Ledge.app")

    private static func rival(_ path: String, _ build: String?) -> RunningCopy.Rival {
        RunningCopy.Rival(bundleURL: URL(fileURLWithPath: path)) { build }
    }

    @Test("No running copy, no question")
    func nothingRunning() {
        #expect(RunningCopy.decide(rivals: [], own: Self.own, ownBuild: "416") == .proceed)
    }

    @Test("Only stale copies are asked about")
    func staleIsAsked() {
        let rivals = [Self.rival("/Applications/Ledge.app", "414")]
        #expect(RunningCopy.decide(rivals: rivals, own: Self.own, ownBuild: "416") == .ask)
    }

    /// One current copy among them is enough to keep the old hand-off:
    /// quitting the others would still leave two copies after this one starts.
    @Test("A single current copy keeps the hand-off")
    func oneCurrentCopyHandsOff() {
        let rivals = [Self.rival("/Applications/Ledge.app", "414"), Self.rival("/Users/someone/Ledge.app", "416")]
        #expect(RunningCopy.decide(rivals: rivals, own: Self.own, ownBuild: "416") == .handOff)
    }

    /// At the same path the plist on disk is this copy's, so it is never read.
    @Test("The same path is decided without reading a build")
    func samePathReadsNothing() {
        let read = Counter()
        let rival = RunningCopy.Rival(bundleURL: Self.own) { read.bump(); return "416" }
        #expect(RunningCopy.decide(rivals: [rival], own: Self.own, ownBuild: "416") == .ask)
        #expect(read.count == 0)
    }

    /// Only a copy known to answer the replacement signal keeps its session.
    @Test("Whether Keep Awake carries on depends on the running build", arguments: [
        ("/Applications/Ledge.app", String?("426"), true),
        ("/Applications/Ledge.app", String?("500"), true),
        ("/Applications/Ledge.app", String?("425"), false),
        ("/Applications/Ledge.app", String?("414"), false),
        ("/Applications/Ledge.app", String?.none, false),
        ("/Applications/Ledge.app", String?("1.2.5"), false),
        // At our own path the plist is ours, whatever it says.
        ("/Users/someone/Downloads/Ledge.app", String?("500"), false),
    ])
    func keepsKeepAwake(path: String, build: String?, keeps: Bool) {
        #expect(RunningCopy.keepsKeepAwake(
            running: URL(fileURLWithPath: path), runningBuild: build, own: Self.own
        ) == keeps)
    }

    @Test("A copy with no location gets the warning")
    func noLocationGetsTheWarning() {
        #expect(!RunningCopy.keepsKeepAwake(running: nil, runningBuild: "500", own: Self.own))
    }

    /// A copy that refused is staying: waiting for it would ask forever.
    @Test("Every copy has to agree to quit", arguments: [
        ([true], true), ([true, true], true), ([true, false], false), ([false], false), ([], false),
    ])
    func agreement(accepted: [Bool], waits: Bool) {
        #expect(RunningCopy.allAgreedToQuit(accepted) == waits)
    }

    @Test("It's worth waiting for an answer from a new enough build or one that can't be read", arguments: [
        ("/Applications/Ledge.app", String?("426"), true),
        ("/Applications/Ledge.app", String?("425"), false),
        ("/Applications/Ledge.app", String?.none, false),
        ("/Users/someone/Downloads/Ledge.app", String?("1"), true),
    ])
    func mayAnswer(path: String, build: String?, may: Bool) {
        #expect(RunningCopy.mayAnswerReplacement(
            running: URL(fileURLWithPath: path), runningBuild: build, own: Self.own
        ) == may)
    }

    @Test("Waiting ends as soon as the copies have gone")
    func waitEndsOnExit() async {
        let clock = FakeClock()
        let polls = Counter()
        let gone = await RunningCopy.waitForExit(
            deadline: .seconds(30), poll: .milliseconds(100), now: clock.read,
            allTerminated: { polls.count >= 3 },
            sleep: { polls.bump(); clock.advance($0) }
        )
        #expect(gone)
        #expect(polls.count == 3)
    }

    @Test("Waiting gives up at the deadline, not before")
    func waitGivesUp() async {
        let clock = FakeClock()
        let polls = Counter()
        let gone = await RunningCopy.waitForExit(
            deadline: .seconds(30), poll: .milliseconds(100), now: clock.read,
            allTerminated: { false },
            sleep: { polls.bump(); clock.advance($0) }
        )
        #expect(!gone)
        #expect(polls.count == 300)
    }

    /// A busy main actor serves a 100 ms poll seconds late. Counting polls ran
    /// on well past the time the person was promised an answer by.
    @Test("A poll served late counts for the time it took")
    func latePollsCount() async {
        let clock = FakeClock()
        let polls = Counter()
        let gone = await RunningCopy.waitForExit(
            deadline: .seconds(30), poll: .milliseconds(100), now: clock.read,
            allTerminated: { false },
            sleep: { _ in polls.bump(); clock.advance(.seconds(31)) }
        )
        #expect(!gone)
        #expect(polls.count == 1)
    }

    @Test("Going during the last poll still counts as gone")
    func goneDuringLastPoll() async {
        let clock = FakeClock()
        let polls = Counter()
        let gone = await RunningCopy.waitForExit(
            deadline: .seconds(30), poll: .milliseconds(100), now: clock.read,
            allTerminated: { polls.count >= 1 },
            sleep: { _ in polls.bump(); clock.advance(.seconds(31)) }
        )
        #expect(gone)
    }

    /// Longer than a quit that ends a Keep Awake session can take: three
    /// waits of `keepAwakeTerminationBudget`, with room to drain the rest.
    @Test("The deadline outlasts a quit that ends Keep Awake")
    @MainActor func deadlineCoversQuit() {
        #expect(RunningCopy.exitDeadline >= LedgeCoordinator.keepAwakeTerminationBudget * 3 + .seconds(10))
    }

    private final class Counter: @unchecked Sendable {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    private final class FakeClock: @unchecked Sendable {
        private var current = ContinuousClock.now
        func advance(_ by: Duration) { current += by }
        var read: () -> ContinuousClock.Instant { { self.current } }
    }
}

/// Where the Keep Awake helper may be registered from.
@Suite("Keep Awake helper location")
struct KeepAwakeHelperLocationTests {

    @Test("A disk image, an external drive or a translocated copy cannot register the helper", arguments: [
        "/Volumes/Ledge/Ledge.app",
        "/Volumes/External SSD/Applications/Ledge.app",
        "/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/Ledge.app",
    ])
    func vanishingLocationsRefuse(path: String) {
        #expect(!KeepAwakeHelperInstall.isInstallableLocation(URL(fileURLWithPath: path)))
    }

    @Test("An installed copy can", arguments: [
        "/Applications/Ledge.app",
        "/Users/someone/Applications/Ledge.app",
    ])
    func installedLocationsAllow(path: String) {
        #expect(KeepAwakeHelperInstall.isInstallableLocation(URL(fileURLWithPath: path)))
    }

    /// The check has to come before macOS is asked anything: a registration
    /// that happened and was then reported as refused would leave the daemon
    /// pointing at the image all the same.
    @Test("Set Up checks the location before registering")
    func registerChecksFirst() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/LedgeShell/Coordinator/KeepAwakeHelperInstall.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "static func register() -> Outcome {"))
        let body = source[start.upperBound...]
        let check = try #require(body.range(of: "guard KeepAwakeHelperInstall.isInstallableLocation() else {"))
        let refuse = try #require(body.range(of: "return .notInstallableHere"))
        let ask = try #require(body.range(of: "try service.register()"))
        #expect(check.upperBound <= refuse.lowerBound)
        #expect(refuse.upperBound <= ask.lowerBound)
    }
}
