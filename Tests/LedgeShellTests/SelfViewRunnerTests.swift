import Foundation
import LedgeCore
import QuartzCore
import Testing

@testable import LedgeShell
@testable import LedgeSystem

/// A camera that never existed, answering whatever the case under test is
/// about. Nothing here waits on hardware, so every deadline is exact.
@MainActor
private final class FakeCamera: SelfViewCapturing {

    var answer: CameraAccess
    /// What `requestAccess` comes back with, once the dialog is "answered".
    var afterAsking: CameraAccess = .allowed
    /// Set to fail the start, the way a camera already held by something else
    /// would.
    var refusesToStart = false

    private(set) var starts = 0
    private(set) var stops = 0
    var isRunning = false
    var onFirstFrame: (() -> Void)?
    var onFailure: (() -> Void)?

    /// What this camera calls itself. The privacy card is told the name, so
    /// the tests are told it too.
    var deviceID: String? = "built-in.front"

    /// Whether another application is reading the same camera.
    var isSharedWithAnotherApp = false

    init(answer: CameraAccess = .allowed) { self.answer = answer }

    func access() -> CameraAccess { answer }

    func requestAccess() async -> CameraAccess {
        answer = afterAsking
        return afterAsking
    }

    @discardableResult
    func start() -> Bool {
        guard !refusesToStart else { return false }
        starts += 1
        isRunning = true
        return true
    }

    func makePreviewLayer() -> CALayer? {
        isRunning ? CALayer() : nil
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stops += 1
    }
}

/// The self-view, driven exactly as a person drives it: a press, a frame, a
/// pointer that wanders off, a clock that does not care.
@Suite("The self-view runner")
@MainActor
struct SelfViewRunnerTests {

    private struct Harness {
        let camera: FakeCamera
        let runner: SelfViewRunner
        let published: Box<[SelfViewPayload]>
        let holds: Box<[Bool]>
        let cameraUse: Box<[Bool]>
        let namedCameras: Box<[String?]>
        let settingsOpened: Box<Int>
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func make(access: CameraAccess = .allowed) -> Harness {
        let camera = FakeCamera(answer: access)
        let published = Box<[SelfViewPayload]>([])
        let holds = Box<[Bool]>([])
        let use = Box<[Bool]>([])
        let named = Box<[String?]>([])
        let settings = Box(0)
        let runner = SelfViewRunner(
            camera: camera,
            publish: { published.value.append($0) },
            holdChanged: { holds.value.append($0) },
            cameraUseChanged: { running, device in
                use.value.append(running)
                named.value.append(device)
            },
            openCameraSettings: { settings.value += 1 }
        )
        return Harness(
            camera: camera,
            runner: runner,
            published: published,
            holds: holds,
            cameraUse: use,
            namedCameras: named,
            settingsOpened: settings
        )
    }

    // MARK: - A press that works

    @Test("A press on an allowed Mac wakes the camera and holds the notch")
    func pressStarts() {
        let h = make()
        h.runner.press(now: 0)

        #expect(h.runner.phase == .waking)
        #expect(h.camera.starts == 1)
        #expect(h.holds.value == [true], "the notch is held from the press, not from the picture")
        #expect(h.cameraUse.value == [true], "the privacy card is told at once: this one is ours")
        #expect(
            h.namedCameras.value == ["built-in.front"],
            "and told which camera, so it can still report everybody else's"
        )
    }

    @Test("The first frame is what makes it live")
    func firstFrame() {
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()

        #expect(h.runner.phase == .live)
        #expect(h.published.value.last?.phase == .live)
        #expect(h.holds.value == [true], "still one hold; going live does not retake it")
    }

    @Test("A frame arriving after the session was closed changes nothing")
    func lateFrame() {
        let h = make()
        h.runner.press(now: 0)
        h.runner.press(now: 1)
        #expect(h.runner.phase == .off)

        h.camera.onFirstFrame?()
        #expect(h.runner.phase == .off, "a straggler must not reopen a closed frame")
    }

    // MARK: - Waiting, and giving up

    @Test("A short wait says nothing; six tenths of a second earns the sentence")
    func patience() {
        let h = make()
        h.runner.press(now: 0)
        h.runner.tick(now: 0.5)
        #expect(h.published.value.last?.waitHasLasted == false)

        h.runner.tick(now: 0.6)
        #expect(h.published.value.last?.waitHasLasted == true)
        #expect(h.published.value.last?.sentence == SelfViewCopy.waking)
    }

