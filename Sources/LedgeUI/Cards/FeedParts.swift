import LedgeCore
import SwiftUI

extension FeedPayload {

    /// The glyph a feed wears when its producer named none.
    var displaySymbol: String { symbolName ?? "list.bullet.rectangle" }
}

/// A ring that fills clockwise from twelve o'clock to a fraction.
///
/// One ring for the card's gauges and the ears' mini rings, in the shape the
/// timer's satellite wears: a quiet full round, with the progress drawn over
/// it in a round-capped stroke of the same width. Only the size differs.
struct FeedRing: View {

    /// 0...1.
    let fraction: Double
    let tint: Color
    let track: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // From twelve o'clock, like every clock face and the dial.
                .rotationEffect(.degrees(-90))
                // A round cap on a zero-length arc is still a dot, and a ring
                // at nothing should be empty.
                .opacity(fraction > 0 ? 1 : 0)
        }
        // The stroke is centred on the circle's edge, so it is drawn inside the
        // frame it was given rather than half outside it.
        .padding(lineWidth / 2)
        .animation(Motion.slow, value: fraction)
    }
}

/// One gauge of a feed card: the value inside its ring, the label under it.
///
/// The card's visual anchor, as the big temperature is the weather card's.
struct FeedGaugeView: View {

    let gauge: FeedGauge

    var body: some View {
        VStack(spacing: NotchLayout.feedGaugeSpacing) {
            ZStack {
                FeedRing(
                    fraction: gauge.fraction,
                    tint: gauge.level.feedTint,
                    track: .white.opacity(0.15),
                    lineWidth: 4
                )
                // White whatever the level: the ring carries it, and the number
                // is the one thing that has to stay readable.
                Text(gauge.value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 5)
            }
            .frame(width: NotchLayout.feedGaugeDiameter, height: NotchLayout.feedGaugeDiameter)

            Text(gauge.label)
                .font(.cardCaption)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .frame(height: NotchLayout.feedGaugeLabelHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(gauge.label), \(gauge.value)")
    }
}

/// A feed's glyph on a small tile, the way the music ears wear the cover.
///
/// Neutral whatever the feed's level: when a feed turns critical, its ring and
/// its words go red and nothing else about the ear changes.
struct FeedSymbolTile: View {

    let symbolName: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(
                    colors: [.white.opacity(0.26), .white.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Image(systemName: symbolName)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(width: 15, height: 15)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// One side of a feed in the closed notch.
///
/// A ring and the producer's words beside it, when the side has a fraction;
/// the feed's tile and its words, when it has only words. Both sides read left
/// to right, ring or tile first, so the two ears are one phrase either side of
/// the cutout.
struct FeedEar: View {

    enum Side { case leading, trailing }

    let payload: FeedPayload
    let side: Side

    private var text: String? {
        side == .leading ? payload.compactLeading : payload.compactTrailing
    }

    private var fraction: Double? {
        side == .leading ? payload.compactLeadingFraction : payload.compactTrailingFraction
    }

    var body: some View {
        if text != nil || fraction != nil {
            HStack(spacing: 2.5) {
                if let fraction {
                    // The timer ear's own dial geometry, with no hand: this is
                    // how full something is, not a count of time.
                    FeedRing(
                        fraction: fraction,
                        tint: payload.level.feedTint,
                        track: payload.level.feedTint.opacity(0.3),
                        lineWidth: 2.4
                    )
                    .frame(width: 14, height: 14)
                } else {
                    FeedSymbolTile(symbolName: payload.displaySymbol)
                }
                if let text {
                    Text(text)
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(payload.level.feedTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
            }
            // Room to breathe either side, as the music tile has: a ring and
            // three digits are most of an ear, and words longer than that
            // shrink rather than reach for the shape's corner.
            .frame(maxWidth: 42)
        } else if side == .leading {
            // Nothing for this side, so it says whose ears these are.
            FeedSymbolTile(symbolName: payload.displaySymbol)
        } else if payload.level != .normal, !payload.hasCompactContent {
            // A feed with nothing for the ears that is nonetheless standing the
            // notch up — turning critical — would otherwise be a tile and an
            // empty ear.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.cardLabel)
                .foregroundStyle(payload.level.feedTint)
        }
    }
}
