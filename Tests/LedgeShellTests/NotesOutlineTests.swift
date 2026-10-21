import AppKit
import Foundation
import LedgeCore
import LedgeSystem
import SwiftUI
import Testing
@testable import LedgeShell

/// The note window keeps its shape whatever its body is showing.
///
/// The window is clear and the view paints the black, so the outline is
/// wherever the view's content ends. Hosted the way `makePanel` hosts it —
/// 360 by 420, `sizingOptions = []` — in a window twenty thousand points off
/// every screen, never key, and photographed without the WindowServer.
@MainActor
@Suite("Notes window outline", .serialized)
struct NotesOutlineTests {

    private func host(_ model: NotesEditorModel) -> (NSWindow, NSHostingView<NotesEditorView>) {
        _ = NSApplication.shared
        let size = CGSize(width: 360, height: 420)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        let hosting = NSHostingView(rootView: NotesEditorView(model: model))
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.orderFrontRegardless()
        return (window, hosting)
    }

    /// Points, at the window's horizontal middle, where nothing is drawn at
    /// the top and at the bottom.
    private func emptyBands(_ hosting: NSView) -> (top: CGFloat, bottom: CGFloat) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return (-1, -1) }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / hosting.bounds.height
        let x = rep.pixelsWide / 2
        func clear(_ y: Int) -> Bool { (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) < 0.05 }
        var top = 0
        while top < rep.pixelsHigh, clear(top) { top += 1 }
        var bottom = 0
        while bottom < rep.pixelsHigh, clear(rep.pixelsHigh - 1 - bottom) { bottom += 1 }
        return (CGFloat(top) / scale, CGFloat(bottom) / scale)
    }

    /// The lowest row, in points, with bright text on it: the key hints.
    private func lowestText(_ hosting: NSView) -> CGFloat {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return -1 }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / hosting.bounds.height
        for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.6, c.greenComponent > 0.6, c.blueComponent > 0.6 { return CGFloat(y) / scale }
            }
        }
        return -1
    }

    private func note() -> NotesEditorModel {
        let model = NotesEditorModel()
        model.load(NoteBody(id: "A", text: AttributedString("Groceries\nMilk"), createdAt: 0, editedAt: 0))
        model.notes = (0 ..< 3).map { NoteSummary(id: "s\($0)", title: "Note \($0)", preview: "", editedAt: 0) }
        return model
    }

    @Test("A search that finds nothing leaves the window its full shape")
    func noMatchKeepsTheShape() {
        let model = note()
        let (window, hosting) = host(model)
        defer { window.close() }
        let resting = emptyBands(hosting)
        #expect(resting.top == 0 && resting.bottom == 0, "the note itself fills the window: \(resting)")

        model.show(.notes)
        model.query = "zzzz"
        // Reached: All Notes is up, and nothing matches.
        #expect(model.overlay == .notes)
        #expect(model.listedNotes.isEmpty)
        let bands = emptyBands(hosting)
        #expect(bands.top == 0 && bands.bottom == 0, "the outline pulled in around the list: \(bands)")
    }

    @Test("The keys keep their line while a search goes from matches to none")
    func hintsStayPut() {
        let model = note()
        let (window, hosting) = host(model)
        defer { window.close() }
        model.show(.notes)
        #expect(model.listedNotes.count == 3)
        let matching = lowestText(hosting)
        model.query = "zzzz"
        #expect(model.listedNotes.isEmpty)
        let nothing = lowestText(hosting)
        #expect(matching > 300, "the hints should sit at the window's foot: \(matching)")
        #expect(abs(matching - nothing) < 1, "the hints moved: \(matching) -> \(nothing)")
    }

    @Test("Commands and All Notes are drawn in the window's own shape")
    func palettesKeepTheShape() {
        let model = note()
        let (window, hosting) = host(model)
        defer { window.close() }
        for overlay in [NotesOverlay.commands, .notes] {
            model.show(overlay)
            #expect(model.overlay == overlay)
            #expect(model.query.isEmpty)
            let bands = emptyBands(hosting)
            #expect(bands.top == 0 && bands.bottom == 0, "\(overlay) shrank the window: \(bands)")
            model.dismissOverlay()
        }
    }
}