    @Test("Ten seconds without a frame gives up, and lets the camera go first")
    func givesUp() {
        let h = make()
        h.runner.press(now: 0)
        h.runner.tick(now: 9.9)
        #expect(h.runner.phase == .waking)

        h.runner.tick(now: 10)
        #expect(h.runner.phase == .failed)
        #expect(h.camera.stops == 1, "the light is out before the card says it never started")
        #expect(h.holds.value == [true, false], "nothing is running, so nothing is held")
        #expect(h.cameraUse.value == [true, false])
    }

    @Test("Try again starts a fresh session from the failed face")
    func tryAgain() {
        let h = make()
        h.runner.press(now: 0)
        h.runner.tick(now: 10)
        #expect(h.runner.phase == .failed)

        h.runner.tryAgain(now: 20)
        #expect(h.runner.phase == .waking)
        #expect(h.camera.starts == 2)
        // The ten seconds start again from here, not from the first press.
        h.runner.tick(now: 29.9)
        #expect(h.runner.phase == .waking)
        h.runner.tick(now: 30)
        #expect(h.runner.phase == .failed)
    }

    @Test("A session that fails under its own weight says so")
    func runtimeFailure() {
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()
        h.camera.onFailure?()

        #expect(h.runner.phase == .failed)
        #expect(h.camera.stops == 1)
    }

    // MARK: - Permission

    @Test("The first press asks, and the answer opens the frame")
    func asksOnce() async {
        let h = make(access: .notAsked)
        h.camera.afterAsking = .allowed
        h.runner.press(now: 0)
        #expect(h.runner.phase == .asking)
        #expect(h.holds.value == [true], "the pointer has to reach macOS's dialog")
        #expect(h.camera.starts == 0, "nothing is running while the dialog is up")

        await Task.yield()
        await Task.yield()
        #expect(h.runner.phase == .waking)
        #expect(h.camera.starts == 1)
    }

    @Test("A refusal in the dialog becomes the refused face")
    func refusedInTheDialog() async {
        let h = make(access: .notAsked)
        h.camera.afterAsking = .refused
        h.runner.press(now: 0)
        await Task.yield()
        await Task.yield()

        #expect(h.runner.phase == .refused)
        #expect(h.camera.starts == 0)
        #expect(h.holds.value == [true, false], "a refusal holds nothing open")
    }

    @Test("Closing the frame while the dialog is up abandons the answer")
    func closingWhileAsking() async {
        let h = make(access: .notAsked)
        h.camera.afterAsking = .allowed
        h.runner.press(now: 0)
        h.runner.press(now: 1)
        #expect(h.runner.phase == .off)

        await Task.yield()
        await Task.yield()
        #expect(h.runner.phase == .off, "the answer is macOS's to remember, not ours to act on")
        #expect(h.camera.starts == 0)
    }

    @Test("Every refusal has its own face, and none of them runs a camera")
    func refusals() {
        for (access, face) in [
            (CameraAccess.refused, SelfViewPhase.refused),
            (.blocked, .blocked),
            (.missing, .noCamera),
        ] {
            let h = make(access: access)
            h.runner.press(now: 0)
            #expect(h.runner.phase == face)
            #expect(h.camera.starts == 0)
            #expect(h.holds.value.isEmpty, "a face with nothing running holds nothing")
            #expect(h.cameraUse.value.isEmpty)
        }
    }

    @Test("Pressing on a refusal puts the month back and gives nothing up")
    func pressOnARefusal() {
        let h = make(access: .refused)
        h.runner.press(now: 0)
        h.runner.press(now: 1)
        #expect(h.runner.phase == .off)
        #expect(h.camera.stops == 0)
    }

    @Test("Open Settings opens settings and nothing else")
    func openSettings() {
        let h = make(access: .refused)
        h.runner.press(now: 0)
        h.runner.openSettings()
        #expect(h.settingsOpened.value == 1)
        #expect(h.runner.phase == .refused, "the card waits where it was")
    }

    @Test("A camera that will not start is not called a refusal")
    func startRefused() {
        let h = make()
        h.camera.refusesToStart = true
        h.runner.press(now: 0)
        #expect(h.runner.phase == .failed)
        #expect(h.holds.value.isEmpty)
    }

