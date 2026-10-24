import Foundation
import Testing
@testable import LedgeCore

/// What a note may keep, and how a note is read back when its attributes
/// cannot be.
@Suite("Note text")
struct NoteTextTests {

    private func styled(_ text: String, _ intent: InlinePresentationIntent) -> AttributedString {
        var piece = AttributedString(text)
        piece.inlinePresentationIntent = intent
        return piece
    }

    /// Every attribute Foundation itself can put on a run, beside the two
    /// that may stay.
    private func polluted() -> AttributedString {
        var note = AttributedString("plain ")
        note += styled("bold", .stronglyEmphasized)
        note += AttributedString(" ")
        note += styled("both", [.stronglyEmphasized, .emphasized])
        note += AttributedString(" ")
        note += styled("code", [.code, .emphasized])
        note += AttributedString(" ")
        note += styled("struck", .strikethrough)
        var link = AttributedString(" link")
        link.link = URL(string: "https://example.com")
        link.languageIdentifier = "en"
        note += link
        return note
    }

    @Test("Normalising keeps every character, bold and italic, and nothing else")
    func normalizedIsIdempotentAndKeepsCharacters() throws {
        let note = polluted()
        try #require(note.runs.contains { $0.link != nil }, "the fixture carries a link")
        try #require(note.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true },
                     "the fixture carries a code intent")

        let clean = NoteText.normalized(note)
        #expect(String(clean.characters) == String(note.characters))
        #expect(clean.runs.allSatisfy { $0.link == nil && $0.languageIdentifier == nil })
        #expect(clean.runs.allSatisfy {
            ($0.inlinePresentationIntent ?? []).isSubset(of: NoteText.allowedIntent)
        })
        #expect(clean[try #require(clean.range(of: "bold"))].inlinePresentationIntent == .stronglyEmphasized)
        #expect(clean[try #require(clean.range(of: "both"))].inlinePresentationIntent == [.stronglyEmphasized, .emphasized])
        #expect(clean[try #require(clean.range(of: "code"))].inlinePresentationIntent == .emphasized)
        #expect(clean[try #require(clean.range(of: "struck"))].inlinePresentationIntent == nil)
        #expect(NoteText.normalized(clean) == clean)
    }

    @Test("Normalised text encodes as intent and nothing else")
    func normalizedEncodesPlainly() throws {
        let json = String(decoding: try JSONEncoder().encode(NoteText.normalized(polluted())), as: UTF8.self)
        try #require(json.contains("NSInlinePresentationIntent"), "bold survived to be encoded")
        #expect(!json.contains("NSLink"))
        #expect(!json.contains("NSLanguage"))
    }

    // MARK: - List markers

    @Test("A pasted list's tab, bullet, tab becomes the bullet a person types")
    func listMarkersCollapse() {
        var text = AttributedString("Shopping\n\t•\tmilk\n\t◦\teggs\nend")
        #expect(NoteText.collapseListMarkers(in: &text))
        #expect(String(text.characters) == "Shopping\n• milk\n◦ eggs\nend")
    }

    @Test("A bold list item stays bold through the collapse")
    func listMarkersKeepStyle() throws {
        var text = styled("\t•\tbold item", .stronglyEmphasized)
        NoteText.collapseListMarkers(in: &text)
        try #require(String(text.characters) == "• bold item")
        #expect(text.runs.count == 1)
        #expect(text.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
    }

    @Test("Tabs a person typed are left alone")
    func typedTabsStay() {
        // Mid-line, a bare marker still being typed, and a numbered column:
        // none of them is a pasted list item.
        for typed in ["a\t•\tb", "\t•\t", "\t•\t ", "\t1\tapples", "\tx\ty", "plain"] {
            var text = AttributedString(typed)
            #expect(!NoteText.collapseListMarkers(in: &text), "rewrote \(typed.debugDescription)")
            #expect(String(text.characters) == typed)
        }
    }

    // MARK: - Salvage

    private func salvage(_ json: String) throws -> AttributedString {
        try JSONDecoder().decode(SalvagedNoteText.self, from: Data(json.utf8)).text
    }

    @Test("Salvage reads every shape AttributedString writes")
    func salvageShapes() throws {
        // Each fixture is what Foundation itself writes, so the salvage is
        // checked against the real shapes rather than against a guess.
        let plain = AttributedString("just words")
        var mixed = AttributedString("a ")
        mixed += styled("b", .stronglyEmphasized)
        mixed += AttributedString(" c")
        var repeated = AttributedString()
        for i in 0 ..< 20 {
            repeated += i.isMultiple(of: 2) ? styled("w\(i) ", .emphasized) : AttributedString("w\(i) ")
        }
        for note in [plain, mixed, repeated] {
            let json = String(decoding: try JSONEncoder().encode(note), as: UTF8.self)
            let back = try salvage(json)
            #expect(back == note, "\(json.prefix(80))")
        }
        let tabled = String(decoding: try JSONEncoder().encode(repeated), as: UTF8.self)
        try #require(tabled.contains("attributeTable"), "the repeated fixture uses the table shape")
    }

    @Test("A run whose attributes cannot be read keeps its characters and its bold")
    func salvageKeepsWhatItCan() throws {
        let json = """
        ["old ",{"NSInlinePresentationIntent":2},"HILITE",{"SwiftUI.BackgroundColor":{"tag":{"someFutureProvider":{}},"value":"AAAA"},"NSInlinePresentationIntent":1}," note",{}]
        """
        let back = try salvage(json)
        #expect(String(back.characters) == "old HILITE note")
        #expect(back[try #require(back.range(of: "old"))].inlinePresentationIntent == .stronglyEmphasized)
        #expect(back[try #require(back.range(of: "HILITE"))].inlinePresentationIntent == .emphasized)
        #expect(back[try #require(back.range(of: " note"))].inlinePresentationIntent == nil)
    }

    @Test("Intent bits Ledge has no control for are not salvaged either")
    func salvageDropsForeignIntent() throws {
        // 6 is bold and .code; kept, the code bit would be stored unseen.
        let back = try salvage(#"["x",{"NSInlinePresentationIntent":6}]"#)
        #expect(back.runs.first?.inlinePresentationIntent == .stronglyEmphasized)
    }

    @Test("Something that is not text at all is still refused")
    func salvageRefusesGarbage() {
        #expect(throws: (any Error).self) { try salvage(#"{"what":1}"#) }
        #expect(throws: (any Error).self) { try salvage(#"[1, 2]"#) }
    }
}
