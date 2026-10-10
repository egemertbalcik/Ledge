import Foundation
import Testing
@testable import LedgeShell

@Suite("Note commands")
struct NotesCommandTests {

    @Test("An empty search offers everything, in its own order")
    func everything() {
        #expect(NotesCommand.matching("") == NotesCommand.allCases)
        #expect(NotesCommand.matching("   ") == NotesCommand.allCases)
    }

    @Test("Words are matched one by one, not as one string")
    func words() {
        // Nobody types a command's title exactly; they type the parts they
        // remember, in whatever order comes to mind.
        #expect(NotesCommand.matching("copy md").contains(.copyMarkdown))
        #expect(NotesCommand.matching("note new").contains(.newNote))
        #expect(NotesCommand.matching("apple").contains(.exportToNotes))
    }

    @Test("A title that starts with what was typed comes before one that merely contains it")
    func ranking() {
        let found = NotesCommand.matching("note")
        #expect(found.first == .newNote)
        #expect(found.contains(.duplicate))
    }

    @Test("Nonsense matches nothing")
    func nothing() {
        #expect(NotesCommand.matching("zzzz").isEmpty)
        #expect(NotesCommand.matching("copy zzzz").isEmpty)
    }

    @Test("Every command says what it is and how it is run")
    func complete() {
        for command in NotesCommand.allCases {
            #expect(!command.title.isEmpty)
            #expect(!command.symbol.isEmpty)
        }
        // One shortcut, one command: two commands sharing a key would make the
        // list lie about what the key does.
        let shortcuts = NotesCommand.allCases.map(\.shortcut).filter { !$0.isEmpty }
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test("No shortcut takes a key macOS already means inside a text view")
    func doesNotStealEditingKeys() {
        // This is here because one did. ⌘⌫ is `deleteToBeginningOfLine:` in
        // every macOS text view, and giving it to Delete Note meant the window
        // closed when somebody tried to clear a line they were writing.
        //
        // Anything on this list belongs to the text system. A note window that
        // cannot do what every other text field does is not an editor, however
        // many commands it has.
        let reserved: Set<String> = [
            "⌘⌫",   // delete to the start of the line
            "⌘⌦",   // delete to the end of the line
            "⌥⌫",   // delete the word behind the caret
            "⌘←", "⌘→",  // the ends of the line
            "⌘↑", "⌘↓",  // the ends of the note
            "⌥←", "⌥→",  // word by word
            "⌘A", "⌘C", "⌘V", "⌘X",  // select, copy, paste, cut
            "⌘Z", "⇧⌘Z",             // undo and redo
        ]
        for command in NotesCommand.allCases {
            #expect(!reserved.contains(command.shortcut),
                    "\(command.title) takes \(command.shortcut), which belongs to the text system")
        }
    }

    @Test("Deleting a note is reachable, and says so")
    func deleteIsBound() {
        // It lost ⌘⌫ for good reasons; it must not have lost its keyboard
        // route altogether.
        #expect(!NotesCommand.deleteNote.shortcut.isEmpty)
        #expect(NotesCommand.deleteNote.shortcut.contains("⌃"))
    }

    @Test("What cannot run with no note, and what still can")
    func enablement() {
        for command in NotesCommand.allCases {
            let withNothing = command.isEnabled(hasNote: false, hasText: false)
            #expect(withNothing == (command == .newNote || command == .allNotes))
        }
        // Copying and exporting need something to copy.
        #expect(!NotesCommand.copyMarkdown.isEnabled(hasNote: true, hasText: false))
        #expect(NotesCommand.copyMarkdown.isEnabled(hasNote: true, hasText: true))
        #expect(NotesCommand.deleteNote.isEnabled(hasNote: true, hasText: false))
    }
}
