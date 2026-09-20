import LedgeCore
import SwiftUI
import os

/// A ruler you drag to set a timer's length.
///
/// The obvious thing here is iOS's wheel of numbers. It is the wrong shape for
/// this card: a wheel needs vertical room the notch does not have, and it
/// shows five values where a card this wide can show forty. A tape rule shows
/// the neighbourhood of the number — where five minutes is, how far an hour
/// is — and it is the instrument a timer already resembles.
///
/// The marker stands still and the rule moves under it, which is the way a
/// physical dial reads: pulling left brings larger numbers toward you.
struct DurationDialView: View {

    @Binding var minutes: Int

    /// The card's accent — orange for a timer, green for a break.
    let tint: Color

    /// Latches the shell's hover so the card cannot close mid-drag when the
    /// pointer leaves it. The same latch the volume sliders use.
    let setDragging: (Bool) -> Void

    /// One tick as the value crosses a minute — the same feedback the number
    /// gives when it crosses a detent, so the two ways of setting a length
    /// feel like one instrument.
    var haptic: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the drag started, and how far it has gone. Held apart so the rule
    /// can slide continuously while the number lands on whole minutes.
    @State private var anchor: Int?
    @State private var translation: CGFloat = 0
    /// The last few samples of the drag, for the speed at the moment of
    /// release. Only the tail matters, so the list is trimmed as it goes.
    @State private var samples: [(translation: CGFloat, time: TimeInterval)] = []
    @State private var glide: Task<Void, Never>?
    /// Whether this view has actually latched the shell for a drag.
    ///
    /// The dial remains in the hierarchy at zero height while the ruler is
    /// closed. Its `onDisappear` therefore also runs when somebody merely
    /// switches away from the timer card. Emitting `setDragging(false)` for
    /// that non-interaction made the timer interpret teardown as the end of a
    /// drag and take a fresh post-drag hold. Keep the callback balanced: a
    /// release is sent only after this instance sent the matching acquire.
    @State private var hasDragLatch = false

