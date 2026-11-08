import Foundation

/// Reads a feed file.
///
/// A feed is a small JSON document some other program writes into a folder
/// Ledge watches. Schema version 1:
///
/// ```json
/// {
///   "version": 1,
///   "id": "limits",
///   "title": "Limits",
///   "symbol": "gauge.with.dots.needle.67percent",
///   "compact_leading": "C 90%",
///   "compact_trailing": "G ~100%",
///   "compact_leading_fraction": 0.9,
///   "compact_trailing_fraction": 1.0,
///   "level": "normal",
///   "gauges": [
///     {"label": "Claude", "value": "90%", "fraction": 0.9, "level": "warning"}
///   ],
///   "rows": [
///     {"label": "Claude 5h", "value": "10% used", "detail": "resets 05:00",
///      "fraction": 0.10, "level": "normal"}
///   ],
///   "updated_at": 1794088196,
///   "stale_after": 43200
/// }
/// ```
///
/// Only `version` is required. Everything else has an answer when it is
/// missing, because the writer is somebody else's script: a file that is
/// nearly right should still draw, and a file that is wrong should be skipped
/// whole rather than half-drawn. Unknown fields are ignored so a newer
/// producer can add to a version-1 file without breaking an older Ledge.
///
/// Parsed by hand from `JSONSerialization` rather than decoded. `Decodable`
/// is all or nothing, and one row with a number where a string belongs would
/// have thrown away the whole card; here it throws away the row.
public enum FeedParser {

    /// Past this a file is not a status card. The limit is on the file, not on
    /// what survives parsing, so an oversize file is never read into a model.
    public static let maxBytes = 64 * 1024

    public static let supportedVersion = 1

    /// How far ahead of this Mac's clock a producer's `updated_at` may be.
    public static let clockSkew: TimeInterval = 5 * 60

    /// How much of each string is kept. A card has no room for more, and a
    /// producer with a runaway string should not make the model carry it.
    enum Limit {
        static let id = 128
        static let title = 80
        static let symbol = 80
        static let compact = 24
        static let gaugeLabel = 20
        static let gaugeValue = 12
        static let label = 60
        static let value = 60
        static let detail = 80
    }

    public struct Feed: Equatable, Sendable {
        /// The producer's `id`, or the file's name without its extension.
        public let id: String
        public let payload: FeedPayload

        public init(id: String, payload: FeedPayload) {
            self.id = id
            self.payload = payload
        }
    }

    /// Why a file was not used. Only ever logged: a rejected file is simply
    /// not a card.
    public enum Rejection: Error, Equatable, Sendable, CustomStringConvertible {
        case oversize(bytes: Int)
        case notAnObject
        case missingVersion
        case unsupportedVersion(Int)

        public var description: String {
            switch self {
            case .oversize(let bytes): "larger than \(FeedParser.maxBytes) bytes (\(bytes))"
            case .notAnObject: "not a JSON object"
            case .missingVersion: "no version"
            case .unsupportedVersion(let version):
                "version \(version) is not one this Ledge reads (\(FeedParser.supportedVersion))"
            }
        }
    }

    /// - Parameters:
    ///   - fallbackID: the file's name without its extension, for a file that
    ///     names no `id` of its own.
    ///   - fallbackUpdatedAt: when the file was last written, in Unix seconds,
    ///     for one that says nothing about when its numbers were true. The
    ///     file's own date is a fair stand-in: it is when the producer last
    ///     had something to say.
    ///   - now: Unix seconds, for settling staleness. The parser never reads
    ///     a clock.
    ///   - seenAt: when this version of the file was first read, in Unix
    ///     seconds; `now` when not given. No date the file gives may be later
    ///     than this, give or take `clockSkew`. It has to be a time that stays
    ///     put while the file does: the folder is read again every minute, and
    ///     a ceiling taken from each read's `now` moved with it, so a file
    ///     dated in the future read "Just now" forever and never went stale.
    public static func parse(
        _ data: Data,
        fallbackID: String,
        fallbackUpdatedAt: TimeInterval = 0,
        now: TimeInterval,
        seenAt: TimeInterval? = nil
    ) -> Result<Feed, Rejection> {
        guard data.count <= maxBytes else { return .failure(.oversize(bytes: data.count)) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.notAnObject)
        }
        guard let raw = numeric(root["version"]), raw == raw.rounded(), let version = Int(exactly: raw)
        else { return .failure(.missingVersion) }
        guard version == supportedVersion else { return .failure(.unsupportedVersion(version)) }

