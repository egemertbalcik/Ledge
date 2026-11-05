import AppKit
import LedgeCore

/// The text of a note on macOS 15, where SwiftUI has no rich text editor.
///
/// A plain `NSTextView` takes anything: a paste, a drop, a Service or the
/// right-click Font menu brings in highlight, colours, fonts, underline and
/// links, none of which Ledge can show a control for or take away again. The
/// other editor's formatting definition keeps all of that out, and this does
/// the same job in AppKit's terms: whatever enters the text by any route is held
/// to bold and italic in Ledge's own face as it arrives (the storage's delegate
/// does that, through `NoteAppKitBridge.clamp`), and so are the typing
/// attributes.
///
/// Everything else about it is the other editor's text view, measured on
/// macOS 26: where SwiftUI sets something AppKit would not, it is set here to
/// the same value, and where SwiftUI leaves AppKit's default, so does this —
/// smart quotes, spelling and the rest follow the user's own settings on both.
final class LegacyNoteTextView: NSTextView {

    /// While the text view is being handed a note rather than edited, so what
    /// it says about its selection is not reported back as the user's.
    private(set) var isPresenting = false

    /// While a search moves the selection and the scroll with it.
    private var isRevealing = false

    /// Told when the person scrolls the note, as opposed to Ledge scrolling it.
    var onScroll: (() -> Void)?

    /// From the scroll view, whenever the note has moved under it.
    func scrolled() {
        guard !isPresenting, !isRevealing else { return }
        onScroll?()
    }

    /// The note's own undo history, apart from the window's.
    ///
    /// ⌘Z in the find bar's or a list's field undoes the field's own typing
    /// and then, with nothing left there, goes on up to the window. While the
    /// note's history was the window's, that undid the note: with a list drawn
    /// over it, a note nobody could see, and the window then saved what it
    /// undid. The other editor never does this — its text view leaves the
    /// window while a list or the find bar is up — and neither does this one.
    private let history = UndoManager()

    override var undoManager: UndoManager? { history }

    /// ⌘Z and ⇧⌘Z, for that history. Left to AppKit, `undo:` and `redo:` go on
    /// up to the window, which undoes from its own.
    ///
    /// Given to the class at run time rather than written as Swift methods:
    /// a Swift method by either name makes every `Selector(("undo:"))` in the
    /// module a warning, the window's own key handling among them.
    private static let undoActions: Void = {
        let undo: @convention(block) (LegacyNoteTextView, Any?) -> Void = { textView, _ in
            if textView.history.canUndo { textView.history.undo() }
        }
        let redo: @convention(block) (LegacyNoteTextView, Any?) -> Void = { textView, _ in
            if textView.history.canRedo { textView.history.redo() }
        }
        class_addMethod(LegacyNoteTextView.self, LegacyNoteTextView.undoAction, imp_implementationWithBlock(undo), "v@:@")
        class_addMethod(LegacyNoteTextView.self, LegacyNoteTextView.redoAction, imp_implementationWithBlock(redo), "v@:@")
    }()

