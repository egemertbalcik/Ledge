import LedgeCore
import LedgeSystem
import LedgeUI
import SwiftUI

/// What the editor is editing.
///
/// Held by the controller rather than the view so the window can be shown and
/// hidden without rebuilding the hosting view, which would reset SwiftUI state
/// and drop the selection mid-sentence.
@MainActor
final class NotesEditorModel: ObservableObject {

    @Published var text = AttributedString("")
    @Published var selection = AttributedTextSelection()

    /// Which note is loaded, so the view can put the caret back in the text
    /// when a different one is swapped into the same window.
    @Published private(set) var noteID: String?

    /// Bumped by every `load`, so the view can start the window's undo
    /// history over once the new text is in the text view. Not the id: the
    /// same note reopened has the same one.
    @Published private(set) var loads = 0

    /// Told on every change, so the store can take it.
    var onEdit: ((AttributedString) -> Void)?

    /// Bumped whenever the window is raised, so the caret goes back into the
    /// text. A plain `writing = true` cannot do this on its own: focus is
    /// already nominally true from the first appearance, and SwiftUI applies a
    /// focus binding when it *changes*.
    @Published private(set) var focusRequests = 0

    func requestFocus() { focusRequests &+= 1 }

    // MARK: - What is laid over the note

    @Published var overlay: NotesOverlay = .none
    /// What the palette and the note list are filtered by.
    @Published var query: String = ""
    /// What the find bar is looking for — its own, not the palette's.
    ///
    /// One string for all three was the bug: opening the palette left the find
    /// bar's words in it, closing the find bar filtered the note list, and the
    /// count never belonged to what was on screen.
    @Published var findQuery: String = "" {
        didSet { findMatches() }
    }
    @Published var highlighted: Int = 0
    /// Whether the highlight was last moved by a key. Hovering must not scroll:
    /// the scroll moves the rows under the pointer, which lands another row
    /// under it, which scrolls again.
    @Published var followingKeys: Bool = true
    /// Filled when the note list opens, so the window never holds a stale copy
    /// of a list it is not showing.
    @Published var notes: [NoteSummary] = []

    /// Where every match is, and which one is current.
    @Published private(set) var matches: [Range<AttributedString.Index>] = []
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

    /// Told to run a command. The window owns what commands do — the model
    /// knows the vocabulary, not the machinery.
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

