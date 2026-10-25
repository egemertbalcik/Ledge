import LedgeCore
import Observation

/// What the settings window shows about permissions and providers.
///
/// Same arrangement as `NotchPresentation`: `LedgeUI` owns an observable built
/// only from `LedgeCore` values, and the shell writes it. That is what keeps the
/// view layer from needing to know how a permission is checked or how a
/// provider is constructed.
@MainActor
@Observable
public final class SettingsModel {

    public var permissions: [PermissionRow] = [] {
        didSet { forgetSettledWaits(previous: oldValue) }
    }

    /// Whether an Accessibility grant has actually reached this process.
    ///
    /// Kept beside the grant rather than derived from it, because macOS can
    /// say granted while the key presses never arrive — it holds a new grant
    /// back until the app starts again. Without this, every list says
    /// "Granted" over a feature that plainly does not work.
    public var accessibilityIsInEffect = true

    /// Where a press sent somebody. The two end differently, which is the
    /// whole reason they are told apart.
    public enum PermissionWait: Equatable, Sendable {
        /// macOS's own prompt is up. It ends when the request answers —
        /// including when the answer changes nothing, which is what a prompt
        /// macOS declined to show looks like from here.
        case prompt
        /// System Settings is open on Ledge's behalf. It ends when Ledge is
        /// active again, whatever the switch says: somebody who came back
        /// without switching anything on must get their button back.
        case systemSettings
    }

    /// What each row is waiting on, in the words it shows while it waits.
    ///
    /// Kept in the model rather than in a view, because the same permission
    /// is drawn in three places — the Permissions pane, a card's page and
    /// the Cards list — and they cannot be allowed to disagree about whether
    /// a prompt is already up.
    public private(set) var waitingFor: [PermissionKind: String] = [:]

    /// What kind of wait each one is.
    private var waitKinds: [PermissionKind: PermissionWait] = [:]

    /// The status each wait began against, so an answer that arrives while
    /// the window is elsewhere still ends it.
    private var waitingSince: [PermissionKind: PermissionStatus] = [:]

    /// A press that has sent the person somewhere.
    public func beganWaiting(
        for kind: PermissionKind,
        on wait: PermissionWait,
        saying message: String
    ) {
        waitingFor[kind] = message
        waitKinds[kind] = wait
        waitingSince[kind] = status(of: kind)
    }

    /// One wait is over, however it ended.
    public func endedWaiting(for kind: PermissionKind) {
        waitingFor.removeValue(forKey: kind)
        waitKinds.removeValue(forKey: kind)
        waitingSince.removeValue(forKey: kind)
    }

    /// Ledge is in front again, so nobody is in System Settings on its
    /// behalf any more.
    ///
    /// Without this, a row whose switch was not touched kept saying "Waiting
    /// for you in System Settings…" with no button for the rest of the app's
    /// life: the wait only ever ended on a status change, and coming back
    /// having changed nothing is not one.
    public func cameBackFromSystemSettings() {
        for (kind, wait) in waitKinds where wait == .systemSettings {
            endedWaiting(for: kind)
        }
        // The handoff itself outlives the wait. The watch is still running,
        // so a grant made a minute from now is still noticed and still
        // announced; what changes is what the row says in the meantime. It
        // keeps the guide and the drag open, which is the whole answer to the
        // one case the app cannot detect — a list holding an older copy of
        // Ledge.
        if let handoff, handoff.phase == .waiting {
            if status(of: handoff.kind) == .notDetermined {
                self.handoff?.phase = .back
            } else {
                // An answer arrived. Whatever it was, the row now says it
                // better than the guide can.
                self.handoff = nil
                appDragEnded = nil
            }
        }
    }

    /// Drops the waits whose answers have arrived.
    private func forgetSettledWaits(previous: [PermissionRow]) {
        guard !waitingFor.isEmpty else { return }
        for (kind, began) in waitingSince where status(of: kind) != began {
            endedWaiting(for: kind)
            // An answer closes the guide too: the row's own face says more
            // about a grant or a refusal than a diagram of where to look.
            if handoff?.kind == kind {
                handoff = nil
                appDragEnded = nil
            }
        }
    }

    /// The face one permission wears right now, everywhere it is drawn.
    public func face(of kind: PermissionKind) -> PermissionFace {
        PermissionPresentation.face(
            kind,
            status: status(of: kind),
            isInEffect: kind == .accessibility ? accessibilityIsInEffect : true,
            waitingFor: waitingFor[kind],
            cameBackStillOff: handoff?.kind == kind && handoff?.phase == .back
        )
    }

