import AppKit
import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// The row as drawn.
@MainActor
@Suite("The readout as drawn")
struct HUDRowViewTests {

    private static let geometry = NotchGeometry(
        screenSize: CGSize(width: 1512, height: 982),
        notchSize: CGSize(width: 185, height: 32),
        notchCenterX: 756,
        isHardwareNotch: true
    )

    private func path(_ level: Double, width: CGFloat = 194) -> Path {
        HUDSegmentsShape(level: level, gap: 1, innerRadius: 0.5)
            .path(in: CGRect(x: 0, y: 0, width: width, height: 5))
    }

    @Test("Every state lays out at the body's width and the row's height")
    func lays() {
        let metrics = HUDRowMetrics(geometry: Self.geometry, bodyWidth: 281)
        let readouts = [
            HUDReadout(kind: .volume, level: 0.4),
            HUDReadout(kind: .volume, level: 0),
            HUDReadout(kind: .volume, level: 0.4, isMuted: true),
            HUDReadout(kind: .volume, level: 1),
            HUDReadout(kind: .brightness, level: 0.2),
            HUDReadout(kind: .brightness, level: 0.9),
            HUDReadout(kind: .keyboardBacklight, level: 0.5),
        ]
        for readout in readouts {
            let size = NSHostingView(rootView: HUDRowView(readout: readout, metrics: metrics)).fittingSize
            #expect(size.width == 281, "\(readout)")
            // A hosting view reports whole points, and this is half of one.
            #expect(size.height == metrics.height.rounded(.up), "\(readout)")
        }
    }

    /// Mute and zero are different statements, and it is only the glyph
    /// that tells them apart now.
    @Test("Zero and muted share an empty bar and differ by the slash")
    func zeroAndMuted() {
        let zero = HUDReadout(kind: .volume, level: 0)
        let muted = HUDReadout(kind: .volume, level: 0.4, isMuted: true)
        #expect(zero.symbolName == "speaker.fill")
        #expect(muted.symbolName == "speaker.slash.fill")
        #expect(muted.level == 0.4, "the level comes back with the unmute")
    }

    @Test("The drawn path follows the level, and an animating value can overshoot safely")
    func pathFollowsLevel() {
        #expect(path(0).isEmpty)
        #expect(path(-0.1).isEmpty)
        #expect(!path(1 / 16).isEmpty)
        #expect(path(1.2).boundingRect == path(1).boundingRect)
        #expect(path(1).boundingRect.maxX == 194)
        #expect(path(0.5).boundingRect.maxX < 100)
    }

    @Test("The level is what animates")
    func animatable() {
        var shape = HUDSegmentsShape(level: 0.25, gap: 1, innerRadius: 0.5)
        #expect(shape.animatableData == 0.25)
        shape.animatableData = 0.75
        #expect(shape.level == 0.75)
    }

    @Test("Each direction of a phase change gets a spring, Reduce Motion the plain one")
    func shapeSprings() {
        func change(_ from: NotchPhase, _ to: NotchPhase, reduced: Bool = false) -> Animation {
            Motion.phaseChange(from: from, to: to, response: 0.4, damping: 0.9, reduced: reduced)
        }
        let ordinary = Motion.expand(response: 0.4, damping: 0.9)
        #expect(change(.idle, .hud) == Motion.hudShapeIn)
        #expect(change(.hud, .idle) == Motion.hudShapeOut)
        #expect(change(.expanded, .hud) == ordinary)
        #expect(change(.hud, .expanded) == ordinary)
        #expect(change(.idle, .hover) == ordinary)
        #expect(change(.idle, .hud, reduced: true) == Motion.expand(response: 0.4, damping: 0.9, reduced: true))
    }

    @Test("The presentation remembers where a phase came from, and only on a real change")
    func previousPhase() {
        let presentation = NotchPresentation()
        presentation.phase = .companion
        presentation.phase = .hud
        #expect(presentation.previousPhase == .companion)
        presentation.phase = .hud
        #expect(presentation.previousPhase == .companion)
        presentation.phase = .idle
        #expect(presentation.previousPhase == .hud)
    }

    /// The owner's decision: no colour for mute, in either place this key
    /// reads out. The Levels card is a separate surface and was left alone.
    @Test("Nothing about a muted readout is red")
    func noRed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/LedgeUI/Cards/HUDEarsView.swift"), encoding: .utf8
        )
        #expect(!source.contains("Color.red"))
        #expect(!source.contains(".red"))
    }

    /// A new identity per press would restart the arrival on every repeat.
    @Test("The row keeps its identity as the reading changes")
    func stableIdentity() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/LedgeUI/NotchOverlayView.swift"), encoding: .utf8
        )
        let start = try #require(source.range(of: "HUDRowView("))
        let tail = source[start.upperBound...]
        let end = try #require(tail.range(of: ".transition(Motion.hudRow(reduced: reduceMotion))"))
        #expect(!tail[..<end.lowerBound].contains(".id("))
    }
}
