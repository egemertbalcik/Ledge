import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// The Espresso length's numbers take scrolling while the pointer is over
/// them, and give it back the moment they can no longer be scrolled.
///
/// A claim left behind is the failure worth guarding: the wheel would stop
/// paging the cards until the card came back. The hover rule is tested as a
/// value; where the claim is made and released is read from the source, for
/// the reason `KeepAwakeCardLifecycleTests` gives — no rendered card can see
/// a handler that is missing.
@Suite("Scrolling the Espresso length's numbers")
struct KeepAwakeLengthScrollTests {

    // MARK: - The hover rule

    @Test("Arriving on the next number before leaving the last keeps the next one")
    func arrivalBeforeLeave() {
        var hover = LengthHover()
        hover.entered(.hours)
        hover.entered(.minutes)
        let gaveBack = hover.left(.hours)
        #expect(!gaveBack, "hours no longer holds the scrolling, so cannot give it back")
        #expect(hover.over == .minutes)
    }

    @Test("Leaving the number that holds the scrolling gives it back")
    func leavingGivesBack() {
        var hover = LengthHover()
        hover.entered(.days)
        let first = hover.left(.days)
        #expect(first)
        #expect(hover.over == nil)
        let second = hover.left(.days)
        #expect(!second, "and only once")
    }

    // MARK: - Where the claim is made and released

    private var cardCode: String {
        get throws { KeepAwakeCardLifecycleTests.code(in: try KeepAwakeCardLifecycleTests.cardSource) }
    }

    @Test("Each number claims the scrolling while the pointer is over it")
    func numbersClaimOnHover() throws {
        #expect(try cardCode.contains(".onHover { inside in pointer(inside, field) }"))
    }

    @Test("The card gives the scrolling back when the question ends and when the card goes")
    func releases() throws {
        let body = KeepAwakeCardLifecycleTests.code(
            in: try KeepAwakeCardLifecycleTests.bodyBlock(of: try KeepAwakeCardLifecycleTests.cardSource)
        )
        // A number taken away from under the pointer is never told it left.
        #expect(body.contains(".onChange(of: flow.isAsking)"))
        #expect(body.components(separatedBy: "claimScroll(nil)").count - 1 >= 2,
                "once when the question ends, once when the card goes away")
    }

    @Test("The shell hands the notch's scrolling to the claimed number")
    func shellWiresIt() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let coordinator = try String(
            contentsOf: root.appending(path: "Sources/LedgeShell/Coordinator/LedgeCoordinator.swift"),
            encoding: .utf8
        )
        let code = KeepAwakeCardLifecycleTests.code(in: coordinator)
        #expect(code.contains("gestures.claimScroll(ScrollClaim(owner: owner, axis: axis, step: step))"))
        #expect(code.contains("gestures.releaseScroll(owner)"))
        #expect(code.contains("self?.claimScroll(number, by: .keepAwakeLength, axis: .vertical)"))
    }
}
