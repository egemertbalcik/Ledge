import Foundation

/// What changed between two readings of the permission state.
///
/// Grants have always been noticed — the user goes to System Settings, comes
/// back, and the affected cards start working. Losses were not. A permission
/// revoked while the app runs left providers polling something that would
/// never answer again, a Settings pane showing what was true at launch, and,
/// for Accessibility, an event tap the system had already killed.
///
/// Kept as a pure function so the rule is testable without a Mac in a
/// particular permission state — which is the whole difficulty with this part
/// of the app.
public enum PermissionDiff {

    public struct Change: Equatable, Sendable {
        public let kind: PermissionKind
        public let wasUsable: Bool
        public let isUsable: Bool

        public var isLoss: Bool { wasUsable && !isUsable }
        public var isGain: Bool { !wasUsable && isUsable }
    }

    /// Every permission whose usability flipped between the two readings.
    ///
    /// Anything absent from `before` is treated as a first reading rather than
    /// a change: launching should not report the whole world as a gain.
    public static func changes(
        from before: [PermissionKind: PermissionStatus],
        to after: [PermissionKind: PermissionStatus]
    ) -> [Change] {
        after.compactMap { kind, status in
            guard let previous = before[kind] else { return nil }
            guard previous.isUsable != status.isUsable else { return nil }
            return Change(kind: kind, wasUsable: previous.isUsable, isUsable: status.isUsable)
        }
        // Deterministic order, so a log line and a test read the same way twice.
        .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }
}
