import CoreGraphics
import Foundation
import Testing

@testable import LedgeSystem

/// One system window at a time: macOS's first message, then System Settings
/// from its button. If the message is not seen, System Settings opens anyway.
@MainActor
@Suite("macOS's Accessibility message")
struct AccessibilityAlertTests {

    private final class Counter: @unchecked Sendable {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    @Test("Already up, nothing to wait for")
    func alreadyUp() async {
        let sleeps = Counter()
        let up = await AccessibilityAlert.appears(isUp: { true }, sleep: { _ in sleeps.bump() })
        #expect(up)
        #expect(sleeps.count == 0)
    }

    @Test("Coming up during the wait ends the wait there")
    func comesUp() async {
        let sleeps = Counter()
        let up = await AccessibilityAlert.appears(isUp: { sleeps.count >= 2 }, sleep: { _ in sleeps.bump() })
        #expect(up)
        #expect(sleeps.count == 2)
    }

    /// The pane has to open in the end, or this is a button that does nothing.
    @Test("Never coming up gives up after 0.7 s")
    func neverComesUp() async {
        let sleeps = Counter()
        let up = await AccessibilityAlert.appears(isUp: { false }, sleep: { _ in sleeps.bump() })
        #expect(!up)
        #expect(sleeps.count == 7)
    }

    /// The little app stays running for weeks after its message has gone. A
    /// check on the process alone says "up" forever, and then nothing ever
    /// opens System Settings: a button that does nothing.
    @Test("Up means a window on screen, not the process running")
    func needsAWindow() {
        let window: [String: Any] = [kCGWindowOwnerPID as String: pid_t(5059)]
        let other: [String: Any] = [kCGWindowOwnerPID as String: pid_t(77)]
        #expect(AccessibilityAlert.hasWindow(in: [other, window], ownedBy: [5059]))
        #expect(!AccessibilityAlert.hasWindow(in: [other], ownedBy: [5059]))
        #expect(!AccessibilityAlert.hasWindow(in: [], ownedBy: [5059]))
    }

