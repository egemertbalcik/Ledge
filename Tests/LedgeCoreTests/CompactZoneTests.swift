import CoreGraphics
import Foundation
import Testing

@testable import LedgeCore

@Suite("Compact zones")
struct CompactZoneTests {

    /// A 306pt resting island centred on x=500, with a 200pt cutout: ears run
    /// 347...400 and 600...653.
    private let rect = CGRect(x: 347, y: 0, width: 306, height: 32)
    private let cutout: CGFloat = 200

    @Test("The leading ear, the cutout and the trailing ear zone correctly")
    func zones() {
        #expect(NotchLayout.compactZone(x: 360, restingRect: rect, cutoutWidth: cutout) == .leading)
        #expect(NotchLayout.compactZone(x: 500, restingRect: rect, cutoutWidth: cutout) == .cutout)
        #expect(NotchLayout.compactZone(x: 620, restingRect: rect, cutoutWidth: cutout) == .trailing)
    }

    @Test("The cutout edges belong to the cutout — the main card's zone")
    func edgesAreNeutral() {
        #expect(NotchLayout.compactZone(x: 400, restingRect: rect, cutoutWidth: cutout) == .cutout)
        #expect(NotchLayout.compactZone(x: 600, restingRect: rect, cutoutWidth: cutout) == .cutout)
    }

    @Test("Points just past the cutout edge reach the ears")
    func justPastEdges() {
        #expect(NotchLayout.compactZone(x: 399.5, restingRect: rect, cutoutWidth: cutout) == .leading)
        #expect(NotchLayout.compactZone(x: 600.5, restingRect: rect, cutoutWidth: cutout) == .trailing)
    }

    @Test("Non-finite input answers the neutral zone, never traps")
    func nonFinite() {
        #expect(NotchLayout.compactZone(x: .nan, restingRect: rect, cutoutWidth: cutout) == .cutout)
        #expect(NotchLayout.compactZone(x: .infinity, restingRect: rect, cutoutWidth: cutout) == .cutout)
        #expect(NotchLayout.compactZone(x: 620, restingRect: rect, cutoutWidth: .nan) == .cutout)
    }

    @Test("A cutout wider than the rect swallows every inside point")
    func degenerate() {
        #expect(NotchLayout.compactZone(x: 360, restingRect: rect, cutoutWidth: 400) == .cutout)
        #expect(NotchLayout.compactZone(x: 640, restingRect: rect, cutoutWidth: 400) == .cutout)
    }

    @Test("A negative cutout behaves as zero width — the midpoint splits the ears")
    func negativeCutout() {
        #expect(NotchLayout.compactZone(x: 499, restingRect: rect, cutoutWidth: -50) == .leading)
        #expect(NotchLayout.compactZone(x: 501, restingRect: rect, cutoutWidth: -50) == .trailing)
    }
}
