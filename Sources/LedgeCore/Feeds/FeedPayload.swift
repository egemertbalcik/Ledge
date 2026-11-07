import Foundation

/// How much a feed, or one of its rows, wants to be looked at.
///
/// Three steps and no more. A producer that needs a finer scale has a number
/// to put in the row's value; what the notch needs to decide is only whether
/// to draw something in white, in orange or in red.
public enum FeedLevel: String, Equatable, Sendable, Codable, CaseIterable {
    case normal
    case warning
    case critical

    /// Reads the word a producer wrote. A word this version does not know —
    /// a producer on a newer schema, or a typo — is `normal`: drawing a row in
    /// white is a quiet mistake, drawing it in red is a loud one.
    public init(word: String?) {
        self = word.flatMap { FeedLevel(rawValue: $0.lowercased()) } ?? .normal
    }
}

/// One line of a feed card: a label, what it is at, and optionally how far
/// along that is.
public struct FeedRow: Equatable, Sendable, Codable {
    public var label: String
    public var value: String

    /// A short note beside the value — when it resets, what it is waiting for.
    public var detail: String?

    /// 0...1, drawn as a thin bar under the row. Nil draws no bar.
    public var fraction: Double?

    public var level: FeedLevel

    public init(
        label: String,
        value: String,
        detail: String? = nil,
        fraction: Double? = nil,
        level: FeedLevel = .normal
    ) {
        self.label = label
        self.value = value
        self.detail = detail
        // Clamped here so no view has to: a bar wider than its track is a
        // producer's arithmetic, not something to draw.
        self.fraction = fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        self.level = level
    }
}

/// What a feed card draws: a title, a few rows, and how fresh they are.
///
/// Feeds are files other programs write, so this is the app's own picture of
/// one rather than the file's — `FeedParser` turns the second into the first,
/// and nothing past it knows what the file looked like.
public struct FeedPayload: Equatable, Sendable, Codable {

    /// The most rows a card draws. A card that grows with its producer's
    /// enthusiasm stops being a glance.
    public static let maxRows = 8

    public var title: String

    /// An SF Symbol name, as the producer wrote it. Whether it exists is the
    /// view's problem: the core has no symbols to check it against.
    public var symbolName: String?

    /// Short text for the left and right of the cutout when the notch is
    /// closed. Either, both or neither.
    public var compactLeading: String?
    public var compactTrailing: String?

    /// The feed as a whole, which is not necessarily the worst of its rows:
    /// the producer knows what its numbers mean.
    public var level: FeedLevel

    public var rows: [FeedRow]

    /// When the producer last wrote, in Unix seconds. Unix and not the app's
    /// reference date, because a file written by a shell script has no idea
    /// when 2001 began.
    public var updatedAt: TimeInterval

    /// How long after `updatedAt` the numbers stop being true, if the
    /// producer said.
    public var staleAfter: TimeInterval?

    /// Whether `staleAfter` had run out when this was published.
    ///
    /// Stored rather than derived because the core has no clock: the provider
    /// is the one place that knows what time it is, and it republishes when
    /// the answer changes.
    public var isStale: Bool

    public init(
        title: String,
        symbolName: String? = nil,
        compactLeading: String? = nil,
        compactTrailing: String? = nil,
        level: FeedLevel = .normal,
        rows: [FeedRow] = [],
        updatedAt: TimeInterval = 0,
        staleAfter: TimeInterval? = nil,
        isStale: Bool = false
    ) {
        self.title = title
        self.symbolName = symbolName
        self.compactLeading = compactLeading
        self.compactTrailing = compactTrailing
        self.level = level
        self.rows = Array(rows.prefix(Self.maxRows))
        self.updatedAt = updatedAt
        self.staleAfter = staleAfter
        self.isStale = isStale
    }

    /// Whether the producer gave the closed notch anything to say.
    public var hasCompactText: Bool { compactLeading != nil || compactTrailing != nil }

    /// The moment the numbers stop being true, or nil if the producer never
    /// said they would.
    public var staleDeadline: TimeInterval? {
        guard let staleAfter else { return nil }
        return updatedAt + staleAfter
    }

    /// Whether the numbers had stopped being true at `now` (Unix seconds).
    ///
    /// A feed with no `stale_after` is never stale: it said nothing about how
    /// long it stays true, and a guess here would dim a card its producer
    /// meant to stand.
    public func isPastDeadline(at now: TimeInterval) -> Bool {
        guard let deadline = staleDeadline else { return false }
        return now > deadline
    }

    /// The same feed with `isStale` settled against `now`.
    public func settled(at now: TimeInterval) -> FeedPayload {
        var copy = self
        copy.isStale = isPastDeadline(at: now)
        return copy
    }
}