    private static let undoAction = NSSelectorFromString("undo:")
    private static let redoAction = NSSelectorFromString("redo:")

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case Self.undoAction: history.canUndo
        case Self.redoAction: history.canRedo
        default: super.validateUserInterfaceItem(item)
        }
    }

    static func make() -> LegacyNoteTextView {
        _ = undoActions
        let textView = LegacyNoteTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        // AppKit's default is off for a text view built in code, and SwiftUI
        // turns it on. Without it ⌘Z does nothing at all.
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isAutomaticLinkDetectionEnabled = false
        // On in the other editor's text view, and unreachable there: ⌘F is the
        // window's own, and its own find bar is the only one. Off here so no
        // route can put a second one on screen.
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.allowsDocumentBackgroundColorChange = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        // The caret, explicitly. Left to the system it is drawn in the user's
        // accent colour against a near-black window, and a graphite accent puts
        // an invisible insertion point in a window whose purpose is typing.
        textView.insertionPointColor = caret
        // Links never survive into a note, so this only matters for the cursor.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        // What Writing Tools may hand back: words and their styling, not lists
        // or tables, which a note has no way to hold.
        textView.allowedWritingToolsResultOptions = [.plainText, .richText]
        textView.typingAttributes = NoteAppKitBridge.attributes(for: [])
        // The other editor's text sits flush with its frame but for AppKit's
        // own five points of line padding, which is also AppKit's default.
        // Stated rather than assumed, because it decides where every character
        // is drawn.
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }

    /// The caret's colour, as the other editor's `.tint(Color.white.opacity(0.9))`
    /// comes out on its text view: measured there as white at 216 of 255.
    static let caret = NSColor(colorSpace: .extendedSRGB, components: [1, 1, 1, 216.0 / 255.0], count: 4)

    // MARK: - What the model asks of it

    /// Puts a note in, with the caret where the model says, and starts the
    /// undo history over: the note's own, and the window's, which is what the
    /// other editor clears.
    ///
    /// Not an edit. The text view records nothing of it, and the history goes
    /// because what is in it belongs to whatever note was here before: ⌘Z
    /// after a switch would otherwise put the last note's text into this one
    /// and save it there.
    ///
    /// Anything an input method was still composing is let go first, so its
    /// candidates do not stay up over a different note. What was composed is
    /// already in the text the window saved for the note being left, as it is
    /// with the other editor.
    ///
    /// The scroll position stays unless `fromTop` says otherwise, which is
    /// what the other editor does: its text view keeps its offset when a note
    /// is swapped into it, and starts at the top when it is built afresh,
    /// which happens when the note arrives from behind a list.
    func present(_ text: AttributedString, caret: Int, fromTop: Bool) {
        isPresenting = true
        defer { isPresenting = false }
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        textStorage?.setAttributedString(NoteAppKitBridge.appKit(text))
        layOutWhole()
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: min(max(caret, 0), length), length: 0))
        if fromTop { scroll(.zero) }
        breakUndoCoalescing()
        history.removeAllActions()
        window?.undoManager?.removeAllActions()
    }

    /// Lays the whole note out now, as the other editor's text view is laid
    /// out the moment its text arrives.
    ///
    /// Left to TextKit, everything below the window is only estimated: a long
    /// note's scroller is the wrong length until it has been scrolled through,
    /// and a search or a switch lands somewhere other than where the other
    /// editor would put it. Nothing to do yet while the text view has no width;
    /// its scroll view asks again once it has one.
    func layOutWhole() {
        guard let layout = textLayoutManager, (textContainer?.size.width ?? 0) > 0 else { return }
        layout.ensureLayout(for: layout.documentRange)
    }

    /// Turns a style on or off over the selection, or for what is typed next.
    ///
    /// Over a selection it is an edit like any other, so ⌘Z takes it back, as
    /// it does in the other editor.
    func apply(_ intent: InlinePresentationIntent, on: Bool) {
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else {
            var typing = NoteAppKitBridge.intent(of: typingAttributes)
            if on { typing.insert(intent) } else { typing.remove(intent) }
            typingAttributes = NoteAppKitBridge.attributes(for: typing)
            return
        }
        guard let storage = textStorage,
              shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil)
        else { return }
        storage.beginEditing()
        for range in ranges {
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                var current = NoteAppKitBridge.intent(of: attributes)
                if on { current.insert(intent) } else { current.remove(intent) }
                storage.setAttributes(NoteAppKitBridge.attributes(for: current), range: run)
            }
        }
        storage.endEditing()
        didChangeText()
    }

    /// Selects a match and scrolls to it.
    func reveal(_ range: NSRange) {
        let length = (string as NSString).length
        guard range.location != NSNotFound, NSMaxRange(range) <= length else { return }
        isRevealing = true
        defer { isRevealing = false }
        setSelectedRange(range)
        scrollRangeToVisible(range)
    }

    /// Takes out what an image or a file left behind, as part of the change
    /// that brought it.
    ///
    /// Made as an edit of its own inside the paste or the drop, so it joins
    /// that change's undo group: one ⌘Z takes back the paste and this
    /// together, as it does the panel's tidying of a pasted list.
    ///
    /// Not while an input method is composing. Until the composition ends, a
    /// replacement character can sit in the text view while the note, which
    /// never holds one, does not, and every offset after it is one apart
    /// between the two; the next change after the composition takes it out.
    func removeObjectReplacements() {
        guard !hasMarkedText(), let storage = textStorage else { return }
        let buffer = storage.mutableString
        guard buffer.range(of: NoteAppKitBridge.objectReplacement, options: .literal).location != NSNotFound
        else { return }
        var ranges: [NSRange] = []
        var at = buffer.range(of: NoteAppKitBridge.objectReplacement, options: .literal)
        while at.location != NSNotFound {
            ranges.append(at)
            let from = NSMaxRange(at)
            at = buffer.range(of: NoteAppKitBridge.objectReplacement, options: .literal,
                              range: NSRange(location: from, length: buffer.length - from))
        }
        guard shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
                               replacementStrings: ranges.map { _ in "" })
        else { return }
        storage.beginEditing()
        for range in ranges.reversed() { storage.deleteCharacters(in: range) }
        storage.endEditing()
        didChangeText()
    }

    // MARK: - Fonts and layout

    /// The Font menu and the Font panel, as the other editor takes them: the
    /// face they ask for decides bold and italic, and the face drawn is Ledge's.
    ///
    /// Done here rather than left to `NSTextView`, because a run Ledge styled
    /// carries its intent, and the intent is what is believed over a face (a
    /// fallback font AppKit swaps in for an emoji must not make bold plain).
    /// Each run's own face is what the menu converts, so the menu's Bold on
    /// italic text gives bold italic, as it does in the other editor.
    ///
    /// A run whose bold and italic the menu leaves as they were is left alone,
    /// so Bigger, Smaller or a new family make no edit, no undo step and no
    /// save of their own.
    override func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager else { return super.changeFont(sender) }
        func converted(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]? {
            let was = NoteAppKitBridge.intent(of: attributes)
            let now = NoteAppKitBridge.intent(of: manager.convert(NoteAppKitBridge.font(for: was)))
            guard now != was else { return nil }
            var out = NoteAppKitBridge.attributes(for: now)
            for key in [NSAttributedString.Key.markedClauseSegment, .textAlternatives] {
                if let value = attributes[key] { out[key] = value }
            }
            return out
        }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else {
            if let typing = converted(typingAttributes) { typingAttributes = typing }
            return
        }
        guard let storage = textStorage else { return }
        var changes: [(NSRange, [NSAttributedString.Key: Any])] = []
        for range in ranges {
            storage.enumerateAttributes(in: range) { attributes, run, _ in
                if let new = converted(attributes) { changes.append((run, new)) }
            }
        }
        guard !changes.isEmpty,
              shouldChangeText(inRanges: changes.map { NSValue(range: $0.0) }, replacementStrings: nil)
        else { return }
        storage.beginEditing()
        for (run, attributes) in changes { storage.setAttributes(attributes, range: run) }
        storage.endEditing()
        didChangeText()
    }

    /// What the Font panel shows as the selection's font: Ledge's face for
    /// it, not whatever fallback AppKit drew an emoji or a Chinese character
    /// in, which the panel would otherwise offer to change.
    override func updateFontPanel() {
        guard usesFontPanel, let storage = textStorage, window?.firstResponder === self else { return }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        var intents: [InlinePresentationIntent] = []
        if ranges.isEmpty {
            intents = [NoteAppKitBridge.intent(of: typingAttributes)]
        } else {
            for range in ranges {
                storage.enumerateAttributes(in: range) { attributes, _, _ in
                    intents.append(NoteAppKitBridge.intent(of: attributes))
                }
            }
        }
        NSFontManager.shared.setSelectedFont(NoteAppKitBridge.font(for: intents.first ?? []),
                                             isMultiple: Set(intents.map(\.rawValue)).count > 1)
    }

    /// Never vertical. The right-click menu offers it on every text view, and
    /// the other editor's turns sideways when it is chosen; a note window
    /// sized for lines across has no use for it.
    override func changeLayoutOrientation(_ sender: Any?) {}

    // MARK: - Keys and the pasteboard

    /// Never while a list is drawn over it. Hidden, it is already out of the
    /// key view loop and out of reach of a click; this closes the last way in,
    /// a window being told to put it there, so the keyboard cannot end up in a
    /// note nobody can see.
    override var acceptsFirstResponder: Bool {
        !isHiddenOrHasHiddenAncestor && super.acceptsFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        !isHiddenOrHasHiddenAncestor && super.becomeFirstResponder()
    }

    /// Escape belongs to the window, which uses it to go back.
    ///
    /// The other editor's text view was measured handing it up to the window,
    /// for the key and for the command alike. Said here rather than left to
    /// `NSTextView`, whose own answer to Escape can be to offer completions.
    override func cancelOperation(_ sender: Any?) {
        window?.cancelOperation(sender)
    }

    /// The pasteboard names AppKit writes rich text and plain text under.
    /// `NSTextView` answers to these and not to `.rtf` and `.string`, which are
    /// the same types by their newer names.
    private static let richText = NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type")
    private static let plainText = NSPasteboard.PasteboardType("NSStringPboardType")

    /// Rich text and plain text: what the other editor puts on the pasteboard
    /// that anything outside Ledge can read. Its remaining two types are
    /// SwiftUI's own.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes.filter { $0 == Self.richText || $0 == Self.plainText }
    }

    /// The rich text without the window's ink, in Ledge's own faces.
    ///
    /// The note is drawn near-white on near-black, and that colour is the
    /// window's, not the note's. Written into the copy it arrives in a white
    /// document as white text, which is to say as nothing. The faces go as
    /// the note has them, with the line spacing: each run in the face its
    /// bold and italic call for, not the fallback font AppKit may be drawing
    /// an emoji or a Chinese character in, which is not bold and would come
    /// back plain wherever it was pasted, this window included.
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == Self.richText || type == .rtf else { return super.writeSelection(to: pboard, type: type) }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        if ranges.count == 1, let storage = textStorage, NSMaxRange(ranges[0]) <= storage.length {
            let copied = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: ranges[0]))
            let whole = NSRange(location: 0, length: copied.length)
            copied.enumerateAttributes(in: whole) { attributes, run, _ in
                copied.setAttributes([.font: NoteAppKitBridge.font(for: NoteAppKitBridge.intent(of: attributes)),
                                      .paragraphStyle: NoteAppKitBridge.paragraphStyle], range: run)
            }
            guard let rich = copied.rtf(from: whole, documentAttributes: [:]) else { return false }
            return pboard.setData(rich, forType: type)
        }
        // Several ranges at once, from an Option-drag: AppKit's own rich text
        // for them, however it joins them, read back and written again without
        // the colour. Its faces are the ones drawn.
        let scratch = NSPasteboard(name: NSPasteboard.Name("com.egemert.ledge.notes-copy-\(UUID().uuidString)"))
        defer { scratch.releaseGlobally() }
        scratch.declareTypes([Self.richText], owner: nil)
        guard super.writeSelection(to: scratch, type: Self.richText),
              let data = scratch.data(forType: Self.richText),
              let copied = NSMutableAttributedString(rtf: data, documentAttributes: nil)
        else { return false }
        let whole = NSRange(location: 0, length: copied.length)
        copied.removeAttribute(.foregroundColor, range: whole)
        guard let clean = copied.rtf(from: whole, documentAttributes: [:]) else { return false }
        return pboard.setData(clean, forType: type)
    }
}

