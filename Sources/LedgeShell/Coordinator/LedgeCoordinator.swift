import AppKit
import LedgeCore
import LedgeProviders
import LedgeSystem
import LedgeUI
import SwiftUI
import os

/// Wires the reducer, the panel, the hover tracker, and the windows together.
///
/// This is the only place that mutates `NotchState`: every input becomes a
/// `NotchEvent`, the reducer decides, and the resulting effects are handed to
/// the runner. Nothing else is allowed to set a phase directly.
@MainActor
public final class LedgeCoordinator {

    public static let log = Logger(subsystem: "com.egemert.ledge", category: "shell")

    public let preferences: Preferences
    public let presentation = NotchPresentation()

    private var state = NotchState()
    private let effects = EffectRunner()

    private lazy var displayPanels = DisplayPanels(
        make: { [unowned self] id, screen in self.makePanelController(id, screen) }
    )
    private var hoverTracker: HoverTracker<CGDirectDisplayID>?
    private var settingsWindow: NSWindow?
    private var permissionWatch: Task<Void, Never>?

    /// What the standing watch owes whoever started it.
    ///
    /// Held beside the task rather than only inside it, because a watch can
    /// end by being replaced — a second request made while the first is still
    /// out — and a cancelled task's own `defer` cannot be the thing that
    /// reports the end: cancellation skips it, which left the row that was
    /// saying "Waiting for your answer…" saying it forever.
    private var permissionWatchEnd: (@MainActor () -> Void)?

    /// The notch's half of a grant that happens in System Settings.
    private let handoffCard = HandoffProvider()

    /// Which window sent somebody out to grant something.
    ///
    /// `raiseAfterGrant` used to be exactly that — settings only — so
    /// a grant made from the tour raised nothing: the tour had been lowered to
    /// stand aside for System Settings, and it sat behind it afterwards, in an
    /// app with no Dock icon to go looking for.
    private enum WhoAsked { case settings, tour }

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
    private struct PermissionAttempt {
        let token = UUID()
        let kind: PermissionKind
        /// Which window to bring back. Nil when nobody left the app — a
        /// prompt is answered in front of the window that asked.
        let who: WhoAsked?
    }
    private var attempt: PermissionAttempt?

    /// The one folder Ledge ever asks for by name, and the reason it does not
    /// ask for Full Disk Access to get at the same thing.
    private lazy var focusFolder = FocusDatabaseAccess(
        bookmark: { [weak self] in self?.preferences.focusFolderBookmark ?? "" },
        storeBookmark: { [weak self] in self?.preferences.focusFolderBookmark = $0 }
    )

    /// Asks for the Focus database folder, and rebuilds the card on an answer.
    ///
    /// The panel opens *on* the folder, so granting is one click: `~/Library`
    /// is hidden in the Finder, and somebody sent to find it themselves would
    /// not.
    private func chooseFocusFolder() {
        let folder = FocusDatabaseAccess.databaseFolder
        // No alert. macOS makes this folder the first time a Focus is used,
        // and until then there is nothing to hand over — which the row says
        // in its own face, with no button. A modal explaining that the button
        // you just pressed should not have been there is the app admitting it
        // drew the wrong thing.
        guard FileManager.default.fileExists(atPath: folder.path) else {
            settingsModel.focusFolderExists = false
            return
        }
        standAsideForSystemUI()
        let panel = NSOpenPanel()
        panel.message = FocusFolderCopy.panelMessage
        panel.prompt = FocusFolderCopy.panelPrompt
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // Only this folder can be chosen. Without it the panel would hand
        // back whatever was on screen when Grant Access was pressed, and
        // Ledge kept it: a security-scoped bookmark to some other folder,
        // its scope held open for the life of the process, while the row went
        // on saying "Not granted" with no word about why.
        let onlyTheFocusFolder = FocusFolderPanelDelegate(allowed: folder)
        panel.delegate = onlyTheFocusFolder
        // The row says the panel is up, and why it is one press.
        settingsModel.focusFolderPanelIsUp = true
        settingsModel.focusFolderWrongPick = nil
        NSApp.activate(ignoringOtherApps: true)
        defer {
            settingsModel.focusFolderPanelIsUp = false
            reclaimFront()
        }
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        // Belt and braces over the delegate: a disabled folder cannot be
        // *selected*, but the panel still answers with whatever directory it
        // was showing, so the answer is checked as well as narrowed.
        guard FocusFolderPanelDelegate.isTheFocusFolder(picked, allowed: folder) else {
            settingsModel.focusFolderWrongPick = picked.lastPathComponent
            Self.log.notice("focus folder: kept nothing, a different folder was picked")
            return
        }
        settingsModel.focusFolderWrongPick = nil
        focusFolder.remember(picked)
        // Everything that gave up on the folder is told to look again, now:
        // the source's own retry has backed off to half a minute by this
        // point, which showed as the app ignoring a Focus for half a minute
        // after being handed the thing it needed.
        focusBaseline?.accessChanged()
        activities.restartProvider("focus")
        syncFocusQuietState()
        refreshSettingsModel()
    }

    /// Notification tokens, kept so they can be removed. `addObserver(forName:)`
    /// returns an object the centre retains until it is handed back; dropping
    /// the token leaks the registration and makes `start()` non-idempotent.
    private var observerTokens: [any NSObjectProtocol] = []
    private var distributedTokens: [any NSObjectProtocol] = []

    /// Whether the displays are asleep or the screen is locked. While dark
    /// the pointer poll and the brightness watcher stand down; the panels are
    /// not visible to anyone, and a laptop left locked overnight should not
    /// spend its battery watching for a hover that cannot happen.
    /// Why the screen is not worth polling. Each reason is remembered on its
    /// own; see `ScreenDormancy` for what one shared flag got wrong.
    private var dormancy = ScreenDormancy()

