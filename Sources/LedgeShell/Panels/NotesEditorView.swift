import LedgeCore
import LedgeSystem
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

    /// Told on every change, so the store can take it.
    var onEdit: ((AttributedString) -> Void)?

    /// The note's first line, which is the only title a note has.
    var title: String {
        String(text.characters)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    var characterCount: Int { String(text.characters).count }

    func load(_ body: NoteBody) {
        // The caller sets the note's id immediately after this, and the order
        // matters: `onChange` in the view fires on a later pass, and if the id
        // were still the previous note's then this note's text would be saved
        // over that one.
        text = body.text
        selection = AttributedTextSelection()
        noteID = body.id
    }

    func edited() {
        onEdit?(text)
    }

    /// Turns bold or italic on or off across the selection.
    ///
    /// Done here rather than left to the system. `toggleBold:` has no responder
    /// at all in this app — measured — and the font-manager route does not
    /// convert the system font. Owning it means the stored attribute is exactly
    /// `inlinePresentationIntent`, which is Foundation's own and encodes as a
    /// plain integer rather than a SwiftUI font blob nothing else can read.
    func toggle(_ intent: InlinePresentationIntent) {
        let ranges = selectedRanges()
        guard !ranges.isEmpty else { return }
        let allOn = ranges.allSatisfy {
            text[$0].inlinePresentationIntent?.contains(intent) ?? false
        }
        for range in ranges {
            var current = text[range].inlinePresentationIntent ?? []
            if allOn {
                current.remove(intent)
            } else {
                current.insert(intent)
            }
            // Cleared rather than left empty, so a note with no formatting
            // stores as a bare string instead of a run carrying nothing.
            text[range].inlinePresentationIntent = current.isEmpty ? nil : current
        }
        edited()
    }

    /// Whether the selection is entirely within the given style, so the
    /// footer's controls can show what is on.
    func isActive(_ intent: InlinePresentationIntent) -> Bool {
        let ranges = selectedRanges()
        guard !ranges.isEmpty else { return false }
        return ranges.allSatisfy {
            text[$0].inlinePresentationIntent?.contains(intent) ?? false
        }
    }

    private func selectedRanges() -> [Range<AttributedString.Index>] {
        switch selection.indices(in: text) {
        case .insertionPoint:
            return []
        case .ranges(let set):
            return Array(set.ranges)
        @unknown default:
            return []
        }
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
    /// Puts the window away. The system's own close button is hidden because
    /// the view draws its own header, so without this there is no way out.
    var onClose: () -> Void = {}

    private var displayTitle: String {
        model.title.isEmpty ? "New Note" : model.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            editor
            footer
        }
        .background {
            // The window reads as a piece of the island that came loose, so it
            // is the same near-black rather than a system material.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The title, which is the note's own first line — never a field to fill in.
    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "note.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text(displayTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(model.title.isEmpty ? 0.35 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            CloseButton(action: onClose)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var editor: some View {
        TextEditor(text: $model.text, selection: $model.selection)
            .focused($writing)
            .font(.system(size: 13))
            .lineSpacing(3)
            .foregroundStyle(.white.opacity(0.92))
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
            // ⌘B and ⌘I are the system-standard bindings, so there is nothing
            // here for anyone to learn.
            .onKeyPress(.init("b"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.toggle(.stronglyEmphasized)
                return .handled
            }
            .onKeyPress(.init("i"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.toggle(.emphasized)
                return .handled
            }
    }

    /// Quiet, and the only place the two formatting commands are visible at
    /// all — there is no toolbar and no menu to find them in.
    private var footer: some View {
        HStack(spacing: 10) {
            StyleChip(label: "B", weight: .bold, isOn: model.isActive(.stronglyEmphasized)) {
                model.toggle(.stronglyEmphasized)
            }
            StyleChip(label: "I", italic: true, isOn: model.isActive(.emphasized)) {
                model.toggle(.emphasized)
            }
            Spacer(minLength: 0)
            Text("esc returns  ·  ⌘W closes")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.28))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.03))
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
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(isOn ? 0.18 : (hovering ? 0.09 : 0.0)))
                )
                .foregroundStyle(.white.opacity(isOn ? 0.95 : 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label == "B" ? "Bold" : "Italic")
    }
}


/// Closes the window. Always visible, not hover-revealed: a control you cannot
/// see is one that is not there, which is exactly how the hidden system button
/// read.
private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.5))
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(.white.opacity(hovering ? 0.14 : 0.06))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Close note")
    }
}
