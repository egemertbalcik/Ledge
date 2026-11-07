import CoreGraphics
import Foundation
import LedgeCore
import Testing

/// What a feed card is on the queue: whether it rests in the ears, whether
/// arriving is news, where it sits, and how tall it is.
@Suite("Feed activities")
struct FeedActivityTests {

    private func feed(
        _ source: String,
        leading: String? = "C 90%",
        trailing: String? = nil,
        level: FeedLevel = .normal,
        updatedAt: TimeInterval = 1_000,
        stale: Bool = false
    ) -> Activity {
        Activity(
            id: ActivityID(kind: .feeds, source: source),
            createdAt: 0,
            payload: .feeds(FeedPayload(
                title: source,
                compactLeading: leading,
                compactTrailing: trailing,
                level: level,
                updatedAt: updatedAt,
                isStale: stale
            ))
        )
    }

    private func other(_ kind: ActivityKind, _ payload: ActivityPayload) -> Activity {
        Activity(id: ActivityID(kind: kind, source: "x"), createdAt: 0, payload: payload)
    }

    // MARK: - The ears

    @Test("A feed rests in the ears only with something to say there")
    func restsWithCompactText() {
        #expect(feed("a", leading: "C 90%", trailing: nil).restsInEars)
        #expect(feed("a", leading: nil, trailing: "G 10%").restsInEars)
        #expect(!feed("a", leading: nil, trailing: nil).restsInEars)
    }

    @Test("A stale feed gives up the ears")
    func staleDoesNotRest() {
        #expect(!feed("a", stale: true).restsInEars)
    }

    // MARK: - What is news

    @Test("A feed arriving is not an announcement, whatever its level")
    func arrivalIsQuiet() {
        for level in FeedLevel.allCases {
            #expect(!feed("a", level: level).isWorthAnnouncing)
        }
    }

    // MARK: - Ordering

    @Test("A feed sits after the cards the app makes and ahead of the controls")
    func priority() {
        #expect(ActivityKind.feeds.defaultPriority < ActivityKind.keepAwake.defaultPriority)
        #expect(ActivityKind.feeds.defaultPriority > ActivityKind.levels.defaultPriority)
    }

    @Test("A feed republishing in place neither moves nor steals the selection")
    func republishingIsQuiet() {
        var queue = ActivityQueue()
        queue.upsert(other(.weather, .weather(WeatherPayload(temperatureCelsius: 20))))
        queue.upsert(feed("a", leading: "1"))
        queue.upsert(feed("b", leading: "2"))
        let order = queue.activities.map(\.id)
        let selected = queue.selectedID

        queue.upsert(feed("a", leading: "9", level: .critical))
        #expect(queue.activities.map(\.id) == order)
        #expect(queue.selectedID == selected)
    }

    @Test("A feed with only a ring for the ears still rests there")
    func ringRests() {
        let ringOnly = Activity(
            id: ActivityID(kind: .feeds, source: "ring"),
            createdAt: 0,
            payload: .feeds(FeedPayload(title: "t", compactTrailingFraction: 0.5))
        )
        #expect(ringOnly.restsInEars)
    }

    // MARK: - The card's height

    @Test("The card is as tall as what is on it, and no taller")
    func contentHeight() {
        let row = FeedRow(label: "a", value: "1")
        let bar = FeedRow(label: "a", value: "1", fraction: 0.5)
        let bare = NotchLayout.feedsContentHeight(gaugeCount: 0, rows: [])
        let one = NotchLayout.feedsContentHeight(gaugeCount: 0, rows: [row])
        let withBar = NotchLayout.feedsContentHeight(gaugeCount: 0, rows: [bar])
        let two = NotchLayout.feedsContentHeight(gaugeCount: 0, rows: [row, row])
        #expect(bare == NotchLayout.feedPadding + NotchLayout.feedHeaderHeight)
        #expect(one == bare + NotchLayout.feedHeaderGap + NotchLayout.feedRowHeight)
        #expect(withBar == one + NotchLayout.feedBarHeight)
        #expect(two == one + NotchLayout.feedRowSpacing + NotchLayout.feedRowHeight)
    }

    @Test("Gauges add one row of rings, and a hairline only when rows follow")
    func gaugeHeight() {
        let row = FeedRow(label: "a", value: "1")
        let bare = NotchLayout.feedsContentHeight(gaugeCount: 0, rows: [])
        let ringsOnly = NotchLayout.feedsContentHeight(gaugeCount: 2, rows: [])
        #expect(ringsOnly == bare + NotchLayout.feedGaugesGap + NotchLayout.feedGaugesHeight)
        // Two gauges are one row of rings, as three are.
        #expect(NotchLayout.feedsContentHeight(gaugeCount: 3, rows: []) == ringsOnly)

        let both = NotchLayout.feedsContentHeight(gaugeCount: 2, rows: [row])
        #expect(both == ringsOnly + NotchLayout.feedDividerHeight + NotchLayout.feedRowHeight)
        // The hairline takes the place of the header's gap above the rows.
        let rowsOnly = NotchLayout.feedsContentHeight(gaugeCount: 0, rows: [row])
        #expect(both - ringsOnly != rowsOnly - bare)
    }

    @Test("Three gauges and eight rows with a bar each still fit under the card's ceiling")
    func tallestCard() {
        let rows = (0..<FeedPayload.maxRows).map {
            FeedRow(label: "r\($0)", value: "\($0)", fraction: 0.5)
        }
        let content = NotchLayout.feedsContentHeight(gaugeCount: FeedPayload.maxGauges, rows: rows)
        let height = NotchLayout.feedsHeight(content)
        #expect(height == NotchLayout.referenceNotchHeight + content + NotchLayout.dotsBand,
                "the ceiling must not be the thing that sets it")
        #expect(height <= 400)
        // And the same on a Pro's taller cutout.
        let pro = NotchLayout.feedsHeight(content, notchHeight: 38)
        #expect(pro == 38 + content + NotchLayout.dotsBand)
    }

    @Test("A card that has not measured itself opens at a fixed height")
    func unmeasured() {
        #expect(NotchLayout.feedsHeight(0) == 140)
        #expect(NotchLayout.feedsHeight(.nan) == 140)
        // A Pro's taller cutout moves it by the difference.
        #expect(NotchLayout.feedsHeight(0, notchHeight: 38) == 146)
    }

    @Test("The card opens at the height its payload is worth before it reports")
    func opensAtEstimate() {
        let payload = FeedPayload(
            title: "t",
            gauges: [FeedGauge(label: "g", value: "1%", fraction: 0.01)],
            rows: [
                FeedRow(label: "a", value: "1", fraction: 0.2),
                FeedRow(label: "b", value: "2"),
            ]
        )
        let geometry = NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: 735.5,
            isHardwareNotch: true
        )
        func size(payload: ActivityPayload?, measured: CGFloat = 0) -> CGSize {
            NotchLayout.cardSize(
                kind: .feeds, phase: .expanded, base: CGSize(width: 315, height: 125),
                payload: payload, cardContentHeight: measured, geometry: geometry,
                routePickerRows: 0, hasSelection: true
            )
        }
        let estimated = size(payload: .feeds(payload))
        let measured = size(
            payload: nil,
            measured: NotchLayout.feedsContentHeight(gaugeCount: 1, rows: payload.rows)
        )
        #expect(estimated == measured)
        #expect(estimated != size(payload: nil), "and not the fixed height an unmeasured card gets")
    }
}
