import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// What the levels card draws, and what it refuses to claim.
@Suite("The levels card")
@MainActor
struct LevelsCardTests {

    private func rows(volume: Double? = 0.55, muted: Bool = false,
                      external: Bool = false, note: LevelRow.Note? = nil,
                      brightness: Double? = 0.8) -> [LevelRow] {
        var rows: [LevelRow] = []
        if let volume {
            rows.append(LevelRow(id: "sound", kind: .sound, name: "MacBook Pro Speakers",
                                 control: .level(volume), isMuted: muted,
                                 canMute: true, note: note))
        } else {
            rows.append(LevelRow(id: "sound", kind: .sound, name: "LG HDR 4K",
                                 control: .fixed, note: .fixedElsewhere))
        }
        if let brightness {
            rows.append(LevelRow(id: "display-1", kind: .display, name: "Built-in Display",
                                 control: .level(brightness)))
        } else {
            rows.append(LevelRow(id: "display-1", kind: .display, name: "Built-in Display",
                                 control: .unreadable, note: .unreadable))
        }
        if external {
            rows.append(LevelRow(id: "display-2", kind: .display, name: "Dell U2723QE",
                                 control: .level(0.6), floor: 0.18,
                                 note: .gamma(floor: 0.18)))
        }
        return rows
    }

