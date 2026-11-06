import CoreGraphics
import Foundation
import Testing

@testable import LedgeCore

/// The level readout's approved measurements, and the things it must not
/// disturb.
@Suite("The readout's row")
struct HUDRowTests {

    private func geometry(
        notch: CGSize = CGSize(width: 185, height: 32),
        scale: CGFloat = 1
    ) -> NotchGeometry {
        NotchGeometry(
            screenSize: CGSize(width: 1512, height: 982),
            notchSize: notch,
            notchCenterX: 756,
            isHardwareNotch: true,
            displayScale: scale
        )
    }

    private let body: CGFloat = 281

    private func layout(
        _ phase: NotchPhase,
        _ geometry: NotchGeometry,
        radius: CGFloat = 30
    ) -> NotchLayout {
        .layout(
            for: phase, geometry: geometry, expandedSize: CGSize(width: 420, height: 160),
            bottomRadius: radius, closedBottomRadius: 10, gutterRadius: 10
        )
    }

    // MARK: - The shape

    @Test("The readout is the row taller than the island, at every notch and scale", arguments: [
        (CGSize(width: 185, height: 32), CGFloat(1)),
        (CGSize(width: 179, height: 37), CGFloat(1.1)),
        (CGSize(width: 200, height: 38), CGFloat(1.18)),
    ])
    func height(notch: CGSize, scale: CGFloat) {
        let geometry = geometry(notch: notch, scale: scale)
        let height = layout(.hud, geometry).bodySize.height
        #expect(abs(height - (notch.height + 0.5 + 30 * scale)) < 0.001)
    }

    @Test("At the approved notch the shape is 62.5 tall with a 26 corner")
    func approvedShape() {
        let readout = layout(.hud, geometry())
        #expect(readout.bodySize.height == 62.5)
        #expect(readout.bottomRadius == 26)
    }

    /// The expanded clamp is half the height, and the taller shape no longer
    /// reaches the slider's 30 default.
    @Test("The corner is capped, and a smaller corner someone chose stays theirs")
    func radiusCap() {
        #expect(layout(.hud, geometry(), radius: 40).bottomRadius == 26)
        #expect(layout(.hud, geometry(), radius: 14).bottomRadius == 14)
        #expect(layout(.hud, geometry(scale: 1.18), radius: 40).bottomRadius == 26 * 1.18)
    }

    /// They shared one footprint until now. Music must not grow with the readout.
    @Test("Music resting stays the island's own size, and so does a peek")
    func compactIsUntouched() {
        for scale in [1.0, 1.18] as [CGFloat] {
            let geometry = geometry(scale: scale)
            let compact = geometry.notchSize.height + NotchLayout.compactExtraHeight
            #expect(layout(.companion, geometry).bodySize.height == compact)
            #expect(layout(.peek, geometry).bodySize.height == compact)
            #expect(NotchLayout.hud(geometry, bottomRadius: 30, gutterRadius: 10).bodySize.height == compact)
        }
    }

    @Test("It keeps the island's width, so it only ever grows downward")
    func sameWidth() {
        let geometry = geometry()
        #expect(layout(.hud, geometry).bodySize.width == layout(.companion, geometry).bodySize.width)
    }

    // MARK: - The row

    @Test("The approved measurements")
    func measurements() {
        let row = HUDRowMetrics(geometry: geometry(), bodyWidth: body, earWidth: 48)
        #expect(row.barTop == 7)
        #expect(row.barHeight == 5)
        #expect(row.barLeading == 60)
        #expect(row.barWidth == 194)
        #expect(row.iconLeading == 14.6)
        #expect(row.iconSize == 22)
        #expect(row.centreY == 9.5)
        #expect(row.segmentGap == 1)
        #expect(row.height == 30.5)
    }

    @Test("The bar sits closer to the notch than to the shape's bottom edge")
    func barIsHigh() {
        let row = HUDRowMetrics(geometry: geometry(), bodyWidth: body, earWidth: 48)
        let below = row.height - (row.barTop + row.barHeight)
        #expect(below == 18.5)
        #expect(row.barTop < below)
    }

    @Test("Everything scales with the display")
    func scales() {
        let row = HUDRowMetrics(geometry: geometry(scale: 1.18), bodyWidth: body * 1.18, earWidth: 48)
        #expect(abs(row.iconSize - 22 * 1.18) < 0.001)
        #expect(abs(row.barHeight - 5 * 1.18) < 0.001)
        #expect(abs(row.segmentGap - 1.18) < 0.001)
    }

