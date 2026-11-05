import AppKit
import LedgeCore
import LedgeSystem
import LedgeUI
import SwiftUI

/// One note, in its own window, on macOS 15.
///
/// `NotesEditorView` again, with an AppKit text view where that view has
/// SwiftUI's rich `TextEditor`. The header, the notice, the find bar, the
/// palettes and the footer are the same views with the same values, in the
/// same places, so the window is the same window.
///
/// One thing is arranged differently, and on purpose: the text view is never
/// taken down. The other editor's is built again every time it comes back from
/// behind a list or the find bar, and starts again at the top of the note; this
/// one keeps its place, and the note is not laid out a second time. So it has
/// one place in the layout, the find bar is put above it, and a list is drawn
/// over it while the text view is hidden underneath.
struct LegacyNotesEditorView: View {

    @ObservedObject var model: LegacyNotesEditorModel

    /// Puts the window away. The system's own close button is hidden because
    /// the view draws its own header, so without this there is no way out.
    var onClose: () -> Void = {}

    private var displayTitle: String {
        model.title.isEmpty ? "New Note" : model.title
    }

    /// Whether a list is drawn where the note is.
    private var isListing: Bool {
        model.overlay == .commands || model.overlay == .notes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notice = model.notice {
                NoticeLine(text: notice)
            }
            Divider().overlay(NoteInk.edge)
            if model.overlay == .find {
                FindBar(query: $model.findQuery,
                        summary: model.matchSummary,
                        hasMatches: !model.matches.isEmpty,
                        step: { model.stepMatch($0) },
                        dismiss: { model.dismissOverlay() })
                Divider().overlay(NoteInk.edge)
            }
            ZStack {
                editor
                listing
            }
            if model.overlay == .none {
                footer
            }
        }
        // The window's shape, whatever is in it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(NoteInk.edge, lineWidth: 1)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.smooth(duration: 0.18), value: model.notice)
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
        LegacyNoteTextEditor(model: model,
                             isHidden: isListing,
                             focusRequests: model.focusRequests,
                             noteID: model.noteID)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxHeight: .infinity)
            // Out of sight in this pass, under the list's not quite opaque
            // black; the text view itself is hidden on the next.
            .opacity(isListing ? 0 : 1)
            .allowsHitTesting(!isListing)
            .accessibilityHidden(isListing)
            .onChange(of: model.text) { _, _ in model.edited() }
    }

    @ViewBuilder private var listing: some View {
        switch model.overlay {
        case .none, .find:
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
                create: { model.onCommand?(.newNote) }
            ) { index, isHighlighted in
                if let summary = model.listedNotes[safe: index] {
                    NotesListRow(summary: summary,
                                 isHighlighted: isHighlighted,
                                 isOpen: summary.id == model.noteID)
                }
            }
        }
    }

    /// The two styles, and the key that opens everything else.
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

/// The note's text view, in SwiftUI.
///
/// Built once and kept. Focus is given by hand, because SwiftUI's focus state
/// does not reach into an AppKit view: the caret goes into the text when the
/// view first appears, when a different note is loaded, when a list over it
/// goes away, and whenever the window asks — the same moments the other
/// editor's `@FocusState` is set.
struct LegacyNoteTextEditor: NSViewRepresentable {

    let model: LegacyNotesEditorModel
    /// A list is drawn over it.
    let isHidden: Bool
    let focusRequests: Int
    let noteID: String?

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let model: LegacyNotesEditorModel
        weak var textView: LegacyNoteTextView?
        var focusRequests: Int
        var noteID: String?
        var wasHidden: Bool

        init(model: LegacyNotesEditorModel, focusRequests: Int, noteID: String?, isHidden: Bool) {
            self.model = model
            self.focusRequests = focusRequests
            self.noteID = noteID
            self.wasHidden = isHidden
        }

        nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            NoteAppKitBridge.clamp(textStorage, in: editedRange)
        }

        /// Tells the model what the text now is, after any change at all.
        ///
        /// The storage rather than the text view's change notification, because
        /// not every change sends one: ⌘Z puts the text back without it, and a
        /// model that missed the undo would save the text as it was before.
        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            MainActor.assumeIsolated {
                guard let textView, !textView.isPresenting, let storage = textView.textStorage else { return }
                model.textViewChanged(NoteAppKitBridge.note(storage))
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                      toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            NoteAppKitBridge.attributes(for: NoteAppKitBridge.intent(of: newTypingAttributes))
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? LegacyNoteTextView else { return }
            textView.removeObjectReplacements()
            report(textView)
        }

        /// The right-click menu without Layout Orientation, which the text view
        /// refuses anyway.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let orientation = #selector(NSTextView.changeLayoutOrientation(_:))
            for item in menu.items where item.submenu?.items.contains(where: { $0.action == orientation }) == true {
                menu.removeItem(item)
            }
            return menu
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? LegacyNoteTextView, !textView.isPresenting else { return }
            report(textView)
        }

        func report(_ textView: LegacyNoteTextView) {
            model.textViewSelected(textView.selectedRanges.map(\.rangeValue),
                                   typing: NoteAppKitBridge.intent(of: textView.typingAttributes))
        }

        /// Puts the caret in the text, once SwiftUI has finished with the pass
        /// that asked for it.
        func focus(_ textView: NSTextView) {
            Task { @MainActor [weak textView] in
                guard let textView, let window = textView.window, !textView.isHiddenOrHasHiddenAncestor else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, focusRequests: focusRequests, noteID: noteID, isHidden: isHidden)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = LegacyNoteTextView.make()
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.textView = textView
        textView.onScroll = { [weak model] in model?.textViewScrolled() }

        let scroll = LegacyNoteScrollView.make(around: textView)
        scroll.isHidden = isHidden

        model.attach(textView)
        // Reported on the next turn rather than now: this is SwiftUI building
        // the view, and the model may not change while it does.
        let coordinator = context.coordinator
        Task { @MainActor [weak textView] in
            guard let textView else { return }
            coordinator.report(textView)
        }
        if !isHidden { coordinator.focus(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if isHidden, !scroll.isHidden {
            // The keyboard leaves the note in this pass, as it leaves the other
            // editor's when that is taken down, so the list arriving can take
            // it. The view is hidden on the next turn: hidden while it still
            // held the keyboard, AppKit would hand it on to some other view
            // there and then, in the middle of SwiftUI's update.
            if let window = scroll.window, let textView = scroll.documentView,
               window.firstResponder === textView {
                window.makeFirstResponder(nil)
            }
            Task { @MainActor [weak scroll, weak coordinator] in
                guard let scroll, let coordinator, coordinator.wasHidden else { return }
                scroll.isHidden = true
            }
        } else if !isHidden, scroll.isHidden {
            scroll.isHidden = false
        }
        let wantsFocus = coordinator.focusRequests != focusRequests
            || coordinator.noteID != noteID
            || (coordinator.wasHidden && !isHidden)
        coordinator.focusRequests = focusRequests
        coordinator.noteID = noteID
        coordinator.wasHidden = isHidden
        if wantsFocus, !isHidden, let textView = scroll.documentView as? NSTextView {
            coordinator.focus(textView)
        }
    }
}
