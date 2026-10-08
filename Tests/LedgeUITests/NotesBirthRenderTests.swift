import LedgeCore
import SwiftUI
import Testing
@testable import LedgeUI

/// The note leaving the island actually draws something.
///
/// Written because the animation shipped once with its hook wired inside a
/// closure that never ran, and the only way that was noticed was a person
/// looking at the notch and seeing nothing. A render test cannot tell whether
/// it looks good, but it can tell whether any pixels arrive at all.
@Suite("A note being born")
@MainActor
struct NotesBirthRenderTests {

    /// How many pixels the blob covers at a given progress.
    private func litPixels(progress: Double) -> Int {
        // The clock is wound back, so the view really is at `progress`.
        // Without this every call measured the first frame, which is how a
        // test named for the animation managed to say nothing about it.
        let view = NotesBirthView(
            birth: NotesBirth(
                to: CGRect(x: 600, y: 40, width: 360, height: 300),
                token: 1,
                startedAt: Date(timeIntervalSinceNow: -progress * NotesBirth.duration)
            ),
            islandRect: CGRect(x: 100, y: 0, width: 280, height: 200),
            tint: .white,
            fixedProgress: progress
        )
        .frame(width: 1000, height: 500)
        .background(.black)

        let renderer = ImageRenderer(content: AnyView(view))
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return 0 }

        var lit = 0
        // Sampled on a grid rather than per pixel: this is asking "is anything
        // drawn", not measuring a shape.
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                if colour.brightnessComponent > 0.4 { lit += 1 }
            }
        }
        return lit
    }

    @Test("The blob is drawn at every stage, not nothing")
    func drawsSomething() {
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            #expect(litPixels(progress: progress) > 0,
                    "nothing was drawn at progress \(progress)")
        }
    }

    /// It has to grow. A blob that is the same size the whole way is a shape
    /// being moved, not a piece being drawn out.
    @Test("It covers more ground as it goes")
    func growsOverTime() {
        let early = litPixels(progress: 0.2)
        let late = litPixels(progress: 0.9)
        #expect(late > early * 2, "it barely grew: \(early) then \(late)")
    }

    /// The whole effect is that the thing separates. If the blob never leaves
    /// the island's corner there is nothing to watch.
    @Test("The blob travels away from the island")
    func itMoves() {
        let start = NotesBirthView(
            birth: NotesBirth(to: CGRect(x: 600, y: 40, width: 360, height: 300), token: 1),
            islandRect: CGRect(x: 100, y: 0, width: 280, height: 200),
            tint: .white
        )
        // The geometry is pure, so it can be checked without rendering.
        #expect(start.rectForTesting(progress: 0).midX < 400, "it does not start at the island")
        #expect(start.rectForTesting(progress: 1).midX > 700, "it never reaches the window")
    }

    @Test("It grows from a bubble into the window's shape")
    func itGrows() {
        let view = NotesBirthView(
            birth: NotesBirth(to: CGRect(x: 600, y: 40, width: 360, height: 300), token: 1),
            islandRect: CGRect(x: 100, y: 0, width: 280, height: 200),
            tint: .white
        )
        let small = view.rectForTesting(progress: 0)
        let large = view.rectForTesting(progress: 1)
        #expect(small.width < 40, "it does not start small")
        #expect(large.width > 300, "it does not end at the window's size")
    }
}

/// The flight's shape over time, checked as geometry rather than by eye.
@Suite("The flight's shape")
@MainActor
struct NotesBirthShapeTests {

    private let landing = CGRect(x: 1086, y: 49, width: 360, height: 420)

    private func view() -> NotesBirthView {
        NotesBirthView(
            birth: NotesBirth(to: landing, cornerRadius: 14, token: 1),
            islandRect: CGRect(x: 597, y: 0, width: 275, height: 220),
            tint: .black
        )
    }

    /// It must land on the window exactly. A blob that stops a few points short
    /// — or proud — shows a seam at the moment the window takes over.
    @Test("It lands exactly on the window")
    func landsExactly() {
        let final = view().rectForTesting(progress: 1)
        #expect(abs(final.minX - landing.minX) < 0.5)
        #expect(abs(final.minY - landing.minY) < 0.5)
        #expect(abs(final.width - landing.width) < 0.5)
        #expect(abs(final.height - landing.height) < 0.5)
    }