    // MARK: - Closing

    @Test("A second press lets the camera go")
    func pressCloses() {
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()
        h.runner.press(now: 2)

        #expect(h.runner.phase == .off)
        #expect(h.camera.stops == 1)
        #expect(h.holds.value == [true, false])
        #expect(h.cameraUse.value == [true, false])
    }

    @Test("Join lets the camera go before the meeting app asks for it")
    func joinLetsGo() {
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()
        h.runner.letGo()

        #expect(h.camera.stops == 1)
        #expect(h.runner.phase == .off)
    }

    @Test("Join with no frame open does nothing at all")
    func joinWithNothingOpen() {
        let h = make()
        h.runner.letGo()
        #expect(h.camera.stops == 0)
        #expect(h.published.value.isEmpty, "a card that never changed must not redraw")
    }

    @Test("The card going away takes the camera with it")
    func cardWentAway() {
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()
        h.runner.cardWentAway()

        #expect(h.runner.phase == .off)
        #expect(h.camera.stops == 1)
        #expect(h.holds.value == [true, false])
    }

    @Test("A card going away with nothing running is not news")
    func cardWentAwayQuietly() {
        let h = make()
        h.runner.cardWentAway()
        #expect(h.published.value.isEmpty)
    }

    // MARK: - The two clocks

    @Test("The minute only runs while the pointer is away")
    func minuteAway() {
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()
        h.runner.pointerChanged(inside: false, now: 10)

        h.runner.tick(now: 69)
        #expect(h.runner.phase == .live, "a second short of the minute")
        h.runner.tick(now: 70)
        #expect(h.runner.phase == .off)
        #expect(h.camera.stops == 1)
    }

    @Test("Coming back to the notch cancels the count and starts the minute over")
    func comingBack() {
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()
        h.runner.pointerChanged(inside: false, now: 0)
        h.runner.tick(now: 55)
        #expect(h.published.value.last?.countdown == 5)

        h.runner.pointerChanged(inside: true, now: 56)
        #expect(h.published.value.last?.countdown == nil, "nothing is closing any more")
        h.runner.tick(now: 80)
        #expect(h.runner.phase == .live, "the pointer is back; the minute is not owed")

        // Leaving again starts a fresh minute rather than resuming the old one.
        h.runner.pointerChanged(inside: false, now: 90)
        h.runner.tick(now: 140)
        #expect(h.runner.phase == .live)
        h.runner.tick(now: 150)
        #expect(h.runner.phase == .off)
    }

    @Test("The count only appears for the last ten seconds")
    func countdownAppearsLate() {
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()
        h.runner.pointerChanged(inside: false, now: 0)

        h.runner.tick(now: 49)
        #expect(h.published.value.last?.countdown == nil)
        h.runner.tick(now: 52)
        #expect(h.published.value.last?.countdown == 8)
    }

    @Test("A cursor parked on the notch still loses the camera after five minutes")
    func theCap() {
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()
        h.runner.pointerChanged(inside: true, now: 0)

        h.runner.tick(now: 299)
        #expect(h.runner.phase == .live)
        h.runner.tick(now: 300)
        #expect(h.runner.phase == .off)
        #expect(h.camera.stops == 1)
    }

    @Test("A session begun with the pointer already away gets its whole minute")
    func startedWhileAway() {
        let h = make()
        // The pointer left long before anything was pressed.
        h.runner.pointerChanged(inside: false, now: 0)
        h.runner.press(now: 500)
        h.camera.onFirstFrame?()

        h.runner.tick(now: 540)
        #expect(h.runner.phase == .live, "the minute starts with the camera, not with the pointer")
        h.runner.tick(now: 560)
        #expect(h.runner.phase == .off)
    }

    @Test("Every panel gets a layer of its own")
    func layersAreNotShared() {
        // A Mac with an external display has two panels drawing the same
        // card. A CALayer has one superlayer, so a shared one would be taken
        // by the second panel and the first would go black.
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()

        let first = h.runner.makePreviewLayer()
        let second = h.runner.makePreviewLayer()
        #expect(first != nil)
        #expect(second != nil)
        #expect(first !== second)
    }