    @Test("The bar never reaches the glyph's slot's start, and ends inside the body")
    func barIsInside() {
        for offset in [-30, -8, 0, 10, 30] as [CGFloat] {
            let row = HUDRowMetrics(geometry: geometry(), bodyWidth: body, contentOffset: offset, earWidth: 48)
            #expect(row.barLeading > row.iconLeading)
            #expect(row.barLeading + row.barWidth < body)
        }
    }

    // MARK: - Where the pointer lands

    @Test("A point in the row is a level along the bar, at every scale and offset", arguments: [
        (CGFloat(1), CGFloat(0)),
        (CGFloat(1.18), CGFloat(0)),
        (CGFloat(1), CGFloat(10)),
        (CGFloat(1), CGFloat(-8)),
    ])
    func levelAlongTheBar(scale: CGFloat, offset: CGFloat) throws {
        let metrics = HUDRowMetrics(geometry: geometry(scale: scale), bodyWidth: body, contentOffset: offset)
        #expect(metrics.level(atRowX: metrics.barLeading) == 0)
        #expect(metrics.level(atRowX: metrics.barLeading + metrics.barWidth) == 1)
        let middle = try #require(metrics.level(atRowX: metrics.barLeading + metrics.barWidth / 2))
        #expect(abs(middle - 0.5) < 0.0001)
    }

    @Test("Past either end of the bar is that end")
    func levelPastTheEnds() {
        let metrics = HUDRowMetrics(geometry: geometry(), bodyWidth: body)
        #expect(metrics.level(atRowX: -500) == 0)
        #expect(metrics.level(atRowX: 0) == 0)
        #expect(metrics.level(atRowX: body) == 1)
        #expect(metrics.level(atRowX: 5000) == 1)
    }

    @Test("Nothing to measure against, or nonsense to measure, is no level")
    func levelFromNothing() {
        let metrics = HUDRowMetrics(geometry: geometry(), bodyWidth: body)
        #expect(metrics.level(atRowX: .nan) == nil)
        #expect(metrics.level(atRowX: .infinity) == nil)
        #expect(HUDRowMetrics(geometry: geometry(), bodyWidth: 0).level(atRowX: 40) == nil)
    }

    @Test("A row acts on the display it is showing, not the one under the pointer")
    func rowsDisplay() {
        #expect(HUDRowDisplay.target(shown: 2, underCursor: 1, available: [1, 2]) == 2)
    }

    @Test("A readout that names no display, or one that has gone, falls back to the pointer's", arguments: [
        (UInt32?.none, [UInt32(1), 2]),
        (UInt32?.some(9), [UInt32(1), 2]),
    ])
    func rowsDisplayFallback(shown: UInt32?, available: [UInt32]) {
        #expect(HUDRowDisplay.target(shown: shown, underCursor: 1, available: available) == 1)
        #expect(HUDRowDisplay.target(shown: shown, underCursor: nil, available: available) == nil)
    }

    @Test("The pointer can set sound and brightness, and not the keyboard's backlight")
    func whatThePointerCanSet() {
        #expect(HUDReadout.Kind.volume.canBeSetFromTheRow)
        #expect(HUDReadout.Kind.brightness.canBeSetFromTheRow)
        #expect(!HUDReadout.Kind.keyboardBacklight.canBeSetFromTheRow)
    }

    @Test("The offset moves the glyph and the bar together and shortens the bar")
    func offset() {
        let row = HUDRowMetrics(geometry: geometry(), bodyWidth: body, contentOffset: 4, earWidth: 48)
        #expect(row.iconLeading == 18.6)
        #expect(row.barLeading == 64)
        #expect(row.barWidth == 186)
    }

    /// The slider went to ±30 for the old ears, and a stored value may still.
    @Test("The offset is clamped, and nonsense in it is ignored", arguments: [
        (CGFloat(30), CGFloat(70)),
        (CGFloat(-30), CGFloat(52)),
        (CGFloat.nan, CGFloat(60)),
        (CGFloat.infinity, CGFloat(60)),
    ])
    func offsetClamp(offset: CGFloat, leading: CGFloat) {
        #expect(HUDRowMetrics(geometry: geometry(), bodyWidth: body, contentOffset: offset, earWidth: 48).barLeading == leading)
    }

