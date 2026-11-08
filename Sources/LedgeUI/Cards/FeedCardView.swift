import LedgeCore
import SwiftUI

extension FeedLevel {

    /// The level in words, for VoiceOver: colour alone says nothing there.
    /// Nil while all is well.
    var spoken: String? {
        switch self {
        case .normal: nil
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    /// A glyph beside a value when the user has asked for more than colour.
    var glyph: String? {
        switch self {
        case .normal: nil
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    /// How a level is drawn, in the app's own colours: white while all is
    /// well, the way the battery ring is, and colour only when there is
    /// something to say about it.
    var feedTint: Color {
        switch self {
        case .normal: .white.opacity(0.85)
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// The card for a feed: a title, the readings the producer wants seen first as
/// rings across the top, and a row for each of the rest.
///
/// Laid out the way the weather card is: a header with how old it is, a hero
/// that is the point of the card, a hairline, and a quieter strip underneath.
/// A feed is a status somebody else keeps, so the card says how old it is, and
/// goes dim when the producer's own `stale_after` has run out. The age is the
/// one thing that stays at full strength then, in orange — a card whose
/// numbers have stopped being true should say so more clearly than it says
/// them.
public struct FeedCardView: View {

    private let payload: FeedPayload

    @Environment(\.colorSchemeContrast) private var contrast

    public init(payload: FeedPayload) {
        self.payload = payload
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !payload.gauges.isEmpty {
                HStack(spacing: 0) {
                    ForEach(payload.gauges.indices, id: \.self) { index in
                        FeedGaugeView(gauge: payload.gauges[index])
                            // Equal columns, so the rings are spread evenly
                            // whether there are one, two or three.
                            .frame(maxWidth: .infinity)
                    }
                }
                .opacity(dimmed)
                .padding(.top, NotchLayout.feedGaugesGap)
            }

            if !payload.rows.isEmpty {
                if !payload.gauges.isEmpty {
                    // The hairline the weather card sets over its hourly strip.
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(height: 1)
                        .padding(.vertical, NotchLayout.feedDividerPadding)
                }
                VStack(alignment: .leading, spacing: NotchLayout.feedRowSpacing) {
                    ForEach(payload.rows.indices, id: \.self) { index in
                        FeedRowView(row: payload.rows[index])
                    }
                }
                .opacity(dimmed)
                .padding(.top, payload.gauges.isEmpty ? NotchLayout.feedHeaderGap : 0)
            }
        }
        // The same margins as the other cards that measure themselves, and
        // counted in `NotchLayout.feedsContentHeight` so that the card opens at
        // the height it will measure.
        .padding(.horizontal, 8)
        .padding(.vertical, NotchLayout.feedPadding / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dimmed: Double { payload.isStale ? 0.5 : 1 }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: payload.displaySymbol)
                    .font(.cardTitle)
                    .foregroundStyle(payload.level.feedTint)
                    .accessibilityHidden(true)
                Text(payload.title)
                    .font(.cardTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    // The name wins the room, as the weather's city does.
                    .layoutPriority(1)
                    .accessibilityValue(payload.isStale ? "Out of date" : "")
            }
            .opacity(dimmed)
            freshness
            Spacer(minLength: 0)
        }
        .frame(height: NotchLayout.feedHeaderHeight)
    }

    /// Whose card this is, and how long ago it was written: "Feed · Just now"
    /// while fresh, "Feed · Updated 12m ago" once the difference matters.
    ///
    /// "Feed" is always there. Another program writes this card, and it can
    /// call itself anything and wear any symbol — "Battery", a battery glyph,
    /// critical — so the card says plainly that it is not one of Ledge's own.
    ///
    /// The age is always on show too: a producer that has died keeps its last
    /// numbers on screen, and the age is what admits it. A feed with no date
    /// says nothing about its age rather than something false.
    @ViewBuilder
    private var freshness: some View {
        if payload.updatedAt > 0 {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let age = context.date.timeIntervalSince1970 - payload.updatedAt
                // Never abbreviated, but giving ground rather than taking it
                // from the title: the full phrase where it fits, then the age.
                ViewThatFits(in: .horizontal) {
                    freshnessText(Self.freshnessText(age: age, prefixed: true))
                    freshnessText(Self.freshnessText(age: age, prefixed: false))
                    freshnessText(Self.mark)
                }
            }
        } else {
            freshnessText(Self.mark)
        }
    }

    private func freshnessText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(payload.isStale ? Color.orange : Color.white.opacity(contrast == .increased ? 0.6 : 0.35))
            .fixedSize(horizontal: true, vertical: false)
    }

    static let mark = "Feed"

    static func freshnessText(age: TimeInterval, prefixed: Bool) -> String {
        if age < 120 { return "\(mark) · Just now" }
        let ago = WeatherCardView.ago(age)
        return prefixed ? "\(mark) · Updated \(ago) ago" : "\(mark) · \(ago) ago"
    }
}

/// One line of a feed card, with its bar under it when it has a fraction.
///
/// Quieter than the gauges above it: the label in secondary white at the left,
/// the value at the right, and a note beside the value in tertiary. When there
/// is not room for all three, the note is what gives way, then the label; the
/// value never does.
struct FeedRowView: View {

    let row: FeedRow

    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColour
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.label)
                    .font(.cardBody)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let detail = row.detail {
                    Text(detail)
                        .font(.cardBody)
                        .foregroundStyle(.white.opacity(contrast == .increased ? 0.65 : 0.4))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if withoutColour, let glyph = row.level.glyph {
                    Image(systemName: glyph)
                        .font(.cardSmallFigure)
                        .foregroundStyle(row.level.feedTint)
                        .accessibilityHidden(true)
                }
                // First claim on the room, but not more than the row has: a
                // long value truncates rather than drawing past the card.
                Text(row.value)
                    .font(.cardSmallFigure)
                    .monospacedDigit()
                    .foregroundStyle(row.level.feedTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)
            }
            .frame(height: NotchLayout.feedRowHeight)

            if let fraction = row.fraction {
                ProgressBar(progress: fraction, tint: row.level.feedTint)
                    .frame(height: 3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.level.spoken ?? "")
    }
}
