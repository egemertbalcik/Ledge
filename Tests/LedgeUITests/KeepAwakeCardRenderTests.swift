import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// The card is drawn here rather than described, because the thing being
/// checked — that a long length still fits the width the island gives it — is
/// not visible in the view's source.
@Suite("The Keep Awake card draws at the widths it is given")
@MainActor
struct KeepAwakeCardRenderTests {

    /// The widths the island actually produces, not round numbers: 275 is what
    /// a hardware notch gives this card, and designing against 340 is how a
    /// seven-day span came to be truncated on every real Mac.
    private static let widths: [CGFloat] = [260, 275, 283, 320]

    private func payload(minutes: Int, phase: KeepAwakePayload.Phase = .ready) -> KeepAwakePayload {
        KeepAwakePayload(phase: phase, minutes: minutes)
    }

    private func drawn(_ view: some View, width: CGFloat) -> CGSize? {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 2
        return renderer.nsImage?.size
    }

    @Test("Every length from the floor to seven days draws at every width")
    func drawsAtEveryLength() {
        // The lengths that change the shape: minutes only, hours added, days
        // added, and the ceiling.
        let lengths = [
            KeepAwakeReducer.minimumMinutes,
            45,
            3 * 60 + 5,
            24 * 60,
            3 * 24 * 60 + 7 * 60 + 25,
            KeepAwakeReducer.maximumMinutes
        ]
        for minutes in lengths {
            for width in Self.widths {
                // Both Ready faces, and the running one: the length is on all
                // three and each has a different amount of room for it.
                let faces: [(String, KeepAwakeCardView)] = [
                    ("resting", KeepAwakeCardView(payload: payload(minutes: minutes))),
                    ("asking", KeepAwakeCardView(
                        payload: payload(minutes: minutes), startsAsking: true,
                        draft: KeepAwakeSpan(totalMinutes: minutes)
                    )),
                    ("running", KeepAwakeCardView(payload: KeepAwakePayload(
                        phase: .running,
                        remaining: TimeInterval(minutes * 60),
                        until: "14:30",
                        minutes: minutes
                    )))
                ]
                for (name, card) in faces {
                    let size = drawn(card, width: width)
                    #expect(size != nil, "nothing drawn \(name) at \(minutes)m, width \(width)")
                    if let size {
                        #expect(size.width <= width + 0.5,
                                "\(name) \(minutes)m overflowed \(width) (drew \(size.width))")
                    }
                }
            }
        }
    }

    @Test("The card is no wider with days on it than without")
    func lengthDoesNotChangeTheWidth() {
        // The width belongs to the island, not to the number: a longer span
        // must not push the card out.
        for width in Self.widths {
            let short = drawn(
                KeepAwakeCardView(payload: payload(minutes: 20), startsAsking: true,
                                  draft: KeepAwakeSpan(days: 0, hours: 0, minutes: 20)),
                width: width
            )
            let long = drawn(
                KeepAwakeCardView(payload: payload(minutes: 20), startsAsking: true,
                                  draft: KeepAwakeSpan(days: 6, hours: 23, minutes: 59)),
                width: width
            )
            #expect(short?.width == long?.width, "the width moved with the length at \(width)")
        }
    }

    @Test("The compact face still draws")
    func compactDraws() {
        for width in [130.0, 180.0] as [CGFloat] {
            let card = KeepAwakeCardView(payload: payload(minutes: 90), isCompactWidth: true)
            #expect(drawn(card, width: width) != nil, "nothing drawn compact at \(width)")
        }
    }
}

/// The card reports a height and the island is sized from it. These are about
/// that contract, which no amount of drawing the card on its own could check:
/// the card looked right in isolation while the island stayed at 170 and put
/// the button under the page dots.
@Suite("The island follows the Keep Awake card")
@MainActor
struct KeepAwakeHeightContractTests {

    private let geometry = NotchGeometry(
        screenSize: CGSize(width: 1470, height: 956),
        notchSize: CGSize(width: 179, height: 32),
        notchCenterX: 735,
        isHardwareNotch: true
    )

