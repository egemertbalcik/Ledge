import AppKit
import Foundation
import LedgeCore
import LedgeUI

/// Everything a permission press touches outside itself.
///
/// Closures, so the whole flow can run in a test with a System Settings that
/// is or isn't in front, answers that arrive when the test says, and windows
/// that only count how often they were moved.
@MainActor
struct PermissionFlowWorld {
    var status: (PermissionKind) -> PermissionStatus
    /// Asks. The flag says macOS's one-time Accessibility message may appear.
    var request: (PermissionKind, _ alertMayAppear: Bool) async -> PermissionStatus
    var openSettings: (PermissionKind) -> Void
    /// Re-reads every permission and acts on what moved, which is how a grant
    /// can reach `grantArrived` before the code that asked hears of it.
    var reread: () -> Void
    /// An answer came back from `request`, whoever owns the press by now.
    var answered: (PermissionKind, PermissionStatus) -> Void

    var settingsIsVisible: () -> Bool
    var tourIsVisible: () -> Bool
    var presentSettings: () -> Void
    var raiseTour: () -> Void
    var reclaimFront: () -> Void
    var standAside: () -> Void

    var systemSettingsHoldsTheFront: () -> Bool
    var panelIsUp: () -> Bool
    var endPanelArrival: () -> Void
    /// Calls back when somebody leaves System Settings for another application
    /// or closes it. Returns what stops listening.
    var watchComingBack: (@escaping @MainActor () -> Void) -> @MainActor () -> Void

    var accessibilityWasAsked: () -> Bool
    var markAccessibilityAsked: () -> Void

    var sayWaiting: (PermissionKind) -> Void
    var sayArrived: (PermissionKind) -> Void
    var clearLock: () -> Void

    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
}

/// One press on a permission button, from the press to whichever window ends
/// up in front.
///
/// Apart from the coordinator so it can be run. The rules here broke twice
/// while source-reading tests stayed green: a check in the wrong place, then a
/// way of getting an answer that went round the check altogether.
@MainActor
final class PermissionFlow {

    /// Which window sent somebody out to grant something.
    ///
    /// The raise after a grant used to be exactly that — settings only — so
    /// a grant made from the tour raised nothing: the tour had been lowered to
    /// stand aside for System Settings, and it sat behind it afterwards, in an
    /// app with no Dock icon to go looking for.
    enum WhoAsked { case settings, tour }

    /// One press that is still waiting for an answer.
    ///
    /// Owned here rather than read back from `SettingsModel`, and identified
    /// by a token rather than by its permission. Both for the same reason:
    /// this is what the notch's lock and the arrival card hang off, and the
    /// model's copy is derived — it folds itself away the moment the
    /// permissions are re-read, which is the line *before* the grant is
    /// announced. Asking the model afterwards left the lock in the ears with
    /// no watch behind it and no arrival ever said. The token is what tells
    /// one press from the next: "Open System Settings Again" is a second
    /// attempt at the same permission, and the first attempt's ending must
    /// not tear down the second attempt's guide.
    private struct Attempt {
        let token = UUID()
        let kind: PermissionKind
        /// Which window to bring back. Nil when nobody left the app — a
        /// prompt is answered in front of the window that asked.
        let who: WhoAsked?
    }

    /// How long to keep looking for a permission the user was just sent to
    /// System Settings to grant.
    static let watchWindow: TimeInterval = 240

    private let model: SettingsModel
    private let world: PermissionFlowWorld

    private var attempt: Attempt?
    private var watch: Task<Void, Never>?

    /// What the standing watch owes whoever started it.
    ///
    /// Held beside the task rather than only inside it, because a watch can
    /// end by being replaced — a second request made while the first is still
    /// out — and a cancelled task's own `defer` cannot be the thing that
    /// reports the end: cancellation skips it, which left the row that was
    /// saying "Waiting for your answer…" saying it forever.
    private var watchEnd: (@MainActor () -> Void)?
    private var stopWatchingComingBack: (@MainActor () -> Void)?

    /// A grant landed, or the wait ran out, with somebody still at System
    /// Settings, so the window that asked was left where it was.
    ///
    /// Bringing it up then was the jolt of the whole handoff: it jumped over
    /// the window they were looking at, took the keyboard and covered what was
    /// announcing the grant. It comes back when they do. Nothing else brings
    /// it back, so everything that counts as coming back ends this.
    private(set) var isOwedTheFront = false

    /// Whether somebody is out granting something and the watch is on it.
    var isWatching: Bool { watch != nil }

    init(model: SettingsModel, world: PermissionFlowWorld) {
        self.model = model
        self.world = world
    }

    // MARK: - Presses

