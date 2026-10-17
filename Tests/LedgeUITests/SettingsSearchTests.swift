import Foundation
import LedgeCore
import Testing

@testable import LedgeUI

/// What the settings window can find.
@Suite("Searching the settings")
struct SettingsSearchTests {

    private func index(advanced: Bool = false) -> [SettingsSearchHit] {
        SettingsSearch.index(advanced: advanced, cards: [
            ProviderDescriptor(id: "notes", displayName: "Notes", kind: .notes,
                               permission: nil, isEnabled: true, isAvailable: true),
            ProviderDescriptor(id: "keep-awake", displayName: "Keep Awake", kind: .keepAwake,
                               permission: nil, isEnabled: false, isAvailable: true),
        ])
    }

    private func find(_ query: String, advanced: Bool = false) -> [SettingsSearchHit] {
        SettingsSearch.matches(query, in: index(advanced: advanced))
    }

    @Test("The words people actually type land somewhere")
    func theUsualWords() {
        // Each of these is a word somebody would reach for, and none of them
        // is the title of the setting it finds.
        let expected: [(String, SettingsPane)] = [
            ("city", .cards),
            ("startup", .general),
            ("lid", .keepAwake),
            ("screenshot", .general),
            ("dnd", .general),
            ("sparkle", .general),
            ("pomodoro", .cards),
            ("airpods", .devices),
        ]
        for (query, pane) in expected {
            let hits = find(query)
            #expect(!hits.isEmpty, "“\(query)” found nothing")
            #expect(
                hits.contains { $0.pane == pane },
                "“\(query)” found \(hits.map(\.title)) — none of them on \(pane.title)"
            )
        }
    }

    @Test("A card is findable by its own name")
    func cardsAreFindable() {
        #expect(find("notes").contains { $0.row == "card:notes" })
        // And Keep Awake's row leads to its own pane, not into Cards.
        let keepAwake = find("keep awake").first { $0.row == "card:keep-awake" }
        #expect(keepAwake?.pane == .keepAwake)
    }

    @Test("Every word has to match, and only from the start of one")
    func everyWordMatches() {
        // Two words narrow rather than widen.
        #expect(find("volume key").allSatisfy { $0.card == "levels" })
        // A prefix matches; a fragment from the middle does not, or a
        // two-letter query would return most of the window.
        #expect(!find("cit").isEmpty)
        #expect(find("ity").isEmpty)
    }

    @Test("Nothing matches nonsense")
    func nonsense() {
        #expect(find("qqzz").isEmpty)
        #expect(find("   ").isEmpty)
    }

    @Test("Tuning is findable only when it is reachable")
    func tuningFollowsAdvanced() {
        #expect(find("spring", advanced: false).isEmpty, "a pane the sidebar is hiding")
        #expect(!find("spring", advanced: true).isEmpty)
    }

    @Test("Every hit says where it lives")
    func everyHitHasATrail() {
        for hit in index(advanced: true) {
            #expect(!hit.trail.isEmpty)
            if let card = hit.card {
                #expect(
                    hit.trail.contains("›"),
                    "\(hit.title) is on a card page but its trail does not say which: \(hit.trail)"
                )
                #expect(SettingsSearch.cardName(card) != nil, "\(card) has no name for the trail")
            }
        }
    }

    @Test("Nothing is findable twice")
    func noDuplicates() {
        let ids = index(advanced: true).map(\.id)
        #expect(Set(ids).count == ids.count, "two rows claim the same place")
    }
}

/// Where a search result actually lands.
@Suite("Search destinations")
struct SettingsSearchDestinationTests {

    private var index: [SettingsSearchHit] {
        SettingsSearch.index(advanced: true, cards: [])
    }

    private func hit(_ query: String) -> SettingsSearchHit? {
        SettingsSearch.matches(query, in: index).first
    }

    @Test("A tuning result names its tab")
    func tuningResultsCarryTheirTab() {
        // Found by review: every tuning result opened the pane on Shape &
        // Motion, so "ear width" landed on a tab that does not hold it.
        #expect(hit("ear width")?.tuningTab == .ears)
        #expect(hit("hover delay")?.tuningTab == .timing)
        #expect(hit("volume step")?.tuningTab == .timing)
        #expect(hit("corner radius")?.tuningTab == .shape)
        #expect(hit("outline")?.tuningTab == .shape)

        for tuning in index.filter({ $0.pane == .tuning }) {
            #expect(tuning.tuningTab != nil, "\(tuning.title) would open on whichever tab was last")
        }
    }