    /// A press sent somebody to System Settings for this permission.
    ///
    /// - Parameter isFirstTime: whether macOS's own one-time Accessibility
    ///   message is up alongside the list.
    public func beganHandoff(for kind: PermissionKind, isFirstTime: Bool = false) {
        // One at a time. A second press while the first is still out replaces
        // it, and the row it replaces has to stop saying it is waiting —
        // otherwise it says "Waiting for you in System Settings…", with no
        // button, for the rest of the session.
        if let previous = handoff?.kind, previous != kind {
            endedWaiting(for: previous)
        }
        handoff = PermissionHandoff(kind: kind, phase: .waiting, isFirstTime: isFirstTime)
        appDragEnded = nil
        beganWaiting(for: kind, on: .systemSettings, saying: PermissionCopy.waitingInSettings)
    }

    /// The handoff is over: an answer arrived, Stop Waiting was pressed, or
    /// the watch ran out.
    public func endedHandoff() {
        guard let kind = handoff?.kind else { return }
        handoff = nil
        appDragEnded = nil
        endedWaiting(for: kind)
    }

    /// How many permissions are waiting on the person.
    ///
    /// A row that is mid-prompt counts too: it has no button because one is
    /// already up, and "nothing is waiting for you" under a spinner is the
    /// window disagreeing with itself.
    public var waitingOnYou: Int {
        permissions.filter { row in
            waitingFor[row.kind] != nil || face(of: row.kind).remedy != nil
        }.count
    }
    public var providers: [ProviderDescriptor] = []

    /// The Devices pane's own model, when the shell has a catalogue to back
    /// it. nil in the preview and in tests that do not exercise devices, and
    /// the pane says so rather than rendering an empty list as if it were an
    /// answer.
    public var devices: DevicesSettingsModel?

    /// The pane on screen, by its name. Closing the window takes its content
    /// down so nothing keeps polling behind it, and this is what the next
    /// opening uses to come back to the same pane.
    public var shownPane: String?

    /// Waits for anything the Settings panes still owe the disk. Called on
    /// the way out.
    public func drainPendingWrites() async {
        await devices?.drainPendingWrites()
    }

    /// What the app can currently see playing, and why. Follows a demotion
    /// live, so a settings window left open tells the truth.
    public var mediaSource: MediaSourceStatus = .playersOnly

    /// True when the process that launched the app is a terminal.
    ///
    /// Worth surfacing because macOS credits a permission grant to the
    /// *responsible* process, so anything granted in that state attaches to the
    /// terminal instead — which looks exactly like a denial and is miserable to
    /// diagnose.
    public var isLaunchedFromTerminal = false

    /// Whether the key tap is *actually* running — not whether it was asked
    /// for. The switch below it is a wish; this is what came of the wish, and
    /// a user watching the macOS readout appear over Ledge's own is owed the
    /// difference in writing rather than in a log line nobody reads.
    public var isSuppressingSystemHUD = false

    /// Whether Keep Awake's privileged helper could be installed here, and
    /// whether it is.
    ///
    /// A value rather than a check the pane runs, for the same reason as the
    /// Focus folder below: the pane only redraws when something it observes
    /// moves, and a helper installed while the window was open went on
    /// reading "not set up" until something unrelated happened to redraw it.
    public var keepAwakeHelper: KeepAwakeHelperInstallation = .notInstalled

    /// A permission being granted in System Settings, while it is happening.
    ///
    /// The row alone cannot carry this: the person is in another app, the
    /// switch is in a list Ledge cannot read, and the only honest things to
    /// show are where to look and a way to stop waiting. Held here so the
    /// tour and the Permissions pane draw the same thing.
    public var handoff: PermissionHandoff?

    /// How a drag of Ledge's own icon ended, when it did not land in the
    /// list. Cleared by the next press.
    public var appDragEnded: AppDragOutcome?

    /// Whether macOS has already shown its one-time Accessibility message
    /// for this copy of Ledge.
    ///
    /// Written down rather than detected: macOS shows that message at most
    /// once in an app's life and tells the app nothing about it. The guide
    /// mentions it only while it can still appear, because a sentence about a
    /// dialog that is not there is a sentence that makes somebody look for
    /// one.
    public var accessibilityWasAskedBefore = false

