import Foundation
import Testing
@testable import LedgeCore

@Suite("Note export formats")
struct NoteFormatsTests {

    private func styled(_ text: String, _ intent: InlinePresentationIntent) -> AttributedString {
        var piece = AttributedString(text)
        piece.inlinePresentationIntent = intent
        return piece
    }

    @Test("Bold and italic become tags, and both become nested tags")
    func html() {
        var note = AttributedString("plain ")
        note += styled("bold", .stronglyEmphasized)
        note += AttributedString(" ")
        note += styled("both", [.stronglyEmphasized, .emphasized])
        let html = NoteHTML.render(note)
        #expect(html.contains("<b>bold</b>"))
        #expect(html.contains("<b><i>both</i></b>"))
        #expect(html.hasPrefix("plain "))
    }

    @Test("Markup in the user's own writing is escaped, never passed through")
    func htmlEscaping() {
        // Otherwise a note containing `<b>` would arrive in Notes as bold text
        // the user never asked for — or worse, as broken markup.
        let html = NoteHTML.render(AttributedString("a < b & c > d <b>not bold</b>"))
        #expect(!html.contains("<b>"))
        #expect(html.contains("&lt;"))
        #expect(html.contains("&amp;"))
        #expect(html.contains("&gt;"))
    }

    @Test("Newlines become breaks, because a newline in HTML is only a space")
    func htmlBreaks() {
        let html = NoteHTML.render(AttributedString("first\nsecond"))
        #expect(html == "first<br>second")
    }

    @Test("Quotes and backslashes survive the trip through AppleScript")
    func scriptLiteral() {
        let literal = NoteHTML.appleScriptLiteral(#"say "hi" \ bye"#)
        #expect(literal == #""say \"hi\" \\ bye""#)
    }

    @Test("Markdown marks hug the word, not the spaces around it")
    func markdown() {
        // `** bold **` is four asterisks in every parser, not emphasis.
        var note = styled(" bold ", .stronglyEmphasized)
        note += styled("em", .emphasized)
        note += styled("both", [.stronglyEmphasized, .emphasized])
        let markdown = NoteMarkdown.render(note)
        #expect(markdown == " **bold** _em_**_both_**")
    }

    @Test("Text with no styling comes back unchanged, in both formats")
    func plain() {
        let note = AttributedString("nothing special here")
        #expect(NoteMarkdown.render(note) == "nothing special here")
        #expect(NoteHTML.render(note) == "nothing special here")
    }
}
