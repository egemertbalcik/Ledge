import AppKit
import Foundation
import LedgeCore
import LedgeSystem
import Testing
@testable import LedgeShell

/// The macOS 15 editor on its own: what it must do whichever macOS it runs on.
///
/// Hosted as `NotesUndoTests` hosts an editor — a real `NotesPanel` over a
/// store in a scratch folder, never key, far off every screen — and driven
/// through its text view the way AppKit drives it. Nothing here needs macOS 26,
/// so all of it also runs on 15, where nothing else can stand in for it.
@MainActor
@Suite("Notes AppKit editor", .serialized, .timeLimit(.minutes(5)))
struct LegacyNotesEditorTests {

    typealias Harness = NotesUndoTests.Harness

    private func arrive(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(250)) }

    /// A harness with this note open in the AppKit editor.
    private func open(_ text: AttributedString) async throws -> (Harness, LegacyNotesEditorModel, LegacyNoteTextView) {
        _ = NSApplication.shared
        let h = Harness(.appKit)
        let note = await h.store.create()
        await h.store.update(note.id, text: text)
        await h.store.flush()
        let body = try #require(await h.store.body(note.id))
        h.hosting.layoutSubtreeIfNeeded()
        h.present(body)
        let textView = try #require(h.textView() as? LegacyNoteTextView)
        try #require(await arrive { textView.string == String(text.characters) }, "the note is on screen")
        let model = try #require(h.model as? LegacyNotesEditorModel)
        return (h, model, textView)
    }

    private func done(_ h: Harness) {
        h.model.onEdit = nil
        h.panel.orderOut(nil)
        h.panel.close()
    }

    private func runs(_ text: AttributedString) -> [String] {
        text.runs.map { "\(String(text.characters[$0.range]))=\($0.inlinePresentationIntent?.rawValue ?? 0)" }
    }

    // MARK: - The window's choice

    @Test("The window shows the SwiftUI editor on macOS 26 and the AppKit one before it")
    func windowChoosesByVersion() throws {
        _ = NSApplication.shared
        let controller = NotesWindowController(
            store: NotesStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ledge-notes-legacy-tests/\(UUID().uuidString)", isDirectory: true)),
            preferences: Preferences(store: MemoryPreferenceStore()))
        let model = try #require(Mirror(reflecting: controller).children.first { $0.label == "model" }?.value)
        if #available(macOS 26.0, *) {
            try #require(ProcessInfo.processInfo.environment["LEDGE_LEGACY_NOTES"] != "1",
                         "the switch for trying the macOS 15 editor is off")
            #expect(model is NotesEditorModel)
        } else {
            #expect(model is LegacyNotesEditorModel)
        }
    }

    // MARK: - Set up as measured

    @Test("The text view is set up as the macOS 26 editor's was measured")
    func setUpAsMeasured() async throws {
        let (h, _, textView) = try await open(AttributedString("words"))
        defer { done(h) }
        #expect(textView.textLayoutManager != nil, "TextKit 2")
        #expect(textView.allowsUndo)
        #expect(textView.isRichText)
        #expect(!textView.importsGraphics)
        #expect(!textView.usesFindBar)
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        #expect(!textView.drawsBackground)
        #expect(textView.textContainerInset == .zero)
        #expect(textView.textContainer?.lineFragmentPadding == 5)
        #expect(textView.allowedWritingToolsResultOptions.rawValue == 3)
        #expect(textView.autoresizingMask == [.width, .height])
        let caret = try #require(textView.insertionPointColor.usingColorSpace(.sRGB))
        #expect([caret.redComponent, caret.greenComponent, caret.blueComponent] == [1, 1, 1])
        #expect(abs(caret.alphaComponent - 216.0 / 255.0) < 0.001)
        let scroll = try #require(textView.enclosingScrollView)
        #expect(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller)
        #expect(!scroll.drawsBackground && !scroll.contentView.drawsBackground)
        #expect(scroll.verticalScrollElasticity == .allowed && scroll.horizontalScrollElasticity == .none)
        #expect(textView.minSize == scroll.contentSize, "a click below the last line lands in the text")
        let frame = scroll.convert(scroll.bounds, to: h.hosting)
        #expect(frame == CGRect(x: 12, y: 55, width: 336, height: 328), "where the macOS 26 editor's sits: \(frame)")
    }

    @Test("The note is drawn where, and as, the macOS 26 editor was measured drawing it")
    func matchesWhatWasMeasured() async throws {
        let measured = try await NotesEditorFixture.measure(.appKit)
        // To the hundredth of a point where it was measured. Elsewhere the
        // system font may measure a little differently, which moves every
        // character without anything being wrong, so only what that cannot
        // move is held.
        let differences: [String]
        if #available(macOS 26.0, *) {
            differences = NotesEditorFixture.differences(measured, from: NotesEditorFixture.swiftUI)
        } else {
            differences = NotesEditorFixture.structuralDifferences(measured, from: NotesEditorFixture.swiftUI)
        }
        #expect(differences.isEmpty, "\(differences.count) differences: \(differences.prefix(12))")
        // The looser test passes where the exact one does, or it holds nothing.
        #expect(NotesEditorFixture.structuralDifferences(measured, from: NotesEditorFixture.swiftUI).isEmpty)
    }

    @Test("Every character that draws something is in the picture, and one word made bold changes it")
    func pictureHasTheNote() async throws {
        let (h, textView) = try await NotesEditorFixture.open(.appKit, NotesEditorFixture.sample)
        defer { done(h) }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        _ = h.panel.makeFirstResponder(nil)
        await settle()
        let before = try NotesEditorFixture.picture(h.hosting)
        let visible = NotesEditorFixture.visibleCharacters(textView, in: h)
        try #require(visible.count > 200, "the note's characters were looked for")
        for (character, location, rect) in visible {
            #expect(NotesEditorFixture.drawn(before, in: rect, of: h.hosting),
                    "\(character.debugDescription) at \(location) is not in the picture at \(rect)")
        }
        let model = try #require(h.model as? LegacyNotesEditorModel)
        textView.setSelectedRange((textView.string as NSString).range(of: "tail"))
        model.toggle(.stronglyEmphasized)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        _ = h.panel.makeFirstResponder(nil)
        await settle()
        let after = try NotesEditorFixture.picture(h.hosting)
        #expect(!NotesEditorFixture.difference(before, after, of: h.hosting).isEmpty, "a bold word shows")
    }

    @Test("A line that starts right to left sits on the right")
    func rightToLeftLineIsRightAligned() async throws {
        let (h, _, textView) = try await open(AttributedString("left to right\nשלום עולם\nمرحبا"))
        defer { done(h) }
        let string = textView.string as NSString
        for word in ["שלום", "مرحبا"] {
            let first = NSRange(location: string.range(of: word).location, length: 1)
            let onScreen = textView.firstRect(forCharacterRange: first, actualRange: nil)
            let inView = textView.convert(h.panel.convertFromScreen(onScreen), from: nil)
            #expect(inView.maxX > textView.bounds.width - 10, "\(word) starts at the right: \(inView)")
        }
        let latin = textView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        #expect(textView.convert(h.panel.convertFromScreen(latin), from: nil).minX < 10)
    }

    @Test("A long note is laid out whole as soon as it opens")
    func longNoteIsLaidOutWhole() async throws {
        let lines = 400
        let (h, _, textView) = try await open(AttributedString((0 ..< lines).map { "Line \($0)" }.joined(separator: "\n")))
        defer { done(h) }
        let layout = try #require(textView.textLayoutManager)
        let height = layout.usageBoundsForTextContainer.height
        let line = textView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil).height
        #expect(abs(height - CGFloat(lines) * (line + 3) + 3) < 1, "\(height) for \(lines) lines of \(line) and 3 between")
        #expect(await arrive { textView.frame.height == height }, "the scroller is the note's length: \(textView.frame.height)")
    }

    @Test("A note loaded before its window is built is laid out whole too")
    func noteLoadedEarlyIsLaidOutWhole() async throws {
        _ = NSApplication.shared
        let h = Harness(.appKit)
        defer { done(h) }
        let lines = 300
        // The window's first open with no warm-up before it: the note arrives
        // while the text view does not exist yet.
        h.present(NoteBody(id: "early", text: AttributedString((0 ..< lines).map { "Line \($0)" }.joined(separator: "\n")),
                           createdAt: 0, editedAt: 0))
        h.hosting.layoutSubtreeIfNeeded()
        let textView = try #require(h.textView())
        try #require(await arrive { (textView.string as NSString).length > 0 }, "the note reached the text view")
        let line = textView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil).height
        let whole = CGFloat(lines) * (line + 3) - 3
        #expect(await arrive { abs(textView.frame.height - whole) < 1 }, "\(textView.frame.height), not \(whole)")
    }

    // MARK: - One text view

    @Test("One text view, kept through the find bar, both lists and a switch")
    func oneTextViewIsKept() async throws {
        let long = AttributedString((0 ..< 120).map { "Line \($0)" }.joined(separator: "\n"))
        let (h, model, textView) = try await open(long)
        defer { done(h) }
        textView.scrollRangeToVisible(NSRange(location: 600, length: 1))
        await settle()
        let offset = textView.enclosingScrollView?.contentView.bounds.minY ?? 0
        try #require(offset > 0, "the note is scrolled")
        for overlay in [NotesOverlay.find, .commands, .notes] {
            model.show(overlay)
            await settle()
            #expect(textView.enclosingScrollView?.isHidden == (overlay != .find), "\(overlay)")
            #expect(h.panel.firstResponder !== textView, "\(overlay) has the keyboard, not the hidden note")
            model.dismissOverlay()
            #expect(await arrive { h.panel.firstResponder === textView }, "the caret is back in the note after \(overlay)")
            #expect(h.textView() === textView, "the same text view after \(overlay)")
            #expect(textView.enclosingScrollView?.isHidden == false)
        }
        #expect(textView.enclosingScrollView?.contentView.bounds.minY == offset, "and still where it was read")
        h.present(NoteBody(id: "other", text: AttributedString("other"), createdAt: 0, editedAt: 0))
        await settle()
        #expect(h.textView() === textView)
    }

    @Test("A list over the note never leaves the keyboard in it")
    func listTakesTheKeyboard() async throws {
        let (h, model, textView) = try await open(AttributedString("a note"))
        defer { done(h) }
        try #require(await arrive { h.panel.firstResponder === textView }, "the caret starts in the note")
        model.notes = [NoteSummary(id: "x", title: "X", preview: "", editedAt: 0)]
        model.show(.notes)
        // Which view takes it instead is SwiftUI's to decide, and in a window
        // that is never key it decides nothing for either editor; that the list's
        // own field has it is for a real window to show.
        #expect(await arrive { h.panel.firstResponder !== textView }, "the note gave it up")
        #expect(await arrive { textView.enclosingScrollView?.isHidden == true })
        textView.window?.makeFirstResponder(textView)
        #expect(h.panel.firstResponder !== textView, "a hidden note cannot take the keyboard")
    }

    @Test("⌘F puts the keyboard in the find field, and Escape from there goes back to the note")
    func findTakesTheKeyboard() async throws {
        let (h, model, textView) = try await open(AttributedString("find me here"))
        defer { done(h) }
        try #require(await arrive { h.panel.firstResponder === textView })
        model.show(.find)
        #expect(await arrive { (h.panel.firstResponder as? NSTextView)?.isFieldEditor == true })
        model.dismissOverlay()
        #expect(await arrive { h.panel.firstResponder === textView })
    }

    @Test("Asked for, the caret goes back into the text")
    func focusRequestsReachTheText() async throws {
        let (h, model, textView) = try await open(AttributedString("a note"))
        defer { done(h) }
        try #require(await arrive { h.panel.firstResponder === textView })
        _ = h.panel.makeFirstResponder(nil)
        try #require(h.panel.firstResponder !== textView)
        model.requestFocus()
        #expect(await arrive { h.panel.firstResponder === textView })
    }

    // MARK: - Finding

    @Test("A search selects each match and scrolls to it")
    func searchScrollsToTheMatch() async throws {
        let long = AttributedString((0 ..< 200).map { "Line \($0)" }.joined(separator: "\n") + "\nthe needle")
        let (h, model, textView) = try await open(long)
        defer { done(h) }
        textView.scroll(.zero)
        model.show(.find)
        model.findQuery = "needle"
        let match = (textView.string as NSString).range(of: "needle")
        #expect(model.matches == [match])
        #expect(model.matchSummary == "1 of 1")
        #expect(textView.selectedRange() == match)
        let rect = textView.convert(h.panel.convertFromScreen(
            textView.firstRect(forCharacterRange: match, actualRange: nil)), from: nil)
        #expect(textView.visibleRect.contains(rect), "\(rect) is on screen in \(textView.visibleRect)")
        model.findQuery = "line 1"
        #expect(model.matches.count == 111)
        model.stepMatch(-1)
        #expect(model.matchSummary == "111 of 111")
        #expect(textView.selectedRange() == model.matches.last)
    }

    // MARK: - Typing and styling

    @Test("What is typed reaches the model and the store")
    func typingReachesTheStore() async throws {
        let (h, model, textView) = try await open(AttributedString("Title"))
        defer { done(h) }
        var told: [AttributedString] = []
        h.model.onEdit = { told.append($0) }
        _ = h.panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText("\nbody", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(String(model.text.characters) == "Title\nbody")
        #expect(model.title == "Title")
        #expect(await arrive { told.last.map { String($0.characters) } == "Title\nbody" }, "the window was told")
        #expect(told.allSatisfy { $0 == NoteText.normalized($0) }, "only ever the stored form")
    }

    @Test("Bold and italic over a selection, and the chips say so")
    func styleOverASelection() async throws {
        let (h, model, textView) = try await open(AttributedString("one two three"))
        defer { done(h) }
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        #expect(!model.isActive(.stronglyEmphasized))
        model.toggle(.stronglyEmphasized)
        #expect(runs(model.text) == ["one =0", "two=2", " three=0"])
        #expect(model.isActive(.stronglyEmphasized))
        model.toggle(.emphasized)
        #expect(runs(model.text) == ["one =0", "two=3", " three=0"])
        let font = try #require(textView.textStorage?.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
        #expect(font == NoteAppKitBridge.font(for: [.stronglyEmphasized, .emphasized]))
        model.toggle(.stronglyEmphasized)
        #expect(runs(model.text) == ["one =0", "two=1", " three=0"])
        #expect(textView.selectedRange() == NSRange(location: 4, length: 3), "the selection stays")
        textView.setSelectedRange(NSRange(location: 2, length: 4))
        #expect(!model.isActive(.emphasized), "part italic is not italic")
        // Italic, then bold italic, with nothing between: italic throughout,
        // but not one style throughout, which is the other editor's test.
        textView.setSelectedRange(NSRange(location: 7, length: 6))
        model.toggle(.stronglyEmphasized)
        model.toggle(.emphasized)
        try #require(runs(model.text) == ["one =0", "two=1", " three=3"])
        textView.setSelectedRange(NSRange(location: 4, length: 9))
        #expect(!model.isActive(.emphasized), "italic beside bold italic is not shown as italic")
    }

    @Test("Bold at a caret is what the next keystroke types")
    func styleAtACaret() async throws {
        let (h, model, textView) = try await open(AttributedString("plain"))
        defer { done(h) }
        _ = h.panel.makeFirstResponder(textView)
        #expect(!model.isActive(.stronglyEmphasized))
        model.toggle(.stronglyEmphasized)
        #expect(model.isActive(.stronglyEmphasized), "the chip lights before anything is typed")
        textView.insertText("B", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(runs(model.text) == ["plain=0", "B=2"])
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(!model.isActive(.stronglyEmphasized), "moving into plain text is plain again")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(model.isActive(.stronglyEmphasized), "after the bold letter it is bold")
    }

    @Test("Formatting from anywhere but the chips is held to bold and italic")
    func foreignFormattingIsClamped() async throws {
        let (h, model, textView) = try await open(AttributedString("Before AFTER"))
        defer { done(h) }
        let range = NSRange(location: 0, length: 6)
        let storage = try #require(textView.textStorage)
        // What the Font panel, a colour drop and the context menu do: an
        // attribute change through the text view.
        try #require(textView.shouldChangeText(in: range, replacementString: nil))
        storage.addAttributes([.font: try #require(NSFont(name: "Georgia-Bold", size: 24)),
                               .foregroundColor: NSColor.red, .underlineStyle: NSUnderlineStyle.single.rawValue,
                               .backgroundColor: NSColor.white, .kern: 3.0], range: range)
        textView.didChangeText()
        textView.setSelectedRange(range)
        textView.alignCenter(nil)
        textView.raiseBaseline(nil)
        textView.loosenKerning(nil)
        textView.underline(nil)
        await settle()
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, run, _ in
            #expect(NoteAppKitBridge.clamped(attributes) == nil, "\(run): \(attributes)")
        }
        #expect(runs(model.text) == ["Before=2", " AFTER=0"], "the bold face became Ledge's bold")
        #expect(foreign(in: model.text).isEmpty)
    }

    @Test("The Font menu's size and family change nothing, and leave no undo step or save behind")
    func fontMenuWithoutStyleIsNoEdit() async throws {
        let (h, model, textView) = try await open(AttributedString("some plain words"))
        defer { done(h) }
        var told = 0
        h.model.onEdit = { _ in told += 1 }
        let alternatives = NSTextAlternatives(primaryString: "some", alternativeStrings: ["sum"])
        let storage = try #require(textView.textStorage)
        let keeper = storage.delegate
        storage.delegate = nil
        storage.addAttribute(.textAlternatives, value: alternatives, range: NSRange(location: 0, length: 4))
        storage.delegate = keeper
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        let manager = NSFontManager.shared
        defer { manager.target = nil }
        manager.target = textView
        let bigger = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        bigger.tag = Int(NSFontAction.sizeUpFontAction.rawValue)
        manager.modifyFont(bigger)
        #expect(textView.undoManager?.canUndo == false, "no undo step")
        #expect(told == 0, "nothing to save")
        // Bold from the same menu is an edit, and dictation's alternatives
        // stay on the words they belong to.
        let bold = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        bold.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
        manager.addFontTrait(bold)
        #expect(runs(model.text) == ["some plain words=2"])
        #expect(textView.undoManager?.canUndo == true)
        #expect(storage.attribute(.textAlternatives, at: 0, effectiveRange: nil) as? NSTextAlternatives === alternatives)
    }

    @Test("The Font panel is shown Ledge's face, not a fallback one an emoji is drawn in")
    func fontPanelSeesLedgeFace() async throws {
        var text = AttributedString("bold 🎉 here")
        text[text.range(of: "🎉")!].inlinePresentationIntent = .stronglyEmphasized
        let (h, _, textView) = try await open(text)
        defer { done(h) }
        let storage = try #require(textView.textStorage)
        let range = (storage.string as NSString).range(of: "🎉")
        let keeper = storage.delegate
        storage.delegate = nil
        storage.addAttribute(.font, value: try #require(NSFont(name: "AppleColorEmoji", size: 13)), range: range)
        storage.delegate = keeper
        _ = h.panel.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.updateFontPanel()
        #expect(NSFontManager.shared.selectedFont?.fontName == NoteAppKitBridge.font(for: .stronglyEmphasized).fontName,
                "\(NSFontManager.shared.selectedFont?.fontName ?? "none")")
    }

    @Test("Typing attributes cannot carry a highlight or a foreign face")
    func typingAttributesAreClamped() async throws {
        let (h, _, textView) = try await open(AttributedString("text"))
        defer { done(h) }
        textView.typingAttributes = [.backgroundColor: NSColor.white, .foregroundColor: NSColor.black,
                                     .font: NSFont(name: "Georgia-Italic", size: 30) ?? NSFont.systemFont(ofSize: 30)]
        #expect(NoteAppKitBridge.clamped(textView.typingAttributes) == nil, "\(textView.typingAttributes)")
        #expect(NoteAppKitBridge.intent(of: textView.typingAttributes) == .emphasized)
    }

    @Test("An object replacement character never stays in the text, and goes in the same ⌘Z")
    func objectReplacementIsRemoved() async throws {
        let (h, model, textView) = try await open(AttributedString("start"))
        defer { done(h) }
        _ = h.panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.breakUndoCoalescing()
        textView.insertText(" a\u{FFFC}b", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "start ab")
        #expect(String(model.text.characters) == "start ab")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))
        #expect(h.pressUndo())
        #expect(await arrive { textView.string == "start" && String(model.text.characters) == "start" })
    }

    // MARK: - Keys and the pasteboard

    @Test("Escape in the text goes to the window")
    func escapeGoesToTheWindow() async throws {
        let (h, _, textView) = try await open(AttributedString("words"))
        defer { done(h) }
        var escapes = 0
        h.panel.onEscape = { escapes += 1 }
        _ = h.panel.makeFirstResponder(textView)
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(escapes == 1)
        // The key itself, handed to the window as AppKit hands it one.
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: h.panel.windowNumber, context: nil,
                                                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                isARepeat: false, keyCode: 53))
        try #require(h.panel.firstResponder === textView, "the key goes to the note")
        h.panel.sendEvent(key)
        #expect(escapes == 2)
        #expect(textView.string == "words")
    }

    @Test("Bold, then the window is told, as it is for any edit")
    func toggleReachesTheWindow() async throws {
        let (h, model, textView) = try await open(AttributedString("one two"))
        defer { done(h) }
        var told: [AttributedString] = []
        h.model.onEdit = { told.append($0) }
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        model.toggle(.stronglyEmphasized)
        let last = try #require(told.last, "told straight away, as the other editor's toggle tells it")
        #expect(runs(last) == ["one =0", "two=2"])
    }

    @Test("Text in the middle of being composed is let go by a load, and kept by the note it was typed in")
    func compositionAcrossALoad() async throws {
        let (h, model, textView) = try await open(AttributedString("note A "))
        defer { done(h) }
        _ = h.panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(textView.hasMarkedText(), "composing")
        // What the window saves for the note it is leaving, as the other
        // editor's model also holds it: the composition included.
        #expect(String(NoteText.normalized(model.text).characters) == "note A にほん")
        model.load(NoteBody(id: "B", text: AttributedString("note B"), createdAt: 0, editedAt: 0))
        #expect(!textView.hasMarkedText(), "nothing is still being composed into the next note")
        #expect(textView.string == "note B")
        #expect(String(model.text.characters) == "note B")
        textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(String(model.text.characters) == "note B!", "typing goes on normally")
    }

    @Test("A note picked from All Notes starts at its top, as the other editor's does")
    func pickedFromTheListStartsAtTheTop() async throws {
        let long = AttributedString((0 ..< 150).map { "Line \($0)" }.joined(separator: "\n"))
        let (h, model, textView) = try await open(long)
        defer { done(h) }
        let clip = try #require(textView.enclosingScrollView?.contentView)
        textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length - 1, length: 1))
        await settle()
        try #require(clip.bounds.minY > 0, "scrolled down")
        // What a pick does: the list goes, then the note arrives.
        model.notes = [NoteSummary(id: "other", title: "Other", preview: "", editedAt: 0)]
        model.show(.notes)
        await settle()
        model.dismissOverlay()
        model.load(NoteBody(id: "other", text: long, createdAt: 0, editedAt: 0))
        await settle()
        #expect(clip.bounds.minY == 0)
        // Typing settles the note in place, and the next swap keeps it.
        textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length - 1, length: 1))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        await settle()
        let offset = clip.bounds.minY
        try #require(offset > 0)
        model.load(NoteBody(id: "third", text: long, createdAt: 0, editedAt: 0))
        await settle()
        #expect(clip.bounds.minY == offset, "a swap with nothing over the note keeps its place")
    }

    @Test("Scrolled after a list went, a note keeps its place through the next switch, as the other editor's does")
    func scrolledAfterAListKeepsItsPlace() async throws {
        let long = AttributedString((0 ..< 150).map { "Line \($0)" }.joined(separator: "\n"))
        let (h, model, textView) = try await open(long)
        defer { done(h) }
        let scroll = try #require(textView.enclosingScrollView)
        let clip = scroll.contentView
        model.notes = [NoteSummary(id: "other", title: "Other", preview: "", editedAt: 0)]
        model.show(.notes)
        await settle()
        model.dismissOverlay()
        await settle()
        try #require(clip.bounds.minY == 0, "back at the top")
        // A scroll by hand, as AppKit reports one: the note moves under the
        // window and the scroll view says it was the person's doing.
        clip.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        let offset = clip.bounds.minY
        try #require(offset == 600, "scrolled")
        model.load(NoteBody(id: "other", text: long, createdAt: 0, editedAt: 0))
        await settle()
        #expect(clip.bounds.minY == offset)
    }

    @Test("The text never turns vertical, and the right-click menu does not offer it")
    func neverVertical() async throws {
        let (h, _, textView) = try await open(AttributedString("words"))
        defer { done(h) }
        let vertical = NSMenuItem(title: "Vertical", action: #selector(NSTextView.changeLayoutOrientation(_:)),
                                  keyEquivalent: "")
        vertical.tag = NSLayoutManager.TextLayoutOrientation.vertical.rawValue
        textView.changeLayoutOrientation(vertical)
        #expect(textView.layoutOrientation == .horizontal)
        let click = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 40, y: 360),
                                                    modifierFlags: [], timestamp: 0, windowNumber: h.panel.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(textView.menu(for: click), "the text view has a right-click menu")
        try #require(menu.items.contains { $0.submenu != nil }, "with its submenus")
        let orientation = #selector(NSTextView.changeLayoutOrientation(_:))
        #expect(!menu.items.contains { $0.submenu?.items.contains { $0.action == orientation } == true })
    }

    @Test("A copy is rich and plain text without the window's ink")
    func copyLeavesTheInkBehind() async throws {
        var text = AttributedString("plain BOLD ITAL")
        text[text.range(of: "BOLD")!].inlinePresentationIntent = .stronglyEmphasized
        text[text.range(of: "ITAL")!].inlinePresentationIntent = .emphasized
        let (h, _, textView) = try await open(text)
        defer { done(h) }
        let board = NSPasteboard(name: NSPasteboard.Name("ledge-notes-legacy-copy-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        #expect(textView.writeSelection(to: board, types: textView.writablePasteboardTypes))
        #expect(board.string(forType: .string) == "plain BOLD ITAL")
        let rich = try #require(board.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        #expect(rich.string == "plain BOLD ITAL")
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attributes, _, _ in
            #expect(attributes[.foregroundColor] == nil)
        }
        let bold = (rich.string as NSString).range(of: "BOLD").location
        #expect(NoteAppKitBridge.intent(of: rich.attributes(at: bold, effectiveRange: nil)) == .stronglyEmphasized)
        let italic = (rich.string as NSString).range(of: "ITAL").location
        #expect(NoteAppKitBridge.intent(of: rich.attributes(at: italic, effectiveRange: nil)) == .emphasized)
        #expect(!(board.types ?? []).contains(.rtfd))
    }

    @Test("A copy keeps the bold and italic of characters drawn in a fallback face, pasted back in")
    func copyKeepsStylesThroughFallbackFaces() async throws {
        var text = AttributedString("the bank 🏦 ✓ and 中文 end")
        text[text.range(of: "🏦 ✓")!].inlinePresentationIntent = .stronglyEmphasized
        text[text.range(of: "中文")!].inlinePresentationIntent = .emphasized
        let (h, _, textView) = try await open(text)
        defer { done(h) }
        // The storage drawing them in the fonts AppKit falls back to, which
        // are not bold or italic.
        let storage = try #require(textView.textStorage)
        let string = storage.string as NSString
        let emoji = try #require(NSFont(name: "AppleColorEmoji", size: 13))
        let chinese = try #require(NSFont(name: "PingFangSC-Regular", size: 13))
        let keeper = storage.delegate
        storage.delegate = nil
        storage.addAttribute(.font, value: emoji, range: string.range(of: "🏦"))
        storage.addAttribute(.font, value: chinese, range: string.range(of: "中文"))
        storage.delegate = keeper
        try #require(NoteAppKitBridge.intent(of: emoji) == [] && NoteAppKitBridge.intent(of: chinese) == [])

        let board = NSPasteboard(name: NSPasteboard.Name("ledge-notes-legacy-fallback-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        textView.setSelectedRange(NSRange(location: 0, length: string.length))
        try #require(textView.writeSelection(to: board, types: textView.writablePasteboardTypes))
        let rich = try #require(board.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        let copied = rich.string as NSString
        for (word, intent) in [("🏦", InlinePresentationIntent.stronglyEmphasized), ("✓", .stronglyEmphasized),
                               ("中文", .emphasized), ("bank", [])] {
            let face = try #require(rich.attribute(.font, at: copied.range(of: word).location, effectiveRange: nil) as? NSFont)
            #expect(NoteAppKitBridge.intent(of: face) == intent, "\(word) is copied as \(face.fontName)")
        }

        let (other, model, into) = try await open(AttributedString("pasted: "))
        defer { done(other) }
        into.setSelectedRange(NSRange(location: 8, length: 0))
        try #require(into.readSelection(from: board))
        try #require(await arrive { String(model.text.characters).hasSuffix("中文 end") }, "the paste arrived")
        for (word, intent) in [("🏦 ✓", InlinePresentationIntent.stronglyEmphasized), ("中文", .emphasized)] {
            let range = try #require(model.text.range(of: word))
            #expect(model.text[range].inlinePresentationIntent == intent, "\(word) came back as it was")
        }
    }

    // MARK: - Loading

    @Test("A load puts the caret at the end, clears the list and the history, and says nothing")
    func loadResets() async throws {
        let (h, model, textView) = try await open(AttributedString("first note"))
        defer { done(h) }
        _ = h.panel.makeFirstResponder(textView)
        textView.insertText(" typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(textView.undoManager?.canUndo == true)
        var told = 0
        h.model.onEdit = { _ in told += 1 }
        model.show(.find)
        model.findQuery = "note"
        var next = AttributedString("second\n\t•\tpasted list item")
        next[next.range(of: "second")!].inlinePresentationIntent = .stronglyEmphasized
        model.load(NoteBody(id: "second", text: next, createdAt: 0, editedAt: 0))
        #expect(model.overlay == .none && model.findQuery.isEmpty && model.query.isEmpty)
        #expect(String(model.text.characters) == "second\n• pasted list item", "an old pasted list has its bullet")
        #expect(textView.string == "second\n• pasted list item")
        #expect(textView.selectedRange() == NSRange(location: (textView.string as NSString).length, length: 0))
        #expect(textView.undoManager?.canUndo == false)
        #expect(told == 0, """
            nothing is reported during the load itself, so the window has moved its id before the text is \
            saved anywhere; the other editor reports it on its next pass too
            """)
        // On that next pass the note just loaded is reported, and only it.
        var reported: [String] = []
        h.model.onEdit = { reported.append(String($0.characters)) }
        #expect(await arrive { !reported.isEmpty }, "the load is reported once SwiftUI has had its pass")
        await settle()
        #expect(reported.allSatisfy { $0 == "second\n• pasted list item" }, "\(reported)")
    }

    /// Anything a note must not carry, by the attribute's name.
    private func foreign(in text: AttributedString) -> [String] {
        let json = String(decoding: (try? JSONEncoder().encode(text)) ?? Data(), as: UTF8.self)
        return ["\"SwiftUI.", "\"CoreText.", "\"NSLink\"", "\"NSUnderline", "\"NSColor", "\"NSBackground", "\"NSFont"]
            .filter { json.contains($0) }
    }
}
