import Foundation

/// A note as Markdown, for the clipboard.
///
/// The same two intents the app stores, written as the marks everything else
/// understands. Bold is `**`, italic is `_` — the underscore rather than a
/// single asterisk so that a word in both reads as `**_word_**` instead of
/// three asterisks running together, which many parsers get wrong.
public enum NoteMarkdown {

    public static func render(_ text: AttributedString) -> String {
        var out = ""
        for run in text.runs {
            let piece = String(text.characters[run.range])
            guard !piece.isEmpty else { continue }
            let intent = run.inlinePresentationIntent ?? []
            let bold = intent.contains(.stronglyEmphasized)
            let italic = intent.contains(.emphasized)
            guard bold || italic else { out += piece; continue }
            // Marks go inside the run's own leading and trailing spaces: a
            // `** bold **` with the spaces inside the marks is not emphasis in
            // any parser, it is four literal asterisks.
            let leading = piece.prefix { $0.isWhitespace }
            let trailing = piece.reversed().prefix { $0.isWhitespace }.reversed()
            let core = piece.dropFirst(leading.count).dropLast(trailing.count)
            guard !core.isEmpty else { out += piece; continue }
            var marked = String(core)
            if italic { marked = "_" + marked + "_" }
            if bold { marked = "**" + marked + "**" }
            out += leading + marked + trailing
        }
        return out
    }
}