    /// And as the window's own shape, not merely its rectangle.
    @Test("It ends at the window's corner radius")
    func endsAtWindowRadius() {
        #expect(abs(view().radiusForTesting(progress: 1) - 14) < 0.5)
    }

    /// Round while it is leaving: that is what makes it a bubble rather than a
    /// rectangle sliding.
    @Test("It starts round")
    func startsRound() {
        let v = view()
        let early = v.rectForTesting(progress: 0.1)
        let radius = v.radiusForTesting(progress: 0.1)
        #expect(abs(radius - min(early.width, early.height) / 2) < 1.0, "it is not a circle on the way out")
    }

    /// It has to gather at the corner before it goes, or the three beats read
    /// as one slide.
    @Test("It gathers at the corner before travelling")
    func gathersFirst() {
        let v = view()
        let origin = v.rectForTesting(progress: 0).midX
        let atTenth = v.rectForTesting(progress: 0.1).midX
        let atHalf = v.rectForTesting(progress: 0.5).midX
        let earlyTravel = atTenth - origin
        let midTravel = atHalf - origin
        #expect(earlyTravel < midTravel * 0.12, "it leaves immediately instead of gathering")
    }

    /// Travel grows monotonically until the deliberate settling overshoot.
    @Test("It does not reverse before settling")
    func monotonic() {
        let v = view()
        var lastX = -Double.infinity
        var lastWidth = -Double.infinity
        for step in 0...24 {
            let r = v.rectForTesting(progress: Double(step) / 40)
            #expect(r.midX >= lastX - 0.01, "it moved backwards at \(Double(step) / 40)")
            #expect(r.width >= lastWidth - 0.01, "it shrank at \(Double(step) / 40)")
            #expect(r.width.isFinite && r.height.isFinite, "a non-finite rect")
            lastX = r.midX
            lastWidth = r.width
        }
    }

    /// Reduce Motion is handled in the shell by not flying at all, but the view
    /// must still be sane if it is asked to draw at the end.
    @Test("Every progress in range produces a drawable rect")
    func alwaysDrawable() {
        let v = view()
        for step in -5...45 {
            let r = v.rectForTesting(progress: Double(step) / 40)
            #expect(r.width > 0 && r.height > 0)
            #expect(r.width.isFinite && r.height.isFinite)
        }
    }
}

/// Offscreen captures of the actual overlay, including its production clip.
/// This catches a sag that the shape draws but the container cuts away.
@Suite("Notes birth production pixels")
@MainActor
struct NotesBirthProductionRenderTests {
    private func rendered(progress: Double, scale: CGFloat = 1, display: UInt32 = 7) throws -> NSBitmapImageRep {
        let geometry = NotchGeometry(screenSize: CGSize(width: 1000, height: 900),
                                     notchSize: CGSize(width: 179, height: 32), notchCenterX: 500,
                                     isHardwareNotch: true, displayScale: scale)
        let preferences = Preferences(store: MemoryPreferenceStore())
        let presentation = NotchPresentation()
        let layout = NotchLayout(bodySize: CGSize(width: 280 * scale, height: 220 * scale),
                                 bottomRadius: 22 * scale, gutterRadius: 11 * scale)
        let island = CGRect(x: (1000 - layout.bodySize.width) / 2, y: 0,
                            width: layout.bodySize.width, height: layout.bodySize.height)
        let start = Date(timeIntervalSince1970: 1000)
        presentation.fixedNow = start.addingTimeInterval(progress * NotesBirth.duration)
        presentation.notesBirth = NotesBirth(to: CGRect(x: island.midX + 24 * scale, y: island.maxY + 16 * scale,
                                                       width: 360, height: 420), token: 1, startedAt: start,
                                             displayScale: scale, displayID: 7, islandRect: island, sourceLayout: layout)
        presentation.phase = .expanded
        presentation.selected = Activity(id: ActivityID(kind: .notes, source: "test"), createdAt: 0,
                                         payload: .notes(NotesPayload(notes: [])))
        let renderer = ImageRenderer(content: NotchOverlayView(geometry: geometry, preferences: preferences,
                                                               presentation: presentation, displayID: display)
            .frame(width: 1000, height: 780).background(.white))
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff))
    }

    @Test("The sag escapes the resting clip and only appears on its source display")
    func sagVisible() throws {
        let image = try rendered(progress: 0.3)
        let other = try rendered(progress: 0.3, display: 8)
        // Point inside the silhouette's lobe, outside the old 220pt clip.
        let lip = NotesBirthGeometry.lip(in: CGRect(x: 360, y: 0, width: 280, height: 220), at: 0.3, scale: 1)
        #expect(try #require(image.colorAt(x: Int(lip.x), y: Int(lip.y))).brightnessComponent < 0.1)
        #expect(try #require(other.colorAt(x: Int(lip.x), y: Int(lip.y))).brightnessComponent > 0.9)
    }

    @Test("Export deterministic production filmstrip", .enabled(if: ProcessInfo.processInfo.environment["LEDGE_BIRTH_SHEET"] == "1"))
    func filmstrip() throws {
        let progress = [0.0, 0.18, 0.40, 0.62, 0.76, 0.86, 1.0]
        var rows: [[NSImage]] = []
        for scale: CGFloat in [1, 1.2] {
            rows.append(try progress.map { t in
                let bitmap = try rendered(progress: t, scale: scale)
                let image = NSImage(size: CGSize(width: 1000, height: 780))
                image.addRepresentation(bitmap)
                return image
            })
        }
        let sheet = VStack(spacing: 12) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(rows[row].indices, id: \.self) { col in
                        VStack {
                            Image(nsImage: rows[row][col]).resizable().frame(width: 300, height: 234)
                            Text("\(row == 0 ? "1.00" : "1.20") · \(progress[col], specifier: "%.2f")")
                                .font(.system(size: 12)).foregroundStyle(.black)
                        }
                    }
                }
            }
        }.padding(12).background(.white)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/ledge-notes-birth-filmstrip.png"))
    }
}

