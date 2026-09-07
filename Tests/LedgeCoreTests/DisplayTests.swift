import CoreGraphics
import Foundation
import Testing

@testable import LedgeCore

@Suite("Display reconcile")
struct DisplayReconcilerTests {

    @Test("An unchanged set adds and removes nothing")
    func noChange() {
        let plan = DisplayReconciler.plan(current: [1, 2], wanted: [1, 2])
        #expect(plan.added.isEmpty)
        #expect(plan.removed.isEmpty)
        #expect(plan.kept == [1, 2])
    }

    @Test("Plugging in a display adds exactly that one")
    func hotPlug() {
        let plan = DisplayReconciler.plan(current: [1], wanted: [1, 7])
        #expect(plan.added == [7])
        #expect(plan.removed.isEmpty)
        #expect(plan.kept == [1], "the built-in panel must not be disturbed")
    }

    @Test("Unplugging a display removes its panel and keeps the rest")
    func unplug() {
        let plan = DisplayReconciler.plan(current: [1, 7], wanted: [1])
        #expect(plan.added.isEmpty)
        #expect(plan.removed == [7])
        #expect(plan.kept == [1])
    }

    @Test("Survivors come back in the wanted order, not the current one")
    func preservesWantedOrder() {
        let plan = DisplayReconciler.plan(current: [7, 1], wanted: [1, 7, 9])
        #expect(plan.kept == [1, 7])
        #expect(plan.added == [9])
    }

    @Test("Losing every display removes everything and keeps nothing")
    func allGone() {
        let plan = DisplayReconciler.plan(current: [1, 7], wanted: [Int]())
        #expect(plan.removed == [1, 7])
        #expect(plan.kept.isEmpty)
        #expect(plan.added.isEmpty)
    }

    @Test("Starting from nothing is all additions")
    func coldStart() {
        let plan = DisplayReconciler.plan(current: [Int](), wanted: [1, 7])
        #expect(plan.added == [1, 7])
        #expect(plan.removed.isEmpty)
    }
}

@Suite("Display hit test")
struct DisplayHitTestTests {

    /// Two displays side by side, each with a small resting region at its top.
    private let builtIn = (key: 1, rect: CGRect(x: 600, y: 900, width: 180, height: 32))
    private let external = (key: 7, rect: CGRect(x: 2000, y: 900, width: 180, height: 32))

    private var closed: [(key: Int, rect: CGRect)] { [builtIn, external] }

    @Test("With one display this is exactly the old inside/outside answer")
    func singleDisplayEquivalence() {
        let inside = DisplayHitTest.hit(
            point: CGPoint(x: 690, y: 910),
            current: nil, currentOpenRegion: nil,
            closedRegions: [builtIn]
        )
        #expect(inside == 1)

        let outside = DisplayHitTest.hit(
            point: CGPoint(x: 100, y: 500),
            current: nil, currentOpenRegion: nil,
            closedRegions: [builtIn]
        )
        #expect(outside == nil)
    }

    @Test("The open region keeps the cursor even outside the closed footprint")
    func openRegionIsSticky() {
        // The overlay has grown well below and wider than its resting shape.
        let open = CGRect(x: 500, y: 700, width: 400, height: 232)
        let hit = DisplayHitTest.hit(
            point: CGPoint(x: 520, y: 750),
            current: 1, currentOpenRegion: open,
            closedRegions: closed
        )
        #expect(hit == 1, "the cursor is on the grown card, so the display still owns it")
    }

    @Test("Moving between displays switches in a single step, never through nil")
    func transitionsDirectly() {
        let open = CGRect(x: 500, y: 700, width: 400, height: 232)
        let hit = DisplayHitTest.hit(
            point: CGPoint(x: 2090, y: 910),   // on the external display's notch
            current: 1, currentOpenRegion: open,
            closedRegions: closed
        )
        #expect(hit == 7)
    }

    @Test("A point on no display at all returns nil")
    func missReturnsNil() {
        let hit = DisplayHitTest.hit(
            point: CGPoint(x: 1500, y: 500),
            current: nil, currentOpenRegion: nil,
            closedRegions: closed
        )
        #expect(hit == nil)
    }

    @Test("Two points of slack above the edge still count as a hit")
    func verticalSlackHonoured() {
        // Reaching for the notch puts the cursor a point above the screen.
        let justAbove = CGPoint(x: 690, y: builtIn.rect.maxY + 1)
        #expect(
            DisplayHitTest.hit(
                point: justAbove, current: nil, currentOpenRegion: nil,
                closedRegions: closed
            ) == 1
        )

        let tooFar = CGPoint(x: 690, y: builtIn.rect.maxY + 10)
        #expect(
            DisplayHitTest.hit(
                point: tooFar, current: nil, currentOpenRegion: nil,
                closedRegions: closed
            ) == nil
        )
    }

    @Test("The scan order is honoured, so the notched display is tested first")
    func scanOrderIsDeterministic() {
        // Overlapping regions would otherwise be resolved arbitrarily.
        let overlapping = [
            (key: 7, rect: CGRect(x: 600, y: 900, width: 180, height: 32)),
            (key: 1, rect: CGRect(x: 600, y: 900, width: 180, height: 32)),
        ]
        let hit = DisplayHitTest.hit(
            point: CGPoint(x: 690, y: 910),
            current: nil, currentOpenRegion: nil,
            closedRegions: overlapping
        )
        #expect(hit == 7, "first in the list wins")
    }
}
