import Foundation
import Testing

@testable import LedgeShell

/// A newer copy takes over, and Keep Awake's session survives it.
@MainActor
@Suite("Quit and Open keeps Keep Awake")
struct CopyReplacementTests {

    fileprivate static let names = ReplacementNames(bundleIdentifier: "com.egemert.ledge.tests")
    fileprivate static let own = URL(fileURLWithPath: "/Users/someone/Downloads/Ledge.app")
    fileprivate static let installed = URL(fileURLWithPath: "/Applications/Ledge.app")

    /// A road that holds what is posted until the test lets it through, which
    /// is what a busy copy looks like from the other end.
    @MainActor
    private final class Road {
        var holding = false
        var held: [(Notification.Name, String)] = []
        private var observers: [ObjectIdentifier: (Notification.Name, @MainActor (String) -> Void)] = [:]

        private final class Token: NSObject {}

        var channel: ReplacementChannel {
            ReplacementChannel(
                post: { name, payload in
                    if self.holding {
                        self.held.append((name, payload))
                    } else {
                        self.deliver(name, payload)
                    }
                },
                observe: { name, handler in
                    let token = Token()
                    self.observers[ObjectIdentifier(token)] = (name, handler)
                    return token
                },
                remove: { self.observers[ObjectIdentifier($0)] = nil }
            )
        }

        func deliver(_ name: Notification.Name, _ payload: String) {
            for (observed, handler) in observers.values where observed == name { handler(payload) }
        }

        func letThrough() {
            holding = false
            let waiting = held
            held = []
            for (name, payload) in waiting { deliver(name, payload) }
        }

        var observerCount: Int { observers.count }
    }

    private final class Clock {
        private var current = ContinuousClock.now
        func advance(_ by: Duration) { current += by }
        var read: () -> ContinuousClock.Instant { { self.current } }
    }

    /// One running copy, with what happened to it written down in order.
    @MainActor
    private final class OldCopy {
        let pid: pid_t
        var log: [String] = []
        var quitsFromOutside = 0
        var refusesQuit = false
        var gone = false
        var listener: ReplacementListener?

        init(pid: pid_t = 41) { self.pid = pid }

        var marked: Bool { log.contains("marked") }

        /// Running the real listener, as a build that can answer does. The
        /// channel notes the answer going out, so its place in the order shows.
        func listen(on road: Road, stamp: @escaping () -> UInt64 = ReplacementMessage.systemNanoseconds) {
            var channel = road.channel
            let post = channel.post
            channel.post = { [weak self] name, payload in
                if name == CopyReplacementTests.names.acknowledged { self?.log.append("answered") }
                post(name, payload)
            }
            listener = ReplacementListener(
                names: CopyReplacementTests.names, channel: channel, pid: pid, stamp: stamp,
                markSession: { [weak self] in self?.log.append("marked") },
                quit: { [weak self] in self?.log.append("quit itself") }
            )
            listener?.start()
        }

        func rival(path: URL = CopyReplacementTests.installed, build: String? = "500") -> CopyReplacement.Rival {
            CopyReplacement.Rival(
                pid: pid, running: path, runningBuild: build, own: CopyReplacementTests.own,
                quit: { [self] in
                    quitsFromOutside += 1
                    log.append("quit from outside")
                    return !refusesQuit
                },
                isGone: { [self] in gone }
            )
        }
    }

