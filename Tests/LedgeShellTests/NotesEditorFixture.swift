import AppKit
import Foundation
import LedgeCore
import LedgeSystem
import Testing
@testable import LedgeShell

/// One note, the way both editors are measured on it.
///
/// The parity tests hold the AppKit editor to the SwiftUI one side by side,
/// which needs macOS 26. What the SwiftUI editor measured on this note is also
/// written down, in `NotesEditorFixtureData.swift`, so a Mac without it can
/// still hold the AppKit editor to it — and the parity tests check, where both
/// run, that the SwiftUI editor still measures what was written down.
@MainActor
enum NotesEditorFixture {

    typealias Harness = NotesUndoTests.Harness

    static var sample: AttributedString {
        var text = AttributedString(
            "Groceries for the week\nplain BOLD ITAL BOTH tail\n• milk\n• eggs 🥚 and 日本語\n"
                + "A line long enough to wrap at least once inside a window three hundred and sixty points wide, "
                + "so the second line of it is laid out too\nשלום עולם, a line that starts right to left\n"
                + "مرحبا بالعالم\ncafe\u{301} last line"
        )
        text[text.range(of: "Groceries")!].inlinePresentationIntent = .stronglyEmphasized
        text[text.range(of: "BOLD")!].inlinePresentationIntent = .stronglyEmphasized
        text[text.range(of: "ITAL")!].inlinePresentationIntent = .emphasized
        text[text.range(of: "BOTH")!].inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
        text[text.range(of: "日本語")!].inlinePresentationIntent = .emphasized
        return text
    }

    /// An editor with this note open, in a window set up as the controller
    /// sets up its own: dark, clear, 360 by 420.
    static func open(_ kind: NotesEditorKind, _ text: AttributedString) async throws -> (Harness, NSTextView) {
        _ = NSApplication.shared
        let h = Harness(kind)
        h.panel.appearance = NSAppearance(named: .darkAqua)
        h.panel.isOpaque = false
        h.panel.backgroundColor = .clear
        let note = await h.store.create()
        await h.store.update(note.id, text: text)
        await h.store.flush()
        let body = try #require(await h.store.body(note.id))
        h.hosting.layoutSubtreeIfNeeded()
        h.present(body)
        let textView = try #require(h.textView())
        let deadline = ContinuousClock.now + .seconds(5)
        while textView.string != String(text.characters), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(textView.string == String(text.characters), "\(kind): the note is on screen")
        return (h, textView)
    }

    /// Where every character is drawn, in the window's own points from its
    /// top left.
    static func rects(_ textView: NSTextView, in h: Harness) -> [CGRect] {
        (0 ..< (textView.string as NSString).length).map { location in
            let onScreen = textView.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
            return h.hosting.convert(h.panel.convertFromScreen(onScreen), from: nil)
        }
    }

    /// The text's own frame in the window.
    static func frame(_ textView: NSTextView, in h: Harness) -> CGRect {
        guard let scroll = textView.enclosingScrollView else { return .zero }
        return scroll.convert(scroll.bounds, to: h.hosting)
    }