    /// Ledge's own location on disk, for the Accessibility list.
    ///
    /// Nil when Ledge is running from a disk image or a translocated path:
    /// adding *that* to the list grants a copy that disappears, so the guide
    /// says to move Ledge to Applications instead of offering the drag.
    public var appLocation: String?

    /// What Ledge is doing to the Keep Awake helper right now.
    ///
    /// Written by the shell, read by whichever Keep Awake pane happens to be
    /// on screen. It used to be `@State` inside the pane, so leaving the
    /// pane and coming back during a removal produced a fresh view with no
    /// memory of it — offering Remove again, over a privileged operation
    /// still in flight.
    public var keepAwakeOperation: KeepAwakeOperation?

    /// Whether Sparkle has a check in flight.
    ///
    /// Observable state the shell writes, not a closure the button calls:
    /// `canCheckForUpdates` was read during `body`, and nothing about Sparkle
    /// finishing is something a view can observe, so the button kept whatever
    /// it had been drawn with until an unrelated redraw.
    public var isCheckingForUpdates = false

    /// Whether the Focus database folder can be read.
    ///
    /// Observable state rather than a closure the view calls, because a view
    /// only redraws when something it observes changes: the row went on saying
    /// "Not granted" after the folder had been granted, until something else
    /// happened to redraw the pane.
    public var focusFolderGranted = false

    /// The event calendars on this Mac, for the Calendar card's page to
    /// offer one by one. Filled by the shell, which is the only layer that can
    /// read them; empty without the Calendars grant.
    public var calendars: [CalendarInfo] = []

    /// Whether the folder exists yet. macOS makes it the first time a Focus
    /// is used, and until then there is nothing to hand over — which the row
    /// now says, instead of opening a panel on a folder that is not there.
    public var focusFolderExists = true

    /// Whether the open panel is up.
    public var focusFolderPanelIsUp = false

    /// What was picked instead, when somebody wandered off the folder and
    /// pressed Grant Access. Ledge keeps nothing in that case.
    public var focusFolderWrongPick: String?

    /// Where the Focus folder stands, as one value.
    public var focusFolderState: FocusFolderState {
        if focusFolderPanelIsUp { return .waiting }
        if focusFolderGranted { return .granted }
        if let picked = focusFolderWrongPick { return .wrongFolder(picked: picked) }
        if !focusFolderExists { return .noFolderYet }
        return .notGranted
    }

    public var focusFolderFace: FocusFolderFace { FocusFolderCopy.face(focusFolderState) }

    public init() {}

    public func status(of kind: PermissionKind) -> PermissionStatus {
        permissions.first { $0.kind == kind }?.status ?? .notDetermined
    }
}


/// A privileged operation on the Keep Awake helper.
public enum KeepAwakeOperation: String, Equatable, Sendable {
    case settingUp
    case removing

    /// What the pane says while it runs.
    public var headline: String {
        switch self {
        case .settingUp: "Asking macOS…"
        case .removing: "Removing…"
        }
    }

    public var detail: String {
        switch self {
        case .settingUp: "macOS may show its own message. Nothing is running yet."
        case .removing: "Taking the helper out and letting macOS forget it."
        }
    }
}


/// A permission being granted in System Settings, while it is happening.
public struct PermissionHandoff: Equatable, Sendable {

    public enum Phase: Equatable, Sendable {
        /// System Settings is open and Ledge is watching for the grant.
        case waiting
        /// Ledge is in front again and the grant still has not arrived. Not
        /// a failure: the commonest cause is a list holding an *older* copy
        /// of Ledge, which looks switched on and grants nothing.
        case back
    }

    public var kind: PermissionKind
    public var phase: Phase

    /// Whether macOS's own one-time Accessibility message is up alongside
    /// the list. It is what puts Ledge in that list at all, so the guide
    /// mentions it once and never again.
    public var isFirstTime: Bool

    public init(kind: PermissionKind, phase: Phase = .waiting, isFirstTime: Bool = false) {
        self.kind = kind
        self.phase = phase
        self.isFirstTime = isFirstTime
    }
}

/// How a drag of Ledge's icon ended.
public enum AppDragOutcome: Equatable, Sendable {
    /// Dropped somewhere that is not the list.
    case missed
    /// Dropped on another application — Finder, most likely, where a
    /// link-only drag leaves an alias and nothing else.
    case landedElsewhere
}