    /// The tallest glyph rises 1.8 above the row's approved centre line. The
    /// width is passed in: the setting is shared by every test in the process.
    @Test("Narrow ears move the row down so nothing can go behind the hardware", arguments: [
        (CGFloat(36), CGFloat(11.8)), (CGFloat(47), CGFloat(11.8)), (CGFloat(48), CGFloat(9.5)), (CGFloat(90), CGFloat(9.5)),
    ])
    func narrowEars(ear: CGFloat, centre: CGFloat) {
        let row = HUDRowMetrics(geometry: geometry(), bodyWidth: 185 + ear * 2, earWidth: ear)
        #expect(row.centreY == centre)
        // The bar stretches with the ears and the glyph stays pinned.
        #expect(row.iconLeading == 14.6)
        #expect(row.barWidth == 185 + ear * 2 - 87)
    }

    // MARK: - The segments

    private let size = CGSize(width: 194, height: 5)

    @Test("Sixteen segments fill the bar exactly")
    func sixteen() throws {
        let rects = HUDSegments.rects(in: size, gap: 1)
        #expect(rects.count == 16)
        #expect(try #require(rects.first).minX == 0)
        #expect(try #require(rects.last).maxX == 194)
        #expect(rects.allSatisfy { $0.height == 5 && $0.minY == 0 })
    }

    /// An HStack of 11.19-wide frames gives gaps that visibly differ.
    @Test("Every gap is exactly the same and every edge lands on a pixel",
          arguments: [CGFloat(194), 170, 203.5, 228.92, 301.3])
    func pixelSnapped(width: CGFloat) {
        let rects = HUDSegments.rects(in: CGSize(width: width, height: 5), gap: 1)
        for (left, right) in zip(rects, rects.dropFirst()) {
            #expect(abs((right.minX - left.maxX) - 1) < 0.0001)
        }
        for rect in rects.dropLast() {
            #expect((rect.minX * 2).rounded() == rect.minX * 2)
            #expect((rect.maxX * 2).rounded() == rect.maxX * 2)
        }
    }

    @Test("The segments differ by a pixel at most")
    func evenWidths() throws {
        let widths = HUDSegments.rects(in: size, gap: 1).map(\.width)
        #expect(try #require(widths.max()) - (try #require(widths.min())) <= 0.5)
    }

    @Test("Nothing to draw in, nothing drawn", arguments: [
        CGSize.zero, CGSize(width: 0, height: 5), CGSize(width: CGFloat.nan, height: 5), CGSize(width: -10, height: 5),
    ])
    func emptyBar(size: CGSize) {
        #expect(HUDSegments.rects(in: size, gap: 1).isEmpty)
    }

    @Test("One step of the volume key is one segment", arguments: 0...16)
    func oneStepOneSegment(steps: Int) {
        let rects = HUDSegments.rects(in: size, gap: 1)
        let lit = HUDSegments.lit(level: Double(steps) / 16, in: rects)
        #expect(lit.count == steps)
        #expect(zip(lit, rects).allSatisfy { $0 == $1 })
    }

    /// The level spring overshoots both ends of the bar on its way to rest.
    @Test("Overshoot and nonsense stay inside the bar")
    func clamped() {
        let rects = HUDSegments.rects(in: size, gap: 1)
        #expect(HUDSegments.lit(level: -0.2, in: rects).isEmpty)
        #expect(HUDSegments.lit(level: 1.3, in: rects) == rects)
        #expect(HUDSegments.lit(level: .nan, in: rects).isEmpty)
    }

    /// A drag, an external display's floor or a non-default step can land here.
    @Test("A level between segments cuts through the one it lands in")
    func cuts() throws {
        let rects = HUDSegments.rects(in: size, gap: 1)
        let lit = HUDSegments.lit(level: (3 + 0.5) / 16, in: rects)
        #expect(lit.count == 4)
        let last = try #require(lit.last)
        #expect(last.minX == rects[3].minX)
        #expect(abs(last.width - rects[3].width / 2) < 0.0001)
    }

    // MARK: - Which spring

    @Test("The shape takes the readout's own spring only to and from the compact phases")
    func springs() {
        for phase in [NotchPhase.idle, .companion, .peek] {
            #expect(ReadoutShapeMotion(from: phase, to: .hud) == .arriving)
            #expect(ReadoutShapeMotion(from: .hud, to: phase) == .leaving)
        }
        // A whole card collapsing in an eighth of a second would be violent.
        for phase in [NotchPhase.hover, .expanded] {
            #expect(ReadoutShapeMotion(from: phase, to: .hud) == .ordinary)
            #expect(ReadoutShapeMotion(from: .hud, to: phase) == .ordinary)
        }
        for from in NotchPhase.allCases where from != .hud {
            for to in NotchPhase.allCases where to != .hud {
                #expect(ReadoutShapeMotion(from: from, to: to) == .ordinary)
            }
        }
    }
}
