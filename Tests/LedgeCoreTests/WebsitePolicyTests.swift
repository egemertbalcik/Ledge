import Foundation
import Testing

@testable import LedgeCore

/// Turning what somebody typed into a canonical host. Everything downstream —
/// matching, storage, deduplication — depends on two spellings of one site
/// becoming one value.
@Suite("Reading a website")
struct WebsiteHostTests {

    @Test("A plain host is taken as it is")
    func plainHost() {
        #expect(WebsiteHost("youtube.com")?.value == "youtube.com")
        #expect(WebsiteHost("music.youtube.com")?.value == "music.youtube.com")
    }

    /// The bug this had: `URLComponents("youtube.com/watch")` *succeeds* and
    /// puts the whole thing in `path` with no host, so a `??` fallback never
    /// fired and every scheme-less pasted link was rejected.
    @Test("A scheme-less link still yields its host", arguments: [
        "youtube.com/",
        "youtube.com/watch?v=dQw4w9WgXcQ",
        "youtube.com/watch?v=x#t=30",
        "www.youtube.com/feed/subscriptions",
    ])
    func schemelessLink(text: String) {
        #expect(WebsiteHost(text)?.value == "youtube.com", "could not read \(text)")
    }

    @Test("A scheme-less link to a subdomain keeps the subdomain")
    func schemelessSubdomain() {
        #expect(WebsiteHost("music.youtube.com/path")?.value == "music.youtube.com")
        #expect(WebsiteHost("music.youtube.com/playlist?list=x")?.value == "music.youtube.com")
    }

    @Test("A full URL contributes only its host")
    func fullURL() {
        #expect(
            WebsiteHost("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1s")?.value == "youtube.com"
        )
        #expect(WebsiteHost("http://music.youtube.com/playlist#frag")?.value == "music.youtube.com")
    }

    /// Case, port, path, query, fragment and a trailing dot are all noise: the
    /// site is the same site.
    @Test("Noise is removed", arguments: [
        "YouTube.COM",
        "youtube.com.",
        "youtube.com:443",
        "https://youtube.com/",
        "https://YouTube.com:8080/some/path?q=1#x",
        "  youtube.com  ",
    ])
    func noiseIsRemoved(text: String) {
        #expect(WebsiteHost(text)?.value == "youtube.com", "could not read \(text)")
    }

    /// `www` is a convention, not a site. A rule for `www.youtube.com` that
    /// failed to match `youtube.com` would be a trap.
    @Test("A leading www is dropped, and only a leading one")
    func wwwHandling() {
        #expect(WebsiteHost("www.youtube.com")?.value == "youtube.com")
        #expect(WebsiteHost("https://www.music.youtube.com")?.value == "music.youtube.com")
        // Not a prefix: a site genuinely called this keeps its name.
        #expect(WebsiteHost("wwwx.youtube.com")?.value == "wwwx.youtube.com")
        #expect(WebsiteHost("site.www.com")?.value == "site.www.com")
    }

    @Test("An international name is normalised by Foundation, not by hand")
    func internationalHost() {
        // Punycode either way round: what matters is that one spelling of the
        // site produces one value, and that it is not rejected.
        let unicode = WebsiteHost("münchen.de")
        let punycode = WebsiteHost("xn--mnchen-3ya.de")
        #expect(punycode != nil)
        if let unicode { #expect(unicode == punycode, "two spellings of one site differ") }
    }

    @Test("Malformed entries are rejected", arguments: [
        "", "   ", "youtube", "...", ".com", "youtube..com", "http://", "https:///path",
        "-youtube.com", "youtube-.com", "you tube.com", "user:pass@youtube.com",
    ])
    func malformedRejected(text: String) {
        #expect(WebsiteHost(text) == nil, "accepted \(text)")
    }

    /// Documented decision: addresses and single labels are not websites for
    /// this feature, and a rule for one would read as a site while meaning
    /// something else.
    @Test("Addresses and localhost are rejected", arguments: [
        "localhost", "127.0.0.1", "192.168.1.4", "[::1]", "http://127.0.0.1:8080/",
    ])
    func addressesRejected(text: String) {
        #expect(WebsiteHost(text) == nil, "accepted \(text)")
    }

    @Test("Coverage is matched on label boundaries")
    func coverage() {
        let rule = WebsiteHost("youtube.com")!
        #expect(WebsiteHost("youtube.com")!.isCovered(by: rule))
        #expect(WebsiteHost("music.youtube.com")!.isCovered(by: rule))
        #expect(WebsiteHost("a.b.youtube.com")!.isCovered(by: rule))
    }

    /// The two mistakes a plain suffix comparison makes, in opposite
    /// directions.
    @Test("Neighbouring names are not covered", arguments: [
        "notyoutube.com", "youtube.com.example.org", "myyoutube.com", "youtubex.com",
    ])
    func neighboursNotCovered(text: String) {
        let rule = WebsiteHost("youtube.com")!
        #expect(WebsiteHost(text)?.isCovered(by: rule) == false, "\(text) matched the rule")
    }
}

