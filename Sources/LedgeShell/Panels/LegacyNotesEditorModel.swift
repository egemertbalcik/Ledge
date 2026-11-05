import AppKit
import LedgeCore
import LedgeSystem
import SwiftUI

/// What the macOS 15 editor is editing.
///
/// `NotesEditorModel` again, for a window whose text is an `NSTextView` rather
/// than SwiftUI's rich `TextEditor`, which macOS 15 does not have. Every
/// decision that model makes is made here the same way, so the window behaves
/// the same on both: what a load clears, where the caret goes, what the chips
/// say, how a search moves through the note. Only the plumbing differs. There,
/// SwiftUI carries the text and the selection to the text view and back; here
/// the text view is told directly, and tells the model what it did.
///
/// The text is held as it is stored — characters, bold and italic as intent —
/// because the faces are the text view's business and never the truth about a
/// note.
@MainActor
final class LegacyNotesEditorModel: ObservableObject, NotesEditing {

    /// The note, as the text view last reported it or as it was loaded.
    @Published private(set) var text = AttributedString("")

    /// Where the caret or the selection is, in the text view's own offsets.
    /// One range, except after an Option-drag selects several.
    @Published private(set) var selection = [NSRange(location: 0, length: 0)]

    /// The intent the next typed character would get, which is what a chip
    /// shows when nothing is selected.
    @Published private(set) var typingIntent: InlinePresentationIntent = []

    /// Which note is loaded, so the view can put the caret back in the text
    /// when a different one is swapped into the same window.
    @Published private(set) var noteID: String?

    /// Bumped by every `load`.
    @Published private(set) var loads = 0

    /// Told on every change, so the store can take it.
    var onEdit: ((AttributedString) -> Void)?

    /// Bumped whenever the window is raised, so the caret goes back into the
    /// text.
    @Published private(set) var focusRequests = 0

    func requestFocus() { focusRequests &+= 1 }

    /// The text view, once SwiftUI has built it. Weak: the view owns it, and a
    /// model outliving its window must not keep one alive.
    private(set) weak var textView: LegacyNoteTextView?

    // MARK: - What is laid over the note

    @Published var overlay: NotesOverlay = .none
    /// What the palette and the note list are filtered by.
    @Published var query: String = ""
    /// What the find bar is looking for — its own, not the palette's.
    @Published var findQuery: String = "" {
        didSet { findMatches() }
    }
    @Published var highlighted: Int = 0
    /// Whether the highlight was last moved by a key.
    @Published var followingKeys: Bool = true
    /// Filled when the note list opens.
    @Published var notes: [NoteSummary] = []

    /// Where every match is, and which one is current.
    @Published private(set) var matches: [NSRange] = []
    @Published private(set) var matchIndex: Int = 0

    /// A line of explanation under the header, cleared the moment anything
    /// else happens.
    @Published var notice: String? {
        didSet { if notice != nil { clearNoticeSoon() } }
    }

    private var noticeClearing: Task<Void, Never>?

    private func clearNoticeSoon() {
        noticeClearing?.cancel()
        noticeClearing = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    var onCommand: ((NotesCommand) -> Void)?
    var onOpenNote: ((String) -> Void)?

    var commands: [NotesCommand] { NotesCommand.matching(query) }

    var listedNotes: [NoteSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return notes }
        return notes.filter {
            $0.title.lowercased().contains(needle) || $0.preview.lowercased().contains(needle)
        }
    }

    /// Whether anything has been laid over the note since it was loaded. The
    /// other editor's text view is built again when what was over it goes,
    /// so the next note into it, picked from the list or not, starts at the
    /// top; typing into the note or scrolling it in between settles it back
    /// in place, as it does that rebuilt view.
    private var coveredSinceLoad = false

    func show(_ overlay: NotesOverlay) {
        coveredSinceLoad = true
        query = ""
        highlighted = 0
        followingKeys = true
        if overlay != .find { findQuery = "" }
        self.overlay = overlay
    }

    func dismissOverlay() {
        overlay = .none
        query = ""
        findQuery = ""
        highlighted = 0
        requestFocus()
    }

    /// Whether a command can run on what is open right now.
    func canRun(_ command: NotesCommand) -> Bool {
        command.isEnabled(hasNote: noteID != nil,
                          hasText: !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Finding

    /// Every place the search appears, and the selection moved to the first.
    ///
    /// Searched in the note's own text, as the other editor searches, and
    /// only then turned into the text view's offsets: the two then find the
    /// same matches, however the search treats case and composed characters.
    private func findMatches() {
        let needle = findQuery.trimmingCharacters(in: .whitespaces)
        guard needle.count > 0 else {
            matches = []
            matchIndex = 0
            return
        }
        var found: [NSRange] = []
        var search = text.startIndex ..< text.endIndex
        while let range = text[search].range(of: needle, options: .caseInsensitive) {
            found.append(NSRange(range, in: text))
            guard range.upperBound < text.endIndex else { break }
            search = range.upperBound ..< text.endIndex
        }
        matches = found
        matchIndex = 0
        revealMatch()
    }

    /// Moves to the next match, or the previous one.
    func stepMatch(_ direction: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + direction + matches.count) % matches.count
        revealMatch()
    }

    private func revealMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        select(matches[matchIndex])
    }

