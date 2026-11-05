import AppKit
import Foundation
import LedgeCore
import LedgeSystem
import SwiftUI
import Testing
@testable import LedgeShell

/// The macOS 15 editor is the macOS 26 editor, as far as anybody using it can
/// tell.
///
/// Both are hosted side by side the way the window hosts them, with the same
/// note in each, and asked the same questions: how their text views are set
/// up, where they draw every character, what a note becomes on disk after
/// passing through either, what a paste turns into, what the chips say, what ⌘Z
/// and Escape do. The SwiftUI editor is the measure, so these run only where it
/// exists. The few places the two differ on purpose are asserted as such,
/// so a change to either side is noticed rather than absorbed.
@MainActor
@Suite("Notes editors agree", .serialized, .timeLimit(.minutes(5)))
struct NotesEditorParityTests {

    typealias Harness = NotesUndoTests.Harness

    @MainActor private struct Pair {
        let swiftUI: Harness
        let appKit: Harness
        /// The SwiftUI editor's text view, which is the measure, and the
        /// AppKit editor's.
        let v26: NSTextView
        let v15: NSTextView

        var both: [(Harness, NSTextView)] { [(swiftUI, v26), (appKit, v15)] }

        func close() {
            for h in [swiftUI, appKit] {
                h.model.onEdit = nil
                h.panel.orderOut(nil)
                h.panel.close()
            }
        }
    }