    func show(_ overlay: NotesOverlay) {
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
    /// Counting was not finding. Knowing a word is in the note seven times does
    /// not help anybody reach any of them, so this moves the selection — which
    /// is also what scrolls the editor to it.
    private func findMatches() {
        let needle = findQuery.trimmingCharacters(in: .whitespaces)
        guard needle.count > 0 else {
            matches = []
            matchIndex = 0
            return
        }
        var found: [Range<AttributedString.Index>] = []
        var search = text.startIndex ..< text.endIndex
        while let range = text[search].range(of: needle, options: .caseInsensitive) {
            found.append(range)
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
        selection = AttributedTextSelection(range: matches[matchIndex])
    }

    /// "3 of 7", or what to do when there are none.
    var matchSummary: String {
        if findQuery.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if matches.isEmpty { return "Not in this note" }
        return "\(matchIndex + 1) of \(matches.count)"
    }

    /// How far from its resting state the window's content is while it opens.    /// How far from its resting state the window's content is while it opens.
    ///
    /// One number, so the whole surface moves as one thing rather than as a
    /// handful of separately timed effects. Zero is the window as it lives.
    @Published private(set) var openingAmount: CGFloat = 0

    /// Set before the window is shown. Shown first, the first composited frame
    /// is the resting state and the animation starts from there, which reads as
    /// a flash rather than as an opening.
    func beginOpening() { openingAmount = 1 }

    func finishOpening(animated: Bool) {
        guard animated else { return openingAmount = 0 }
        // `.smooth` is SwiftUI's own default spring and has no bounce. The
        // window is a place to type, arriving where it was asked for; it has no
        // momentum of its own to justify an overshoot, and Apple's guidance is
        // that bounce is earned by the gesture behind a move, not added to it.
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
        // Whatever was over the note goes with it, in the same change. The
        // All Notes list used to be dismissed first and the note loaded
        // afterwards, so pressing New note there played two animations back to
        // back — the list leaving, then the note arriving — which is the
        // unsmooth moment the owner felt rather than the new note itself.
        overlay = .none
        query = ""
        findQuery = ""
        highlighted = 0
        // The caller sets the note's id immediately after this, and the order
        // matters: `onChange` in the view fires on a later pass, and if the id
        // were still the previous note's then this note's text would be saved
        // over that one.
        text = Self.rendered(body.text)
        selection = AttributedTextSelection()
        noteID = body.id
        loads &+= 1
    }

    func edited() {
        onEdit?(Self.stored(text))
    }

    /// Turns bold or italic on or off, over the selection or at the caret.
    ///
    /// Three things were wrong with doing this by hand, and all three are the
    /// same mistake: reaching into the string instead of asking it.
    ///
    /// With a bare caret there is no range to write into, so the old code
    /// returned early and did nothing — which is the commonest way anybody uses
    /// bold at all: press it, then type. `transformAttributes(in:)` covers both
    /// cases from one call; with a selection it runs over every run in it, and
    /// at an insertion point it writes the *typing* attributes, so the next
    /// characters come out bold.
    ///
    /// Any mutation of an `AttributedString` invalidates every index into it,
    /// not only the ones it touched — the storage is a tree and the indices are
    /// paths through it. Writing through a stale index is why the caret jumped
    /// to the end of the note after every toggle; this hands the selection to
    /// the mutation so it is carried across.
    ///
    /// And the editor draws bold from the `font` attribute, not from
    /// `inlinePresentationIntent`. The intent is what gets stored — it encodes
    /// as a plain integer anything can read, where a font encodes as a blob
    /// nothing else can — but on its own it is invisible while you are typing.
    /// Both are written here: the intent to be saved, the font to be seen.
    func toggle(_ intent: InlinePresentationIntent) {
        let turningOn = !isActive(intent)
        text.transformAttributes(in: &selection) { container in
            var current = container.inlinePresentationIntent ?? []
            if turningOn { current.insert(intent) } else { current.remove(intent) }
            container.inlinePresentationIntent = current.isEmpty ? nil : current
            container.font = NoteFace.font(for: current)
        }
        edited()
    }

    /// Gives every run the face its stored intent calls for.
    ///
    /// Notes are saved carrying intent and nothing else, so a note loaded from
    /// disk would otherwise come back on screen with its bold gone — the
    /// attribute is there, but the editor does not draw from it.
    ///
    /// Normalised first. The formatting definition only governs what comes
    /// into the text view, not text the app hands it, so a note an earlier
    /// build saved with a pasted highlight in it would otherwise open with the
    /// highlight still in the model and be saved straight back with it. A list
    /// an earlier build pasted as tab, bullet, tab is given its bullets for
    /// the same reason: the panel tidies them as they arrive now, and a note
    /// should not read differently depending on when it was pasted into.
    static func rendered(_ text: AttributedString) -> AttributedString {
        var clean = NoteText.normalized(text)
        NoteText.collapseListMarkers(in: &clean)
        var out = clean
        for run in clean.runs {
            out[run.range].font = NoteFace.font(for: run.inlinePresentationIntent ?? [])
        }
        return out
    }

    /// Whether what the user types next would come out in this style, so the
    /// controls can show what is on.
    ///
    /// At a caret that means the typing attributes, not nothing — a control
    /// that goes dark the moment the selection collapses is lying about the
    /// state the next keystroke will be in.
    func isActive(_ intent: InlinePresentationIntent) -> Bool {
        switch selection.indices(in: text) {
        case .insertionPoint:
            return selection.typingAttributes(in: text)
                .inlinePresentationIntent?.contains(intent) ?? false
        case .ranges(let set):
            let ranges = Array(set.ranges)
            guard !ranges.isEmpty else { return false }
            return ranges.allSatisfy {
                text[$0].inlinePresentationIntent?.contains(intent) ?? false
            }
        @unknown default:
            return false
        }
    }

    /// The text as it should be stored: characters and intent, nothing else.
    ///
    /// The font is derived and so is never the truth about a note. Saving it
    /// would put a SwiftUI blob in the JSON that nothing else can read, and
    /// would go stale the moment the editor's size changed. The same goes for
    /// everything else a paste or an older build can leave in the model —
    /// colours, links, paragraph styles — so this keeps what Ledge can make
    /// rather than removing what it happens to know about.
    static func stored(_ text: AttributedString) -> AttributedString {
        NoteText.normalized(text)
    }

}

/// The face that shows what the intent means.
///
/// Its own home, outside the model, because the formatting definition's
/// constraints run off the main actor and the model is isolated to it.
enum NoteFace {
    static func font(for intent: InlinePresentationIntent) -> Font {
        var font = Font.system(size: 13)
        if intent.contains(.stronglyEmphasized) { font = font.bold() }
        if intent.contains(.emphasized) { font = font.italic() }
        return font
    }
}

/// What the text view will let a note carry: bold and italic, and the face
/// drawn from them.
///
/// Without it the editor took whatever arrived. A paste, a drop, a Service or
/// the right-click Font menu brought in highlight, colours, fonts, underline
/// and links, none of which Ledge can show a control for or take away again.
/// SwiftUI applies this to everything entering the text view by any of those
/// routes, so they all come out the same.
///
/// The order is the point. The intent is read from the face first, so what
/// arrived as a bold font becomes Ledge's bold — the B chip lights up for it,
/// it is exported, and it survives a reopen — and only then is the face
/// replaced with Ledge's own. The other way round, pasted bold would be turned
/// plain before anything had looked at it.
///
/// It also stops the first edit after a load throwing the caret to the end of
/// the note. `.lineSpacing` made SwiftUI stamp a line height across the whole
/// text on that edit, which came back through the binding as a replacement of
/// everything; line height is outside this scope, so it is never written into
/// the text and the spacing is drawn from the environment alone.
struct NoteFormatting: AttributedTextFormattingDefinition {
    struct Scope: AttributeScope {
        let inlinePresentationIntent: AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute
        let font: AttributeScopes.SwiftUIAttributes.FontAttribute
    }

    /// The view's, so a pasted face can be asked whether it is bold.
    let context: Font.Context

    var body: some AttributedTextFormattingDefinition<Scope> {
        IntentFollowsFace(context: context)
        FaceFollowsIntent()
    }
}

/// Bold and italic, read off whatever face a run arrived in.
///
/// A rich paste has no intent at all, only a font — Helvetica Bold, Times Bold
/// from an `<h1>`, a heavy face from Word — and the rest of Ledge only knows
/// bold as intent. A run with no face of its own is left as it is.
struct IntentFollowsFace: AttributedTextValueConstraint {
    typealias Scope = NoteFormatting.Scope
    typealias AttributeKey = AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute

    let context: Font.Context

    func constrain(_ container: inout Attributes) {
        // Only the two Ledge has controls for. `.code`, `.strikethrough` and
        // the rest can ride in on SwiftUI's own pasteboard type.
        var intent = (container.inlinePresentationIntent ?? []).intersection(NoteText.allowedIntent)
        if let face = container.font {
            let resolved = face.resolve(in: context)
            if resolved.isBold { intent.insert(.stronglyEmphasized) } else { intent.remove(.stronglyEmphasized) }
            if resolved.isItalic { intent.insert(.emphasized) } else { intent.remove(.emphasized) }
        }
        container.inlinePresentationIntent = intent.isEmpty ? nil : intent
    }
}

/// The face is only ever Ledge's own, chosen by the intent.
struct FaceFollowsIntent: AttributedTextValueConstraint {
    typealias Scope = NoteFormatting.Scope
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.FontAttribute

    func constrain(_ container: inout Attributes) {
        container.font = NoteFace.font(for: container.inlinePresentationIntent ?? [])
    }
}

/// One note, in its own window.
///
/// No toolbar, no slash menu, no browse list, no save button. The card in the
/// notch is the index; this window is one note.
struct NotesEditorView: View {

    @ObservedObject var model: NotesEditorModel

    /// Keyboard focus for the text itself.
    ///
    /// The window becoming key and the hosting view becoming first responder is
    /// not enough: SwiftUI hands the caret to whichever field it considers
    /// focused, and with nothing claiming focus the editor draws no insertion
    /// point at all. The user sees a window they can type into with no sign of
    /// where the text will go.
    @FocusState private var writing: Bool
    /// The window's, which is where ⌘Z goes. One for the whole session,
    /// because the window is.
    @Environment(\.undoManager) private var undoManager
    /// What the formatting definition resolves a pasted face against.
    @Environment(\.fontResolutionContext) private var fontContext
    /// Puts the window away. The system's own close button is hidden because
    /// the view draws its own header, so without this there is no way out.
    var onClose: () -> Void = {}

    private var displayTitle: String {
        model.title.isEmpty ? "New Note" : model.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notice = model.notice {
                NoticeLine(text: notice)
            }
            Divider().overlay(NoteInk.edge)
            // The overlay takes the body rather than floating над it. A card
            // over the note hid the header, which was the only way back out —
            // "there is no easy way to return" was a layout fault, not a key
            // handling one.
            if model.overlay == .none {
                editor
                footer
            } else {
                overlay
            }
        }
        // The window's shape, whatever is in it. The black is drawn behind
        // this stack in a clear window, so a body shorter than the window — a
        // list, a search with nothing found — pulled the outline and its
        // shadow in around it, and every keystroke across "no match" looked
        // like the window resizing itself.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // The window reads as a piece of the island that came loose, so it
            // is the same near-black rather than a system material.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(NoteInk.edge, lineWidth: 1)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.smooth(duration: 0.18), value: model.notice)
        // A note's history starts when it is loaded. The text view records the
        // load itself as an edit, and keeps whatever was typed in the note
        // before, so ⌘Z after a switch put the last note's text into this one
        // and saved it there — and on the first note of a session undid it
        // to nothing, which closing then threw away. Here rather than on the
        // editor: opened from All Notes, the editor is new in this same pass.
        .onChange(of: model.loads) { _, _ in undoManager?.removeAllActions() }
        // Grows out of the corner nearest the notch, which is where the window
        // came from. Scale and nothing else: the window's own alpha covers the
        // first frame, and a second fade here only muddies it.
        .scaleEffect(1 - 0.06 * model.openingAmount, anchor: .topLeading)
    }

    /// The window's one piece of chrome, and the only way back.
    private var header: some View {
        HStack(spacing: 8) {
            if model.overlay == .none {
                Image(systemName: "note.text")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NoteInk.muted)
                Text(displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(model.title.isEmpty ? NoteInk.faint : NoteInk.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                HeaderButton(symbol: "square.and.pencil", name: "New Note", keys: "⌘N") {
                    model.onCommand?(.newNote)
                }
                HeaderButton(symbol: "square.stack", name: "All Notes", keys: "⌘P") {
                    model.onCommand?(.allNotes)
                }
                HeaderButton(symbol: "command", name: "Commands", keys: "⌘K") {
                    model.show(.commands)
                }
            } else {
                HeaderButton(symbol: "chevron.left", name: "Back to the note", keys: "esc") {
                    model.dismissOverlay()
                }
                Text(model.overlay.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NoteInk.text)
                Spacer(minLength: 8)
            }
            CloseButton(action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    private var editor: some View {
        TextEditor(text: $model.text, selection: $model.selection)
            .focused($writing)
            .font(.system(size: 13))
            // The caret, explicitly. Left to the system it is drawn in the
            // user's accent colour against a near-black window, and a graphite
            // or dark accent puts an invisible insertion point in a window
            // whose whole purpose is typing.
            .tint(Color.white.opacity(0.9))
            .lineSpacing(3)
            .foregroundStyle(NoteInk.text)
            .attributedTextFormattingDefinition(NoteFormatting(context: fontContext))
            .scrollContentBackground(.hidden)
            .background(.clear)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxHeight: .infinity)
            .onChange(of: model.text) { _, _ in model.edited() }
            // On opening, and again whenever a different note is loaded into
            // the same window — the caret belongs in the text every time.
            .onAppear { writing = true }
            .onChange(of: model.noteID) { _, _ in writing = true }
            // Off and back on: SwiftUI acts on a focus binding when it changes,
            // and after the first appearance this is already true.
            .onChange(of: model.focusRequests) { _, _ in
                writing = false
                Task { @MainActor in writing = true }
            }
    }

    @ViewBuilder private var overlay: some View {
        switch model.overlay {
        case .none:
            EmptyView()
        case .commands:
            NotesPaletteView(
                overlay: .commands,
                query: $model.query,
                count: model.commands.count,
                highlighted: $model.highlighted,
                followingKeys: $model.followingKeys,
                run: { index in
                    guard let command = model.commands[safe: index], model.canRun(command) else { return }
                    model.dismissOverlay()
                    model.onCommand?(command)
                },
                dismiss: { model.dismissOverlay() }
            ) { index, isHighlighted in
                if let command = model.commands[safe: index] {
                    NotesCommandRow(command: command,
                                    isHighlighted: isHighlighted,
                                    isEnabled: model.canRun(command))
                }
            }
        case .notes:
            NotesPaletteView(
                overlay: .notes,
                query: $model.query,
                count: model.listedNotes.count,
                highlighted: $model.highlighted,
                followingKeys: $model.followingKeys,
                run: { index in
                    guard let summary = model.listedNotes[safe: index] else { return }
                    model.dismissOverlay()
                    model.onOpenNote?(summary.id)
                },
                dismiss: { model.dismissOverlay() },
                // No dismiss here: loading the note takes the list away as
                // part of the same change, where dismissing first made two.
                create: { model.onCommand?(.newNote) }
            ) { index, isHighlighted in
                if let summary = model.listedNotes[safe: index] {
                    NotesListRow(summary: summary,
                                 isHighlighted: isHighlighted,
                                 isOpen: summary.id == model.noteID)
                }
            }
        case .find:
            VStack(spacing: 0) {
                FindBar(query: $model.findQuery,
                        summary: model.matchSummary,
                        hasMatches: !model.matches.isEmpty,
                        step: { model.stepMatch($0) },
                        dismiss: { model.dismissOverlay() })
                Divider().overlay(NoteInk.edge)
                editor
            }
        }
    }

    /// The two styles, and the key that opens everything else.
    ///
    /// Bold and italic are here because they are used while writing rather than
    /// chosen from a list; everything else lives behind ⌘K, which this says so
    /// that somebody who never opens the palette still learns it exists.
    private var footer: some View {
        HStack(spacing: 8) {
            StyleChip(label: "B", weight: .bold, isOn: model.isActive(.stronglyEmphasized)) {
                model.toggle(.stronglyEmphasized)
            }
            StyleChip(label: "I", italic: true, isOn: model.isActive(.emphasized)) {
                model.toggle(.emphasized)
            }
            Spacer(minLength: 0)
            Text("⌘K for commands")
                .font(.system(size: 10))
                .foregroundStyle(NoteInk.faint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(NoteInk.raised.opacity(0.5))
    }
}

/// A small bold/italic control. Shows what the selection already is, so the
/// keyboard shortcut and the button never disagree.
private struct StyleChip: View {
    let label: String
    var weight: Font.Weight = .regular
    var italic = false
    let isOn: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: weight))
                .italic(italic)
                .frame(width: 22, height: 19)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? NoteInk.mark.opacity(0.22) : NoteInk.raised.opacity(hovering ? 1 : 0))
                )
                .foregroundStyle(isOn ? NoteInk.mark : (hovering ? NoteInk.text : NoteInk.muted))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label == "B" ? "Bold" : "Italic")
    }
}



