import LedgeCore
import SwiftUI

/// What the notes card can ask the shell to do.
///
/// Closures rather than anything concrete, because the thing being asked for is
/// a window, and `LedgeUI` never imports AppKit — the same crossing the timer's
/// haptic makes.
public struct NotesActions {
    /// Opens an existing note in the editor window.
    public var open: (String) -> Void
    /// Makes a note and opens it.
    public var create: () -> Void
    /// Removes a note. The store sets the file aside rather than unlinking it.
    public var delete: (String) -> Void

    /// Whether the pointer is over a tile.
    ///
    /// The overlay has one tap across its whole shape that pins and dismisses
    /// the card, and it fires *as well as* a control's own action rather than
    /// instead of it — the route picker carries the same scar. Without this a
    /// click on a note both opened it and collapsed the island, which took the
    /// card away underneath the animation that was supposed to come out of it.
    public var hovering: (Bool) -> Void

    public init(
        open: @escaping (String) -> Void = { _ in },
        create: @escaping () -> Void = {},
        delete: @escaping (String) -> Void = { _ in },
        hovering: @escaping (Bool) -> Void = { _ in }
    ) {
        self.open = open
        self.create = create
        self.delete = delete
        self.hovering = hovering
    }
}

/// The notes the user has written, as a grid of tiles.
///
/// Read-only by design. Typing happens in the editor window and nowhere else —
/// a text field inside a notch card has been tried twice in this app and
/// removed twice, because the island is not a place to put a cursor.
public struct NotesCardView: View {

    private let payload: NotesPayload
    private let actions: NotesActions
    private let isCompactWidth: Bool

    /// Three across, two down.
    ///
    /// The tiles are wider than they are tall, which is not a style choice:
    /// a simple card is allowed 220pt including the cutout and the page dots,
    /// and square tiles at this width want 262. Squares would have had the
    /// bottom row clipped away by the island's own shape. A note tile reads
    /// perfectly well as a short wide card — it is holding a line of text, not
    /// a picture.
    private static let columns = 3
    private static let visibleRows = 2
    static let tileHeight: CGFloat = 55

    public init(
        payload: NotesPayload,
        actions: NotesActions = NotesActions(),
        isCompactWidth: Bool = false
    ) {
        self.payload = payload
        self.actions = actions
        self.isCompactWidth = isCompactWidth
    }

    /// The tiles to draw: the new-note tile first, then the newest notes.
    ///
    /// The new-note tile leads rather than trails so its position never moves.
    /// A control that wanders as the collection grows is one the hand has to
    /// look for every time.
    private var shown: [NoteSummary] {
        Array(payload.notes.prefix(Self.columns * Self.visibleRows - 1))
    }

    private var hidden: Int {
        max(0, payload.notes.count - shown.count)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8),
                    count: Self.columns
                ),
                spacing: 8
            ) {
                NewNoteTile(onHover: actions.hovering) { actions.create() }
                ForEach(shown) { note in
                    NoteTile(
                        note: note,
                        isOpen: note.id == payload.openNoteID,
                        onOpen: { actions.open(note.id) },
                        onDelete: { actions.delete(note.id) },
                        onHover: actions.hovering
                    )
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text")
                .font(.cardLabel)
                .foregroundStyle(.white.opacity(0.7))
            Text(label)
                .font(.cardControl)
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.cardCaption)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private var label: String {
        switch payload.notes.count {
        case 0: "Notes"
        case 1: "1 note"
        default: "\(payload.notes.count) notes"
        }
    }
}

/// The tile that makes a new note.
private struct NewNoteTile: View {
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(isHovering ? 0.14 : 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                )
                .overlay(
                    Image(systemName: "plus")
                        .font(.cardLabel)
                        .foregroundStyle(.white.opacity(isHovering ? 0.95 : 0.7))
                )
                .frame(height: NotesCardView.tileHeight)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0; onHover($0) }
        .accessibilityLabel("New note")
    }
}

/// One note.
private struct NoteTile: View {
    let note: NoteSummary
    let isOpen: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onHover: (Bool) -> Void

    @State private var isHovering = false

    private var title: String {
        note.title.isEmpty ? "Untitled" : note.title
    }

    var body: some View {
        Button(action: onOpen) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(isHovering ? 0.16 : 0.10))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.cardCaption)
                            .foregroundStyle(.white.opacity(note.title.isEmpty ? 0.45 : 0.95))
                            .lineLimit(2)
                        if !note.preview.isEmpty {
                            Text(note.preview)
                                .font(.cardCaption)
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6)
                }
                .overlay {
                    // The note the window currently has open, so the card and
                    // the window never disagree about what is being written.
                    if isOpen {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.yellow.opacity(0.8), lineWidth: 1.5)
                    }
                }
                .frame(height: NotesCardView.tileHeight)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            // Shown on hover, like the shelf's. A context menu is where this
            // started and nobody found it — a delete you have to guess at is
            // one the app does not really have.
            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white.opacity(0.9), .black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .transition(.opacity)
                .accessibilityLabel("Delete note")
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0; onHover($0) }
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note.preview.isEmpty ? title : "\(title), \(note.preview)")
        .accessibilityAddTraits(.isButton)
    }
}
