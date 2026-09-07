import Foundation

/// What has to change to make the set of live panels match the set of displays.
public struct DisplayPlan<Key: Hashable>: Equatable {
    public let added: [Key]
    public let removed: [Key]
    public let kept: [Key]

    public init(added: [Key], removed: [Key], kept: [Key]) {
        self.added = added
        self.removed = removed
        self.kept = kept
    }
}

/// Works out which panels to build, tear down, and leave alone when the display
/// configuration changes.
///
/// Pure and in `LedgeCore` on purpose: there is no test target for `LedgeShell`,
/// so logic placed there could not be covered at all. Hot-plugging a monitor is
/// exactly the kind of thing that is tedious to test by hand and easy to get
/// wrong.
public enum DisplayReconciler {

    /// - Parameters:
    ///   - current: the panels that exist now.
    ///   - wanted: the displays that should have one, in screen order.
    /// - Returns: the plan, preserving `wanted`'s order so panels are created
    ///   predictably rather than in whatever order a dictionary iterates.
    public static func plan<Key: Hashable>(
        current: [Key],
        wanted: [Key]
    ) -> DisplayPlan<Key> {
        let currentSet = Set(current)
        let wantedSet = Set(wanted)
        return DisplayPlan(
            added: wanted.filter { !currentSet.contains($0) },
            removed: current.filter { !wantedSet.contains($0) },
            kept: wanted.filter { currentSet.contains($0) }
        )
    }
}
