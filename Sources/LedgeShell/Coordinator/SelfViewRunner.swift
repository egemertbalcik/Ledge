import Foundation
import LedgeCore
import LedgeSystem
import QuartzCore
import os

/// Runs the calendar card's self-view: what the camera is doing, how long it
/// has left, and who is told about it.
///
/// Every decision it makes is a pure one from `SelfViewPolicy`, and every
/// moment it acts on arrives through `tick(now:)`. That is deliberate: the
/// interesting behaviour here is all about time — a sentence that waits six
/// tenths of a second, a session abandoned at five, a minute that only runs
/// while the pointer is away — and none of it would be testable if the clock
/// were read in here.
@MainActor
public final class SelfViewRunner {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "selfview")

    private let camera: any SelfViewCapturing

    /// Publishes the card's payload. Called only when something actually
    /// changed, so a quarter-second tick does not redraw the notch.
    private let publish: (SelfViewPayload) -> Void

    /// Tells the shell whether the notch must stay open against its own
    /// rules. Called on every change of that answer and never otherwise.
    private let holdChanged: (Bool) -> Void

    /// Tells Ledge's own privacy card that this camera use is Ledge's, and
    /// which camera it is. The identity is what keeps the card honest about
    /// everybody else's.
    private let cameraUseChanged: (Bool, String?) -> Void

    /// Opens System Settings at the camera pane.
    private let openCameraSettings: () -> Void

    /// Which session is running, counted up from zero.
    ///
    /// The views that draw the picture watch this rather than a layer: each
    /// of them owns its own layer — a Mac with an external display has two
    /// panels, and a `CALayer` cannot be in two of them — and a change here
    /// is what tells them to ask for a new one.
    public private(set) var sessionID = 0

    /// A layer for one view to draw. Nil when nothing is running.
    public func makePreviewLayer() -> CALayer? {
        camera.makePreviewLayer()
    }

    private var payload = SelfViewPayload.off {
        didSet {
            guard payload != oldValue else { return }
            publish(payload)
            let holds = payload.phase.holdsNotchOpen
            if holds != oldValue.phase.holdsNotchOpen { holdChanged(holds) }
            let uses = payload.phase.isRunningCamera
            if uses != oldValue.phase.isRunningCamera {
                cameraUseChanged(uses, uses ? camera.deviceID : nil)
            }
        }
    }

    /// When the camera was asked for. Both deadlines are measured from it.
    private var startedAt: TimeInterval?

    /// When the pointer left the notch; nil while it is on it.
    private var awaySince: TimeInterval?

    /// The permission request in flight, so a second press can cancel it.
    private var asking: Task<Void, Never>?

    /// The clock every deadline here is measured against.
    ///
    /// Monotonic in the app — `systemUptime`, not `Date` — because the five
    /// minutes a camera may run are five minutes of elapsed time, and a civil
    /// clock that moves backwards (daylight saving, a time-server
    /// correction) would hand the camera an extra hour. Injected so tests can
    /// hand it any instant they like.
    private let now: () -> TimeInterval

    public init(
        camera: any SelfViewCapturing,
        publish: @escaping (SelfViewPayload) -> Void,
        holdChanged: @escaping (Bool) -> Void = { _ in },
        cameraUseChanged: @escaping (Bool, String?) -> Void = { _, _ in },
        openCameraSettings: @escaping () -> Void = {},
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.camera = camera
        self.publish = publish
        self.holdChanged = holdChanged
        self.cameraUseChanged = cameraUseChanged
        self.openCameraSettings = openCameraSettings
        self.now = now
        self.camera.onFirstFrame = { [weak self] in self?.firstFrameArrived() }
        self.camera.onFailure = { [weak self] in self?.sessionFailed() }
    }

    public var phase: SelfViewPhase { payload.phase }

    /// Which camera this would open, or has open.
    public var cameraID: String? { camera.deviceID }

    /// Whether another application is reading that camera too.
    public var isSharedWithAnotherApp: Bool { camera.isSharedWithAnotherApp }

    /// Whether anything here is holding the notch open.
    public var holdsNotchOpen: Bool { payload.phase.holdsNotchOpen }

    // MARK: - Presses

    /// The segment was pressed.
    public func press(now: TimeInterval) {
        switch SelfViewPolicy.press(on: payload.phase) {
        case .open:
            open(now: now)
        case .close:
            end(reason: "the segment")
        case .backToMonth:
            // Nothing is running behind a refusal, so this gives nothing up.
            payload = .off
        }
    }

    /// Join was pressed. The meeting app needs the camera more than the card
    /// does, and it needs it now rather than after an animation.
    public func letGo() {
        guard payload.phase != .off else { return }
        end(reason: "Join")
    }

    /// "Try again", under a session that never produced a frame.
    public func tryAgain(now: TimeInterval) {
        guard payload.phase == .failed else { return }
        begin(now: now)
    }

    /// "Open Settings", under a refusal. Ledge re-reads access on the next
    /// press, so coming back and pressing simply works.
    public func openSettings() {
        openCameraSettings()
    }

    /// The card left the screen, the notch collapsed, or the display changed.
    public func cardWentAway() {
        guard payload.phase != .off else { return }
        end(reason: "the card went away")
    }

    // MARK: - The pointer

    /// Where the pointer is. Only the minute-away clock cares; the five-minute
    /// cap runs either way.
    public func pointerChanged(inside: Bool, now: TimeInterval) {
        if inside {
            awaySince = nil
            // Coming back cancels the count, including the last few seconds
            // of it. Nothing is owed after that: the minute starts again from
            // the next time the pointer leaves.
            if payload.countdown != nil { payload.countdown = nil }
        } else if awaySince == nil {
            awaySince = now
        }
    }

    // MARK: - Time

    /// Everything that happens because time passed.
    ///
    /// Called four times a second while a session is alive, and by hand in
    /// tests. Patience, giving up, the count and the two deadlines are all
    /// decided from the same instant, so they can never disagree about it.
    public func tick(now: TimeInterval) {
        guard let startedAt, payload.phase != .off else { return }

        if payload.phase == .waking {
            let waited = now - startedAt
            if waited >= SelfViewTiming.giveUp {
                // Five seconds of nothing. The session goes before the
                // sentence appears, so the light is already out when the card
                // says the camera never started.
                camera.stop()
                self.startedAt = nil
                payload = SelfViewPayload(phase: .failed)
                Self.log.notice("selfview: gave up waiting for a frame")
                return
            }
            if !payload.waitHasLasted, waited >= SelfViewTiming.patience {
                payload.waitHasLasted = true
            }
        }

        guard payload.phase.isRunningCamera else { return }

        if SelfViewPolicy.hasExpired(startedAt: startedAt, awaySince: awaySince, now: now) {
            end(reason: awaySince == nil ? "the five-minute cap" : "a minute away")
            return
        }
        let count = SelfViewPolicy.countdown(
            phase: payload.phase,
            startedAt: startedAt,
            awaySince: awaySince,
            now: now
        )
        if count != payload.countdown { payload.countdown = count }
    }

    // MARK: - The camera

    private func open(now: TimeInterval) {
        let access = camera.access()
        guard access == .notAsked else {
            if access == .allowed {
                begin(now: now)
            } else {
                payload = SelfViewPayload(phase: SelfViewPolicy.phase(for: access))
            }
            return
        }
        // The first press is what asks. The frame opens over the month while
        // macOS's own dialog is up, because the pointer has to travel to it
        // and a notch that shut on the way would take the question with it.
        payload = SelfViewPayload(phase: .asking)
        asking?.cancel()
        asking = Task { [weak self] in
            guard let self else { return }
            let answer = await self.camera.requestAccess()
            guard !Task.isCancelled, self.payload.phase == .asking else {
                // The person closed the frame while the dialog was up. Their
                // answer is remembered by macOS and does nothing here.
                return
            }
            if answer == .allowed {
                self.begin(now: self.now())
            } else {
                self.payload = SelfViewPayload(phase: SelfViewPolicy.phase(for: answer))
            }
        }
    }

    private func begin(now: TimeInterval) {
        asking?.cancel()
        asking = nil
        guard camera.start() else {
            // Nothing to draw. The honest answer depends on why, and the only
            // reason that is not a refusal is a Mac without a front camera.
            startedAt = nil
            payload = SelfViewPayload(phase: camera.access() == .missing ? .noCamera : .failed)
            return
        }
        sessionID += 1
        startedAt = now
        // The minute away starts with the camera, not with whenever the
        // pointer happened to leave. A session begun with the pointer already
        // elsewhere — "Try again" pressed, then the hand moved — gets its
        // full minute rather than an expired one.
        if awaySince != nil { awaySince = now }
        payload = SelfViewPayload(phase: .waking)
        Self.log.notice("selfview: waking")
    }

    private func firstFrameArrived() {
        guard payload.phase == .waking else { return }
        payload = SelfViewPayload(phase: .live)
        Self.log.notice("selfview: live")
    }

    private func sessionFailed() {
        guard payload.phase.isRunningCamera else { return }
        camera.stop()
        startedAt = nil
        payload = SelfViewPayload(phase: .failed)
    }

    /// Lets the camera go and puts the month back.
    ///
    /// The session stops before anything on screen moves: the green light
    /// going out is the one part of this nobody should have to wait out an
    /// animation for.
    private func end(reason: String) {
        camera.stop()
        asking?.cancel()
        asking = nil
        startedAt = nil
        payload = .off
        Self.log.notice("selfview: closed by \(reason, privacy: .public)")
    }
}