@Suite("Liquid contour continuity")
@MainActor
struct NotesBirthContourTests {
    @Test("A tiny sag does not switch to a different corner")
    func smallSag() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 220)
        let resting = LedgeShape(bottomRadius: 22, gutterRadius: 11).path(in: rect)
        let tiny = LedgeShape(bottomRadius: 22, gutterRadius: 11, cornerSag: 0.501).path(in: rect)
        // Compare the actual contour, not just its bounding box.
        var different = 0
        for x in stride(from: 250.0, through: 305.0, by: 0.5) {
            for y in stride(from: 180.0, through: 230.0, by: 0.5) {
                if resting.contains(CGPoint(x: x, y: y)) != tiny.contains(CGPoint(x: x, y: y)) { different += 1 }
            }
        }
        #expect(different < 12, "the corner popped across \(different) sample points")
    }

    @Test("The neck is a column with a waist, not a thread")
    func waist() {
        let island = CGRect(x: 100, y: 0, width: 280, height: 220)
        let view = NotesBirthView(birth: NotesBirth(to: CGRect(x: 400, y: 260, width: 360, height: 420), token: 1),
                                  islandRect: island, tint: .black)
        let t = 0.40
        let blob = view.rectForTesting(progress: t)
        let lip = NotesBirthGeometry.lip(in: island, at: t, scale: 1)
        let dx = blob.midX - lip.x, dy = blob.midY - lip.y
        let length = hypot(dx, dy)
        let px = -dy / length, py = dx / length
        let neck = try? #require(view.neck(at: t, blob: blob))

        /// How far the band reaches either side of its centre line at `u`.
        func halfWidth(at u: CGFloat) -> CGFloat {
            let centre = CGPoint(x: lip.x + dx * u, y: lip.y + dy * u)
            var reach: CGFloat = 0
            for step in stride(from: CGFloat(0.5), through: 80, by: 0.5) {
                let probe = CGPoint(x: centre.x + px * step, y: centre.y + py * step)
                if neck?.contains(probe) == true { reach = step } else { break }
            }
            return reach
        }

        let atWaist = halfWidth(at: 0.5)
        let atIslandEnd = halfWidth(at: 0.12)
        let atBlobEnd = halfWidth(at: 0.88)

        // Joined, and wide enough to read as the card's own substance rather
        // than a string drawn between two objects — this was capped at a
        // seventeen-point half-width and looked like an appendage.
        #expect(atWaist > 6, "the connection is a thread, not a column: \(atWaist)pt")
        // And genuinely pinched: a waist is only a waist if it is the narrowest
        // part of the span.
        #expect(atWaist < atIslandEnd, "no waist — it is a bar")
        #expect(atWaist < atBlobEnd, "no waist — it is a bar")
        // Gone by the time it is meant to have parted.
        #expect(!view.hasNeckForTesting(progress: NotesBirthGeometry.snap))
    }
}
