import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// A producer's chosen colour, the feed's level and a bare ring's fraction,
/// and which of them wins.
@Suite("Feed colours: who wins")
struct FeedColourRulesTests {

    // MARK: Chosen colours against the level

    @Test("Critical is red whatever colour was chosen")
    func criticalBeatsChosen() {
        #expect(FeedEar.tint(fixed: "#4F8EF7", level: .critical, otherwise: .white) == .red)
    }

    @Test("Below critical the chosen colour stands")
    func chosenStands() {
        let blue = FeedEar.color(hex: "#4F8EF7")
        #expect(blue != nil)
        #expect(FeedEar.tint(fixed: "#4F8EF7", level: .warning, otherwise: .orange) == blue)
        #expect(FeedEar.tint(fixed: "#4F8EF7", level: .normal, otherwise: .white) == blue)
    }

    @Test("With no colour chosen, what the caller would draw")
    func noChoice() {
        #expect(FeedEar.tint(fixed: nil, level: .warning, otherwise: .orange) == .orange)
    }

    // MARK: A ring with no words

    @Test("The level can only make a bare ring worse")
    func levelMakesItWorse() {
        #expect(FeedEar.bareRingTint(forFraction: 0.9, level: .normal) == .green)
        #expect(FeedEar.bareRingTint(forFraction: 0.9, level: .warning) == .orange)
        #expect(FeedEar.bareRingTint(forFraction: 0.9, level: .critical) == .red)
        #expect(FeedEar.bareRingTint(forFraction: 0.1, level: .warning) == .red, "never better than its fraction")
    }

    @Test("A chosen colour stands in for the fraction's, but not for critical")
    func bareChosen() {
        #expect(FeedEar.bareRingTint(forFraction: 0.1, level: .normal, fixed: "#4F8EF7") == FeedEar.color(hex: "#4F8EF7"))
        #expect(FeedEar.bareRingTint(forFraction: 0.9, level: .critical, fixed: "#4F8EF7") == .red)
    }

    // MARK: Colours too dark for the notch

    private func luminance(_ c: (Double, Double, Double)) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.0) + 0.7152 * linear(c.1) + 0.0722 * linear(c.2)
    }

    @Test("A colour too dark to see is lifted to 3:1 against black", arguments: [
        (0.0, 0.0, 0.0), (0x11 / 255.0, 0x11 / 255.0, 0x11 / 255.0), (0.0, 0.0, 1.0), (0.3, 0.0, 0.0),
    ])
    func darkIsLifted(colour: (Double, Double, Double)) {
        let lifted = FeedEar.readableOnBlack(red: colour.0, green: colour.1, blue: colour.2)
        #expect((luminance(lifted) + 0.05) / 0.05 >= 2.99)
        #expect(luminance(lifted) < 0.11, "lifted just enough, not washed out")
    }

    @Test("A dark blue stays blue")
    func hueKept() {
        let (red, green, blue) = FeedEar.readableOnBlack(red: 0, green: 0, blue: 0.5)
        #expect(blue > red && blue > green)
    }

    @Test("A chosen colour too dark to see is lifted on its way to the screen")
    func chosenDarkIsLifted() throws {
        // Through the conversion every view uses, not just the helper.
        let colour = try #require(FeedEar.color(hex: "#111111"))
        let srgb = try #require(NSColor(colour).usingColorSpace(.sRGB))
        let lifted = (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
        #expect((luminance(lifted) + 0.05) / 0.05 >= 2.99)
    }

    @Test("A colour that can already be seen comes back unchanged")
    func brightUnchanged() {
        let blue = (0x4F / 255.0, 0x8E / 255.0, 0xF7 / 255.0)
        let back = FeedEar.readableOnBlack(red: blue.0, green: blue.1, blue: blue.2)
        #expect(back == blue)
    }
}

/// The rules above, where they are drawn. Each part of a feed is rendered
/// offscreen with a blue chosen, and the painted pixels say which colour won:
/// the rules could pass while a view went on reading the colour directly.
@Suite("Feed colours: where they are drawn")
@MainActor
struct FeedColourDrawnTests {

    private static let blue = "#2F80ED"

    /// How many painted pixels lean red, blue or green.
    private struct Paint { var red = 0, blue = 0, green = 0 }

    private func paint(_ view: some View, width: CGFloat, height: CGFloat) throws -> Paint {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height).background(Color.black))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        // Redrawn into a known byte order, so red is always the first byte.
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var paint = Paint()
        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = y * context.bytesPerRow + x * 4
                let r = Int(data[pixel]), g = Int(data[pixel + 1]), b = Int(data[pixel + 2])
                if b > r + 80, b > g + 30 { paint.blue += 1 }
                if r > b + 80, r > g + 50 { paint.red += 1 }
                if g > r + 60, g > b + 40 { paint.green += 1 }
            }
        }
        return paint
    }

    private func ear(_ level: FeedLevel, text: String? = nil, fraction: Double? = nil) -> FeedEar {
        FeedEar(payload: FeedPayload(title: "Build", compactTrailing: text, compactTrailingFraction: fraction,
                                     compactTrailingColor: Self.blue, level: level),
                side: .trailing)
    }

    @Test("A gauge shows its colour, and red once critical")
    func gauge() throws {
        let calm = try paint(FeedGaugeView(gauge: FeedGauge(label: "A", value: "1", fraction: 0.8, color: Self.blue)),
                             width: 60, height: 70)
        #expect(calm.blue > 50 && calm.red < 5)
        let critical = try paint(FeedGaugeView(gauge: FeedGauge(label: "A", value: "1", fraction: 0.8,
                                                                level: .critical, color: Self.blue)),
                                 width: 60, height: 70)
        #expect(critical.red > 50 && critical.blue < 5)
    }

    @Test("Words beside the notch show their colour, and red once critical")
    func words() throws {
        let calm = try paint(ear(.normal, text: "FAILED"), width: 60, height: 32)
        #expect(calm.blue > 20 && calm.red < 5)
        let critical = try paint(ear(.critical, text: "FAILED"), width: 60, height: 32)
        #expect(critical.red > 20 && critical.blue < 5)
    }

    @Test("A ring with words shows its colour, and red once critical")
    func ringWithWords() throws {
        let calm = try paint(ear(.normal, text: "91", fraction: 0.8), width: 40, height: 38)
        #expect(calm.blue > 50 && calm.red < 5)
        let critical = try paint(ear(.critical, text: "91", fraction: 0.8), width: 40, height: 38)
        #expect(critical.red > 50 && critical.blue < 5)
    }

    @Test("A bare ring shows its colour instead of the fraction's, and red once critical")
    func bareRing() throws {
        let calm = try paint(ear(.normal, fraction: 0.9), width: 30, height: 30)
        #expect(calm.blue > 50 && calm.green < 5)
        let critical = try paint(ear(.critical, fraction: 0.9), width: 30, height: 30)
        #expect(critical.red > 50 && critical.blue < 5)
    }
}
