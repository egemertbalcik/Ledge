import Foundation

/// How much of the notch one website may have.
public enum WebsiteAppearance: String, Hashable, Sendable, Codable, CaseIterable {

    /// A card to cycle to, and nothing resting in the ears.
    case card

    /// A card, and a place in the compact view like a player's.
    case cardAndCompact

    /// Whether this appearance includes the compact view. `cardAndCompact`
    /// implies `card` — there is no "compact without a card", because the
    /// compact view is what a card rests in.
    public var allowsCompact: Bool { self == .cardAndCompact }

    public var title: String {
        switch self {
        case .card: "Card"
        case .cardAndCompact: "Card and compact view"
        }
    }
}

/// One website the user has allowed, and how far.
public struct WebsiteRule: Hashable, Sendable, Codable, Identifiable {

    public var id: WebsiteHost { host }

    public let host: WebsiteHost
    public var appearance: WebsiteAppearance

    public init(host: WebsiteHost, appearance: WebsiteAppearance = .card) {
        self.host = host
        self.appearance = appearance
    }

    /// Builds a rule from typed text, or nil if it is not a website.
    public init?(_ text: String, appearance: WebsiteAppearance = .card) {
        guard let host = WebsiteHost(text) else { return nil }
        self.init(host: host, appearance: appearance)
    }
}

/// What a website's media may do, resolved from the user's rules.
///
/// Web media is hidden unless its website is allowed. That is the default and
/// the point: a browser holds one now-playing slot for every tab and hands it
/// around, so what arrives is often not what anybody chose to play. An allow
/// list turns "anything in a browser" into "the handful of sites I actually
/// listen to".
///
/// Pure and clockless. Everything downstream — publication, the card queue,
/// the ears, handover, opening the browser — asks this one type, so the four
/// decisions cannot drift apart.
public struct WebsitePolicy: Equatable, Sendable {

    /// The rules, deduplicated by canonical host and ordered by it.
    public let rules: [WebsiteRule]

    public init(rules: [WebsiteRule] = []) {
        // Deduplicated by canonical host — two spellings of one site are one
        // rule — and ordered, so the list reads the same on every launch and
        // in every test. Last one wins: an edit is an overwrite.
        var byHost: [WebsiteHost: WebsiteRule] = [:]
        for rule in rules { byHost[rule.host] = rule }
        self.rules = byHost.values.sorted { $0.host < $1.host }
    }

    /// Nothing allowed: the default, and what an empty preference store means.
    public static let hidden = WebsitePolicy()

    /// The rule that governs a host, which is the most specific one covering
    /// it.
    ///
    /// `music.youtube.com` beats `youtube.com` for a page on the former,
    /// because the user who wrote the longer rule meant it. Specificity is the
    /// label count, and ties cannot happen: two rules with the same host are
    /// one rule.
    public func rule(for host: WebsiteHost) -> WebsiteRule? {
        rules
            .filter { host.isCovered(by: $0.host) }
            .max { $0.host.labelCount < $1.host.labelCount }
    }

    /// What this media may do.
    ///
    /// - Parameters:
    ///   - ownerIsApp: true for a native player. Those bypass this policy
    ///     entirely — Music, Spotify and Podcasts are not websites and are not
    ///     affected by a website list.
    ///   - origin: what is known about where the media came from. Only
    ///     evidence that stands for a web content origin can match a rule —
    ///     an asset URL on an ordinary CDN matches nothing, however plausible
    ///     its host looks. Unknown means hidden: a page Ledge cannot name is a
    ///     page the user cannot have allowed.
    public func appearance(
        ownerIsApp: Bool,
        origin: MediaOriginEvidence
    ) -> WebsiteAppearance? {
        if ownerIsApp { return .cardAndCompact }
        guard let host = origin.verifiedWebsite else { return nil }
        return rule(for: host)?.appearance
    }

    /// Whether this media may have a card at all.
    public func allowsCard(ownerIsApp: Bool, origin: MediaOriginEvidence) -> Bool {
        appearance(ownerIsApp: ownerIsApp, origin: origin) != nil
    }

    /// Whether it may also hold the compact view.
    public func allowsCompact(ownerIsApp: Bool, origin: MediaOriginEvidence) -> Bool {
        appearance(ownerIsApp: ownerIsApp, origin: origin)?.allowsCompact ?? false
    }

    /// Adds or replaces a rule, keeping the order and the deduplication.
    public func setting(_ rule: WebsiteRule) -> WebsitePolicy {
        WebsitePolicy(rules: rules + [rule])
    }

    /// Removes a website's rule.
    public func removing(_ host: WebsiteHost) -> WebsitePolicy {
        WebsitePolicy(rules: rules.filter { $0.host != host })
    }

    public var isEmpty: Bool { rules.isEmpty }
}