/// The scroll view the note's text sits in, as the other editor's does.
final class LegacyNoteScrollView: NSScrollView {

    static func make(around textView: NSTextView) -> LegacyNoteScrollView {
        let scroll = LegacyNoteScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        // Measured on the other editor's: it bounces vertically and never
        // sideways, where AppKit would decide both for itself.
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = textView
        // A scroller dragged or a trackpad swiped; the wheel is below.
        NotificationCenter.default.addObserver(scroll, selector: #selector(scrolledByHand),
                                               name: NSScrollView.didLiveScrollNotification, object: scroll)
        return scroll
    }

    /// The width the note was last laid out whole at.
    private var laidOutWidth: CGFloat = 0

    /// Tells the text view when the person moves the note under the window.
    ///
    /// Only then: the text view moves it too — to keep the caret in sight as
    /// it takes the keyboard back, to show a search's match — and none of
    /// that is somebody choosing where to read.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        scrolledByHand()
    }

    @objc private func scrolledByHand() {
        (documentView as? LegacyNoteTextView)?.scrolled()
    }

    /// The text view is kept at least as large as what shows of it, as the
    /// other editor's is, so a click below the last line still lands in the
    /// text rather than on nothing; and laid out whole again whenever its
    /// width changes, which undoes every line of the layout before.
    override func tile() {
        super.tile()
        guard let textView = documentView as? LegacyNoteTextView else { return }
        if textView.minSize != contentSize { textView.minSize = contentSize }
        if contentSize.width > 0, contentSize.width != laidOutWidth {
            laidOutWidth = contentSize.width
            textView.layOutWhole()
        }
    }
}
