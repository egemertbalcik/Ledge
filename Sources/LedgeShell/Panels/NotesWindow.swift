import AppKit
import LedgeCore
import LedgeSystem
import LedgeUI
import SwiftUI
import os

/// The window a note is written in.
///
/// Separate from `LedgePanel` in every way that matters. The notch panel must
/// never take focus — it would interrupt whatever the user is typing into. This
/// one has to take focus, because a window you cannot type into is not an
/// editor.
///
/// Measured, not assumed: a `.nonactivatingPanel` with `canBecomeKey` true
/// stops being the key window the moment another application activates, so
/// "show it without ever taking focus" is not available. What is available is
/// the arrangement Raycast settled on after years of getting it wrong in both
/// directions — take focus on the click that asks for it, and hand it straight
/// back on Escape without closing the window.
final class NotesPanel: NSPanel {

    /// The app that was in front when this window opened, so Escape can give
    /// the user back exactly what they were doing.
    var previousApp: NSRunningApplication?

    /// Told when Escape is pressed, so the controller can return focus.
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    /// Never main: this app is an accessory and has no main window of its own.
    override var canBecomeMain: Bool { false }

    /// Command-key equivalents, by hand.
    ///
    /// `NSApplication` dispatches `⌘C`, `⌘V`, `⌘Z` and the rest through
    /// `NSApp.mainMenu`, and this app has no menu at all — there is no Dock
    /// icon and no menu bar item, so `mainMenu` is nil for the whole life of
    /// the process. Measured: `performKeyEquivalent(⌘V)` returns false and
    /// nothing is pasted, while `sendAction(paste:)` works and the text view is
    /// right there in the responder chain. So the chain is fine; only the
    /// dispatch was missing. This supplies it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let shift = flags.contains(.shift)

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "w":
            // The system close button is hidden, so this is the keyboard way
            // out and it has to be wired by hand like the rest.
            requestClose()
            return true
        case "z":
            let selector = shift
                ? Selector(("redo:"))
                : Selector(("undo:"))
            return NSApp.sendAction(selector, to: nil, from: self)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Told to put the window away, for ⌘W.
    var onClose: (() -> Void)?

    private func requestClose() { onClose?() }

    override func cancelOperation(_ sender: Any?) {
        // Escape gives focus back; it does not close. Closing on Escape would
        // make a stray keystroke look like the note had been thrown away.
        onEscape?()
    }
}