/// What a website's media may do. Web media is hidden unless its site is
/// allowed; native players are not websites and are not affected.
@Suite("Website policy")
struct WebsitePolicyTests {

    private let youtube = WebsiteHost("youtube.com")!
    private let music = WebsiteHost("music.youtube.com")!
    private let other = WebsiteHost("example.org")!

    private func policy(_ rules: [WebsiteRule]) -> WebsitePolicy {
        WebsitePolicy(rules: rules)
    }

    @Test("An empty policy hides every website")
    func emptyHidesEverything() {
        let policy = WebsitePolicy.hidden
        #expect(policy.allowsCard(ownerIsApp: false, origin: .blobOrigin(youtube)) == false)
        #expect(policy.allowsCompact(ownerIsApp: false, origin: .blobOrigin(youtube)) == false)
        #expect(policy.appearance(ownerIsApp: false, origin: .blobOrigin(youtube)) == nil)
    }

    @Test("An unlisted website stays hidden")
    func unlistedHidden() {
        let policy = self.policy([WebsiteRule(host: youtube, appearance: .cardAndCompact)])
        #expect(policy.allowsCard(ownerIsApp: false, origin: .blobOrigin(other)) == false)
    }

    /// The case Ledge cannot name: no origin, no rule, no card.
    @Test("Media with no known website stays hidden")
    func unknownOriginHidden() {
        let policy = self.policy([WebsiteRule(host: youtube, appearance: .cardAndCompact)])
        #expect(policy.allowsCard(ownerIsApp: false, origin: .none) == false)
        #expect(policy.appearance(ownerIsApp: false, origin: .none) == nil)
    }

    @Test("A native player bypasses the policy entirely")
    func nativeUnaffected() {
        for policy in [WebsitePolicy.hidden, self.policy([WebsiteRule(host: (youtube))])] {
            #expect(policy.allowsCard(ownerIsApp: true, origin: .none))
            #expect(policy.allowsCompact(ownerIsApp: true, origin: .none))
            #expect(policy.appearance(ownerIsApp: true, origin: .none) == .cardAndCompact)
        }
    }

    @Test("Card-only never reaches the compact view")
    func cardOnly() {
        let policy = self.policy([WebsiteRule(host: youtube, appearance: .card)])
        #expect(policy.allowsCard(ownerIsApp: false, origin: .blobOrigin(youtube)))
        #expect(policy.allowsCompact(ownerIsApp: false, origin: .blobOrigin(youtube)) == false)
    }

    @Test("Card-and-compact reaches both")
    func cardAndCompact() {
        let policy = self.policy([WebsiteRule(host: youtube, appearance: .cardAndCompact)])
        #expect(policy.allowsCard(ownerIsApp: false, origin: .blobOrigin(youtube)))
        #expect(policy.allowsCompact(ownerIsApp: false, origin: .blobOrigin(youtube)))
    }

    @Test("A rule covers its subdomains")
    func subdomainsCovered() {
        let policy = self.policy([WebsiteRule(host: youtube, appearance: .card)])
        #expect(policy.allowsCard(ownerIsApp: false, origin: .blobOrigin(music)))
    }

