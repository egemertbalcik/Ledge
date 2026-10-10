import Foundation

/// Everything a note window can be asked to do, as one list.
///
/// One list rather than a menu in one place and key handling in another: the
/// palette, the window's key equivalents and the footer's controls all read
/// from here, so a shortcut shown next to a command is the shortcut that runs
/// it. There is no menu bar to fall back on — this app has none — which makes a
/// single source for the vocabulary the only way the three stay in step.
enum NotesCommand: String, CaseIterable, Identifiable, Sendable {
    case newNote
    case duplicate
    case allNotes
    case find
    case bold
    case italic
    case copyMarkdown
    case copyPlainText
    case exportToNotes
    case deleteNote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newNote: "New Note"
        case .duplicate: "Duplicate Note"
        case .allNotes: "All Notes"
        case .find: "Find in Note"
        case .bold: "Bold"
        case .italic: "Italic"
        case .copyMarkdown: "Copy as Markdown"
        case .copyPlainText: "Copy as Plain Text"
        case .exportToNotes: "Export to Apple Notes"
        case .deleteNote: "Delete Note"
        }
    }

    var symbol: String {
        switch self {
        case .newNote: "square.and.pencil"
        case .duplicate: "plus.square.on.square"
        case .allNotes: "square.stack"
        case .find: "text.magnifyingglass"
        case .bold: "bold"
        case .italic: "italic"
        case .copyMarkdown: "doc.on.clipboard"
        case .copyPlainText: "doc.on.clipboard"
        case .exportToNotes: "square.and.arrow.up"
        case .deleteNote: "trash"
        }
    }

    /// The shortcut as it is drawn beside the command.
    var shortcut: String {
        switch self {
        case .newNote: "⌘N"
        case .duplicate: "⌘D"
        case .allNotes: "⌘P"
        case .find: "⌘F"
        case .bold: "⌘B"
        case .italic: "⌘I"
        case .copyMarkdown: "⇧⌘C"
        case .copyPlainText: ""
        case .exportToNotes: "⇧⌘E"
        // Not ⌘⌫: that is `deleteToBeginningOfLine:` in every macOS text view,
        // and taking it meant the window closed when somebody tried to clear a
        // line.
        case .deleteNote: "⌃⌘⌫"
        }
    }

    /// Words that should find this command besides its own title, so somebody
    /// who thinks of it by another name still lands on it.
    var aliases: [String] {
        switch self {
        case .newNote: ["create", "add"]
        case .duplicate: ["copy note", "clone"]
        case .allNotes: ["browse", "switch", "open", "list"]
        case .find: ["search", "filter"]
        case .bold: ["strong", "weight"]
        case .italic: ["emphasis", "slanted"]
        case .copyMarkdown: ["clipboard", "md"]
        case .copyPlainText: ["clipboard", "plain", "txt"]
        case .exportToNotes: ["apple notes", "send", "share"]
        case .deleteNote: ["remove", "trash", "discard"]
        }
    }

    /// Whether a command can be run right now.
    ///
    /// A command that cannot run is shown dimmed rather than hidden: a list
    /// whose contents move about depending on hidden state is a list nobody can
    /// learn the shape of.
    func isEnabled(hasNote: Bool, hasText: Bool) -> Bool {
        switch self {
        case .newNote, .allNotes: true
        case .duplicate, .deleteNote, .find: hasNote
        case .bold, .italic: hasNote
        case .copyMarkdown, .copyPlainText, .exportToNotes: hasNote && hasText
        }
    }

    /// The commands a search matches, in the order they should be offered.
    ///
    /// Matching is on words rather than on the whole string, so "copy md" finds
    /// "Copy as Markdown" — nobody types a command's title exactly. Ranking
    /// puts a title that starts with what was typed above one that merely
    /// contains it, and both above a match that only came through an alias.
    static func matching(_ query: String) -> [NotesCommand] {
        let terms = query.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return allCases }
        return allCases.compactMap { command -> (NotesCommand, Int)? in
            let title = command.title.lowercased()
            let haystacks = [title] + command.aliases
            var worst = 0
            for term in terms {
                if title.hasPrefix(term) || title.split(separator: " ").contains(where: { $0.hasPrefix(term) }) {
                    worst = max(worst, 0)
                } else if title.contains(term) {
                    worst = max(worst, 1)
                } else if haystacks.contains(where: { $0.contains(term) }) {
                    worst = max(worst, 2)
                } else {
                    return nil
                }
            }
            return (command, worst)
        }
        .sorted { left, right in
            left.1 == right.1
                ? (allCases.firstIndex(of: left.0) ?? 0) < (allCases.firstIndex(of: right.0) ?? 0)
                : left.1 < right.1
        }
        .map(\.0)
    }
}
