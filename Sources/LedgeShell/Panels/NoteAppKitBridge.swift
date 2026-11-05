import AppKit
import LedgeCore
import LedgeUI
import SwiftUI

/// A note's text as AppKit draws it, and back.
///
/// The macOS 15 editor is an `NSTextView`, which knows nothing of intents: it
/// draws bold from a bold font. So on the way in each run is given the face its
/// intent calls for, and on the way out each run's intent is read off its face.
/// What survives the trip is what a note may hold — characters, bold and
/// italic — through the same `NoteText.normalized` the other editor stores
/// through, so a note reads the same whichever editor last saved it.
enum NoteAppKitBridge {

    /// The face the intent calls for, as `NoteFace` gives it to the other
    /// editor: the system font at 13 points, bold and italic as traits.
    static func font(for intent: InlinePresentationIntent) -> NSFont {
        switch (intent.contains(.stronglyEmphasized), intent.contains(.emphasized)) {
        case (false, false): faces.regular
        case (true, false): faces.bold
        case (false, true): faces.italic
        case (true, true): faces.boldItalic
        }
    }

    /// Made the way SwiftUI makes them for the other editor — CoreText's
    /// system and emphasised-system UI fonts, with italic as a trait — so the
    /// text view is handed the same fonts, by name, and not merely the same
    /// family: `.SFNS-Regular`, `.SFNS-Bold`, `.SFNS-RegularItalic` and
    /// `.SFNS-BoldItalic`. Fonts are immutable, so the four can be shared.
    nonisolated(unsafe) private static let faces: (regular: NSFont, bold: NSFont, italic: NSFont, boldItalic: NSFont) = {
        func ui(_ type: CTFontUIFontType) -> CTFont {
            CTFontCreateUIFontForLanguage(type, 13, nil) ?? (NSFont.systemFont(ofSize: 13) as CTFont)
        }
        func italic(_ font: CTFont) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(font, 13, nil, .traitItalic, .traitItalic) ?? font
        }
        let regular = ui(.system)
        let bold = ui(.emphasizedSystem)
        return (regular as NSFont, bold as NSFont, italic(regular) as NSFont, italic(bold) as NSFont)
    }()

    /// The note's ink, the colour `.foregroundStyle(NoteInk.text)` draws in.
    static let ink = NSColor(NoteInk.text)

    /// The space between lines, the other editor's `.lineSpacing(3)`, in the
    /// paragraph style its text view was measured to carry: AppKit's own,
    /// with the standard line-break strategy, which keeps a lone word off the
    /// last line of a paragraph, and no tightening. Immutable once made, so it
    /// can be shared.
    nonisolated(unsafe) static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.lineBreakStrategy = .standard
        style.allowsDefaultTighteningForTruncation = false
        return style
    }()

    /// The intent on a run Ledge styled, under a name of Ledge's own.
    ///
    /// Not Foundation's `.inlinePresentationIntent`, which the other editor's
    /// text view carries: an AppKit text storage takes that one out of whatever
    /// is put in it, so it is never there to be read back. AppKit leaves this
    /// one alone. It is never written anywhere: copying, dragging and Services
    /// put rich text on the pasteboard without it, and a note's file keeps
    /// intent alone. It is in the text view's own text, though, beside the
    /// window's near-white ink, so what AppKit hands that text to directly —
    /// the Share menu, Writing Tools, accessibility — is given both. The key
    /// means nothing to any of them, and what Writing Tools hands back is held
    /// to Ledge's attributes like any other change.
    static let intentKey = NSAttributedString.Key("com.egemert.ledge.note-intent")

    /// Everything a run of a note carries on screen, and nothing else: the
    /// face, the ink, the line spacing, and on a bold or italic run the intent
    /// itself.
    static func attributes(for intent: InlinePresentationIntent) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: intent), .foregroundColor: ink, .paragraphStyle: paragraphStyle,
        ]
        let kept = intent.intersection(NoteText.allowedIntent)
        if !kept.isEmpty { attributes[intentKey] = NSNumber(value: kept.rawValue) }
        return attributes
    }

    /// Bold and italic, read off a face.
    ///
    /// The font's own traits. Measured against the other editor's formatting
    /// definition on macOS 26 across sixty faces, pasted, they decide every one
    /// the same way: Helvetica Bold, Times Bold from an `<h1>`, semibold and
    /// anything heavier are bold, and a medium face or anything lighter is not.
    static func intent(of font: NSFont) -> InlinePresentationIntent {
        let traits = font.fontDescriptor.symbolicTraits
        var intent: InlinePresentationIntent = []
        if traits.contains(.bold) { intent.insert(.stronglyEmphasized) }
        if traits.contains(.italic) { intent.insert(.emphasized) }
        return intent
    }

    /// The intent a run of AppKit text stands for.
    ///
    /// Ledge's own, first, when the run has it: Ledge writes it on every run
    /// it makes bold or italic, and it outlasts the face. AppKit swaps a
    /// fallback font into a run for a character the face cannot draw — an
    /// emoji, a check mark, Chinese — and that font is not bold, so bold read
    /// off the face alone went plain the moment it happened.
    ///
    /// What arrives from outside has no such mark, and is read in the other
    /// editor's order: the intent it says it has, held to bold and italic,
    /// unless it has a face, which then decides.
    ///
    /// Ledge's own face on a run is the exception, and decides even over the
    /// mark: one of the four can only have been put there on purpose — Paste
    /// Style, the Styles panel — and the other editor reads a face that way.
    static func intent(of attributes: [NSAttributedString.Key: Any]) -> InlinePresentationIntent {
        let face = attributes[.font] as? NSFont
        if let own = attributes[intentKey], !(face.map(isLedgeFace) ?? false) {
            return said(own).intersection(NoteText.allowedIntent)
        }
        if let face { return intent(of: face) }
        return said(attributes[.inlinePresentationIntent]).intersection(NoteText.allowedIntent)
    }

    /// Whether a font is one of the four Ledge draws a note in.
    static func isLedgeFace(_ font: NSFont) -> Bool {
        font.pointSize == 13
            && [faces.regular, faces.bold, faces.italic, faces.boldItalic].contains { $0.fontName == font.fontName }
    }

    private static func said(_ value: Any?) -> InlinePresentationIntent {
        if let intent = value as? InlinePresentationIntent { return intent }
        if let number = value as? NSNumber { return InlinePresentationIntent(rawValue: number.uintValue) }
        return []
    }

    /// The attributes a run should have, given the ones it arrived with, or
    /// nil when it already has them.
    ///
    /// Two of AppKit's own are left alone: the clause marks an input method
    /// puts on text it is still composing, and dictation's alternatives.
    /// Neither is formatting and neither reaches the note; they belong to
    /// whatever put them there.
    static func clamped(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]? {
        var own = Self.attributes(for: intent(of: attributes))
        for key in [NSAttributedString.Key.markedClauseSegment, .textAlternatives] {
            if let value = attributes[key] { own[key] = value }
        }
        guard !NSDictionary(dictionary: attributes).isEqual(to: own) else { return nil }
        return own
    }

    /// Holds a stretch of text to Ledge's own attributes, wherever it came
    /// from: a paste, a drop, a Service, the Font menu, a dictation.
    static func clamp(_ text: NSMutableAttributedString, in range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        text.enumerateAttributes(in: range) { attributes, run, _ in
            if let own = clamped(attributes) { text.setAttributes(own, range: run) }
        }
    }

    /// A note as the text view should draw it.
    static func appKit(_ text: AttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in text.runs {
            let intent = (run.inlinePresentationIntent ?? []).intersection(NoteText.allowedIntent)
            out.append(NSAttributedString(string: String(text.characters[run.range]),
                                          attributes: attributes(for: intent)))
        }
        return out
    }

    /// What the text view holds, as a note: its characters, and bold and
    /// italic as intent.
    ///
    /// The object replacement character goes too. It is what an image or a
    /// file leaves in text, and a note keeps neither, so all it could ever
    /// become is a box nobody put there.
    static func note(_ drawn: NSAttributedString) -> AttributedString {
        let whole = NSRange(location: 0, length: drawn.length)
        let kept = NSMutableAttributedString(string: drawn.string)
        drawn.enumerateAttributes(in: whole) { attributes, range, _ in
            let intent = Self.intent(of: attributes)
            guard !intent.isEmpty else { return }
            kept.addAttribute(.inlinePresentationIntent, value: NSNumber(value: intent.rawValue), range: range)
        }
        let characters = kept.mutableString
        var at = characters.range(of: Self.objectReplacement, options: [.backwards, .literal])
        while at.location != NSNotFound {
            kept.deleteCharacters(in: at)
            at = characters.range(of: Self.objectReplacement, options: [.backwards, .literal],
                                  range: NSRange(location: 0, length: at.location))
        }
        if let text = try? AttributedString(kept, including: \.foundation) {
            return NoteText.normalized(text)
        }
        // Foundation turns down nothing this holds, but losing the bold is not
        // how to find out otherwise.
        var text = AttributedString()
        kept.enumerateAttribute(.inlinePresentationIntent, in: NSRange(location: 0, length: kept.length)) { value, range, _ in
            var piece = AttributedString(kept.attributedSubstring(from: range).string)
            let intent = said(value)
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            text.append(piece)
        }
        return NoteText.normalized(text)
    }

    static let objectReplacement = "\u{FFFC}"
}
