import AppKit
import Foundation
import LedgeCore
import LedgeSystem
import SwiftUI
import Testing
@testable import LedgeShell

/// A paste brings into a note only what Ledge itself can make: characters,
/// bold and italic.
///
/// The editor is the real one, hosted as `NotesUndoTests` hosts it — a real
/// `NotesPanel` and `NotesEditorView` over a store in a scratch folder, never
/// key, and ordered in only for the drop, far off every screen. Every fixture
/// goes on a pasteboard of its own, named for the test and released after it;
/// the user's clipboard is never read or written. The paste is driven through
/// `readSelection(from:)`, which is what `paste:` and Services call, so it goes
/// through everything AppKit and SwiftUI do with a real one.
@MainActor
@Suite("Notes paste", .serialized, .timeLimit(.minutes(5)))
struct NotesPasteTests {

    typealias Harness = NotesUndoTests.Harness

    // MARK: - Fixtures

    /// A pasteboard nobody else will ever see.
    private func board(_ label: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("ledge-notes-paste-\(label)-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    /// One labelled run per foreign attribute, with plain spaces between.
    private func rich() -> NSAttributedString {
        let s = NSMutableAttributedString()
        func add(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            s.append(NSAttributedString(string: text, attributes: attributes))
            s.append(NSAttributedString(string: " "))
        }
        let base = NSFont.systemFont(ofSize: 13)
        add("HILITE", [.backgroundColor: NSColor.white, .foregroundColor: NSColor.black, .font: base])
        add("GEORGIA24", [.font: NSFont(name: "Georgia", size: 24) ?? base])
        add("BOLDFONT", [.font: NSFont.boldSystemFont(ofSize: 13)])
        add("ITALFONT", [.font: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)])
        add("UNDER", [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.systemGreen])
        add("STRIKE", [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        add("LINK", [.link: URL(string: "https://example.com/x")!])
        add("KERN", [.kern: 6.0])
        add("BASELINE", [.baselineOffset: 7.0])
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.headIndent = 40
        s.append(NSAttributedString(string: "\nCENTERED\n", attributes: [.paragraphStyle: centred]))
        s.append(NSAttributedString(string: "TAIL"))
        return s
    }

    private func rtf(_ s: NSAttributedString) -> Data {
        s.rtf(from: NSRange(location: 0, length: s.length), documentAttributes: [:]) ?? Data()
    }

    private func png() -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private var html: String {
        """
        <html><body style="background:#fff">
        <p><span style="background-color:#ffffff;color:#222222;font-family:Georgia;font-size:20px">WEBHILITE</span>
        <mark>MARKED</mark> <b>WEBBOLD</b> <strong>STRONG</strong> <i>WEBITAL</i> <u>WEBUNDER</u>
        <a href="https://example.com/a">WEBLINK</a> x<sup>2</sup></p>
        <h1>HEADING</h1>
        <ul><li>UL ONE</li><li>UL TWO</li></ul>
        <table border="1"><tr><td>CELL A</td><td>CELL B</td></tr></table>
        <p style="text-align:right">RIGHTPARA</p>
        <img src="data:image/png;base64,\(png().base64EncodedString())" width="8" height="8">
        <p>WEBTAIL</p>
        </body></html>
        """
    }

    private func rtfBoard() throws -> NSPasteboard {
        let b = board("rtf")
        let source = rich()
        b.declareTypes([.rtf, .string], owner: nil)
        b.setData(rtf(source), forType: .rtf)
        b.setString(source.string, forType: .string)
        try #require(b.types?.contains(.rtf) == true, "the board carries RTF")
        let read = try #require(b.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        let at = (read.string as NSString).range(of: "HILITE").location
        try #require(read.attribute(.backgroundColor, at: at, effectiveRange: nil) != nil,
                     "the highlight is on the board, so a clean note means it was refused")
        return b
    }

    private func htmlBoard() throws -> NSPasteboard {
        let b = board("html")
        b.declareTypes([.html, .string], owner: nil)
        b.setString(html, forType: .html)
        b.setString("WEBHILITE", forType: .string)
        try #require(b.types?.contains(.html) == true, "the board carries HTML")
        try #require(b.string(forType: .html)?.contains("<b>WEBBOLD</b>") == true)
        return b
    }

    // MARK: - Driving the editor

    /// Waits for what the test is about to assert, under a limit, rather
    /// than for a number of turns.
    private func arrive(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// A chance for something that must not happen to show. Bounded, because
    /// the right answer is that nothing does.
    private func idle() async { try? await Task.sleep(for: .milliseconds(300)) }

    /// A harness with this note open in it and the text view first responder.
    private func open(_ text: AttributedString) async throws -> (Harness, NoteBody, NSTextView) {
        _ = NSApplication.shared
        let h = Harness()
        let note = await h.store.create()
        await h.store.update(note.id, text: text)
        await h.store.flush()
        let body = try #require(await h.store.body(note.id))
        h.hosting.layoutSubtreeIfNeeded()
        h.present(body)
        let textView = try #require(h.textView())
        try #require(await arrive { textView.string == String(text.characters) }, "the note is on screen")
        _ = h.panel.makeFirstResponder(textView)
        return (h, body, textView)
    }

    private func paste(_ board: NSPasteboard, into textView: NSTextView, at offset: Int,
                       model: NotesEditorModel, arrived marker: String) async throws {
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        textView.breakUndoCoalescing()
        try #require(textView.readSelection(from: board), "the text view took the paste")
        try #require(await arrive { String(model.text.characters).contains(marker) }, "the paste reached the model")
    }

    /// Whether a run carries the intent and face Ledge would give it, and
    /// nothing besides.
    private func isLedgeOwn(_ run: AttributedString.Runs.Run) -> Bool {
        var expected = AttributeContainer()
        if let intent = run.inlinePresentationIntent { expected.inlinePresentationIntent = intent }
        expected.font = NoteFace.font(for: run.inlinePresentationIntent ?? [])
        return run.attributes == expected
    }

    /// Puts the window away and stops it reporting edits to a harness that
    /// is about to go: the harness holds itself unowned in the model's edit
    /// callback, and a window that was ordered in can still be updated after
    /// the test has returned.
    private func done(_ h: Harness) {
        h.model.onEdit = nil
        h.panel.orderOut(nil)
        h.panel.close()
    }

    private func json(_ text: AttributedString) throws -> String {
        let body = NoteBody(id: "probe", text: NotesEditorModel.stored(text), createdAt: 0, editedAt: 0)
        return String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
    }

    private func foreignKeys(in json: String) -> [String] {
        ["\"SwiftUI.", "\"CoreText.", "\"NSLink\"", "\"Foundation.", "\"NSUnderline", "\"NSColor", "\"NSBackground"]
            .filter { json.contains($0) }
    }

    // MARK: - What comes in

    @Test("A rich paste keeps its words, bold and italic, and nothing else")
    func richPasteKeepsOnlyLedgeFormatting() async throws {
        let b = try rtfBoard()
        defer { b.releaseGlobally() }
        let (h, _, textView) = try await open(AttributedString("Before AFTER"))
        try await paste(b, into: textView, at: 7, model: h.model, arrived: "HILITE")

        #expect(h.model.text.runs.allSatisfy(isLedgeOwn),
                "\(h.model.text.runs.filter { !isLedgeOwn($0) }.map { String(describing: $0.attributes) })")
        #expect(foreignKeys(in: try json(h.model.text)) == [])
        let storage = try #require(textView.textStorage)
        let at = (storage.string as NSString).range(of: "HILITE").location
        #expect(storage.attribute(.backgroundColor, at: at, effectiveRange: nil) == nil, "the highlight is drawn")
        done(h)
    }

    @Test("Pasted bold and italic are Ledge's bold and italic", arguments: ["rtf", "html"])
    func pastedBoldIsLedgeBold(source: String) async throws {
        let b = try source == "rtf" ? rtfBoard() : htmlBoard()
        defer { b.releaseGlobally() }
        let bold = source == "rtf" ? "BOLDFONT" : "WEBBOLD"
        let italic = source == "rtf" ? "ITALFONT" : "WEBITAL"
        if source == "rtf" {
            let read = try #require(b.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
            let font = try #require(read.attribute(.font, at: (read.string as NSString).range(of: bold).location,
                                                   effectiveRange: nil) as? NSFont)
            try #require(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "the fixture really is bold")
        }
        let (h, _, textView) = try await open(AttributedString("Before AFTER"))
        try await paste(b, into: textView, at: 7, model: h.model, arrived: bold)

        let boldRange = try #require(h.model.text.range(of: bold))
        let italicRange = try #require(h.model.text.range(of: italic))
        #expect(h.model.text[boldRange].runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(h.model.text[italicRange].runs.allSatisfy { $0.inlinePresentationIntent == .emphasized })
        h.model.selection = AttributedTextSelection(range: boldRange)
        #expect(h.model.isActive(.stronglyEmphasized), "the B chip shows it")
        let stored = NotesEditorModel.stored(h.model.text)
        #expect(NoteMarkdown.render(stored).contains("**\(bold)**"))
        #expect(NoteHTML.render(stored).contains("<b>\(bold)</b>"))

        let back = try JSONDecoder().decode(NoteBody.self, from: Data(try json(h.model.text).utf8))
        let reopened = NotesEditorModel.rendered(back.text)
        let again = try #require(reopened.range(of: bold))
        #expect(reopened[again].runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized },
                "still bold after a reopen")
        done(h)
    }

    @Test("A pasted highlight never reaches the note's file")
    func highlightNeverReachesDisk() async throws {
        let b = try rtfBoard()
        defer { b.releaseGlobally() }
        let (h, body, textView) = try await open(AttributedString("Before AFTER"))
        try await paste(b, into: textView, at: 7, model: h.model, arrived: "HILITE")
        await h.closeFlush()

        let file = h.dir.appendingPathComponent("\(body.id).json")
        let data = try #require(try? Data(contentsOf: file), "the note was written")
        let written = String(decoding: data, as: UTF8.self)
        try #require(written.contains("HILITE"), "the paste is in the file")
        #expect(!written.contains("SwiftUI.BackgroundColor"))
        #expect(foreignKeys(in: written) == [])
        #expect(data.count < 1024, "\(data.count) bytes")
        done(h)
    }

    @Test("Images in a paste are dropped, not kept as a placeholder")
    func imagesAreDroppedNotPersisted() async throws {
        let source = NSMutableAttributedString(string: "IMGBEFORE ")
        let wrapper = FileWrapper(regularFileWithContents: png())
        wrapper.preferredFilename = "dot.png"
        source.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        source.append(NSAttributedString(string: " IMGAFTER"))
        let rtfd = try #require(source.rtfd(from: NSRange(location: 0, length: source.length), documentAttributes: [:]))
        let b = board("rtfd")
        defer { b.releaseGlobally() }
        b.declareTypes([.rtfd, .string], owner: nil)
        b.setData(rtfd, forType: .rtfd)
        b.setString("IMGBEFORE IMGAFTER", forType: .string)
        let read = try #require(NSAttributedString(rtfd: rtfd, documentAttributes: nil))
        var attachments = 0
        read.enumerateAttribute(.attachment, in: NSRange(location: 0, length: read.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        try #require(attachments == 1, "the board carries an image")

        let (h, _, textView) = try await open(AttributedString("Before AFTER"))
        try await paste(b, into: textView, at: 7, model: h.model, arrived: "IMGAFTER")
        #expect(!String(h.model.text.characters).contains("\u{FFFC}"))
        done(h)
    }

    @Test("A drop is held to the same rule as a paste")
    func dragGoesThroughTheSameRule() async throws {
        let b = try htmlBoard()
        defer { b.releaseGlobally() }
        let (h, _, textView) = try await open(AttributedString("Before AFTER"))
        // The drop needs a window that is on a screen to land in.
        h.panel.orderFrontRegardless()
        let rect = textView.firstRect(forCharacterRange: NSRange(location: 7, length: 0), actualRange: nil)
        let point = h.panel.convertPoint(fromScreen: NSPoint(x: rect.minX + 1, y: rect.midY))
        let drag = FakeDrag(board: b, window: h.panel, point: point)
        _ = textView.draggingEntered(drag)
        _ = textView.draggingUpdated(drag)
        try #require(textView.prepareForDragOperation(drag))
        try #require(textView.performDragOperation(drag), "the text view took the drop")
        textView.concludeDragOperation(drag)
        try #require(await arrive { String(h.model.text.characters).contains("WEBHILITE") }, "the drop reached the model")

        #expect(h.model.text.runs.allSatisfy(isLedgeOwn))
        #expect(foreignKeys(in: try json(h.model.text)) == [])
        let bold = try #require(h.model.text.range(of: "WEBBOLD"))
        #expect(h.model.text[bold].runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
        done(h)
    }

    @Test("A pasted list arrives with the bullet a person types")
    func pastedListIsBulleted() async throws {
        let b = try htmlBoard()
        defer { b.releaseGlobally() }
        let read = try #require(NSAttributedString(html: Data(html.utf8), documentAttributes: nil))
        try #require(read.string.contains("\t•\tUL ONE"), "AppKit spells the list out as tab, bullet, tab")
        let (h, _, textView) = try await open(AttributedString("Before AFTER"))
        try await paste(b, into: textView, at: 7, model: h.model, arrived: "UL ONE")

        #expect(await arrive { String(h.model.text.characters).contains("• UL ONE\n• UL TWO") })
        #expect(!String(h.model.text.characters).contains("\t•\t"))
        #expect(textView.string.contains("• UL ONE"), "the screen shows what is saved")
        let pasted = (textView.string as NSString).length - ("Before AFTER" as NSString).length
        #expect(textView.selectedRange() == NSRange(location: 7 + pasted, length: 0),
                "the caret is still after the paste once the bullets are tidied")
        done(h)
    }

    @Test("Rich text pasted into a bold run keeps its own bold and plain")
    func richPasteIntoBoldKeepsItsOwn() async throws {
        let source = NSMutableAttributedString(string: "PLAINPASTE ", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        source.append(NSAttributedString(string: "BOLDPASTE", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
        let b = board("into-bold")
        defer { b.releaseGlobally() }
        b.declareTypes([.rtf, .string], owner: nil)
        b.setData(rtf(source), forType: .rtf)
        try #require(b.types?.contains(.rtf) == true)

        var start = AttributedString("plain BOLDRUN plain")
        start[try #require(start.range(of: "BOLDRUN"))].inlinePresentationIntent = .stronglyEmphasized
        let (h, _, textView) = try await open(start)
        try #require(h.model.text[try #require(h.model.text.range(of: "BOLDRUN"))].inlinePresentationIntent == .stronglyEmphasized)
        try await paste(b, into: textView, at: 10, model: h.model, arrived: "BOLDPASTE")

        let plain = try #require(h.model.text.range(of: "PLAINPASTE"))
        let bold = try #require(h.model.text.range(of: "BOLDPASTE"))
        #expect(h.model.text[plain].runs.allSatisfy { $0.inlinePresentationIntent == nil })
        #expect(h.model.text[bold].runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
        done(h)
    }

    @Test("Typing after a paste that ends highlighted comes out plain")
    func typingAfterAHighlightedPasteIsPlain() async throws {
        let source = NSMutableAttributedString(string: "plain ")
        source.append(NSAttributedString(string: "HILITE", attributes: [
            .backgroundColor: NSColor.white, .foregroundColor: NSColor.black,
            .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12),
        ]))
        let b = board("ends-highlighted")
        defer { b.releaseGlobally() }
        b.declareTypes([.rtf, .string], owner: nil)
        b.setData(rtf(source), forType: .rtf)
        b.setString(source.string, forType: .string)
        let read = try #require(b.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) })
        try #require(read.attribute(.backgroundColor, at: read.length - 1, effectiveRange: nil) != nil,
                     "the last pasted character is highlighted on the board")

        let (h, _, textView) = try await open(AttributedString("Start "))
        try await paste(b, into: textView, at: 6, model: h.model, arrived: "HILITE")
        textView.insertText("ZZ", replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(await arrive { String(h.model.text.characters).hasSuffix("HILITEZZ") }, "the typing reached the model")

        let typed = try #require(h.model.text.range(of: "ZZ"))
        #expect(h.model.text[typed].runs.allSatisfy(isLedgeOwn))
        #expect(h.model.text[typed].runs.allSatisfy { $0.inlinePresentationIntent == nil })
        let storage = try #require(textView.textStorage)
        let at = (storage.string as NSString).range(of: "ZZ").location
        #expect(storage.attribute(.backgroundColor, at: at, effectiveRange: nil) == nil)
        #expect(textView.typingAttributes[.backgroundColor] == nil)
        done(h)
    }

    @Test("Formatting from the right-click menu does not stick")
    func contextMenuFormattingIsInert() async throws {
        let (h, _, textView) = try await open(AttributedString("Before AFTER"))
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        textView.underline(nil)
        await idle()
        try #require(String(h.model.text.characters) == "Before AFTER")
        #expect(h.model.text.runs.allSatisfy(isLedgeOwn))
        #expect(foreignKeys(in: try json(h.model.text)) == [])
        done(h)
    }

    // MARK: - Undo and the caret

    @Test("A paste is one undo")
    func pasteIsOneUndo() async throws {
        let b = try rtfBoard()
        defer { b.releaseGlobally() }
        let (h, _, textView) = try await open(AttributedString("Before AFTER"))
        try await paste(b, into: textView, at: 7, model: h.model, arrived: "HILITE")
        try #require(textView.undoManager?.canUndo == true, "the paste is undoable")

        #expect(h.pressUndo())
        #expect(await arrive { String(h.model.text.characters) == "Before AFTER" })
        #expect(textView.string == "Before AFTER")
        done(h)
    }

    @Test("A pasted list is still one undo")
    func pastedListIsOneUndo() async throws {
        let b = try htmlBoard()
        defer { b.releaseGlobally() }
        let (h, _, textView) = try await open(AttributedString("Before AFTER"))
        try await paste(b, into: textView, at: 7, model: h.model, arrived: "UL ONE")
        try #require(await arrive { String(h.model.text.characters).contains("• UL ONE") }, "the list was tidied")
        #expect(h.pressUndo())
        #expect(await arrive { String(h.model.text.characters) == "Before AFTER" })
        #expect(textView.string == "Before AFTER")
        done(h)
    }

    @Test("The caret lands after what was pasted")
    func caretFollowsThePastedText() async throws {
        let b = board("caret")
        defer { b.releaseGlobally() }
        b.declareTypes([.string], owner: nil)
        b.setString("PP", forType: .string)
        try #require(b.string(forType: .string) == "PP")
        let (h, _, textView) = try await open(AttributedString("0123456789 tail of the note"))
        try await paste(b, into: textView, at: 5, model: h.model, arrived: "PP")
        await idle()

        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
        textView.insertText("T", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await arrive { String(h.model.text.characters) == "01234PPT56789 tail of the note" },
                "\(String(h.model.text.characters).debugDescription)")
        done(h)
    }

    @Test("The caret lands after a rich paste too")
    func caretFollowsARichPaste() async throws {
        let b = try rtfBoard()
        defer { b.releaseGlobally() }
        let (h, _, textView) = try await open(AttributedString("Before AFTER"))
        try await paste(b, into: textView, at: 7, model: h.model, arrived: "HILITE")
        await idle()

        let pasted = (textView.string as NSString).length - ("Before AFTER" as NSString).length
        try #require(pasted > 0)
        #expect(textView.selectedRange() == NSRange(location: 7 + pasted, length: 0))
        done(h)
    }

    @Test("The first keystroke after a note opens stays where it was typed")
    func firstKeystrokeAfterLoadStaysPut() async throws {
        let (h, _, textView) = try await open(AttributedString("0123456789 tail of the note"))
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.insertText("Q", replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(await arrive { String(h.model.text.characters).contains("Q") }, "the keystroke reached the model")
        await idle()

        #expect(textView.selectedRange() == NSRange(location: 4, length: 0))
        textView.insertText("R", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await arrive { String(h.model.text.characters) == "012QR3456789 tail of the note" },
                "\(String(h.model.text.characters).debugDescription)")
        done(h)
    }

    // MARK: - Notes already on disk

    /// A note as an earlier build saved it: a pasted highlight, as SwiftUI's
    /// archived colour, beside a bold word.
    private func pollutedJSON(id: String) throws -> String {
        var text = AttributedString("old HILITE note")
        text[try #require(text.range(of: "old"))].inlinePresentationIntent = .stronglyEmphasized
        let hilite = try #require(text.range(of: "HILITE"))
        text[hilite].backgroundColor = Color(nsColor: .white)
        text[hilite].foregroundColor = Color(nsColor: .black)
        text[hilite].underlineStyle = .single
        let body = NoteBody(id: id, text: text, createdAt: 1, editedAt: 1)
        let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        try #require(json.contains("SwiftUI.BackgroundColor"), "the fixture is polluted the way 1.2.x wrote it")
        return json
    }

    @Test("A note saved with a pasted highlight opens clean and is written back clean")
    func pollutedNoteHeals() async throws {
        _ = NSApplication.shared
        let h = Harness()
        try FileManager.default.createDirectory(at: h.dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let file = h.dir.appendingPathComponent("\(id).json")
        try Data(try pollutedJSON(id: id).utf8).write(to: file)
        let body = try #require(await h.store.body(id))
        try #require(body.text.runs.contains { $0.backgroundColor != nil }, "the highlight decoded from disk")

        h.hosting.layoutSubtreeIfNeeded()
        h.present(body)
        let textView = try #require(h.textView())
        try #require(await arrive { textView.string == "old HILITE note" }, "the note is on screen")
        #expect(h.model.text.runs.allSatisfy(isLedgeOwn))
        await h.closeFlush()

        let written = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        try #require(written.contains("HILITE"))
        #expect(foreignKeys(in: written) == [])
        let back = try JSONDecoder().decode(NoteBody.self, from: Data(written.utf8))
        #expect(back.text[try #require(back.text.range(of: "old"))].inlinePresentationIntent == .stronglyEmphasized)
        done(h)
    }

    @Test("Whatever the model holds, only characters and intent are stored")
    func storedIsIntentOnly() throws {
        // The definition keeps a paste out of the model; this is the edge that
        // holds even if something gets past it, or is set without it.
        var text = AttributedString("plain HILITE bold")
        let hilite = try #require(text.range(of: "HILITE"))
        text[hilite].backgroundColor = Color(nsColor: .white)
        text[hilite].link = URL(string: "https://example.com")
        text[hilite].underlineStyle = .single
        let bold = try #require(text.range(of: "bold"))
        text[bold].inlinePresentationIntent = [.stronglyEmphasized, .code]
        text[bold].font = .custom("Georgia", size: 24)
        let polluted = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        try #require(polluted.contains("SwiftUI.BackgroundColor"), "the fixture would have been saved polluted")

        let stored = NotesEditorModel.stored(text)
        #expect(foreignKeys(in: String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)) == [])
        #expect(String(stored.characters) == "plain HILITE bold")
        #expect(stored[try #require(stored.range(of: "bold"))].inlinePresentationIntent == .stronglyEmphasized)
    }

    @Test("A list an earlier build pasted opens with its bullets")
    func oldPastedListOpensBulleted() {
        let opened = NotesEditorModel.rendered(AttributedString("Shopping\n\t•\tmilk\n\t•\teggs"))
        #expect(String(opened.characters) == "Shopping\n• milk\n• eggs")
    }

    @Test("A note whose formatting cannot be decoded keeps its words")
    func undecodableFormattingKeepsTheNote() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledge-notes-paste-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        // The archive renamed to a provider this SDK has never heard of, as a
        // later one might write it.
        let json = try pollutedJSON(id: id).replacingOccurrences(of: "appKitColor", with: "someFutureProvider")
        try #require(json.contains("someFutureProvider"))
        #expect(throws: (any Error).self, "SwiftUI's own decoder gives up on the whole string") {
            _ = try JSONDecoder().decode(AttributedString.self, from: Data(Self.textField(of: json).utf8))
        }
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(id).json"))

        let store = NotesStore(directory: dir, now: { 2 })
        let body = try #require(await store.body(id), "the note was set aside")
        #expect(body.plainText == "old HILITE note")
        #expect(body.text[try #require(body.text.range(of: "old"))].inlinePresentationIntent == .stronglyEmphasized)
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.contains("unreadable") } ?? []
        #expect(aside.isEmpty)
    }

    /// The `text` field of a note's JSON, on its own.
    private static func textField(of json: String) throws -> String {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let text = try #require(object["text"])
        return String(decoding: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    // MARK: - Keys

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 9))
    }

    @Test("⌥⇧⌘V pastes and matches style; ⌘V and ⇧⌘V paste")
    func matchStyleShortcutIsPlain() throws {
        let matchStyle = try key("V", [.command, .shift, .option])
        try #require(matchStyle.charactersIgnoringModifiers == "V", "the event reads as AppKit sends it")
        #expect(NotesPanel.editingAction(for: matchStyle) == #selector(NSTextView.pasteAsPlainText(_:)))
        #expect(NotesPanel.editingAction(for: try key("v", [.command])) == #selector(NSText.paste(_:)))
        #expect(NotesPanel.editingAction(for: try key("V", [.command, .shift])) == #selector(NSText.paste(_:)))
        #expect(NotesPanel.editingAction(for: try key("v", [.command, .option])) == nil,
                "an Option-modified V never falls through to a rich paste")
        #expect(NotesPanel.editingAction(for: try key("z", [.command, .shift])) == Selector(("redo:")))
        #expect(NotesPanel.editingAction(for: try key("v", [.control])) == nil)
    }
}

/// A drag that is only its pasteboard, for driving a drop without a mouse.
final class FakeDrag: NSObject, NSDraggingInfo, @unchecked Sendable {
    let board: NSPasteboard
    weak var window: NSWindow?
    let point: NSPoint

    init(board: NSPasteboard, window: NSWindow, point: NSPoint) {
        self.board = board
        self.window = window
        self.point = point
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
    var draggingLocation: NSPoint { point }
    var draggedImageLocation: NSPoint { point }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { board }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 4242 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
