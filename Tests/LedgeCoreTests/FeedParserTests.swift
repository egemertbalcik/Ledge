import Foundation
@testable import LedgeCore
import Testing

/// The file a script writes, read into the card the notch draws.
@Suite("Feed files")
struct FeedParserTests {

    /// 2026-11-06 12:00:00 UTC, in Unix seconds.
    private let now: TimeInterval = 1_794_052_800

    private func parse(
        _ json: String,
        fallbackID: String = "from-filename",
        fallbackUpdatedAt: TimeInterval = 0
    ) -> Result<FeedParser.Feed, FeedParser.Rejection> {
        FeedParser.parse(
            Data(json.utf8), fallbackID: fallbackID,
            fallbackUpdatedAt: fallbackUpdatedAt, now: now
        )
    }

    private func feed(
        _ json: String,
        fallbackID: String = "from-filename",
        fallbackUpdatedAt: TimeInterval = 0
    ) -> FeedParser.Feed? {
        guard case .success(let feed) = parse(json, fallbackID: fallbackID, fallbackUpdatedAt: fallbackUpdatedAt)
        else { return nil }
        return feed
    }

    // MARK: - Fixed colours

    @Test("A side's colour is read only as #RRGGBB")
    func compactColours() {
        let good = feed(##"{"version":1,"compact_leading_color":"#D97757","compact_trailing_color":"#2F80ED"}"##)
        #expect(good?.payload.compactLeadingColor == "#D97757")
        #expect(good?.payload.compactTrailingColor == "#2F80ED")
        for bad in ["D97757", "#D9775", "#D977577", "#GGGGGG", "orange", ""] {
            let parsed = feed(#"{"version":1,"compact_leading_color":"\#(bad)"}"#)
            #expect(parsed?.payload.compactLeadingColor == nil, "\(bad)")
        }
    }

    // MARK: - What a whole file says

    @Test("A complete file reads field for field")
    func completeFile() throws {
        let json = """
        {
          "version": 1,
          "id": "limits",
          "title": "Limits",
          "symbol": "gauge.with.dots.needle.67percent",
          "compact_leading": "C 90%",
          "compact_trailing": "G ~100%",
          "compact_leading_fraction": 0.9,
          "compact_trailing_fraction": 1,
          "level": "warning",
          "gauges": [
            {"label": "Claude", "value": "90%", "fraction": 0.9, "level": "warning"},
            {"label": "Gemini", "value": "~100%", "fraction": 1, "level": "critical"}
          ],
          "rows": [
            {"label": "Claude 5h", "value": "10% used", "detail": "resets 05:00",
             "fraction": 0.10, "level": "normal"},
            {"label": "Gemini", "value": "~100%", "fraction": 1, "level": "critical"}
          ],
          "updated_at": 1794052700,
          "stale_after": 43200
        }
        """
        let parsed = try #require(feed(json))
        #expect(parsed.id == "limits")
        let payload = parsed.payload
        #expect(payload.title == "Limits")
        #expect(payload.symbolName == "gauge.with.dots.needle.67percent")
        #expect(payload.compactLeading == "C 90%")
        #expect(payload.compactTrailing == "G ~100%")
        #expect(payload.compactLeadingFraction == 0.9)
        #expect(payload.compactTrailingFraction == 1)
        #expect(payload.level == .warning)
        #expect(payload.gauges == [
            FeedGauge(label: "Claude", value: "90%", fraction: 0.9, level: .warning),
            FeedGauge(label: "Gemini", value: "~100%", fraction: 1, level: .critical),
        ])
        #expect(payload.updatedAt == 1_794_052_700)
        #expect(payload.staleAfter == 43_200)
        #expect(!payload.isStale)
        #expect(payload.rows == [
            FeedRow(label: "Claude 5h", value: "10% used", detail: "resets 05:00",
                    fraction: 0.10, level: .normal),
            FeedRow(label: "Gemini", value: "~100%", fraction: 1, level: .critical),
        ])
    }

    @Test("Only the version is required")
    func minimalFile() throws {
        let parsed = try #require(feed(#"{"version": 1}"#, fallbackID: "limits", fallbackUpdatedAt: 1_794_000_000))
        #expect(parsed.id == "limits", "the file's name stands in for an id")
        let payload = parsed.payload
        #expect(payload.title == "limits", "and for a title")
        #expect(payload.symbolName == nil)
        #expect(!payload.hasCompactContent)
        #expect(payload.compactLeadingFraction == nil)
        #expect(payload.compactTrailingFraction == nil)
        #expect(payload.level == .normal)
        #expect(payload.gauges.isEmpty)
        #expect(payload.rows.isEmpty)
        #expect(payload.updatedAt == 1_794_000_000, "the file's own date stands in for updated_at")
        #expect(payload.staleAfter == nil)
        #expect(!payload.isStale)
    }

    @Test("A row's optional fields may all be missing")
    func bareRow() throws {
        let json = #"{"version": 1, "rows": [{"label": "Disk", "value": "81%"}]}"#
        let row = try #require(feed(json)?.payload.rows.first)
        #expect(row == FeedRow(label: "Disk", value: "81%"))
        #expect(row.detail == nil)
        #expect(row.fraction == nil)
        #expect(row.level == .normal)
    }

    @Test("Fields this version does not know are ignored")
    func unknownFields() throws {
        let json = """
        {"version": 1, "title": "T", "colour": "teal", "extra": {"a": [1, 2]},
         "rows": [{"label": "A", "value": "1", "sparkline": [1, 2, 3]}]}
        """
        let payload = try #require(feed(json)?.payload)
        #expect(payload.title == "T")
        #expect(payload.rows.count == 1)
    }

    // MARK: - What is turned away

    @Test("Text that is not JSON is turned away")
    func notJSON() {
        #expect(parse("not json") == .failure(.notAnObject))
        #expect(parse("") == .failure(.notAnObject))
        // Half a file: a producer that wrote in place and was read mid-write.
        #expect(parse(#"{"version": 1, "title": "Lim"#) == .failure(.notAnObject))
    }

    @Test("JSON that is not an object is turned away")
    func notAnObject() {
        #expect(parse("[1, 2, 3]") == .failure(.notAnObject))
        #expect(parse("42") == .failure(.notAnObject))
        #expect(parse("null") == .failure(.notAnObject))
    }

    @Test("A file with no version is turned away")
    func missingVersion() {
        #expect(parse(#"{"title": "No version"}"#) == .failure(.missingVersion))
        #expect(parse(#"{"version": "1"}"#) == .failure(.missingVersion), "a string is not a version")
    }

    @Test("A version this Ledge does not read is turned away", arguments: [2, 3, 99, 0, -1])
    func unsupportedVersion(version: Int) {
        #expect(parse(#"{"version": \#(version), "title": "Future"}"#) == .failure(.unsupportedVersion(version)))
    }

    @Test("A file over 64 KB is turned away without being read")
    func oversize() {
        let padding = String(repeating: " ", count: FeedParser.maxBytes)
        let json = #"{"version": 1}"# + padding
        #expect(parse(json) == .failure(.oversize(bytes: json.utf8.count)))
    }

    @Test("A file of exactly 64 KB is the largest that is read")
    func largestAllowed() {
        let base = #"{"version": 1}"#
        let json = base + String(repeating: " ", count: FeedParser.maxBytes - base.utf8.count)
        #expect(json.utf8.count == FeedParser.maxBytes)
        #expect(feed(json) != nil)
    }

    // MARK: - Strings

    @Test("Blank and non-string text counts as absent")
    func blankText() throws {
        let json = """
        {"version": 1, "id": "  ", "title": "", "symbol": 7,
         "compact_leading": "   ", "compact_trailing": null}
        """
        let parsed = try #require(feed(json, fallbackID: "file"))
        #expect(parsed.id == "file")
        #expect(parsed.payload.title == "file")
        #expect(parsed.payload.symbolName == nil)
        #expect(!parsed.payload.hasCompactContent)
    }

    @Test("Text is trimmed and cut to what a card has room for")
    func longText() throws {
        let long = String(repeating: "x", count: 5_000)
        let json = #"{"version": 1, "title": "  Padded  ", "compact_leading": "\#(long)"}"#
        let payload = try #require(feed(json)?.payload)
        #expect(payload.title == "Padded")
        #expect(payload.compactLeading?.count == FeedParser.Limit.compact)
    }

    // MARK: - Rows

    @Test("A row without a label or a value is dropped, and the rest stay")
    func brokenRows() throws {
        let json = """
        {"version": 1, "rows": [
          {"label": "Kept", "value": "1"},
          {"value": "no label"},
          {"label": "no value"},
          {"label": "number value", "value": 5},
          "not even an object",
          {"label": "Also kept", "value": "2"}
        ]}
        """
        let rows = try #require(feed(json)?.payload.rows)
        #expect(rows.map(\.label) == ["Kept", "Also kept"])
    }

    @Test("A card draws at most eight rows")
    func rowCap() throws {
        let rows = (1...12).map { #"{"label": "R\#($0)", "value": "\#($0)"}"# }.joined(separator: ",")
        let payload = try #require(feed(#"{"version": 1, "rows": [\#(rows)]}"#)?.payload)
        #expect(payload.rows.count == FeedPayload.maxRows)
        #expect(payload.rows.map(\.label) == (1...8).map { "R\($0)" })
    }

    @Test("A fraction is held to 0...1, and a non-number draws no bar")
    func fractions() throws {
        let json = """
        {"version": 1, "rows": [
          {"label": "a", "value": "1", "fraction": 1.7},
          {"label": "b", "value": "1", "fraction": -0.2},
          {"label": "c", "value": "1", "fraction": "half"},
          {"label": "d", "value": "1", "fraction": 0.5}
        ]}
        """
        let rows = try #require(feed(json)?.payload.rows)
        #expect(rows.map(\.fraction) == [1, 0, nil, 0.5])
    }

    // MARK: - Gauges

    @Test("A gauge needs a label, a value and a fraction")
    func gaugeNeedsItsThree() throws {
        let json = """
        {"version": 1, "gauges": [
          {"label": "Kept", "value": "10%", "fraction": 0.1},
          {"value": "10%", "fraction": 0.1},
          {"label": "no value", "fraction": 0.1},
          {"label": "no fraction", "value": "10%"},
          {"label": "string fraction", "value": "10%", "fraction": "0.1"},
          {"label": "number value", "value": 10, "fraction": 0.1},
          "not an object",
          {"label": "Also kept", "value": "20%", "fraction": 0.2}
        ]}
        """
        let gauges = try #require(feed(json)?.payload.gauges)
        #expect(gauges.map(\.label) == ["Kept", "Also kept"])
    }

    @Test("A gauge reads a fixed colour")
    func gaugeColour() throws {
        let json = ##"{"version": 1, "gauges": [{"label": "A", "value": "1", "fraction": 0.1, "color": "#D97757"}, {"label": "B", "value": "2", "fraction": 0.2, "color": "blue"}]}"##
        let payload = try #require(feed(json)?.payload)
        #expect(payload.gauges.map(\.color) == ["#D97757", nil])
    }

    @Test("A card draws at most four gauges, counted after the broken ones are dropped")
    func gaugeCap() throws {
        let broken = #"{"label": "broken", "value": "1%"}"#
        let good = (1...5).map { #"{"label": "G\#($0)", "value": "\#($0)%", "fraction": 0.\#($0)}"# }
        let json = #"{"version": 1, "gauges": [\#(([broken] + good).joined(separator: ","))]}"#
        let payload = try #require(feed(json)?.payload)
        #expect(payload.gauges.count == FeedPayload.maxGauges)
        #expect(payload.gauges.map(\.label) == ["G1", "G2", "G3", "G4"])
    }

    @Test("A gauge's fraction is held to 0...1, and its level reads like a row's")
    func gaugeFractionAndLevel() throws {
        let json = """
        {"version": 1, "gauges": [
          {"label": "a", "value": "1", "fraction": 3},
          {"label": "b", "value": "1", "fraction": -1, "level": "Critical"},
          {"label": "c", "value": "1", "fraction": 0.5, "level": "dire"}
        ]}
        """
        let gauges = try #require(feed(json)?.payload.gauges)
        #expect(gauges.map(\.fraction) == [1, 0, 0.5])
        #expect(gauges.map(\.level) == [.normal, .critical, .normal])
    }

    @Test("Gauge text is cut to what a ring has room for")
    func gaugeText() throws {
        let long = String(repeating: "x", count: 500)
        let json = #"{"version": 1, "gauges": [{"label": "\#(long)", "value": "\#(long)", "fraction": 0.5}]}"#
        let gauge = try #require(feed(json)?.payload.gauges.first)
        #expect(gauge.label.count == FeedParser.Limit.gaugeLabel)
        #expect(gauge.value.count == FeedParser.Limit.gaugeValue)
    }

    @Test("A gauges field that is not a list draws no gauges")
    func gaugesNotAList() throws {
        for value in ["7", #""many""#, #"{"label": "a"}"#, "null"] {
            let payload = try #require(feed(#"{"version": 1, "gauges": \#(value)}"#)?.payload)
            #expect(payload.gauges.isEmpty, "gauges \(value)")
        }
    }

    // MARK: - Rings in the closed notch

    @Test("The compact fractions are held to 0...1, and a non-number is no ring")
    func compactFractions() throws {
        let json = #"{"version": 1, "compact_leading_fraction": 4, "compact_trailing_fraction": -2}"#
        let payload = try #require(feed(json)?.payload)
        #expect(payload.compactLeadingFraction == 1)
        #expect(payload.compactTrailingFraction == 0)

        let nonsense = try #require(feed(
            #"{"version": 1, "compact_leading_fraction": "half", "compact_trailing_fraction": null}"#
        )?.payload)
        #expect(nonsense.compactLeadingFraction == nil)
        #expect(nonsense.compactTrailingFraction == nil)
    }

    @Test("A ring with no words is still something to say in the ears")
    func ringAlone() throws {
        let payload = try #require(feed(#"{"version": 1, "compact_trailing_fraction": 0.4}"#)?.payload)
        #expect(payload.compactTrailing == nil)
        #expect(payload.hasCompactContent)
    }

    // MARK: - Levels

    @Test("Levels read as the words they are", arguments: [
        ("normal", FeedLevel.normal), ("warning", .warning), ("critical", .critical),
        ("CRITICAL", .critical), ("Warning", .warning),
    ])
    func knownLevels(word: String, level: FeedLevel) throws {
        let json = #"{"version": 1, "level": "\#(word)", "rows": [{"label": "a", "value": "1", "level": "\#(word)"}]}"#
        let payload = try #require(feed(json)?.payload)
        #expect(payload.level == level)
        #expect(payload.rows.first?.level == level)
    }

    @Test("A level nobody knows is normal, not alarming")
    func unknownLevels() throws {
        let json = """
        {"version": 1, "level": "catastrophic",
         "rows": [{"label": "a", "value": "1", "level": 3}, {"label": "b", "value": "1", "level": ""}]}
        """
        let payload = try #require(feed(json)?.payload)
        #expect(payload.level == .normal)
        #expect(payload.rows.allSatisfy { $0.level == .normal })
    }

    // MARK: - Freshness

    @Test("Inside stale_after a feed is fresh, past it the feed is stale")
    func staleComputation() throws {
        // Written 2 hours before `now`, good for 1 hour: stale by an hour.
        let stale = try #require(feed(#"{"version": 1, "updated_at": 1794045600, "stale_after": 3600}"#)?.payload)
        #expect(stale.isStale)
        #expect(stale.staleDeadline == 1_794_049_200)

        // Good for 4 hours: still true.
        let fresh = try #require(feed(#"{"version": 1, "updated_at": 1794045600, "stale_after": 14400}"#)?.payload)
        #expect(!fresh.isStale)
    }

    @Test("The deadline itself is not yet stale")
    func staleBoundary() {
        let payload = FeedPayload(title: "t", updatedAt: 1_000, staleAfter: 60)
        #expect(!payload.isPastDeadline(at: 1_060))
        #expect(payload.isPastDeadline(at: 1_060.5))
    }

    @Test("A feed that never said how long it stays true is never stale")
    func neverStale() throws {
        let payload = try #require(feed(#"{"version": 1, "updated_at": 1000}"#)?.payload)
        #expect(payload.staleAfter == nil)
        #expect(!payload.isStale)
        #expect(!payload.isPastDeadline(at: .greatestFiniteMagnitude))
    }

    @Test("A stale_after that is not a positive number is ignored")
    func nonsenseStaleAfter() throws {
        for value in ["0", "-5", #""soon""#, "null"] {
            let payload = try #require(feed(#"{"version": 1, "updated_at": 1000, "stale_after": \#(value)}"#)?.payload)
            #expect(payload.staleAfter == nil, "stale_after \(value)")
            #expect(!payload.isStale)
        }
    }

    @Test("A missing or nonsense updated_at falls back to the file's date")
    func updatedAtFallback() throws {
        for json in [
            #"{"version": 1}"#,
            #"{"version": 1, "updated_at": 0}"#,
            #"{"version": 1, "updated_at": -4}"#,
            #"{"version": 1, "updated_at": "yesterday"}"#,
        ] {
            let payload = try #require(feed(json, fallbackUpdatedAt: 1_793_000_000)?.payload)
            #expect(payload.updatedAt == 1_793_000_000, "\(json)")
        }
    }

    @Test("The file's date makes a feed stale like any other")
    func fallbackDateGoesStale() throws {
        let payload = try #require(feed(#"{"version": 1, "stale_after": 60}"#, fallbackUpdatedAt: now - 3_600)?.payload)
        #expect(payload.isStale)
    }

    @Test("Settling against a later moment is what makes a feed stale")
    func settling() {
        let payload = FeedPayload(title: "t", updatedAt: 1_000, staleAfter: 60)
        #expect(!payload.settled(at: 1_030).isStale)
        #expect(payload.settled(at: 1_100).isStale)
        #expect(payload.settled(at: 1_100).settled(at: 1_030).isStale == false, "and back again")
    }
}