    /// Without the wait path taken, every press opens the pane as before. And
    /// the only way past opening it is the message actually being up.
    @Test("The request only skips opening the pane when the message is up")
    func requestOrder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/LedgeSystem/Permissions/PermissionCenter.swift"), encoding: .utf8
        )
        let start = try #require(source.range(of: "case .accessibility:\n            // The prompt is a courtesy"))
        let body = source[start.upperBound...]
        let trust = try #require(body.range(of: "MediaKeyInterceptor.requestTrust()"))
        let gate = try #require(body.range(of: "if accessibilityAlertMayAppear {"))
        let skip = try #require(body.range(of: "if alertIsUp { return status(of: .accessibility) }"))
        let open = try #require(body.range(of: "openSettings(for: .accessibility)"))
        #expect(trust.upperBound <= gate.lowerBound)
        #expect(gate.upperBound <= skip.lowerBound)
        #expect(skip.upperBound <= open.lowerBound)
    }

    // MARK: - Not before the press

    /// The probe tap raises the message, so a new user saw it at launch. This
    /// is also every Accessibility list change that wasn't for Ledge: the list
    /// changing can't get past this on its own.
    @Test("Nobody has asked and macOS says no: no probe, so no message")
    func noProbeBeforeThePress() {
        var probes = 0
        let answer = MediaKeyInterceptor.answer(hasBeenAsked: false, axSaysTrusted: false) {
            probes += 1
            return true
        }
        #expect(!answer)
        #expect(probes == 0)
    }

    /// Somebody who granted it long ago, before the press was written down,
    /// and a switch flipped for Ledge with no press in it.
    @Test("Nobody has asked but macOS says yes: probe, which raises nothing")
    func probeWhenAlreadyTrusted() {
        var probes = 0
        let answer = MediaKeyInterceptor.answer(hasBeenAsked: false, axSaysTrusted: true) {
            probes += 1
            return true
        }
        #expect(answer)
        #expect(probes == 1)
    }

    /// Everybody past the press keeps the honest question, including when a
    /// grant was revoked while Ledge ran, which the cached answer cannot see.
    @Test("After the press it always probes", arguments: [true, false])
    func probeAfterThePress(axSaysTrusted: Bool) {
        var probes = 0
        let answer = MediaKeyInterceptor.answer(hasBeenAsked: true, axSaysTrusted: axSaysTrusted) {
            probes += 1
            return false
        }
        #expect(!answer)
        #expect(probes == 1)
    }

    @MainActor private final class Gate {
        var released = 0
        var slept = 0
        func sleep() async {
            slept += 1
            let mine = slept
            while released < mine, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    private func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func arrive(_ what: Comment, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), what, sourceLocation: sourceLocation)
    }

    @Test("The watcher hears the list, stops when told, and starting twice hears once")
    func watcher() async throws {
        let name = Notification.Name("com.egemert.ledge.tests.\(UUID().uuidString)")
        let watcher = AccessibilityListWatcher(name: name, delays: [])
        var heard = 0
        watcher.start { heard += 1 }
        watcher.start { heard += 1 }
        post(name)
        await arrive("the first change was heard") { heard > 0 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(heard == 1)
        watcher.stop()
        post(name)
        try await Task.sleep(for: .milliseconds(150))
        #expect(heard == 1)
    }

    /// The notification can land before the new answer can be read, and a
    /// single look then would miss the grant until the next launch.
    @Test("A change gets another look after each delay, then no more")
    func looksAgain() async {
        let name = Notification.Name("com.egemert.ledge.tests.\(UUID().uuidString)")
        let gate = Gate()
        let watcher = AccessibilityListWatcher(
            name: name, delays: [.milliseconds(250), .seconds(1)], sleep: { _ in await gate.sleep() }
        )
        var heard = 0
        watcher.start { heard += 1 }
        defer { watcher.stop() }
        post(name)
        await arrive("the first look ran and the second is waiting") { heard == 1 && gate.slept == 1 }
        gate.released = 1
        await arrive("the second look ran") { heard == 2 && gate.slept == 2 }
        gate.released = 2
        await arrive("the third look ran") { heard == 3 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(heard == 3)
    }

    @Test("Stopping ends the looks still to come")
    func stopEndsLooks() async {
        let name = Notification.Name("com.egemert.ledge.tests.\(UUID().uuidString)")
        let gate = Gate()
        let watcher = AccessibilityListWatcher(name: name, delays: [.seconds(1)], sleep: { _ in await gate.sleep() })
        var heard = 0
        watcher.start { heard += 1 }
        post(name)
        await arrive("the look after this one is waiting") { heard == 1 && gate.slept == 1 }
        watcher.stop()
        gate.released = 1
        try? await Task.sleep(for: .milliseconds(30))
        #expect(heard == 1)
    }

    /// Ledge isn't active while System Settings is in front, and AppKit holds
    /// distributed notifications back from an inactive app unless told not to.
    /// A test process is never suspended, so only the source can show this.
    @Test("The watcher asks for delivery while Ledge isn't active")
    func deliveredWhileInactive() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/LedgeSystem/Level/MediaKeyInterceptor.swift"), encoding: .utf8
        )
        #expect(source.contains("suspensionBehavior: .deliverImmediately"))
        #expect(AccessibilityListWatcher.systemNotification.rawValue == "com.apple.accessibility.api")
    }

    @Test("Launch says whether anyone has asked before anything can ask")
    func launchOrder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/LedgeShell/Coordinator/LedgeCoordinator.swift"), encoding: .utf8
        )
        let start = try #require(source.range(of: "    public func start() {\n"))
        let body = source[start.upperBound...]
        let first = try #require(body.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") })
        #expect(first.contains("MediaKeyInterceptor.hasBeenAsked = preferences.accessibilityWasAsked"))
        // A list change only looks again. Nothing may turn it into a probe.
        #expect(body.contains("accessibilityList.start { [weak self] in self?.revalidatePermissions() }"))
        // And nothing built earlier may have asked already.
        let delegate = try String(contentsOf: root.appending(path: "Sources/LedgeApp/AppDelegate.swift"), encoding: .utf8)
        #expect(!delegate.contains("MediaKeyInterceptor"))
    }
}
