import CoreGraphics
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// The corner construction behind `LedgeShape`. It drifted
/// apart once when only one was corrected, which is why it lives in one place
/// and is checked here.
@Suite("Continuous corner")
@MainActor
struct ContinuousCornerTests {

    @Test("Reach grows with smoothing")
    func reachGrowsWithSmoothing() {
        // A corner stops being straight `(1 + smoothing) * radius` before the
        // vertex. Callers end their straight edge there, so this number is what
        // keeps edges and corners from overlapping.
        #expect(ContinuousCorner.reach(radius: 10, smoothing: 0) == 10)
        #expect(ContinuousCorner.reach(radius: 10, smoothing: 1) == 20)
        #expect(ContinuousCorner.reach(radius: 10, smoothing: 0.6) == 16)
    }

    @Test("Smoothing is clamped to 0...1")
    func smoothingClamped() {
        // Out-of-range smoothing arrives from a preference slider, and a
        // negative reach would invert the ramp.
        #expect(ContinuousCorner.reach(radius: 10, smoothing: -3) == 10)
        #expect(ContinuousCorner.reach(radius: 10, smoothing: 4) == 20)
    }

    @Test("A zero radius has no reach")
    func zeroRadius() {
        #expect(ContinuousCorner.reach(radius: 0, smoothing: 0.6) == 0)
    }
}

@Suite("Shapes")
@MainActor
struct ShapeTests {

    private let rect = CGRect(x: 0, y: 0, width: 300, height: 120)

    @Test("The notch shape stays inside its rect")
    func notchStaysInBounds() {
        // The silhouette must never paint outside the panel: anything that
        // escaped would be clipped, and a clipped corner is exactly what a
        // self-intersecting path looks like on screen.
        let path = LedgeShape(bottomRadius: 30, gutterRadius: 11).path(in: rect)
        let bounds = path.boundingRect
        #expect(bounds.minX >= rect.minX - 0.5)
        #expect(bounds.maxX <= rect.maxX + 0.5)
        #expect(bounds.minY >= rect.minY - 0.5)
        #expect(bounds.maxY <= rect.maxY + 0.5)
    }

    @Test("The notch shape survives a radius larger than the rect")
    func notchClampsAbsurdRadius() {
        // The radii are user-tunable and the shape animates through every size
        // between closed and expanded, so an over-large radius is reachable by
        // sliders alone. It must clamp, not self-intersect.
        let path = LedgeShape(bottomRadius: 900, gutterRadius: 400).path(in: rect)
        #expect(!path.isEmpty)
        #expect(path.boundingRect.width <= rect.width + 0.5)
        #expect(path.boundingRect.height <= rect.height + 0.5)
    }

}

/// Formatters that appear on every card. Cheap to get subtly wrong, and wrong
/// in a way that only shows up at the boundaries.
@Suite("Card formatting")
@MainActor
struct CardFormattingTests {

    @Test("Clock pads seconds to two digits")
    func clockPads() {
        #expect(ActivityCardView.clock(0) == "0:00")
        #expect(ActivityCardView.clock(9) == "0:09")
        #expect(ActivityCardView.clock(61) == "1:01")
        #expect(ActivityCardView.clock(600) == "10:00")
    }

    @Test("Clock floors negatives at zero")
    func clockNegative() {
        // Remaining time goes briefly negative between a track ending and the
        // next poll; "-1:-30" would be a visible glitch.
        #expect(ActivityCardView.clock(-5) == "0:00")
    }

    @Test("Relative time reads as a countdown")
    func relative() {
        #expect(ActivityCardView.relative(0) == "now")
        #expect(ActivityCardView.relative(-60) == "now")
        #expect(ActivityCardView.relative(20) == "now")
        #expect(ActivityCardView.relative(15 * 60) == "in 15m")
        #expect(ActivityCardView.relative(60 * 60) == "in 1h")
        #expect(ActivityCardView.relative(90 * 60) == "in 1h 30m")
    }
}

@Suite("What counts as the same card")
@MainActor
struct CardIdentityTests {

    private func activity(_ kind: ActivityKind, _ source: String) -> Activity {
        Activity(id: ActivityID(kind: kind, source: source), createdAt: 0, payload: .message(MessagePayload(title: "x")))
    }

    /// The Clock card is one card wearing three activities — ready, running,
    /// finished — and the provider swaps between them as the user works.
    /// Keyed by activity, starting the stopwatch tore the card down and built
    /// a new one, which flashed and forgot which face was being looked at.
    @Test("Every face of the Clock card is the same card")
    func timerFamilyIsOneCard() {
        let ready = NotchOverlayView.cardIdentity(activity(.timer, "idle"))
        let session = NotchOverlayView.cardIdentity(activity(.timer, "session"))
        let finished = NotchOverlayView.cardIdentity(activity(.timer, "finished"))
        #expect(ready == session)
        #expect(session == finished)
    }

    @Test("Different kinds stay different cards")
    func kindsStayDistinct() {
        #expect(
            NotchOverlayView.cardIdentity(activity(.timer, "session"))
                != NotchOverlayView.cardIdentity(activity(.weather, "session"))
        )
    }

    /// Two players, two cards: cycling between them must still animate as a
    /// change of card rather than one morphing into the other.
    @Test("Two sources of the same kind stay different cards")
    func sourcesStayDistinct() {
        #expect(
            NotchOverlayView.cardIdentity(activity(.nowPlaying, "com.apple.Music"))
                != NotchOverlayView.cardIdentity(activity(.nowPlaying, "com.spotify.client"))
        )
    }
}