    /// Everything that owes the disk something, drained in order.
    ///
    /// Rule edits sit in the Settings model's own write mailbox, and the
    /// catalogue's writes are debounced — so quitting straight after changing
    /// a rule lost it. Both are asked to finish here, and the caller waits.
    /// The shutdown barrier: four steps, in this order, each finished before
    /// the next is trusted.
    ///
    /// Flushing while the producers were still running lost whatever landed
    /// after the write — and an alert latch lost that way says the same thing
    /// again after the next launch, which is the one thing the latch exists to
    /// prevent. So:
    ///
    /// 1. stop the providers, so nothing new is observed;
    /// 2. close the mailbox and wait for the delivery in flight;
    /// 3. drain the Settings edits, which are the user's own;
    /// 4. write the catalogue.
    ///
    /// Idempotent: a second quit request while the first is still running
    /// waits for it rather than starting again.
    public func flushPendingWork() async {
        if let existing = quiesceWork {
            await existing.value
            return
        }
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            // Keep Awake first, and before `activities.stop()` takes the
            // provider down: `stop()` lets go of the assertion but writes
            // nothing, so the session has to be ended — or deliberately left
            // running — while there is still a provider to ask.
            await self.endKeepAwakeForTermination()
            // And then wait for what ending it set in motion. The lid restore
            // is enqueued, not performed, by the end above — and a quit that
            // exits with it still queued leaves the panel at zero and the
            // record on disk. Recoverable at the next launch, which is no help
            // at all to somebody holding a dark laptop now.
            //
            // Bounded by the same budget as the session write, and for the
            // same reason: a quit wedged behind a device that has stopped
            // answering is worse than a restore that lands a moment late. The
            // record survives either way.
            await self.withTimeout(Self.keepAwakeTerminationBudget) {
                // Everything the end set in motion, not just the part of it
                // this coordinator happens to hold a handle to. Returning
                // from `end(reason:)` says the session is written down; the
                // hold being given back, the panel coming up, another
                // application's preference going back and the daemon hearing
                // "no more Low Power Mode" are each a separate piece of work
                // that nobody was waiting on.
                await self.keepAwake?.joinSideEffects()
                await self.lidConserve.settle()
                await self.lidLowPower?.settle()
            }
            // Taking the providers down starts more of the same work — a
            // second App Nap end, a second disarm — so the barrier has to come
            // after it as well as before it. Before, so the End's own
            // restores are joined while the provider still exists; after,
            // because `stop()` is itself a producer.
            let finishing = self.keepAwake
            self.activities.stop()
            await self.withTimeout(Self.keepAwakeTerminationBudget) {
                await finishing?.joinSideEffects()
                await self.lidConserve.settle()
                await self.lidLowPower?.settle()
            }
            await self.deviceObservations.close()
            await self.settingsModel.drainPendingWrites()
            await self.deviceCatalogue.flush()
            self.notesWindow.close()
            await self.notes.flush()
        }
        quiesceWork = work
        await work.value
    }

    /// The shutdown in progress, so a second request joins it.
    private var quiesceWork: Task<Void, Never>?

    // MARK: - Keep Awake

    /// How this process is about to end, which decides whether a Keep Awake
    /// session ends with it.
    ///
    /// Classified rather than inferred, because the three cases are
    /// indistinguishable from inside `applicationShouldTerminate`: Sparkle
    /// relaunching for an update, the system logging out or restarting, and the
    /// user actually quitting all arrive the same way. Only the last one means
    /// "I am done keeping this Mac awake".
    enum TerminationKind: Equatable {
        case quit
        case updateRelaunch
        case powerOff
    }

    private(set) var terminationKind: TerminationKind = .quit

    /// Told by the Sparkle delegate just before an update relaunch.
    public func willRelaunchForUpdate() {
        terminationKind = .updateRelaunch
    }

    /// Told by `NSWorkspace.willPowerOffNotification`.
    public func willPowerOff() {
        terminationKind = .powerOff
    }

    /// The provider, while the card is on. Held so the coordinator can end a
    /// session explicitly — `hub.remove` only reaches `stop()`, which is the
    /// crash-equivalent path and deliberately writes nothing.
    weak var keepAwake: KeepAwakeProvider?

    /// How long a quit may wait for the session to be written down.
    ///
    /// Bounded because a quit that hangs on a disk is worse than a session
    /// recorded a moment late: the end is released before the write is even
    /// attempted, so the Mac is already free to sleep whatever happens here.
    static let keepAwakeTerminationBudget: Duration = .seconds(6)

    private func endKeepAwakeForTermination() async {
        guard let provider = keepAwake else { return }
        switch terminationKind {
        case .updateRelaunch, .powerOff:
            // Neither is the user saying they are finished. The journal keeps
            // `running`; a relaunch in this boot resumes and announces it, and
            // a restart ends it by boot id.
            await provider.flushPendingWrites()
        case .quit:
            await withTimeout(Self.keepAwakeTerminationBudget) {
                await provider.end(reason: .quit)
            }
        }
    }

    /// Ends a session because the card is being switched off or settings are
    /// being reset.
    public func endKeepAwake(reason: KeepAwakeEndReason) async {
        guard let provider = keepAwake else { return }
        await withTimeout(Self.keepAwakeTerminationBudget) {
            await provider.end(reason: reason)
        }
    }

    /// Stops waiting on `body` after `budget`, rather than holding a quit open.
    ///
    /// It bounds the *wait*, not the work. `end` lets go of the assertion
    /// before it tries to write anything, so by the time this gives up the Mac
    /// is already free to sleep and all that is outstanding is a record
    /// catching up. A quit wedged behind a disk that has stopped answering
    /// would be the worse outcome, and a failing disk is exactly when that
    /// happens.
    private func withTimeout(_ budget: Duration,
                             _ body: @escaping @MainActor () async -> Void) async {
        let gate = FirstToFinish()
        let work = Task { @MainActor in
            await body()
            await gate.signal()
        }
        let limit = Task {
            try? await Task.sleep(for: budget)
            await gate.signal()
        }
        await gate.wait()
        work.cancel()
        limit.cancel()
    }

    /// Builds the Devices pane's model once, handing it closures that reach
    /// the catalogue actor. The pane never touches the store directly, so no
    /// filesystem work is ever asked for on the main actor.
    private func installDevicesModelIfNeeded() {
        guard settingsModel.devices == nil else { return }
        let store = deviceCatalogue
        let notifier = alertNotifier
        settingsModel.devices = DevicesSettingsModel(
            actions: DevicesSettingsModel.Actions(
                load: { await store.snapshot() },
                history: { id in await store.history(for: id) },
                setPinned: { id, pinned in await store.setPinned(pinned, for: id) },
                setHidden: { id, hidden in await store.setHidden(hidden, for: id) },
                setAlerts: { id, configuration in await store.setAlerts(configuration, for: id) },
                forget: { [weak self] id, keep in
                    await store.forget(id, keepingHistory: keep)
                    // The mailbox remembers what it last forwarded per device.
                    // Left alone, a forgotten device that is still around
                    // would not be reported again until the heartbeat came
                    // round — so it would reappear minutes later rather than
                    // on its next sighting.
                    await MainActor.run { self?.deviceObservations.forget(id) }
                },
                deleteAllHistory: { await store.deleteAllHistory() },
                // The one place notification permission is ever requested.
                requestNotificationAuthorization: { await notifier.requestAuthorization() },
                // Routed through the store's own consumer, which is the same
                // path a real alert takes. An earlier version held a weak
                // reference to the provider that was never assigned, so every
                // Preview button silently did nothing.
                preview: { rule, name in
                    Task { await store.deliverPreview(of: rule, deviceName: name) }
                }
            )
        )
    }

    /// Shows notifications for alerts that asked for them. Never requests
    /// authorisation of its own accord.
    private let alertNotifier: any AlertNotifying = SystemAlertNotifier()


    /// The device catalogue: what Ledge remembers about the hardware around
    /// it, and the one place battery alerts are decided.
    ///
    /// Owned here because the providers that feed it and the provider that
    /// delivers from it are both built here. An actor, so the disk work it
    /// does never lands on the main thread.
    public lazy var deviceCatalogue = DeviceCatalogueStore(paired: pairedDevices)

    /// What the Mac is paired with, as the Bluetooth provider last read it.
    ///
    /// Owned here because three things share one answer: the provider that
    /// reads it, the proximity provider that matches advertisements against
    /// it, and the catalogue that refuses to store anything it cannot find in
    /// it. One reading, one answer — two copies would disagree, and a
    /// catalogue pruning against the stale one would delete the user's
    /// devices.
    public let pairedDevices = PairedDeviceRegistry()

    /// Coalesces what the providers see before it reaches the catalogue.
    ///
    /// Without this, an unchanged set of AirPods in range produced a
    /// catalogue write on roughly every scan window, for as long as they sat
    /// on the desk — the scanner's six seconds and the write debounce's five
    /// simply lined up.
    public lazy var deviceObservations = ObservationMailbox(store: deviceCatalogue)

    /// "Reset all settings" rewrites every preference at once, and three
    /// things hold their own copy of one: the shelf store its items, the
    /// timer provider its recents, the provider hub its running set. Left
    /// alone, each wrote the old value straight back on its next change.
    /// A fresh grant must reach the providers that were waiting on it: the
    /// calendar provider had scheduled its next look hours out, the proximity
    /// scanner had declined to start, the weather had fallen back to the typed
    /// city. Restart every provider gated on this permission so the card
    /// appears now, not at the next scheduled evaluation. Reached both from a
    /// request that answered synchronously and from the asynchronous
    /// authorization callbacks (Location answers after the prompt closes).
    /// The permission state as of the last reading, so the next one can tell
    /// what moved. Only the usability matters, but the status is kept whole
    /// for the log line.
    private var lastPermissionSnapshot: [PermissionKind: PermissionStatus] = [:]

    /// The same reading in the shape the settings pane draws.
    private var lastPermissionRows: [PermissionRow] = []

    /// Re-reads every permission and acts on whatever changed.
    ///
    /// Called on waking and on becoming active — the two moments a user can
    /// have been in System Settings since we last looked. Not a poll: TCC
    /// broadcasts nothing, and asking on a timer would spend the whole day
    /// checking for something that happens once a year.
    private func revalidatePermissions() {
        let rows = permissions.snapshot()
        let fresh = Dictionary(uniqueKeysWithValues: rows.map { ($0.kind, $0.status) })
        let changes = PermissionDiff.changes(from: lastPermissionSnapshot, to: fresh)
        lastPermissionSnapshot = fresh
        lastPermissionRows = rows
        guard !changes.isEmpty else { return refreshSettingsModel() }

        for change in changes {
            if change.isGain {
                Self.log.notice("permission gained: \(change.kind.rawValue, privacy: .public)")
                permissionGranted(change.kind)
            } else {
                Self.log.notice("permission lost: \(change.kind.rawValue, privacy: .public)")
                permissionLost(change.kind)
            }
        }
        refreshSettingsModel()
    }

    /// A permission was taken away while the app was running.
    ///
    /// Required providers stop; optional providers adopt their fallbacks.
    /// Accessibility is the one with a second
    /// casualty: the system has already killed the event tap, so the HUD
    /// coordinator has to be told it is no longer suppressing anything, or it
    /// would sit believing it owned a readout it had lost.
    private func permissionLost(_ kind: PermissionKind) {
        activities.permissionChanged(kind, isGranted: false)
        if kind == .accessibility { hud.revalidateTrust() }
        if kind == .focusStatus { syncFocusQuietState() }
    }

    /// Re-reads whether a Focus is on, rather than waiting to be told.
    ///
    /// The quiet-during-Focus rule follows the source's change callback, and a
    /// change is only announced when the source's own idea of the answer
    /// moves. Around a permission being granted it does not: starting the card
    /// makes the shared source take its first reading silently — that priming
    /// is deliberate, so a Focus already on at launch is a baseline rather
    /// than news — and the refresh that follows then finds nothing changed and
    /// announces nothing. The rule was left believing no Focus was on while
    /// one was.
    ///
    /// So at the moments where the source may have learned something without
    /// saying so, the coordinator asks.
    private func syncFocusQuietState() {
        focusBaseline?.refresh()
        focusModeActive = focusBaseline?.current() != nil
    }

    private func permissionGranted(_ kind: PermissionKind) {
        if kind == .automation { ScriptingNowPlayingSource.forgetDenials() }
        // A gained grant needs re-deciding exactly as much as a lost one. Only
        // the loss did this, so Accessibility granted while the app ran left
        // the tap unstarted until the next launch — with the settings switch
        // saying it was suppressing the whole time.
        if kind == .accessibility { hud.revalidateTrust() }
        activities.permissionChanged(kind, isGranted: true)
        if kind == .focusStatus { syncFocusQuietState() }
        refreshSettingsModel()
        raiseAfterGrant(for: kind)
    }

    /// Brings the settings window back after the user has granted something.
    ///
    /// The grant happens in System Settings, which opens *over* Ledge's
    /// window, and Ledge is an accessory app: once it is behind something
    /// there is no Dock icon and no Cmd-Tab entry to get back to it, so the
    /// window had to be hunted for among everything else on screen. Only when
    /// the window was already open — a grant made from the tour, or from
    /// System Settings with nothing of ours on screen, moves nothing.
    /// - Parameter kind: the permission whose answer arrived, or nil when the
    ///   caller is the watch for the press itself. Checked against the press
    ///   that is outstanding: a Calendar grant landing while somebody is in
    ///   System Settings over *Bluetooth* is not a reason to take the
    ///   foreground away from them — and a permission can appear to flap
    ///   several times a minute.
    private func raiseAfterGrant(for kind: PermissionKind? = nil) {
        // Only while the user is out granting something they asked for from
        // this window. Any gain at all used to bring the window forward, and
        // since a permission could appear to flap several times a minute, the
        // app repeatedly stole focus from whatever the user was doing —
        // including from System Settings, where they were trying to grant.
        guard permissionWatch != nil else { return }
        guard let open = attempt else { return }
        if let kind, kind != open.kind { return }
        // Whichever window asked. The tour is the one that cannot be found
        // again: it was lowered to stand aside for System Settings, and
        // nothing but an activation floats it back.
        switch open.who {
        case .tour where onboarding.isVisible:
            onboarding.raise()
        case .settings, .tour, nil:
            guard let settingsWindow, settingsWindow.isVisible else {
                // The tour is the only other window that asks, so it is the
                // fallback when Settings is not up.
                if onboarding.isVisible { onboarding.raise() }
                return
            }
            present(settingsWindow)
        }
    }

    /// Gets Ledge's own windows out of the way of a system dialog.
    ///
    /// Both the tour and the settings window float, so they cannot be lost
    /// behind other applications. The exception is the moment they send the
    /// user to a permission prompt or to System Settings: a floating window
    /// covers the dialog it just asked for, and the user sees a button that
    /// does nothing. They come back up when the user comes back to Ledge.
    private func standAsideForSystemUI() {
        settingsWindow?.level = .normal
        onboarding.setFloating(false)
    }

    private func reclaimFront() {
        if settingsWindow?.isVisible == true { settingsWindow?.level = .floating }
        onboarding.setFloating(true)
    }

    /// How long to keep looking for a permission the user was just sent to
    /// System Settings to grant.
    private static let permissionWatchWindow: TimeInterval = 240

    /// Watches for the answer while the user is away in System Settings.
    ///
    /// TCC broadcasts nothing, so without this the grant is only noticed when
    /// Ledge next becomes active — which is the very thing the user cannot do
    /// without first finding the window. Bounded, and only ever running while
    /// a request the user made is outstanding and the settings window is up.
    /// Watches for an answer that arrives somewhere else.
    ///
    /// - Parameter onEnd: called however the watch ends — an answer, the
    ///   window closing, or the four minutes running out. Whatever the row
    ///   was saying while it waited stops being true at all three.
    private func watchForPermission(
        _ kind: PermissionKind,
        onEnd: (@MainActor () -> Void)? = nil
    ) {
        stopWatchingForPermission()
        permissionWatchEnd = onEnd
        let before = permissions.status(of: kind)
        // Automation is read by sending an Apple Event to a player, so it is
        // asked for less often than the rest, which are local reads.
        let interval: TimeInterval = kind == .automation ? 2 : 1
        permissionWatch = Task { @MainActor [weak self] in
            // Whichever way this ends — an answer, the window closing, the
            // four minutes running out — the watch stops being "the user is
            // out granting something". It is what `raiseAfterGrant`
            // reads, so a watch left standing meant a grant made an hour later
            // for some other reason could pull the settings window in front of
            // whatever the user was doing.
            defer {
                if !Task.isCancelled {
                    self?.permissionWatch = nil
                    self?.permissionWatchEnd = nil
                    onEnd?()
                }
            }
            for _ in 0..<Int(Self.permissionWatchWindow / interval) {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                guard self.settingsWindow?.isVisible == true || self.onboarding.isVisible else { return }
                guard self.permissions.status(of: kind) != before else { continue }
                self.revalidatePermissions()
                self.sayTheAnswerArrived(for: kind)
                self.raiseAfterGrant(for: kind)
                return
            }
        }
    }

    /// A press is waiting for an answer. Returns the token that owns it.
    ///
    /// - Parameter handingOff: whether the answer happens in another
    ///   application. Only then does the notch pick up the thread.
    @discardableResult
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
            guideShows: settingsModel.handoff?.kind
        )
        if let ending = change.endWaitFor { settingsModel.endedWaiting(for: ending) }
        if change.clearsTheLock { handoffCard.clear() }
        if change.endsTheGuide { settingsModel.endedHandoff() }
        let started = PermissionAttempt(
            kind: kind,
            who: handingOff ? (onboarding.isVisible ? .tour : .settings) : nil
        )
        attempt = started
        if handingOff {
            handoffCard.waiting(for: kind.displayName)
            // macOS shows its one-time Accessibility message at most once in
            // an app's life and says nothing about having done so, so the
            // fact that it can still appear is written down here, at the one
            // press that can raise it.
            if kind == .accessibility, !preferences.accessibilityWasAsked {
                preferences.accessibilityWasAsked = true
                settingsModel.accessibilityWasAskedBefore = true
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
        settingsModel.endedWaiting(for: open.kind)
        if open.who != nil {
            handoffCard.clear()
            settingsModel.endedHandoff()
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
        guard permissions.status(of: kind) == .granted else { return }
        handoffCard.arrived(
            kind.displayName,
            detail: PermissionGuideCopy.arrivedDetail(kind),
            holding: PermissionGuideCopy.arrivalHold(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        )
    }

    /// Ends the standing watch and tells whoever started it that it is over.
    ///
    /// The row that waits has to stop waiting on every ending, including the
    /// ones it did not cause: a second permission asked for while the first
    /// is still out replaces the watch, and Ledge going away takes it with it.
    private func stopWatchingForPermission() {
        let end = permissionWatchEnd
        permissionWatchEnd = nil
        permissionWatch?.cancel()
        permissionWatch = nil
        end?()
    }

    /// Which card-switch request is the newest.
    /// The journal's one writer, outliving every provider over it.
    private let keepAwakeJournal = KeepAwakeJournalWorker(FileKeepAwakeJournal())

    /// The lid-closed hold.
    ///
    /// A seam, and for now an honest refusal: nothing here registers a
    /// privileged daemon, so until the installation path exists this reports
    /// what is true — the helper is not set up, or this build could never set
    /// it up — and the card says so in words instead of offering a mode that
    /// cannot start. Swapping in the real `KeepAwakeHelperLid` is the whole of
    /// what has to change here when it does.
    /// The lid-closed hold, over XPC to the root daemon when this build can
    /// have one.
    ///
    /// `fromBundle` answers nil for a build with no requirement recorded in its
    /// Info.plist, which is what an ad-hoc signed local build is: no
    /// requirement could match an unsigned chain, so the packaging script
    /// leaves the key out rather than writing one that never will. There is
    /// then nothing to connect to, and the unavailable stand-in says so in a
    /// sentence instead of offering a hold that could not be taken.
    /// The one connection to the daemon, or nil for a build that can have none.
    ///
    /// One client, not two. The hold and Low Power Mode are the same lease
    /// under the same generation — the daemon refuses a Low Power Mode request
    /// from a session that is not the one holding this Mac — so a second
    /// client with its own session and its own generation counter would be
    /// refused every time it asked.
    private lazy var keepAwakeHelperClient: KeepAwakeHelperClient? = {
        guard let link = KeepAwakeXPCLink.fromBundle() else { return nil }
        return KeepAwakeHelperClient(link: link)
    }()

    private lazy var keepAwakeLid: any KeepAwakeLidHolding = {
        guard let client = keepAwakeHelperClient else {
            return KeepAwakeLidUnavailable(KeepAwakeHelperInstall.current())
        }
        return KeepAwakeHelperLid(
            client: client,
            installation: { KeepAwakeHelperInstall.current() }
        )
    }()

    /// Everything a shut lid is supposed to save, and the journal that puts it
    /// all back.
    ///
    /// One instance for the app, not one per provider. The record it owns
    /// outlives any provider — a session switched off and on again builds a
    /// new one while the old one's restore may still be landing — and two of
    /// these over the same file would each think the other's entries were
    /// leftovers to clean up.
    ///
    /// The keyboard backlight is behind its own gate, so this is the real one
    /// on every Mac and the gate decides whether it does anything. Low Power
    /// Mode goes through the daemon when there is one, and a Mac with no
    /// daemon installed gets every other saving and an honest refusal for
    /// that one — the setting is root, and claiming a change it never made
    /// would be worse than not making it.
    /// Turning App Nap off for the roster while a lid-closed session runs.
    ///
    /// Both the switch and the roster are read at the moment of use rather
    /// than captured, so a user who changes either mid-session gets what they
    /// asked for without restarting one.
    private lazy var keepAwakeAppNap: AppNapSuspending = {
        let preferences = self.preferences
        return RosterAppNap(
            suspension: AppNapSuspension(
                journal: FileAppNapJournal(
                    url: FileKeepAwakeJournal.defaultDirectory()
                        .appendingPathComponent("app-nap.json", isDirectory: false)
                )
            ),
            wanted: { preferences.keepAwakeDisableAppNap },
            roster: { preferences.agentRoster }
        )
    }()

    /// Low Power Mode, held separately so a quit can join its outstanding
    /// request. A Mac left throttled because the app exited before the daemon
    /// heard "give it back" is a Mac running slower than its owner asked for,
    /// with nothing on screen to explain it.
    private lazy var lidLowPower: HelperLowPowerMode? =
        keepAwakeHelperClient.map(HelperLowPowerMode.init(client:))

    private lazy var lidConserve: LidConserveDriver = {
        let lowPower: any LowPowerModeControl = lidLowPower ?? UnprivilegedLowPowerMode()
        return LidConserveDriver(
            sensor: ClamshellSensor(),
            conserver: LidConserver(
                journal: FileLidConserveJournal(),
                panel: PanelBacklight(controller: BrightnessController()),
                keyboard: CoreBrightnessKeyboardBacklight(),
                audio: CoreAudioLidOutput(),
                lowPower: lowPower
            )
        )
    }()

    /// The menu-bar item a live lid-closed hold puts up, and the only way to
    /// end one when the lid is shut and the notch is on a panel that is off.
    private lazy var keepAwakeLidItem = KeepAwakeLidStatusItem(end: { [weak self] in
        guard let self else { return }
        Task { @MainActor in await self.endKeepAwake(reason: .endedByYou) }
    })

    /// Keeps the Keep Awake switch's answers in the order they were given.
    private lazy var keepAwakeToggle = KeepAwakeToggle(
        end: { [weak self] in await self?.endKeepAwake(reason: .turnedOff) },
        apply: { [weak self] enabled in
            guard let self else { return }
            self.activities.setProvider("keep-awake", enabled: enabled)
            self.refreshSettingsModel()
        }
    )

    /// What the Keep Awake card's buttons actually do.
    ///
    /// Without this the card drew Start, End, Resume and Done over the default
    /// empty closures, so every one of them was a no-op in the shipping app
    /// while the tests that drove the provider directly all passed.
    private func makeKeepAwakeActions() -> KeepAwakeActions {
        KeepAwakeActions(
            switchOn: { [weak self] in
                guard let self else { return }
                // Nothing starts while the helper is being taken out. The
                // removal asks the daemon whether it still owes the Mac
                // anything, and a session admitted during that question
                // would be a session whose lid hold is about to be removed
                // from under it.
                guard self.mayStartKeepAwake else { return }
                Task { @MainActor in await self.keepAwake?.begin() }
            },
            retryLid: { [weak self] in
                guard let self else { return }
                guard self.mayStartKeepAwake else { return }
                Task { @MainActor in await self.keepAwake?.retryLidHold() }
            },
            dropLidHold: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    // One operation, not end-then-begin. The provider swaps
                    // the session without ever releasing the assertion, so a
                    // slow disk cannot leave the Mac unprotected and a refusal
                    // leaves the hold that was running exactly where it was.
                    //
                    // Not gated: this one gives the helper's claim *back*,
                    // which is the direction a removal wants anyway.
                    await self.keepAwake?.changeMode(toLidClosed: nil)
                }
            },
            startLidClosed: { [weak self] minutes in
                guard let self else { return }
                guard self.mayStartKeepAwake else { return }
                self.preferences.keepAwakeDefaultMinutes = Double(minutes)
                Task { @MainActor in
                    guard let provider = self.keepAwake else { return }
                    // Switching the lid mode on while the Mac is already being
                    // held is the ordinary sequence the two-switch card
                    // invites, and `begin` refuses it outright — its guard
                    // wants Ready. The length question opened, took an answer,
                    // and the answer went nowhere.
                    if await provider.changeMode(toLidClosed: minutes) == .nothingRunning {
                        await provider.begin(minutes: minutes, lidClosed: true)
                    }
                }
            },
            refreshLid: { [weak self] in
                guard let self else { return nil }
                await self.keepAwake?.refreshLid()
                return self.keepAwake?.lidReading
            },
            end: { [weak self] in
                guard let self else { return }
                Task { @MainActor in await self.keepAwake?.end(reason: .endedByYou) }
            },
            dismiss: { [weak self] in self?.keepAwake?.dismiss() },
            resume: { [weak self] in
                guard let self else { return }
                guard self.mayStartKeepAwake else { return }
                Task { @MainActor in await self.keepAwake?.resume() }
            },
            haptic: {
                NSHapticFeedbackManager.defaultPerformer.perform(
                    .alignment, performanceTime: .drawCompleted
                )
            },
            setDragging: { [weak self] dragging in self?.setHUDDragging(dragging) }
        )
    }

    private func handlePreferencesReset() {
        shelf.reload()
        timerProviderRef?.replaceRecents(TimerProvider.decodeRecents(preferences.timerRecents))
        // The reconcile is what tears the provider down, so the end has to be
        // awaited before it rather than merely started alongside it: posting
        // the end and reconciling in the same turn let the removal win, and a
        // reset then left a session on disk that the next launch resumed.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.endKeepAwake(reason: .turnedOff)
            self.activities.reconcileWithPreferences()
            self.refreshSettingsModel()
        }
    }

    private func setScreensDark(_ reason: ScreenDormancy.Reason, _ active: Bool) {
        guard dormancy.set(reason, active) else { return }
        presentation.screensAreDark = dormancy.isDark
        if dormancy.isDark {
            notesWindow.cancelPendingOpening()
            hoverTracker?.stop()
            hud.setDormant(true)
            Self.log.notice("screens dark — pointer and brightness polling paused")
        } else {
            hoverTracker?.start()
            hud.setDormant(false)
            // The pointer may be anywhere now; forget the pre-sleep answer —
            // and tell the reducer, or a card left open under the pointer at
            // lock time stays open until the pointer re-enters and leaves.
            let key = currentDisplayUnderCursor()
            hoverTracker?.resync(to: key)
            if state.isHovering != (key != nil) { send(.hoverChanged(key != nil)) }
            Self.log.notice("screens lit — polling resumed")
        }
    }

    private lazy var activities = ActivityCoordinator(
        presentation: presentation,
        preferences: preferences,
        // A provider whose permission is refused waits rather than starting
        // and polling something that will never answer.
        isPermitted: { [weak self] kind in self?.permissions.status(of: kind) == .granted }
    )
    private lazy var gestures = GestureMonitor(
        threshold: preferences.swipeThreshold,
        isNatural: preferences.naturalSwipe
    )

    private let artworkLoader = ArtworkLoader()

    /// Files parked in the notch. Owned here rather than by the provider so the
    /// drop handler keeps working while the provider is switched off.
    private lazy var shelf = ShelfStore(
        load: { [weak self] in self?.preferences.shelfPaths ?? "" },
        save: { [weak self] paths in self?.preferences.shelfPaths = paths }
    )
    /// The user's notes. Owned here, not by the provider, so the editor window
    /// keeps working while the card is switched off — the same reason the shelf
    /// store lives here.
    private let notes = NotesStore()

    /// The one editor window.
    private lazy var notesWindow = NotesWindowController(
        store: notes,
        preferences: preferences
    )

    /// Held so the card can be told which note is being written.
    private weak var notesProviderRef: NotesProvider?
    private weak var levelsProviderRef: LevelsProvider?
    /// Held so Ledge's own camera use can be kept out of its own privacy card.
    private weak var privacyProviderRef: PrivacyProvider?

    /// The calendar card's self-view: the camera, its deadlines, and the
    /// payload the card draws.
    private lazy var selfView = SelfViewRunner(
        camera: SelfViewCamera(),
        publish: { [weak self] payload in
            guard let self else { return }
            self.presentation.selfView = payload
            self.keepSelfViewTicking(payload.phase != .off)
        },
        holdChanged: { [weak self] holding in
            self?.send(.cardHoldChanged(holding))
        },
        cameraUseChanged: { [weak self] running, device in
            self?.privacyProviderRef?.selfViewChanged(running, device: device)
        },
        openCameraSettings: {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
    )

    /// The self-view's clock: elapsed time, not civil time.
    ///
    /// Every deadline on that card — six tenths of a second of patience, five
    /// seconds before giving up, a minute away, five minutes in all — is a
    /// length of time rather than a moment, and `Date` can move backwards
    /// under all four of them.
    private static func selfViewClock() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Drives the self-view's deadlines while a session is alive.
    ///
    /// Four times a second, and only then: the patience before a sentence,
    /// the five seconds before giving up, the minute away and the five-minute
    /// cap are all read from the same instant, and nothing moves on screen
    /// unless one of those answers actually changed.
    private var selfViewTicker: Task<Void, Never>?

    private func keepSelfViewTicking(_ wanted: Bool) {
        guard wanted else {
            selfViewTicker?.cancel()
            selfViewTicker = nil
            return
        }
        guard selfViewTicker == nil else { return }
        selfViewTicker = Task { @MainActor [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                // Once a second while the picture is up, ask the privacy card
                // to look again. Another application taking the camera Ledge
                // already has open changes nothing the watcher can see — the
                // device was running either way — so without this the card
                // would wait on a sixty-second safety poll to notice.
                ticks += 1
                if ticks % 4 == 0, self.selfView.phase.isRunningCamera {
                    self.privacyProviderRef?.recheck()
                }
                // The card itself may have gone while a readout stood over
                // it — the one case the `.hud` guard on `cardWentAway` lets
                // through, because from the view's side a temporary
                // occlusion and a real dismissal look the same. The camera
                // belongs to the calendar card; if that is not what is
                // selected any more, it goes.
                guard self.selfViewIsStillEarned else {
                    self.selfView.cardWentAway()
                    return
                }
                self.selfView.tick(now: Self.selfViewClock())
            }
        }
    }

    /// Whether the camera still has a card to live in.
    ///
    /// Two questions, and the shell is the only layer that can answer either
    /// while a readout is standing over the calendar: is the calendar still
    /// the selected card, and does it still have a meeting to join? Without
    /// the second, a meeting that ended behind a volume readout handed the
    /// card back with a live picture and no segment to close it with.
    private var selfViewIsStillEarned: Bool {
        guard let selected = presentation.selected,
              case .event(let payload) = selected.payload
        else { return false }
        return payload.joinLink != nil
    }

    private func makeSelfViewActions() -> SelfViewActions {
        SelfViewActions(
            press: { [weak self] in
                self?.selfView.press(now: Self.selfViewClock())
            },
            openSettings: { [weak self] in self?.selfView.openSettings() },
            tryAgain: { [weak self] in
                self?.selfView.tryAgain(now: Self.selfViewClock())
            },
            cardWentAway: { [weak self] in
                guard let self else { return }
                // A volume key takes the calendar off screen for as long as
                // the readout is up, and the reducer promises to hand the
                // card back afterwards with the camera still on. The view's
                // own "I disappeared" cannot tell that apart from being
                // swiped away — this can.
                guard self.state.phase != .hud else { return }
                self.selfView.cardWentAway()
            },
            letGo: { [weak self] in self?.selfView.letGo() },
            picture: { [weak self] in
                AnyView(CameraLayerView(
                    sessionID: self?.selfView.sessionID ?? 0,
                    make: { self?.selfView.makePreviewLayer() }
                ))
            }
        )
    }

    private let screenshots = ScreenshotWatcher()
    private lazy var permissions = PermissionCenter(preferences: preferences)
    private let settingsModel = SettingsModel()
    /// Transport control, told where the system is actually pointing.
    ///
    /// A command with no address — the only kind a player without a scripting
    /// dictionary can be sent — goes to whichever player the system considers
    /// now-playing, which is not always the one on the card. The commander
    /// refuses rather than guesses, and this is what it asks.
    private lazy var commander = NowPlayingCommander(
        systemOwner: { [weak self] in self?.systemMediaOwner }
    )

    /// Which player the system itself says is playing, raw. Only the composite
    /// source can answer: the AppleScript-only path sees Music and Spotify,
    /// both of which take addressed commands and never reach the unaddressed
    /// one.
    private var systemMediaOwner: String? {
        (resolvedNowPlayingSource as? CompositeNowPlayingSource)?.systemOwnerBundleID
    }
    private lazy var hud = HUDCoordinator(
        preferences: preferences,
        presentation: presentation,
        hasNotchPanel: { [weak self] in
            guard let self else { return false }
            return !self.displayPanels.order.isEmpty
        }
    )

    /// Which player the transport buttons talk to.
    ///
    /// Derived from whatever is on the card rather than stored, so the buttons
    /// always act on what the user can actually see — the activity's source key
    /// is the player's bundle id.
    private var activeMediaBundleID: String? {
        guard let selected = presentation.selected, selected.kind == .nowPlaying else { return nil }
        return selected.id.source
    }

    public init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// Opens a note on its own a few seconds after launch, when asked to.
    ///
    /// Diagnostics only, behind `~/.ledge-notes-selftest`. An animation that
    /// plays for half a second inside a notch cannot be checked by reasoning
    /// about it, and this is the only way to drive it without a hand on the
    /// trackpad.
    private var notesSelfTest: Task<Void, Never>?

    private func runNotesSelfTestIfRequested() {
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".ledge-notes-selftest")
        guard FileManager.default.fileExists(atPath: marker) else { return }
        notesSelfTest?.cancel()
        // A note id written into the marker opens that note instead of making a
        // new one. An empty document and one with text are different cases —
        // the caret's height comes from the line it sits on, and an empty one
        // has no line.
        let wanted = (try? String(contentsOfFile: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        notesSelfTest = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            if let wanted, !wanted.isEmpty {
                Task { @MainActor in await self?.notesWindow.open(noteID: wanted) }
            } else {
                self?.notesWindow.create()
            }
            // Twice, with a close in between: the first flight and every later
            // one are different events — the window, its hosting view and the
            // text system all come into being during the first — and telling
            // them apart is most of what this is for.
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.notesWindow.close()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.notesWindow.create()
        }
    }

    public func start() {
        // Out of the way of launch, and well before anybody can click a tile.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            self?.notesWindow.warmUp()
        }
        // Blank notes left behind by a quit, a crash or a kill while one was
        // open. Closing a window discards its note if it is empty, but nothing
        // closes a window when the process dies under it.
        Task { [notes] in await notes.discardEmpties() }
        runNotesSelfTestIfRequested()
        presentation.audioLevels = { [weak self] in self?.simulatedLevels() ?? [] }
        displayPanels.reconcile()
        pruneHoveredDisplay()
        // Every later reconcile (hot-plug, wake, resolution change) must
        // prune too: a hover owner that just unplugged left every surviving
        // panel demoting its drawn phase and the sticky hit test with a dead
        // key — an open card nobody could see or click.
        // Where a note goes: beside the island it was asked for, on the screen
        // that island is on. Wired here rather than inside the notes provider's
        // factory — that closure only runs if the card is switched on and
        // built, and a note can be opened regardless.
        notesWindow.notchScreen = { [weak self] in self?.notesPanel?.currentScreen }
        notesWindow.sourceIsland = { [weak self] in
            guard let self, let panel = self.notesPanel else { return nil }
            return panel.shapeRect(for: self.presentation.phase)
        }
        notesWindow.displayScale = { [weak self] in self?.notesPanel?.geometry.displayScale ?? 1 }

        displayPanels.onPanelsChanged = { [weak self] in
            guard let self else { return }
            self.pruneHoveredDisplay()
            self.notesWindow.finishBirthAfterDisplayChange()
            // Whether there is a notch to draw the HUD in is the question
            // `hud.apply()` asks first, and closing the lid or unplugging the
            // built-in display changes the answer. Without this the keys stay
            // swallowed on a Mac that no longer has anywhere to show them.
            self.hud.apply()
        }

        let geometry = displayPanels.primary?.geometry
            ?? NSScreen.main.map(ScreenGeometry.measure)
            ?? .simulated(screenSize: CGSize(width: 1470, height: 956))
        Self.log.notice("""
            geometry: screen=\(geometry.screenSize.width, privacy: .public)×\
            \(geometry.screenSize.height, privacy: .public) \
            notch=\(geometry.notchSize.width, privacy: .public)×\
            \(geometry.notchSize.height, privacy: .public) \
            centreX=\(geometry.notchCenterX, privacy: .public) \
            hardware=\(geometry.isHardwareNotch, privacy: .public) \
            scale=\(geometry.displayScale, privacy: .public)
            """)

        effects.onTimer = { [weak self] timer in self?.send(.timerFired(timer)) }
        activities.setPinnedKind(ActivityKind(rawValue: preferences.pinnedCard))
        observePinnedCard()
        NotchLayout.setEarWidth(preferences.earWidth)
        observeEarWidth()
        // Seeded before the observation arms: it starts as "" and the first
        // unrelated interaction-pref change would otherwise read "Berlin" != ""
        // and needlessly restart the weather provider, discarding a valid
        // reading.
        observedWeatherCity = preferences.weatherCity

        // A Focus already on at launch must count: the provider announces
        // only *changes* and baselines silently, so a user who enabled Do Not
        // Disturb before starting Ledge was peeked at like anyone else.
        // Same source the provider uses, so the baseline is right whether the
        // database is readable or only the system's on/off answer is.
        // Before anything reads the Focus database: the folder the user gave
        // is only readable while its scope is held open.
        focusFolder.restore()
        focusBaseline = SystemFocusSource()
        focusBaseline?.startWatching { [weak self] in
            guard let self else { return }
            self.focusModeActive = self.focusBaseline?.current() != nil
        }
        focusModeActive = focusBaseline?.current() != nil

        applyScreenshotWatching()
        observeScreenshotPreference()
        startActivities()
        startHUD()
        startGestures()
        applyDebugOverrides()
        startHoverTracking()
        observeSystemChanges()
        introduceIfNeeded()
        sayHello()
    }

    /// The first launch always leaves the user with a window in front of them.
    ///
    /// Normally that is the tour. But someone whose onboarding flag is already
    /// set — an upgrade, a reinstall, a copy carried over from another Mac —
    /// gets no tour, and Ledge is an accessory app: no Dock icon, no window,
    /// nothing in the Cmd-Tab list. That launch is indistinguishable from one
    /// that failed, and was read as exactly that. Settings stands in, once.
    private func introduceIfNeeded() {
        // Development launches open Settings themselves and must not consume
        // the one introduction the real first launch is owed.
        guard !DebugSwitches.isOn("LEDGE_DEBUG") else {
            onboarding.showIfNeeded(hasCompletedOnboarding: preferences.hasCompletedOnboarding)
            return
        }
        let tourShown = onboarding.showIfNeeded(
            hasCompletedOnboarding: preferences.hasCompletedOnboarding
        )
        guard !preferences.hasBeenIntroduced else { return }
        preferences.hasBeenIntroduced = true
        guard !tourShown else { return }
        Self.log.notice("first launch without the tour — opening Settings instead")
        showSettings()
    }

    /// How long the eyes are on screen: exactly as long as their own
    /// performance says it needs, so re-timing the animation never leaves the
    /// island closing over it or waiting after it.
    private static var greetingDuration: TimeInterval { GreetingState.duration }

    /// Opens the notch on a pair of blinking eyes when Ledge starts.
    ///
    /// A peek, because that is already the phase for "the notch has something
    /// to say and will stop saying it shortly" — it opens the island at its
    /// compact size and closes itself on a timer. The eyes are drawn instead
    /// of the ears' usual contents for as long as the flag is up.
    private func sayHello() {
        Self.log.notice("greeting: opening (\(Self.greetingDuration, format: .fixed(precision: 2), privacy: .public)s)")
        presentation.greeting = true
        send(.peekRequested(Self.greetingDuration))
        greeting = Task { @MainActor [weak self] in
            // A beat past the performance. The eyes' last movement fades them
            // out; clearing the flag on the same frame put the resting content
            // up while they were still going, which is the hand-over reading
            // as a swap rather than as one thing giving way to another.
            try? await Task.sleep(for: .seconds(Self.greetingDuration + 0.18))
            guard let self, !Task.isCancelled else { return }
            self.presentation.greeting = false
            self.greeting = nil
            Self.log.notice("greeting: done")
        }
    }

    private var greeting: Task<Void, Never>?

    /// Builds one display's panel. Every panel shares the same presentation and
    /// the same callbacks — one brain, N windows.
    private func makePanelController(
        _ id: CGDirectDisplayID,
        _ screen: NSScreen
    ) -> LedgePanelController {
        let controller = LedgePanelController(
            displayID: id,
            screen: screen,
            preferences: preferences,
            presentation: presentation,
            onTap: { [weak self] in
                guard let self else { return }
                // While the notch is holding the lock for a handoff, a click
                // on it is the way back to the window that asked — which an
                // accessory app otherwise has no way of offering, having
                // neither a Dock icon nor a Cmd-Tab entry. Narrow on purpose:
                // only while a watch is actually running, and only when the
                // card under the pointer is that one.
                // Only in the phases that actually draw the resting content.
                // "Not open" is not the same thing: a peek draws what it is
                // announcing and a readout draws the HUD, and in both the
                // lock is merely what is underneath.
                let restIsOnScreen = self.state.phase == .idle || self.state.phase == .companion
                if self.permissionWatch != nil,
                   restIsOnScreen,
                   self.restingContent()?.id == HandoffProvider.waitingID {
                    self.raiseAfterGrant()
                    return
                }
                self.send(.clicked)
            },
            nowPlayingActions: makeNowPlayingActions(),
            timerActions: makeTimerActions(),
            keepAwakeActions: makeKeepAwakeActions(),
            shelfActions: makeShelfActions(),
            notesActions: makeNotesActions(),
            levelsActions: makeLevelsActions(),
            selfViewActions: makeSelfViewActions(),
            onDropFiles: { [weak self] urls in self?.acceptDroppedFiles(urls) ?? false },
            onHUDAdjust: { [weak self] kind, level in self?.hud.adjust(kind, to: level) },
            onHUDAdjustDisplay: { [weak self] id, level in
                self?.hud.adjustBrightness(of: id, to: level)
                // The row that moved is not the only thing on screen: redraw the
                // list so its bar tracks the drag.
                self?.presentation.hudDisplays = self?.hud.brightnessDisplays() ?? []
            },
            onHUDDragging: { [weak self] dragging in self?.setHUDDragging(dragging) }
        )
        return controller
    }

    private func applyScreenshotWatching() {
        if preferences.shelfAutoScreenshots {
            screenshots.startWatching { [weak self] url in
                guard let self else { return }
                // On a clock, unlike a file the user dropped: Ledge put this
                // here on their behalf and should tidy up after itself.
                guard self.shelf.add([url], expiresAfter: ShelfStore.screenshotLifetime) > 0 else {
                    return
                }
                // And say so. A screenshot that lands in the notch without a
                // word is indistinguishable from one that went only to the
                // desktop, which makes the feature invisible to the person it
                // is for.
                self.announceShelf()
            }
        } else {
            screenshots.stopWatching()
        }
    }

    private func observeScreenshotPreference() {
        withObservationTracking {
            _ = preferences.shelfAutoScreenshots
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyScreenshotWatching()
                self?.observeScreenshotPreference()
            }
        }
    }

    private func observePinnedCard() {
        withObservationTracking {
            _ = preferences.pinnedCard
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.activities.setPinnedKind(ActivityKind(rawValue: self.preferences.pinnedCard))
                self.observePinnedCard()
            }
        }
    }

    // MARK: - Onboarding

    /// The public repository — the tour's "read the code" and About's link.
    static let sourceURL = URL(string: "https://github.com/egemertbalcik/Ledge")!

    /// The window is the presenter's; what finishing *means* is the
    /// coordinator's, because permissions, providers and the welcome card are
    /// things only this knows about.
    private lazy var onboarding = OnboardingPresenter(
        makeView: { [weak self] finish in
            guard let self else {
                return OnboardingView(model: SettingsModel(), actions: SettingsActions(
                    setLaunchAtLogin: { _ in false }, loginItemStatus: { "" },
                    copyToClipboard: { _ in }, quit: {}
                ), openSettings: {}, openSource: {}, finish: finish)
            }
            self.refreshSettingsModel()
            let isReturnVisit = self.preferences.hasCompletedOnboarding
            return OnboardingView(
                model: self.settingsModel,
                actions: self.makeSettingsActions(),
                openSettings: { [weak self] in self?.showSettings() },
                openSource: { NSWorkspace.shared.open(Self.sourceURL) },
                finish: finish,
                openCards: { [weak self] in self?.showSettings(pane: "cards") },
                // A second visit is a reference: the steps become tabs,
                // nothing is written down, and nothing waits.
                isReturnVisit: isReturnVisit,
                // Read only while a first tour is unfinished, which now means
                // Ledge itself stopped during it — a crash, a force quit, or
                // Quit Ledge from the terminal banner. A tour somebody closed
                // is finished, so it never comes back here.
                startStep: isReturnVisit
                    ? .hover
                    : TourStep(rawValue: Int(self.preferences.tourPage)) ?? .hover,
                hasBuiltInNotch: Self.theScreenHasANotch()
            )
        },
        place: { window in
            guard let screen = ScreenGeometry.preferredScreen() else {
                window.center()
                return
            }
            OnboardingPresenter.hangUnderTheNotch(
                window,
                on: screen,
                notchCenterX: ScreenGeometry.measure(screen).notchCenterX
            )
        },
        title: { [weak self] in
            self?.preferences.hasCompletedOnboarding == true ? TourCopy.titleAgain : TourCopy.title
        },
        onFinish: { [weak self] in self?.onboardingFinished() }
    )

    /// Whether this Mac has a notch of its own, for the one sentence that
    /// changes if it does not.
    private static func theScreenHasANotch() -> Bool {
        guard let screen = ScreenGeometry.preferredScreen() else { return true }
        return ScreenGeometry.measure(screen).isHardwareNotch
    }

    /// Presents the tour: at first launch, and again on request from Settings.
    public func showOnboarding() { onboarding.show() }

    /// The tour was answered — Done, or the close button, which is the same
    /// answer.
    ///
    /// Closing used to leave the flag alone, so the tour came back on every
    /// launch until somebody reached the end. That is nagging.
    ///
    /// The tour no longer opens the player gate either. Opening it here put
    /// the Automation dialog up a few seconds after the tour closed — at the
    /// next read of a player that was merely open — and at every later launch
    /// of somebody who had never been asked, with no button pressed and
    /// nothing on screen to explain it. Automation is asked for by its own
    /// button in the Permissions tab, which remembers the press (see
    /// `PermissionCenter.mayAskAboutPlayers`), so it is never shut for good
    /// and never asked for on its own.
    private func onboardingFinished() {
        let wasFirstRun = !preferences.hasCompletedOnboarding
        preferences.hasCompletedOnboarding = true
        preferences.tourPage = 0
        activities.startEnabled()
        if wasFirstRun { playWelcome() }
    }

    // MARK: - What the tour watches

    /// Who is listening for what the real notch does.
    ///
    /// Keyed, so a tour window closing takes only its own listener out — and
    /// so a second tour cannot leave the first one's closure behind to be
    /// called forever.
    private var tourListeners: [UUID: @MainActor (TourSignal) -> Void] = [:]

    /// Subscribes to what the notch does, and hands back the unsubscribe.
    private func observeNotch(
        _ listener: @escaping @MainActor (TourSignal) -> Void
    ) -> @MainActor () -> Void {
        let token = UUID()
        tourListeners[token] = listener
        return { [weak self] in self?.tourListeners.removeValue(forKey: token) }
    }

    /// The notch did something the tour may be waiting to see.
    private func tellTheTour(_ signal: TourSignal) {
        guard !tourListeners.isEmpty else { return }
        for listener in tourListeners.values { listener(signal) }
    }

    /// Which step of the tour is up, or nil once it is over.
    private func tourStepChanged(_ step: TourStep?) {
        // Only a first visit is worth remembering the place in, and only
        // because Ledge itself can stop during one. A second visit is a
        // lookup; writing a page number for it would bring somebody back to
        // step three the next time the app crashed.
        let isFirstTour = !preferences.hasCompletedOnboarding
        guard let step else {
            if isFirstTour { preferences.tourPage = 0 }
            return
        }
        if isFirstTour { preferences.tourPage = Double(step.rawValue) }
        // The notch's half of the step. Nothing to do for the others: the
        // drop step is taught by the drop itself, which enables the shelf and
        // announces what landed on it, and the last two steps are read.
        //
        // A first visit only. On a second the queue has the person's own
        // cards in it, and announcing "This is Ledge" over their music, to
        // somebody who opened the window to look one thing up, is the app
        // talking over itself.
        if step == .hover, isFirstTour { publishHelloCard() }
    }

    /// Gives the notch something to open while the Hover step is up.
    ///
    /// Load-bearing, not decoration: during a first tour no provider has been
    /// started yet, so the queue is empty and hovering the notch would open
    /// onto nothing — on the step whose whole job is to show that hovering
    /// opens it.
    private func publishHelloCard() {
        guard activities.activity(withID: ActivityID(kind: .message, source: "hello")) == nil else { return }
        publishTourCard(
            source: "hello",
            title: TourCopy.hello.title,
            body: TourCopy.hello.detail,
            symbol: "sparkles",
            // Long enough to read the step it belongs to, and short enough
            // that it is gone before somebody finishes the tour.
            seconds: 45
        )
    }

    /// Publishes one of the tour's own cards through the real path.
    ///
    /// A scenario provider rather than a card pushed straight into the
    /// presentation: the queue, the expiry and the ears are the things being
    /// demonstrated, so the demonstration goes through them. Adding a
    /// provider whose identifier is already registered replaces it — stopping
    /// the old one and retracting its card — so this is safe to call twice.
    private func publishTourCard(
        source: String,
        title: String,
        body: String,
        symbol: String,
        seconds: TimeInterval
    ) {
        let card = ScenarioActivity(
            kind: .message,
            source: source,
            expiresAfter: seconds,
            message: MessagePayload(title: title, body: body, symbolName: symbol)
        )
        activities.add(FakeActivityProvider(
            scenario: Scenario(name: source, steps: [Scenario.Step(at: 0.1, action: .publish(card))]),
            loops: false
        ))
        activities.start()
    }

    /// The first thing the notch ever does on its own.
    ///
    /// Four pages of window explained an app that lives somewhere else on the
    /// screen, and then the window closed onto nothing: whether any of it had
    /// worked was left for the user to discover by accident. So the tour ends
    /// by pointing at the thing it was describing — the notch opens, says one
    /// short line, and closes itself, which is exactly what it will do every
    /// day from here.
    ///
    /// A scenario rather than a bespoke provider: publishing an activity and
    /// letting it expire is what every real source does, so the demo is the
    /// real path and not a special case that can rot on its own.
    private func playWelcome() {
        // Waits for the greeting rather than timing it. Peeks are refused
        // while the eyes are up — that is the rule that keeps an arrival from
        // cutting the hello in half — so a welcome card timed to a stopwatch
        // was simply dropped when the two overlapped by a tenth of a second.
        // Awaiting the greeting's own task cannot be off by a tenth.
        Task { @MainActor [weak self] in
            await self?.greeting?.value
            try? await Task.sleep(for: .milliseconds(500))
            self?.publishWelcomeCard()
        }
    }

    /// The first thing the notch ever does on its own.
    ///
    /// Four pages of window explained an app that lives somewhere else on the
    /// screen, and then the window closed onto nothing: whether any of it had
    /// worked was left for the user to find out by accident. So the tour ends
    /// by pointing at the thing it was describing — the notch opens, says one
    /// short line, and closes itself, which is what it will do every day from
    /// here.
    ///
    /// A scenario rather than a bespoke provider: publishing an activity and
    /// letting it expire is what every real source does, so the demo runs the
    /// real path instead of a special case that can rot unnoticed.
    private func publishWelcomeCard() {
        let welcome = ScenarioActivity(
            kind: .message,
            source: "welcome",
            expiresAfter: 4,
            message: MessagePayload(
                title: "You're all set",
                // Short enough to fit the card at every scale: the
                // longer line was truncated mid-word, which is a poor first
                // impression for the sentence that exists to be read.
                body: "Hover me any time",
                symbolName: "sparkles"
            )
        )
        let scenario = Scenario(
            name: "welcome",
            steps: [Scenario.Step(at: 0.1, action: .publish(welcome))]
        )
        activities.add(FakeActivityProvider(scenario: scenario, loops: false))
        activities.start()
        Self.log.notice("onboarding: playing the welcome card")

        // Opened, not just peeked. A peek shows the ears — a glyph and a dot —
        // which is the right treatment for the hundredth notification and the
        // wrong one for the first: the sentence is the point, and the sentence
        // lives in the card. It opens itself, holds long enough to be read,
        // and closes itself, which also demonstrates the two things the user
        // was just told the notch does.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.presentation.selected?.id.source == "welcome" else { return }
            self.send(.clicked)
            try? await Task.sleep(for: .seconds(3.2))
            guard self.presentation.selected?.id.source == "welcome" else { return }
            self.collapse()
        }
    }


    // MARK: - Activities

    /// Peeks that arrived while another peek was on screen, oldest first,
    /// stamped so stale entries can be dropped at drain time. Latest-wins was
    /// the old rule, and the loser simply never appeared. Full ids, not
    /// kinds: two queued device connects must each flash their own card, not
    /// the first `.device` in the queue twice.
    private var pendingPeeks: [(id: ActivityID, at: TimeInterval, byUser: Bool)] = []

    /// How long a queued peek stays worth playing. Past this it is old news —
    /// replaying a Bluetooth connect from a minute ago reads as a glitch.
    private static let pendingPeekLifetime: TimeInterval = 8

    /// The one admission test for a peek, applied both to fresh arrivals and
    /// to queued entries at drain time. The queue used to be a second entrance
    /// with no bouncer: kinds the Focus filter would have suppressed walked in
    /// through the drain.
    private func admitPeek(kind: ActivityKind, byUser: Bool = false) -> Bool {
        Self.admitsPeek(
            kind: kind, byUser: byUser, greeting: presentation.greeting,
            quietDuringFocus: preferences.quietDuringFocus, focusActive: focusModeActive
        )
    }

    /// The admission rule itself, apart from the coordinator so it can be
    /// checked without one.
    ///
    /// `byUser` is a confirmation of something the user has just done, like
    /// switching coffee on. Focus keeps the notch from interrupting; it was
    /// never meant to stop the notch answering, and suppressing the answer
    /// left a press with nothing to show for it.
    static func admitsPeek(
        kind: ActivityKind, byUser: Bool, greeting: Bool,
        quietDuringFocus: Bool, focusActive: Bool
    ) -> Bool {
        // Nothing interrupts the hello. It lasts under two seconds, and an
        // arrival landing on top of it left the eyes handing straight over to
        // a volume readout — the ears never got to close, which is the whole
        // shape of the greeting.
        guard !greeting else { return false }
        if quietDuringFocus, focusActive, !byUser,
           !peeksDuringFocus.contains(kind) { return false }
        return true
    }

    /// Whether a Focus mode is on, tracked from the focus provider's own
    /// payloads. While on, ambient peeks stay quiet — the user asked not to be
    /// interrupted, and that includes the notch.
    private var focusModeActive = false

    /// Reads the Focus state for the quiet-during-Focus rule, independently of
    /// whether the Focus *provider* is switched on in Settings.
    private var focusBaseline: SystemFocusSource?

    /// What may still peek during Focus. Everything here is either the user's
    /// own action echoed back (the Focus toggle itself, a finished timer) or
    /// something urgent enough to outrank Do Not Disturb (the recording
    /// indicator, a critically low battery).
    private static let peeksDuringFocus: Set<ActivityKind> = [
        .focus, .privacy, .power, .timer,
    ]

    /// What an arriving card should stand the notch up for, if anything.
    ///
    /// Kept beside the arrival handler rather than inside the payloads: what
    /// deserves raising the voice is a decision about this app's manners, and
    /// the list of things that qualify will grow.
    private static func announcement(for activity: Activity) -> NotchAnnouncement? {
        switch activity.payload {
        case .timer(let payload):
            return NotchAnnouncement.forTimer(payload)
        case .keepAwake(let payload):
            // A session that came back on its own, and one that ended while
            // nobody was looking, both have to say so — the first because
            // nobody asked for it, the second because the Mac's behaviour
            // changed while the user was away.
            return NotchAnnouncement.forKeepAwake(payload)
        default:
            return nil
        }
    }

    /// Wires the activity hub up and starts it.
    ///
    /// Four things happen here and the order matters: what an arriving card
    /// means, what an empty queue means, what a resting track means, and
    /// only then the switches, observers and the start itself.
    private func startActivities() {
        wireArrivals()
        wireKeepAwakeLidItem()
        // Before any provider, and whether or not Keep Awake is switched on.
        // A conserve record is left by a process that died with the lid shut
        // and the panel at zero, and the user who then turns the feature off
        // is exactly the user who would never get their screen back if this
        // lived inside the provider that the setting decides not to build.
        lidConserve.recover()
        wireRestingContent()
        // Fixtures are development scaffolding, not something a normal run
        // should show. Now that a real provider exists they are opt-in.
        if DebugSwitches.isOn("LEDGE_FAKE_ACTIVITIES") {
            for scenario in ScenarioCatalog.bundled() {
                activities.add(FakeActivityProvider(scenario: scenario, loops: true))
                Self.log.notice("loaded scenario \"\(scenario.name, privacy: .public)\"")
            }
        }

        // Coming back to the app is the other moment the user can have been in
        // System Settings since we last looked. Between the two there is no
        // realistic way to change a grant without one of them firing, which is
        // why neither needs a timer behind it.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.revalidatePermissions()
                // Back from System Settings: the windows that stood aside for
                // the dialog take the front again, and any row that was
                // waiting on that journey stops waiting — whether or not the
                // switch was touched. Somebody who looked and left must get
                // their button back.
                self?.settingsModel.cameBackFromSystemSettings()
                self?.reclaimFront()
            }
        })

        // Anything a removed feature left in the keychain goes now, rather
        // than living on in an app that can no longer even show it.
        RetiredCredentials.purge()

        // The first reading, which is a baseline rather than a change: the
        // diff ignores anything it has not seen before.
        revalidatePermissions()

        // The automation answer arrives after the snapshot that asked for it —
        // the Apple Event query cannot run on the main thread (it blocks for as
        // long as Music takes to reply), so the first reading is always stale.
        permissions.onAutomationStatusChanged = { [weak self] in
            self?.revalidatePermissions()
        }

        preferences.onReset = { [weak self] in self?.handlePreferencesReset() }
        permissions.onAuthorizationChanged = { [weak self] _, _ in
            // Both grants and revocations pass through the same snapshot as
            // activation and the request result. Duplicate callbacks are quiet.
            self?.revalidatePermissions()
        }
        // Added before the hub starts, so it is running from launch. It is
        // not a card anybody switches on, and it has nothing to show until a
        // grant is being waited for.
        activities.add(handoffCard)
        activities.start()
        registerProviders()
    }

    /// What an arriving card does to the island, and what an emptied queue
    /// leaves behind.
    /// Keeps the menu-bar item in step with the hold.
    ///
    /// Driven from every Keep Awake publish rather than from the arrival,
    /// because the item has to follow what is left and what the helper last
    /// said for the whole life of a session — which may be days — and because
    /// the moment it must disappear is the moment the hold stops, not the
    /// moment a card is dismissed.
    private func wireKeepAwakeLidItem() {
        activities.onKeepAwake = { [weak self] payload in
            guard let self else { return }
            guard let payload, payload.isRunning else {
                self.keepAwakeLidItem.hide()
                return
            }
            self.keepAwakeLidItem.show(KeepAwakeLidBadge.badge(
                for: payload.lid,
                remaining: payload.isIndefinite
                    ? nil
                    : SatelliteContent.keepAwakeLabel(remaining: payload.remaining)
            ))
        }
    }

    private func wireArrivals() {
        activities.onArrival = { [weak self] activity in
            guard let self else { return }
            // The focus card is also how we learn the state — read it before
            // deciding whether to stay quiet.
            if case .focus(let payload) = activity.payload {
                self.focusModeActive = payload.isActive
            }
            // The timer's launcher card is not an announcement: it arrives
            // whenever a countdown ends or is cancelled, and saying so put the
            // default work length in the ears for a timer nobody started.
            guard activity.isWorthAnnouncing else { return }
            self.announce(activity)
        }
        activities.onKeepAwakeStarted = { [weak self] activity in
            // The user's own press. Free ears get the cup and its state for a
            // Focus-length moment; busy ones get the cup beside them instead,
            // the way AirPods connecting does while music plays. Focus or not:
            // it answers a press, it does not interrupt.
            self?.announce(activity, byUser: true)
        }
        activities.onEmpty = { [weak self] in
            // Nothing left to show, so an overlay held open by a click has
            // nothing to hold open for.
            self?.send(.dismissed)
        }
    }

    /// Puts an arrival in front of the user: beside the island when music
    /// already holds it and the arrival is satellite material, otherwise as a
    /// peek — now, or queued behind whatever has the stage.
    private func announce(_ activity: Activity, byUser: Bool = false) {
        guard self.admitPeek(kind: activity.kind, byUser: byUser) else {
            Self.log.debug("peek suppressed: \(activity.kind.rawValue, privacy: .public)")
            return
        }
        // While the companion rests, a device or charger announcement is
        // satellite material, not a takeover: the music keeps the island
        // and the event shows beside it for its dwell.
        if self.state.phase == .companion,
           let content = Self.transientSatellite(for: activity) {
            self.showSatellite(content, source: activity.id, priority: activity.priority)
            return
        }
        // Whether this arrival is worth standing up for, decided once and
        // honoured by every path below. Deciding it at the bottom meant
        // the branches that peek early — a card re-announcing mid-peek, a
        // queued peek replayed later — went out as ordinary whispers, and
        // a pomodoro that ends while anything else is on screen is exactly
        // the case this exists for.
        let announcement = Self.announcement(for: activity)
        let duration = announcement == nil
            ? self.preferences.peekDuration
            : NotchAnnouncement.duration

        // The SAME card announcing again — Caps Lock toggled mid-peek,
        // a second Focus flip — restarts the current peek in place with
        // the fresh payload rather than queueing behind itself: queued,
        // a rapid caps on-off-on showed its states seconds late, which
        // read as the indicator failing.
        if self.state.phase == .peek, self.presentation.peeked?.id == activity.id {
            self.presentation.peeked = activity
            self.presentation.announcement = announcement
            self.send(.peekRequested(duration))
            return
        }
        // A peek already on screen keeps the stage; this one waits its
        // turn and plays when the current one retires. Every phase the
        // reducer will decline to take over — an open stack under the
        // cursor, a HUD hovered or riding on a pinned card — is the same
        // case: sending would drop the announcement on the floor, so it
        // queues and plays when the stage clears. The condition mirrors
        // the reducer's own guards exactly.
        if self.state.phase == .peek
            || self.state.phase == .hover || self.state.phase == .expanded
            || (self.state.phase == .hud && (self.state.isHovering || self.state.isPinned)) {
            if self.pendingPeeks.count < 3 {
                self.pendingPeeks.append((activity.id, Date().timeIntervalSinceReferenceDate, byUser))
            }
            return
        }
        // The card the peek is *for*: selection only moves for standings
        // that outrank it, so without this the flash showed whatever was
        // already selected — music starting under a calendar card peeked
        // the calendar.
        self.presentation.peeked = activity
        // Some news is worth more than a two-second whisper: the notch
        // stands up instead — see `NotchAnnouncement`.
        self.presentation.announcement = announcement
        self.send(.peekRequested(duration))
    }

    /// What a resting track — playing, paused, or gone — does to the ears.
    /// The rules it leans on live in `MediaLinger`.
    private func wireRestingContent() {
        activities.onNowPlayingChanged = { [weak self] present, playing, pausedTimerRemaining in
            guard let self else { return }
            self.companionLinger?.cancel()
            self.companionLinger = nil
            // A new resting fact supersedes whatever the old one was waiting
            // for: this one brings its own lifetime.
            self.cancelRestingRelease()
            // Real resting facts supersede the farewell's phase-hold, and
            // its content: the island now belongs to the new fact.
            self.briefRest?.cancel()
            self.briefRest = nil
            self.presentation.farewell = nil
            if !present {
                // Nothing restable — close the companion.
                self.presentation.lingeringNowPlaying = nil
                self.setRestingHold(false)
                self.linger.nothingRests(now: Date().timeIntervalSinceReferenceDate)
            } else if playing {
                // Something is a live resident: playing music, a ticking
                // timer, a close event. None of them is a paused track, and
                // this is where a paused track used to come back from the dead.
                //
                // `present` is true whenever *anything* rests, so setting the
                // lingering card from it re-lingered a video paused hours ago
                // every time something unrelated took the island — a film
                // from the morning claimed the ears two seconds after an
                // unrelated resident appeared. The linger belongs to the pause
                // that started it and to nothing else.
                self.presentation.lingeringNowPlaying = nil
                self.setRestingHold(true)
                self.linger.nowResting(Self.mediaKey(self.presentation.nowPlaying))
            } else {
                // Bounded rest: paused music gets the companion linger,
                // a paused timer its five minutes — whichever runs longer,
                // since the content chain shows the longer-lived resident.
                // `Duration.seconds` traps on huge doubles, and the stored
                // value is only slider-bounded until someone edits defaults.
                // The bounded rest: this branch *is* a paused track (or a
                // paused timer), which is the only thing that may linger.
                // The linger belongs to a track that *was* in the ears and
                // then stopped. A paused track that merely turns up gets a
                // card and nothing more.
                //
                // Scrolling reels is where this showed: the browser's own
                // media cannot hold the ears, so every gap between clips let
                // the fallback name Spotify — still holding a track paused
                // hours ago — and each of those arrivals looked exactly like
                // "the user has just paused something". The notch lit up with
                // a track from the morning, over and over, for as long as the
                // scrolling went on.
                // The rules live in `MediaLinger`, which is where they can be
                // tested; what is left here is the timer and the drawing.
                let key = Self.mediaKey(self.presentation.nowPlaying)
                // Only a track can linger, so only ask when there is one.
                // `MediaLinger` gives an *unidentifiable* track the plain stay,
                // and nil is also what `mediaKey` says when there is no track
                // at all — so whatever else was present-but-not-playing was
                // granted two minutes for music that did not exist, and the
                // island sat open with nothing in its ears.
                let verdict: MediaLinger.Verdict = self.presentation.nowPlaying == nil
                    ? .neverRested
                    : self.linger.paused(
                        key,
                        full: min(self.preferences.companionLinger, 3_600),
                        now: Date().timeIntervalSinceReferenceDate
                    )
                let remaining: TimeInterval
                switch verdict {
                case .stays(let seconds):
                    remaining = seconds
                case .neverRested, .spent:
                    remaining = 0
                }
                if DebugSwitches.tracing("media") {
                    switch verdict {
                    case .neverRested:
                        Self.log.notice("linger refused: \(key ?? "-", privacy: .public) was never resting")
                    case .spent:
                        Self.log.notice("linger refused: \(key ?? "-", privacy: .public) already had its turn")
                    case .stays(let seconds):
                        Self.log.notice("linger: \(key ?? "-", privacy: .public) keeps the ears for \(Int(seconds), privacy: .public)s")
                    }
                }
                guard remaining > 0 || (pausedTimerRemaining ?? 0) > 0 else {
                    self.presentation.lingeringNowPlaying = nil
                    self.releaseRestingHold()
                    return
                }

                self.presentation.lingeringNowPlaying = self.presentation.nowPlaying
                // A paused timer's grace is a countdown someone means to come
                // back to, so it stands on its own however long the track's
                // linger has left.
                let linger = max(remaining, pausedTimerRemaining ?? 0)
                guard linger > 0 else { self.releaseRestingHold(); return }
                self.setRestingHold(true)
                self.companionLinger = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(linger))
                    guard let self, !Task.isCancelled else { return }
                    // The linger is up — but not while a readout is sitting
                    // beside the track it belongs to.
                    self.presentation.lingeringNowPlaying = nil
                    self.releaseRestingHold()
                }
            }
        }

    }

    /// Registers every provider in the table and starts the enabled ones.
    ///
    /// Now Playing is the awkward one: its source is chosen by an async probe,
    /// so its factory awaits that choice the first time it is built. Everything
    /// else is constructed synchronously on demand.
    private func registerProviders() {
        let registrations = ProviderRegistry.all(
            observations: deviceObservations,
            catalogue: deviceCatalogue,
            paired: pairedDevices,
            nowPlayingProvider: { [weak self] in
                guard let self else {
                    return NowPlayingProvider(
                        source: StubNowPlayingSource(),
                        artwork: ArtworkLoader()
                    )
                }
                let provider = NowPlayingProvider(
                    source: self.resolvedNowPlayingSource ?? StubNowPlayingSource(),
                    artwork: self.artworkLoader,
                    showsVideo: { [weak self] in
                        self?.preferences.showVideoInCompact ?? Prefs.showVideoInCompact.defaultValue
                    },
                    webMedia: { [weak self] in self?.preferences.webMedia ?? .hidden },
                    ownerIsApp: { BrowserCatalogue.shared.isOpenableApp(bundleID: $0) }
                )
                self.nowPlayingProviderRef = provider
                return provider
            },
            weatherCity: { [weak self] in self?.preferences.weatherCity ?? "" },
            timerProvider: { [weak self] in
                guard let self else { return TimerProvider() }
                // Re-enabling hands back the surviving instance: its session
                // and stopwatch are still ticking on wall-clock deadlines.
                if let existing = self.timerProviderRef { return existing }
                let provider = TimerProvider(
                    durations: { [weak self] in
                    guard let self else { return TimerProvider.Durations() }
                    // Slider-bounded in Settings, but read raw from defaults:
                    // a hand-edited huge value would trap the countdown's Int
                    // conversion. A day is a generous ceiling for a pomodoro.
                    func sane(_ minutes: Double) -> TimeInterval {
                        minutes.isFinite ? min(max(minutes, 1), 1_440) * 60 : 25 * 60
                    }
                    return TimerProvider.Durations(
                        work: sane(self.preferences.timerWorkMinutes),
                        shortBreak: sane(self.preferences.timerShortBreakMinutes),
                        longBreak: sane(self.preferences.timerLongBreakMinutes),
                        autoAdvance: self.preferences.timerAutoAdvance
                    )
                    },
                    recents: TimerProvider.decodeRecents(self.preferences.timerRecents),
                    persistRecents: { [weak self] minutes in
                        self?.preferences.timerRecents = TimerProvider.encodeRecents(minutes)
                    }
                )
                self.timerProviderRef = provider
                return provider
            },
            shelfProvider: { [weak self] in
                guard let self else { return ShelfProvider(store: ShelfStore(load: { "" }, save: { _ in })) }
                return ShelfProvider(store: self.shelf)
            },
            levelsProvider: { [weak self] in
                let provider = LevelsProvider(rows: { [weak self] in
                    self?.levelRows() ?? []
                })
                self?.levelsProviderRef = provider
                return provider
            },
            privacyProvider: { [weak self] in
                let provider = PrivacyProvider(
                    source: SystemRecordingSource(),
                    sharedWithAnotherApp: { [weak self] in
                        self?.selfView.isSharedWithAnotherApp ?? false
                    }
                )
                self?.privacyProviderRef = provider
                // A provider built while the self-view is already on screen —
                // the card switched on mid-session — inherits the cover, or
                // it would announce the picture the user is looking at.
                if self?.selfView.phase.isRunningCamera == true {
                    provider.selfViewChanged(true, device: self?.selfView.cameraID)
                }
                return provider
            },
            notesProvider: { [weak self] in
                guard let self else { return NotesProvider(store: NotesStore()) }
                let provider = NotesProvider(store: self.notes)
                self.notesProviderRef = provider
                // The card marks whichever note the window has open, so the two
                // never disagree about what is being written.
                self.notesWindow.onOpenNoteChanged = { [weak provider] id in
                    provider?.setOpenNote(id)
                }
                return provider
            },
            // The same source the quiet-during-Focus rule reads, not a second
            // one. See the parameter's own note: two of them argued.
            focusSource: { [weak self] in
                guard let base = self?.focusBaseline else { return SystemFocusSource() }
                return SharedFocusSource(base)
            },
            keepAwakeProvider: { [weak self] in
                guard let self else {
                    return KeepAwakeProvider(
                        assertion: IOPMSleepAssertion(),
                        power: IOKitPowerSource(),
                        thermal: ProcessInfoThermalSource(),
                        journal: FileKeepAwakeJournal(),
                        tombstone: DefaultsKeepAwakeTombstone(),
                        bootID: BootSession.identifier()
                    )
                }
                let provider = KeepAwakeProvider(
                    assertion: IOPMSleepAssertion(),
                    // Its own power source, not a share of the battery card's.
                    // The single-subscriber limit is per instance, and each
                    // instance brings its own run-loop source, so this watches
                    // the same hardware without taking the other's callback
                    // away.
                    power: IOKitPowerSource(),
                    thermal: ProcessInfoThermalSource(),
                    // The one writer over the one file, shared by every
                    // provider built here. Switching Keep Awake off and on
                    // again builds a new one while the old one may still be
                    // waiting on the disk, and which of them is allowed to
                    // write is a question that outlives both.
                    journal: self.keepAwakeJournal,
                    tombstone: DefaultsKeepAwakeTombstone(),
                    bootID: BootSession.identifier(),
                    lid: self.keepAwakeLid,
                    conserve: self.lidConserve,
                    appNap: self.keepAwakeAppNap,
                    // A session that ends with no notch on screen keeps its
                    // summary until there is somewhere to show it.
                    hasNotchPanel: { [weak self] in self?.displayPanels.primary != nil },
                    settings: { [weak self] in
                        guard let self else { return KeepAwakeProvider.Settings() }
                        return KeepAwakeProvider.Settings(
                            defaultMinutes: Int(self.preferences.keepAwakeDefaultMinutes),
                            batteryFloor: Int(self.preferences.keepAwakeBatteryFloor)
                        )
                    }
                )
                self.keepAwake = provider
                return provider
            }
        )
        for registration in registrations {
            activities.register(registration)
        }

        // Resolve the media source first, then start: building the provider
        // before the probe answers would attach it to a stub for good.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let choice = await NowPlayingSourceSelector.choose(
                forceStub: DebugSwitches.isOn("LEDGE_STUB_MEDIA"),
                mayQueryPlayers: { [weak self] in self?.permissions.mayAskAboutPlayers ?? false },
                // The same switch the provider reads, so the source layer does
                // not hold the notch for a page the provider will refuse to
                // publish.
                allowsMedia: { [weak self] snapshot in
                    guard let self else { return false }
                    return self.preferences.webMedia.allowsCard(
                        ownerIsApp: BrowserCatalogue.shared.isOpenableApp(
                            bundleID: snapshot.appBundleID
                        )
                    )
                }
            )
            Self.log.notice("now playing source: \(choice.reason, privacy: .public)")
            self.resolvedNowPlayingSource = choice.source
            // A demotion changes what the user can see, so the settings window
            // has to hear about it rather than showing what was true at launch.
            (choice.source as? CompositeNowPlayingSource)?.onStatusChanged = { [weak self] in
                self?.refreshSettingsModel()
            }
            self.refreshSettingsModel()
            self.activities.startEnabled()
            // The provider may already exist, built while this probe was still
            // running — a permission answer arriving first is enough to have
            // started it — and what it was handed then was the empty stub that
            // stands in until the real source is known. It answers "nothing
            // playing" for ever, and `startEnabled` will not replace a provider
            // that is already registered, so the media card simply never
            // appeared for the rest of that run. Rebuilding here is idempotent
            // and costs one restart at launch.
            if self.activities.isProviderRunning("nowplaying") {
                self.activities.restartProvider("nowplaying")
            }

            // Starting a pomodoro is a menu click, and a menu click cannot be
            // made from a test. This exists so the end of one — the whole
            // point of the announcement — can be watched happening rather
            // than reasoned about.
            if DebugSwitches.isOn("LEDGE_START_TIMER") {
                self.startTimer()
            }
        }
    }

    /// The media source, once the capability probe has answered.
    private var resolvedNowPlayingSource: (any NowPlayingSource)?

    /// What the app can see playing right now. Nil before the probe answers,
    /// which is the same thing as "players only" as far as the user is
    /// concerned — nothing system-wide is running yet either way.
    private var mediaSourceStatus: MediaSourceStatus {
        (resolvedNowPlayingSource as? CompositeNowPlayingSource)?.status ?? .playersOnly
    }

    /// The live now-playing provider, so a transport command can trigger an
    /// immediate re-poll instead of waiting for its steady tick. Weak: the hub
    /// owns it, and it is rebuilt whenever the provider is toggled.
    private weak var nowPlayingProviderRef: NowPlayingProvider?

    /// The live timer provider, so the menu bar and the card can drive the
    /// session. Weak: the hub owns it, and it is rebuilt when toggled.
    /// Held strongly on purpose. `ProviderHub.remove` drops its entry when
    /// the provider is toggled off in Settings; with only a weak reference
    /// here the instance died with it, and toggling back on built a fresh
    /// provider — a running pomodoro or stopwatch silently gone, laps lost,
    /// contrary to the provider's own "the session survives stop()" contract.
    /// The factory hands the same instance back, so the session resumes.
    private var timerProviderRef: TimerProvider?

    /// Hides the music companion a while after playback pauses. Cancelled the
    /// moment playback resumes or the track changes.
    private var companionLinger: Task<Void, Never>?
    /// Whether a card's ears carry anything worth a parting glance. The
    /// timer's idle launcher, a calendar with nothing imminent, and the
    /// control surfaces show static chrome — resting them is loitering,
    /// not information.
    /// A card earns its four-second goodbye on exactly the terms it would
    /// earn a rest: a launcher, a control surface or a calendar with nothing
    /// imminent has nothing to say on the way out either.
    private static func deservesFarewell(_ activity: Activity) -> Bool {
        activity.restsInEars
    }

    /// The companion's live tenant, if one is on the island right now: playing
    /// music, a ticking (not paused) timer, or an imminent event. These are
    /// the residents a walked-away card's farewell must never overpass —
    /// bounded lingerers (paused music, a paused timer) are deliberately not
    /// counted, so the farewell may still front-run them.
    private var liveResident: Activity? {
        if let playing = presentation.nowPlaying,
           case .nowPlaying(let payload) = playing.payload,
           payload.isPlaying {
            return playing
        }
        if let session = presentation.timerSession,
           case .timer(let payload) = session.payload,
           payload.isRunning {
            return session
        }
        if let event = presentation.closeEvent { return event }
        return nil
    }

    /// The four-second walk-away rest for cards with no resting content.
    private var briefRest: Task<Void, Never>?

    /// Which paused track may keep the ears, and for how long. See
    /// `MediaLinger` — the rules, and the three bugs behind them, live there.
    private var linger = MediaLinger()

    /// Identity for that memory: the player and the track, not the activity —
    /// a republished card is a new `Activity` describing the same track.
    private static func mediaKey(_ activity: Activity?) -> String? {
        guard let activity, case .nowPlaying(let payload) = activity.payload else { return nil }
        return "\(activity.id.source)|\(payload.itemKey ?? payload.title)"
    }

    /// What the *fact* path last told the reducer about resting: true while
    /// a resident (indefinite or inside its bounded linger) holds the island,
    /// false once nothing may rest — including after a linger has run out.
    /// The farewell borrows `hasNowPlaying` for its four seconds and must
    /// hand back exactly this truth, never the queue's stale "present" (a
    /// paused track is present long after its linger closed the island).
    private var restingHold = false

    /// The one place the fact path speaks to the reducer about resting.
    private func setRestingHold(_ holds: Bool) {
        restingHold = holds
        send(.nowPlayingChanged(holds))
    }

    /// Whether a rest whose time is up may actually end — see `RestRelease`,
    /// where the rule lives so it can be tested without a notch.
    private var restRelease = RestRelease()
    private var restReleaseBackstop: Task<Void, Never>?

    /// The longest a guest may hold a rest open past its time.
    private static let restReleaseGrace: TimeInterval = 30

    /// Whether something short-lived is sharing the island right now. A
    /// *standing* neighbour — a running timer beside the music — is not a
    /// guest and does not hold anything open; it lives in the view's own
    /// satellite chain rather than this one.
    private var hasIslandGuest: Bool {
        presentation.hudSatellite != nil || state.phase == .hud
    }

    /// Drops the resting hold, or waits for the guest beside it to leave.
    private func releaseRestingHold() {
        let wasPending = restRelease.isPending
        guard !restRelease.release(hasGuest: hasIslandGuest) else {
            return setRestingHold(false)
        }
        guard !wasPending else { return }
        restReleaseBackstop = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.restReleaseGrace))
            guard let self, !Task.isCancelled else { return }
            Self.log.notice("resting hold held past its grace — releasing anyway")
            self.flushRestingRelease(force: true)
        }
    }

    /// Lets go of a deferred rest once the island is the track's alone again.
    /// `setRestingHold` re-enters this through the phase change it causes, so
    /// the pending flag is cleared before the send, not after.
    private func flushRestingRelease(force: Bool = false) {
        guard restRelease.flush(hasGuest: hasIslandGuest, force: force) else { return }
        restReleaseBackstop?.cancel()
        restReleaseBackstop = nil
        setRestingHold(false)
    }

    /// Forgets a deferred rest outright — the fact it was waiting on has been
    /// replaced by a newer one, which brings its own lifetime.
    private func cancelRestingRelease() {
        restRelease.cancel()
        restReleaseBackstop?.cancel()
        restReleaseBackstop = nil
    }

    /// Ends a paused track's linger early, because the ears have been given
    /// to something else in the meantime.
    ///
    /// A paused track keeps the island for its linger — a courtesy for the
    /// moment you press pause, so what was playing does not blink out from
    /// under you. But opening the island, reading another card and walking
    /// away used to hand the ears *back* to that track once the card's
    /// Ends a farewell in flight — its task, its content, and the borrowed
    /// `hasNowPlaying` — restoring the resting truth. Safe when no farewell
    /// is running: nothing is sent, so callers need not check first.
    private func endFarewell() {
        guard briefRest != nil else {
            presentation.farewell = nil
            return
        }
        briefRest?.cancel()
        briefRest = nil
        presentation.farewell = nil
        if state.hasNowPlaying != restingHold {
            send(.nowPlayingChanged(restingHold))
        }
    }

    // MARK: - HUD

    /// Dismisses the satellite readout after its dwell.
    private var satelliteDismiss: DispatchWorkItem?
    /// Priority of the current satellite tenant, for intra-batch contention.
    private var satellitePriority = Int.min
    /// The activity behind the current satellite tenant, so hovering the
    /// trailing side of a duo can open *its* card rather than the resident's.
    private var satelliteSourceID: ActivityID?
    /// The tenant parked while an open card visits, re-seated when the
    /// companion returns — so walking away from the card the duo itself
    /// invited lands back on the split island, not on a seat wiped by the
    /// visit.
    private var parkedSatellite: (content: SatelliteContent, source: ActivityID?, priority: Int)?
    /// The selection to hand back when a trailing-duo visit ends. Opening the
    /// satellite's card selects it in the queue, and a selection is sticky —
    /// without the hand-back, every later hover anywhere on the island kept
    /// opening the trailing card. Cleared when the user cycles away inside
    /// the open stack: a deliberate move outranks the hand-back.
    private var duoHandBack: (target: ActivityID, prior: ActivityID)?

    /// Shows a level readout in the detached satellite blob beside the
    /// companion instead of taking the companion over. Repeat key presses
    /// extend the dwell; the cursor arriving (any phase change) clears it.
    private func showSatellite(
        _ content: SatelliteContent,
        source: ActivityID?,
        priority: Int = Int.max
    ) {
        // Arrivals are announced most-urgent-first, so two satellite-worthy
        // events in one batch (device + charger on wake) used to end with
        // the *last* write — the least urgent — owning the seat. A tenant
        // may only be displaced by an equal-or-higher priority while its
        // dwell runs.
        if presentation.hudSatellite != nil, priority < satellitePriority { return }
        satellitePriority = priority
        presentation.hudSatellite = content
        satelliteSourceID = source
        satelliteDismiss?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.presentation.hudSatellite = nil
                self?.satelliteSourceID = nil
                // The guest has left; a rest that was waiting on it may go.
                self?.flushRestingRelease()
            }
        }
        satelliteDismiss = item
        // Level readouts flash like the HUD; announcements (AirPods, charger)
        // read like peeks and deserve the peek's dwell.
        let base: TimeInterval
        if case .level = content { base = preferences.hudDuration } else { base = preferences.peekDuration }
        let dwell = base.isFinite ? min(max(base, 0.5), 10) : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: item)
    }

    /// The satellite form of a transient arrival, when it has one: AirPods and
    /// friends show their glyph, a charger shows a green bolt. Anything else
    /// (calendar, keyboard, messages) returns nil and takes the normal path.
    private static func transientSatellite(for activity: Activity) -> SatelliteContent? {
        switch activity.payload {
        case .device(let payload):
            // Anything but a departure. A goodbye has no glyph to flash; an
            // arrival does, and so does a case opening on the desk, whose
            // connection to this Mac is unknown either way.
            guard payload.isConnected != false else { return nil }
            return .device(symbolName: payload.symbolName, tint: .neutral)
        case .power(let payload):
            guard payload.isCharging else { return nil }
            return .charging(level: payload.percentage)
        case .keepAwake(let payload):
            // Starting a hold while music has the ears: the cup beside the
            // island, not a takeover of it.
            guard payload.isRunning else { return nil }
            return .keepAwake(remaining: payload.isIndefinite ? nil : payload.remaining)
        default:
            return nil
        }
    }

    private func clearSatellite() {
        satelliteDismiss?.cancel()
        satelliteDismiss = nil
        presentation.hudSatellite = nil
        satelliteSourceID = nil
        satellitePriority = Int.min
        flushRestingRelease()
    }

    /// The level readout the trailing seat is drawing, when it is drawing one.
    /// Nil for every other tenant — a timer or a recording dot still opens its
    /// own card, which is the right answer for those.
    private func satelliteReadout(on key: CGDirectDisplayID) -> HUDReadout? {
        guard case .level(let readout)? = presentation.hudSatellite else { return nil }
        guard trailingDuoTarget(on: key) == LevelsProvider.activityID else { return nil }
        return readout
    }

    /// A parked level readout re-reads the levels snapshot before re-seating:
    /// the visit it survived may have been to the Levels card itself, and an
    /// echo showing the pre-drag value would contradict the card just closed.
    private func refreshedTenant(_ content: SatelliteContent) -> SatelliteContent {
        guard case .level(let readout) = content,
              readout.kind == .volume || readout.kind == .brightness,
              let activity = activities.activity(withID: LevelsProvider.activityID),
              case .levels(let payload) = activity.payload
        else { return content }
        return .level(HUDReadout(
            kind: readout.kind,
            level: readout.kind == .volume ? payload.volume : payload.brightness,
            isMuted: readout.isMuted,
            deviceName: readout.deviceName
        ))
    }

    private func startHUD() {
        // The settings window draws the tap's real state, so it has to hear
        // about every attempt — including the ones that fail.
        hud.onSuppressionChanged = { [weak self] _ in self?.refreshSettingsModel() }
        hud.onReadout = { [weak self] readout in
            guard let self else { return }
            // Every readout, ahead of every gate: an open Levels card follows
            // the keys through this, and its own drags are already filtered
            // on the card side.
            self.presentation.latestLevel = readout
            // The Levels card is a level control too: its drags change the
            // hardware, the hardware answers with change events — CoreAudio
            // right behind the release, the brightness poll a beat later —
            // and each would summon the readout over the very card being
            // dragged. The quiet window absorbs the echo.
            guard Date().timeIntervalSinceReferenceDate >= self.levelsCardQuietUntil else { return }
            // The route menu *is* a volume control, so its own drag must not
            // summon the level HUD on top of it. Without this, moving a slider
            // changed the system volume, the volume listener fired, and the
            // menu was replaced by the sound readout mid-drag.
            let routeMenuOwnsVolume = readout.kind == .volume && self.presentation.routePickerRows > 0
            if !routeMenuOwnsVolume {
                // While the music companion is resting, the readout detaches
                // into the satellite blob beside it — the split treatment the
                // real Dynamic Island uses — instead of taking the whole
                // compact view over. Every other phase keeps the ears readout.
                if DebugSwitches.tracing("levels") {
                    Self.log.debug("""
                        readout \(readout.kind.rawValue, privacy: .public): \
                        phase=\(self.state.phase.rawValue, privacy: .public) \
                        resting=\(self.restingContent()?.id.kind.rawValue ?? "-", privacy: .public)
                        """)
                }
                if self.state.phase == .companion {
                    self.showSatellite(.level(readout), source: LevelsProvider.activityID)
                } else if self.levelsCardIsOpen {
                    // The Levels card *is* the readout. Summoning the HUD over
                    // it swapped card for panel and back on every key, and the
                    // card came back showing the level it opened with.
                    //
                    // It follows the provider's publishes instead — and a
                    // brightness key produces none of its own, because
                    // brightness has no change notification and is polled by
                    // whoever needs it. So ask. Only while the card is open:
                    // nothing enumerates devices otherwise.
                    self.levelsProviderRef?.republish()
                } else {
                    self.send(.hudRequested(self.preferences.hudDuration))
                }
            }
            // The sound panel's active row reads its level straight off the
            // readout, so the keys move it for free. The brightness panel draws
            // a row per display out of `hudDisplays`, which was only rebuilt
            // when the panel opened — so pressing the keys with it open changed
            // the screen but left the bar sitting still. Rebuild it while it is
            // actually on show.
            if readout.kind == .brightness, self.wasHudHovered {
                self.presentation.hudDisplays = self.hud.brightnessDisplays()
            }
        }
        hud.start()
        observeHUDPreferences()
    }

    /// Re-applies the HUD configuration when its settings change, so toggling
    /// suppression takes effect immediately instead of at the next launch.
    /// `withObservationTracking` fires once, so it re-arms itself each time.
    private func observeHUDPreferences() {
        withObservationTracking {
            _ = preferences.hudEnabled
            _ = preferences.hudBrightnessEnabled
            _ = preferences.suppressSystemHUD
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.hud.apply()
                self?.observeHUDPreferences()
            }
        }
    }

    private func makeNowPlayingActions() -> NowPlayingActions {
        NowPlayingActions(
            playPause: { [weak self] in self?.sendMedia(.playPause) ?? false },
            next: { [weak self] in self?.sendMedia(.next) ?? false },
            previous: { [weak self] in self?.sendMedia(.previous) ?? false },
            seek: { [weak self] fraction in
                guard let self,
                      case .nowPlaying(let payload)? = self.presentation.selected?.payload,
                      payload.duration > 0
                else { return false }
                // The player's own id, never the card's name for the song —
                // see `NowPlayingPayload.transportKey`.
                return self.sendMedia(.seek(payload.duration * fraction, item: payload.transportKey))
            },
            audioLevels: { [weak self] in self?.simulatedLevels() ?? [] },
            chooseOutput: {
                // The nearest honest equivalent to iOS's output picker: the
                // system Sound settings, where the output device is chosen.
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            },
            outputs: { [weak self] in self?.currentOutputs() ?? [] },
            selectOutput: { [weak self] id in
                VolumeController.setDefaultOutputDevice(id)
                guard let self else { return }
                // Refresh the open panel: new checkmark order, new title, and a
                // readout for the new device's own level. The route change takes
                // a beat to land, hence the short delay.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, self.wasHudHovered else { return }
                    self.presentation.hudOutputs = self.currentOutputs()
                    self.hud.refreshVolumeReadout()
                }
            },
            setOutputVolume: { id, level in
                // Any device, not just the current route — CoreAudio can set a
                // level on an output that is not the default.
                //
                // Scalar and mute together: moving the bar up is a request to
                // hear something, and dragging it to the bottom is a request
                // to hear nothing. Half the operation is a control that lies
                // about what it did.
                guard let result = VolumeController.apply(level: level, on: id) else { return nil }
                return LevelFeedback(level: result.shownLevel, isMuted: result.showsMuted)
            },
            openOwningApp: { [weak self] in self?.bringMediaAppForward() }
        )
    }

    /// The levels card's conduits: the same enumerations and setters the HUD's
    /// hover panel uses, pulled when the card opens. Drags latch the same
    /// hover-exit suppression, and brightness goes through the HUD coordinator
    /// so external displays keep their gamma bookkeeping.
    private func makeLevelsActions() -> LevelsActions {
        LevelsActions(
            rows: { [weak self] in self?.levelRows() ?? [] },
            setLevel: { [weak self] id, level in self?.setLevel(id, to: level) },
            toggleMute: { [weak self] id in self?.toggleMute(id) },
            // Not wired, and the rows say so by not offering it. The output
            // list belongs to the Now Playing card's AirPlay button and has no
            // seam anything else can open it through; drawing a chevron here
            // that did nothing would be exactly the dead control this card is
            // being rebuilt to be rid of.
            swapOutput: { _ in },
            setDragging: { [weak self] dragging in
                guard let self else { return }
                // The device the gesture owns, snapshotted on the first touch
                // and held for the whole drag. Resolving the current output on
                // every tick meant plugging in headphones mid-drag moved the
                // drag to them: the number went on moving, so there was
                // nothing to see, and the device being changed was not the one
                // being looked at.
                if dragging {
                    self.levelDrag.began(on: self.currentOutputs().first(where: \.isCurrent)?.id)
                } else {
                    self.levelDrag.ended()
                }
                self.setHUDDragging(dragging)
                // Quiet from the first touch until well after release: the
                // hardware's answering change events (CoreAudio, the
                // brightness poll) arrive on their own schedule.
                // 30s covers any real drag; a severed one (display unplug
                // mid-drag) self-heals instead of silencing the HUD for good.
                self.levelsCardQuietUntil = Date().timeIntervalSinceReferenceDate + (dragging ? 30 : 2)
            }
        )
    }

    /// Every level there is, as rows.
    ///
    /// Built here because this is the only layer that can ask the hardware
    /// anything, and read in `LedgeUI`, which cannot. One list, so the card
    /// and the ears can no longer disagree about what exists.
    private func levelRows() -> [LevelRow] {
        var rows: [LevelRow] = []

        if let output = currentOutputs().first(where: \.isCurrent) {
            rows.append(soundRow(output))
        } else {
            // The row stays, so the card keeps its shape, and says why.
            rows.append(LevelRow(id: Self.soundRowID, kind: .sound, name: LevelCopy.sound,
                                 control: .unreadable, note: .noOutput))
        }

        for display in hud.brightnessDisplays() {
            rows.append(displayRow(display))
        }
        return rows
    }

    static let soundRowID = "sound"

    private func soundRow(_ output: AudioOutputOption) -> LevelRow {
        // A level the device will not let anybody set — HDMI, some USB
        // interfaces. No line to drag, and a sentence saying where the volume
        // actually lives rather than a bar that does nothing.
        guard let level = output.level else {
            return LevelRow(id: Self.soundRowID, kind: .sound, name: output.name,
                            control: .fixed, note: .fixedElsewhere)
        }
        return LevelRow(
            id: Self.soundRowID, kind: .sound, name: output.name,
            control: .level(level), isMuted: output.isMuted,
            canMute: true, canSwap: false,
            note: levelNotes[Self.soundRowID]
        )
    }

    private func displayRow(_ display: DisplayLevelOption) -> LevelRow {
        let id = "display-\(display.id)"
        // An external panel is dimmed with a gamma ramp rather than a
        // backlight, so below the floor the picture is unreadable and the
        // controller clamps. The card draws that start hatched and stops the
        // fill at the tick — a bar that followed the pointer to zero while
        // the screen sat at 18% was the control lying.
        let floor = display.isBuiltIn ? 0 : DisplayBrightnessController.gammaFloor
        // No standing sentence. The hatched start and the tick already say
        // the line cannot go below there, which is the whole of what the
        // explanation added — and a caveat under a row somebody has not
        // touched is a card explaining itself rather than a card. A refusal or
        // a half-applied change still speaks, because those are answers to
        // something the user just did.
        return LevelRow(
            id: id, kind: .display, name: display.name,
            control: .level(display.level),
            floor: floor,
            note: levelNotes[id]
        )
    }

    /// What a row has to say, until it stops saying it.
    ///
    /// A refusal is the answer to something the user just did, so it is theirs
    /// for a few seconds and then gone. Kept here rather than in the card
    /// because the card is rebuilt on every publish.
    private var levelNotes: [String: LevelRow.Note] = [:]

    private func say(_ note: LevelRow.Note?, on id: String) {
        levelNotes[id] = note
        guard note != nil else { return }
        let era = levelNoteEra + 1
        levelNoteEra = era
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(LevelCopy.noteSeconds))
            guard let self, self.levelNoteEra == era else { return }
            self.levelNotes[id] = nil
        }
    }
    private var levelNoteEra = 0

    /// Which output a level drag owns. See `LevelDragTarget`.
    private var levelDrag = LevelDragTarget<UInt32>()

    private func setLevel(_ id: String, to level: Double) -> LevelRow? {
        if id == Self.soundRowID {
            let outputs = currentOutputs()
            guard let current = outputs.first(where: \.isCurrent) else { return nil }
            // The held device while a drag is in flight, and the system's
            // otherwise — but never a held device the system has stopped
            // reporting, because an output unplugged mid-drag is nothing to
            // write to.
            let target = levelDrag.device(
                current: current.id,
                isStillPresent: { held in outputs.contains { $0.id == held } }
            )
            guard let target,
                  let output = outputs.first(where: { $0.id == target }) else { return nil }
            guard let result = VolumeController.apply(level: level, on: output.id) else {
                say(.refused, on: id)
                return soundRow(output)
            }
            // The device's answer, and the reason when it is not the answer
            // that was asked for.
            switch result.scalarOutcome {
            case .partial: say(.partial, on: id)
            case .unsupported, .refused: say(.refused, on: id)
            default: say(nil, on: id)
            }
            return LevelRow(
                id: id, kind: .sound, name: output.name,
                control: .level(result.shownLevel), isMuted: result.showsMuted,
                canMute: true, canSwap: false, note: levelNotes[id]
            )
        }
        guard let display = hud.brightnessDisplays().first(where: { "display-\($0.id)" == id })
        else { return nil }
        hud.adjustBrightness(of: display.id, to: level)
        presentation.hudDisplays = hud.brightnessDisplays()
        // Read back rather than assumed: the controller clamps an external
        // panel at its floor, and the number on the card is the panel's.
        guard let after = hud.brightnessDisplays().first(where: { $0.id == display.id })
        else { return nil }
        return displayRow(after)
    }

    private func toggleMute(_ id: String) -> LevelRow? {
        guard id == Self.soundRowID,
              let output = currentOutputs().first(where: \.isCurrent) else { return nil }
        let result = VolumeController.apply(muted: !output.isMuted, on: output.id)
        if !result.muteOutcome.isComplete { say(.refused, on: id) } else { say(nil, on: id) }
        return LevelRow(
            id: id, kind: .sound, name: output.name,
            control: .level(result.shownLevel), isMuted: result.showsMuted,
            canMute: true, canSwap: false, note: levelNotes[id]
        )
    }

    /// Whether the Levels card is the open card right now — the one case a
    /// hardware key should move a bar in place rather than summon the HUD.
    private var levelsCardIsOpen: Bool {
        (state.phase == .hover || state.phase == .expanded)
            && presentation.selected?.id == LevelsProvider.activityID
    }

    /// Readouts stay quiet until this instant — the Levels card's drags own
    /// the level changes they cause. Each drag tick re-arms it; release
    /// shortens it to a two-second echo tail.
    private var levelsCardQuietUntil: TimeInterval = 0

    /// Extra height the hovered panel's device rows add, for the hit region.
    /// This must agree with `NotchOverlayView.hudExtraHeight` or the shape
    /// and the clickable area drift apart: live brightness rows cost 48pt,
    /// faded audio routes 36pt.
    private var hudExtraHeight: CGFloat {
        presentation.hudExtraHeight(hovered: state.phase == .hud && state.isHovering)
    }

    private var wasHudHovered = false

    /// The selectable outputs right now, current one flagged, each with its own
    /// level for the faded bars.
    private func currentOutputs() -> [AudioOutputOption] {
        let current = VolumeController.defaultOutputDevice()
        return VolumeController.outputDevices().map {
            // Logical, not physical: an output turned all the way down shows
            // an empty bar even on hardware that clamps zero.
            let level = VolumeController.shownLevel(of: $0.id)
            return AudioOutputOption(
                id: $0.id,
                name: $0.name,
                isCurrent: $0.id == current,
                level: level,
                // The same rule the HUD draws by: silence at zero is an empty
                // bar, and only the user's own mute is the muted state.
                isMuted: VolumeController.showsMuted($0.id, level: level ?? 0),
                // Asked of the device, not inferred from the fact that a level
                // came back: the two are different questions.
                isAdjustable: VolumeController.writer.canSetLevel(of: $0.id)
            )
        }
    }

    /// Keeps the timer card on screen when its session ends by the user's own
    /// hand. Only while the timer is what they are looking at: cancelling from
    /// the menu bar must not pull the stage away from another card.
    private func selectTimerLauncherIfWatching() {
        guard presentation.selected?.id.kind == .timer else { return }
        activities.selectWhenAvailable(TimerProvider.idleActivityID)
    }

    private func makeTimerActions() -> TimerActions {
        TimerActions(
            // The same path as the menu item: ensure the provider is running
            // first, so the ready card's chips work even when the timer
            // provider is toggled off in Settings.
            toggle: { [weak self] in self?.toggleTimerFromMenu() },
            cancel: { [weak self] in
                self?.timerProviderRef?.cancel()
                // Ending a session retracts its card, and a retracted card
                // hands the open stage to whichever neighbour ranks next — so
                // cancelling from the timer threw the user onto the weather.
                // The launcher takes its place instead: the card stays put and
                // offers to start another, which is why the button was
                // pressed. The mirror of what starting a timer already does.
                self?.selectTimerLauncherIfWatching()
            },
            skip: { [weak self] in
                self?.timerProviderRef?.skip()
                // Skipping the last leg ends the session too (with auto-advance
                // off, any skip does).
                self?.selectTimerLauncherIfWatching()
            },
            startFocus: { [weak self] in
                self?.ensureTimerRunning()
                self?.timerProviderRef?.startFocus()
                // The session the user just started is what they should be
                // looking at — without this the retracted ready card handed
                // the open stage to whichever neighbour ranked next.
                self?.activities.selectWhenAvailable(TimerProvider.activityID)
            },
            startBreak: { [weak self] in
                self?.ensureTimerRunning()
                self?.timerProviderRef?.begin(.shortBreak)
                self?.activities.selectWhenAvailable(TimerProvider.activityID)
            },
            startCustom: { [weak self] minutes in
                self?.ensureTimerRunning()
                self?.timerProviderRef?.startCustom(minutes: minutes)
                self?.activities.selectWhenAvailable(TimerProvider.activityID)
            },
            // The duration passing a detent. `.alignment` is the tick the
            // system gives for a value snapping into place — the same feel as
            // a window edge meeting a guide — and `.drawCompleted` lets the
            // trackpad fire it with the frame the number moved in rather than
            // ahead of it. Respects the user's "Play feedback" setting on its
            // own; nothing here needs to check it.
            haptic: {
                NSHapticFeedbackManager.defaultPerformer.perform(
                    .alignment, performanceTime: .drawCompleted
                )
            },
            // Dialling a length is a drag like any other: the card must not
            // close under a pointer that has wandered off it mid-drag. Only
            // the hover latch — the Levels card's quiet window is about
            // hardware answering back, and nothing here touches the hardware.
            setDragging: { [weak self] dragging in self?.setHUDDragging(dragging) },
            dismissFinished: { [weak self] in
                self?.timerProviderRef?.dismissFinished()
                self?.selectTimerLauncherIfWatching()
            },
            stopwatchToggle: { [weak self] in
                self?.ensureTimerRunning()
                self?.timerProviderRef?.stopwatchToggle()
                // Starting from the ready card retracts it for the session
                // card; the user should land on the face they just started.
                self?.activities.selectWhenAvailable(TimerProvider.activityID)
            },
            stopwatchLap: { [weak self] in self?.timerProviderRef?.stopwatchLap() },
            stopwatchReset: { [weak self] in
                self?.timerProviderRef?.stopwatchReset()
                // Reset with no countdown retracts the session card for the
                // ready card — stay on the clock either way.
                self?.activities.selectWhenAvailable(TimerProvider.idleActivityID)
            }
        )
    }

    private var notesPanel: LedgePanelController? {
        if let id = presentation.hoveredDisplayID, let panel = displayPanels.controller(for: id) { return panel }
        return displayPanels.primary
    }

    private func makeNotesActions() -> NotesActions {
        NotesActions(
            open: { [weak self] id in
                guard let self else { return false }
                return await self.notesWindow.open(noteID: id)
            },
            create: { [weak self] in self?.notesWindow.create() },
            // No delete. It called the store while the window still had the
            // note open, and the window's next keystroke wrote it straight
            // back — deleting stays in the window, with the note in front of
            // the person doing it.
            openAll: { [weak self] in self?.notesWindow.openAllNotes() },
            copyMarkdown: { [weak self] id in self?.notesWindow.copy(.markdown, noteID: id) },
            copyPlainText: { [weak self] id in self?.notesWindow.copy(.plainText, noteID: id) },
            hovering: { [weak self] over in
                self?.presentation.notesTileHovered = over
            }
        )
    }

    private func makeShelfActions() -> ShelfActions {
        ShelfActions(
            remove: { [weak self] path in self?.shelf.remove(path: path) },
            clear: { [weak self] in self?.shelf.clear() },
            reveal: { path in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        )
    }

    /// Takes files dropped on the notch. Enables the shelf provider first if the
    /// user had switched it off, so a drop is never silently discarded.
    private func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        // Told before anything else can fail: the tour's Drop step is about
        // the gesture landing on the notch, which it just did, whether or not
        // the shelf had room for this particular file.
        tellTheTour(.fileDropped)
        let added = shelf.add(urls)
        guard added > 0 else { return true }
        announceShelf()
        return true
    }

    /// Flashes the shelf to confirm something landed on it.
    ///
    /// The flash must show the *shelf*: a second arrival is an in-place upsert
    /// with no arrival event, so without this the peek showed whatever card
    /// was selected — music, the calendar — as if it had anything to do with
    /// the file. Setting `peeked` directly also covers the peek-over-peek
    /// takeover, whose phase does not change and whose exit-clear therefore
    /// never ran.
    ///
    /// On the *first* arrival the provider's publish crosses an AsyncStream
    /// and has not landed yet — the queue answers nil and the flash fell back
    /// to the selected card. The store already holds the items, so the card is
    /// built locally when the queue cannot supply it.
    private func announceShelf() {
        if !preferences.isProviderEnabled("shelf") {
            activities.setProvider("shelf", enabled: true)
        }
        presentation.peeked = activities.activity(withID: ShelfProvider.activityID)
            ?? Activity(
                id: ShelfProvider.activityID,
                createdAt: Date().timeIntervalSinceReferenceDate,
                payload: .shelf(ShelfPayload(items: shelf.items))
            )
        send(.peekRequested(preferences.peekDuration))
    }

    // MARK: - Timer commands (menu bar)

    /// Starts a fresh pomodoro cycle. Enables the provider first if the user
    /// switched it off, so the menu item is never a dead click.
    public func startTimer() {
        ensureTimerRunning()
        timerProviderRef?.startFocus()
    }

    /// One menu item, three jobs: start a cycle, pause it, resume it.
    public func toggleTimerFromMenu() {
        ensureTimerRunning()
        if timerProviderRef?.isActive == true {
            timerProviderRef?.toggle()
        } else {
            timerProviderRef?.startFocus()
        }
    }

    private func ensureTimerRunning() {
        // Gated on the hub, not on the reference: the provider instance is
        // held strongly now (its session must survive a toggle), so a non-nil
        // reference no longer means "running".
        guard !activities.isProviderRunning("timer") else { return }
        activities.setProvider("timer", enabled: true)
    }

    /// Synthesized equalizer levels: deterministic musical motion seeded by
    /// the playing track, no audio capture of any kind. Empty when nothing is
    /// playing — the views then rest flat.
    private func simulatedLevels() -> [Double] {
        presentation.simulatedAudioLevels(at: Date().timeIntervalSinceReferenceDate)
    }

    /// The last freeze state pushed to the queue — every phase change used to
    /// re-push it unconditionally, and hub.mutate notifies unconditionally,
    /// which re-synced the whole presentation (and re-rendered the overlay)
    /// for a no-op write.
    private var lastOrderFrozen = false

    private func setOrderFrozenIfChanged(_ frozen: Bool) {
        guard frozen != lastOrderFrozen else { return }
        lastOrderFrozen = frozen
        activities.setOrderFrozen(frozen)
    }

    // MARK: - Backdrop outline

    /// Brings the app whose media is on the card to the front.
    ///
    /// Activation only — never a launch. The card exists because that app is
    /// playing something, so it is running; and an app that has quit since the
    /// card was drawn should not be started by a click on empty space.
    private func bringMediaAppForward() {
        guard let bundleID = activeMediaBundleID,
              BrowserCatalogue.shared.isOpenableApp(bundleID: bundleID)
        else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        app.activate()
        Self.log.debug("brought \(bundleID, privacy: .public) forward")
    }

    /// - Returns: whether the press reached a player. See `MediaPress`.
    @discardableResult
    private func sendMedia(_ command: NowPlayingCommand) -> Bool {
        guard let bundleID = activeMediaBundleID else { return false }
        let press = MediaPress(
            send: { [weak self] in self?.commander.send($0, to: bundleID) ?? .refused },
            // Re-read the player right away so the card reflects reality in a
            // few hundred milliseconds, not on the next 1–4s poll.
            expectChange: { [weak self] in self?.nowPlayingProviderRef?.expectChange() }
        )
        return press(command)
    }

    // MARK: - Gestures

    private func startGestures() {
        gestures.onSwipe = { [weak self] swipe in
            guard let self else { return }
            guard let intent = SwipeIntent.from(swipe, phase: self.state.phase) else { return }
            switch intent {
            case .cycleForward: self.activities.cycleForward()
            case .cycleBackward: self.activities.cycleBackward()
            }
        }
        gestures.onMiddleClick = { [weak self] in self?.activities.cycleForward() }
        gestures.shouldHandle = { window in window is LedgePanel }
        // The route menu is a list, and a list under the pointer owns the
        // wheel. Everywhere else on the card the wheel moves between cards.
        gestures.wheelBelongsToContent = { [weak self] in
            (self?.presentation.routePickerRows ?? 0) > 0
        }
        gestures.start()
        observeInteractionPreferences()
        observeLiveEffectPreferences()
        observeMediaPreferences()
    }

    /// Re-applies interaction settings when they change.
    ///
    /// Without this the swipe sliders and the click-to-pin toggle were read once
    /// at construction, so changing them appeared to do nothing until the next
    /// launch — while the HUD settings next to them applied immediately.
    /// The city the last weather restart used, so unrelated interaction
    /// preferences sharing the observation cannot churn the provider.
    private var observedWeatherCity = ""

    /// Effects with their own lifecycles — the outline sampler, the audio tap,
    /// the panels' capture hiding — used to notice their preference only at
    /// the next phase change; a toggle in Settings must land now.
    private func observeLiveEffectPreferences() {
        withObservationTracking {
            _ = preferences.hideFromScreenCapture
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                for controller in self.displayPanels.all {
                    controller.applyCapturePreference()
                }
                self.observeLiveEffectPreferences()
            }
        }
    }

    /// The media settings decide what the player that is *already* playing is
    /// allowed to do, so they have to be answered now: a website whose rule
    /// was removed has to go away while the same track keeps playing, and one
    /// just allowed has to appear without waiting for the next track. The
    /// provider re-decides from the snapshot it already holds — no second read
    /// of the player, and no relaunch.
    private func observeMediaPreferences() {
        withObservationTracking {
            _ = preferences.showWebMediaCards
            _ = preferences.showWebMediaInCompact
            _ = preferences.showVideoInCompact
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.nowPlayingProviderRef?.reconsider()
                self.observeMediaPreferences()
            }
        }
    }

    /// The ear width is draft-edited in Settings and lands only when the
    /// Apply button writes the preference — this observation is that landing.
    /// A collapse follows so every panel redraws its silhouette at the new
    /// width instead of keeping the old one until the next phase change.
    private func observeEarWidth() {
        withObservationTracking {
            _ = preferences.earWidth
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                NotchLayout.setEarWidth(self.preferences.earWidth)
                self.send(.forceCollapse)
                self.observeEarWidth()
            }
        }
    }

    private func observeInteractionPreferences() {
        withObservationTracking {
            _ = preferences.swipeThreshold
            _ = preferences.naturalSwipe
            _ = preferences.weatherCity
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.gestures.updateSettings(
                    threshold: self.preferences.swipeThreshold,
                    isNatural: self.preferences.naturalSwipe
                )
                // A retyped city takes effect now, not at the next half-hour
                // refresh. Only when it actually changed, though: this fires
                // for *any* tracked preference, and restarting weather on every
                // swipe-slider tick tore the provider down dozens of times per
                // drag, stranding a URLSession and firing a network fetch each
                // time.
                if self.preferences.weatherCity != self.observedWeatherCity {
                    self.observedWeatherCity = self.preferences.weatherCity
                    self.activities.restartProvider("weather")
                }
                self.observeInteractionPreferences()
            }
        }
    }

    /// Re-reads permission state and provider enablement into the model the
    /// settings window renders.
    ///
    /// Only ever *checks* — nothing here can prompt, so it is safe on a timer.
    private func refreshSettingsModel() {
        installDevicesModelIfNeeded()
        settingsModel.isSuppressingSystemHUD = hud.isSuppressing
        // Sparkle takes the check back when it finishes.
        if updateCheckInFlight, canCheckForUpdates() { updateCheckInFlight = false }
        settingsModel.isCheckingForUpdates = updateCheckInFlight
        // The probe tap's own answer. macOS can report an Accessibility grant
        // while holding the key presses back until the app starts again, and
        // every list in the window says "Granted" through all of it.
        settingsModel.accessibilityIsInEffect = MediaKeyInterceptor.isTrusted
        settingsModel.focusFolderGranted = focusFolder.isReadable
        // macOS makes this folder the first time a Focus is used. Until then
        // the row says so and offers nothing, instead of a button that opens
        // a panel on a folder that is not there.
        settingsModel.focusFolderExists = FileManager.default.fileExists(
            atPath: FocusDatabaseAccess.databaseFolder.path
        )
        settingsModel.accessibilityWasAskedBefore = preferences.accessibilityWasAsked
        settingsModel.appLocation = Self.appLocationToOffer()
        // Read every time rather than cached at launch: a helper installed
        // while Ledge is running must not need a relaunch to be believed.
        settingsModel.keepAwakeHelper = KeepAwakeHelperInstall.current()
        // Deliberately does *not* re-read the permissions: this runs from many
        // places, and every read would quietly become the new baseline, so a
        // revocation could be absorbed between two of them and never acted on.
        // `revalidatePermissions()` owns that reading, and this draws it.
        settingsModel.permissions = lastPermissionRows
        settingsModel.mediaSource = mediaSourceStatus
        settingsModel.isLaunchedFromTerminal = permissions.isLaunchedFromTerminal
        settingsModel.providers = ProviderRegistry.descriptors(
            activities.registeredProviders,
            isEnabled: { [weak self] id in
                guard let self else { return true }
                let fallback = self.activities.registeredProviders
                    .first { $0.id == id }?.isEnabledByDefault ?? true
                return self.preferences.isProviderEnabled(id, defaultEnabled: fallback)
            },
            isPermitted: { [weak self] kind in
                self?.permissions.status(of: kind) == .granted
            },
            wasSwitchedOnByHand: { [weak self] id in
                self?.preferences.providerWasSwitchedOnByHand(id) ?? false
            }
        )
    }

    /// Where Ledge is, when that is somewhere worth putting in the
    /// Accessibility list.
    ///
    /// Nil from a disk image or a translocated path. An entry made from either
    /// grants a copy that disappears when the image is ejected or the quarantine
    /// copy is cleaned up, and the list then shows Ledge switched on while
    /// nothing works — the exact state the guide's drag exists to get somebody
    /// out of. The guide says to move Ledge to Applications instead.
    private static func appLocationToOffer() -> String? {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        guard !path.hasPrefix("/Volumes/") else { return nil }
        guard !path.contains("/AppTranslocation/") else { return nil }
        return path
    }

    /// Tears everything down.
    ///
    /// Every piece below owns something the app does not: a timer retained by
    /// the run loop, a local event monitor, a CoreAudio listener registration,
    /// an event tap held by the main run loop. None of them are released by
    /// simply dropping this object, so there has to be an explicit path — and
    /// something has to call it.
    public func stop() {
        notesSelfTest?.cancel()
        notesSelfTest = nil
        notesWindow.tearDown()
        greeting?.cancel()
        greeting = nil
        presentation.greeting = false
        // A pending pause-linger would otherwise fire nowPlayingChanged into a
        // torn-down coordinator and re-arm fresh timers after cancelAll.
        companionLinger?.cancel()
        companionLinger = nil
        briefRest?.cancel()
        briefRest = nil
        presentation.farewell = nil
        restingHold = false
        parkedHUDCheck?.cancel()
        parkedHUDCheck = nil
        stopWatchingForPermission()
        // A window closing because Ledge is going away is not an answer to
        // the tour. It is the one case the tour *should* come back from.
        onboarding.appIsQuitting()
        tourListeners.removeAll()
        attempt = nil
        handoffCard.clear()
        preferences.onReset = {}
        focusBaseline?.stopWatching()
        focusBaseline = nil
        dormancy.clear()
        presentation.screensAreDark = false
        satelliteDismiss?.cancel()
        satelliteDismiss = nil
        parkedSatellite = nil
        duoHandBack = nil
        lastOrderFrozen = false
        screenshots.stopWatching()
        displayPanels.tearDownAll()
        hoverTracker?.stop()
        hoverTracker = nil
        gestures.stop()
        activities.stop()
        // *After* the providers, not before: emptying the queue while a
        // provider could still submit left the new work behind it. This is the
        // mid-session reset, which discards on purpose — the quit path goes
        // through `flushPendingWork`, which delivers instead.
        deviceObservations.invalidate()
        hud.stop()
        effects.cancelAll()

        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
        for token in distributedTokens {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        distributedTokens.removeAll()
    }

    // MARK: - Events

    /// The single entry point into the state machine.
    /// One event, in three parts: what has to be settled before the
    /// reducer sees it, what follows from every event whether or not the
    /// phase moved, and what only a phase change means.
    ///
    /// The order of all three is load-bearing — several of the comments
    /// below are about things that broke when something ran a step too
    /// early or too late — so this reads as the sequence it is.
    private func send(_ event: NotchEvent) {
        settleBeforeReducing(event)

        let previous = state.phase
        let produced = NotchReducer.reduce(&state, event)
        effects.run(produced)

        followEveryEvent(event)

        // Every event and every phase it produced. The one trace that makes a
        // report like "it did not react at first" answerable: whether the
        // event arrived at all, and what the island decided to do with it.
        if DebugSwitches.tracing("state") {
            Self.log.notice("""
                state: \(String(describing: event), privacy: .public) \
                \(previous.rawValue, privacy: .public) -> \(self.state.phase.rawValue, privacy: .public)
                """)
        }

        guard state.phase != previous else { return }
        followPhaseChange(from: previous, event: event)
    }

    /// Fixups the reducer must not see stale: a severed drag, a farewell
    /// that has to hand its borrowed flag back, the pointer's position at
    /// the moment a readout was asked for.
    private func settleBeforeReducing(_ event: NotchEvent) {
        // A collapse can sever a slider drag without its onEnded ever firing —
        // the hosting view is torn down when a display unplugs or repositions
        // mid-drag. Left latched, the flag suppressed every hover exit forever.
        if case .forceCollapse = event {
            isAdjustingHUD = false
            // A farewell cut short must give `hasNowPlaying` back before the
            // rebuild keeps it: left borrowed, the collapse settled into a
            // companion drawing the departed card until the next real fact.
            endFarewell()
            parkedSatellite = nil
            // The rebuilt state wipes `isHovering`, but the tracker's inside
            // key survives — a cursor already on the notch never re-fires an
            // entry, so nothing would restore the truth. Left desynced, the
            // next click pinned a card whose release timer then closed it
            // under a live cursor (and LEDGE_FORCE_EXPANDED self-closed).
            Task { @MainActor [weak self] in
                guard let self else { return }
                let key = self.currentDisplayUnderCursor()
                self.hoverTracker?.resync(to: key)
                if self.state.isHovering != (key != nil) {
                    self.send(.hoverChanged(key != nil))
                }
            }
        }

        // A dismissal ends the farewell too: swiping a card away must not
        // leave its ghost resting out the window — nor re-seat a satellite
        // whose card was just thrown out.
        if case .dismissed = event {
            endFarewell()
            parkedSatellite = nil
        }

        // Where the pointer sat when the HUD came up, so a hold under a
        // pointer that never moves can be told from a genuine adjustment. A
        // repeat press restarts the HUD timer, so a pending parked check must
        // not retire the extended readout early — the restarted timer re-arms it.
        if case .hudRequested = event {
            parkedHUDCheck?.cancel()
            parkedHUDCheck = nil
            if state.phase != .hud { hudPointerAtRequest = NSEvent.mouseLocation }
        }

    }

    /// True after every event, phase change or not: a guest can arrive and
    /// leave without the phase moving at all.
    private func followEveryEvent(_ event: NotchEvent) {

        // The HUD's own timer yields to a hover — held open for adjustment.
        // But a pointer merely *parked* on the notch when the key was pressed
        // is no adjustment, and the readout would otherwise stand until the
        // mouse next moved: check it is still exactly where it was, give it a
        // second chance to move, then release the hold.
        //
        // Two ways into the hold: the HUD timer firing under a hover, and a
        // hover *arriving* while the HUD is up — a pointer parked in the ear
        // zone beside an idle cutout only becomes "hovering" once the readout
        // widens the entry region, and that entry cancels the HUD timer, so
        // the first path would never fire for it.
        let heldHUD = state.phase == .hud && state.isHovering && !isAdjustingHUD
        switch event {
        case .timerFired(.hud) where heldHUD, .hoverChanged(true) where heldHUD:
            scheduleParkedHUDRelease()
        default:
            break
        }

        // The HUD reads this to widen into a draggable slider, and a hover can
        // change without the phase changing (holding a HUD open), so it is
        // mirrored before the phase guard below.
        presentation.isHovering = state.isHovering

        // The self-view's minute only runs while the pointer is away, and
        // this is the one place that knows. Told on every event rather than
        // on a phase change, because the pointer leaving a held-open card
        // changes no phase at all — that is the whole point of the hold.
        selfView.pointerChanged(inside: state.isHovering, now: Self.selfViewClock())

        // A full HUD is a guest too — it borrows the whole compact view and
        // owes the track it interrupted the island back. Checked on every
        // event rather than only on a phase change, since a guest can leave
        // without the phase moving at all.
        flushRestingRelease()

        // Populate the sound panel's output list exactly once per opening, so
        // the device enumeration never runs on a per-tick hover path.
        let hudHovered = state.phase == .hud && state.isHovering
        if hudHovered != wasHudHovered {
            wasHudHovered = hudHovered
            presentation.hudOutputs = hudHovered ? currentOutputs() : []
            // Same one-shot rule for displays: enumerating screens per hover
            // tick would be wasteful, and the set cannot change mid-hover
            // without a reconfiguration that redraws anyway.
            presentation.hudDisplays = hudHovered ? hud.brightnessDisplays() : []
        }

    }

    /// Whether a phase is one where the notch is open under the pointer.
    private static func isOpen(_ phase: NotchPhase) -> Bool {
        phase == .hover || phase == .expanded
    }

    /// Only when the island actually moved between phases.
    private func followPhaseChange(from previous: NotchPhase, event: NotchEvent) {
        // The tour's two do-it steps watch the real notch. Only the open and
        // close a *person* caused: a peek retiring is the notch finishing
        // something of its own, and crediting that to the reader would tell
        // them they did something they did not do.
        if Self.isOpen(state.phase), !Self.isOpen(previous) {
            tellTheTour(.opened)
        } else if Self.isOpen(previous), !Self.isOpen(state.phase) {
            tellTheTour(.closed)
        }
        // A slider drag lives on an open surface — the Levels card, the route
        // menu, the widened HUD. When the phase leaves all of them (a pin
        // release dismissing the card mid-drag, a peek), the gesture's view is
        // torn down and its onEnded never fires; left latched, the flag
        // swallowed every hover exit from then on. Settle it on the next turn,
        // outside this transaction.
        let openSurface = state.phase == .hover || state.phase == .expanded || state.phase == .hud
        if isAdjustingHUD, !openSurface {
            Task { @MainActor [weak self] in self?.setHUDDragging(false) }
        }
        // The card is gone — collapsed by a display change, a shut lid, a
        // swipe, a click. Whatever closed it, the camera goes with it: a
        // picture nobody can see is a camera light nobody can explain.
        //
        // On the next turn, like the drag above it: letting go sends an event
        // of its own, and sending one from inside the reducer's own follow-up
        // is a reducer running inside a reducer.
        if !openSurface {
            Task { @MainActor [weak self] in self?.selfView.cardWentAway() }
        }
        // The satellite belongs to the resting companion alone; any phase
        // movement (hover, peek, the full HUD) supersedes it. An *open* is a
        // visit rather than an eviction, though: the tenant is parked while
        // the card shows and re-seated when the companion returns. Any other
        // movement — a peek, the HUD, idle — drops the parked tenant too.
        let opening = state.phase == .hover || state.phase == .expanded
        // A readout opened by hovering the ear is a visit like any other: the
        // ear it came from is still the ear it belongs to, so its tenant is
        // parked for the duration rather than wiped. Without this the notch
        // came back from the panel as bare music, and the readout the user had
        // just been adjusting was simply gone.
        let visiting = opening || (state.phase == .hud && state.hudFromCompanion)
        // Opening the stack is when a stale shelf tile would be seen: a file
        // trashed or renamed while Ledge ran stayed on the shelf until the
        // next launch. One stat per item, only on open.
        if opening, previous != .hover, previous != .expanded {
            shelf.pruneMissing()
            // Screenshots whose day is up go before anyone sees them, rather
            // than on a timer nobody is watching.
            shelf.pruneExpired()
        }
        if previous == .companion, visiting, let content = presentation.hudSatellite {
            parkedSatellite = (content, satelliteSourceID, satellitePriority)
        }
        clearSatellite()
        presentation.phase = state.phase
        if state.phase == .companion, let parked = parkedSatellite {
            parkedSatellite = nil
            showSatellite(refreshedTenant(parked.content), source: parked.source, priority: parked.priority)
        } else if !visiting {
            parkedSatellite = nil
        }
        // The duo visit's selection hands back when the stack closes: only if
        // the trailing card is still the selection (cycling away inside the
        // open stack is a deliberate move and keeps), and only to a card that
        // still exists.
        if !opening, previous == .hover || previous == .expanded,
           let handBack = duoHandBack {
            duoHandBack = nil
            if presentation.selected?.id == handBack.target,
               activities.activity(withID: handBack.prior) != nil {
                activities.select(handBack.prior)
            }
        }
        // The flashed card belongs to the peek alone; a stale one would
        // redirect the *next* peek to the wrong activity.
        if state.phase != .peek {
            presentation.peeked = nil
            // The shape sits back down with the peek that raised it.
            presentation.announcement = nil
        }
        // The menu only exists inside an open card. Left set after a collapse,
        // its row count would keep the hit region sized for a menu that is not
        // on screen — a strip of invisible window swallowing clicks, which is
        // what made the notch feel stuck.
        if state.phase != .hover && state.phase != .expanded {
            presentation.routePickerRows = 0
        }
        // The interactive region grows and shrinks with the phase, so the
        // click-through decision has to be re-made whenever it changes.
        updateInteractivity()
        // Opening the stack refreshes a stale weather reading: the user may
        // cycle to the card a beat later, and "Updated 40m ago" on a
        // glanceable surface reads as neglect. Stale-guarded, so flicking
        // the notch open repeatedly costs nothing.
        if state.phase == .hover || state.phase == .expanded {
            activities.refreshWeatherIfStale(olderThan: 5 * 60)
        }
        // Order freezes while the open stack is under the cursor and re-ranks
        // in one motion when it closes. A HUD that owes the stack a restore
        // keeps the freeze: glancing at the volume and coming back must not
        // land on reordered cards.
        let stackVisible = state.phase == .hover || state.phase == .expanded
        let stackSuspended = state.phase == .hud
            && (state.suspended == .hover || state.suspended == .expanded)
        // A peek with the cursor still inside restores straight to .hover when
        // its timer fires — the stack is coming right back, so the freeze must
        // ride through, or a peek arriving over a HUD becomes a side door that
        // flushes the deferred re-rank under a stationary cursor.
        let stackReturning = state.phase == .peek && state.isHovering
        setOrderFrozenIfChanged(stackVisible || stackSuspended || stackReturning)
        // Any stage clearing back to rest — a peek or HUD retiring on its
        // timer, the user walking away from an open stack, an abandoned pin
        // releasing — hands the turn to the next queued entry: it arrived
        // unseen and is still owed its moment. Only an explicit dismissal
        // (swipe, click-close, forceCollapse) means "stop showing me things"
        // and empties the backlog. Each queued entry is re-admitted through
        // the same tests as a fresh arrival (TTL, Focus quiet, still on the
        // queue) and dropped once stale.
        //
        // The dismiss quiet-window upstream leans on expiring providers
        // publishing *transitions only* (they all do today); a steadily
        // republishing expiring provider would silently defeat it.
        let stageCleared: Bool
        switch event {
        case .timerFired(.peek): stageCleared = previous == .peek
        case .timerFired(.hud), .hudReleased: stageCleared = previous == .hud
        case .hoverChanged, .timerFired(.pinRelease):
            // Walking away from an open stack clears the stage too: entries
            // queued *while* it was open arrived unseen and are still owed
            // their turn — the old rule treated the exit as "user took the
            // stage" and silently emptied the backlog.
            stageCleared = previous == .hover || previous == .expanded
        default: stageCleared = false
        }
        if stageCleared, state.phase == .idle || state.phase == .companion {
            let now = Date().timeIntervalSinceReferenceDate
            while !pendingPeeks.isEmpty {
                let entry = pendingPeeks.removeFirst()
                guard now - entry.at < Self.pendingPeekLifetime,
                      admitPeek(kind: entry.id.kind, byUser: entry.byUser),
                      // Gone from the queue (expired, dismissed) means gone:
                      // peeking anyway flashed whatever card happened to be
                      // selected — the exact wrong-card bug peeked exists to
                      // prevent. The next queued entry gets its chance.
                      activities.activity(withID: entry.id) != nil
                else { continue }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.state.phase == .idle || self.state.phase == .companion else {
                        // A direct arrival took the stage in the gap between
                        // the drain and this Task; the queued entry keeps its
                        // turn instead of dying silently.
                        self.pendingPeeks.insert(entry, at: 0)
                        return
                    }
                    // Re-fetched in the gap too — and if it vanished in these
                    // few milliseconds, there is nothing left to announce.
                    guard let card = self.activities.activity(withID: entry.id) else { return }
                    self.presentation.peeked = card
                    // A queued announcement is still an announcement when its
                    // turn comes: waiting for the stage must not demote it to
                    // a whisper.
                    let announcement = Self.announcement(for: card)
                    self.presentation.announcement = announcement
                    self.send(.peekRequested(
                        announcement == nil ? self.preferences.peekDuration : NotchAnnouncement.duration
                    ))
                }
                break
            }
        } else if event == .dismissed || event == .forceCollapse
            || (event == .clicked && previous == .expanded
                && (state.phase == .idle || state.phase == .companion)) {
            // "Stop showing me things" empties the backlog — the swipe, a
            // collapse, and click-closing a pinned card alike; everything
            // else lets the TTL decide. Without the click case the two ways
            // of closing the same card disagreed about the queue's fate.
            pendingPeeks.removeAll()
        }
        Self.log.debug("""
            phase: \(previous.rawValue, privacy: .public) -> \
            \(self.state.phase.rawValue, privacy: .public) \
            (\(String(describing: event), privacy: .public))
            """)
    }

    /// Shown briefly, without stealing focus. Used by later milestones when an
    /// activity arrives; wired now so the phase is exercised.
    public func peek() {
        // Debug hook: flash whatever is selected, but never a stale peeked
        // card left by an earlier announcement.
        presentation.peeked = nil
        send(.peekRequested(preferences.peekDuration))
    }

    public func collapse() {
        send(.forceCollapse)
    }

    // MARK: - Hover

    private func startHoverTracking() {
        let tracker = HoverTracker<CGDirectDisplayID>(
            closedRegions: { [weak self] in self?.closedRegions() ?? [] },
            openRegion: { [weak self] key in self?.openRegion(key) },
            openDelay: { [weak self] in self?.preferences.hoverOpenDelay ?? 0 },
            closeDelay: { [weak self] in self?.preferences.hoverCloseDelay ?? 0 },
            onInsideChanged: { [weak self] key in
                guard let self else { return }
                // A drag in flight owns the interaction: the slider must keep
                // receiving events even when the cursor slips off the shape
                // mid-slide, so exits are ignored until the drag ends.
                if self.isAdjustingHUD && key == nil { return }
                // A pinned card stays on screen for its grace period after the
                // cursor walks away. Going click-through there left it visible
                // but dead: clicks landed on whatever was behind it, and the
                // click-again-to-close toggle stopped working. The pin-release
                // timer changes the phase, which re-runs this properly.
                // Interactivity follows the cursor immediately, ahead of the
                // debounced phase change, so a click never lands in the gap.
                // The pinned rule lives in `interactiveKey()`, shared with
                // every other caller, so a phase change cannot undo it.
                self.applyInteractive(key ?? self.interactiveKey())
            },
            onSettled: { [weak self] key in
                guard let self else { return }
                // No expand-on-hover gate here: the event stream must always
                // flow (isHovering feeds clicks and the pin release), and the
                // reducer itself declines to open when the preference is off.
                // Swallowing events at this level left pinned cards open
                // forever and made clicks unable to open the overlay.
                if self.isAdjustingHUD && key == nil { return }
                // Opening shows what the compact view was showing. Resting in
                // the companion draws the music while the *selection* may be
                // something else entirely — the calendar outranks it — so
                // hovering used to open whatever topped the queue rather than
                // the thing under the pointer.
                if let key {
                    // Whatever the ears are showing is what the pointer is
                    // pointing at, so that is what opens. This used to be a
                    // hand-written guess — playing music, else a running timer
                    // — which left paused music, a meeting inside the hour and
                    // a card mid-farewell falling through to whatever happened
                    // to be selected: hover the paused track, get the calendar.
                    if self.state.phase == .companion {
                        // The ears are one surface but not one subject. While a
                        // duo rests, the trailing side belongs to the satellite
                        // and asks for its card; the cutout and leading ear ask
                        // for the resident's.
                        if let readout = self.satelliteReadout(on: key) {
                            // A level readout in the ear opens the panel that
                            // readout belongs to — the same rows the full-width
                            // HUD opens when the pointer reaches it. It used to
                            // open the Levels card instead: press the brightness
                            // key, get a card that also does sound.
                            self.presentation.hud = readout
                            self.send(.hudRequested(self.preferences.hudDuration, fromCompanion: true))
                        } else if let target = self.trailingDuoTarget(on: key) {
                            if let prior = self.presentation.selected?.id, prior != target {
                                self.duoHandBack = (target, prior)
                            }
                            self.activities.select(target)
                        } else if let shown = self.restingContent() {
                            self.activities.select(shown.id)
                        }
                    } else if self.state.phase == .peek, let peeked = self.presentation.peeked {
                        // An announcement is on screen; opening it is the only
                        // sensible answer to a pointer arriving on it.
                        self.activities.select(peeked.id)
                    }
                }
                // The four-second farewell: walking away keeps the card you
                // were reading in the ears. With no resident at all, the same
                // window holds the phase open and the island closes after it.
                // A *live* resident — playing music, a ticking timer, an
                // imminent event — is never overpassed, though: leaving the
                // weather card while a track plays hands the ears straight
                // back to the music, and the farewell only fires for cards
                // walked away from over a quiet island (or bounded lingerers
                // like paused music, which the farewell may still front-run).
                // Never for a pinned card (the pin release owns that); a
                // dismissal or collapse clears it.
                let leavingOpenIsland = key == nil
                    && (self.state.phase == .hover || self.state.phase == .expanded)
                let farewellFor: Activity? = {
                    guard leavingOpenIsland, !self.state.isPinned,
                          let leaving = self.presentation.selected,
                          Self.deservesFarewell(leaving),
                          self.liveResident == nil
                    else { return nil }
                    return leaving
                }()
                // The linger used to be forfeited here: the ears had been
                // given to a card, so the paused track did not get them back.
                // That made the two minutes mean "two minutes of not touching
                // the notch", and opening the weather for five seconds cost
                // the track the rest of them. The clock runs from the pause
                // and nothing else, so closing the island hands the ears back
                // to whatever is still inside its own lifetime.
                if let leaving = farewellFor {
                    self.presentation.farewell = leaving
                    if !self.state.hasNowPlaying {
                        self.send(.nowPlayingChanged(true))
                    }
                    self.briefRest?.cancel()
                    self.briefRest = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(4))
                        guard let self, !Task.isCancelled else { return }
                        self.briefRest = nil
                        self.presentation.farewell = nil
                        // Hand back the resting *truth*: a resident inside
                        // its linger takes the island; anything else — a
                        // paused track whose linger already ran out included
                        // — closes it.
                        self.send(.nowPlayingChanged(self.restingHold))
                    }
                }
                self.send(.hoverChanged(key != nil))
            }
        )
        tracker.start()
        hoverTracker = tracker
    }

    /// What the ears are drawing right now, by the same rule the overlay uses.
    ///
    /// The precedence lives in `CompactRest` so the view and this cannot
    /// disagree: farewell, playing music, a running timer, an imminent
    /// meeting, paused music inside its linger, then the card last read.
    private func restingContent() -> Activity? {
        let playing: Activity? = {
            guard let activity = presentation.nowPlaying, activity.restsInEars else { return nil }
            return activity
        }()
        let runningTimer: Activity? = {
            guard let session = presentation.timerSession,
                  case .timer(let payload) = session.payload,
                  !payload.isIdle
            else { return nil }
            return session
        }()
        return CompactRest.resolve(
            farewell: presentation.farewell,
            playingNowPlaying: playing,
            runningTimer: runningTimer,
            closeEvent: presentation.closeEvent,
            nowPlaying: presentation.lingeringNowPlaying,
            selected: presentation.selected
        )
    }

    /// The card the trailing side of a resting duo opens, if the cursor is
    /// there and a satellite tenant holds the seat. Nil means "no duo under
    /// the pointer" and the caller falls through to the resident's card.
    ///
    /// The tenant ladder mirrors `SatelliteArbiter.resolve` exactly — the
    /// transient readout, then the timer while music keeps the island, then
    /// the recording dot — so what opens is always what the seat is drawing.
    /// The satellite is a hardware-notch trick (the pill has no split), and a
    /// target whose activity has left the queue answers nil rather than
    /// letting `select` no-op into opening the wrong card.
    private func trailingDuoTarget(on key: CGDirectDisplayID) -> ActivityID? {
        guard let controller = displayPanels.controller(for: key),
              controller.geometry.isHardwareNotch,
              let regions = controller.compactRegions(for: restingPhase)
        else { return nil }
        // The satellite's own rectangle first, then the island's own thirds.
        // Measuring the thirds from a box that included the satellite moved
        // the assumed cutout by half the gap, so a pointer on the island's
        // trailing ear could read as the cutout and open nothing.
        let zone = regions.zone(
            at: NSEvent.mouseLocation,
            cutoutWidth: controller.geometry.notchSize.width
        )
        guard zone == .trailing || zone == .satellite else { return nil }

        let musicIsMainIsland: Bool = {
            guard let playing = presentation.nowPlaying,
                  case .nowPlaying(let payload) = playing.payload
            else { return false }
            return payload.isPlaying
        }()

        let candidate: ActivityID?
        if presentation.hudSatellite != nil {
            candidate = satelliteSourceID
        } else if let session = presentation.timerSession,
                  case .timer(let payload) = session.payload,
                  !payload.isIdle, musicIsMainIsland {
            candidate = session.id
        } else if let privacy = presentation.privacyActive,
                  case .privacy(let payload) = privacy.payload,
                  payload.cameraActive || payload.micActive {
            candidate = privacy.id
        } else {
            candidate = nil
        }
        guard let candidate, activities.activity(withID: candidate) != nil else { return nil }
        return candidate
    }

    /// Every display's resting region, in the panels' own (notched-first) order
    /// so the hit-test scan is deterministic.
    ///
    /// The *drawn* resting shape, not the idle rect: the companion, a peek and
    /// the HUD all show 53pt ears beyond the cutout on every display, and an
    /// entry region narrower than the pixels meant a cursor arriving straight
    /// on the album art or the level bar never registered — the panel stayed
    /// click-through and the HUD never widened until the pointer crossed the
    /// idle-sized centre.
    /// The phase the shape is resting at, for the purpose of where it answers
    /// the pointer: an open card demotes to whatever it would show if the
    /// cursor left.
    private var restingPhase: NotchPhase {
        switch presentation.phase {
        case .companion, .peek, .hud: presentation.phase
        case .hover, .expanded: demotedRestingPhase
        case .idle: .idle
        }
    }

    private func closedRegions() -> [(key: CGDirectDisplayID, rect: CGRect)] {
        let resting = restingPhase
        // The display whose overlay is drawn *open* — a hovered/pinned card,
        // or the widened HUD panel — offers its whole drawn shape as the entry
        // region, not the demoted strip. After an exit the tracker holds no
        // current key, so the sticky branch cannot answer; without this a
        // pointer overshooting a card's bottom edge and coming straight back
        // onto a button was invisible: the card stayed click-through for the
        // close delay and then closed under the cursor, and a pinned card's
        // release timer was never cancelled by the return.
        let openDisplay = drawnOpenDisplay
        return displayPanels.all.flatMap { controller -> [(key: CGDirectDisplayID, rect: CGRect)] in
            if let openDisplay, controller.displayID == openDisplay,
               let open = openRegion(openDisplay) {
                return [(controller.displayID, open)]
            }
            // The satellite is a second rectangle under the same display, not
            // a bigger one: the pointer answers on the island and on the
            // circle, and over the gap between them it is on the desktop.
            guard let regions = controller.compactRegions(for: resting) else { return [] }
            return regions.rects.map { (controller.displayID, $0) }
        }
    }

    /// Every display's *resting* region as if nothing transient were up —
    /// what the island would offer the pointer with no HUD widening it.
    private func restingRegions() -> [(key: CGDirectDisplayID, rect: CGRect)] {
        let resting = demotedRestingPhase
        return displayPanels.all.compactMap { controller in
            controller.shapeRect(for: resting).map { (controller.displayID, $0) }
        }
    }

    /// The resting shape behind an open or transient phase: the companion
    /// only if something is actually drawn resting.
    private var demotedRestingPhase: NotchPhase {
        // The demotion test must be the same one the overlay uses (playing
        // music or a running timer) — `state.hasNowPlaying` also counts
        // *paused* music in its linger, which the overlay draws as idle; the
        // mismatch put an invisible companion-sized entry strip on a display
        // drawing nothing.
        let playing: Bool = {
            guard let activity = presentation.nowPlaying,
                  case .nowPlaying(let payload) = activity.payload
            else { return false }
            return payload.isPlaying
        }()
        let timerRunning: Bool = {
            guard let session = presentation.timerSession,
                  case .timer(let payload) = session.payload
            else { return false }
            return !payload.isIdle
        }()
        return (playing || timerRunning) ? .companion : .idle
    }

    /// The display drawing an open overlay right now, if any: the hover owner
    /// while a card is up (hovered or pinned) or the HUD panel is widened.
    private var drawnOpenDisplay: CGDirectDisplayID? {
        let open = state.phase == .hover || state.phase == .expanded
            || (state.phase == .hud && state.isHovering)
        guard open else { return nil }
        return presentation.hoveredDisplayID.map { CGDirectDisplayID($0) }
    }

    /// The grown region of one display's overlay, for the sticky hit test.
    private func openRegion(_ key: CGDirectDisplayID) -> CGRect? {
        displayPanels.controller(for: key)?.shapeRect(
            for: state.phase,
            hudHovered: state.phase == .hud && state.isHovering,
            hudExtraHeight: hudExtraHeight
        )
    }

    /// Exactly one panel may be interactive: any other would turn that
    /// display's full-width top strip into an invisible click-eater.
    /// Repoints the hover owner when the display it names goes away.
    ///
    /// `applyInteractive` deliberately never clears `hoveredDisplayID` — see the
    /// note there — which leaves it naming a display that may since have been
    /// unplugged, or dropped when "show on all displays" was switched off. No
    /// live panel then matches it, so every panel treats the hover as somebody
    /// else's and a pinned card becomes invisible on the only screen left.
    /// Repointed rather than set to nil, because nil means "every panel
    /// matches", which is the flicker this stickiness exists to prevent.
    private func pruneHoveredDisplay() {
        guard let current = presentation.hoveredDisplayID else { return }
        guard !displayPanels.order.contains(CGDirectDisplayID(current)) else { return }
        presentation.hoveredDisplayID = displayPanels.order.first
    }

    private func applyInteractive(_ key: CGDirectDisplayID?) {
        for controller in displayPanels.all {
            controller.setInteractive(controller.displayID == key)
        }
        // Publish which display owns the hover, so only that panel opens.
        //
        // Only ever *set*, never cleared to nil here. `onInsideChanged` fires
        // the moment the cursor leaves, but the phase change behind it is
        // debounced by `hoverCloseDelay` — so clearing on exit left a window
        // where the phase was still `.hover` while no display claimed it, and
        // `nil` means "every panel matches". Both screens opened for that
        // window, which is the flicker. The last owner stays the owner until
        // someone else takes it; the value is ignored in every non-pointer
        // phase anyway.
        if let key { presentation.hoveredDisplayID = key }
    }

    /// True while the pointer is dragging the HUD's slider. Hover exits are
    /// suppressed for its duration; when it ends, the hover state is re-read so
    /// a drag that finished off the shape still collapses cleanly.
    private var isAdjustingHUD = false

    /// The pointer's location when the HUD was raised, and the pending
    /// second-chance check for a hold under a parked pointer.
    private var hudPointerAtRequest: CGPoint?
    private var parkedHUDCheck: DispatchWorkItem?

    /// How far the pointer may drift and still count as parked. Real reaching
    /// for the slider moves tens of points; sensor jitter moves none.
    private static let parkedTolerance: CGFloat = 3

    private var pointerIsParked: Bool {
        guard let origin = hudPointerAtRequest else { return false }
        let now = NSEvent.mouseLocation
        return abs(now.x - origin.x) <= Self.parkedTolerance
            && abs(now.y - origin.y) <= Self.parkedTolerance
    }

    private func scheduleParkedHUDRelease() {
        parkedHUDCheck?.cancel()
        parkedHUDCheck = nil
        guard pointerIsParked else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.parkedHUDCheck = nil
                // Still a held HUD, still nobody dragging, still not moved
                // — then it was never a hover, and the readout retires. Any
                // movement in the grace means the user reached for it.
                guard self.state.phase == .hud, self.state.isHovering,
                      !self.isAdjustingHUD, self.pointerIsParked
                else { return }
                // Was this a hover at all before the readout widened the
                // island? A pointer parked over the cutout is on the notch in
                // any phase and keeps its hover (a card it had open comes
                // back). One parked in the ear zone only became "inside" when
                // the HUD grew under it — an artifact, not a hover: forget it,
                // or the retire would settle straight into an unasked-for card.
                let genuine = DisplayHitTest.hit(
                    point: NSEvent.mouseLocation,
                    current: nil as CGDirectDisplayID?,
                    currentOpenRegion: nil,
                    closedRegions: self.restingRegions()
                ) != nil
                if !genuine {
                    self.hoverTracker?.resync(to: nil)
                    self.send(.hoverChanged(false))
                }
                self.send(.hudReleased)
            }
        }
        parkedHUDCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func setHUDDragging(_ dragging: Bool) {
        guard dragging != isAdjustingHUD else { return }
        isAdjustingHUD = dragging
        guard !dragging else { return }
        // Drag over: settle to wherever the cursor actually is now — and tell
        // the tracker, whose own idea of "inside" went stale while its exits
        // were being swallowed. Without the resync it never fires the exit
        // for a cursor resting on the widened bar, and the readout stays
        // open and click-eating until the cursor recrosses the idle notch.
        let key = currentDisplayUnderCursor()
        hoverTracker?.resync(to: key)
        applyInteractive(key ?? interactiveKey())
        let inside = key != nil
        if state.isHovering != inside {
            send(.hoverChanged(inside))
        }
    }

    private func updateInteractivity() {
        applyInteractive(interactiveKey())
    }

    /// Which panel may take clicks: the one under the cursor — or, with
    /// nothing under it, the one drawing a pinned card, which stays clickable
    /// for its whole grace period. That second rule used to live only in the
    /// tracker's exit callback, so any phase change while the card was pinned
    /// and abandoned (a volume key, a peek) re-ran this and made every panel
    /// click-through: the card was plainly on screen and dead to clicks.
    private func interactiveKey() -> CGDirectDisplayID? {
        if let key = currentDisplayUnderCursor() { return key }
        if state.isPinned, state.phase == .expanded {
            return presentation.hoveredDisplayID.map { CGDirectDisplayID($0) }
        }
        return nil
    }

    /// Which display the cursor is on right now, by the same rule the tracker
    /// uses — so the two can never disagree.
    private func currentDisplayUnderCursor() -> CGDirectDisplayID? {
        // The sticky branch of the hit test needs the *grown* region, and this
        // used to pass nil for it — so the test matched only the idle notch
        // rect. With a card open and the cursor anywhere on its body, this
        // answered "no display", every panel was made click-through, and clicks
        // fell through to whatever was behind a card that was still plainly on
        // screen. The hover tracker re-applies only when its key *changes*, so
        // nothing corrected it until the cursor left the notch and came back.
        //
        // `hoveredDisplayID` is the same value the tracker stickies on, which
        // is what keeps the two from disagreeing.
        let current = presentation.hoveredDisplayID
            ?? displayPanels.order.first
        return DisplayHitTest.hit(
            point: NSEvent.mouseLocation,
            current: current,
            currentOpenRegion: current.flatMap { openRegion($0) },
            closedRegions: closedRegions()
        )
    }

    // MARK: - System

    /// Re-measure whenever the display setup changes or the machine wakes: the
    /// notch is gone, moved, or a different size after any of these.
    private func observeSystemChanges() {
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.log.notice("screen parameters changed — repositioning")
                self?.send(.forceCollapse)
                self?.displayPanels.scheduleReconcile()
            }
        })

        // Dark screens: nothing is visible, so nothing should poll. The hover
        // tracker (30 Hz) and the HUD's brightness watcher (2 Hz) stop while
        // the displays sleep or the screen is locked, and resume on wake. The
        // reducer state is left alone — a resting companion is still resting.
        for (name, asleep) in [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false),
        ] {
            observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreensDark(.displaysAsleep, asleep) }
            })
        }
        // The lock screen does not sleep the displays right away; it posts on
        // the distributed centre instead. Same treatment.
        // The lock screen does not sleep the displays right away, and they
        // wake again on their own while the session stays locked — which is
        // why this is its own reason rather than the same flag.
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedTokens.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreensDark(.sessionLocked, locked) }
            })
        }

        // Logging out, restarting or shutting down is not the user saying they
        // are finished with Keep Awake, so the session is left recorded as
        // running: a restart then ends it by boot id, and a logout resumes it
        // at the next login if its deadline is still ahead.
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.willPowerOff() }
        })

        // The deadline is an absolute time, so moving the clock moves how long
        // is left. The timer is re-armed rather than trusted — a timer that
        // fires early and quietly returns is how a session never ends at all.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSSystemClockDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepAwake?.clockDidChange() }
        })

        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.log.notice("woke from sleep — repositioning")
                self?.send(.forceCollapse)
                // The assertion is re-armed rather than assumed intact, and the
                // deadline is checked: sleeping through the end of a session is
                // the ordinary case, not the exception.
                self?.keepAwake?.systemDidWake()
                // A lid can close on one permission state and open on another.
                self?.revalidatePermissions()
                // The refresh timer runs on a suspending clock, so a night of
                // sleep leaves the weather card up to its full cadence stale
                // the moment the lid opens. Refresh the live instance — a
                // restart here retracted the standing card and discarded the
                // stale-but-valid reading while Wi-Fi was still coming back.
                self?.activities.refreshWeather()
                // Same suspending-clock exposure: the calendar's "wake when
                // the event enters its lead window" check owes its remaining
                // awake time after sleep — re-evaluate against the real clock.
                self?.activities.refreshCalendar()
                self?.displayPanels.scheduleReconcile()
                // A network outage blacklists every cover fetched during it,
                // permanently. Waking is the cheapest reliable signal that the
                // network may have come back.
                self?.artworkLoader.forgetFailures()
            }
        })
    }

    private func applyDebugOverrides() {

        // Black-on-dark makes the silhouette's edges impossible to judge; the
        // tint is how you actually see what the shape is doing.
        if DebugSwitches.isOn("LEDGE_DEBUG_TINT") {
            // Transient: persisted, this left the shape red on every later
            // normal launch until manually un-toggled.
            preferences.setDebugTintTransient(true)
        }

        // Pins the overlay open so the expanded silhouette can be inspected
        // without a cursor parked on the notch.
        // The card the tour ends on, without sitting through the tour.
        if DebugSwitches.isOn("LEDGE_DEMO_WELCOME") {
            playWelcome()
        }

        if DebugSwitches.isOn("LEDGE_FORCE_EXPANDED") {
            send(.clicked)
        }

        // Starts a focus session at launch, so the music+timer satellite can
        // be reproduced without clicking through the ready card.
        if DebugSwitches.isOn("LEDGE_DEBUG_TIMER") {
            ensureTimerRunning()
            timerProviderRef?.startFocus()
        }
    }

    // MARK: - Settings

    /// - Parameter pane: which pane to open on, when the caller means a
    ///   particular one — the tour's "Choose Cards…" is a promise about where
    ///   the window opens. Nil keeps whatever the window was last showing.
    public func showSettings(pane: String? = nil) {
        // Never refuse to open: with no panel at all — a login item starting
        // with the lid shut — this used to return silently and the menu item
        // simply did nothing.
        let geometry = displayPanels.primary?.geometry
            ?? NSScreen.main.map(ScreenGeometry.measure)
            ?? .simulated(screenSize: CGSize(width: 1470, height: 956))

        if let settingsWindow {
            // Re-hosted only when the geometry actually changed, or when a
            // caller asked for a pane: the Appearance sliders' bounds come
            // from the display, but a rebuild also resets the view's @State —
            // reopening must not snap the selected pane back to the first tab
            // every time.
            if lastSettingsGeometry != geometry || pane != nil {
                lastSettingsGeometry = geometry
                settingsWindow.contentView = NSHostingView(
                    rootView: SettingsView(
                        preferences: preferences,
                        geometry: geometry,
                        actions: makeSettingsActions(),
                        model: settingsModel,
                        startPane: pane
                    )
                )
            }
            refreshSettingsModel()
            present(settingsWindow)
            return
        }
        lastSettingsGeometry = geometry

        let actions = makeSettingsActions()

        let window = NSWindow(
            // Must match the SwiftUI frame in `SettingsView`; seven tabs do not
            // fit the old 460pt width.
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ledge Settings"
        window.isReleasedWhenClosed = false
        refreshSettingsModel()
        window.contentView = NSHostingView(
            rootView: SettingsView(
                preferences: preferences,
                geometry: geometry,
                actions: actions,
                model: settingsModel,
                startPane: pane
            )
        )
        window.center()
        settingsWindow = window
        present(window)
    }

    /// The geometry the settings window was last built against.
    private var lastSettingsGeometry: NotchGeometry?

    /// Asks the app layer to run an update check. Sparkle's updater lives
    /// there, next to the bundle it updates; this is the only way in now that
    /// the menu bar is gone.
    public var onCheckForUpdates: () -> Void = {}
    public var canCheckForUpdates: () -> Bool = { false }

    /// Whether a check Ledge asked for is still running.
    ///
    /// Sparkle refuses a second check while one is out, and says so through
    /// `canCheckForUpdates`. That alone cannot drive a button: it is also
    /// false when there is no updater at all — in a preview, in a test, in a
    /// build without Sparkle — and the button would sit at "Checking…"
    /// forever. So the fact being tracked is "we started one and it has not
    /// come back", which is only ever true after a press.
    private var updateCheckInFlight = false

    /// Both permission entry points use the same window and grant lifecycle.
    private func requestPermission(_ kind: PermissionKind) {
        // Usually seeded at startup. Also establish a before-reading if an
        // explicit request is the first entry point, so its grant is a change.
        if lastPermissionSnapshot.isEmpty { revalidatePermissions() }
        standAsideForSystemUI()
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
            let status = await self.permissions.request(kind)
            // Update the snapshot as well as providers, so the next poll does
            // not treat this same answer as a second grant and restart again.
            self.revalidatePermissions()
            // Granting the calendar is the reason to switch the calendar card
            // on, and anybody who just allowed it did not do it to leave the
            // card hidden. About the answer rather than about the press, so
            // it happens whoever owns the attempt by now.
            if kind == .calendars, status == .granted {
                self.activities.setProvider("calendar", enabled: true)
                self.refreshSettingsModel()
            }
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
                let stillAsking = !kind.answersBeforeReturning && status == .notDetermined
                if stillAsking {
                    self.watchForPermission(kind) { [weak self] in
                        // Ownership decides the foreground too: a watch whose
                        // press has been overtaken must not pull the front
                        // back from whatever replaced it.
                        guard let self, self.attempt?.token == token else { return }
                        self.endedAttempt(token)
                        // The front comes back when the answer does, not
                        // before it.
                        self.reclaimFront()
                    }
                } else {
                    // Answered here, whichever way — including the answer
                    // "nothing changed", which is what macOS declining to
                    // prompt looks like from here. There is no return from
                    // System Settings to wait for, and standing aside for a
                    // dialog that has already closed left the window it was
                    // asked from sitting among other applications.
                    self.endedAttempt(token)
                    self.reclaimFront()
                }
            } else {
                self.watchForPermission(kind) { [weak self] in self?.endedAttempt(token) }
            }
        }
    }

    /// Whether anything on this side still needs the helper.
    ///
    /// Checked before the daemon is asked and again after it answers, so a
    /// session that began during the question is not unregistered out from
    /// under itself.
    @MainActor
    private func whatTheHelperStillOwes() -> KeepAwakeHelperRemoval? {
        guard let keepAwake else { return nil }
        if keepAwake.state.isRunning || keepAwake.lidReading.isLive { return .stillOwesWork }
        // A Start that has been admitted and is still being written is
        // invisible to both of the readings above: the provider is Ready
        // until the journal write lands. Removing the helper in that window
        // hands somebody a session that cannot be held through a shut lid.
        if keepAwake.isStarting { return .stillOwesWork }
        return nil
    }

    /// Whether a session may be started right now.
    ///
    /// The other half of the removal gate. Serialising removal against
    /// *itself* is not enough: a Start admitted while the daemon is being
    /// asked about its obligations would be allowed to proceed into a helper
    /// that is about to be unregistered.
    @MainActor
    var mayStartKeepAwake: Bool { keepAwakeOperation == nil }

    /// What Ledge is doing to the helper right now, if anything.
    ///
    /// On the coordinator rather than in the pane: the pane can be closed,
    /// reopened or rebuilt while a privileged operation is in flight, and a
    /// fresh view with no memory of it used to offer the same button again.
    private var keepAwakeOperation: KeepAwakeOperation?

    /// Takes the lid-closed helper back out, if it is safe to.
    ///
    /// The guard was written when the protocol was — three lines above the
    /// call it belongs to — and this button shipped for an hour without it,
    /// offered in red beside a running session. A daemon with a setting still
    /// to put back is the only thing that can put it back, and unregistering
    /// it there leaves a Mac that cannot sleep and nothing left able to fix
    /// it. That is the failure this entire feature is built around avoiding.
    @MainActor
    private func removeKeepAwakeHelper() async -> KeepAwakeHelperRemoval {
        // Only one of these at a time, and never while something is starting
        // a session. The removal has an await in the middle of it, and a
        // second press — or a Start arriving during that await — used to be
        // admitted alongside it.
        guard keepAwakeOperation == nil else {
            return .failed("Ledge is already working on the helper. Wait for that to finish.")
        }
        keepAwakeOperation = .removing
        settingsModel.keepAwakeOperation = .removing
        defer {
            keepAwakeOperation = nil
            settingsModel.keepAwakeOperation = nil
        }

        if let reason = whatTheHelperStillOwes() { return reason }

        // What the daemon says about work nobody here remembers — a hold from
        // a run that crashed, or the other build's. Its own answer, not an
        // inference from ours.
        // No client, but a registered daemon: fail closed. Client creation
        // needs the helper's requirement metadata, which a bundle can be
        // missing while the daemon is registered and holding something —
        // and "we could not ask" is not "there is nothing to ask about".
        if keepAwakeHelperClient == nil, KeepAwakeHelperInstall.current() != .notInstalled {
            return .failed(
                "Ledge can't reach the helper to ask whether it still has a setting to put back, "
                    + "so it left it alone."
            )
        }
        if let client = keepAwakeHelperClient {
            let status = await client.refreshStatus()
            // An answer, or nothing doing. A timeout, a disconnected helper
            // or any other failure answers nil, and nil used to fall straight
            // through to `unregister()` — removing the one thing that can put
            // a sleep setting back, at exactly the moment Ledge cannot say
            // whether it is holding one.
            guard let status else {
                return .failed(
                    "Ledge couldn't reach the helper to ask whether it still has a setting "
                        + "to put back, so it left it alone. Try again in a moment."
                )
            }
            guard status.mayUnregister else { return .stillOwesWork }
        }

        // Asked again on this side of the await: a session can have started
        // while the daemon was answering, and an answer about a minute ago
        // does not authorise unregistering underneath it.
        if let reason = whatTheHelperStillOwes() { return reason }

        switch KeepAwakeHelperSetup.unregister() {
        case .removed:
            refreshSettingsModel()
            await keepAwake?.refreshLid()
            return .removed
        case .refused(let why):
            refreshSettingsModel()
            return .failed(why)
        case .installed, .needsApproval:
            refreshSettingsModel()
            return .failed("macOS did not take the helper out.")
        }
    }

    private func makeSettingsActions() -> SettingsActions {
        SettingsActions(
            setLaunchAtLogin: { LoginItemService.setEnabled($0) },
            loginItemStatus: { LoginItemService.statusDescription },
            copyToClipboard: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            quit: { NSApp.terminate(nil) },
            checkForUpdates: { [weak self] in
                guard let self else { return }
                self.updateCheckInFlight = true
                self.onCheckForUpdates()
                self.refreshSettingsModel()
            },
            canCheckForUpdates: { [weak self] in self?.canCheckForUpdates() ?? false },
            runningApps: {
                // Dock apps and menu-bar apps, not the dozens of background
                // processes behind them: the roster is a list somebody picks
                // from, and a hundred-entry menu is not one.
                NSWorkspace.shared.runningApplications.compactMap { app in
                    guard app.activationPolicy != .prohibited,
                          let id = app.bundleIdentifier,
                          AgentRoster.isWritableDomain(id)
                    else { return nil }
                    return (id: id, name: app.localizedName ?? id)
                }
            },
            runningChromium: { RunningChromium.all() },
            installKeepAwakeHelper: { [weak self] in
                guard let self else { return .unavailable }
                // The same gate the removal takes: one privileged operation
                // at a time, held where a rebuilt pane can still see it.
                guard self.keepAwakeOperation == nil else {
                    return .refused("Ledge is already working on the helper.")
                }
                self.keepAwakeOperation = .settingUp
                self.settingsModel.keepAwakeOperation = .settingUp
                defer {
                    self.keepAwakeOperation = nil
                    self.settingsModel.keepAwakeOperation = nil
                }
                guard KeepAwakeHelperInstall.current() != .unsignedBuild else { return .unavailable }
                let outcome: KeepAwakeHelperSetupOutcome
                switch KeepAwakeHelperSetup.register() {
                case .installed: outcome = .installed
                case .needsApproval: outcome = .needsApproval
                case .removed: outcome = .unavailable
                case .refused(let why): outcome = .refused(why)
                }
                // The pane's own reading is a separate fact from the outcome
                // of this press, and it is the one the rest of the section is
                // drawn from.
                self.refreshSettingsModel()
                return outcome
            },
            showKeepAwakeHelperApproval: { KeepAwakeHelperSetup.showApproval() },
            removeKeepAwakeHelper: { [weak self] in
                guard let self else { return .failed("Ledge is shutting down.") }
                return await self.removeKeepAwakeHelper()
            },
            isAccessibilityTrusted: { MediaKeyInterceptor.isTrusted },
            requestPermission: { [weak self] kind in self?.requestPermission(kind) },
            openPermissionSettings: { [weak self] kind in
                guard let self else { return }
                self.standAsideForSystemUI()
                let token = self.beganAttempt(for: kind, handingOff: true)
                self.permissions.openSettings(for: kind)
                // However this ends — an answer, the window closing, the four
                // minutes running out — the row stops saying it is waiting
                // and the notch stops holding the lock.
                self.watchForPermission(kind) { [weak self] in self?.endedAttempt(token) }
            },
            // Opening the pane is a third moment worth re-reading at, and it
            // must act on what it finds rather than merely draw it: seeing
            // "Not granted" beside a provider that is still running would be
            // the settings window disagreeing with the app.
            refreshPermissions: { [weak self] in self?.revalidatePermissions() },
            openLoginItems: { KeepAwakeHelperSetup.showApproval() },
            setProviderEnabled: { [weak self] id, enabled in
                guard let self else { return }
                // Keep Awake is the one switch with work to do on the way off,
                // so it is the one switch whose order has to be kept. See
                // `KeepAwakeToggle`.
                guard id == "keep-awake" else {
                    self.activities.setProvider(id, enabled: enabled)
                    self.refreshSettingsModel()
                    return
                }
                self.keepAwakeToggle.set(enabled)
            },
            showOnboarding: { [weak self] in self?.showOnboarding() },
            openSource: { NSWorkspace.shared.open(Self.sourceURL) },
            chooseFocusFolder: { [weak self] in self?.chooseFocusFolder() },
            stopWaiting: { [weak self] in
                guard let self else { return }
                // The one way out that does not depend on System Settings
                // doing anything. Cancelling the watch runs its own ending,
                // which is what takes the row's spinner away.
                self.stopWatchingForPermission()
                self.endedCurrentAttempt()
                self.reclaimFront()
            },
            observeNotch: { [weak self] listener in
                self?.observeNotch(listener) ?? {}
            },
            tourStep: { [weak self] step in self?.tourStepChanged(step) },
            appTile: { [weak self] in
                guard let self, let location = self.settingsModel.appLocation else { return nil }
                return AnyView(AppTile(
                    url: URL(fileURLWithPath: location),
                    name: PermissionGuideCopy.tileName,
                    onDragEnded: { [weak self] outcome in
                        self?.settingsModel.appDragEnded = outcome
                    },
                    onCopyLocation: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(location, forType: .string)
                    }
                ))
            }
        )
    }

    /// An `.accessory` app is not in the activation order, so a plain
    /// `makeKeyAndOrderFront` can leave the window buried behind whatever the
    /// user was using. Ordering front regardless, then activating, is what
    /// actually brings it to the top.
    private func present(_ window: NSWindow) {
        // macOS refuses programmatic activation that is not backed by a user
        // event, so a window opened at launch, or while System Settings is
        // frontmost, lands *behind* whatever the user is looking at. For an
        // accessory app that is fatal: no Dock icon, no Cmd-Tab entry, no way
        // back to a window you cannot see.
        //
        // The tour floats for the same reason (`OnboardingPresenter.show`).
        // This used to float only under LEDGE_DEBUG, which compiles away in
        // release — so the one path that exists to prove the app started could
        // open behind Safari and prove nothing.
        //
        // It stays floating for as long as it is open, and that is deliberate.
        // A settings window that sinks behind other applications is merely
        // annoying for a normal app, and unusable for this one: an accessory
        // app has no Dock icon and no Cmd-Tab entry, so a buried window is a
        // window the user has to hunt for with Mission Control — and the times
        // it sinks are the worst possible ones, because granting a permission
        // means going to System Settings, which takes the front.
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.log.notice("settings window presented at \(window.frame.debugDescription, privacy: .public)")
    }

}


/// Lets a caller wait for whichever of two things finishes first.
///
/// A task group would say this more briefly, but the region-based isolation
/// checker cannot see through one whose child is main-actor isolated, and a
/// construct the compiler cannot check is not worth the brevity.
private actor FirstToFinish {

    private var hasFinished = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !hasFinished else { return }
        hasFinished = true
        let resumable = waiting
        waiting.removeAll()
        resumable.forEach { $0.resume() }
    }

    func wait() async {
        guard !hasFinished else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}
