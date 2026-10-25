import CoreGraphics
import Foundation
import Testing

@testable import LedgeCore

/// A level key pressed while a card is open under a pointer that never moves.
///
/// Found by review: the readout that replaces the card is a fraction of its
/// size, so a pointer resting on the card body was judged to have left, and a
/// pointer parked inside the readout was judged never to have hovered at all.
/// Either way the card closed under a still pointer, and a pinned card was
/// dismissed. The real layout, the real hit test and the real reducer, driven
/// the way the shell drives them.
@Suite("A readout in front of an open card")
struct ReadoutOverCardTests {

    private static let geometry = NotchGeometry(
        screenSize: CGSize(width: 1512, height: 982),
        notchSize: CGSize(width: 185, height: 32),
        notchCenterX: 756,
        isHardwareNotch: true
    )

    /// A layout as a rectangle on screen, hanging from the top edge.
    private static func onScreen(_ layout: NotchLayout) -> CGRect {
        let size = layout.boundingSize
        return CGRect(
            x: geometry.notchCenterX - size.width / 2,
            y: geometry.screenSize.height - size.height,
            width: size.width, height: size.height
        )
    }

    /// The weather card open, the hovered readout, and the closed notch.
    private static func regions() -> (card: CGRect, readout: CGRect, resting: CGRect) {
        let size = NotchLayout.cardSize(
            kind: .weather, phase: .hover, base: CGSize(width: 420, height: 160),
            geometry: geometry, routePickerRows: 0, hasSelection: true, earWidth: 53
        )
        func layout(_ phase: NotchPhase, interactive: Bool = false) -> CGRect {
            onScreen(NotchLayout.layout(
                for: phase, geometry: geometry, expandedSize: size,
                bottomRadius: 22, closedBottomRadius: 10, gutterRadius: 6,
                isHudInteractive: interactive, hudExtraHeight: 0
            ))
        }
        return (layout(.hover), layout(.hud, interactive: true), layout(.idle))
    }

    private func run(_ state: inout NotchState, _ events: NotchEvent...) {
        for event in events { _ = NotchReducer.reduce(&state, event) }
    }

    /// What the shell's tracker answers for a pointer that has not moved.
    private func stillInside(_ pointer: CGPoint, region: CGRect?) -> Bool {
        DisplayHitTest.hit(
            point: pointer, current: 1 as Int?, currentOpenRegion: region,
            closedRegions: [(key: 1, rect: Self.regions().resting)]
        ) != nil
    }

    @Test("Resting on the card below the readout: no exit, and the card comes back when the readout ends")
    func pointerBelowTheReadout() throws {
        let (card, readout, _) = Self.regions()
        let pointer = CGPoint(x: Self.geometry.notchCenterX, y: Self.geometry.screenSize.height - 130)
        try #require(card.contains(pointer), "the pointer is on the open card")
        try #require(!readout.contains(pointer), "and below the readout drawn in its place")

        var state = NotchState()
        run(&state, .hoverChanged(true), .hudRequested(1.4))
        try #require(ReadoutOverCard.coversCard(state))

        let region = ReadoutOverCard.trackingRegion(readout: readout, card: card)
        #expect(stillInside(pointer, region: region), "the pointer has not left anything")

        // The readout's timer, under a pointer that is still inside: held,
        // then handed back because the pointer is on the card, not the slider.
        run(&state, .timerFired(.hud))
        try #require(state.phase == .hud && state.isHovering)
        #expect(ReadoutOverCard.handsCardBack(pointer: pointer, readout: readout, card: card))
        run(&state, .hudReleased)
        #expect(state.phase == .hover, "the card the pointer is on is back")
    }

    @Test("Parked inside the readout, over the card: a real hover, so the card comes back")
    func pointerParkedOnTheReadout() throws {
        let (card, readout, resting) = Self.regions()
        let pointer = CGPoint(x: Self.geometry.notchCenterX, y: Self.geometry.screenSize.height - 70)
        try #require(card.contains(pointer) && readout.contains(pointer))
        try #require(!resting.insetBy(dx: 0, dy: -DisplayHitTest.slack).contains(pointer),
                     "below the closed notch, where the old check called it an artifact")

        var state = NotchState()
        run(&state, .hoverChanged(true), .hudRequested(1.4), .timerFired(.hud))
        try #require(state.phase == .hud && state.isHovering, "held under the pointer")
        #expect(!ReadoutOverCard.handsCardBack(pointer: pointer, readout: readout, card: card),
                "on the readout, the hold stands so the slider can be used")

        // The shell's parked-pointer release.
        let genuine = ReadoutOverCard.restsOnCard(pointer: pointer, card: card)
        #expect(genuine)
        if !genuine { run(&state, .hoverChanged(false)) }
        run(&state, .hudReleased)
        #expect(state.phase == .hover)
    }

    @Test("A pinned card stays pinned through a level key")
    func pinnedCardStays() throws {
        let (card, readout, _) = Self.regions()
        let pointer = CGPoint(x: Self.geometry.notchCenterX, y: Self.geometry.screenSize.height - 130)
        try #require(card.contains(pointer))

        var state = NotchState()
        run(&state, .hoverChanged(true), .clicked)
        try #require(state.phase == .expanded && state.isPinned)
        run(&state, .hudRequested(1.4))
        try #require(ReadoutOverCard.coversCard(state))
        #expect(stillInside(pointer, region: ReadoutOverCard.trackingRegion(readout: readout, card: card)))

        run(&state, .timerFired(.hud))
        try #require(state.phase == .hud)
        #expect(ReadoutOverCard.handsCardBack(pointer: pointer, readout: readout, card: card))
        run(&state, .hudReleased)
        #expect(state.phase == .expanded)
        #expect(state.isPinned)
    }

    /// The rule the shell had for a pointer that only became "inside" when
    /// the readout widened the island beside a closed notch still holds.
    @Test("Over the resting notch, nothing changes")
    func restingNotchUnchanged() throws {
        let (card, readout, _) = Self.regions()
        var state = NotchState()
        run(&state, .hudRequested(1.4))
        try #require(state.phase == .hud && state.suspended == .idle)
        #expect(!ReadoutOverCard.coversCard(state))
        #expect(ReadoutOverCard.trackingRegion(readout: readout, card: nil) == readout)

        // Off the card entirely: no hover is invented.
        let away = CGPoint(x: card.maxX + 40, y: card.midY)
        #expect(!ReadoutOverCard.restsOnCard(pointer: away, card: card))
        #expect(!ReadoutOverCard.handsCardBack(pointer: away, readout: readout, card: card))
        #expect(!ReadoutOverCard.restsOnCard(pointer: away, card: nil))
    }
}