    /// The card's own source. Two of the rules here are about things that
    /// change no layout and so cannot be seen in a render.
    static var cardSource: String {
        (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/LedgeUI/Cards/LevelsCardView.swift"),
            encoding: .utf8
        )) ?? ""
    }

    private func drawn(_ rows: [LevelRow], width: CGFloat = 275) -> CGSize? {
        let renderer = ImageRenderer(content: LevelsCardView(rows: rows).frame(width: width))
        renderer.scale = 2
        return renderer.nsImage?.size
    }

    @Test("Every face draws at the widths the island gives it")
    func drawsEverywhere() {
        let faces: [[LevelRow]] = [
            rows(),
            rows(muted: true),
            rows(volume: 0),
            rows(external: true),
            rows(note: .refused),
            rows(volume: nil, brightness: nil),
            // The worst case: three displays, a refusal and a floor sentence.
            rows(external: true, note: .partial) + [
                LevelRow(id: "display-3", kind: .display, name: "LG HDR 4K",
                         control: .level(0.74), floor: 0.18)
            ]
        ]
        for face in faces {
            for width in [231, 260, 275, 283, 320] as [CGFloat] {
                guard let size = drawn(face, width: width) else {
                    Issue.record("a face would not draw at \(width)")
                    continue
                }
                #expect(size.height > 0)
                #expect(size.height <= 300 * 2, "the card must stay under the 300pt cap")
            }
        }
    }

    @Test("A sentence makes the card taller rather than being clipped")
    func sentencesTakeRoom() {
        // The card had a fixed 160pt height. Four rows and an explanation ran
        // through the page dots and off the bottom, which is the one thing the
        // island's own shape cannot show you is happening.
        guard let plain = drawn(rows()), let explained = drawn(rows(external: true))
        else { Issue.record("both must draw"); return }
        #expect(explained.height > plain.height,
                "a row's sentence has to cost height or it is being clipped")
    }

    /// The card drawn into plain RGBA bytes, one array per row of pixels, top
    /// first, so two pictures can be compared pixel by pixel. A render cannot
    /// hover, so the touched row is seeded.
    private func pixels(_ rows: [LevelRow], touched: String? = nil) -> [[UInt8]]? {
        let renderer = ImageRenderer(
            content: LevelsCardView(rows: rows, touched: touched).frame(width: 275)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return (0..<height).map { Array(bytes[($0 * width * 4)..<(($0 + 1) * width * 4)]) }
    }

    /// The first and last rows of pixels where two pictures differ.
    private func changedRows(_ a: [[UInt8]], _ b: [[UInt8]]) -> ClosedRange<Int>? {
        let changed = a.indices.filter { a[$0] != b[$0] }
        guard let first = changed.first, let last = changed.last else { return nil }
        return first...last
    }

    @Test("A card nobody is touching has nothing picked out")
    func atRestNothingIsDimmed() throws {
        // The row being touched is picked out, which is right under a
        // pointer and wrong on a card at rest. `.focusable()` on the rows
        // made something take focus the instant the card was drawn, so every
        // photograph showed one row picked out for no reason.
        let resting = try #require(pixels(rows(external: true)))
        // Drawn twice: identical, because nothing in the card itself decides
        // to highlight a row.
        #expect(pixels(rows(external: true)) == resting)
        // A touch on a row that is not there picks nothing out either.
        #expect(pixels(rows(external: true), touched: "no-such-row") == resting)
    }

    @Test("Touching a row adds to that row and takes nothing from the others",
          arguments: ["sound", "display-1", "display-2"])
    func touchingOneRowLeavesTheOthers(touched: String) throws {
        // Hovering the sound row faded brightness to 38%, and the other way
        // round. On a two-row card that read as half the card switching off.
        // The touched row lifts instead, so the picture changes, and no pixel
        // anywhere gets fainter than it was at rest.
        let resting = try #require(pixels(rows(external: true)))
        let lifted = try #require(pixels(rows(external: true), touched: touched))
        try #require(lifted.count == resting.count, "touching a row changed the card's height")
        #expect(lifted != resting, "touching \(touched) changed nothing on the card")

        var fainter = 0
        for (restRow, liftedRow) in zip(resting, lifted) {
            // Every fourth byte is a pixel's alpha. One step of rounding at an
            // antialiased edge is not a fade.
            for alpha in stride(from: 3, to: restRow.count, by: 4)
            where Int(liftedRow[alpha]) < Int(restRow[alpha]) - 2 {
                fainter += 1
            }
        }
        #expect(fainter == 0, "touching \(touched) made \(fainter) pixels fainter")
    }

    /// The highest alpha in a band of pixel rows: 255 wherever the line, which
    /// is solid white, is drawn at full strength.
    private func strongest(_ picture: [[UInt8]], in band: ClosedRange<Int>) -> UInt8 {
        band.flatMap { y in stride(from: 3, to: picture[y].count, by: 4).map { picture[y][$0] } }.max() ?? 0
    }

    /// How many pixels in a band are opaque or nearly. The plate is faint and
    /// adds none; a thicker line adds a row of them.
    private func opaque(_ picture: [[UInt8]], in band: ClosedRange<Int>) -> Int {
        band.reduce(0) { count, y in
            count + stride(from: 3, to: picture[y].count, by: 4).filter { picture[y][$0] >= 250 }.count
        }
    }

    @Test("At rest every row is drawn at full strength, and a touched row's line is thicker",
          arguments: ["sound", "display-1", "display-2"])
    func restingRowsAreFullStrength(touched: String) throws {
        let resting = try #require(pixels(rows(external: true)))
        let lifted = try #require(pixels(rows(external: true), touched: touched))
        let band = try #require(changedRows(resting, lifted), "touching \(touched) changed nothing")
        // Nothing faded at rest: the row's own line is solid white.
        #expect(strongest(resting, in: band) >= 250, "\(touched) is faded at rest")
        #expect(opaque(lifted, in: band) > opaque(resting, in: band),
                "touching \(touched) did not thicken its line")
    }

    @Test("Moving from one row straight onto the next keeps the new row lifted, in either order")
    func hoverHandOff() {
        // The new row's entry first, then the old row's exit.
        var held = LevelsCardView.hovering(nil, row: "sound", inside: true)
        held = LevelsCardView.hovering(held, row: "display-1", inside: true)
        held = LevelsCardView.hovering(held, row: "sound", inside: false)
        #expect(held == "display-1")
        // The usual order: exit, then entry.
        held = LevelsCardView.hovering(held, row: "display-1", inside: false)
        #expect(held == nil)
        held = LevelsCardView.hovering(held, row: "display-2", inside: true)
        #expect(held == "display-2")
        // Leaving the card from the row that holds it clears it.
        #expect(LevelsCardView.hovering("display-2", row: "display-2", inside: false) == nil)
    }

    @Test("Only the touched row changes")
    func theChangeStaysInItsRow() throws {
        let resting = try #require(pixels(rows(external: true)))
        let soundLifted = try #require(pixels(rows(external: true), touched: "sound"))
        let externalLifted = try #require(pixels(rows(external: true), touched: "display-2"))
        let sound = try #require(changedRows(resting, soundLifted))
        let external = try #require(changedRows(resting, externalLifted))
        // The first row and the last: what changes for one never reaches the
        // other, which a fade on every untouched row would.
        #expect(sound.upperBound < external.lowerBound)
    }

    @Test("Every row's line is the same thickness, floor or no floor")
    func oneThicknessForEveryRow() {
        // The tick marking an external display's floor was 7pt tall inside a
        // 3pt line, so it stuck out above and below and that one row read as a
        // thicker bar than the others. The owner noticed it straight away, and
        // a difference in weight that says nothing is worse than no mark.
        //
        // Checked in the source, because an overflowing tick changes no
        // layout: the card renders at exactly the same height either way, so
        // the first version of this test — comparing rendered heights — passed
        // with the bug restored.
        let source = Self.cardSource
        #expect(!source.contains("height: 7"),
                "something in a 3pt line is taller than the line")
        #expect(source.contains("frame(width: 1, height: Self.lineThickness)"),
                "the floor tick is not pinned to the line's own thickness")
        // And the drawn heights still match, which is the other half.
        guard let plain = drawn([
            LevelRow(id: "d", kind: .display, name: "Built-in Display", control: .level(0.8))
        ]),
        let floored = drawn([
            LevelRow(id: "d", kind: .display, name: "Dell U2723QE",
                     control: .level(0.6), floor: 0.18)
        ])
        else { Issue.record("both must draw"); return }
        #expect(plain.height == floored.height)
    }

    @Test("The card draws what the provider published, not what it opened with")
    func theCardFollowsThePayload() {
        // The card pulls its rows, and *when* to pull is a question only the
        // provider can answer: a volume key changes the level without anything
        // on the card being touched. With nothing watching, an open card went
        // on showing the number from the moment it opened — which is what the
        // owner saw.
        //
        // Drawn, because that is the half a render can prove: the same card
        // with two different published payloads is two different pictures.
        let quiet = LevelsPayload(volume: 0.1, brightness: 0.8,
                                  rows: rows(volume: 0.1))
        let loud = LevelsPayload(volume: 0.9, brightness: 0.8,
                                 rows: rows(volume: 0.9))
        func picture(_ payload: LevelsPayload) -> Data? {
            let renderer = ImageRenderer(
                content: LevelsCardView(payload: payload).frame(width: 275)
            )
            renderer.scale = 1
            return renderer.nsImage?.tiffRepresentation
        }
        #expect(picture(quiet) != picture(loud),
                "the card drew the same thing for two different published levels")
    }

    @Test("The card is wired to every level the provider can publish")
    func everyPublishedFactIsWatched() {
        // `ImageRenderer` does not mount a view, so no render can prove the
        // card *asked*. What can be checked is that it is watching all three
        // of the things the provider publishes — a volume key, a brightness
        // key and the mute key each move exactly one of them, and watching two
        // out of three is a card that goes stale on the third.
        let source = Self.cardSource
        for fact in ["payload.volume", "payload.brightness", "payload.isMuted"] {
            #expect(source.contains("onChange(of: \(fact))"),
                    "nothing re-reads the hardware when \(fact) moves")
        }
        // The rows now travel with the payload, so this is the refresh for a
        // card that is already open rather than the thing that fills it.
        #expect(source.contains(".task {") && source.contains("pull()"),
                "nothing re-reads the hardware while the card is open")
    }

    @Test("A row with no line still takes its place")
    func noLineStillHasARow() {
        // A fixed-volume output and an unreadable panel keep their rows, so
        // the card keeps its shape and each can say why. Dropping them would
        // make a Mac with an HDMI output look like a Mac with no sound.
        guard let full = drawn(rows()),
              let nothing = drawn(rows(volume: nil, brightness: nil))
        else { Issue.record("both must draw"); return }
        #expect(nothing.height >= full.height,
                "the rows that cannot be dragged were dropped rather than explained")
    }
}

