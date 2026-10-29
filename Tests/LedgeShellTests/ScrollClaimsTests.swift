import Testing

@testable import LedgeShell

/// Only the card holding the notch's scrolling can give it back.
///
/// SwiftUI does not order one card's teardown against the next card's
/// arrival. A release taken at face value would drop the claim the arriving
/// card had just made, and the scrolling would fall through to the cards
/// behind a control still under the pointer.
@Suite("Who holds the notch's scrolling")
@MainActor
struct ScrollClaimsTests {

    private func claim(_ owner: ScrollClaim.Owner) -> ScrollClaim {
        ScrollClaim(owner: owner, axis: owner == .timerRule ? .horizontal : .vertical) { _ in }
    }

    @Test("A card going away cannot take back the claim of the card that replaced it")
    func staleReleaseRefused() {
        var claims = ScrollClaims()
        claims.claim(claim(.keepAwakeLength))
        claims.claim(claim(.timerRule))
        let released = claims.release(.keepAwakeLength)
        #expect(!released)
        #expect(claims.current?.owner == .timerRule)
    }

    @Test("The holder gives it back, once")
    func holderReleases() {
        var claims = ScrollClaims()
        claims.claim(claim(.timerRule))
        let first = claims.release(.timerRule)
        let second = claims.release(.timerRule)
        #expect(first)
        #expect(!second)
        #expect(claims.current == nil)
    }
}
