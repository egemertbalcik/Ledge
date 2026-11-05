import AppKit
import Foundation
import LedgeCore
import LedgeSystem
import SwiftUI
import Testing
@testable import LedgeShell

/// ⌘Z in the note window only ever reaches the note that is open.
///
/// The editor is hosted the way `NotesWindowController.makePanel` hosts it — a
/// real `NotesPanel`, the real editor view in an `NSHostingView` — over a real
/// store in a scratch folder, once for each editor this Mac can run. The panel
/// is never ordered in and never key. The switch and the close flush are the
/// controller's, line for line, because `present` is private and the
/// controller's own open raises a window on the user's screen.
@MainActor
@Suite("Notes undo", .serialized)
struct NotesUndoTests {

    @MainActor final class Harness {
        let kind: NotesEditorKind
        let dir: URL
        let store: NotesStore
        let model: any NotesEditing
        let panel: NotesPanel
        let hosting: NSView
        var openNoteID: String?

        init(_ kind: NotesEditorKind) {
            self.kind = kind
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ledge-notes-undo-tests/\(UUID().uuidString)", isDirectory: true)
            store = NotesStore(directory: dir)
            panel = NotesPanel(contentRect: NSRect(x: -30000, y: -30000, width: 360, height: 420),
                               styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                               backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            (model, hosting) = kind.host()
            hosting.frame = panel.contentView?.bounds ?? .zero
            hosting.autoresizingMask = [.width, .height]
            panel.contentView?.addSubview(hosting)
            model.onEdit = { [unowned self] text in
                guard let id = self.openNoteID else { return }
                let store = self.store
                Task { await store.update(id, text: text) }
            }
        }

        /// The controller's `present`: retire the note being left, then load.
        func present(_ body: NoteBody) {
            if let leaving = openNoteID, leaving != body.id {
                let text = NoteText.normalized(model.text)
                let store = store
                Task {
                    await store.update(leaving, text: text)
                    await store.flush()
                    await store.discardIfEmpty(leaving)
                }
            }
            model.load(body)
            openNoteID = body.id
        }

        /// The controller's `flush`, as closing the window runs it.
        func closeFlush() async {
            let id = openNoteID
            let text = NoteText.normalized(model.text)
            if let id { await store.update(id, text: text) }
            await store.flush()
            if let id { await store.discardIfEmpty(id) }
        }

        /// What ⌘Z does: `undo:` up the responder chain from the text view.
        func pressUndo() -> Bool {
            guard let textView = textView() else { return false }
            _ = panel.makeFirstResponder(textView)
            return textView.tryToPerform(Selector(("undo:")), with: nil)
        }

        func textView() -> NSTextView? { noteTextView(in: hosting) }

        func note(_ text: String) async -> NoteBody {
            let note = await store.create()
            await store.update(note.id, text: AttributedString(text))
            await store.flush()
            return await store.body(note.id)!
        }

        func diskText(_ id: String) -> String? {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")),
                  let note = try? JSONDecoder().decode(NoteBody.self, from: data) else { return nil }
            return note.plainText
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

    @Test("⌘Z right after switching notes leaves the open note's text alone", arguments: NotesEditorKind.available)
    func undoAfterSwitch(editor: NotesEditorKind) async throws {
        _ = NSApplication.shared
        let h = Harness(editor)
        let a = await h.note("Alpha title\nalpha body")
        let b = await h.note("Bravo title\nbravo body")
        h.hosting.layoutSubtreeIfNeeded()
        try await settle()

        h.present(a); try await settle()
        h.present(b); try await settle()
        let textView = try #require(h.textView())
        try #require(textView.string == "Bravo title\nbravo body", "B is the note on screen")
        // The SwiftUI editor's text view keeps its history in the window's;
        // the AppKit editor's keeps one of its own, so a search field's ⌘Z
        // can never run on into the note.
        if h.kind == .swiftUI {
            try #require(textView.undoManager === h.panel.undoManager, "⌘Z goes to the window's own history")
        } else {
            try #require(textView.undoManager != nil && textView.undoManager !== h.panel.undoManager,
                         "⌘Z goes to the note's own history")
        }

        _ = h.pressUndo(); try await settle()
        #expect(String(h.model.text.characters) == "Bravo title\nbravo body")
        await h.closeFlush()
        #expect(h.diskText(b.id) == "Bravo title\nbravo body")
        #expect(h.diskText(a.id) == "Alpha title\nalpha body")
        h.panel.close()
    }

    @Test("⌘Z on the first note of the session, then closing, keeps the note", arguments: NotesEditorKind.available)
    func undoOnFirstNote(editor: NotesEditorKind) async throws {
        _ = NSApplication.shared
        let h = Harness(editor)
        let a = await h.note("Only note\nkeep me")
        h.hosting.layoutSubtreeIfNeeded()
        try await settle()
        try #require(h.textView()?.string == "", "the editor was built empty, as the warm-up builds it")

        h.present(a); try await settle()
        try #require(h.textView()?.string == "Only note\nkeep me", "the note is on screen")

        _ = h.pressUndo(); try await settle()
        #expect(String(h.model.text.characters) == "Only note\nkeep me")
        await h.closeFlush()
        #expect(h.diskText(a.id) == "Only note\nkeep me")
        #expect(await h.store.list().map(\.id) == [a.id])
    }

    @Test("What was typed in one note cannot be undone into the next", arguments: NotesEditorKind.available)
    func typingStaysWithItsNote(editor: NotesEditorKind) async throws {
        _ = NSApplication.shared
        let h = Harness(editor)
        let a = await h.note("note A")
        let b = await h.note("note B")
        h.hosting.layoutSubtreeIfNeeded()
        try await settle()

        h.present(a); try await settle()
        let textView = try #require(h.textView())
        try #require(textView.string == "note A")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText(" typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.breakUndoCoalescing()
        try await settle()
        try #require(String(h.model.text.characters) == "note A typed", "the typing reached the note")
        try #require(textView.undoManager?.canUndo == true, "the typing is undoable in its own note")

        // ⌘N, ⌘D and a tile on the card all swap the note in place.
        h.present(b); try await settle()
        try #require(h.textView()?.string == "note B", "B is the note on screen")

        _ = h.pressUndo(); try await settle()
        #expect(String(h.model.text.characters) == "note B")
        await h.closeFlush()
        #expect(h.diskText(b.id) == "note B")
        #expect(h.diskText(a.id) == "note A typed")
        h.panel.close()
    }

    @Test("What was typed in one note cannot be undone into one picked from All Notes", arguments: NotesEditorKind.available)
    func typingStaysWithItsNoteThroughList(editor: NotesEditorKind) async throws {
        _ = NSApplication.shared
        let h = Harness(editor)
        let a = await h.note("note A")
        let b = await h.note("note B")
        h.hosting.layoutSubtreeIfNeeded()
        try await settle()

        h.present(a); try await settle()
        let textView = try #require(h.textView())
        try #require(textView.string == "note A")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText(" typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.breakUndoCoalescing()
        try await settle()
        try #require(String(h.model.text.characters) == "note A typed", "the typing reached the note")
        try #require(textView.undoManager?.canUndo == true, "the typing is undoable in its own note")

        // Picked from All Notes, which takes the editor off screen and puts
        // it back with the next note in it.
        h.model.show(.notes); try await settle()
        h.present(b); try await settle()
        try #require(h.textView()?.string == "note B", "B is the note on screen")

        _ = h.pressUndo(); try await settle()
        #expect(String(h.model.text.characters) == "note B")
        await h.closeFlush()
        #expect(h.diskText(b.id) == "note B")
        #expect(h.diskText(a.id) == "note A typed")
        h.panel.close()
    }

    @Test("Typing in the next note can still be undone, and only back to how it opened", arguments: NotesEditorKind.available)
    func ownTypingStillUndoes(editor: NotesEditorKind) async throws {
        _ = NSApplication.shared
        let h = Harness(editor)
        let a = await h.note("note A")
        let b = await h.note("note B")
        h.hosting.layoutSubtreeIfNeeded()
        try await settle()

        h.present(a); try await settle()
        let textView = try #require(h.textView())
        try #require(textView.string == "note A")
        // Left mid-word, the way somebody switches notes while typing.
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText(" half", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle()
        try #require(String(h.model.text.characters) == "note A half", "the typing reached A")

        h.present(b); try await settle()
        try #require(textView.string == "note B", "B is the note on screen")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText(" typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.breakUndoCoalescing()
        try await settle()
        try #require(String(h.model.text.characters) == "note B typed", "the typing reached B")

        #expect(h.pressUndo())
        try await settle()
        #expect(String(h.model.text.characters) == "note B")
        _ = h.pressUndo(); try await settle()
        #expect(String(h.model.text.characters) == "note B")
        h.panel.close()
    }

    /// The search field of whatever is laid over the note: the find bar's or
    /// a list's.
    private func searchField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let found = searchField(in: sub) { return found } }
        return nil
    }

