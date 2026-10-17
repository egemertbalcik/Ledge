/// What the notes card says.
///
/// In `LedgeCore` beside the rest of the copy rather than inside the view, so
/// the window and the card can be shown to use the same words — the two have
/// drifted before, and a card that calls a command something the window calls
/// something else is two features wearing one name.
public enum NotesCopy {

    /// A note whose first line is still empty. The window's own word for it.
    public static let untitled = "Untitled"

    public static let newNote = "New note"

    /// The door to the window's list. Shown only when some notes are not on
    /// the card, because with nothing hidden there is nothing to open it for.
    public static func allNotes(_ count: Int) -> String { "All \(count) notes" }
    public static let allNotesHint =
        "Opens every note, with the search field ready."

    /// In the time column of the note the window has open.
    public static let open = "Open"
    /// And of one that has been asked for and has not arrived. Said only after
    /// a wait long enough to be a wait: most opens are instant, and a word
    /// that flashes and vanishes reads as a fault.
    public static let opening = "Opening…"

    /// The one thing the card can have to say.
    ///
    /// A click on a note whose file has gone used to do nothing at all — no
    /// window, no sentence — which is indistinguishable from a card that has
    /// stopped working.
    public static func couldNotOpen(_ title: String) -> String {
        let name = title.isEmpty ? untitled : title
        return "Couldn't open “\(name)”. Its file is missing or can't be read."
    }

    public static let emptyTitle = "No notes yet"
    public static let emptyBody = "Notes open in their own window and save as you type."

    // MARK: - The context menu
    //
    // The same names the window's own commands use. Deliberately no Delete:
    // deleting from the card called the store while the window still had the
    // note open, and the window's next keystroke wrote it straight back.

    public static let openCommand = "Open"
    public static let copyMarkdown = "Copy as Markdown"
    public static let copyPlainText = "Copy as Plain Text"
}