/// One line of explanation under the header.
///
/// Never an alert. An alert for something the reader can do nothing about this
/// second is an interruption, not information; this sits where they are already
/// looking and leaves on its own.
private struct NoticeLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(NoteInk.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .transition(.opacity)
    }
}

/// A control in the header, which says what it is if you wait on it.
///
/// Its own label rather than `.help`: the system tooltip takes about two
/// seconds, arrives as a pale system rectangle that belongs to no window, and
/// cannot show the shortcut beside the name. Three unlabelled glyphs need
/// naming faster and more quietly than that.
private struct HeaderButton: View {
    let symbol: String
    let name: String
    let keys: String
    let action: () -> Void

    @State private var hovering = false
    @State private var telling = false
    @State private var waiting: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? NoteInk.text : NoteInk.muted)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(NoteInk.raised.opacity(hovering ? 1 : 0))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(keys)")
        .onHover { inside in
            hovering = inside
            waiting?.cancel()
            guard inside else { return telling = false }
            waiting = Task { @MainActor in
                // Long enough that passing over three buttons on the way to the
                // close button never fires one.
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                telling = true
            }
        }
        .overlay(alignment: .top) {
            if telling {
                Tip(name: name, keys: keys)
                    .fixedSize()
                    .offset(y: 26)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.12), value: telling)
        .zIndex(telling ? 1 : 0)
    }
}

