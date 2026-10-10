import Foundation

/// A note as the HTML that Notes.app wants.
///
/// Notes' scripting dictionary describes its `body` property as "the HTML
/// content of the note" — it is the only writable content property, and HTML is
/// what it expects, so this is the whole of the export format.
///
/// The mapping is done by hand, which is not an oversight. `AttributedString`
/// here carries Foundation's `inlinePresentationIntent` and nothing else, on
/// purpose: it encodes as a plain integer that anything can read, where a
/// SwiftUI font attribute encodes as a blob nothing else can. The cost is that
/// `inlinePresentationIntent` means nothing to AppKit — bridging to
/// `NSAttributedString` and asking it for HTML yields unformatted text, because
/// that writer only looks at real font traits. So the intent is read here and
/// written as tags directly.
public enum NoteHTML {

    public static func render(_ text: AttributedString) -> String {
        var html = ""
        for run in text.runs {
            let piece = String(text.characters[run.range])
            guard !piece.isEmpty else { continue }
            var open = "", close = ""
            if let intent = run.inlinePresentationIntent {
                // Nested in a fixed order so the closing tags mirror the
                // opening ones and the markup stays well formed.
                if intent.contains(.stronglyEmphasized) { open += "<b>"; close = "</b>" + close }
                if intent.contains(.emphasized) { open += "<i>"; close = "</i>" + close }
            }
            html += open + escaped(piece) + close
        }
        return html
    }

    /// Escapes the three characters that would otherwise be read as markup, and
    /// turns newlines into breaks.
    ///
    /// A literal newline inside an HTML body is whitespace, not a line break —
    /// a note written as several paragraphs would arrive as one. The escaping
    /// happens first so a `<br>` this adds is never escaped in turn.
    private static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\n": out += "<br>"
            default: out.append(character)
            }
        }
        return out
    }

    /// The text as an AppleScript string literal, quotes and all.
    ///
    /// The script is handed to `osascript` as an argument rather than through a
    /// shell, so there is no shell to escape for; what remains is AppleScript's
    /// own string syntax, where only the backslash and the double quote mean
    /// anything.
    public static func appleScriptLiteral(_ text: String) -> String {
        var out = "\""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default: out.append(character)
            }
        }
        return out + "\""
    }
}