    /// The example from the brief: the longer rule is the one the user meant.
    @Test("The most specific rule wins")
    func mostSpecificWins() {
        let policy = self.policy([
            WebsiteRule(host: youtube, appearance: .card),
            WebsiteRule(host: music, appearance: .cardAndCompact),
        ])
        #expect(policy.appearance(ownerIsApp: false, origin: .blobOrigin(music)) == .cardAndCompact)
        #expect(policy.appearance(ownerIsApp: false, origin: .blobOrigin(youtube)) == .card)
        #expect(
            policy.appearance(ownerIsApp: false, origin: .blobOrigin(WebsiteHost("www.youtube.com")!)) == .card,
            "www is the same site as the apex"
        )
    }

    /// And in the other direction: a specific rule must not leak upwards.
    @Test("A subdomain rule does not cover its parent")
    func subdomainRuleDoesNotCoverParent() {
        let policy = self.policy([WebsiteRule(host: music, appearance: .cardAndCompact)])
        #expect(policy.allowsCard(ownerIsApp: false, origin: .blobOrigin(youtube)) == false)
    }

    @Test("Duplicate hosts collapse to one rule, last wins")
    func duplicatesCollapse() {
        let policy = self.policy([
            WebsiteRule(host: youtube, appearance: .card),
            WebsiteRule(host: WebsiteHost("https://WWW.YouTube.com/feed")!, appearance: .cardAndCompact),
        ])
        #expect(policy.rules.count == 1)
        #expect(policy.appearance(ownerIsApp: false, origin: .blobOrigin(youtube)) == .cardAndCompact)
    }

    @Test("Rules are ordered deterministically")
    func deterministicOrder() {
        let forwards = self.policy([
            WebsiteRule(host: (youtube)), WebsiteRule(host: (music)), WebsiteRule(host: (other)),
        ])
        let backwards = self.policy([
            WebsiteRule(host: (other)), WebsiteRule(host: (music)), WebsiteRule(host: (youtube)),
        ])
        #expect(forwards.rules.map(\.host) == backwards.rules.map(\.host))
    }

    @Test("Setting and removing a rule")
    func settingAndRemoving() {
        var policy = WebsitePolicy.hidden
        policy = policy.setting(WebsiteRule(host: youtube, appearance: .card))
        #expect(policy.rules.count == 1)
        policy = policy.setting(WebsiteRule(host: youtube, appearance: .cardAndCompact))
        #expect(policy.rules.count == 1, "an edit became a second rule")
        #expect(policy.appearance(ownerIsApp: false, origin: .blobOrigin(youtube)) == .cardAndCompact)
        policy = policy.removing(youtube)
        #expect(policy.isEmpty)
    }

    @Test("A rule can be built from typed text, or refused")
    func ruleFromText() {
        #expect(WebsiteRule("https://music.youtube.com/watch?v=x")?.host == music)
        #expect(WebsiteRule("not a host") == nil)
    }
}

/// Storage, migration and reset. Hosts only: a stored rule must never be able
/// to hold a path, a query or anything else from somebody's browsing.
@Suite("Website rules, stored")
@MainActor
struct WebsiteRulePersistenceTests {

    private func rule(_ host: String, _ appearance: WebsiteAppearance) -> WebsiteRule {
        WebsiteRule(host: WebsiteHost(host)!, appearance: appearance)
    }

