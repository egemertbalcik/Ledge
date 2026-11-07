import AppKit
import CoreGraphics
import Testing

@testable import LedgeUI

/// How big the ring in a feed's ear is, and whether its digits fit.
@Suite("Feed ear sizing")
@MainActor
struct FeedEarSizingTests {

    /// The ear is the notch's own height: 32 on an Air, 38 on a Pro, and half
    /// a point more for the shape's rim.
    private static let heights: [CGFloat] = [32.5, 38.5]

    @Test("The ring stands off the shape's edge above and below")
    func ringFitsTheEar() {
        for height in Self.heights {
            let diameter = FeedEar.diameter(forHeight: height)
            #expect(diameter <= height - 5, "a ring of \(diameter) touches an ear of \(height)")
            #expect(diameter >= 24, "a ring of \(diameter) is too small to hold digits")
        }
    }

    @Test("A bigger ear gets a bigger ring, within limits")
    func ringFollowsTheEar() {
        #expect(FeedEar.diameter(forHeight: 38.5) > FeedEar.diameter(forHeight: 32.5))
        #expect(FeedEar.diameter(forHeight: 10) == 20)
        #expect(FeedEar.diameter(forHeight: 400) == 34)
        #expect(FeedEar.diameter(forHeight: .nan) > 0)
        #expect(FeedEar.diameter(forHeight: 0) > 0)
    }

    @Test("The digits are never smaller than 8pt, or larger than 10")
    func digitSize() {
        for height in Self.heights + [0, 20, 400] {
            let size = FeedEar.fontSize(forDiameter: FeedEar.diameter(forHeight: height))
            #expect(size >= 8 && size <= 10)
        }
    }

    /// The width of a string in the face the ring sets it in, as AppKit
    /// measures it: semibold, condensed, with the digits all one width.
    private func width(of text: String, size: CGFloat) -> CGFloat {
        var font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let condensed = font.fontDescriptor.addingAttributes([
            .traits: [NSFontDescriptor.TraitKey.width: -0.2, NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue],
        ])
        font = NSFont(descriptor: condensed, size: size) ?? font
        let tabular = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        font = NSFont(descriptor: tabular, size: size) ?? font
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The size a string is set at in a ring: its own size, or the smaller one
    /// it shrinks to when it does not fit.
    private func effectiveSize(of text: String, height: CGFloat) -> CGFloat {
        let diameter = FeedEar.diameter(forHeight: height)
        let size = FeedEar.fontSize(forDiameter: diameter)
        let scale = min(1, FeedEar.textWidth(forDiameter: diameter) / width(of: text, size: size))
        return size * scale
    }

    @Test("Four characters stay legible in the ring", arguments: ["%100", "100%", "%35", "35%", "%0"])
    func fourCharactersAreLegible(text: String) {
        for height in Self.heights {
            let size = effectiveSize(of: text, height: height)
            #expect(size >= 7.5, "\(text) would be set at \(size)pt in an ear of \(height)")
        }
    }

    @Test("Five characters shrink further, but not below 6.5pt")
    func fiveCharactersShrinkAFairWay() {
        for height in Self.heights {
            let size = effectiveSize(of: "~100%", height: height)
            #expect(size >= 6.5, "~100% would be set at \(size)pt in an ear of \(height)")
        }
    }
}