    private func arrive(_ what: Comment, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), what, sourceLocation: sourceLocation)
    }

    private func replacement(_ road: Road) -> CopyReplacement {
        CopyReplacement(names: Self.names, channel: road.channel)
    }

    private func request(_ id: String, expiresAt: UInt64 = .max) -> String {
        ReplacementMessage.request(id: id, expiresAt: expiresAt)
    }

    // MARK: - The running copy

    /// No gap between them is the whole of the fix: nothing can end the session
    /// between the mark and the quit, and no promise outlives this turn.
    @Test("The running copy marks the session, answers and quits itself, in that order")
    func oneStep() {
        let road = Road()
        let old = OldCopy()
        old.listen(on: road)
        defer { old.listener?.stop() }
        road.channel.post(Self.names.request, request("one"))
        #expect(old.log == ["marked", "answered", "quit itself"])
    }

    /// Two new copies at once used to be able to cancel each other's promise.
    @Test("A second request gets an answer and doesn't mark or quit twice")
    func secondRequest() {
        let road = Road()
        let old = OldCopy()
        old.listen(on: road)
        defer { old.listener?.stop() }
        var answers: [String] = []
        let token = road.channel.observe(Self.names.acknowledged) { answers.append($0) }
        defer { road.channel.remove(token) }
        road.channel.post(Self.names.request, request("one"))
        road.channel.post(Self.names.request, request("two"))
        #expect(old.log == ["marked", "answered", "quit itself", "answered"])
        #expect(answers == ["one 41", "two 41"])
    }

    /// Somebody chose Not Now. A copy that gets the request after that must not
    /// quit and leave nothing running.
    @Test("A request heard after its time is ignored")
    func staleRequest() {
        let road = Road()
        let old = OldCopy()
        old.listen(on: road, stamp: { 100 })
        defer { old.listener?.stop() }
        road.channel.post(Self.names.request, request("late", expiresAt: 99))
        #expect(old.log.isEmpty)
        road.channel.post(Self.names.request, request("just", expiresAt: 100))
        #expect(old.log.first == "marked")
    }

    @Test("A request that can't be read is ignored", arguments: ["", "one", "one x", "a b c"])
    func unreadableRequest(payload: String) {
        let road = Road()
        let old = OldCopy()
        old.listen(on: road)
        defer { old.listener?.stop() }
        road.channel.post(Self.names.request, payload)
        #expect(old.log.isEmpty)
    }

    // MARK: - The new copy

    @Test("The request gives the running copy the answer deadline to act on it")
    func requestCarriesDeadline() async {
        let road = Road()
        var seen: String?
        let token = road.channel.observe(Self.names.request) { seen = $0 }
        defer { road.channel.remove(token) }
        let clock = Clock()
        let replacement = CopyReplacement(names: Self.names, channel: road.channel, stamp: { 1_000 })
        _ = await replacement.run(
            rivals: [OldCopy().rival()], alreadyWarned: true, askAnyway: { _ in false },
            deadline: .seconds(2), now: clock.read, sleep: { clock.advance($0) }
        )
        #expect(seen.flatMap(ReplacementMessage.parseRequest)?.expiresAt == 2_000_001_000)
    }

    /// The first finding: a busy copy could take the quit first. Nothing from
    /// outside goes to a copy that answers, however long it takes.
    @Test("A busy copy is waited for, marks its session and is never quit from outside")
    func busyCopyAnswersLate() async {
        let road = Road()
        road.holding = true
        let old = OldCopy()
        old.listen(on: road)
        defer { old.listener?.stop() }
        var outcome: CopyReplacement.Outcome?
        let replacement = replacement(road)
        let task = Task { @MainActor in
            outcome = await replacement.run(
                rivals: [old.rival()], alreadyWarned: false, askAnyway: { _ in false },
                deadline: .seconds(60),
                sleep: { _ in try? await Task.sleep(for: .milliseconds(5)) }
            )
        }
        await arrive("the request is out and held") { road.held.count == 1 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(outcome == nil)
        #expect(old.log.isEmpty)
        road.letThrough()
        await task.value
        #expect(outcome == .waitForExit)
        #expect(old.log == ["marked", "answered", "quit itself"])
    }

    /// The second finding: a late answer used to count as a promise that had
    /// already run out. An answer now means the copy has marked and is going,
    /// however late it is read, so there is nothing to warn about.
    @Test("An answer read long after the deadline still means the session is safe")
    func answerReadLate() async {
        let road = Road()
        road.holding = true
        let old = OldCopy()
        old.listen(on: road)
        defer { old.listener?.stop() }
        let clock = Clock()
        var asked = 0
        let outcome = await replacement(road).run(
            rivals: [old.rival()], alreadyWarned: false, askAnyway: { _ in asked += 1; return false },
            deadline: .seconds(2), now: clock.read,
            sleep: { _ in
                clock.advance(.seconds(31))
                road.letThrough()
            }
        )
        #expect(outcome == .waitForExit)
        #expect(asked == 0)
        #expect(old.log == ["marked", "answered", "quit itself"])
    }

    @Test("No answer asks once, and Not Now hands off with nothing quit")
    func noAnswerNotNow() async {
        let road = Road()
        let old = OldCopy()
        let clock = Clock()
        var asked = 0
        let outcome = await replacement(road).run(
            rivals: [old.rival()], alreadyWarned: false,
            askAnyway: { _ in asked += 1; return false },
            deadline: .seconds(2), now: clock.read, sleep: { clock.advance($0) }
        )
        #expect(outcome == .handOff)
        #expect(asked == 1)
        #expect(old.quitsFromOutside == 0)
    }

    @Test("No answer and Quit and Open quits it from outside")
    func noAnswerQuitAnyway() async {
        let road = Road()
        let old = OldCopy()
        let clock = Clock()
        let outcome = await replacement(road).run(
            rivals: [old.rival()], alreadyWarned: false, askAnyway: { _ in true },
            deadline: .seconds(2), now: clock.read, sleep: { clock.advance($0) }
        )
        #expect(outcome == .waitForExit)
        #expect(old.quitsFromOutside == 1)
    }

    /// Not Now, and the copy was on its way out all along. Handing off to it
    /// would leave nothing running, and quitting it again would be wrong too.
    @Test("An answer arriving while the question is up settles it", arguments: [false, true])
    func answerDuringQuestion(pressedQuit: Bool) async {
        let road = Road()
        var requestID: String?
        let token = road.channel.observe(Self.names.request) {
            requestID = ReplacementMessage.parseRequest($0)?.id
        }
        defer { road.channel.remove(token) }
        let old = OldCopy()
        let clock = Clock()
        var settledBefore: Bool?
        var settledAfter: Bool?
        let outcome = await replacement(road).run(
            rivals: [old.rival()], alreadyWarned: false,
            askAnyway: { isSettled in
                settledBefore = isSettled()
                road.deliver(
                    Self.names.acknowledged,
                    ReplacementMessage.acknowledgement(of: requestID ?? "", from: old.pid)
                )
                settledAfter = isSettled()
                return pressedQuit
            },
            deadline: .seconds(2), now: clock.read, sleep: { clock.advance($0) }
        )
        #expect(settledBefore == false)
        #expect(settledAfter == true)
        #expect(outcome == .waitForExit)
        #expect(old.quitsFromOutside == 0)
    }

    @Test("Going while the question is up settles it too")
    func goneDuringQuestion() async {
        let road = Road()
        let old = OldCopy()
        let clock = Clock()
        let outcome = await replacement(road).run(
            rivals: [old.rival()], alreadyWarned: false,
            askAnyway: { _ in
                old.gone = true
                return false
            },
            deadline: .seconds(2), now: clock.read, sleep: { clock.advance($0) }
        )
        #expect(outcome == .waitForExit)
        #expect(old.quitsFromOutside == 0)
    }

    @Test("Somebody already warned isn't asked again")
    func warnedOnce() async {
        let road = Road()
        let old = OldCopy()
        let clock = Clock()
        var asked = 0
        let outcome = await replacement(road).run(
            rivals: [old.rival(path: Self.own)], alreadyWarned: true,
            askAnyway: { _ in asked += 1; return false },
            deadline: .seconds(2), now: clock.read, sleep: { clock.advance($0) }
        )
        #expect(outcome == .waitForExit)
        #expect(asked == 0)
        #expect(old.quitsFromOutside == 1)
    }

    /// Too old to answer, so waiting would only be a delay. Goes through the
    /// real classification of a rival, not a hand-written set of pids.
    @Test("A build too old to answer is quit from outside at once")
    func tooOld() async {
        let road = Road()
        let old = OldCopy()
        var slept = 0
        let outcome = await replacement(road).run(
            rivals: [old.rival(build: "422")], alreadyWarned: true, askAnyway: { _ in false },
            sleep: { _ in slept += 1 }
        )
        #expect(outcome == .waitForExit)
        #expect(slept == 0)
        #expect(old.quitsFromOutside == 1)
    }

    /// The caller's half of the coverage gap: a new enough build is waited for,
    /// going through the same classification the app uses.
    @Test("A new enough build is waited for", arguments: ["423", "500"])
    func newEnough(build: String) async {
        let road = Road()
        let old = OldCopy()
        let clock = Clock()
        var slept = 0
        _ = await replacement(road).run(
            rivals: [old.rival(build: build)], alreadyWarned: true, askAnyway: { _ in false },
            deadline: .seconds(2), now: clock.read,
            sleep: { slept += 1; clock.advance($0) }
        )
        #expect(slept > 0)
    }

    @Test("A refused quit hands off")
    func refused() async {
        let road = Road()
        let old = OldCopy()
        old.refusesQuit = true
        let outcome = await replacement(road).run(
            rivals: [old.rival(build: "422")], alreadyWarned: true, askAnyway: { _ in true }
        )
        #expect(outcome == .handOff)
    }

    @Test("Of two copies, the one that answers quits itself and the other is quit from outside")
    func oneAnswersOneDoesNot() async {
        let road = Road()
        let answering = OldCopy(pid: 41)
        answering.listen(on: road)
        defer { answering.listener?.stop() }
        let old = OldCopy(pid: 42)
        let outcome = await replacement(road).run(
            rivals: [answering.rival(), old.rival(build: "422")], alreadyWarned: true, askAnyway: { _ in false }
        )
        #expect(outcome == .waitForExit)
        #expect(answering.quitsFromOutside == 0)
        #expect(old.quitsFromOutside == 1)
    }

    @Test("Every copy that can answer has to")
    func everyCopyAnswers() async {
        let road = Road()
        let one = OldCopy(pid: 41)
        one.listen(on: road)
        defer { one.listener?.stop() }
        let other = OldCopy(pid: 42)
        let clock = Clock()
        var asked = 0
        let outcome = await replacement(road).run(
            rivals: [one.rival(), other.rival()], alreadyWarned: false,
            askAnyway: { _ in asked += 1; return false },
            deadline: .seconds(2), now: clock.read, sleep: { clock.advance($0) }
        )
        #expect(asked == 1)
        #expect(outcome == .handOff)
    }

    @Test("A copy that's gone needs no answer")
    func goneNeedsNoAnswer() async {
        let road = Road()
        let old = OldCopy()
        old.gone = true
        var asked = 0
        let outcome = await replacement(road).run(
            rivals: [old.rival()], alreadyWarned: false, askAnyway: { _ in asked += 1; return false }
        )
        #expect(outcome == .waitForExit)
        #expect(asked == 0)
        #expect(old.quitsFromOutside == 0)
    }

    @Test("An answer to some other request doesn't count")
    func someoneElsesAnswer() async {
        let road = Road()
        let old = OldCopy()
        let clock = Clock()
        var asked = 0
        let outcome = await replacement(road).run(
            rivals: [old.rival()], alreadyWarned: false,
            askAnyway: { _ in asked += 1; return false },
            deadline: .seconds(2), now: clock.read,
            sleep: { duration in
                road.deliver(Self.names.acknowledged, ReplacementMessage.acknowledgement(of: "other", from: old.pid))
                clock.advance(duration)
            }
        )
        #expect(asked == 1)
        #expect(outcome == .handOff)
    }

    @Test("The listener for answers is gone afterwards")
    func cleansUp() async {
        let road = Road()
        _ = await replacement(road).run(rivals: [], alreadyWarned: true, askAnyway: { _ in false })
        #expect(road.observerCount == 0)
    }

    @Test("What an answer carries", arguments: [
        ("abc 41", true), ("abc", false), ("abc x", false), ("a b c", false),
    ])
    func parsing(payload: String, parses: Bool) {
        #expect((ReplacementMessage.parseAcknowledgement(payload) != nil) == parses)
    }

    // MARK: - Wiring

    /// The app's own objects can't be built in a test, so these wires are read.
    /// Everything either side of them runs above.
    @Test("The app goes through the replacement and quits only through it")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let delegate = try String(contentsOf: root.appending(path: "Sources/LedgeApp/AppDelegate.swift"), encoding: .utf8)
        #expect(delegate.contains("self.coordinator.beingReplacedByNewerCopy()"))
        #expect(delegate.contains("quit: { NSApp.terminate(nil) }"))
        #expect(delegate.contains("quit: { rival.terminate() },"))
        #expect(delegate.contains("runningBuild: Self.build(of: rival),"))
        #expect(delegate.contains("let outcome = await replacement.run("))
        #expect(!delegate.contains("$0.terminate()"))
        // What the mark does: Keep Awake reads this when the quit reaches it.
        let coordinator = try String(
            contentsOf: root.appending(path: "Sources/LedgeShell/Coordinator/LedgeCoordinator.swift"), encoding: .utf8
        )
        let mark = try #require(coordinator.range(of: "public func beingReplacedByNewerCopy() {"))
        let body = coordinator[mark.upperBound...].prefix(120)
        #expect(body.contains("guard terminationKind == .quit else { return }"))
        #expect(body.contains("terminationKind = .updateRelaunch"))
    }

    // MARK: - The real road

    /// Only the road is real here, both ends being this process. Two copies
    /// and a real quit need a real Mac.
    @Test("Asking and answering over distributed notifications")
    func realRoad() async {
        let names = ReplacementNames(bundleIdentifier: "com.egemert.ledge.tests.\(UUID().uuidString)")
        var log: [String] = []
        let old = ReplacementListener(
            names: names, channel: .distributed, pid: 41,
            markSession: { log.append("marked") }, quit: { log.append("quit itself") }
        )
        old.start()
        defer { old.stop() }
        var outsideQuits = 0
        let rival = CopyReplacement.Rival(
            pid: 41, running: Self.installed, runningBuild: "500", own: Self.own,
            quit: { outsideQuits += 1; return true }, isGone: { false }
        )
        let outcome = await CopyReplacement(names: names, channel: .distributed).run(
            rivals: [rival], alreadyWarned: false, askAnyway: { _ in false }, deadline: .seconds(30)
        )
        #expect(outcome == .waitForExit)
        #expect(outsideQuits == 0)
        #expect(log == ["marked", "quit itself"])
    }
}