    @Test("An empty store allows no websites")
    func emptyStoreAllowsNothing() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        #expect(preferences.webMedia.isEmpty)
        #expect(preferences.webMedia.allowsCard(ownerIsApp: false, origin: MediaOriginEvidence.from(host: WebsiteHost("youtube.com")?.value, isBlob: true)) == false)
    }

    @Test("Rules survive a reload, with their appearances")
    func rulesPersist() {
        let store = MemoryPreferenceStore()
        let first = Preferences(store: store)
        first.webMedia = WebsitePolicy(rules: [
            rule("youtube.com", .card), rule("music.youtube.com", .cardAndCompact),
        ])

        let reloaded = Preferences(store: store)
        #expect(reloaded.webMedia.rules.count == 2)
        #expect(
            reloaded.webMedia.appearance(
                ownerIsApp: false, origin: .blobOrigin(WebsiteHost("music.youtube.com")!)
            ) == .cardAndCompact
        )
        #expect(
            reloaded.webMedia.appearance(
                ownerIsApp: false, origin: .blobOrigin(WebsiteHost("youtube.com")!)
            ) == .card
        )
    }

    /// The privacy promise, checked against the stored bytes: a rule entered
    /// as a full URL keeps only its host.
    @Test("No URL, path or query is ever stored")
    func noURLIsStored() {
        let store = MemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.webMedia = WebsitePolicy(rules: [
            WebsiteRule("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=secret")!,
        ])
        let stored = store.value(for: Prefs.websiteRules)
        #expect(stored.contains("youtube.com"))
        for forbidden in ["watch", "dQw4w9WgXcQ", "list", "secret", "https", "?", "/"] {
            #expect(!stored.contains(forbidden), "the stored rule contains \(forbidden)")
        }
    }

    @Test("Stored rules are deduplicated and ordered")
    func storedRulesAreCanonical() {
        let store = MemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.webMedia = WebsitePolicy(rules: [
            rule("music.youtube.com", .card),
            rule("youtube.com", .card),
            WebsiteRule("WWW.YouTube.com")!,
        ])
        let hosts = Preferences(store: store).webMedia.rules.map(\.host.value)
        #expect(hosts == ["music.youtube.com", "youtube.com"])
    }

    @Test("Unreadable stored rules are skipped, not fatal")
    func tolerantDecoding() {
        let store = MemoryPreferenceStore()
        // A host this version cannot canonicalise, beside one it can, plus an
        // appearance from a future version.
        store.set(
            #"[{"host":"youtube.com","appearance":"cardAndCompact"},"#
            + #"{"host":"not a host","appearance":"card"},"#
            + #"{"host":"example.org","appearance":"theatre"}]"#,
            for: Prefs.websiteRules
        )
        let policy = Preferences(store: store).webMedia
        #expect(policy.rules.count == 2, "a bad entry took the list down with it")
        #expect(
            policy.appearance(ownerIsApp: false, origin: .blobOrigin(WebsiteHost("example.org")!)) == .card,
            "an unknown appearance must be read as the smaller of the two"
        )
    }

    @Test("Nonsense in the store is an empty list, not a crash")
    func garbageDecodesEmpty() {
        let store = MemoryPreferenceStore()
        store.set("{not json", for: Prefs.websiteRules)
        #expect(Preferences(store: store).webMedia.isEmpty)
    }

    @Test("The rules key is covered by reset")
    func resetCoversRules() {
        #expect(Prefs.allNames.contains(Prefs.websiteRules.name))
        let store = MemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.webMedia = WebsitePolicy(rules: [rule("youtube.com", .cardAndCompact)])
        preferences.resetToDefaults()
        #expect(preferences.webMedia.isEmpty)
        #expect(Preferences(store: store).webMedia.isEmpty, "a reload resurrected the rules")
    }

    /// An installation that never configured web media gets no rules — and
    /// neither does one that had the old global switch *on*: "every website"
    /// cannot be written as rules without inventing a list nobody named.
    @Test("No old setting becomes a website rule", arguments: [
        ("nowplaying.showWebMediaCards", true),
        ("nowplaying.showWebMediaCards", false),
        ("nowplaying.appMediaOnly", false),
        ("nowplaying.appMediaOnly", true),
        ("nowplaying.hideWebMediaCard", true),
    ])
    func legacySettingsGrantNothing(key: String, value: Bool) {
        let store = MemoryPreferenceStore()
        store.set(value, for: PrefKey<Bool>(key, default: false))
        let preferences = Preferences(store: store)
        #expect(preferences.webMedia.isEmpty, "\(key)=\(value) granted a website rule")
    }

    @Test("An untouched installation has nothing to migrate")
    func untouchedInstallation() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        #expect(preferences.webMedia.isEmpty)
        #expect(preferences.webMediaNoticePending == false, "nothing to explain")
    }

    /// The full first-generation truth table. The middle row is the one a
    /// partial reading missed: cards *were* showing, so that user is owed the
    /// same explanation as anybody else.
    @Test("Every old combination that showed web media raises the notice", arguments: [
        // appMediaOnly, hideWebMediaCard, web media was showing
        (false, false, true),
        (false, true, true),
        (true, false, true),      // cards shown, compact hidden
        (true, true, false),      // the only combination that showed nothing
    ])
    func legacyTruthTable(keptOutOfCompact: Bool, hidTheCard: Bool, wasShowing: Bool) {
        let store = MemoryPreferenceStore()
        store.set(keptOutOfCompact, for: WebMediaMigration.appMediaOnly)
        store.set(hidTheCard, for: WebMediaMigration.hideWebMediaCard)

        let preferences = Preferences(store: store)
        #expect(
            preferences.webMediaNoticePending == wasShowing,
            "appMediaOnly=\(keptOutOfCompact) hideWebMediaCard=\(hidTheCard)"
        )
        #expect(preferences.webMedia.isEmpty, "and it granted a website anyway")
    }

    @Test("The second generation's switch decides on its own", arguments: [true, false])
    func secondGenerationNotice(showed: Bool) {
        let store = MemoryPreferenceStore()
        // Both generations present: the newer pair is the one in force.
        store.set(true, for: WebMediaMigration.appMediaOnly)
        store.set(true, for: WebMediaMigration.hideWebMediaCard)
        store.set(showed, for: WebMediaMigration.showWebMediaCards)
        #expect(Preferences(store: store).webMediaNoticePending == showed)
    }

    /// The notice has to survive the relaunch that follows an update, or the
    /// person who did not open Settings that afternoon never learns why.
    @Test("The notice survives a relaunch")
    func noticeIsDurable() {
        let store = MemoryPreferenceStore()
        store.set(true, for: WebMediaMigration.showWebMediaCards)
        #expect(Preferences(store: store).webMediaNoticePending)
        // A second process against the same store: the old keys are long gone
        // by now, and the notice must still be there.
        #expect(Preferences(store: store).webMediaNoticePending, "the explanation was lost")
    }

    @Test("Dismissing the notice sticks")
    func dismissalIsDurable() {
        let store = MemoryPreferenceStore()
        store.set(true, for: WebMediaMigration.showWebMediaCards)
        let first = Preferences(store: store)
        first.webMediaNoticePending = false
        #expect(Preferences(store: store).webMediaNoticePending == false)
    }

    /// Adding a website answers the question the notice was asking.
    @Test("Adding the first website clears the notice")
    func firstRuleClearsNotice() {
        let store = MemoryPreferenceStore()
        store.set(true, for: WebMediaMigration.showWebMediaCards)
        let preferences = Preferences(store: store)
        #expect(preferences.webMediaNoticePending)
        preferences.webMedia = WebsitePolicy(rules: [WebsiteRule("youtube.com")!])
        #expect(preferences.webMediaNoticePending == false)
        #expect(Preferences(store: store).webMediaNoticePending == false)
    }

    @Test("A fresh explicit choice always wins over the legacy keys")
    func explicitChoiceWins() {
        let store = MemoryPreferenceStore()
        store.set(true, for: WebMediaMigration.showWebMediaCards)
        let first = Preferences(store: store)
        first.webMedia = WebsitePolicy(rules: [WebsiteRule("example.org")!])

        // Relaunch: the rules are the truth, and migration does not run again.
        let second = Preferences(store: store)
        #expect(second.webMedia.rules.map(\.host.value) == ["example.org"])
        #expect(second.webMediaNoticePending == false)
    }

    @Test("The notice is covered by reset")
    func resetClearsNotice() {
        let store = MemoryPreferenceStore()
        store.set(true, for: WebMediaMigration.showWebMediaCards)
        let preferences = Preferences(store: store)
        #expect(preferences.webMediaNoticePending)
        preferences.resetToDefaults()
        #expect(preferences.webMediaNoticePending == false)
        #expect(Prefs.allNames.contains(Prefs.webMediaNoticePending.name))
    }


    @Test("The retired keys are swept")
    func retiredKeysSwept() {
        let store = MemoryPreferenceStore()
        store.set(true, for: PrefKey<Bool>("nowplaying.showWebMediaCards", default: false))
        store.set(true, for: PrefKey<Bool>("nowplaying.appMediaOnly", default: false))
        _ = Preferences(store: store)
        #expect(store.hasValue(named: "nowplaying.showWebMediaCards") == false)
        #expect(store.hasValue(named: "nowplaying.appMediaOnly") == false)
    }
}