        let id = string(root["id"], limit: Limit.id) ?? fallbackID

        // A gauge with nothing to fill its ring is no gauge, so a missing
        // fraction drops the item, where a row would only lose its bar.
        let gauges: [FeedGauge] = (root["gauges"] as? [Any] ?? []).compactMap { raw in
            guard let gauge = raw as? [String: Any],
                  let label = string(gauge["label"], limit: Limit.gaugeLabel),
                  let value = string(gauge["value"], limit: Limit.gaugeValue),
                  let fraction = number(gauge["fraction"])
            else { return nil }
            return FeedGauge(
                label: label, value: value, fraction: fraction,
                level: FeedLevel(word: gauge["level"] as? String)
            )
        }

        let rows: [FeedRow] = (root["rows"] as? [Any] ?? []).compactMap { raw in
            guard let row = raw as? [String: Any],
                  let label = string(row["label"], limit: Limit.label),
                  let value = string(row["value"], limit: Limit.value)
            else { return nil }
            return FeedRow(
                label: label,
                value: value,
                detail: string(row["detail"], limit: Limit.detail),
                fraction: number(row["fraction"]),
                level: FeedLevel(word: row["level"] as? String)
            )
        }

        // Never later than when this file was first seen, give or take a
        // clock that runs a little fast. A date in the future would win the
        // ears from every other feed, win every clash over an id, never go
        // stale and read "Just now" forever. A claim past the ceiling is not
        // believed at all: the file's own date says better when it was
        // written, and that date is held to the ceiling too, since
        // `touch -t 2100…` can set it to anything.
        let ceiling = (seenAt ?? now) + clockSkew
        let written = min(fallbackUpdatedAt, ceiling)
        let updatedAt: TimeInterval
        switch number(root["updated_at"]).flatMap({ $0 > 0 ? $0 : nil }) {
        case .some(let claimed) where claimed <= ceiling: updatedAt = claimed
        // With no date of its own to fall back on, the ceiling is the
        // latest the numbers can be true.
        case .some: updatedAt = fallbackUpdatedAt > 0 ? written : ceiling
        case .none: updatedAt = written
        }
        let staleAfter = number(root["stale_after"]).flatMap { $0 > 0 ? $0 : nil }

        let payload = FeedPayload(
            title: string(root["title"], limit: Limit.title) ?? id,
            symbolName: string(root["symbol"], limit: Limit.symbol),
            compactLeading: string(root["compact_leading"], limit: Limit.compact),
            compactTrailing: string(root["compact_trailing"], limit: Limit.compact),
            compactLeadingFraction: number(root["compact_leading_fraction"]),
            compactTrailingFraction: number(root["compact_trailing_fraction"]),
            compactLeadingColor: color(root["compact_leading_color"]),
            compactTrailingColor: color(root["compact_trailing_color"]),
            level: FeedLevel(word: root["level"] as? String),
            gauges: gauges,
            rows: rows,
            updatedAt: updatedAt,
            staleAfter: staleAfter
        ).settled(at: now)

        return .success(Feed(id: id, payload: payload))
    }

    /// A non-empty string, trimmed and cut to `limit` characters. Anything
    /// else — a number, a null, a blank — is absent.
    private static func string(_ value: Any?, limit: Int) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    /// A colour written as `#RRGGBB`. Anything else is absent, and the side
    /// falls back to the colour of its level.
    private static func color(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let digits = raw.dropFirst()
        guard raw.first == "#", digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return raw
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = numeric(value), number.isFinite else { return nil }
        return number
    }

    /// A JSON number, and only a number. `JSONSerialization` hands `true` back
    /// as an `NSNumber` too, which would otherwise read as 1.
    private static func numeric(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.doubleValue
    }
}