    @Test("⌘Z in the find bar or a list never reaches the note, however far it goes",
          arguments: NotesEditorKind.available, [NotesOverlay.commands, .notes, .find])
    func undoInAFieldStaysInTheField(editor: NotesEditorKind, overlay: NotesOverlay) async throws {
        _ = NSApplication.shared
        let h = Harness(editor)
        let a = await h.note("note A")
        h.hosting.layoutSubtreeIfNeeded()
        h.present(a); try await settle()
        let textView = try #require(h.textView())
        _ = h.panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.insertText(" typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.breakUndoCoalescing()
        try await settle()
        try #require(String(h.model.text.characters) == "note A typed", "the typing reached the note")

        h.model.notes = [NoteSummary(id: "x", title: "X", preview: "", editedAt: 0)]
        h.model.show(overlay); try await settle()
        let field = try #require(searchField(in: h.hosting), "\(overlay) has its field")
        try #require(h.panel.makeFirstResponder(field))
        let editing = try #require(field.currentEditor(), "the field is being edited")
        editing.insertText("q")
        try await settle()
        try #require(field.stringValue == "q", "typed into the field")

        // ⌘Z is the panel's to dispatch; it sends `undo:` up the chain from
        // whatever has the keyboard, which here is the field.
        let commandZ = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
        let undo = try #require(NotesPanel.editingAction(for: commandZ))
        for _ in 0 ..< 4 {
            _ = (h.panel.firstResponder ?? h.panel).tryToPerform(undo, with: nil)
            try await settle()
        }
        #expect(field.stringValue.isEmpty, "the field's own typing was undone")
        #expect(String(h.model.text.characters) == "note A typed", "the note was never touched")
        await h.store.flush()
        #expect(await h.store.body(a.id)?.plainText == "note A typed", "nor what the store holds for it")
        h.model.onEdit = nil
        h.panel.close()
    }

    @Test("A load starts the window's history over too", arguments: NotesEditorKind.available)
    func loadClearsTheWindowsHistory(editor: NotesEditorKind) async throws {
        _ = NSApplication.shared
        let h = Harness(editor)
        let a = await h.note("note A")
        let b = await h.note("note B")
        h.hosting.layoutSubtreeIfNeeded()
        h.present(a); try await settle()
        // Something left in the window's own history, as a field that kept its
        // history there would leave it. SwiftUI's fields keep theirs apart on
        // this Mac, so the test puts it there itself.
        let window = try #require(h.panel.undoManager)
        window.registerUndo(withTarget: h.panel) { _ in }
        try await settle()
        try #require(window.canUndo, "the window has something to undo")
        h.present(b); try await settle()
        #expect(!window.canUndo, "the history went with the note it belonged to")
        h.model.onEdit = nil
        h.panel.close()
    }
}
