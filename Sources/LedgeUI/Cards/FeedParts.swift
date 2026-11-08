import AppKit
import LedgeCore
import SwiftUI

extension FeedPayload {

    static let fallbackSymbol = "list.bullet.rectangle"

    /// The glyph a feed wears: the producer's, if it names a symbol that
    /// exists, and the feeds glyph otherwise. A misspelt name would draw an
    /// empty tile and an empty header.
    @MainActor
    var displaySymbol: String {
        guard let symbolName, SymbolNames.exists(symbolName) else { return Self.fallbackSymbol }
        return symbolName
    }
}

/// Which SF Symbol names exist, asked once each.
@MainActor
enum SymbolNames {
    private static var known: [String: Bool] = [:]

    static func exists(_ name: String) -> Bool {
        if let answer = known[name] { return answer }
        // A producer could name a new symbol on every write; the cache is
        // only a convenience, so it is not allowed to grow without end.
        if known.count > 256 { known.removeAll() }
        let answer = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        known[name] = answer
        return answer
    }
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
                    tint: FeedEar.color(hex: gauge.color) ?? gauge.level.feedTint,
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
        .accessibilityLabel([gauge.label, gauge.value, gauge.level.spoken].compactMap { $0 }.joined(separator: ", "))
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
/// A side with a fraction is a ring with the producer's words inside it, the
/// way the timer's satellite holds its countdown: the ring says how full, the
/// digits say how much. A side with a fraction and no words is a small ring
/// whose colour says how full it is. A side with only words wears the feed's
/// tile and the words beside it. Both sides read the same either side of the
/// cutout.
struct FeedEar: View {

    enum Side { case leading, trailing }

    let payload: FeedPayload
    let side: Side

    /// What the ring leaves clear above and below it, so it sits in the ear
    /// rather than touching the shape's edge. The satellite fills its whole
    /// circle; an ear is a strip with the notch's own height, and a ring that
    /// went edge to edge in it would read as cut off.
    private static let verticalMargin: CGFloat = 3

    private var text: String? {
        side == .leading ? payload.compactLeading : payload.compactTrailing
    }

    private var fraction: Double? {
        side == .leading ? payload.compactLeadingFraction : payload.compactTrailingFraction
    }

    /// The producer's colour for this side, if it chose one.
    private var fixedTint: Color? {
        Self.color(hex: side == .leading ? payload.compactLeadingColor : payload.compactTrailingColor)
    }

    /// `#RRGGBB` as a colour. The parser has already checked the shape.
    static func color(hex: String?) -> Color? {
        guard let hex, let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var body: some View {
        if let fraction, text == nil {
            bareRing(fraction: fraction)
        } else if let fraction {
            // As tall as the ear comfortably allows, which is the notch's own
            // height on this Mac: 32 on an Air, 38 on a Pro. Measured because
            // a ring that fits one is lost on the other.
            GeometryReader { proxy in
                ring(fraction: fraction, diameter: Self.diameter(forHeight: proxy.size.height))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else if text != nil {
            HStack(spacing: 3) {
                FeedSymbolTile(symbolName: payload.displaySymbol)
                if let text {
                    Text(text)
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(fixedTint ?? payload.level.feedTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
            }
            // Room to breathe either side, as the music tile has: a tile and
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

    /// A ring with no words holds nothing, so it needs no more room than the
    /// timer's dial beside it: about the same outer size and the same stroke.
    static let bareRingDiameter: CGFloat = 18
    private static let bareRingLineWidth: CGFloat = 2.5

    /// The colour of a ring with no words, which is the only thing saying how
    /// much is left: each side by its own fraction, as a battery reads, and
    /// not by the level of the feed as a whole.
    static func bareRingTint(forFraction fraction: Double) -> Color {
        if fraction < 0.15 { return .red }
        if fraction < 0.4 { return .orange }
        return .green
    }

    private func bareRing(fraction: Double) -> some View {
        let tint = fixedTint ?? Self.bareRingTint(forFraction: fraction)
        return FeedRing(
            fraction: fraction,
            tint: tint,
            track: tint.opacity(0.3),
            lineWidth: Self.bareRingLineWidth
        )
        .frame(width: Self.bareRingDiameter, height: Self.bareRingDiameter)
    }

    /// The ring's outer diameter in an ear of this height, when it holds words.
    static func diameter(forHeight height: CGFloat) -> CGFloat {
        guard height.isFinite, height > 0 else { return 25 }
        return min(max(height - 2 * verticalMargin, 20), 34)
    }

    /// The stroke that goes with a diameter. Thinner in a small ring, where
    /// two strokes of 2.5 would leave less than 20pt for the digits.
    static func lineWidth(forDiameter diameter: CGFloat) -> CGFloat {
        min(max(diameter * 0.075, 2), 2.5)
    }

    /// The digits' size, which is the ring's inner room and no more: about 8.5pt
    /// in the ring of an Air and 10 in a Pro's. They are set condensed, because
    /// four characters like "%100" in the ordinary width would need 7pt or less
    /// to fit a ring this small; condensed they fit at about this size, and a
    /// fifth character makes them shrink further.
    static func fontSize(forDiameter diameter: CGFloat) -> CGFloat {
        min(max(diameter * 0.32, 8), 10)
    }

    /// Up to three bare digits have room in the ring, so they can skip the
    /// condensed face longer strings need and match Ledge's rounded numerals.
    static func isPlainNumber(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 3 && text.allSatisfy(\.isNumber)
    }

    /// The size for those digits: a touch under `fontSize`, since a rounded
    /// face at full width looks larger than a condensed one.
    static func plainNumberSize(forDiameter diameter: CGFloat) -> CGFloat {
        min(max(diameter * 0.28, 8), 9)
    }

    /// What the ring leaves for the digits: its inside, less a little air at
    /// each end. Without the air the first and last characters of a long
    /// string touch the stroke.
    static func textWidth(forDiameter diameter: CGFloat) -> CGFloat {
        diameter - 2 * lineWidth(forDiameter: diameter) - 2.5
    }

    private func ring(fraction: Double, diameter: CGFloat) -> some View {
        let lineWidth = Self.lineWidth(forDiameter: diameter)
        let tint = fixedTint ?? payload.level.feedTint
        return ZStack {
            // The timer ear's own dial geometry, with no hand: this is how full
            // something is, not a count of time.
            FeedRing(
                fraction: fraction,
                tint: tint,
                track: tint.opacity(0.3),
                lineWidth: lineWidth
            )
            if let text {
                let plain = Self.isPlainNumber(text)
                Text(text)
                    .font(.system(
                        size: plain ? Self.plainNumberSize(forDiameter: diameter) : Self.fontSize(forDiameter: diameter),
                        weight: plain ? .bold : .semibold,
                        design: plain ? .rounded : .default
                    ))
                    .fontWidth(plain ? .standard : .condensed)
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: Self.textWidth(forDiameter: diameter))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