    @Test("Nothing outside Tuning claims a tuning tab")
    func onlyTuningHasTabs() {
        for other in index.filter({ $0.pane != .tuning }) {
            #expect(other.tuningTab == nil)
        }
    }

    @Test("The controls that must stay findable, one by one")
    func theReachableControlsAreFindable() {
        // Named rather than counted: a fixed index cannot prove completeness,
        // so this is the list somebody has to keep true. Each entry is a
        // control that exists in the window today.
        let mustFind: [(String, SettingsPane)] = [
            ("launch at login", .general),
            ("screenshots", .general),
            ("reset", .general),
            ("check for updates", .general),
            ("source", .general),
            ("tour", .general),
            ("trackpad", .general),
            ("quiet focus", .general),
            ("quit", .general),
            ("opens first", .cards),
            ("city", .cards),
            ("units", .cards),
            ("timer durations", .cards),
            ("web media", .cards),
            ("web compact", .cards),
            ("video compact", .cards),
            ("linger", .cards),
            ("shelf screenshots", .cards),
            ("volume readout", .cards),
            ("brightness readout", .cards),
            ("hide macos readout", .cards),
            ("helper", .keepAwake),
            ("battery floor", .keepAwake),
            ("apps full speed", .keepAwake),
            ("alerts", .devices),
            ("history", .devices),
            ("focus folder", .permissions),
            ("outline", .tuning),
            ("nudge", .tuning),
            ("card height", .tuning),
            ("spring", .tuning),
            ("swipe distance", .tuning),
            ("glow bar", .tuning),
            ("hide tuning", .tuning),
        ]
        for (query, pane) in mustFind {
            let hits = SettingsSearch.matches(query, in: index)
            #expect(!hits.isEmpty, "“\(query)” finds nothing")
            #expect(
                hits.contains { $0.pane == pane },
                "“\(query)” never lands on \(pane.title): \(hits.map(\.title))"
            )
        }
    }
}

/// Every destination search can name has somewhere to land.
@Suite("Search rows exist where they say")
@MainActor
struct SettingsSearchRowTests {

    /// Every pane's source, by the row names it marks with `searchRow`.
    private static func markedRows() -> Set<String> {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/LedgeUI/Settings")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var names: Set<String> = []
        for file in files where file.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: directory.appending(path: file), encoding: .utf8)
            else { continue }
            var rest = Substring(text)
            while let marker = rest.range(of: #".searchRow(""#) {
                rest = rest[marker.upperBound...]
                guard let close = rest.firstIndex(of: "\"") else { break }
                names.insert(String(rest[..<close]))
                rest = rest[close...]
            }
        }
        return names
    }

    @Test("Every search result points at a row some pane actually marks")
    func everyHitHasARow() {
        // Found by review: results carried a row name that no view had ever
        // heard of, so the pane opened and nothing was pointed at. The two
        // dynamic ones are built from ids at runtime and are checked by
        // their own shape instead.
        let marked = Self.markedRows()
        for hit in SettingsSearch.index(advanced: true, cards: []) {
            // The two built from ids at runtime are checked below, by the
            // shape of the mark rather than by a literal: a pane marks
            // `card:\(provider.id)`, which no text search can match against
            // `card:notes`.
            if hit.row.hasPrefix("card:") || hit.row.hasPrefix("perm:") { continue }
            #expect(
                marked.contains(hit.row),
                "“\(hit.title)” points at \(hit.row), which no pane marks"
            )
        }
    }

    @Test("A card's row and a permission's row are marked, by the names search builds")
    func dynamicRowsAreMarked() {
        // These two are built from ids at runtime, so the marks are written
        // with the same interpolation the search index uses. Checked here by
        // their shape, because a pane marks `card:\(provider.id)` rather than
        // any single literal.
        let marked = Self.markedRows()
        #expect(
            marked.contains { $0.hasPrefix("card:") },
            "a card result would open the list and point at nothing"
        )
        #expect(marked.contains { $0.hasPrefix("perm:") })
    }

    @Test("A card result and a permission result are built the way the panes read them")
    func dynamicRowsKeepTheirShape() {
        let cards = [
            ProviderDescriptor(id: "notes", displayName: "Notes", kind: .notes,
                               permission: nil, isEnabled: true, isAvailable: true),
        ]
        let index = SettingsSearch.index(advanced: false, cards: cards)
        #expect(index.contains { $0.row == "card:notes" })
        #expect(index.contains { $0.row == "perm:calendars" })
    }
}
