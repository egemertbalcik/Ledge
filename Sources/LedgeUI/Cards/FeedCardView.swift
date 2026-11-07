import LedgeCore
import SwiftUI

extension FeedLevel {

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

/// The card for a feed: a title, and a row for each thing the producer wants
/// watched.
///
/// A feed is a status somebody else keeps, so the card says how old it is, and
/// goes dim when the producer's own `stale_after` has run out. The freshness
/// is the one thing that stays at full strength then — a card whose numbers
/// have stopped being true should say so more clearly than it says them.
public struct FeedCardView: View {

    private let payload: FeedPayload

    public init(payload: FeedPayload) {
        self.payload = payload
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !payload.rows.isEmpty {
                VStack(alignment: .leading, spacing: NotchLayout.feedRowSpacing) {
                    ForEach(payload.rows.indices, id: \.self) { index in
                        FeedRowView(row: payload.rows[index])
                    }
                }
                .opacity(payload.isStale ? 0.5 : 1)
                .padding(.top, NotchLayout.feedHeaderGap)
            }
        }
        // The same margins as the other cards that measure themselves, and
        // counted in `NotchLayout.feedsContentHeight` so that the card opens at
        // the height it will measure.
        .padding(.horizontal, 8)
        .padding(.vertical, NotchLayout.feedPadding / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: payload.symbolName ?? "list.bullet.rectangle")
                    .font(.cardTitle)
                    .foregroundStyle(payload.level.feedTint)
                    .accessibilityHidden(true)
                Text(payload.title)
                    .font(.cardTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .opacity(payload.isStale ? 0.5 : 1)
            Spacer(minLength: 8)
            freshness
        }
        .frame(height: NotchLayout.feedHeaderHeight)
    }

    /// How long ago the producer wrote. Always on show, for the reason the
    /// weather card's is: a producer that has died keeps its last numbers on
    /// screen, and the age is what admits it. A feed with no date says
    /// nothing rather than something false.
    @ViewBuilder
    private var freshness: some View {
        if payload.updatedAt > 0 {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let age = context.date.timeIntervalSince1970 - payload.updatedAt
                Text(Self.freshnessText(age: age, isStale: payload.isStale))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(payload.isStale ? 0.75 : 0.35))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    static func freshnessText(age: TimeInterval, isStale: Bool) -> String {
        if age < 120 { return "Just now" }
        let ago = WeatherCardView.ago(age)
        return isStale ? "Updated \(ago) ago" : "\(ago) ago"
    }
}

/// One line of a feed card, with its bar under it when it has a fraction.
struct FeedRowView: View {

    let row: FeedRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.label)
                    .font(.cardBody)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail = row.detail {
                    Text(detail)
                        .font(.cardBody)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                // The value is what the row is for, so it keeps its room when
                // the label and the detail are fighting over what is left.
                Text(row.value)
                    .font(.cardSmallFigure)
                    .monospacedDigit()
                    .foregroundStyle(row.level.feedTint)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .frame(height: NotchLayout.feedRowHeight)

            if let fraction = row.fraction {
                ProgressBar(progress: fraction, tint: row.level.feedTint)
                    .frame(height: 3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