    /// The face of each run, as "start-end name".
    static func faces(_ textView: NSTextView) -> [String] {
        guard let storage = textView.textStorage else { return [] }
        var out: [String] = []
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            out.append("\(range.location)-\(NSMaxRange(range)) \((value as? NSFont)?.fontName ?? "none") \((value as? NSFont)?.pointSize ?? 0)")
        }
        return out
    }

    /// A picture of the window, as the window server would get it.
    static func picture(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Whether a pixel is the note's ink rather than the window's black.
    static func isInk(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        var pixel = [Int](repeating: 0, count: 4)
        rep.getPixel(&pixel, atX: x, y: y)
        return pixel[0] > 128 && pixel[1] > 128 && pixel[2] > 128
    }

    /// How much ink is drawn inside a rectangle of the window, in square
    /// points, so a picture at either scale gives about the same answer.
    static func ink(_ rep: NSBitmapImageRep, in rect: CGRect, of view: NSView) -> Double {
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        let minX = max(0, Int((rect.minX * scale).rounded(.down))), maxX = min(rep.pixelsWide, Int((rect.maxX * scale).rounded(.up)))
        let minY = max(0, Int((rect.minY * scale).rounded(.down))), maxY = min(rep.pixelsHigh, Int((rect.maxY * scale).rounded(.up)))
        guard minX < maxX, minY < maxY else { return 0 }
        var count = 0
        for y in minY ..< maxY {
            for x in minX ..< maxX where isInk(rep, x: x, y: y) { count += 1 }
        }
        return Double(count) / Double(scale * scale)
    }

    static func srgb(_ color: NSColor?) -> [Int] {
        guard let c = color?.usingColorSpace(.sRGB) else { return [] }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    /// A paragraph style by everything about it that AppKit makes public.
    ///
    /// Not `==`: SwiftUI's carries one private flag besides, that natural
    /// alignment follows each paragraph's own direction, which no public API
    /// can set. It changes nothing drawn — the layout and pixel tests include
    /// lines that start right to left — and the AppKit editor's own tests hold
    /// such a line to the right on whatever macOS they run.
    static func describe(_ style: NSParagraphStyle?) -> String {
        guard let s = style else { return "none" }
        return "align \(s.alignment.rawValue) spacing \(s.lineSpacing) before \(s.paragraphSpacingBefore) after \(s.paragraphSpacing) "
            + "head \(s.headIndent) tail \(s.tailIndent) first \(s.firstLineHeadIndent) min \(s.minimumLineHeight) "
            + "max \(s.maximumLineHeight) multiple \(s.lineHeightMultiple) break \(s.lineBreakMode.rawValue) "
            + "strategy \(s.lineBreakStrategy.rawValue) direction \(s.baseWritingDirection.rawValue) "
            + "hyphenation \(s.hyphenationFactor) tighten \(s.tighteningFactorForTruncation) "
            + "tabs \(s.tabStops.map { "\($0.location)/\($0.alignment.rawValue)" }) interval \(s.defaultTabInterval) "
            + "lists \(s.textLists.count) blocks \(s.textBlocks.count) header \(s.headerLevel) "
            + "truncation \(s.allowsDefaultTighteningForTruncation) usesHyphenation \(s.usesDefaultHyphenation)"
    }

    /// Everything written down about one editor on this note, measured the
    /// same way whichever editor it is.
    struct Measured: Equatable {
        var frame: [Double]
        var rects: [[Double]]
        var findRects: [[Double]]
        var faces: [String]
        var paragraph: String
        var ink: [Int]
        var inkArea: Double
        /// The pictures' backing scale, which the ink area depends on.
        var scale: Double = 2
    }

    static func measure(_ kind: NotesEditorKind) async throws -> Measured {
        let (h, textView) = try await open(kind, sample)
        defer {
            h.model.onEdit = nil
            h.panel.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        func points(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { (Double($0) * 1000).rounded() / 1000 } }
        let frame = Self.frame(textView, in: h)
        let rects = Self.rects(textView, in: h).map(points)
        let faces = Self.faces(textView)
        let storage = try #require(textView.textStorage)
        let paragraph = describe(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let ink = srgb(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        _ = h.panel.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(300))
        let shot = try picture(h.hosting)
        let inkArea = Self.ink(shot, in: frame, of: h.hosting)
        let scale = Double(shot.pixelsHigh) / Double(h.hosting.bounds.height)
        h.model.show(.find)
        try await Task.sleep(for: .milliseconds(300))
        let found = try #require(h.textView())
        let findRects = Self.rects(found, in: h).map(points)
        return Measured(frame: points(frame), rects: rects, findRects: findRects, faces: faces, paragraph: paragraph,
                        ink: ink, inkArea: (inkArea * 10).rounded() / 10, scale: scale)
    }

    /// The same, held only to what does not hang on the system font's exact
    /// metrics, for a macOS whose fonts may measure a little differently from
    /// the one this was written down on: the frame; each line's top, height
    /// and first character; where a line that starts left to right starts;
    /// the faces of the bold and italic runs; the paragraph style and the ink.
    /// Emoji, Chinese, right to left and combining characters are left out of
    /// the positions, and characters with no box of their own on either side
    /// are passed over. The ink drawn is only compared at the same scale.
    static func structuralDifferences(_ measured: Measured, from fixture: Measured) -> [String] {
        var out: [String] = []
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(0.5, abs(b) * 0.01) }
        if !zip(measured.frame, fixture.frame).allSatisfy(near) || measured.frame.count != fixture.frame.count {
            out.append("frame \(measured.frame), written down \(fixture.frame)")
        }
        let string = String(sample.characters) as NSString
        for (name, a, b) in [("note", measured.rects, fixture.rects), ("find", measured.findRects, fixture.findRects)] {
            let mine = lines(a, in: string), theirs = lines(b, in: string)
            guard mine.count == theirs.count else {
                out.append("\(name): \(mine.count) lines, written down \(theirs.count)")
                continue
            }
            for (i, (x, y)) in zip(mine, theirs).enumerated() {
                if x.first != y.first || !near(x.top, y.top) || !near(x.height, y.height) {
                    out.append("\(name) line \(i): from \(x.first) at \(x.top) high \(x.height), "
                        + "written down from \(y.first) at \(y.top) high \(y.height)")
                }
                if let mx = x.leading, let my = y.leading, !near(mx, my) {
                    out.append("\(name) line \(i) starts at \(mx), written down \(my)")
                }
            }
        }
        let styled = { (faces: [String]) in faces.filter { !$0.contains(" .SFNS-Regular ") } }
        if styled(measured.faces) != styled(fixture.faces) {
            out.append("styled faces \(styled(measured.faces)), written down \(styled(fixture.faces))")
        }
        if measured.paragraph != fixture.paragraph { out.append("paragraph \(measured.paragraph), written down \(fixture.paragraph)") }
        if measured.ink != fixture.ink { out.append("ink \(measured.ink), written down \(fixture.ink)") }
        if measured.scale == fixture.scale, abs(measured.inkArea - fixture.inkArea) > fixture.inkArea * 0.05 {
            out.append("ink drawn over \(measured.inkArea) square points, written down \(fixture.inkArea)")
        }
        return out
    }

    /// One line of the laid-out note, from where its characters are drawn.
    struct Line {
        var first: Int
        var top: Double
        var height: Double
        /// Where its first character starts, when that is a Latin one.
        var leading: Double?
    }

    static func lines(_ rects: [[Double]], in string: NSString) -> [Line] {
        var out: [Line] = []
        for (location, rect) in rects.enumerated() where rect.count == 4 && rect[2] > 0 && rect[3] > 0 {
            if let last = out.last, abs(last.top - rect[1]) < 0.5 { continue }
            let unit = string.character(at: location)
            let latin = unit < 0x0250 && !CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(unit)!)
            out.append(Line(first: location, top: rect[1], height: rect[3], leading: latin ? rect[0] : nil))
        }
        return out
    }

    /// Whether anything but the window's black is drawn inside a rectangle.
    static func drawn(_ rep: NSBitmapImageRep, in rect: CGRect, of view: NSView) -> Bool {
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        for y in max(0, Int(rect.minY * scale)) ..< min(rep.pixelsHigh, Int((rect.maxY * scale).rounded(.up))) {
            for x in max(0, Int(rect.minX * scale)) ..< min(rep.pixelsWide, Int((rect.maxX * scale).rounded(.up))) {
                var pixel = [Int](repeating: 0, count: 4)
                rep.getPixel(&pixel, atX: x, y: y)
                if pixel[0 ..< 3].max() ?? 0 > 64 { return true }
            }
        }
        return false
    }

    /// The characters of a note that draw something, each with where it is.
    static func visibleCharacters(_ textView: NSTextView, in h: Harness) -> [(String, Int, CGRect)] {
        let string = textView.string as NSString
        var out: [(String, Int, CGRect)] = []
        for (location, rect) in rects(textView, in: h).enumerated() where rect.width >= 2 {
            let whole = string.rangeOfComposedCharacterSequence(at: location)
            let character = string.substring(with: whole)
            guard whole.location == location, !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            out.append((character, location, rect))
        }
        return out
    }

    /// How two pictures differ, as a sentence, or nothing when they do not.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, of view: NSView) -> String {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return "the pictures are not one size" }
        var differing = 0
        var worst = 0
        var box = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1)
        for y in 0 ..< a.pixelsHigh {
            for x in 0 ..< a.pixelsWide {
                var p = [Int](repeating: 0, count: 4), q = [Int](repeating: 0, count: 4)
                a.getPixel(&p, atX: x, y: y)
                b.getPixel(&q, atX: x, y: y)
                let delta = zip(p, q).map { abs($0 - $1) }.max() ?? 0
                if delta > 0 {
                    differing += 1
                    worst = max(worst, delta)
                    box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
                }
            }
        }
        guard differing > 0 else { return "" }
        let scale = CGFloat(a.pixelsHigh) / view.bounds.height
        return "\(differing) pixels differ, by at most \(worst) of 255, between "
            + "\(CGFloat(box.minX) / scale),\(CGFloat(box.minY) / scale) and \(CGFloat(box.maxX) / scale),\(CGFloat(box.maxY) / scale) points"
    }

    /// Where `measured` falls short of what was written down, as sentences.
    static func differences(_ measured: Measured, from fixture: Measured) -> [String] {
        var out: [String] = []
        func close(_ a: [Double], _ b: [Double]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.01 } }
        if !close(measured.frame, fixture.frame) { out.append("frame \(measured.frame), written down \(fixture.frame)") }
        for (name, a, b) in [("note", measured.rects, fixture.rects), ("find", measured.findRects, fixture.findRects)] {
            if a.count != b.count { out.append("\(name): \(a.count) characters, written down \(b.count)"); continue }
            for (i, (x, y)) in zip(a, b).enumerated() where !close(x, y) {
                out.append("\(name) character \(i): \(x), written down \(y)")
            }
        }
        if measured.faces != fixture.faces { out.append("faces \(measured.faces), written down \(fixture.faces)") }
        if measured.paragraph != fixture.paragraph { out.append("paragraph \(measured.paragraph), written down \(fixture.paragraph)") }
        if measured.ink != fixture.ink { out.append("ink \(measured.ink), written down \(fixture.ink)") }
        // Antialiasing may differ by a little between machines; a missing or
        // misplaced line of text does not.
        if abs(measured.inkArea - fixture.inkArea) > fixture.inkArea * 0.05 {
            out.append("ink drawn over \(measured.inkArea) square points, written down \(fixture.inkArea)")
        }
        return out
    }
}