/// What happens in the frame after a card opens.
///
/// Both of the card redesigns landed with the same complaint: the card arrives,
/// settles, and then moves again. The island opens at the estimate, so the
/// estimate has to be right (`CardOpeningTests`); where it is not, the card's
/// first measurement joins the opening spring rather than being applied around
/// it (`IslandTransitionTests`, which films that).
@Suite("A card arriving")
@MainActor
struct CardArrivalTests {

    private let levels = ActivityID(kind: .levels, source: "levels")

    @Test("A card's first measurement is kept, and later ones are still followed")
    func theFirstMeasurementIsKept() {
        let presentation = NotchPresentation()
        #expect(!presentation.hasMeasured(levels))

        // The first report is the one where nothing is known yet, and every
        // later one is a change to something already on screen.
        presentation.reportCardContent(height: 150, from: levels)
        #expect(presentation.hasMeasured(levels))
        #expect(presentation.cardContentHeight(for: levels) == 150)

        presentation.reportCardContent(height: 182, from: levels)
        #expect(presentation.cardContentHeight(for: levels) == 182,
                "a card that grows while somebody is looking at it must still be followed")
    }

    @Test("A card that comes back is already known, so it opens at the right size")
    func aReturningCardDoesNotJump() {
        // The measurement outlives the card being closed, which is why only
        // the very first open could ever have jumped.
        let presentation = NotchPresentation()
        presentation.reportCardContent(height: 150, from: levels)
        #expect(presentation.cardContentHeight(for: levels) == 150)
        #expect(presentation.hasMeasured(levels))
    }

    @Test("Nothing is recorded for a measurement that means nothing")
    func nonsenseIsIgnored() {
        let presentation = NotchPresentation()
        presentation.reportCardContent(height: 0, from: levels)
        presentation.reportCardContent(height: .infinity, from: levels)
        presentation.reportCardContent(height: -5, from: levels)
        #expect(!presentation.hasMeasured(levels))
    }
}
