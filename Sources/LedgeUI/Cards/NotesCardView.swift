import LedgeCore
import SwiftUI

/// What the notes card can ask the shell to do.
///
/// Closures rather than anything concrete, because the thing being asked for is
/// a window, and `LedgeUI` never imports AppKit — the same crossing the timer's
/// haptic makes.
public struct NotesActions {
    /// Opens an existing note in the editor window, and says whether it could
    /// be opened.
    ///
    /// The answer matters: a press on a note whose file has gone used to
    /// produce no window and no sentence, which from the outside is a card
    /// that has stopped working.
    public var open: (String) async -> Bool
    /// Makes a note and opens it.
    public var create: () -> Void
    /// Opens the window on its All Notes list, with the search field focused.
    ///
    /// The count used to be text. With more than a handful of notes the card
    /// said "+307" and nothing on it reached them — the window's own ⌘P list
    /// was the only way, and nobody who had not learnt that shortcut had a
    /// way at all.
    public var openAll: () -> Void
    /// The two the window's own commands offer, so the card's context menu
    /// uses the same names rather than inventing its own.
    public var copyMarkdown: (String) -> Void
    public var copyPlainText: (String) -> Void

    /// Whether the pointer is over a row.
    ///
    /// The overlay has one tap across its whole shape that pins and dismisses
    /// the card, and it fires *as well as* a control's own action rather than
    /// instead of it — the route picker carries the same scar. Without this a
    /// click on a note both opened it and collapsed the island, which took the
    /// card away underneath the animation that was supposed to come out of it.
    public var hovering: (Bool) -> Void

    public init(
        open: @escaping (String) async -> Bool = { _ in true },
        create: @escaping () -> Void = {},
        openAll: @escaping () -> Void = {},
        copyMarkdown: @escaping (String) -> Void = { _ in },
        copyPlainText: @escaping (String) -> Void = { _ in },
        hovering: @escaping (Bool) -> Void = { _ in }
    ) {
        self.open = open
        self.create = create
        self.openAll = openAll
        self.copyMarkdown = copyMarkdown
        self.copyPlainText = copyPlainText
        self.hovering = hovering
    }
}

/// The notes the user has written: the one they were last in, the four before
/// it, and a door to all the rest.
///
/// Not a grid. A grid says every note is equally likely to be next, and that
/// is false — the note somebody wants from the notch is nearly always the one
/// they were just in. Six 55pt tiles spent half their area on tile chrome and
/// set every title in 10pt across two lines; this gives the first note a title
/// you can read and two lines of its own words, and the next four one clean
/// line each.
///
/// Read-only by design. Typing happens in the editor window and nowhere else —
/// a text field inside a notch card has been tried twice in this app and
/// removed twice, because the island is not a place to put a cursor.
public struct NotesCardView: View {

    private let payload: NotesPayload
    private let actions: NotesActions
    private let isCompactWidth: Bool
    private let now: () -> Date

    /// How many notes the card shows before the rest become a count.
    ///
    /// Five, and the card is the same height at twelve notes and at three
    /// hundred. Only the count grows.
    /// Shared with the shell, which sizes the island from the same number
    /// before this card has measured itself.
    static let shownCount = NotchLayout.notesShownCount