/// What the Settings pane does to the list: add, edit, remove, and the
/// orderings that make those read sensibly. Driven through the same policy the
/// pane edits, so the view and this agree by construction.
@Suite("Editing the website list")
@MainActor
struct WebsiteListEditingTests {

    private func store() -> Preferences { Preferences(store: MemoryPreferenceStore()) }

    @Test("Adding websites keeps one rule each, in order")
    func addingWebsites() {
        let preferences = store()
        preferences.webMedia = preferences.webMedia.setting(WebsiteRule("youtube.com")!)
        preferences.webMedia = preferences.webMedia.setting(WebsiteRule("example.org")!)
        #expect(preferences.webMedia.rules.map(\.host.value) == ["example.org", "youtube.com"])
    }

    @Test("Adding a website that is already listed replaces its appearance")
    func addingDuplicateReplaces() {
        let preferences = store()
        preferences.webMedia = preferences.webMedia
            .setting(WebsiteRule("youtube.com", appearance: .card)!)
            .setting(WebsiteRule("https://www.youtube.com/feed", appearance: .cardAndCompact)!)
        #expect(preferences.webMedia.rules.count == 1)
        #expect(preferences.webMedia.rules.first?.appearance == .cardAndCompact)
    }

    /// Editing a rule's website is a rename, not an addition: leaving the old
    /// one behind would be a permission nobody asked for.
    @Test("Renaming a website leaves one rule")
    func renamingLeavesOneRule() {
        let preferences = store()
        preferences.webMedia = preferences.webMedia.setting(WebsiteRule("youtube.com")!)

        let old = WebsiteHost("youtube.com")!
        let renamed = WebsiteRule("music.youtube.com", appearance: .cardAndCompact)!
        preferences.webMedia = preferences.webMedia.removing(old).setting(renamed)

        #expect(preferences.webMedia.rules.map(\.host.value) == ["music.youtube.com"])
        #expect(preferences.webMedia.allowsCard(ownerIsApp: false, origin: .blobOrigin(old)) == false)
    }