/// What a control is called, and the keys that do the same thing.
private struct Tip: View {
    let name: String
    let keys: String

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(NoteInk.text)
            Text(keys)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NoteInk.faint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(NoteInk.edge, lineWidth: 1)
                )
        }
        .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
    }
}

/// Finding something in the note that is open.
///
/// It moves the selection to each match rather than counting them: knowing a
/// word appears seven times helps nobody reach any of them, and moving the
/// selection is also what scrolls the editor to it.
private struct FindBar: View {
    @Binding var query: String
    let summary: String
    let hasMatches: Bool
    let step: (Int) -> Void
    let dismiss: () -> Void

    @FocusState private var searching: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(NoteInk.faint)
            TextField("Find in this note", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(NoteInk.text)
                .tint(NoteInk.mark)
                .focused($searching)
                .onSubmit { step(1) }
                .onKeyPress(.return) { step(1); return .handled }
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hasMatches ? NoteInk.mark.opacity(0.9) : NoteInk.faint)
                    .monospacedDigit()
            }
            if hasMatches {
                StepButton(symbol: "chevron.up") { step(-1) }
                StepButton(symbol: "chevron.down") { step(1) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear { searching = true }
    }
}

private struct StepButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? NoteInk.text : NoteInk.muted)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(NoteInk.raised.opacity(hovering ? 1 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Closes the window. Always visible, not hover-revealed: a control you cannot
/// see is one that is not there.
private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? NoteInk.text : NoteInk.muted)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(NoteInk.raised.opacity(hovering ? 1 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Close note")
    }
}

extension Array {
    /// The element at an index, or nothing. A filtered list and the highlight
    /// into it change on different passes, so the highlight can momentarily
    /// point past the end.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
