import AppKit
import Foundation
import LedgeCore
import LedgeSystem
import Testing
@testable import LedgeShell

/// A note survives being drawn by the macOS 15 editor and read back.
///
/// Every note either editor can make is characters plus bold and italic as
/// intent, so that is what goes through: into the text view's terms and out
/// again, and then into the store's encoding, which is where a difference
/// would cost somebody their formatting.
@Suite("Notes AppKit bridge")
struct NoteAppKitBridgeTests {

    /// A note built from runs of text, each with its own intent.
    static func note(_ runs: [(String, InlinePresentationIntent)]) -> AttributedString {
        var out = AttributedString()
        for (text, intent) in runs {
            var piece = AttributedString(text)
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            out.append(piece)
        }
        return out
    }

    /// The bytes the store would write for this text.
    static func stored(_ text: AttributedString) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(NoteBody(id: "probe", text: text, createdAt: 1, editedAt: 2))
    }

    static let bold: InlinePresentationIntent = .stronglyEmphasized
    static let italic: InlinePresentationIntent = .emphasized
    static let both: InlinePresentationIntent = [.stronglyEmphasized, .emphasized]

    static let cases: [(String, AttributedString)] = [
        ("empty", AttributedString("")),
        ("plain", note([("Groceries\nMilk and eggs", [])])),
        ("bold", note([("all of it bold", bold)])),
        ("italic", note([("all of it italic", italic)])),
        ("bold italic", note([("all of it both", both)])),
        ("mixed runs", note([("plain ", []), ("bold", bold), (" and ", []), ("italic", italic), (" then ", []),
                             ("both", both), (" end", [])])),
        ("adjacent styles", note([("a", bold), ("b", italic), ("c", both), ("d", []), ("e", bold)])),
        ("bullets", note([("Shopping\n", bold), ("• milk\n• ", []), ("eggs", italic), ("\n◦ bread", [])])),
        ("emoji", note([("party 🎉 ", []), ("👩🏽‍💻 family 👨‍👩‍👧‍👦", bold), (" flag 🇹🇷 ", italic), ("keycap 1️⃣", [])])),
        ("combining", note([("cafe\u{301} ", []), ("n\u{303}o", bold), (" a\u{30A}\u{301}", italic), (" 각 ᄀ\u{1161}\u{11A8}", [])])),
        ("cjk", note([("日本語のメモ\n", []), ("重要", bold), ("：明日の会議", []), ("。中文", italic), ("한국어", both)])),
        ("trailing newline", note([("ends with a newline", bold), ("\n", [])])),
        ("only newlines", note([("\n\n\n", [])])),
        ("styled newline", note([("first", []), ("\n", bold), ("second", [])])),
        ("tabs and spaces", note([("\tindented   ", []), ("  spaced  ", italic)])),
        ("rtl", note([("שלום ", []), ("עולם", bold), (" مرحبا", italic)])),
        ("long", note((0 ..< 2_000).map { i in
            ("line \(i) with some words in it\n", [[], bold, italic, both][i % 4])
        })),
    ]

    @Test("A note goes into the text view and comes back as it was",
          arguments: cases.map(\.0))
    func roundTrip(name: String) throws {
        let text = try #require(Self.cases.first { $0.0 == name }?.1)
        let back = NoteAppKitBridge.note(NoteAppKitBridge.appKit(text))
        #expect(String(back.characters) == String(text.characters))
        #expect(back == NoteText.normalized(text))
        #expect(try Self.stored(back) == Self.stored(NoteText.normalized(text)), "the file would differ")
    }

    @Test("What the text view draws carries Ledge's face and nothing else", arguments: cases.map(\.0))
    func drawnIsLedgeOwn(name: String) throws {
        let text = try #require(Self.cases.first { $0.0 == name }?.1)
        let drawn = NoteAppKitBridge.appKit(text)
        #expect(drawn.string == String(text.characters))
        var checked = 0
        drawn.enumerateAttributes(in: NSRange(location: 0, length: drawn.length)) { attributes, _, _ in
            checked += 1
            #expect(NoteAppKitBridge.clamped(attributes) == nil, "\(attributes)")
            let styled = NoteAppKitBridge.intent(of: attributes) != []
            #expect(Set(attributes.keys) == Set([.font, .foregroundColor, .paragraphStyle] + (styled ? [NoteAppKitBridge.intentKey] : [])))
        }
        #expect(checked > 0 || drawn.length == 0)
    }

    @Test("The face says which intent it is")
    func faces() {
        for intent in [InlinePresentationIntent(), Self.bold, Self.italic, Self.both] {
            let font = NoteAppKitBridge.font(for: intent)
            #expect(font.pointSize == 13)
            #expect(NoteAppKitBridge.intent(of: font) == intent, "\(font)")
        }
    }

    @Test("Images and attachments do not come back as characters")
    func objectReplacementIsDropped() {
        let drawn = NSMutableAttributedString(string: "before ", attributes: NoteAppKitBridge.attributes(for: []))
        drawn.append(NSAttributedString(attachment: NSTextAttachment()))
        drawn.append(NSAttributedString(string: " after\u{FFFC}", attributes: NoteAppKitBridge.attributes(for: Self.bold)))
        let back = NoteAppKitBridge.note(drawn)
        #expect(String(back.characters) == "before  after")
        #expect(back[back.range(of: "after")!].inlinePresentationIntent == Self.bold)
    }

    @Test("From outside, a face decides over what a run says it is, as the other editor's definition does")
    func faceDecidesOverIntent() {
        let said = NSNumber(value: InlinePresentationIntent([.stronglyEmphasized, .code]).rawValue)
        let plainFace = NoteAppKitBridge.intent(of: [.inlinePresentationIntent: said,
                                                     .font: NSFont.systemFont(ofSize: 20)])
        #expect(plainFace == [], "a plain face over bold intent is plain")
        let noFace = NoteAppKitBridge.intent(of: [.inlinePresentationIntent: said])
        #expect(noFace == Self.bold, "with no face, the intent stands, held to bold and italic")
        let boldFace = NoteAppKitBridge.intent(of: [.font: NSFont.boldSystemFont(ofSize: 9)])
        #expect(boldFace == Self.bold)
        let ledgeOwn = NoteAppKitBridge.intent(of: [NoteAppKitBridge.intentKey: NSNumber(value: Self.both.rawValue),
                                                    .font: NSFont(name: "AppleColorEmoji", size: 13) ?? NSFont.systemFont(ofSize: 13)])
        #expect(ledgeOwn == Self.both, "Ledge's own mark outlasts a fallback face")
    }

    @Test("Whatever a run arrived with, it leaves with Ledge's own attributes")
    func clampKeepsOnlyLedgeOwn() throws {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "HILITE ", attributes: [
            .backgroundColor: NSColor.white, .foregroundColor: NSColor.black,
            .font: NSFont(name: "Georgia", size: 24) ?? NSFont.systemFont(ofSize: 24),
            .underlineStyle: NSUnderlineStyle.single.rawValue, .link: URL(string: "https://example.com")!,
        ]))
        text.append(NSAttributedString(string: "BOLD", attributes: [.font: NSFont.boldSystemFont(ofSize: 30),
                                                                    .kern: 4.0]))
        NoteAppKitBridge.clamp(text, in: NSRange(location: 0, length: text.length))
        let hilite = text.attributes(at: 0, effectiveRange: nil)
        #expect(Set(hilite.keys) == [.font, .foregroundColor, .paragraphStyle])
        #expect(NoteAppKitBridge.intent(of: hilite) == [])
        let bold = text.attributes(at: text.length - 1, effectiveRange: nil)
        #expect(Set(bold.keys) == [.font, .foregroundColor, .paragraphStyle, NoteAppKitBridge.intentKey])
        #expect(NoteAppKitBridge.intent(of: bold) == Self.bold)
        #expect((bold[.font] as? NSFont) == NoteAppKitBridge.font(for: Self.bold))
    }

    // MARK: - In a live text view

    /// The AppKit editor with this note open in it.
    @MainActor private func presented(_ text: AttributedString) async throws -> (NotesUndoTests.Harness, NSTextView) {
        _ = NSApplication.shared
        let h = NotesUndoTests.Harness(.appKit)
        h.hosting.layoutSubtreeIfNeeded()
        h.present(NoteBody(id: "live", text: text, createdAt: 1, editedAt: 2))
        let textView = try #require(h.textView())
        let deadline = ContinuousClock.now + .seconds(5)
        while textView.string != String(text.characters), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(textView.string == String(text.characters), "the note is in the text view")
        return (h, textView)
    }

    @MainActor
    @Test("A note survives a live text view's storage and the store's encoding", arguments: cases.map(\.0))
    func roundTripThroughATextView(name: String) async throws {
        let text = try #require(Self.cases.first { $0.0 == name }?.1)
        let (h, textView) = try await presented(text)
        defer { h.panel.close() }
        let storage = try #require(textView.textStorage)
        let back = NoteAppKitBridge.note(storage)
        #expect(back == NoteText.normalized(text))
        #expect(try Self.stored(back) == Self.stored(NoteText.normalized(text)))
        #expect(h.model.text == NoteText.normalized(text), "what the window would save")
    }

    /// Bold over an emoji, a check mark and a square, and italic over
    /// Chinese: every one a character the system face cannot draw.
    static let fallbackNote = note([("Before ", []), ("🎉✓▪", bold), (" ", []), ("中文", italic),
                                    (" both 漢字🙂", both), (" end", [])])

    @MainActor
    @Test("Bold and italic outlast the fonts AppKit swaps in for what the face cannot draw")
    func styleOutlastsFontFallback() async throws {
        let (h, textView) = try await presented(Self.fallbackNote)
        defer { h.panel.close() }
        let storage = try #require(textView.textStorage)
        let expected = NoteText.normalized(Self.fallbackNote)
        storage.fixAttributes(in: NSRange(location: 0, length: storage.length))
        #expect(NoteAppKitBridge.note(storage) == expected, "after fixAttributes")
        #expect(h.model.text == expected)

        // The swap itself, made as AppKit makes it and with nothing to put
        // the face back: the storage holds the fallback fonts, and the note
        // still reads as it was.
        let string = storage.string as NSString
        let emoji = try #require(NSFont(name: "AppleColorEmoji", size: 13))
        let chinese = try #require(NSFont(name: "PingFangSC-Regular", size: 13))
        let keeper = storage.delegate
        storage.delegate = nil
        storage.addAttribute(.font, value: emoji, range: string.range(of: "🎉"))
        storage.addAttribute(.font, value: chinese, range: string.range(of: "中文"))
        storage.addAttribute(.font, value: chinese, range: string.range(of: "漢字"))
        storage.delegate = keeper
        for word in ["🎉", "中文", "漢字"] {
            let face = try #require(storage.attribute(.font, at: string.range(of: word).location, effectiveRange: nil) as? NSFont)
            try #require(NoteAppKitBridge.intent(of: face) == [], "\(word) is in a plain fallback face now: \(face.fontName)")
        }
        #expect(NoteAppKitBridge.note(storage) == expected, "after the fonts were swapped")
        // TextKit 1, which a text view falls back to for good the moment
        // anything asks for its layout manager, fixes fonts as it lays out.
        let layout = try #require(textView.layoutManager)
        layout.ensureLayout(for: try #require(textView.textContainer))
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { _, _, _ in }
        #expect(NoteAppKitBridge.note(storage) == expected, "after TextKit 1 laid it out")
        #expect(h.model.text == expected)
    }
}