    /// Which note is being opened, if the store has not answered yet.
    @State private var opening: String?
    /// Whether the wait has lasted long enough to say so. Most opens never
    /// reach this; one that flashes "Opening…" and vanishes reads as a fault.
    @State private var openingIsSlow = false
    /// A note the store could not open, until the next press.
    @State private var failed: NoteSummary?
    /// The order the card is drawing, held still while the pointer is on it.
    ///
    /// A note edited in the window moves to the top on the next publish, and
    /// the publish arrives while somebody's pointer is over the row that is
    /// about to move. The list is held under the hand — the same rule the HUD
    /// panel uses for its device rows — and catches up when the pointer
    /// leaves.
    @State private var frozen: [String]?

    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        payload: NotesPayload,
        actions: NotesActions = NotesActions(),
        isCompactWidth: Bool = false,
        now: @escaping () -> Date = Date.init,
        /// Seeded for a test or the gallery, which have no pointer to press
        /// with and no store to be slow.
        opening: String? = nil,
        openingIsSlow: Bool = false,
        failed: NoteSummary? = nil,
        /// The order the card is holding, for a test: `@State` cannot be
        /// written before a view is mounted, so the rule about what happens
        /// *between* a pointer arriving and the next publish is unreachable
        /// from outside unless it can be seeded here.
        frozenOrder: [String]? = nil
    ) {
        self.payload = payload
        self.actions = actions
        self.isCompactWidth = isCompactWidth
        self.now = now
        _opening = State(initialValue: opening)
        _openingIsSlow = State(initialValue: openingIsSlow)
        _failed = State(initialValue: failed)
        _frozen = State(initialValue: frozenOrder)
    }

    /// The notes in the order the card is drawing them.
    var ordered: [NoteSummary] {
        guard let frozen else { return payload.notes }
        // Anything new goes to the end of the held order rather than jumping
        // the queue; anything deleted simply drops out.
        let byID = Dictionary(payload.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let held = frozen.compactMap { byID[$0] }
        let arrived = payload.notes.filter { !frozen.contains($0.id) }
        return held + arrived
    }

    var shown: [NoteSummary] { Array(ordered.prefix(Self.shownCount)) }
    var hidden: Int { max(0, ordered.count - shown.count) }

    public var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.top, 8)
            // Four more than the other cards. The two controls sit on the
            // card's own bottom edge, and at 14 they read as though they were
            // part of the page dots underneath them.
            .padding(.bottom, 18)
            .onHover { inside in
                actions.hovering(inside)
                // Frozen on entry, released on exit. Taken on *entry* rather
                // than on the first publish, so the order cannot change
                // between the pointer arriving and the next one arriving.
                frozen = inside ? ordered.map(\.id) : nil
            }
    }

    @ViewBuilder private var content: some View {
        if shown.isEmpty {
            empty
        } else {
            VStack(alignment: .leading, spacing: 0) {
                lead(shown[0])
                if shown.count > 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shown.dropFirst()) { row($0) }
                    }
                    .padding(.top, 4)
                }
                if let failed {
                    Text(NotesCopy.couldNotOpen(failed.title))
                        .font(.cardNote)
                        .foregroundStyle(NoteInk.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .transition(.opacity)
                }
                footer
            }
        }
    }

    /// The card with nothing in it, which is how the first note gets made.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(NotesCopy.emptyTitle)
                    .font(.cardHeadline)
                    .foregroundStyle(NoteInk.text)
                Text(NotesCopy.emptyBody)
                    .font(.cardNote)
                    .foregroundStyle(NoteInk.muted(contrast == .increased))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            NoteControl(title: NotesCopy.newNote, leadingPlus: true) { actions.create() }
                .onHover { actions.hovering($0) }
            Spacer(minLength: 0)
            if hidden > 0 {
                // The count *is* the door. As text it named 307 notes the card
                // could not reach.
                Button { actions.openAll() } label: {
                    Text(NotesCopy.allNotes(ordered.count))
                        .font(.cardControl)
                        .foregroundStyle(NoteInk.muted(contrast == .increased))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .onHover { actions.hovering($0) }
                .accessibilityHint(NotesCopy.allNotesHint)
            }
        }
        .padding(.top, 10)
    }

    // MARK: - Rows

    /// The note the user was last in, with two lines of its own words.
    private func lead(_ note: NoteSummary) -> some View {
        NoteRow(
            note: note,
            trailing: trailing(for: note),
            isOpen: note.id == payload.openNoteID,
            preview: note.preview.isEmpty ? nil : note.preview,
            actions: actions,
            press: { press(note) }
        )
    }

    private func row(_ note: NoteSummary) -> some View {
        NoteRow(
            note: note,
            trailing: trailing(for: note),
            isOpen: note.id == payload.openNoteID,
            preview: nil,
            actions: actions,
            press: { press(note) }
        )
    }

    /// What sits in the time column: a time, Open, or Opening….
    ///
    /// Never wraps and never pushes a title, which is why it is one of three
    /// short things rather than a sentence.
    func trailing(for note: NoteSummary) -> NoteRowTrailing {
        if opening == note.id, openingIsSlow { return .opening }
        if note.id == payload.openNoteID { return .open }
        return .when(NoteWhen.label(note.editedAt, now: now()))
    }

    private func press(_ note: NoteSummary) {
        failed = nil
        opening = note.id
        openingIsSlow = false
        Task { @MainActor in
            // Said only if the wait lasts. Most opens are instant, and a word
            // that flashes and vanishes reads as a fault rather than as work.
            let patience = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Self.patienceBeforeSaying))
                guard !Task.isCancelled, opening == note.id else { return }
                openingIsSlow = true
            }
            let opened = await actions.open(note.id)
            patience.cancel()
            guard opening == note.id else { return }
            opening = nil
            openingIsSlow = false
            if !opened { failed = note }
        }
    }

    /// How long a press may go unanswered before the card says so.
    static let patienceBeforeSaying = 400
}

