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
/// real `NotesPanel`, the real `NotesEditorView` in an `NSHostingView` — over a
/// real store in a scratch folder. The panel is never ordered in and never
/// key. The switch and the close flush are the controller's, line for line,
/// because `present` is private and the controller's own open raises a window
/// on the user's screen.
@MainActor
@Suite("Notes undo", .serialized)
struct NotesUndoTests {

    @MainActor final class Harness {
        let dir: URL
        let store: NotesStore
        let model = NotesEditorModel()
        let panel: NotesPanel
        let hosting: NSHostingView<NotesEditorView>
        var openNoteID: String?

        init() {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ledge-notes-undo-tests/\(UUID().uuidString)", isDirectory: true)
            store = NotesStore(directory: dir)
            panel = NotesPanel(contentRect: NSRect(x: -30000, y: -30000, width: 360, height: 420),
                               styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                               backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            hosting = NSHostingView(rootView: NotesEditorView(model: model, onClose: {}))
            hosting.sizingOptions = []
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
                let text = NotesEditorModel.stored(model.text)
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
            let text = NotesEditorModel.stored(model.text)
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

        func textView() -> NSTextView? {
            func find(_ view: NSView) -> NSTextView? {
                if let textView = view as? NSTextView { return textView }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return find(hosting)
        }

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

    @Test("⌘Z right after switching notes leaves the open note's text alone")
    func undoAfterSwitch() async throws {
        _ = NSApplication.shared
        let h = Harness()
        let a = await h.note("Alpha title\nalpha body")
        let b = await h.note("Bravo title\nbravo body")
        h.hosting.layoutSubtreeIfNeeded()
        try await settle()

        h.present(a); try await settle()
        h.present(b); try await settle()
        let textView = try #require(h.textView())
        try #require(textView.string == "Bravo title\nbravo body", "B is the note on screen")
        try #require(textView.undoManager === h.panel.undoManager, "⌘Z goes to the window's own history")

        _ = h.pressUndo(); try await settle()
        #expect(String(h.model.text.characters) == "Bravo title\nbravo body")
        await h.closeFlush()
        #expect(h.diskText(b.id) == "Bravo title\nbravo body")
        #expect(h.diskText(a.id) == "Alpha title\nalpha body")
        h.panel.close()
    }

    @Test("⌘Z on the first note of the session, then closing, keeps the note")
    func undoOnFirstNote() async throws {
        _ = NSApplication.shared
        let h = Harness()
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

    @Test("What was typed in one note cannot be undone into the next")
    func typingStaysWithItsNote() async throws {
        _ = NSApplication.shared
        let h = Harness()
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

    @Test("What was typed in one note cannot be undone into one picked from All Notes")
    func typingStaysWithItsNoteThroughList() async throws {
        _ = NSApplication.shared
        let h = Harness()
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

    @Test("Typing in the next note can still be undone, and only back to how it opened")
    func ownTypingStillUndoes() async throws {
        _ = NSApplication.shared
        let h = Harness()
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
}