    /// What the card measures, by drawing it at the width the island gives it.
    private func contentHeight(_ view: some View) -> CGFloat {
        let width = NotchLayout.cardWidth(kind: .keepAwake, geometry: geometry)
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 1
        return renderer.nsImage?.size.height ?? 0
    }

    private func islandHeight(forContent content: CGFloat) -> CGFloat {
        NotchLayout.cardSize(
            kind: .keepAwake,
            phase: .expanded,
            base: CGSize(width: 275, height: 170),
            cardContentHeight: content,
            geometry: geometry,
            routePickerRows: 0,
            hasSelection: true
        ).height
    }

    private func payload(_ phase: KeepAwakePayload.Phase) -> KeepAwakePayload {
        switch phase {
        case .running:
            KeepAwakePayload(phase: .running, remaining: 2 * 24 * 3600,
                             until: "14:30", minutes: 3 * 24 * 60)
        default:
            KeepAwakePayload(phase: phase, minutes: 60)
        }
    }

    @Test("Every face gets an island tall enough for it, with the dots' strip left over")
    func islandFollowsEveryFace() {
        let faces: [(String, KeepAwakeCardView)] = [
            ("resting", KeepAwakeCardView(payload: payload(.ready))),
            ("asking", KeepAwakeCardView(payload: payload(.ready), startsAsking: true,
                                         draft: KeepAwakeSpan(days: 6, hours: 23, minutes: 59))),
            ("running", KeepAwakeCardView(payload: payload(.running)))
        ]
        for (name, card) in faces {
            let content = contentHeight(card)
            #expect(content > 0, "\(name) drew nothing")
            let island = islandHeight(forContent: content)
            // The cutout is above the content, and the dots sit in a strip of
            // their own below it. Anything less and the card's last row is
            // drawn under them.
            let needed = geometry.notchSize.height + content + NotchLayout.dotsBand
            #expect(island >= needed,
                    "\(name): island \(island) is short of \(needed) (content \(content))")
        }
    }

    @Test("The asking face is taller than the resting one, and the island knows")
    func islandGrowsWhenTheCardAsks() {
        let resting = contentHeight(KeepAwakeCardView(payload: payload(.ready)))
        let asking = contentHeight(
            KeepAwakeCardView(payload: payload(.ready), startsAsking: true)
        )
        #expect(asking > resting, "the three boxes have to cost something")
        #expect(islandHeight(forContent: asking) > islandHeight(forContent: resting),
                "and the island has to pay it, or the boxes are drawn into the dots")
    }

    @Test("A card that has not measured itself yet still gets a usable island")
    func unmeasuredCardIsNotCollapsed() {
        let island = islandHeight(forContent: 0)
        #expect(island >= 140, "the first frame must not be a sliver")
    }
}

/// The lid-closed mode, drawn.
///
/// The sentences are the whole of this feature's honesty, and they are long:
/// "Something else is already keeping this Mac awake — another app, or pmset in
/// Terminal" is three lines on a card 275 points wide. A refusal that is
/// truncated to "Something else is already…" has told the user nothing, which
/// is the failure the nine codes exist to prevent — so every one of them is
/// drawn here at every width the island produces.
@Suite("The lid-closed mode draws at the widths it is given")
@MainActor
struct KeepAwakeLidRenderTests {

    private static let widths: [CGFloat] = [260, 275, 283, 320]

    private static let everyState: [KeepAwakeLidState] =
        [.unsignedBuild, .notInstalled, .off, .holding, .unconfirmed]
            + KeepAwakeLidCode.allCases.map { .refused($0) }

    private func drawn(_ view: some View, width: CGFloat) -> CGSize? {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 2
        return renderer.nsImage?.size
    }