    /// Waits for what the test is about to assert, under a limit.
    private func arrive(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    /// Both editors with this note open in them, laid out, each set up as
    /// `NotesEditorFixture` sets up the one it measures.
    private func open(_ text: AttributedString) async throws -> Pair {
        let a = try await NotesEditorFixture.open(.swiftUI, text)
        let b = try await NotesEditorFixture.open(.appKit, text)
        await settle()
        return Pair(swiftUI: a.0, appKit: b.0, v26: a.1, v15: b.1)
    }




    // MARK: - The text views

    @available(macOS 26.0, *)
    @Test("The two text views are set up alike")
    func textViewsAreSetUpAlike() async throws {
        let pair = try await open(NotesEditorFixture.sample)
        defer { pair.close() }
        let v26 = pair.v26, v15 = pair.v15
        func same<T: Equatable>(_ name: String, _ read: (NSTextView) -> T) {
            #expect(read(v26) == read(v15), "\(name): \(read(v26)) on 26, \(read(v15)) on 15")
        }
        same("TextKit 2") { $0.textLayoutManager != nil }
        same("inset") { $0.textContainerInset }
        same("line padding") { $0.textContainer?.lineFragmentPadding }
        same("width tracks") { $0.textContainer?.widthTracksTextView }
        same("height tracks") { $0.textContainer?.heightTracksTextView }
        same("container width") { $0.textContainer?.size.width }
        same("rich") { $0.isRichText }
        same("graphics") { $0.importsGraphics }
        same("image editing") { $0.allowsImageEditing }
        same("font panel") { $0.usesFontPanel }
        same("ruler") { $0.usesRuler }
        same("ruler shown") { $0.isRulerVisible }
        same("inspector bar") { $0.usesInspectorBar }
        same("find panel") { $0.usesFindPanel }
        same("undo") { $0.allowsUndo }
        same("editable") { $0.isEditable }
        same("selectable") { $0.isSelectable }
        same("field editor") { $0.isFieldEditor }
        same("draws background") { $0.drawsBackground }
        same("background alpha") { $0.backgroundColor.alphaComponent }
        same("document background") { $0.allowsDocumentBackgroundColorChange }
        same("link tool tips") { $0.displaysLinkToolTips }
        same("link detection") { $0.isAutomaticLinkDetectionEnabled }
        same("data detection") { $0.isAutomaticDataDetectionEnabled }
        same("smart quotes") { $0.isAutomaticQuoteSubstitutionEnabled }
        same("smart dashes") { $0.isAutomaticDashSubstitutionEnabled }
        same("text replacement") { $0.isAutomaticTextReplacementEnabled }
        same("spelling correction") { $0.isAutomaticSpellingCorrectionEnabled }
        same("continuous spelling") { $0.isContinuousSpellCheckingEnabled }
        same("grammar") { $0.isGrammarCheckingEnabled }
        same("smart insert") { $0.smartInsertDeleteEnabled }
        same("completion") { $0.isAutomaticTextCompletionEnabled }
        same("character picker") { $0.allowsCharacterPickerTouchBarItem }
        same("writing tools") { $0.writingToolsBehavior }
        same("writing tools results") { $0.allowedWritingToolsResultOptions.rawValue }
        same("inline predictions") { $0.inlinePredictionType }
        same("maths") { $0.mathExpressionCompletionType }
        same("genmoji") { $0.supportsAdaptiveImageGlyph }
        same("orientation") { $0.layoutOrientation }
        same("adaptive colour") { $0.usesAdaptiveColorMappingForDarkAppearance }
        same("rollover button") { $0.usesRolloverButtonForSelection }
        same("vertically resizable") { $0.isVerticallyResizable }
        same("horizontally resizable") { $0.isHorizontallyResizable }
        same("autoresizing") { $0.autoresizingMask }
        same("max size") { $0.maxSize }
        same("min size") { $0.minSize }
        same("focus ring") { $0.focusRingType }
        same("caret") { NotesEditorFixture.srgb($0.insertionPointColor) }
        same("selection") { NSDictionary(dictionary: $0.selectedTextAttributes) }
        same("marked text") { NSDictionary(dictionary: $0.markedTextAttributes ?? [:]) }
        same("links") { NSDictionary(dictionary: $0.linkTextAttributes ?? [:]) }
        same("readable without SwiftUI's own") {
            $0.readablePasteboardTypes.filter { !$0.rawValue.hasPrefix("com.apple.SwiftUI") }
        }
        same("drop types without SwiftUI's own") {
            $0.acceptableDragTypes.filter { !$0.rawValue.hasPrefix("com.apple.SwiftUI") }.sorted { $0.rawValue < $1.rawValue }
        }

        let scroll26 = try #require(v26.enclosingScrollView), scroll15 = try #require(v15.enclosingScrollView)
        func sameScroll<T: Equatable>(_ name: String, _ read: (NSScrollView) -> T) {
            #expect(read(scroll26) == read(scroll15), "scroll \(name): \(read(scroll26)) on 26, \(read(scroll15)) on 15")
        }
        sameScroll("vertical scroller") { $0.hasVerticalScroller }
        sameScroll("horizontal scroller") { $0.hasHorizontalScroller }
        sameScroll("autohides") { $0.autohidesScrollers }
        sameScroll("style") { $0.scrollerStyle }
        sameScroll("knob") { $0.scrollerKnobStyle }
        sameScroll("draws background") { $0.drawsBackground }
        sameScroll("clip draws background") { $0.contentView.drawsBackground }
        sameScroll("border") { $0.borderType }
        sameScroll("insets") { "\($0.contentInsets)" }
        sameScroll("adjusts insets") { $0.automaticallyAdjustsContentInsets }
        sameScroll("scroller insets") { "\($0.scrollerInsets)" }
        sameScroll("vertical bounce") { $0.verticalScrollElasticity }
        sameScroll("horizontal bounce") { $0.horizontalScrollElasticity }
        sameScroll("predominant axis") { $0.usesPredominantAxisScrolling }
        sameScroll("magnification") { $0.allowsMagnification }
        sameScroll("line scroll") { $0.verticalLineScroll }
        sameScroll("page scroll") { $0.verticalPageScroll }
        sameScroll("rulers") { $0.rulersVisible }

        // The two settings that differ on purpose. SwiftUI turns on a system
        // find bar the window can never show, because ⌘F is the window's.
        #expect(v26.usesFindBar && !v15.usesFindBar)
        #expect(v26.isIncrementalSearchingEnabled && !v15.isIncrementalSearchingEnabled)
    }

    @available(macOS 26.0, *)
    @Test("Every character is drawn in the same place", arguments: [NotesOverlay.none, .find])
    func layoutMatches(overlay: NotesOverlay) async throws {
        let pair = try await open(NotesEditorFixture.sample)
        defer { pair.close() }
        if overlay != .none {
            for (h, _) in pair.both { h.model.show(overlay) }
            await settle()
        }
        let v26 = try #require(pair.swiftUI.textView()), v15 = try #require(pair.appKit.textView())
        let scroll26 = try #require(v26.enclosingScrollView), scroll15 = try #require(v15.enclosingScrollView)
        #expect(scroll26.convert(scroll26.bounds, to: pair.swiftUI.hosting)
                == scroll15.convert(scroll15.bounds, to: pair.appKit.hosting), "the text sits in the same frame")
        #expect(v26.frame.size.width == v15.frame.size.width)
        let length = (v26.string as NSString).length
        try #require(length == (v15.string as NSString).length)
        var checked = 0
        for location in 0 ..< length {
            let range = NSRange(location: location, length: 1)
            let a = v26.firstRect(forCharacterRange: range, actualRange: nil)
            let b = v15.firstRect(forCharacterRange: range, actualRange: nil)
            #expect(abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
                    && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01,
                    "character \(location) \((v26.string as NSString).substring(with: range).debugDescription): \(a) on 26, \(b) on 15")
            checked += 1
        }
        #expect(checked == length && checked > 100)
    }

    @available(macOS 26.0, *)
    @Test("The window looks the same, pixel for pixel", arguments: [NotesOverlay.none, .find, .commands, .notes])
    func windowsMatchPixelForPixel(overlay: NotesOverlay) async throws {
        let pair = try await open(NotesEditorFixture.sample)
        defer { pair.close() }
        for (h, textView) in pair.both {
            h.model.notes = (0 ..< 3).map { NoteSummary(id: "s\($0)", title: "Note \($0)", preview: "p", editedAt: 0) }
            // A caret blinks and a key window draws it; neither is what is
            // being compared, so the selection is put where neither shows.
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            // Spelling and grammar marks are drawn whenever the checker
            // answers, which on a busy machine can be between one picture and
            // the other. Both editors' settings are compared on their own.
            textView.isContinuousSpellCheckingEnabled = false
            textView.isGrammarCheckingEnabled = false
            if overlay != .none { h.model.show(overlay) }
        }
        await settle()
        // The drawing, not the focus: a field holding the keyboard draws its
        // placeholder differently, and which one holds it in a window that is
        // never key is asked separately.
        for (h, _) in pair.both { _ = h.panel.makeFirstResponder(nil) }
        await settle()
        let a = try NotesEditorFixture.picture(pair.swiftUI.hosting)
        let b = try NotesEditorFixture.picture(pair.appKit.hosting)
        // That there is something to compare: every character of the note
        // that draws anything has some of it in the picture, where it should
        // be. Two blank pictures are also the same.
        if overlay == .none || overlay == .find {
            for (h, picture) in [(pair.swiftUI, a), (pair.appKit, b)] {
                let visible = NotesEditorFixture.visibleCharacters(try #require(h.textView()), in: h)
                try #require(visible.count > 200, "\(h.kind): the note's characters were looked for")
                for (character, location, rect) in visible {
                    #expect(NotesEditorFixture.drawn(picture, in: rect, of: h.hosting),
                            "\(h.kind): \(character.debugDescription) at \(location) is not in the picture at \(rect)")
                }
            }
        }
        let difference = NotesEditorFixture.difference(a, b, of: pair.swiftUI.hosting)
        #expect(difference.isEmpty, """
            \(difference); first responders \
            \(String(describing: pair.swiftUI.panel.firstResponder.map { type(of: $0) })) and \
            \(String(describing: pair.appKit.panel.firstResponder.map { type(of: $0) }))
            """)
    }

    @available(macOS 26.0, *)
    @Test("A comparison that finds nothing would have found one word made bold, or one letter changed",
          arguments: ["bold", "letter"])
    func pixelComparisonSeesADifference(change: String) async throws {
        let pair = try await open(NotesEditorFixture.sample)
        defer { pair.close() }
        let tail = (pair.v15.string as NSString).range(of: "tail")
        if change == "bold" {
            pair.v15.setSelectedRange(tail)
            pair.appKit.model.toggle(.stronglyEmphasized)
        } else {
            pair.v15.insertText("l", replacementRange: NSRange(location: tail.location + 2, length: 1))
        }
        for (h, textView) in pair.both {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            _ = h.panel.makeFirstResponder(nil)
        }
        await settle()
        let a = try NotesEditorFixture.picture(pair.swiftUI.hosting)
        let b = try NotesEditorFixture.picture(pair.appKit.hosting)
        #expect(!NotesEditorFixture.difference(a, b, of: pair.swiftUI.hosting).isEmpty)
    }

    @available(macOS 26.0, *)
    @Test("The SwiftUI editor still measures what was written down for the other Macs")
    func fixtureStillHolds() async throws {
        let measured = try await NotesEditorFixture.measure(.swiftUI)
        let differences = NotesEditorFixture.differences(measured, from: NotesEditorFixture.swiftUI)
        #expect(differences.isEmpty, "\(differences.prefix(12))")
    }

    @available(macOS 26.0, *)
    @Test("The text is drawn in the same faces and ink")
    func facesMatch() async throws {
        let pair = try await open(NotesEditorFixture.sample)
        defer { pair.close() }
        let v26 = try #require(pair.v26.textStorage), v15 = try #require(pair.v15.textStorage)
        for location in 0 ..< v26.length {
            let a = v26.attributes(at: location, effectiveRange: nil), b = v15.attributes(at: location, effectiveRange: nil)
            let fa = try #require(a[.font] as? NSFont), fb = try #require(b[.font] as? NSFont)
            #expect(fa.fontName == fb.fontName && fa.pointSize == fb.pointSize,
                    "at \(location): \(fa.fontName) on 26, \(fb.fontName) on 15")
            #expect(fa.fontDescriptor.symbolicTraits == fb.fontDescriptor.symbolicTraits)
            #expect(NotesEditorFixture.srgb(a[.foregroundColor] as? NSColor) == NotesEditorFixture.srgb(b[.foregroundColor] as? NSColor))
            let pa = a[.paragraphStyle] as? NSParagraphStyle, pb = b[.paragraphStyle] as? NSParagraphStyle
            #expect(NotesEditorFixture.describe(pa) == NotesEditorFixture.describe(pb), "at \(location): \(NotesEditorFixture.describe(pa)) on 26, \(NotesEditorFixture.describe(pb)) on 15")
            #expect(b[.backgroundColor] == nil && b[.underlineStyle] == nil)
        }
        for (location, typing) in [(0, "a bold start"), (30, "after BOLD")] {
            pair.v26.setSelectedRange(NSRange(location: location, length: 0))
            pair.v15.setSelectedRange(NSRange(location: location, length: 0))
            let a = pair.v26.typingAttributes, b = pair.v15.typingAttributes
            #expect((a[.font] as? NSFont)?.fontName == (b[.font] as? NSFont)?.fontName, "typing at \(typing)")
            #expect(NotesEditorFixture.srgb(a[.foregroundColor] as? NSColor) == NotesEditorFixture.srgb(b[.foregroundColor] as? NSColor), "typing at \(typing)")
            #expect(NotesEditorFixture.describe(a[.paragraphStyle] as? NSParagraphStyle) == NotesEditorFixture.describe(b[.paragraphStyle] as? NSParagraphStyle),
                    "typing at \(typing)")
        }
    }

    // MARK: - What reaches the disk

    /// A note written the way somebody writes one: typed, made bold and
    /// italic from the keys — over an emoji, a check mark and Chinese too —
    /// and pasted into. What the store wrote for it, and the note that is.
    private func write(in kind: NotesEditorKind) async throws -> (Data, NoteBody) {
        _ = NSApplication.shared
        let writer = Harness(kind)
        defer {
            writer.model.onEdit = nil
            writer.panel.close()
        }
        writer.hosting.layoutSubtreeIfNeeded()
        let first = await writer.store.create()
        let body = try #require(await writer.store.body(first.id))
        writer.present(body)
        let textView = try #require(writer.textView())
        _ = writer.panel.makeFirstResponder(textView)
        textView.insertText("Plan for Monday\n• call the bank 🏦 ✓\n• 日本語 and cafe\u{301}\n",
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(await arrive { String(writer.model.text.characters).hasPrefix("Plan for Monday") })
        let string = textView.string as NSString
        for (word, intent) in [("Plan", InlinePresentationIntent.stronglyEmphasized),
                               ("🏦 ✓", .stronglyEmphasized), ("日本語", .emphasized)] {
            textView.setSelectedRange(string.range(of: word))
            await settle()
            writer.model.toggle(intent)
            await settle()
        }
        let pasted = NSMutableAttributedString(string: "pasted ", attributes: [.font: NSFont(name: "Times-Italic", size: 18)!])
        pasted.append(NSAttributedString(string: "heavy", attributes: [.font: NSFont(name: "Avenir-Heavy", size: 11)!]))
        let board = NSPasteboard(name: NSPasteboard.Name("ledge-notes-parity-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.declareTypes([.rtf], owner: nil)
        board.setData(pasted.rtf(from: NSRange(location: 0, length: pasted.length), documentAttributes: [:]), forType: .rtf)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        try #require(textView.readSelection(from: board))
        try #require(await arrive { String(writer.model.text.characters).hasSuffix("pasted heavy") })
        try #require(await arrive { writer.model.text.runs.contains { $0.inlinePresentationIntent == .emphasized } },
                     "the pasted italic face became an intent")
        // Each edit reaches the store in a task of its own, and two of those
        // are not ordered: one still in flight can land after the flush below
        // and put an older text back. That race belongs to the controller on
        // both editors and is not what this test is about, so the in-flight
        // edits are let land first.
        await settle()
        await writer.closeFlush()
        let written = try Data(contentsOf: writer.dir.appendingPathComponent("\(first.id).json"))
        let made = try JSONDecoder().decode(NoteBody.self, from: written)
        for (word, intent) in [("Plan", InlinePresentationIntent.stronglyEmphasized), ("🏦 ✓", .stronglyEmphasized),
                               ("日本語", .emphasized), ("pasted", .emphasized), ("heavy", .stronglyEmphasized)] {
            let range = try #require(made.text.range(of: word), "\(kind): \(word) was written")
            try #require(made.text[range].inlinePresentationIntent == intent, "\(kind): \(word) is \(intent.rawValue)")
        }
        return (written, made)
    }

    /// The file opened in this editor, a letter typed and taken away again,
    /// and closed. What the editor then holds, encoded as the store encodes,
    /// and what the store wrote.
    private func reopen(_ written: Data, _ made: NoteBody, in kind: NotesEditorKind) async throws -> (held: Data, file: Data) {
        let reader = Harness(kind)
        defer {
            reader.model.onEdit = nil
            reader.panel.close()
        }
        try FileManager.default.createDirectory(at: reader.dir, withIntermediateDirectories: true)
        let file = reader.dir.appendingPathComponent("\(made.id).json")
        try written.write(to: file)
        reader.hosting.layoutSubtreeIfNeeded()
        let read = try #require(await reader.store.body(made.id))
        reader.present(read)
        let textView = try #require(reader.textView())
        try #require(await arrive { textView.string == String(made.text.characters) }, "\(kind): the note is on screen")
        await settle()
        _ = reader.panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(await arrive { String(reader.model.text.characters).hasSuffix("heavyx") }, "\(kind): typed")
        textView.deleteBackward(nil)
        try #require(await arrive { String(reader.model.text.characters) == String(made.text.characters) },
                     "\(kind): and taken away")
        await settle()
        var held = made
        held.text = NoteText.normalized(reader.model.text)
        await reader.closeFlush()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try encoder.encode(held), try Data(contentsOf: file))
    }

    /// The bytes the store wrote for a note, with the edit time it moves on
    /// every edit put back to the original's.
    private func timeless(_ file: Data, as made: NoteBody) throws -> Data {
        var body = try JSONDecoder().decode(NoteBody.self, from: file)
        body.editedAt = made.editedAt
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(body)
    }

    @available(macOS 26.0, *)
    @Test("A note from the macOS 26 editor is saved back byte for byte by the macOS 15 one, and the other way")
    func storedBytesRoundTrip() async throws {
        let (written, made) = try await write(in: .swiftUI)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try #require(try encoder.encode(made) == written, "the store's encoding, reproduced")
        let fifteen = try await reopen(written, made, in: .appKit)
        #expect(fifteen.held == written, "what the AppKit editor holds encodes to the same bytes")
        #expect(try timeless(fifteen.file, as: made) == written, "and the store wrote them")
        let back = try await reopen(fifteen.file, try JSONDecoder().decode(NoteBody.self, from: fifteen.file), in: .swiftUI)
        #expect(try timeless(back.held, as: made) == written, "and back in the SwiftUI editor")
    }

    @available(macOS 26.0, *)
    @Test("A note from the macOS 15 editor is saved back byte for byte by the macOS 26 one, and the other way")
    func storedBytesRoundTripFromFifteen() async throws {
        let (written, made) = try await write(in: .appKit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try #require(try encoder.encode(made) == written, "the store's encoding, reproduced")
        let twentySix = try await reopen(written, made, in: .swiftUI)
        #expect(twentySix.held == written, "what the SwiftUI editor holds encodes to the same bytes")
        #expect(try timeless(twentySix.file, as: made) == written, "and the store wrote them")
        let back = try await reopen(twentySix.file, try JSONDecoder().decode(NoteBody.self, from: twentySix.file), in: .appKit)
        #expect(try timeless(back.held, as: made) == written, "and back in the AppKit editor")
    }

    // MARK: - What comes in

    @available(macOS 26.0, *)
    @Test("A pasted face is called bold or italic by both, for every weight and family")
    func pastedFacesAreJudgedAlike() async throws {
        let pair = try await open(AttributedString("X"))
        defer { pair.close() }
        let fonts = Self.faces()
        try #require(fonts.count > 40, "enough of the fixture's fonts are installed")
        let source = NSMutableAttributedString()
        for (i, font) in fonts.enumerated() {
            source.append(NSAttributedString(string: "W\(i)W", attributes: [.font: font]))
            source.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        }
        let board = NSPasteboard(name: NSPasteboard.Name("ledge-notes-faces-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.declareTypes([.rtf], owner: nil)
        board.setData(source.rtf(from: NSRange(location: 0, length: source.length), documentAttributes: [:]), forType: .rtf)
        for (h, textView) in pair.both {
            _ = h.panel.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 1, length: 0))
            try #require(textView.readSelection(from: board))
            try #require(await arrive { String(h.model.text.characters).contains("W\(fonts.count - 1)W") })
        }
        let v26 = pair.swiftUI.model.text, v15 = pair.appKit.model.text
        var semibold = false, medium = false
        for (i, font) in fonts.enumerated() {
            let a = try #require(v26.range(of: "W\(i)W").map { v26[$0].inlinePresentationIntent })
            let b = try #require(v15.range(of: "W\(i)W").map { v15[$0].inlinePresentationIntent })
            #expect(a == b, "\(font.fontName): \(String(describing: a)) on 26, \(String(describing: b)) on 15")
            if font.fontName.contains("Semibold") || font.fontName.contains("Demi") { semibold = semibold || a == .stronglyEmphasized }
            if font.fontName.contains("Medium") { medium = medium || a == .stronglyEmphasized }
        }
        #expect(semibold, "a semibold face reads as bold")
        #expect(!medium, "a medium face does not")
    }

    static func faces() -> [NSFont] {
        var out: [NSFont] = []
        for weight: NSFont.Weight in [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black] {
            out.append(NSFont.systemFont(ofSize: 13, weight: weight))
        }
        for name in ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "HelveticaNeue-Medium", "HelveticaNeue-Bold",
                     "HelveticaNeue-CondensedBold", "HelveticaNeue-CondensedBlack", "HelveticaNeue-Light",
                     "HelveticaNeue-Italic", "Avenir-Medium", "Avenir-Heavy", "Avenir-Black", "Avenir-Oblique",
                     "AvenirNext-DemiBold", "AvenirNext-Bold", "AvenirNext-Heavy", "Times-Roman", "Times-Bold",
                     "Times-Italic", "Times-BoldItalic", "Georgia-Bold", "Georgia-Italic", "Menlo-Bold", "Menlo-Italic",
                     "Arial-BoldMT", "Arial-Black", "Futura-Medium", "Futura-Bold", "Optima-ExtraBlack",
                     "GillSans-SemiBold", "Charter-Black", "Charter-Italic", "HiraginoSans-W6", "HiraginoSans-W3",
                     "PingFangSC-Semibold", "PingFangSC-Medium", "Verdana-Bold", "Palatino-Bold",
                     "Baskerville-SemiBold", "AmericanTypewriter-Semibold", "Didot-Bold", "MarkerFelt-Wide"] {
            if let font = NSFont(name: name, size: 13) { out.append(font) }
        }
        let base = NSFont.systemFont(ofSize: 13)
        for traits: NSFontDescriptor.SymbolicTraits in [[.italic], [.bold], [.bold, .italic]] {
            if let font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: 13) { out.append(font) }
        }
        return out
    }

    // MARK: - The chips and the keys

    @available(macOS 26.0, *)
    @Test("The chips say the same thing at every caret and selection")
    func chipsAgree() async throws {
        var text = AttributedString("BOLD start plain BOLD ITAL BOTH mixed\nnext ITALBOTH BOLDBOTH end")
        text[text.range(of: "BOLD start")!].inlinePresentationIntent = .stronglyEmphasized
        let rest = text[text.range(of: "plain ")!.upperBound...]
        text[rest.range(of: "BOLD")!].inlinePresentationIntent = .stronglyEmphasized
        text[text.range(of: "ITAL")!].inlinePresentationIntent = .emphasized
        text[text.range(of: "BOTH")!].inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
        // Two styles side by side, both with italic in them and not the same:
        // where "the same intent throughout" and "italic throughout" part.
        let joined = text[text.range(of: "next ")!.upperBound...]
        text[joined.range(of: "ITAL")!].inlinePresentationIntent = .emphasized
        text[joined.range(of: "BOTH")!].inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
        let last = text[text.range(of: "ITALBOTH ")!.upperBound...]
        text[last.range(of: "BOLD")!].inlinePresentationIntent = .stronglyEmphasized
        text[last.range(of: "BOTH")!].inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
        let pair = try await open(text)
        defer { pair.close() }
        let v26 = try #require(pair.swiftUI.model as? NotesEditorModel)
        let v15 = try #require(pair.appKit.model as? LegacyNotesEditorModel)
        let string = pair.v26.string as NSString
        var places: [NSRange] = (0 ... string.length).map { NSRange(location: $0, length: 0) }
        places += [string.range(of: "BOLD start"), string.range(of: "ITAL BOTH"), string.range(of: "BOTH"),
                   string.range(of: "BOTH mixed"), string.range(of: "plain BOLD"), NSRange(location: 0, length: string.length),
                   string.range(of: "start plain"), string.range(of: "ITALBOTH"), string.range(of: "BOLDBOTH"),
                   string.range(of: "LBOT"), string.range(of: "DBOT")]
        for place in places {
            pair.v26.setSelectedRange(place)
            pair.v15.setSelectedRange(place)
            // The SwiftUI editor may carry the text view's selection into its
            // model on a later pass.
            try? await Task.sleep(for: .milliseconds(40))
            for intent in [InlinePresentationIntent.stronglyEmphasized, .emphasized] {
                #expect(v26.isActive(intent) == v15.isActive(intent),
                        "\(intent == .emphasized ? "I" : "B") at \(place): \(v26.isActive(intent)) on 26, \(v15.isActive(intent)) on 15")
            }
        }
    }

    @available(macOS 26.0, *)
    @Test("⌘B over a selection is one ⌘Z in both, and so is ⌘B at a caret then typing")
    func boldUndoesAlike() async throws {
        let pair = try await open(AttributedString("abc def"))
        defer { pair.close() }
        for (h, textView) in pair.both {
            _ = h.panel.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 7, length: 0))
            textView.insertText(" ghi", replacementRange: NSRange(location: NSNotFound, length: 0))
            textView.breakUndoCoalescing()
            try #require(await arrive { String(h.model.text.characters) == "abc def ghi" })
            textView.setSelectedRange(NSRange(location: 0, length: 3))
            await settle()
            h.model.toggle(.stronglyEmphasized)
            // The SwiftUI editor hands the change to its text view on its next
            // pass; ⌘Z before then has nothing of it to undo.
            try #require(await arrive {
                h.model.text.runs.first?.inlinePresentationIntent == .stronglyEmphasized
                    && (textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                        .map { NoteAppKitBridge.intent(of: $0) } == .stronglyEmphasized
            }, "\(h.kind): ⌘B reached the note and its text view")
            #expect(textView.selectedRange() == NSRange(location: 0, length: 3), "\(h.kind): the selection stays")
            #expect(h.pressUndo())
            #expect(await arrive { h.model.text.runs.allSatisfy { $0.inlinePresentationIntent == nil } },
                    "\(h.kind): ⌘Z took the bold back")
            #expect(String(h.model.text.characters) == "abc def ghi", "\(h.kind): and nothing else")

            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            await settle()
            h.model.toggle(.stronglyEmphasized)
            try #require(await arrive {
                (textView.typingAttributes[.font] as? NSFont).map { NoteAppKitBridge.intent(of: $0) } == .stronglyEmphasized
            }, "\(h.kind): the next character will be bold")
            textView.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(await arrive { h.model.text.runs.last.map { String(h.model.text.characters[$0.range]) } == "Z" })
            #expect(h.model.text.runs.last?.inlinePresentationIntent == .stronglyEmphasized, "\(h.kind): typed bold")
        }
    }

    @available(macOS 26.0, *)
    @Test("The Font menu's Bold and Italic come out the same in both")
    func fontMenuAgrees() async throws {
        var text = AttributedString("Before BOLDRUN after")
        text[text.range(of: "BOLDRUN")!].inlinePresentationIntent = .stronglyEmphasized
        let pair = try await open(text)
        defer { pair.close() }
        let manager = NSFontManager.shared
        defer { manager.target = nil }
        func menu(_ trait: NSFontTraitMask, on word: String, _ textView: NSTextView) {
            textView.setSelectedRange((textView.string as NSString).range(of: word))
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.tag = Int(trait.rawValue)
            manager.target = textView
            manager.addFontTrait(item)
            manager.target = nil
        }
        for (h, textView) in pair.both {
            _ = h.panel.makeFirstResponder(textView)
            menu(.boldFontMask, on: "Before", textView)
            await settle()
            menu(.italicFontMask, on: "BOLDRUN", textView)
            await settle()
        }
        func runs(_ t: AttributedString) -> [String] {
            t.runs.map { "\(String(t.characters[$0.range]))=\($0.inlinePresentationIntent?.rawValue ?? 0)" }
        }
        let a = runs(pair.swiftUI.model.text), b = runs(pair.appKit.model.text)
        #expect(a == b, "\(a) on 26, \(b) on 15")
        #expect(b == ["Before=2", " =0", "BOLDRUN=3", " after=0"], "\(b)")

        // A face put straight onto the text, as Paste Style puts one: Ledge's
        // plain face over bold italic makes it plain in both.
        for (_, textView) in pair.both {
            let range = (textView.string as NSString).range(of: "BOLDRUN")
            let storage = try #require(textView.textStorage)
            try #require(textView.shouldChangeText(in: range, replacementString: nil))
            storage.addAttribute(.font, value: NoteAppKitBridge.font(for: []), range: range)
            textView.didChangeText()
            await settle()
        }
        let c = runs(pair.swiftUI.model.text), d = runs(pair.appKit.model.text)
        #expect(c == d, "\(c) on 26, \(d) on 15")
        #expect(d == ["Before=2", " BOLDRUN after=0"], "\(d)")
    }

    @available(macOS 26.0, *)
    @Test("Escape in the text goes to the window in both")
    func escapeReachesTheWindow() async throws {
        let pair = try await open(AttributedString("some words"))
        defer { pair.close() }
        for (h, textView) in pair.both {
            var escapes = 0
            h.panel.onEscape = { escapes += 1 }
            _ = h.panel.makeFirstResponder(textView)
            textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: h.panel.windowNumber, context: nil,
                                                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                    isARepeat: false, keyCode: 53))
            textView.keyDown(with: key)
            #expect(escapes == 2, "\(h.kind)")
            #expect(textView.string == "some words", "\(h.kind)")
        }
    }

    @available(macOS 26.0, *)
    @Test("A copy carries the same rich and plain text, less SwiftUI's own types and the window's ink")
    func copiesAgree() async throws {
        var text = AttributedString("plain BOLD and ITAL")
        text[text.range(of: "BOLD")!].inlinePresentationIntent = .stronglyEmphasized
        text[text.range(of: "ITAL")!].inlinePresentationIntent = .emphasized
        let pair = try await open(text)
        defer { pair.close() }
        var boards: [NSPasteboard] = []
        defer { boards.forEach { $0.releaseGlobally() } }
        for (_, textView) in pair.both {
            let board = NSPasteboard(name: NSPasteboard.Name("ledge-notes-copy-\(UUID().uuidString)"))
            board.clearContents()
            boards.append(board)
            textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
            #expect(textView.writeSelection(to: board, types: textView.writablePasteboardTypes))
        }
        let oldTypes = Set((boards[0].types ?? []).filter { !$0.rawValue.hasPrefix("com.apple.SwiftUI") })
        let newTypes = Set(boards[1].types ?? [])
        #expect(oldTypes == newTypes, "\(oldTypes) on 26, \(newTypes) on 15")
        #expect(boards[0].string(forType: .string) == boards[1].string(forType: .string))
        let a = try #require(boards[0].data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        let b = try #require(boards[1].data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        try #require(a.string == b.string)
        for location in 0 ..< a.length {
            let x = a.attributes(at: location, effectiveRange: nil), y = b.attributes(at: location, effectiveRange: nil)
            #expect((x[.font] as? NSFont)?.fontName == (y[.font] as? NSFont)?.fontName, "at \(location)")
            #expect((x[.paragraphStyle] as? NSParagraphStyle) == (y[.paragraphStyle] as? NSParagraphStyle), "at \(location)")
            #expect(y[.foregroundColor] == nil, "the window's ink stays behind on 15")
        }
        // On 26 it does not, which is the SwiftUI editor's own behaviour and
        // left as it is.
        #expect(a.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil)
    }

    // MARK: - Loading and finding

    @available(macOS 26.0, *)
    @Test("A load puts the caret at the end, forgets the history, and keeps or resets the scroll alike")
    func loadsAgree() async throws {
        let longA = AttributedString((0 ..< 200).map { "Alpha \($0)" }.joined(separator: "\n"))
        let longB = AttributedString((0 ..< 200).map { "Bravo \($0)" }.joined(separator: "\n"))
        let pair = try await open(longA)
        defer { pair.close() }
        for (h, textView) in pair.both {
            #expect(textView.selectedRange() == NSRange(location: (textView.string as NSString).length, length: 0),
                    "\(h.kind): the caret is at the end")
            #expect(textView.undoManager?.canUndo == false, "\(h.kind): nothing to undo")
            textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length - 1, length: 1))
        }
        await settle()
        func offset(_ textView: NSTextView?) -> CGFloat { textView?.enclosingScrollView?.contentView.bounds.minY ?? -1 }
        #expect(offset(pair.v26) == offset(pair.v15) && offset(pair.v26) > 0)

        // Swapped into the same text view: the offset stays.
        for (h, _) in pair.both { h.present(NoteBody(id: "B", text: longB, createdAt: 0, editedAt: 0)) }
        await settle()
        #expect(offset(pair.swiftUI.textView()) == offset(pair.appKit.textView()), "a swap keeps the offset alike")

        // Arriving from behind the list: the top.
        for (h, _) in pair.both {
            h.model.show(.notes)
        }
        await settle()
        for (h, _) in pair.both { h.present(NoteBody(id: "A", text: longA, createdAt: 0, editedAt: 0)) }
        await settle()
        #expect(offset(pair.swiftUI.textView()) == 0)
        #expect(offset(pair.appKit.textView()) == 0)

        // Picked from the list: it goes first, and the note arrives after.
        for (h, _) in pair.both {
            let textView = try #require(h.textView())
            textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length - 1, length: 1))
        }
        await settle()
        #expect(offset(pair.swiftUI.textView()) > 0 && offset(pair.appKit.textView()) > 0)
        for (h, _) in pair.both {
            h.model.show(.notes)
        }
        await settle()
        for (h, _) in pair.both {
            h.model.dismissOverlay()
        }
        await settle()
        for (h, _) in pair.both { h.present(NoteBody(id: "B", text: longB, createdAt: 0, editedAt: 0)) }
        await settle()
        #expect(offset(pair.swiftUI.textView()) == 0, "a note picked from the list starts at the top")
        #expect(offset(pair.appKit.textView()) == 0)

        // Scrolled by hand after the list went: the next note keeps the place.
        for (h, _) in pair.both { h.model.show(.notes) }
        await settle()
        for (h, _) in pair.both { h.model.dismissOverlay() }
        await settle()
        for (h, _) in pair.both {
            // A scroll by hand, as AppKit reports one.
            let scroll = try #require(h.textView()?.enclosingScrollView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        }
        await settle()
        let scrolled = (offset(pair.swiftUI.textView()), offset(pair.appKit.textView()))
        try #require(scrolled.0 == 600 && scrolled.1 == 600, "both scrolled alike: \(scrolled)")
        for (h, _) in pair.both { h.present(NoteBody(id: "A", text: longA, createdAt: 0, editedAt: 0)) }
        await settle()
        #expect(offset(pair.swiftUI.textView()) == scrolled.0, "scrolled after the list went, the place is kept")
        #expect(offset(pair.appKit.textView()) == scrolled.1)
        for (h, _) in pair.both {
            #expect(h.textView()?.selectedRange() == NSRange(location: (String(longA.characters) as NSString).length, length: 0))
            #expect(h.textView()?.undoManager?.canUndo == false)
        }
    }

    @available(macOS 26.0, *)
    @Test("A search finds the same places and selects the same text")
    func findsAgree() async throws {
        let pair = try await open(AttributedString("Café café CAFÉ cafe\u{301}\nthe Cafe and the café\nnone here"))
        defer { pair.close() }
        let v26 = try #require(pair.swiftUI.model as? NotesEditorModel)
        let v15 = try #require(pair.appKit.model as? LegacyNotesEditorModel)
        for (h, _) in pair.both { h.model.show(.find) }
        for query in ["café", "CAFE", "the ", "e\u{301}", "zz", " "] {
            v26.findQuery = query
            v15.findQuery = query
            #expect(v26.matches.count == v15.matches.count, "\(query.debugDescription)")
            #expect(v26.matchSummary == v15.matchSummary, "\(query.debugDescription)")
            for _ in 0 ..< max(v26.matches.count, 1) + 1 {
                await settle()
                let a = try #require(pair.swiftUI.textView()).selectedRange()
                let b = try #require(pair.appKit.textView()).selectedRange()
                #expect(a == b, "\(query.debugDescription) at \(v26.matchIndex): \(a) on 26, \(b) on 15")
                #expect(v26.matchIndex == v15.matchIndex)
                v26.stepMatch(1)
                v15.stepMatch(1)
            }
        }
    }
}
