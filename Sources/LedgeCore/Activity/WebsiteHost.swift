import Foundation

/// A website, reduced to the one part worth storing: its host.
///
/// Never a URL. Ledge keeps rules about *sites*, so a path, a query or a
/// fragment is both unnecessary and somebody's browsing history — this type
/// exists so there is no shape in the model that could hold one.
///
/// Canonical means: lowercased, no scheme, no port, no path, no query, no
/// fragment, no trailing dot, and no leading `www.`. Two spellings of the same
/// site therefore produce the same value, which is what makes rules
/// deduplicable and comparable.
public struct WebsiteHost: Hashable, Sendable, Codable, Comparable {

    /// The canonical host, always non-empty.
    ///
    /// Whatever Foundation returns for the name, lowercased: it decodes
    /// punycode, so `xn--mnchen-3ya.de` and `münchen.de` both canonicalise to
    /// the same Unicode spelling. Foundation's normalisation *is* the
    /// boundary here — a homemade one would be a second, worse implementation
    /// of a standard, and the browser's own host arrives through the same
    /// normalisation, so the two always agree.
    public let value: String

    private init(canonical: String) {
        self.value = canonical
    }

    /// Builds a host from whatever the user typed, or nil if it cannot be
    /// read as one.
    ///
    /// Accepts a bare host (`youtube.com`), a full URL
    /// (`https://www.youtube.com/watch?v=…`), and the untidy things people
    /// paste in between: trailing dots, mixed case, ports, trailing slashes.
    /// Rejects anything that is not a hostname with at least two labels — see
    /// `init?(_:)`'s notes on addresses and single labels.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return nil }
        guard let host = Self.host(from: trimmed) else { return nil }

        var candidate = host.lowercased()
        // A fully-qualified name may end in a dot. `youtube.com.` and
        // `youtube.com` are the same site, and storing both would be two rules
        // for one place.
        while candidate.hasSuffix(".") { candidate.removeLast() }
        // `www` is a convention, not a site. Keeping it would mean a rule for
        // `www.youtube.com` that silently failed to match `youtube.com`.
        if candidate.hasPrefix("www.") { candidate.removeFirst(4) }

        guard Self.isPlausibleHostname(candidate) else { return nil }
        self.init(canonical: candidate)
    }

    /// Pulls the host out of a URL, or takes the text as a host itself.
    ///
    /// Foundation does the URL work, including punycode for international
    /// names: a homemade parser here would be a second, worse implementation
    /// of something the system already knows how to do.
    private static func host(from text: String) -> String? {
        // Parsed as written first — but only accepted if that actually
        // produced a *host*.
        //
        // `URLComponents("youtube.com/watch")` succeeds and puts the whole
        // thing in `path` with no host at all, so a `??` fallback here never
        // fired and every scheme-less pasted link was rejected. Success is not
        // the test; a host is.
        if let components = URLComponents(string: text), let host = components.host {
            return credentialFree(components) ? host : nil
        }
        // No host of its own: a bare name, or a scheme-less link. A scheme
        // lets Foundation parse and normalise it — including an international
        // name, which it decodes for us.
        guard let components = URLComponents(string: "https://" + text),
              let host = components.host
        else { return nil }
        return credentialFree(components) ? host : nil
    }

    /// Whether this carries no credentials.
    ///
    /// `user:pass@host` is not something to save a rule for: it is a
    /// credential in a preference file, and the shape itself usually means the
    /// text was not a website address.
    private static func credentialFree(_ components: URLComponents) -> Bool {
        components.user == nil && components.password == nil
    }

    /// Whether this is a hostname Ledge will keep a rule for.
    ///
    /// Two labels at least, letters or digits or hyphens in each, and nothing
    /// that is really an address.
    ///
    /// **Addresses and single labels are rejected on purpose.** `localhost`,
    /// `192.168.1.4` and `[::1]` are development and local-network targets,
    /// not the websites this feature is about, and a rule for one of them
    /// would read as a site while meaning something else. Somebody who needs
    /// media from a local server is not served by a per-website allow list.
    private static func isPlausibleHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        // IPv6 arrives bracketed from URLComponents; IPv4 is four numbers.
        guard !host.contains(":"), !host.contains("["), !host.contains("]") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            // Letters, digits and hyphens — Unicode letters included, because
            // Foundation hands back the decoded form of an international name
            // and that decoded form is what gets stored and compared.
            // Everything else (spaces, slashes, colons, `@`, punctuation) is
            // how a URL fragment or a typo gets in, and is refused.
            let allowed = label.allSatisfy { character in
                character.isLetter || character.isNumber || character == "-"
            }
            guard allowed else { return false }
        }
        return true
    }

    /// Whether this host is the given rule's host or sits beneath it.
    ///
    /// Matched on label boundaries, which is the whole point: `youtube.com`
    /// covers `music.youtube.com` and must never cover `notyoutube.com` or
    /// `youtube.com.example.org`. A plain suffix comparison gets both of those
    /// wrong, in opposite and equally bad directions.
    public func isCovered(by rule: WebsiteHost) -> Bool {
        if value == rule.value { return true }
        return value.hasSuffix("." + rule.value)
    }

    /// How many labels this host has. The specificity a rule is ranked by.
    public var labelCount: Int {
        value.split(separator: ".").count
    }

    public static func < (lhs: WebsiteHost, rhs: WebsiteHost) -> Bool {
        lhs.value < rhs.value
    }

    public var description: String { value }
}
