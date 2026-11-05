import Foundation
import LedgeCore
import LedgeSystem

/// What the note window asks of whichever editor it is showing.
///
/// Two editors exist because the one Ledge was built with, SwiftUI's rich
/// `TextEditor`, only exists from macOS 26. On 15 the same window is drawn
/// around an AppKit text view instead. The window controller talks to both
/// through this, and only through this, so everything it does — loading a
/// note, saving it, running a command, opening and closing — is the same code
/// whichever editor is on screen.
///
/// Nothing here is observed by the controller. It reads and writes these at
/// the moments it acts, and each editor's own view observes its own model.
@MainActor
protocol NotesEditing: AnyObject {

    /// The note as it is being edited. The controller only ever stores it
    /// through `NoteText.normalized`, so whatever else an editor keeps in it
    /// for its own drawing never reaches the disk.
    var text: AttributedString { get }

    /// The note's first line.
    var title: String { get }

    var overlay: NotesOverlay { get }
    var notes: [NoteSummary] { get set }
    var notice: String? { get set }

    var onEdit: ((AttributedString) -> Void)? { get set }
    var onCommand: ((NotesCommand) -> Void)? { get set }
    var onOpenNote: ((String) -> Void)? { get set }

    func load(_ body: NoteBody)
    func canRun(_ command: NotesCommand) -> Bool
    func show(_ overlay: NotesOverlay)
    func dismissOverlay()
    func toggle(_ intent: InlinePresentationIntent)
    func requestFocus()
    func beginOpening()
    func finishOpening(animated: Bool)
}
