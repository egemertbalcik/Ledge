import Foundation
import Testing

@testable import LedgeUI

/// The timer's open rule takes sideways scrolling while the pointer is on it,
/// and gives it back the moment it cannot be scrolled.
///
/// A claim left behind is the failure worth guarding: a sideways stroke on
/// that spot would turn a rule nobody can see instead of moving between
/// cards. Where the claim is made and released is read from the source, for
/// the reason `KeepAwakeCardLifecycleTests` gives — no rendered card can see
/// a handler that is missing.
@Suite("Scrolling the timer's rule")
struct TimerRuleScrollTests {

    private static func source(_ path: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
        return KeepAwakeCardLifecycleTests.code(in: text)
    }

    @Test("The rule claims the scrolling while the pointer is on it, and gives it back when it goes")
    func ruleClaimsOnHover() throws {
        let dial = try Self.source("Sources/LedgeUI/Cards/DurationDialView.swift")
        #expect(dial.contains("claimScroll(inside ? { steps in scrolled(by: steps) } : nil)"))
        #expect(dial.contains("settle()\n                claimScroll(nil)"),
                "a rule that is gone is never told the pointer left")
        // What a scroll does is `DurationDial.scroll`, tested as a value;
        // this is the view doing what it says.
        #expect(dial.contains("let scroll = DurationDial.scroll("))
        #expect(dial.contains("if scroll.catchesGlide { settle() }"))
        #expect(dial.contains("guard let landed = scroll.landed else { return }"))
    }

    @Test("The card gives it back when the rule shuts and when the card goes")
    func cardReleases() throws {
        let card = try Self.source("Sources/LedgeUI/Cards/TimerCardView.swift")
        #expect(card.contains("if !open { actions.claimScroll(nil) }"))
        #expect(card.contains("isRulerOpen = false\n            actions.claimScroll(nil)"))
        #expect(card.contains("claimScroll: actions.claimScroll"), "the rule is handed the claim")
    }

    @Test("The shell hands the notch's sideways scrolling to the claimed rule")
    func shellWiresIt() throws {
        let code = try Self.source("Sources/LedgeShell/Coordinator/LedgeCoordinator.swift")
        #expect(code.contains("self?.claimScroll(rule, by: .timerRule, axis: .horizontal)"))
        #expect(code.contains("if key == nil { self.gestures.releaseAllScroll() }"),
                "a pointer outside the notch is over none of its controls")
    }
}
