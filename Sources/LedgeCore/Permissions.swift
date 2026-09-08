import Foundation

/// A macOS permission this app can need.
///
/// Lives in `LedgeCore` as plain data so the settings UI can render a row per
/// case without importing the system layer that actually checks them.
public enum PermissionKind: String, Equatable, Sendable, CaseIterable, Codable {

    /// Needed to intercept the media keys and replace the system HUD.
    case accessibility

    /// Needed to ask Music or Spotify what is playing.
    case automation

    /// Needed to read the next calendar event.
    case calendars

    /// Needed to name connected Bluetooth devices.
    case bluetooth

    /// Needed for local weather without a manually chosen city.
    case location

    /// Needed to know whether a Focus is on. Ordinary and promptable, unlike
    /// Full Disk Access — this is what makes the Focus card possible at all.
    case focusStatus

    /// Makes the Focus card immediate, and gives the mode its own name.
    ///
    /// Never required, and never asked for during the tour. Without it Ledge
    /// still knows a Focus is on, through the ordinary Focus-status
    /// permission — but it learns by asking on a timer rather than by being
    /// woken when the database changes, so the card can lag the switch, and
    /// the mode reads as "Focus" rather than by name.
    case fullDiskAccess

    public var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .automation: "Automation"
        case .calendars: "Calendar"
        case .bluetooth: "Bluetooth"
        case .location: "Location"
        case .focusStatus: "Focus"
        case .fullDiskAccess: "Full Disk Access"
        }
    }

    /// What this app loses without it, in the user's terms.
    public var rationale: String {
        switch self {
        case .accessibility:
            "Lets Ledge replace the macOS volume and brightness readout. Without it, Ledge shows its own alongside the system one."
        case .automation:
            "Lets Ledge read what Music and Spotify are playing. Without it, those two still show through the system's own now-playing data, with fewer details."
        case .calendars:
            "Lets Ledge show your next event. Without it, the calendar card is hidden."
        case .bluetooth:
            "Lets Ledge name your connected devices. Without it, battery levels may still appear but without device names."
        case .location:
            "Lets Ledge show local weather automatically. You can pick a city manually instead."
        case .focusStatus:
            "Lets Ledge see whether a Focus is on, so it can show the card when you switch one on or off."
        case .fullDiskAccess:
            "Optional. Makes the Focus card follow the switch straight away instead of within half a minute, and gives the mode its own name and icon. Without it the card still appears, just later and as \"Focus\". macOS quits Ledge when you turn this on — reopen it afterwards."
        }
    }

    /// Whether the app can present a system prompt for this, or whether the
    /// user has to grant it by hand.
    ///
    /// Two cannot be prompted for:
    ///
    /// - **Full Disk Access** has no request API at all. It can only be probed
    ///   by trying a protected read and seeing whether it fails.
    /// - **Accessibility** does show a prompt, but the actual grant still
    ///   happens in System Settings — the prompt is only a shortcut there.
    public var isRequestable: Bool {
        switch self {
        case .accessibility, .automation, .calendars, .bluetooth, .location, .focusStatus: true
        case .fullDiskAccess: false
        }
    }
}

public enum PermissionStatus: String, Equatable, Sendable {

    case granted

    /// Explicitly refused, or revoked later.
    case denied

    /// Never asked. Most permissions start here.
    case notDetermined

    /// The capability does not exist on this machine — no Bluetooth hardware,
    /// no supported player installed.
    case unavailable

    /// Cannot be asked right now — the app it applies to is not running (the
    /// Automation grant is per player, and asking about a closed one would
    /// launch it). Not "unavailable": open Music or Spotify and it can be.
    case notApplicableNow

    public var isUsable: Bool { self == .granted }

    public var summary: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not requested"
        case .unavailable: "Unavailable on this Mac"
        case .notApplicableNow: "Open Music or Spotify to grant"
        }
    }
}

/// One row of the Permissions settings tab.
///
/// Built by the shell and handed to the view, so `LedgeUI` renders permissions
/// without knowing how any of them are checked.
public struct PermissionRow: Identifiable, Equatable, Sendable {
    public let kind: PermissionKind
    public let status: PermissionStatus

    public var id: String { kind.rawValue }

    public init(kind: PermissionKind, status: PermissionStatus) {
        self.kind = kind
        self.status = status
    }
}

/// One row of the per-provider toggle list, for the same reason.
public struct ProviderDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: ActivityKind

    /// The permission this provider needs, if any.
    public let permission: PermissionKind?

    /// Whether the user has it switched on.
    public let isEnabled: Bool

    /// Whether it can actually run right now — a provider can be enabled but
    /// blocked on a permission that has not been granted.
    public let isAvailable: Bool

    public init(
        id: String,
        displayName: String,
        kind: ActivityKind,
        permission: PermissionKind?,
        isEnabled: Bool,
        isAvailable: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.permission = permission
        self.isEnabled = isEnabled
        self.isAvailable = isAvailable
    }
}