    /// "3 of 7", or what to do when there are none.
    var matchSummary: String {
        if findQuery.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if matches.isEmpty { return "Not in this note" }
        return "\(matchIndex + 1) of \(matches.count)"
    }

    /// How far from its resting state the window's content is while it opens.
    @Published private(set) var openingAmount: CGFloat = 0

    func beginOpening() { openingAmount = 1 }

    func finishOpening(animated: Bool) {
        guard animated else { return openingAmount = 0 }
        withAnimation(.smooth(duration: 0.26)) { openingAmount = 0 }
    }

    /// The note's first line, which is the only title a note has.
    var title: String {
        String(text.characters)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    var characterCount: Int { String(text.characters).count }

    func load(_ body: NoteBody) {
        // The other editor's text view is built afresh, and so starts at the
        // top, when a note arrives while anything is laid over it or after
        // something was.
        let fromTop = overlay != .none || coveredSinceLoad
        coveredSinceLoad = false
        // Whatever was over the note goes with it, in the same change.
        overlay = .none
        query = ""
        findQuery = ""
        highlighted = 0
        // As the other editor reads a note from disk: normalised, and a list
        // an earlier build pasted given its bullets.
        var clean = NoteText.normalized(body.text)
        NoteText.collapseListMarkers(in: &clean)
        text = clean
        // The caret at the end, where the other editor's empty selection puts
        // it once the new text is in.
        selection = [NSRange(location: (String(clean.characters) as NSString).length, length: 0)]
        noteID = body.id
        loads &+= 1
        if let textView {
            textView.present(clean, caret: selection[0].location, fromTop: fromTop)
            textViewSelected(textView.selectedRanges.map(\.rangeValue),
                             typing: NoteAppKitBridge.intent(of: textView.typingAttributes))
        }
    }

    func edited() {
        onEdit?(NoteText.normalized(text))
    }

    /// Turns bold or italic on or off, over the selection or at the caret.
    ///
    /// Decided as the other editor decides it — on unless everything selected
    /// already has it — and done in the text view, which is where the text is.
    /// What the text view then holds comes back here as any edit does.
    func toggle(_ intent: InlinePresentationIntent) {
        let turningOn = !isActive(intent)
        if let textView {
            textView.apply(intent, on: turningOn)
            // At a caret nothing in the text changed, so nothing else will
            // tell the chips what the next keystroke now types.
            textViewSelected(textView.selectedRanges.map(\.rangeValue),
                             typing: NoteAppKitBridge.intent(of: textView.typingAttributes))
        } else {
            // Nowhere to draw it yet; the text view takes the text as it is
            // when it is built.
            text = Self.toggled(text, intent, on: turningOn, in: selection)
            if selection.allSatisfy({ $0.length == 0 }) {
                if turningOn { typingIntent.insert(intent) } else { typingIntent.remove(intent) }
            }
        }
        edited()
    }

    private static func toggled(_ text: AttributedString, _ intent: InlinePresentationIntent, on: Bool,
                                in ranges: [NSRange]) -> AttributedString {
        var out = text
        for nsRange in ranges where nsRange.length > 0 {
            guard let range = Range(nsRange, in: out) else { continue }
            for run in out[range].runs {
                var current = run.inlinePresentationIntent ?? []
                if on { current.insert(intent) } else { current.remove(intent) }
                out[run.range].inlinePresentationIntent = current.isEmpty ? nil : current
            }
        }
        return out
    }

    /// Whether what the user types next would come out in this style, so the
    /// controls can show what is on.
    ///
    /// At a caret that is the typing attributes. Over a selection it is the
    /// other editor's test exactly: the whole of every range carries one intent,
    /// and that intent has this style in it. A selection that is part bold and
    /// part bold italic is not "bold" there, so it is not here either.
    func isActive(_ intent: InlinePresentationIntent) -> Bool {
        let ranges = selection.filter { $0.length > 0 }
        guard !ranges.isEmpty else { return typingIntent.contains(intent) }
        return ranges.allSatisfy { nsRange in
            guard let range = Range(nsRange, in: text) else { return false }
            return text[range].inlinePresentationIntent?.contains(intent) ?? false
        }
    }

    // MARK: - The text view's side

    /// Called by the text view as it is built, so a note loaded before it
    /// existed — the warm-up builds the window before anything is opened — is
    /// what it starts with.
    func attach(_ textView: LegacyNoteTextView) {
        self.textView = textView
        textView.present(text, caret: selection.first?.location ?? 0, fromTop: true)
    }

    /// What the text view now holds, after anything changed it: typing, a
    /// paste, a drop, undo.
    func textViewChanged(_ text: AttributedString) {
        guard text != self.text else { return }
        self.text = text
        coveredSinceLoad = false
    }

    /// The person scrolled the note.
    func textViewScrolled() {
        coveredSinceLoad = false
    }

    /// Where the text view's selection now is, and what it would type.
    func textViewSelected(_ ranges: [NSRange], typing: InlinePresentationIntent) {
        if ranges != selection { selection = ranges }
        if typing != typingIntent { typingIntent = typing }
    }

    /// Moves the selection, and the text view's scroll with it.
    private func select(_ range: NSRange) {
        selection = [range]
        textView?.reveal(range)
    }
}
