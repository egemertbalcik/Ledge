import Foundation
import LedgeCore

/// The words a device row shows, worked out away from the view.
///
/// Pulled out so the states that are easy to get wrong — connected but stale,
/// silent but not disconnected, no battery at all — can be checked without
/// rendering anything.
public struct DeviceRowPresentation: Equatable, Sendable {

    public var status: String
    public var levelText: String?
    /// True when the level describes the past. The view draws it quieter; the
    /// label says so in words, because colour alone is not a message.
    public var isLevelHistorical: Bool
    public var accessibilityLabel: String
    /// The exact time, for help text and for anyone who needs the real value
    /// rather than "8 min ago".
    public var exactTime: String

    public init(
        name: String,
        presence: DevicePresence,
        isStale: Bool,
        lowestLevel: Double?,
        lastSeen: Date,
        now: Date,
        relativeText: String,
        exactTime: String
    ) {
        self.exactTime = exactTime
        self.isLevelHistorical = isStale

        status = switch presence {
        case .connected:
            isStale ? "Connected · last heard \(relativeText)" : "Connected"
        case .disconnected:
            "Disconnected · \(relativeText)"
        case .unknown:
            isStale ? "Last seen \(relativeText)" : "In range"
        }

        levelText = lowestLevel.map { "\(Int(($0 * 100).rounded()))%" }

        var parts = [name, status]
        if let lowestLevel {
            parts.append("\(Int((lowestLevel * 100).rounded())) percent")
            if isStale { parts.append("last known value") }
        } else {
            parts.append("no battery reported")
        }
        parts.append("last seen \(exactTime)")
        accessibilityLabel = parts.joined(separator: ", ")
    }
}