/// What the time column is showing.
enum NoteRowTrailing: Equatable {
    case when(String)
    case open
    case opening

    var text: String {
        switch self {
        case .when(let label): label
        case .open: NotesCopy.open
        case .opening: NotesCopy.opening
        }
    }

    /// Open and Opening… are about this note *now*, so they take the amber the
    /// window marks the same note with. A time is not news.
    var isMarked: Bool { self != .when(text) ? true : false }
}

/// One note, as a row.
private struct NoteRow: View {
    let note: NoteSummary
    let trailing: NoteRowTrailing
    let isOpen: Bool
    let preview: String?
    let actions: NotesActions
    let press: () -> Void

    @State private var isHovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: press) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? NotesCopy.untitled : note.title)
                        .font(preview == nil ? .cardControl : .cardHeadline)
                        .foregroundStyle(note.title.isEmpty
                                         ? NoteInk.muted(contrast == .increased)
                                         : NoteInk.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let preview {
                        Text(preview)
                            .font(.cardNote)
                            .foregroundStyle(NoteInk.muted(contrast == .increased))
                            .lineLimit(2)
                            // Two lines means two lines. Without this the row
                            // offered the text one line's worth of height and
                            // the second line was simply never drawn.
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 4)
                Text(trailing.text)
                    .font(.cardCaption)
                    .monospacedDigit()
                    .foregroundStyle(trailing.isMarked
                                     ? NoteInk.mark
                                     : NoteInk.faint(contrast == .increased))
                    .lineLimit(1)
                    // Never truncated and never wrapped: the title gives way
                    // first, because a cut title is still recognisable and a
                    // cut date is not.
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, preview == nil ? 4 : 6)
            .frame(minHeight: preview == nil ? 24 : 0, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? NoteInk.raised : .clear)
            )
            .overlay(alignment: .leading) {
                // The window's own mark, at full strength for the note it has
                // open and half for the one the pointer is on. The card used
                // `.yellow` and the window used this amber, so one feature had
                // two colours.
                Capsule()
                    .fill(NoteInk.mark)
                    .frame(width: 2)
                    .padding(.vertical, 5)
                    .opacity(isOpen ? 1 : (isHovering ? 0.55 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovering = inside
            actions.hovering(inside)
        }
        // The window's own commands, by their own names. No Delete: deleting
        // from the card called the store while the window still had the note
        // open, and the window's next keystroke wrote it straight back.
        .contextMenu {
            Button(NotesCopy.openCommand) { press() }
            Button(NotesCopy.copyMarkdown) { actions.copyMarkdown(note.id) }
            Button(NotesCopy.copyPlainText) { actions.copyPlainText(note.id) }
        }
        .accessibilityLabel(note.title.isEmpty ? NotesCopy.untitled : note.title)
        .accessibilityValue(trailing.text)
    }
}

/// The card's one filled control.
private struct NoteControl: View {
    let title: String
    let leadingPlus: Bool
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            HStack(spacing: 6) {
                if leadingPlus {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NoteInk.mark)
                }
                Text(title)
                    .font(.cardControl)
                    .foregroundStyle(NoteInk.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
