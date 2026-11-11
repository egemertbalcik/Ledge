import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// A ring with no words is coloured by how much is left, and the feed's level
/// can only make it worse. A fraction written as usage rather than what is
/// left used to show a full, critical feed in green.
@Suite("A bare ring's colour")
struct FeedRingColourTests {

    @Test("The level can only make a bare ring worse")
    func levelMakesItWorse() {
        #expect(FeedEar.bareRingTint(forFraction: 0.9, level: .normal) == .green)
        #expect(FeedEar.bareRingTint(forFraction: 0.9, level: .warning) == .orange)
        #expect(FeedEar.bareRingTint(forFraction: 0.9, level: .critical) == .red)
        #expect(FeedEar.bareRingTint(forFraction: 0.1, level: .warning) == .red, "never better than its fraction")
        #expect(FeedEar.bareRingTint(forFraction: 0.3, level: .normal) == .orange)
    }
}
