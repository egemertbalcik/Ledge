import CoreGraphics
import Foundation

/// What an answer to a permission press does to the window that asked.
///
/// In one place because there are several ways to hear of a grant, and each of
/// them comes through here: the watch, the settings pane's refresh and Ledge
/// becoming active. A check on only one of them is no check at all.
public enum GrantArrival: Equatable, Sendable {
    /// Nothing of ours moves.
    case nothing
    /// Bring the window that asked to the front.
    case raise
    /// Somebody is still at System Settings. Leave it where it is and bring it
    /// back when they come back.
    case owe

    /// - Parameters:
    ///   - kind: the permission whose answer arrived. Nil is somebody clicking
    ///     the notch to go back, which is asked for and always honoured.
    ///   - pressKind: what is being waited for, if a press is outstanding.
    public init(
        kind: PermissionKind?,
        pressKind: PermissionKind?,
        isWatching: Bool,
        isStillAtSystemSettings: Bool
    ) {
        guard isWatching, let pressKind else { self = .nothing; return }
        // A Calendar grant landing while somebody is out over Bluetooth is not
        // a reason to take the foreground away from them.
        if let kind, kind != pressKind { self = .nothing; return }
        self = kind != nil && isStillAtSystemSettings ? .owe : .raise
    }
}

/// Where the permission panel sits beside System Settings, and whether it
/// shows at all.
///
/// Pure, because every rule in here is about how it feels to be in System
/// Settings on Ledge's behalf, and none of it can be checked by looking at it
/// once. Fed one reading at a time, a few times a second, while a handoff is
/// open. It keeps no opinion of its own about the handoff: when one ends the
/// panel goes, and the next one starts from a new dock.
///
/// All rectangles are in AppKit's global coordinates, origin at the bottom
/// left of the primary display.
public struct PermissionCompanionDock: Equatable, Sendable {

    public static let panelWidth: CGFloat = 296

    /// Enough to read as a second window. Touching edges would suggest one
    /// window, and a panel passing for part of System Settings is the fake
    /// look this is careful to avoid.
    public static let gap: CGFloat = 12

    /// How far the panel may cover System Settings when it has to go on the
    /// left. Only there: that edge is the sidebar. The list is on the other
    /// side, and nothing may ever sit on the list.
    public static let sidebarOverlap: CGFloat = 40

    /// Who is in front.
    public enum Front: Equatable, Sendable {
        case systemSettings
        /// Something that takes the front for a moment and is not somewhere
        /// the person went: the Touch ID or password dialog, macOS's one-time
        /// Accessibility message.
        case passing
        /// An application somebody chose to go to.
        case regularApp
    }

    public struct Reading: Equatable, Sendable {
        public var front: Front
        /// System Settings' window, if one is on screen in this Space.
        public var window: CGRect?
        /// The usable part of the screen that window is on.
        public var visible: CGRect?
        public var panelHeight: CGFloat

        public init(front: Front, window: CGRect?, visible: CGRect?, panelHeight: CGFloat) {
            self.front = front
            self.window = window
            self.visible = visible
            self.panelHeight = panelHeight
        }
    }

    public enum Answer: Equatable, Sendable {
        case hidden
        case shown(CGRect)
    }

    public private(set) var answer: Answer = .hidden

    private var lastWindow: CGRect?
    private var readingsAway = 0
    private var hasReadAnything = false

    /// How many readings in a row an application has to hold the front before
    /// the panel gives way. Two, at four readings a second, is the quarter of
    /// a second that stops it blinking when something passes through.
    private static let readingsBeforeGivingWay = 2

    public init() {}

    public mutating func read(_ reading: Reading) -> Answer {
        answer = next(reading)
        return answer
    }

    private mutating func next(_ reading: Reading) -> Answer {
        // A window already there at the very first reading was open before the
        // press. It is not still opening, so the panel can arrive with it.
        if !hasReadAnything, let window = reading.window { lastWindow = window }
        hasReadAnything = true

        guard let window = reading.window, let visible = reading.visible else {
            // Closed, or on another Space. Forgetting the frame means it has
            // to sit still again before the panel comes back.
            lastWindow = nil
            readingsAway = 0
            return .hidden
        }

        // Never chases a dragged window. A panel rubber-banding behind one
        // looks fake, so it goes, and comes back once the window has stopped.
        // Includes the first sighting of a window that opened after the press,
        // which is often still opening.
        let moved = lastWindow != window
        lastWindow = window
        if moved { return .hidden }

        if reading.front == .regularApp {
            readingsAway += 1
            return readingsAway >= Self.readingsBeforeGivingWay ? .hidden : answer
        }
        readingsAway = 0

        // Something passing through keeps a panel that is up. It does not
        // bring one up: the first thing to appear over a password dialog
        // should not be Ledge.
        if answer == .hidden, reading.front != .systemSettings { return .hidden }

        guard let frame = Self.place(window: window, visible: visible, panelHeight: reading.panelHeight) else {
            return .hidden
        }
        return .shown(frame)
    }

    /// Right, then left, then nowhere. System Settings is never moved or
    /// resized to make room, and without Accessibility it could not be anyway.
    public static func place(window: CGRect, visible: CGRect, panelHeight: CGFloat) -> CGRect? {
        guard panelHeight <= visible.height else { return nil }

        let x: CGFloat
        let right = window.maxX + gap
        let left = window.minX - gap - panelWidth
        if right + panelWidth <= visible.maxX {
            x = right
        } else if left >= visible.minX {
            x = left
        } else if window.minX + sidebarOverlap - panelWidth >= visible.minX {
            // Hard against the screen edge, over the sidebar by what it takes.
            x = visible.minX
        } else {
            return nil
        }

        // Tops aligned, and pulled back onto the screen if the panel is the
        // taller of the two and System Settings sits low.
        let top = min(window.maxY, visible.maxY)
        let y = max(top - panelHeight, visible.minY)
        return CGRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }
}
