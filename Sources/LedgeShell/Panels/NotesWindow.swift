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
/// Taking focus and taking the screen away from somebody are different things,
/// and only the first is wanted. `.nonactivatingPanel` separates them: the app
/// that was in front stays active and keeps the menu bar, its window keeps
/// drawing as the one being worked in, and only the keyboard moves here. This
/// is what every accessory app with a text field does — Maccy's floating panel
/// and Ice's search panel are both `.nonactivatingPanel` with `canBecomeKey`
/// true and no activation call anywhere.
///
/// It does mean the panel loses the keyboard when anything else legitimately
/// claims it, which for an editor is right: that is the user going back to
/// their work, and `didResignKey` already saves the note when it happens.
final class NotesPanel: NSPanel {

    /// The app that was in front when this window opened, so Escape can give
    /// the user back exactly what they were doing.
    var previousApp: NSRunningApplication?

    /// Told when Escape is pressed, so the controller can return focus.
    var onEscape: (() -> Void)?

    /// Told about every command key this app has no menu to dispatch from.
    ///
    /// `NSApplication` sends ⌘-anything through `NSApp.mainMenu` first, and
    /// this app has no menu at all — no Dock icon, no menu bar item, so
    /// `mainMenu` is nil for the whole life of the process. Measured:
    /// `performKeyEquivalent(⌘V)` returns false and nothing is pasted, while
    /// `sendAction(paste:)` works and the text view is right there in the
    /// responder chain. The chain was never the problem; the dispatch was
    /// missing. This supplies it.
    var onCommand: ((NotesCommand) -> Void)?

    /// ⌘K, which opens the list of commands rather than running one.
    var onPalette: (() -> Void)?

    /// Whether the note itself is what is on screen, rather than a list laid
    /// over it. Commands that act on the writing are refused while it is not.
    var isEditingNote: (() -> Bool)?

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
        let control = flags.contains(.control)