    @Test("Every lid state draws on the resting card without widening it")
    func everyStateRests() {
        for state in Self.everyState {
            for width in Self.widths {
                let card = KeepAwakeCardView(
                    payload: KeepAwakePayload(phase: .ready, minutes: 60, lid: state),
                    // Shown, which is otherwise a press away for the two
                    // states that wait to be reached for.
                    lidNote: true
                )
                let size = drawn(card, width: width)
                #expect(size != nil, "nothing drawn for \(state) at \(width)")
                if let size {
                    #expect(size.width <= width + 0.5,
                            "\(state) overflowed \(width) (drew \(size.width))")
                }
            }
        }
    }

    /// Two buttons where there was one. The question has to be answerable with
    /// "never mind", and the pair has to fit beside the three number boxes.
    @Test("The asking face draws with both of its buttons")
    func askingFaceDraws() {
        for width in Self.widths {
            let card = KeepAwakeCardView(
                payload: KeepAwakePayload(phase: .ready, minutes: 60, lid: .off),
                startsAsking: true,
                draft: KeepAwakeSpan(days: 6, hours: 23, minutes: 59)
            )
            let size = drawn(card, width: width)
            #expect(size != nil, "nothing drawn asking at \(width)")
            if let size {
                #expect(size.width <= width + 0.5,
                        "the asking face overflowed \(width) (drew \(size.width))")
            }
        }
    }

    @Test("The running card draws every sentence the hold can have")
    func runningFaceDraws() {
        for state in Self.everyState {
            for width in Self.widths {
                let card = KeepAwakeCardView(payload: KeepAwakePayload(
                    phase: .running, remaining: 2 * 3600, until: "17:40",
                    minutes: 120, lidHeld: state.isLive, lidClosed: true, lid: state
                ))
                let size = drawn(card, width: width)
                #expect(size != nil, "nothing drawn running for \(state) at \(width)")
                if let size {
                    #expect(size.width <= width + 0.5,
                            "running \(state) overflowed \(width) (drew \(size.width))")
                }
            }
        }
    }

    /// A setup prompt on the resting card would be shouted at everyone who has
    /// not set the helper up — which, until there is anything to set up, is
    /// everyone. So "not set up" waits to be reached for, and a refusal, which
    /// is the answer to something that was already done, does not.
    @Test("Not set up waits to be asked; a refusal does not")
    func whatSpeaksUnasked() {
        func height(_ lid: KeepAwakeLidState, note: Bool) -> CGFloat {
            let card = KeepAwakeCardView(
                payload: KeepAwakePayload(phase: .ready, minutes: 60, lid: lid),
                lidNote: note
            )
            let renderer = ImageRenderer(content: card.frame(width: 275))
            renderer.scale = 1
            return renderer.nsImage?.size.height ?? 0
        }
        let standing = height(.off, note: false)
        #expect(height(.notInstalled, note: false) == standing,
                "a setup prompt is being shouted at a card nobody asked a question of")
        #expect(height(.notInstalled, note: true) > standing,
                "reaching for the mode explained nothing")
        #expect(height(.refused(.foreign), note: false) > standing,
                "a refusal waited to be asked about, so nothing explains it")
    }

    /// The island is sized from what the card measures, and a sentence that
    /// makes the card taller has to make the island taller with it — or the
    /// explanation is drawn underneath the page dots.
    @Test("A card with something to say gets an island tall enough to say it")
    func islandGrowsForTheSentence() {
        let geometry = NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: 735,
            isHardwareNotch: true
        )
        let width = NotchLayout.cardWidth(kind: .keepAwake, geometry: geometry)
        func height(_ card: KeepAwakeCardView) -> CGFloat {
            let renderer = ImageRenderer(content: card.frame(width: width))
            renderer.scale = 1
            return renderer.nsImage?.size.height ?? 0
        }
        let quiet = height(KeepAwakeCardView(payload: KeepAwakePayload(
            phase: .running, remaining: 2 * 3600, until: "17:40", minutes: 120, lid: .off
        )))
        let speaking = height(KeepAwakeCardView(payload: KeepAwakePayload(
            phase: .running, remaining: 2 * 3600, until: "17:40", minutes: 120,
            lid: .refused(.foreign)
        )))
        #expect(speaking > quiet, "the refusal cost no height, so it is not being drawn")
        func island(_ content: CGFloat) -> CGFloat {
            NotchLayout.cardSize(
                kind: .keepAwake, phase: .expanded,
                base: CGSize(width: 275, height: 170),
                cardContentHeight: content, geometry: geometry,
                routePickerRows: 0, hasSelection: true
            ).height
        }
        let needed = geometry.notchSize.height + speaking + NotchLayout.dotsBand
        #expect(island(speaking) >= needed,
                "island \(island(speaking)) is short of \(needed)")
    }
}
