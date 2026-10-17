import Foundation
import LedgeCore

/// What one press being replaced by another means for the row and the notch.
///
/// A pure decision, apart from the coordinator, because these are the rules
/// that broke twice while this was being written. An ordinary Calendar prompt
/// pressed over an open Accessibility handoff abandoned that handoff's guide
/// and left a lock in the notch with nothing able to take it away; and the
/// correction for that, applied one step too widely, tore down the guide that
/// "Open System Settings Again" had just put up.
struct AttemptChange: Equatable {

    /// The permission whose row should stop saying it is waiting, if any.
    ///
    /// Nil when the new press is another go at the same permission: its own
    /// wait is already in place by then, and ending it would leave the row
    /// saying nothing while somebody is in System Settings for it.
    var endWaitFor: PermissionKind?

    /// Whether the notch's lock belongs to nobody now.
    var clearsTheLock: Bool

    /// Whether the guide in the window belongs to nobody now.
    ///
    /// False when the new press is a handoff for the permission the guide is
    /// already showing: that guide *is* the new press's.
    var endsTheGuide: Bool

    static let nothing = AttemptChange(endWaitFor: nil, clearsTheLock: false, endsTheGuide: false)
}

enum PermissionAttempts {

    /// - Parameters:
    ///   - previous: the press being replaced, and whether it handed off to
    ///     another application.
    ///   - kind: what the new press is about.
    ///   - handingOff: whether the new press hands off in its turn.
    ///   - guideShows: the permission the window's guide is drawing, if any.
    ///     Read rather than assumed, because the press has already installed
    ///     its own by the time the shell hears about it.
    static func replacing(
        _ previous: (kind: PermissionKind, handedOff: Bool)?,
        with kind: PermissionKind,
        handingOff: Bool,
        guideShows: PermissionKind?
    ) -> AttemptChange {
        guard let previous else { return .nothing }
        return AttemptChange(
            endWaitFor: previous.kind == kind ? nil : previous.kind,
            clearsTheLock: previous.handedOff,
            endsTheGuide: previous.handedOff && !(handingOff && guideShows == kind)
        )
    }
}