    /// Both permission entry points use the same window and grant lifecycle.
    func press(_ kind: PermissionKind) {
        world.standAside()
        // Read before the attempt below writes it down. Only the first press
        // in Ledge's life can raise macOS's own message.
        let alertMayAppear = kind == .accessibility && !world.accessibilityWasAsked()
        // Accessibility's request *is* a handoff: `AXIsProcessTrustedWithOptions`
        // puts Ledge in the list and opens that list, and the switch is
        // flipped there rather than in a prompt. It goes through the request
        // rather than through the pane alone because only that call puts
        // Ledge in the list at all.
        // Every press is an attempt, whether or not it leaves the app: it is
        // the token, not the permission, that decides whose ending is whose.
        let token = beganAttempt(for: kind, handingOff: kind.isGrantedInSystemSettings)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A press can be overtaken before this task has had a turn —
            // the attempt is made synchronously, the request is not — and
            // macOS cannot be asked to take a request back. Accessibility's
            // opens a System Settings pane, so a stale one sends somebody
            // towards the permission they have already moved on from.
            guard self.attempt?.token == token else { return }
            let status = await self.world.request(kind, alertMayAppear)
            // Update the snapshot as well as providers, so the next poll does
            // not treat this same answer as a second grant and restart again.
            self.world.reread()
            self.world.answered(kind, status)
            // And again on the way back: this press may have been overtaken
            // while the answer was in flight. Everything below installs a
            // watch or takes the foreground, either of which would cancel
            // the newer press's watch or pull the front away from it.
            guard self.attempt?.token == token else { return }
            if status == .granted || !kind.isGrantedInSystemSettings {
                // Location is the exception, and it is an exception twice
                // over: its request returns as soon as it has *asked*, and
                // the answer arrives through a delegate. Ending the wait
                // here would take the spinner away while the dialog is still
                // up; taking the front back would put Ledge's own window
                // over that dialog.
                if !kind.answersBeforeReturning && status == .notDetermined {
                    self.watchForAnswer(kind) { [weak self] in
                        // Ownership decides the foreground too: a watch whose
                        // press has been overtaken must not pull the front
                        // back from whatever replaced it.
                        self?.settleTheFront(token)
                    }
                } else {
                    // Answered here, whichever way — including the answer
                    // "nothing changed", which is what macOS declining to
                    // prompt looks like from here. There is no return from
                    // System Settings to wait for, and standing aside for a
                    // dialog that has already closed left the window it was
                    // asked from sitting among other applications.
                    //
                    // No watch was ever installed for this answer, so nothing
                    // else will say it arrived or decide about the front.
                    self.sayTheAnswerArrived(for: kind)
                    self.settleTheFront(token)
                }
            } else {
                self.watchForAnswer(kind) { [weak self] in self?.endedAttempt(token) }
            }
        }
    }

    /// A press that only opens System Settings, with nothing to ask.
    func openSettings(for kind: PermissionKind) {
        world.standAside()
        let token = beganAttempt(for: kind, handingOff: true)
        world.openSettings(kind)
        // However this ends — an answer, the window closing, the four
        // minutes running out — the row stops saying it is waiting
        // and the notch stops holding the lock.
        watchForAnswer(kind) { [weak self] in self?.endedAttempt(token) }
    }

    /// The one way out that does not depend on System Settings doing anything.
    /// Cancelling the watch runs its own ending, which is what takes the row's
    /// spinner away.
    func stopWaiting() {
        stopWatching()
        endedCurrentAttempt()
        world.reclaimFront()
    }

    /// Ledge is going away.
    func stop() {
        clearOwedTheFront()
        stopWatching()
        attempt = nil
        world.clearLock()
    }

    // MARK: - Answers

    /// Brings the window back after the user has granted something.
    ///
    /// The grant happens in System Settings, which opens *over* Ledge's
    /// window, and Ledge is an accessory app: once it is behind something
    /// there is no Dock icon and no Cmd-Tab entry to get back to it, so the
    /// window had to be hunted for among everything else on screen. Only when
    /// the window was already open — a grant made from the tour, or from
    /// System Settings with nothing of ours on screen, moves nothing.
    /// - Parameter kind: the permission whose answer arrived, or nil when the
    ///   caller is somebody clicking the notch. Checked against the press
    ///   that is outstanding: a Calendar grant landing while somebody is in
    ///   System Settings over *Bluetooth* is not a reason to take the
    ///   foreground away from them — and a permission can appear to flap
    ///   several times a minute.
    func grantArrived(_ kind: PermissionKind?) {
        // Only while the user is out granting something they asked for from
        // this window. Any gain at all used to bring the window forward, and
        // since a permission could appear to flap several times a minute, the
        // app repeatedly stole focus from whatever the user was doing —
        // including from System Settings, where they were trying to grant.
        let arrival = GrantArrival(
            kind: kind,
            pressKind: attempt?.kind,
            isWatching: watch != nil,
            isStillAtSystemSettings: isStillAtSystemSettings
        )
        guard arrival == .raise, let open = attempt else {
            if arrival == .owe { owedTheFront() }
            return
        }
        // Whichever window asked. The tour is the one that cannot be found
        // again: it was lowered to stand aside for System Settings, and
        // nothing but an activation floats it back.
        switch open.who {
        case .tour where world.tourIsVisible():
            world.raiseTour()
        case .settings, .tour, nil:
            guard world.settingsIsVisible() else {
                // The tour is the only other window that asks, so it is the
                // fallback when Settings is not up.
                if world.tourIsVisible() { world.raiseTour() }
                return
            }
            world.presentSettings()
        }
    }

    /// Only for a press that sent somebody there. A prompt answered with System
    /// Settings merely open somewhere behind is none of this.
    private var isStillAtSystemSettings: Bool {
        attempt?.who != nil && world.systemSettingsHoldsTheFront()
    }

    /// The end of a press that answered without somebody clicking back: leaves
    /// the window behind System Settings if that is where they still are.
    /// Read before the attempt ends, because it asks who the press sent there.
    private func settleTheFront(_ token: UUID) {
        guard attempt?.token == token else { return }
        let stillThere = isStillAtSystemSettings
        endedAttempt(token)
        if stillThere {
            owedTheFront()
        } else {
            world.reclaimFront()
        }
    }

    private func owedTheFront() {
        isOwedTheFront = true
        guard stopWatchingComingBack == nil else { return }
        stopWatchingComingBack = world.watchComingBack { [weak self] in self?.personCameBack() }
    }

    /// Forgets the debt without moving anything.
    private func clearOwedTheFront() {
        isOwedTheFront = false
        stopWatchingComingBack?()
        stopWatchingComingBack = nil
    }

    /// They left System Settings, or closed it. Floats the window again
    /// without activating anything: whatever they went to keeps the keyboard.
    func personCameBack() {
        guard isOwedTheFront else { return }
        clearOwedTheFront()
        world.reclaimFront()
        world.endPanelArrival()
    }

    /// A press on the panel or the notch, so taking the front here is asked for.
    func goBackToTheAskingWindow() {
        clearOwedTheFront()
        world.endPanelArrival()
        if world.tourIsVisible() {
            world.raiseTour()
        } else if world.settingsIsVisible() {
            world.presentSettings()
        }
    }

    // MARK: - The watch

    /// Watches for an answer that arrives somewhere else.
    ///
    /// TCC broadcasts nothing, so without this the grant is only noticed when
    /// Ledge next becomes active — which is the very thing the user cannot do
    /// without first finding the window. Bounded, and only ever running while
    /// a request the user made is outstanding and the settings window is up.
    ///
    /// - Parameter onEnd: called however the watch ends — an answer, the
    ///   window closing, or the four minutes running out. Whatever the row
    ///   was saying while it waited stops being true at all three.
    private func watchForAnswer(_ kind: PermissionKind, onEnd: (@MainActor () -> Void)? = nil) {
        stopWatching()
        watchEnd = onEnd
        let before = world.status(kind)
        // Automation is read by sending an Apple Event to a player, so it is
        // asked for less often than the rest, which are local reads.
        let interval: TimeInterval = kind == .automation ? 2 : 1
        watch = Task { @MainActor [weak self] in
            // Whichever way this ends — an answer, the window closing, the
            // four minutes running out — the watch stops being "the user is
            // out granting something". It is what `grantArrived`
            // reads, so a watch left standing meant a grant made an hour later
            // for some other reason could pull the settings window in front of
            // whatever the user was doing.
            defer {
                if !Task.isCancelled {
                    self?.watch = nil
                    self?.watchEnd = nil
                    onEnd?()
                }
            }
            for _ in 0..<Int(Self.watchWindow / interval) {
                guard let sleep = self?.world.sleep else { return }
                await sleep(.seconds(interval))
                guard let self, !Task.isCancelled else { return }
                guard self.world.settingsIsVisible() || self.world.tourIsVisible() else { return }
                guard self.world.status(kind) != before else { continue }
                self.world.reread()
                self.sayTheAnswerArrived(for: kind)
                self.grantArrived(kind)
                return
            }
            // The four minutes ran out. The window that stood aside must not
            // stay at the back for good, and must not jump up over somebody
            // still working in System Settings either.
            guard let self else { return }
            if self.isStillAtSystemSettings {
                self.owedTheFront()
            } else {
                self.world.reclaimFront()
            }
        }
    }

    /// Ends the standing watch and tells whoever started it that it is over.
    ///
    /// The row that waits has to stop waiting on every ending, including the
    /// ones it did not cause: a second permission asked for while the first
    /// is still out replaces the watch, and Ledge going away takes it with it.
    private func stopWatching() {
        let end = watchEnd
        watchEnd = nil
        watch?.cancel()
        watch = nil
        end?()
    }

    // MARK: - Attempts

    /// A press is waiting for an answer. Returns the token that owns it.
    ///
    /// - Parameter handingOff: whether the answer happens in another
    ///   application. Only then does the notch pick up the thread.
    private func beganAttempt(for kind: PermissionKind, handingOff: Bool) -> UUID {
        // One at a time, and the one being replaced is retired here rather
        // than left for its own ending: that ending is fenced by a token
        // which is no longer current, so nothing else would ever come back
        // for it. What exactly that means for the row, the guide and the
        // notch is decided by `PermissionAttempts`, where it can be read and
        // tested on its own.
        let change = PermissionAttempts.replacing(
            attempt.map { (kind: $0.kind, handedOff: $0.who != nil) },
            with: kind,
            handingOff: handingOff,
            guideShows: model.handoff?.kind
        )
        clearOwedTheFront()
        if let ending = change.endWaitFor { model.endedWaiting(for: ending) }
        if change.clearsTheLock { world.clearLock() }
        if change.endsTheGuide { model.endedHandoff() }
        let started = Attempt(
            kind: kind,
            who: handingOff ? (world.tourIsVisible() ? .tour : .settings) : nil
        )
        attempt = started
        if handingOff {
            world.sayWaiting(kind)
            // macOS shows its one-time Accessibility message at most once in
            // an app's life and says nothing about having done so, so the
            // fact that it can still appear is written down here, at the one
            // press that can raise it.
            if kind == .accessibility, !world.accessibilityWasAsked() {
                world.markAccessibilityAsked()
            }
        }
        return started.token
    }

    /// One press is over, however it ended: an answer, Stop Waiting, or the
    /// watch running out.
    ///
    /// - Parameter token: which press ended. A watch being *replaced* runs the
    ///   old one's ending, so without this a second attempt — at another
    ///   permission, or another go at the same one — would be torn down one
    ///   line after it began, leaving somebody in System Settings with no
    ///   guide and nothing in the notch.
    private func endedAttempt(_ token: UUID) {
        guard attempt?.token == token else { return }
        endedCurrentAttempt()
    }

    /// Ends whatever press is outstanding, whichever it is.
    private func endedCurrentAttempt() {
        guard let open = attempt else { return }
        attempt = nil
        model.endedWaiting(for: open.kind)
        if open.who != nil {
            world.clearLock()
            model.endedHandoff()
        }
    }

    /// Says a grant landed, in the notch.
    ///
    /// Only for a grant somebody went out to get: an answer they are standing
    /// in front of needs no announcement, and a permission that changed for
    /// some other reason is not news. Read from this object's own record of
    /// the press rather than from the model, whose copy has already folded
    /// itself away by the time the watch gets here — the re-read of the
    /// permissions is the line before this one.
    private func sayTheAnswerArrived(for kind: PermissionKind) {
        guard let open = attempt, open.kind == kind, open.who != nil else { return }
        // A refusal is the one state Ledge cannot undo. The row says so once,
        // plainly, and the notch says nothing at all — the lock simply goes,
        // which the ending after this does.
        guard world.status(kind) == .granted else { return }
        // One place at a time. The panel is what they are looking at, and it
        // says the same words.
        guard !world.panelIsUp() else { return }
        world.sayArrived(kind)
    }
}

extension PermissionFlow {

    /// The real signals for somebody having left System Settings.
    static func watchComingBack(_ cameBack: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let center = NSWorkspace.shared.notificationCenter
        let observers: [any NSObjectProtocol] = [
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let isRegular = app?.activationPolicy == .regular
                let id = app?.bundleIdentifier
                MainActor.assumeIsolated {
                    let front = SystemSettingsWindow.classify(
                        bundleIdentifier: id, isRegular: isRegular, isSelf: false
                    )
                    if front == .regularApp { cameBack() }
                }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let id = app?.bundleIdentifier
                MainActor.assumeIsolated {
                    if id == SystemSettingsWindow.bundleIdentifier { cameBack() }
                }
            },
        ]
        return {
            for observer in observers { center.removeObserver(observer) }
        }
    }
}