/// Owns the one editor window.
///
/// One window, one note — the same decision Raycast made and documents: "Only
/// one note is visible at the time." A second window would need a second
/// answer for focus, for the birth animation, and for which note the card
/// should mark as open.
@MainActor
final class NotesWindowController {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "notes")

    /// The editor window's corner radius, shared with the animation so the
    /// blob lands as exactly the shape that replaces it.
    static let windowCornerRadius: CGFloat = 14

    private var panel: NotesPanel?
    private var hosting: NSHostingView<NotesEditorView>?
    private var closeObserver: (any NSObjectProtocol)?
    private var resignObserver: (any NSObjectProtocol)?

    private let store: NotesStore
    private let preferences: Preferences

    /// Told which note is open, or nil when the window closes.
    var onOpenNoteChanged: ((String?) -> Void)?

    /// Asks the island to play a note leaving it, at the rect the window is
    /// about to occupy. Returns whether a flight
    /// actually started — there is none without a notched panel to draw it in.
    var playBirth: ((CGRect) -> Bool)?
    var endBirth: (() -> Void)?

    private(set) var openNoteID: String?

    /// The model the editor binds to. Held here so the window can be shown and
    /// hidden without rebuilding the hosting view — rebuilding one resets
    /// SwiftUI state, which here would drop the selection and scroll position
    /// mid-sentence.
    private let model = NotesEditorModel()

    init(store: NotesStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
    }

    var isOpen: Bool { panel?.isVisible ?? false }

    private let opening = NotesOpeningRequest()

    func open(noteID: String) {
        let store = store
        opening.start(load: { await store.body(noteID) }) { [weak self] body in
            self?.present(body)
        }
    }

    func create() {
        let store = store
        opening.start(load: {
            let body = await store.create()
            if Task.isCancelled {
                await store.discardIfEmpty(body.id)
                return nil
            }
            return body
        }) { [weak self] body in self?.present(body) }
    }

    private func present(_ body: NoteBody) {
        let panel = panel ?? makePanel()
        model.load(body)
        updateTitle(from: body.text)
        openNoteID = body.id
        onOpenNoteChanged?(body.id)

        let landing = landingFrame(for: panel)
        let destinationScreen = notchScreen?() ?? NSScreen.main

        // Already on screen: nothing is being born, the note simply changes.
        guard !panel.isVisible else {
            // Switching notes must not undo the user's dragged window position.
            raise(panel)
            return
        }

        // The island plays the note coming out of its corner, and the window
        // appears only as that lands. The flight is drawn inside the notch
        // panel rather than by moving this window: a real window's frame is
        // committed by the WindowServer on its own schedule, which comes apart
        // from a SwiftUI spring at exactly the overshoot.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            // No flight, and no wait for one. Sleeping anyway would leave a
            // Reduce Motion user looking at nothing for half a second.
            panel.setFrame(landing, display: true)
            raise(panel)
            return
        }

        // A flight already running is already heading for the right rect, and
        // the note it carries is only ever read at the end. Starting a second
        // one resets the clock, so the blob snaps back to the island mid-air
        // and the window arrives a whole duration later than the click.
        guard flight == nil else { return }

        // Whether a flight actually began. The shell refuses one when there is
        // no notched panel to draw it in, or when the window would land outside
        // that panel — and waiting out the full duration for an animation that
        // never played means every note on a lid-closed Mac opens after a
        // second of nothing.
        guard playBirth?(landing) == true else {
            panel.setFrame(landing, display: true)
            raise(panel)
            return
        }

        birthToken &+= 1
        let token = birthToken
        flight = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(NotesBirth.duration)) }
            catch { return }
            guard let self, self.birthToken == token else { return }
            if let panel = self.panel {
                // Keep the chosen destination even if the pointer moved to a
                // second monitor. Recompute only when that screen is gone or
                // its usable bounds changed during the flight.
                let stillFits = destinationScreen.map { screen in
                    NSScreen.screens.contains(screen) && screen.visibleFrame.contains(landing)
                } ?? false
                panel.setFrame(stillFits ? landing : self.landingFrame(for: panel), display: true)
                self.raise(panel)
            }
            // One owned task covers both the flight and handoff. Closing can
            // cancel either part, and an old cleanup cannot erase a new birth.
            do { try await Task.sleep(for: .milliseconds(32)) }
            catch { return }
            guard self.birthToken == token else { return }
            self.endBirth?()
            self.flight = nil
        }
    }

    private func cancelBirth() {
        birthToken &+= 1
        flight?.cancel()
        flight = nil
        endBirth?()
    }

    /// A display reconfiguration invalidates the panel-space flight. Complete
    /// on the surviving screen immediately instead of drawing stale coordinates.
    func finishBirthAfterDisplayChange() {
        guard flight != nil else { return }
        cancelBirth()
        if let panel, openNoteID != nil {
            panel.setFrame(landingFrame(for: panel), display: true)
            raise(panel)
        }
    }

    /// The flight in progress, so closing or quitting can stop it raising a
    /// window that is no longer wanted.
    private var flight: Task<Void, Never>?

    /// Which flight is the current one, so a second click cannot land an older
    /// one on top of it.
    private var birthToken = 0

    private func raise(_ panel: NotesPanel) {
        // Remembered so Escape can hand the user back what they were doing.
        // Taken here rather than at the click, because the flight runs for half
        // a second and the user may have changed apps in between.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            panel.previousApp = front
        }
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        // An accessory app is not in the activation order, so ordering a window
        // front is not enough to make it key — the same four-call sequence the
        // Settings window and the tour already use. This is only ever reached
        // from a click on a tile, which is the user event macOS wants to see
        // behind a programmatic activation.
        NSApp.activate(ignoringOtherApps: true)
        if let hosting { panel.makeFirstResponder(hosting) }
    }

    /// The window's title is the note's first line, which is the only title a
    /// note has — there is no title field to fill in before writing.
    private func updateTitle(from text: AttributedString) {
        let first = String(text.characters)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        panel?.title = first.isEmpty ? "New Note" : first
    }

    /// Puts focus back where it was, leaving the window on screen.
    private func returnFocus() {
        guard let panel else { return }
        panel.resignKey()
        if let previous = panel.previousApp, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            previous.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    /// Sleep/lock cancels pending focus changes but leaves an existing editor alone.
    func cancelPendingOpening() {
        opening.cancel()
        cancelBirth()
    }

    func close() {
        // Stopped first: a flight still running would raise this window again a
        // moment after it closed, and pull focus with it.
        opening.cancel()
        cancelBirth()
        panel?.close()
    }

    private func flush() {
        let id = openNoteID
        let text = model.text
        let store = self.store
        Task {
            if let id { await store.update(id, text: text) }
            await store.flush()
            if let id { await store.discardIfEmpty(id) }
        }
    }

    private func makePanel() -> NotesPanel {
        let panel = NotesPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            // Borderless, not a titled window with its chrome hidden: a
            // titled panel still reserves its title bar's height, which left a
            // dead strip above the view's own header. Dragging is kept by
            // `isMovableByWindowBackground` below.
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // Chromeless: the view draws its own header, so the system title bar
        // would be a second one sitting above it. The title still goes on the
        // window for anything that reads it, like the window menu.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        // Below the notch panel, which sits at mainMenuWindow + 3, so a note
        // can never cover the island it came out of.
        panel.level = .floating
        // Follows the user rather than living on the Space it was opened in.
        // Not `.canJoinAllSpaces`, which is right for the notch because the
        // notch is hardware — a note is not, and one that appeared on every
        // desktop would be intrusive.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // A window full of the user's own writing is exactly the window not to
        // put on a shared screen. Follows the same preference the overlay does
        // rather than inventing a second rule for the same question.
        panel.sharingType = preferences.hideFromScreenCapture ? .none : .readOnly

        panel.onEscape = { [weak self] in self?.returnFocus() }
        panel.onClose = { [weak self] in self?.close() }

        let hosting = NSHostingView(rootView: NotesEditorView(
            model: model,
            onClose: { [weak self] in self?.close() }
        ))
        // SwiftUI hands a hosting view's ideal size up to its window, and a
        // text view grows with its content — without this the window would
        // resize itself under the user as they typed.
        hosting.sizingOptions = []
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)
        self.hosting = hosting

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.opening.cancel()
                self.cancelBirth()
                self.flush()
                self.openNoteID = nil
                self.onOpenNoteChanged?(nil)
            }
        }
        // Losing key is a reason to write: the user has gone somewhere else and
        // whatever is in the buffer has to be on disk before it matters.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }

        model.onEdit = { [weak self] text in
            guard let self, let id = self.openNoteID else { return }
            self.updateTitle(from: text)
            let store = self.store
            Task { await store.update(id, text: text) }
        }

        self.panel = panel
        return panel
    }

    /// The emitting display and island, supplied by the shell.
    var notchScreen: (() -> NSScreen?)?
    var sourceIsland: (() -> CGRect?)?
    var displayScale: (() -> CGFloat)?

    private func landingFrame(for panel: NSPanel) -> NSRect {
        let screen = notchScreen?() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return panel.frame }
        let island = sourceIsland?() ?? CGRect(x: screen.frame.midX, y: screen.visibleFrame.maxY,
                                               width: 0, height: 0)
        return NotesBirthGeometry.landing(island: island, visible: screen.visibleFrame,
                                          scale: displayScale?() ?? 1)
    }

    /// Diagnostics: the note window's own drawn content, as PNG bytes.
    func capturedContentPNG() -> Data? {
        guard let view = panel?.contentView else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func tearDown() {
        opening.cancel()
        cancelBirth()
        flush()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        closeObserver = nil
        resignObserver = nil
        panel?.close()
        panel = nil
        hosting = nil
        openNoteID = nil
        onOpenNoteChanged?(nil)
    }
}

/// Owns asynchronous note loading before any window exists. Only the latest
/// request can present, including when a cancelled load ignores cancellation.
@MainActor
final class NotesOpeningRequest {
    private var task: Task<Void, Never>?
    private var generation = 0

    @discardableResult
    func start(load: @escaping @MainActor () async -> NoteBody?,
               deliver: @escaping @MainActor (NoteBody) -> Void) -> Task<Void, Never> {
        cancel()
        let session = generation
        let work = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let body = await load()
            guard !Task.isCancelled, let self, self.generation == session else { return }
            self.task = nil
            if let body { deliver(body) }
        }
        task = work
        return work
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
}