    @Test("A new session is a new number, so the views know to ask again")
    func sessionsAreNumbered() {
        let h = make()
        let before = h.runner.sessionID
        h.runner.press(now: 0)
        #expect(h.runner.sessionID == before + 1)

        h.runner.press(now: 1)
        #expect(h.runner.sessionID == before + 1, "closing is not a new session")
        #expect(h.runner.makePreviewLayer() == nil, "nothing is running to draw")

        h.runner.press(now: 2)
        #expect(h.runner.sessionID == before + 2, "opening again is")
    }

    // MARK: - What the shell wires up

    /// The coordinator's own source, for the two rules that are about how it
    /// is wired rather than about what the runner computes.
    private static var coordinatorSource: String {
        (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/LedgeShell/Coordinator/LedgeCoordinator.swift"),
            encoding: .utf8
        )) ?? ""
    }

    @Test("A readout over the card is not the card going away")
    func aReadoutIsNotADismissal() {
        // Found by review: a volume key replaces the calendar with the
        // readout, the card's `onDisappear` fires, and the camera the
        // reducer had just promised to hand back was stopped instead. The
        // phase is the only thing that can tell those apart, and only the
        // shell knows it.
        let source = Self.coordinatorSource
        guard let action = source.range(of: "cardWentAway: { [weak self] in") else {
            Issue.record("the self-view's teardown action has been rewired; this guard needs rewriting")
            return
        }
        let body = source[action.lowerBound...].prefix(600)
        #expect(
            body.contains("state.phase != .hud"),
            "a card hidden behind a readout is owed back, camera and all"
        )
    }

    @Test("A camera outlives neither the card nor the meeting it belongs to")
    func theTickerChecksTheCardIsStillEarned() {
        // Found by review: a meeting can end while the calendar is off
        // screen behind a readout. The card comes back without Join — and
        // so without the segment that closes the picture — but the picture
        // was still there, with nothing left to end it.
        let source = Self.coordinatorSource
        guard let rule = source.range(of: "private var selfViewIsStillEarned: Bool") else {
            Issue.record("the eligibility rule has been renamed; this guard needs rewriting")
            return
        }
        let body = source[rule.lowerBound...].prefix(400)
        #expect(body.contains("case .event"), "the calendar must still be the selected card")
        #expect(body.contains("joinLink != nil"), "and it must still have a meeting to join")
        #expect(
            source.contains("guard self.selfViewIsStillEarned else {"),
            "and the ticker has to read it"
        )
    }

    @Test("The privacy card is asked to look again while the picture is up")
    func theTickerRechecksSharing() {
        // Another application taking the camera Ledge already has open
        // changes nothing the watcher can see: the device was running
        // either way. Without a nudge, the card would wait out the
        // watcher's sixty-second safety poll before saying so.
        let source = Self.coordinatorSource
        guard let ticker = source.range(of: "selfViewTicker = Task { @MainActor") else {
            Issue.record("the ticker has moved; this guard needs rewriting")
            return
        }
        let body = source[ticker.lowerBound...].prefix(1_200)
        #expect(body.contains("privacyProviderRef?.recheck()"))
        #expect(body.contains("phase.isRunningCamera"), "and only while a camera is actually on")
    }

    @Test("The self-view's deadlines are measured in elapsed time")
    func deadlinesAreMonotonic() {
        // Found by review: every deadline here is a length of time, and a
        // civil clock moving backwards — daylight saving, a time-server
        // correction — would have handed the camera an extra hour.
        let source = Self.coordinatorSource
        guard let clock = source.range(of: "private static func selfViewClock()") else {
            Issue.record("the self-view clock has been renamed; this guard needs rewriting")
            return
        }
        let body = source[clock.lowerBound...].prefix(200)
        #expect(body.contains("systemUptime"))
        #expect(body.contains("Date(") == false)
    }

    @Test("Nothing ticks when nothing is running")
    func quietWhenOff() {
        let h = make()
        h.runner.tick(now: 10_000)
        #expect(h.published.value.isEmpty)
        #expect(h.runner.phase == .off)
    }

    @Test("A quarter-second tick that changes nothing redraws nothing")
    func quietTicks() {
        let h = make()
        h.runner.press(now: 0)
        h.camera.onFirstFrame?()
        let drawn = h.published.value.count

        h.runner.tick(now: 1)
        h.runner.tick(now: 1.25)
        h.runner.tick(now: 1.5)
        #expect(h.published.value.count == drawn, "the notch must not redraw four times a second")
    }
}
