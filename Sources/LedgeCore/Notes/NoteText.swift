import Foundation

/// What a note is allowed to be made of.
///
/// Characters, and bold and italic as Foundation's `inlinePresentationIntent`.
/// Nothing else: those are the only things Ledge has a way to make, so they are
/// the only things a note may keep, whatever arrived in it.
///
/// A paste used to bring everything along — highlight, colours, fonts,
/// underline, links — and most of it was written to the note's file as
/// SwiftUI's private archived blobs. One highlighted word made a 15-character
/// note thirteen kilobytes, the user's white highlight came back on every
/// reopen, and Ledge had no control that could take it off again.
public enum NoteText {

    /// The two intents Ledge has controls for.
    public static let allowedIntent: InlinePresentationIntent = [.stronglyEmphasized, .emphasized]

    /// The note as Ledge could have made it: its characters, plus bold and
    /// italic as intent.
    ///
    /// Run at both of the model's edges — on the way to disk and on the way
    /// back — so nothing else can be saved, and a note an earlier build saved
    /// with a highlight in it opens clean and is written back clean.
    public static func normalized(_ text: AttributedString) -> AttributedString {
        var out = AttributedString()
        for run in text.runs {
            var piece = AttributedString(String(text.characters[run.range]))
            // Bold and italic and no more: `.code`, `.strikethrough` and the
            // other bits can ride in on SwiftUI's own pasteboard type, and
            // nothing in Ledge would ever show them or take them off.
            let kept = (run.inlinePresentationIntent ?? []).intersection(allowedIntent)
            if !kept.isEmpty { piece.inlinePresentationIntent = kept }
            out.append(piece)
        }
        return out
    }

    /// A pasted list item's tab, bullet, tab, and what it becomes.
    public struct ListMarker: Equatable, Sendable {
        /// The three characters, in the string they were found in.
        public let range: Range<String.Index>
        /// The bullet and a space: what the same line looks like typed.
        public let replacement: String
    }

    /// Where a rich paste has spelled a list out, in place of the bullet a
    /// person types.
    ///
    /// AppKit reads an HTML or RTF list as literal characters — a tab, the
    /// marker, a tab — and leaves the indenting to a paragraph style. Ledge
    /// keeps no paragraph styles, so what was left was a marker floating
    /// between two tab stops. "• " is what the same line looks like written in
    /// Ledge by hand.
    ///
    /// Only the bullets `NSTextList` draws, only at the start of a line and
    /// only with words after them — the shape a pasted list item has and a
    /// line being typed does not. Numbered items are left as they came: a tab,
    /// a number and a tab is also how somebody lines up a column by hand, and
    /// rewriting that under them would be the editor arguing.
    public static func listMarkers(in string: String) -> [ListMarker] {
        // Almost every edit has no tab in it at all, and this is asked after
        // every one.
        guard string.contains("\t") else { return [] }
        var found: [ListMarker] = []
        var lineStart = string.startIndex
        while lineStart < string.endIndex {
            let line = string[lineStart...].prefix { $0 != "\n" }
            let opening = Array(line.prefix(4))
            if opening.count == 4, opening[0] == "\t", listBullets.contains(opening[1]), opening[2] == "\t",
               !opening[3].isWhitespace {
                let end = string.index(lineStart, offsetBy: 3)
                found.append(ListMarker(range: lineStart ..< end, replacement: String(opening[1]) + " "))
            }
            guard line.endIndex < string.endIndex else { break }
            lineStart = string.index(after: line.endIndex)
        }
        return found
    }

    /// The same, made in an attributed string; says whether anything
    /// changed. Each bullet keeps the style of the marker it replaces.
    @discardableResult
    public static func collapseListMarkers(in text: inout AttributedString) -> Bool {
        let plain = String(text.characters)
        let found = listMarkers(in: plain)
        // From the end back, so every offset still means what it did.
        for marker in found.reversed() {
            let offset = plain.distance(from: plain.startIndex, to: marker.range.lowerBound)
            let lower = text.characters.index(text.startIndex, offsetBy: offset)
            let upper = text.characters.index(lower, offsetBy: plain[marker.range].count)
            var replacement = AttributedString(marker.replacement)
            replacement.mergeAttributes(text[lower ..< upper].runs.first?.attributes ?? AttributeContainer())
            text.replaceSubrange(lower ..< upper, with: replacement)
        }
        return !found.isEmpty
    }

    /// The markers `NSTextList` writes: disc, circle, square, box, diamond,
    /// hyphen and check.
    public static let listBullets: Set<Character> = ["•", "◦", "▪", "▫", "◆", "⁃", "✓"]
}

/// A note's text read back without SwiftUI's help, for when SwiftUI cannot.
///
/// Notes saved before `NoteText.normalized` existed can hold a pasted colour
/// as SwiftUI's private archive of it. If a later SDK changes that encoding,
/// or the archive is damaged, `AttributedString`'s own decoder throws for the
/// whole string, and the store would set the entire note aside as unreadable —
/// the user losing every word to lose a highlight. This reads the same JSON
/// shapes `AttributedString` writes and keeps what Ledge can use: the
/// characters, and bold and italic wherever their integer is readable.
///
/// Three shapes are written: a bare string for a note with no formatting; an
/// array of text and attributes in turn; and, once attributes repeat often
/// enough, an object whose runs point into a shared attribute table by index.
public struct SalvagedNoteText: Decodable, Sendable {

    public let text: AttributedString

    private enum Keys: String, CodingKey { case runs, attributeTable }

    /// The one attribute worth reading out of a run.
    private struct Intent: Decodable {
        let value: InlinePresentationIntent?

        private enum Keys: String, CodingKey { case intent = "NSInlinePresentationIntent" }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let raw = (try? c.decodeIfPresent(UInt.self, forKey: .intent)) ?? nil
            let kept = InlinePresentationIntent(rawValue: raw ?? 0).intersection(NoteText.allowedIntent)
            value = kept.isEmpty ? nil : kept
        }
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let plain = try? single.decode(String.self) {
            text = AttributedString(plain)
            return
        }
        var table: [InlinePresentationIntent?] = []
        var runs: any UnkeyedDecodingContainer
        if let keyed = try? decoder.container(keyedBy: Keys.self), keyed.contains(.runs) {
            if var entries = try? keyed.nestedUnkeyedContainer(forKey: .attributeTable) {
                while !entries.isAtEnd {
                    table.append((try? entries.decode(Intent.self))?.value)
                }
            }
            runs = try keyed.nestedUnkeyedContainer(forKey: .runs)
        } else {
            runs = try decoder.unkeyedContainer()
        }
        var out = AttributedString()
        while !runs.isAtEnd {
            let characters = try runs.decode(String.self)
            var piece = AttributedString(characters)
            guard !runs.isAtEnd else { out.append(piece); break }
            // Attributes are either inline or an index into the table; either
            // way a run whose attributes cannot be read keeps its characters.
            if let index = try? runs.decode(Int.self) {
                piece.inlinePresentationIntent = table.indices.contains(index) ? table[index] : nil
            } else {
                piece.inlinePresentationIntent = (try? runs.decode(Intent.self))?.value
            }
            out.append(piece)
        }
        text = out
    }
}