    private var position: CGFloat {
        guard let anchor else { return CGFloat(minutes) }
        return DurationDial.position(anchor: anchor, translation: translation)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack {
                // A shallow trough, so the rule reads as something set into
                // the card and dragged, rather than ticks floating on it.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(0.06))
                rule(width: width)
                marker
            }
            .frame(width: width, height: Self.height)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .gesture(drag)
            // A flick that outlives its rule would go on setting a value
            // nobody can see, and go on holding the card open to do it.
            .onDisappear { settle() }
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel("Timer length")
        .accessibilityValue(DurationDial.spoken(minutes))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(by: 1)
            case .decrement: nudge(by: -1)
            @unknown default: break
            }
        }
        // Arrow keys move the dial for anyone not using a pointer; shift takes
        // the five-minute steps the taller ticks mark.
        .focusable()
        // The system ring is drawn as a rectangle around the whole strip and
        // reads as an error state on a black card. Focus shows in the marker
        // instead, which is where the eye already is.
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { nudge(by: -1); return .handled }
        .onKeyPress(.rightArrow) { nudge(by: 1); return .handled }
        .onKeyPress(keys: [.upArrow]) { _ in nudge(by: DurationDial.majorEvery); return .handled }
        .onKeyPress(keys: [.downArrow]) { _ in nudge(by: -DurationDial.majorEvery); return .handled }
    }

    /// The rule's own height. Internal because the card reveals the rule by
    /// growing a window to exactly this, rather than by sliding it in over
    /// whatever is above it.
    static let height: CGFloat = 34

    // MARK: - The rule

    private func rule(width: CGFloat) -> some View {
        Canvas { context, size in
            let centre = size.width / 2
            let step = DurationDial.pointsPerMinute
            // Only what can be seen, plus a tick either side so nothing pops
            // in at the edges.
            let reach = Int(centre / step) + 2
            let current = Int(position.rounded())

            for minute in (current - reach)...(current + reach) {
                guard DurationDial.range.contains(minute) else { continue }
                let x = centre + (CGFloat(minute) - position) * step
                let isMajor = minute % DurationDial.majorEvery == 0
                let length: CGFloat = isMajor ? 16 : 9
                // The rule fades toward its ends rather than being cut off, so
                // the marker stays the brightest thing on the card.
                let distance = abs(x - centre) / centre
                let fade = max(0, 1 - distance * distance)
                let opacity = (isMajor ? 0.75 : 0.32) * fade

                let top = 4.0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: top))
                tick.addLine(to: CGPoint(x: x, y: top + length))
                context.stroke(
                    tick,
                    with: .color(.white.opacity(opacity)),
                    style: StrokeStyle(lineWidth: isMajor ? 1.5 : 1, lineCap: .round)
                )

                guard minute % DurationDial.labelEvery == 0, fade > 0.15 else { continue }
                let text = Text("\(minute)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5 * fade))
                context.draw(text, at: CGPoint(x: x, y: top + length + 8), anchor: .center)
            }
        }
        .frame(width: width, height: Self.height)
        .animation(reduceMotion ? nil : .interactiveSpring(duration: 0.2), value: minutes)
    }

    /// The one bright thing: where the value is read.
    private var marker: some View {
        VStack(spacing: 0) {
            Capsule(style: .continuous)
                .fill(tint)
                .frame(width: 2.5, height: 22)
                .shadow(color: tint.opacity(0.6), radius: 4)
            Spacer(minLength: 0)
        }
        .padding(.top, 1)
        .allowsHitTesting(false)
    }

    // MARK: - Dragging

    private var drag: some Gesture {
        // Zero minimum distance so the rule answers the press itself, not the
        // press plus a few points — a dial that ignores small movements feels
        // stuck rather than precise.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if anchor == nil {
                    // A touch stops whatever the last flick was still doing,
                    // the way catching a scroll view does.
                    glide?.cancel()
                    glide = nil
                    anchor = minutes
                    samples = []
                    if !hasDragLatch {
                        hasDragLatch = true
                        setDragging(true)
                    }
                }
                translation = value.translation.width
                note(translation)
                apply(translation)
            }
            .onEnded { value in
                // Reduce Motion asks for less travel, and a glide is travel
                // nobody asked for by hand.
                guard !reduceMotion else { return settle() }
                note(value.translation.width)
                startGlide(
                    reported: Double(value.velocity.width),
                    measured: RulerGlide.velocity(from: samples)
                )
            }
    }

    private func nudge(by delta: Int) {
        glide?.cancel()
        glide = nil
        minutes = DurationDial.clamp(minutes + delta)
    }

    /// Records where the drag is, and forgets what is too old to matter.
    private func note(_ translation: CGFloat) {
        let now = Date().timeIntervalSinceReferenceDate
        samples.append((translation, now))
        samples.removeAll { now - $0.time > 0.2 }
    }

    /// Moves the value to wherever the rule now sits.
    private func apply(_ translation: CGFloat) {
        let landed = DurationDial.minutes(anchor: anchor ?? minutes, translation: translation)
        guard landed != minutes else { return }
        minutes = landed
        haptic()
    }

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "ruler")

    /// Carries the rule on after the hand lifts, and settles when it stops.
    private func startGlide(reported: Double, measured: Double) {
        let velocity = RulerGlide.release(reported: reported, measured: measured)
        if DebugSwitches.tracing("ruler") {
            Self.log.notice("""
                ruler: release reported=\(reported, privacy: .public) \
                measured=\(measured, privacy: .public) \
                used=\(velocity, privacy: .public) \
                samples=\(samples.count, privacy: .public)
                """)
        }
        var motion = RulerGlide(velocity: velocity)
        guard motion.isGliding else { return settle() }

        glide?.cancel()
        glide = Task { @MainActor in
            var last = Date().timeIntervalSinceReferenceDate
            var travel: CGFloat = 0
            var steps = 0
            while !Task.isCancelled, motion.isGliding {
                // A frame at a time. The step takes the elapsed time rather
                // than assuming it, so a busy frame slows nothing down.
                try? await Task.sleep(for: .milliseconds(8))
                guard !Task.isCancelled else { break }
                let now = Date().timeIntervalSinceReferenceDate
                let travelled = motion.step(now - last)
                last = now
                travel += travelled
                steps += 1

                let before = minutes
                translation += travelled
                apply(translation)
                // The range is a wall, not a spring: at either end the glide
                // is over rather than bouncing or grinding on silently.
                if minutes == before,
                   minutes == DurationDial.range.lowerBound
                    || minutes == DurationDial.range.upperBound {
                    motion.stop()
                }
            }
            guard !Task.isCancelled else {
                if DebugSwitches.tracing("ruler") { Self.log.notice("ruler: glide cancelled") }
                return
            }
            if DebugSwitches.tracing("ruler") {
                Self.log.notice(
                    """
                    ruler: glide finished travel=\(travel, privacy: .public)pt \
                    steps=\(steps, privacy: .public) \
                    minutes=\(minutes, privacy: .public)
                    """
                )
            }
            settle()
        }
    }

    /// The rule comes to rest: the number is already where it should be, so
    /// this only puts the rule back on a whole minute and lets the card go.
    private func settle() {
        glide?.cancel()
        glide = nil
        anchor = nil
        translation = 0
        samples = []
        guard hasDragLatch else { return }
        hasDragLatch = false
        setDragging(false)
    }
}