    @Test("Removing a website removes only that one")
    func removingOne() {
        let preferences = store()
        preferences.webMedia = WebsitePolicy(rules: [
            WebsiteRule("youtube.com")!, WebsiteRule("example.org")!,
        ])
        preferences.webMedia = preferences.webMedia.removing(WebsiteHost("youtube.com")!)
        #expect(preferences.webMedia.rules.map(\.host.value) == ["example.org"])
    }

    @Test("Changing an appearance does not reorder the list")
    func changingAppearanceKeepsOrder() {
        let preferences = store()
        preferences.webMedia = WebsitePolicy(rules: [
            WebsiteRule("alpha.com")!, WebsiteRule("beta.com")!, WebsiteRule("gamma.com")!,
        ])
        let before = preferences.webMedia.rules.map(\.host.value)
        preferences.webMedia = preferences.webMedia
            .setting(WebsiteRule("beta.com", appearance: .cardAndCompact)!)
        #expect(preferences.webMedia.rules.map(\.host.value) == before)
    }
}

/// An asset URL is not a page. The only URL-shaped thing MediaRemote reports
/// describes the *media*, and the media for a YouTube video comes from
/// `googlevideo.com` — so taking its host for the website gets it wrong in
/// both directions: the real site never matches, and a CDN host would
/// authorise every unrelated site sharing it.
@Suite("What counts as knowing the website")
struct MediaOriginEvidenceTests {

    private let youtube = WebsiteHost("youtube.com")!

    @Test("Nothing reported is no evidence")
    func nothingReported() {
        #expect(MediaOriginEvidence.from(host: nil, isBlob: false) == MediaOriginEvidence.none)
        #expect(MediaOriginEvidence.from(host: nil, isBlob: true) == MediaOriginEvidence.none)
        #expect(MediaOriginEvidence.none.verifiedWebsite == nil)
        #expect(MediaOriginEvidence.none.hasAnyHost == false)
    }