        // Anything macOS already means by a key inside a text view is not
        // ours to take. ⌘⌫ is `deleteToBeginningOfLine:`, ⌘← and ⌘→ move to
        // the ends of a line, ⌥⌫ deletes a word, the control letters are the
        // emacs bindings AppKit has honoured since before this app existed.
        // Every one of those reaches `default:` below and goes to the text
        // view, which is the only correct answer: a note window that cannot
        // delete a line is not an editor.
        //
        // This is what ⌘⌫ used to break — it closed the window instead of
        // deleting back to the start of the line.
        if control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "\u{8}", "\u{7f}": onCommand?(.deleteNote); return true
            default: return super.performKeyEquivalent(with: event)
            }
        }

        if shift {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": onCommand?(.copyMarkdown); return true
            case "e": onCommand?(.exportToNotes); return true
            default: break
            }
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        // Editing, handed to whatever holds the caret — the note, or a search
        // field when one is open.
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "z":
            return NSApp.sendAction(shift ? Selector(("redo:")) : Selector(("undo:")),
                                    to: nil, from: self)

        // Moving about, which works wherever you are.
        case "n": onCommand?(.newNote); return true
        case "p": onCommand?(.allNotes); return true
        case "k": onPalette?(); return true
        case "w":
            // The system close button is hidden, so this is the keyboard way
            // out and it has to be wired by hand like the rest.
            requestClose()
            return true

        // Acting on the note, which only means anything while the note is what
        // is on screen. Styling the text under a search field nobody can see
        // changing is worse than doing nothing.
        case "d", "f", "b", "i":
            guard isEditingNote?() == true else { return super.performKeyEquivalent(with: event) }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": onCommand?(.duplicate)
            case "f": onCommand?(.find)
            case "b": onCommand?(.bold)
            default: onCommand?(.italic)
            }
            return true

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
        retire(before: body.id)
        let panel = panel ?? makePanel()
        model.load(body)
        updateTitle(from: body.text)
        openNoteID = body.id
        onOpenNoteChanged?(body.id)

        let landing = landingFrame(for: panel)

        // Already on screen: nothing is opening, the note simply changes.
        // Switching notes must not undo the user's dragged window position.
        guard !panel.isVisible else {
            raise(panel)
            return
        }

        panel.setFrame(landing, display: false)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            model.finishOpening(animated: false)
            fadeIn(panel)
            return
        }

        // The window is at its final size and position from the first frame,
        // and only its content moves: the frame itself cannot be sprung —
        // `NSWindow` is composited by the window server, not by this process's
        // layer tree, so no spring can reach it — and animating it instead
        // gave a motion that came apart from the island's at every overshoot.
        //
        // The state change is started *before* the window is shown. Shown
        // first, the first composited frame is the resting state and the
        // animation begins from there, which reads as a flash.
        model.beginOpening()
        hosting?.layoutSubtreeIfNeeded()
        model.finishOpening(animated: true)
        fadeIn(panel)
    }

    /// Alpha, and only alpha, on the window itself.
    ///
    /// Short and flat: it is not the animation, it is cover for the one frame
    /// where the window server registers a new window and the backing store is
    /// allocated. Everything anybody is meant to notice happens in the content.
    private func fadeIn(_ panel: NotesPanel) {
        panel.alphaValue = 0
        raise(panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// A display reconfiguration can leave the window on a screen that no
    /// longer exists, or outside the usable bounds of the one that does.
    func finishBirthAfterDisplayChange() {
        guard let panel, panel.isVisible, openNoteID != nil else { return }
        panel.setFrame(landingFrame(for: panel), display: true)
    }

    /// Builds everything the first open would otherwise have to build while it
    /// was supposed to be animating.
    ///
    /// Measured: the first open blocked the main thread for around 200ms where
    /// a later one blocked 50, and a quarter-second animation cannot survive
    /// that. Two costs arrive together on that first open — the panel's
    /// registration with the window server, and SwiftUI building the editor's
    /// view graph and laying out its text. Neither has to happen then.
    ///
    /// Invisible and never key: alpha zero, ordered front only so the window
    /// server does its half of the work, then ordered straight back out.
    func warmUp() {
        guard panel == nil else { return }
        let panel = makePanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        hosting?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        warming = Task { @MainActor [weak self] in
            // Held for a couple of frames rather than torn down in the same
            // turn: a view's first composite is where the window server and the
            // text system do their share, and a warm-up that lays out and
            // leaves pays for none of it.
            for _ in 0 ..< 2 {
                do { try await Task.sleep(for: .milliseconds(34)) } catch { break }
                panel.displayIfNeeded()
            }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self?.warming = nil
        }
    }

    private var warming: Task<Void, Never>?

    private func raise(_ panel: NotesPanel) {
        // Remembered so Escape can hand the user back what they were doing.
        // Taken here rather than at the click: the open is asynchronous and
        // the user may have changed apps in between.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            panel.previousApp = front
        }
        // No activation. `.nonactivatingPanel` plus `orderFrontRegardless`
        // is the documented way to take the keyboard without taking the app
        // in front down with it; `orderFrontRegardless` is explicitly a
        // stacking call that changes neither the key nor the main window, and
        // `makeKey` then moves only key.
        panel.orderFrontRegardless()
        panel.makeKey()
        // Not `makeFirstResponder(hosting)`. The hosting view accepting first
        // responder is exactly what it looks like — focus landing on the
        // container rather than on the text inside it — and it took the caret
        // back off the editor every time the window was raised. Measured: the
        // panel was key and the app active, and the first responder was
        // `NSHostingView<NotesEditorView>`, with no insertion point anywhere in
        // the window. The editor's own `@FocusState` owns this.
        model.requestFocus()
        captureEditorFrames()
    }

    /// Writes a few frames of the open editor to disk, when asked to.
    ///
    /// Only runs if `~/.ledge-notes-diag` exists, so it costs a stat and
    /// nothing else for everybody who has not asked for it. Several frames
    /// because the caret blinks: one picture proves nothing about whether there
    /// is a caret at all.
    private func captureEditorFrames() {
        let marker = (NSHomeDirectory() as NSString).appendingPathComponent(".ledge-notes-capture")
        guard FileManager.default.fileExists(atPath: marker) else { return }
        editorCapture?.cancel()
        editorCapture = Task { @MainActor [weak self] in
            for ms in [300, 500, 700, 900, 1100, 1300] {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, let png = self.capturedContentPNG() else { return }
                let out = (NSHomeDirectory() as NSString)
                    .appendingPathComponent(".ledge-editor-\(ms).png")
                try? png.write(to: URL(fileURLWithPath: out))
            }
        }
    }

    private var editorCapture: Task<Void, Never>?

    /// The window's title is the note's first line, which is the only title a
    /// note has — there is no title field to fill in before writing.
    private func updateTitle(from text: AttributedString) {
        let first = String(text.characters)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        panel?.title = first.isEmpty ? "New Note" : first
    }

    /// Puts the note the window is leaving to bed before it takes up another.
    ///
    /// Closing the window already does this. Swapping notes inside an open one
    /// did not, so pressing ⌘N on a blank note left that blank on disk and
    /// opened a second one — and the note list filled up with untitled nothing.
    /// Every way out of a note goes through here now: a new note, a note picked
    /// from the list, and closing.
    ///
    /// The text is read before `model.load` replaces it, which is why this runs
    /// first and not as part of the swap.
    private func retire(before next: String?) {
        guard let leaving = openNoteID, leaving != next else { return }
        let text = NotesEditorModel.stored(model.text)
        let store = store
        Task {
            await store.update(leaving, text: text)
            await store.flush()
            await store.discardIfEmpty(leaving)
        }
    }

    /// Carries out a command, wherever it was asked for — the palette, a
    /// header button, or a key the window caught.
    ///
    /// One place, so the three can never disagree about what a command does.
    func run(_ command: NotesCommand) {
        guard model.canRun(command) else { return }
        switch command {
        case .newNote:
            create()
        case .duplicate:
            guard let id = openNoteID else { return }
            let store = store
            Task { @MainActor [weak self] in
                guard let copy = await store.duplicate(id) else { return }
                self?.present(copy)
            }
        case .allNotes:
            let store = store
            Task { @MainActor [weak self] in
                self?.model.notes = await store.list()
                self?.model.show(.notes)
            }
        case .find:
            model.show(.find)
        case .bold:
            model.toggle(.stronglyEmphasized)
        case .italic:
            model.toggle(.emphasized)
        case .copyMarkdown:
            copy(NoteMarkdown.render(NotesEditorModel.stored(model.text)))
        case .copyPlainText:
            copy(String(model.text.characters))
        case .exportToNotes:
            let title = model.title
            let text = NotesEditorModel.stored(model.text)
            Task { [weak self] in
                if let failure = await NotesExport.send(title: title, text: text) {
                    await MainActor.run { self?.report(failure) }
                }
            }
        case .deleteNote:
            guard let id = openNoteID else { return }
            // Forgotten before the window closes. Closing writes the note out
            // one last time, and `update` revives a note that has gone — so
            // leaving the id in place would bring back the note just deleted.
            openNoteID = nil
            onOpenNoteChanged?(nil)
            let store = store
            Task { await store.delete(id) }
            close()
        }
    }

    private func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Says what went wrong, where the user is already looking.
    ///
    /// A refusal is a decision, not a fault: the user was asked once whether
    /// Ledge could drive Notes and said no, and asking again by raising an
    /// alert would be arguing with them. The window's own header says it
    /// instead, and the next export will try again.
    private func report(_ failure: NotesExport.Failure) {
        switch failure {
        case .notPermitted:
            model.notice = "Notes isn't allowing this. Turn Ledge on under Privacy & Security → Automation."
        case .timedOut:
            model.notice = "Notes didn't answer."
        case .failed:
            model.notice = "Couldn't hand this to Notes."
        }
    }

    /// Hands the keyboard back, leaving the window on screen.
    ///
    /// The app in front never stopped being active, so there is nothing to
    /// restore — only the key window moves. Activating it again is what makes
    /// one of its windows key, which is where the next keystroke should go.
    private func returnFocus() {
        guard let panel else { return }
        panel.resignKey()
        if let previous = panel.previousApp, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            previous.activate()
        }
    }

    /// Sleep/lock cancels pending focus changes but leaves an existing editor alone.
    func cancelPendingOpening() {
        opening.cancel()
    }

    func close() {
        // Stopped first: a load still running would raise this window again a
        // moment after it closed, and pull focus with it.
        opening.cancel()
        panel?.close()
    }

    private func flush() {
        let id = openNoteID
        // Stored form, not what is on screen: the font is derived from the
        // intent for the editor's benefit and is never the truth about a note.
        let text = NotesEditorModel.stored(model.text)
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
            //
            // `.nonactivatingPanel` is what lets the caret land here without
            // the app behind going dim. Three states are in play and only one
            // of them should change: the app that was in front stays *active*
            // and keeps the menu bar, its window stays *main* and keeps drawing
            // as the window you are working in, and only *key* — where
            // keystrokes go — moves here. Without this bit a window of an
            // accessory app cannot become key at all without activating the
            // whole app, which is why there used to be an `NSApp.activate` call
            // below, and why Terminal visibly lost focus the moment a note
            // opened.
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // Chromeless: the view draws its own header, so the system title bar
        // would be a second one sitting above it. The title still goes on the
        // window for anything that reads it, like the window menu.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window paints itself near-black whatever the system is set to, so
        // it has to say so: in Light Mode the system would otherwise draw this
        // window's selection highlight, scrollers and context menus for a light
        // background they are not on.
        panel.appearance = NSAppearance(named: .darkAqua)
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

        panel.onEscape = { [weak self] in
            guard let self else { return }
            // Escape means "back", and what it goes back to depends on where
            // you are: out of a list to the note, and out of the note to
            // whatever you were doing before. Routing it through the window
            // rather than only through the search field is what makes it work
            // when the field has lost focus — which is most of "return does not
            // always work".
            if self.model.overlay != .none {
                self.model.dismissOverlay()
            } else {
                self.returnFocus()
            }
        }
        panel.onCommand = { [weak self] command in self?.run(command) }
        panel.onPalette = { [weak self] in
            guard let self else { return }
            // ⌘K is a way in and a way out: pressed again it puts the note back.
            self.model.overlay == .commands ? self.model.dismissOverlay() : self.model.show(.commands)
        }
        panel.isEditingNote = { [weak self] in self?.model.overlay == NotesOverlay.none }
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
            self.model.notice = nil
            let store = self.store
            Task { await store.update(id, text: text) }
        }
        model.onCommand = { [weak self] command in self?.run(command) }
        model.onOpenNote = { [weak self] id in self?.open(noteID: id) }

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
        return NotesGeometry.landing(island: island, visible: screen.visibleFrame,
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
