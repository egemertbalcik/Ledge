import LedgeCore
import LedgeSystem
import SwiftUI

/// What is open in the note window, if not the note.
///
/// One at a time, and all of them inside the same window. A palette in a window
/// of its own would have to answer where it goes, which screen it is on, and
/// what happens to focus when it closes — three questions this window has
/// already answered.
enum NotesOverlay: Equatable {
    case none
    case commands
    case notes
    case find

    var title: String {
        switch self {
        case .none: ""
        case .commands: "Commands"
        case .notes: "All Notes"
        case .find: "Find in Note"
        }
    }

    var prompt: String {
        switch self {
        case .none: ""
        case .commands: "What do you want to do?"
        case .notes: "Search your notes"
        case .find: "Find in this note"
        }
    }
}

/// The ink this window is drawn in.
///
/// Gathered in one place because three surfaces share it. Everything is an
/// opacity of white over the island's own black except one amber, which marks
/// the row the keys are pointed at and nothing else — a window that is
/// otherwise colourless can say "here" with very little.
enum NoteInk {
    static let text = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.28)
    static let raised = Color.white.opacity(0.055)
    static let edge = Color.white.opacity(0.10)
    static let mark = Color(red: 0.95, green: 0.72, blue: 0.38)
}

/// A search field, a list, and the keys that drive them.
///
/// Laid out as a place rather than a popup: it takes the window's body, the
/// header above it says where you are, and a line underneath keeps the keys on
/// screen. This app has no menu bar, so that line is the only place anybody can
/// learn them.
struct NotesPaletteView<Row: View>: View {

    let overlay: NotesOverlay
    @Binding var query: String
    let count: Int
    @Binding var highlighted: Int
    /// Non-nil while the highlight was last moved by the keyboard. Hovering
    /// must not scroll the list: the scroll moves the rows under the pointer,
    /// which lands a new row under it, which scrolls again — the list runs away
    /// from the hand holding it.
    @Binding var followingKeys: Bool
    let run: (Int) -> Void
    let dismiss: () -> Void
    @ViewBuilder let row: (Int, Bool) -> Row

    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider().overlay(NoteInk.edge)
            if count == 0 { empty } else { rows }
            Divider().overlay(NoteInk.edge)
            hints
        }
        .background(Color.black.opacity(0.97))
        .onAppear { searching = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: overlay == .find ? "text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(NoteInk.faint)
            TextField(overlay.prompt, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(NoteInk.text)
                .tint(NoteInk.mark)
                .focused($searching)
                .onSubmit { run(highlighted) }
                .onKeyPress(.upArrow) { step(-1) }
                .onKeyPress(.downArrow) { step(1) }
                .onKeyPress(.return) { run(highlighted); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// An empty result says what to do about it, not merely that it is empty.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(overlay == .notes ? "No note matches" : "No command matches")
                .font(.system(size: 12))
                .foregroundStyle(NoteInk.muted)
            Text("Try fewer words")
                .font(.system(size: 11))
                .foregroundStyle(NoteInk.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    private var rows: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(0 ..< count, id: \.self) { index in
                        row(index, index == highlighted)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { run(index) }
                            .onHover { inside in
                                guard inside else { return }
                                followingKeys = false
                                highlighted = index
                            }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 248)
            .onChange(of: highlighted) { _, index in
                guard followingKeys else { return }
                scroller.scrollTo(index, anchor: .center)
            }
        }
    }

    private var hints: some View {
        HStack(spacing: 14) {
            Hint(keys: "↑↓", label: "Move")
            Hint(keys: "↵", label: overlay == .notes ? "Open" : "Run")
            Spacer(minLength: 0)
            Hint(keys: "esc", label: "Back")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func step(_ direction: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        followingKeys = true
        highlighted = (highlighted + direction + count) % count
        return .handled
    }
}

/// A key and what it does, drawn small.
private struct Hint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NoteInk.muted)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(NoteInk.raised)
                )
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(NoteInk.faint)
        }
    }
}

/// A row, highlighted by a mark on its edge rather than a block of colour.
///
/// A filled rectangle on a near-black ground reads as a hole cut in the window;
/// a hairline of the island's own warmth reads as a pointer.
private struct RowGround: ViewModifier {
    let isHighlighted: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(isHighlighted ? NoteInk.raised : .clear)
                    Rectangle()
                        .fill(NoteInk.mark)
                        .frame(width: 2)
                        .opacity(isHighlighted ? 1 : 0)
                }
            }
    }
}

extension View {
    func rowGround(isHighlighted: Bool) -> some View {
        modifier(RowGround(isHighlighted: isHighlighted))
    }
}

/// One command, with the keys that run it.
struct NotesCommandRow: View {
    let command: NotesCommand
    let isHighlighted: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: command.symbol)
                .font(.system(size: 12))
                .frame(width: 17)
                .foregroundStyle(isEnabled ? NoteInk.muted : NoteInk.faint.opacity(0.6))
            Text(command.title)
                .font(.system(size: 13))
                .foregroundStyle(isEnabled ? NoteInk.text : NoteInk.faint)
            Spacer(minLength: 10)
            if !command.shortcut.isEmpty {
                Text(command.shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isEnabled ? NoteInk.faint : NoteInk.faint.opacity(0.5))
            }
        }
        .rowGround(isHighlighted: isHighlighted)
    }
}

/// One note, by its first line.
struct NotesListRow: View {
    let summary: NoteSummary
    let isHighlighted: Bool
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: isOpen ? "doc.text.fill" : "doc.text")
                .font(.system(size: 12))
                .frame(width: 17)
                .foregroundStyle(isOpen ? NoteInk.mark.opacity(0.85) : NoteInk.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title.isEmpty ? "Untitled" : summary.title)
                    .font(.system(size: 13))
                    .foregroundStyle(summary.title.isEmpty ? NoteInk.muted : NoteInk.text)
                    .lineLimit(1)
                if !summary.preview.isEmpty {
                    Text(summary.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(NoteInk.faint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .rowGround(isHighlighted: isHighlighted)
    }
}