    @Test("A blob origin is evidence of a website")
    func blobOrigin() {
        let evidence = MediaOriginEvidence.from(host: "music.youtube.com", isBlob: true)
        #expect(evidence == .blobOrigin(WebsiteHost("music.youtube.com")!))
        #expect(evidence.verifiedWebsite?.value == "music.youtube.com")
    }

    /// The blocker, in one test: a CDN host is recorded and never matched.
    @Test("A direct asset URL is not evidence of a website", arguments: [
        "googlevideo.com", "rr3---sn-4g5e6nsz.googlevideo.com",
        "d2wrhdhlxnsn6a.cloudfront.net", "video-weaver.lhr03.hls.ttvnw.net",
    ])
    func directAssetIsNotEvidence(host: String) {
        let evidence = MediaOriginEvidence.from(host: host, isBlob: false)
        #expect(evidence.hasAnyHost, "the host is still recorded")
        #expect(
            evidence.verifiedWebsite == nil,
            "\(host) was treated as the website in the tab"
        )
    }

    /// And the consequence: a rule cannot be matched by a CDN, even one whose
    /// host the user happens to have listed.
    @Test("A rule is never matched by a direct asset host")
    func ruleNotMatchedByCDN() {
        let policy = WebsitePolicy(rules: [
            WebsiteRule(host: WebsiteHost("googlevideo.com")!, appearance: .cardAndCompact),
            WebsiteRule(host: youtube, appearance: .cardAndCompact),
        ])
        let cdn = MediaOriginEvidence.from(host: "googlevideo.com", isBlob: false)
        #expect(
            policy.allowsCard(ownerIsApp: false, origin: cdn) == false,
            "an asset host authorised itself"
        )
        // The same host, had it genuinely been a page origin, would match.
        let asPage = MediaOriginEvidence.from(host: "googlevideo.com", isBlob: true)
        #expect(policy.allowsCard(ownerIsApp: false, origin: asPage))
    }

    @Test("A host that is not a website is no evidence at all", arguments: [
        "localhost", "127.0.0.1", "not a host", "",
    ])
    func unusableHosts(host: String) {
        #expect(MediaOriginEvidence.from(host: host, isBlob: true) == MediaOriginEvidence.none)
    }

    /// A blob whose inner URL is not a web resource — a file, a malformed
    /// string — leaves nothing behind.
    @Test("Malformed and non-web origins are no evidence")
    func malformedOrigins() {
        // What the helper would pass on for `blob:file:///x` or `blob:` alone:
        // nothing, because neither yields an http(s) host.
        #expect(MediaOriginEvidence.from(host: nil, isBlob: true) == MediaOriginEvidence.none)
        #expect(MediaOriginEvidence.from(host: "/", isBlob: true) == MediaOriginEvidence.none)
        #expect(MediaOriginEvidence.from(host: "file", isBlob: true) == MediaOriginEvidence.none)
    }

    /// Evidence carries a host and nothing else — no path or query can reach
    /// it, because none ever travels this far.
    @Test("Evidence holds only a host")
    func evidenceIsHostOnly() {
        let evidence = MediaOriginEvidence.from(
            host: "music.youtube.com", isBlob: true
        )
        // The case name says "blobOrigin" — that is the provenance, not a URL.
        // What must not appear is anything from a *location*: a scheme, a
        // path, a query, a fragment.
        let described = String(describing: evidence)
        for forbidden in ["watch", "?", "#", "https:", "//", "/"] {
            #expect(!described.contains(forbidden), "evidence described as \(described)")
        }
    }

    /// Native media has no website and needs none: the policy lets it through
    /// whatever the evidence says.
    @Test("A native player is unaffected by any evidence", arguments: [
        MediaOriginEvidence.none,
        .directAsset(WebsiteHost("googlevideo.com")!),
        .blobOrigin(WebsiteHost("youtube.com")!),
    ])
    func nativeUnaffected(evidence: MediaOriginEvidence) {
        #expect(WebsitePolicy.hidden.allowsCard(ownerIsApp: true, origin: evidence))
    }
}
