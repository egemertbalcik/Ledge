import AppKit
import CoreGraphics

/// Which app owns the full-screen Space a display is showing right now.
///
/// There is no public way to ask. The window list cannot tell a full-screen
/// window from a maximised one with the Dock hidden: they have the same frame.
/// The WindowServer's own list of Spaces can, and it names the owner.
public enum FullScreenSpace {

    /// `type` of a Space that a full-screen app owns. An ordinary desktop is 0.
    private static let fullScreenType = 4

    /// The bundle identifiers of the apps filling the notched display,
    /// lowercased: one for an app in full screen, both for a Split View. Empty
    /// when that display is showing an ordinary desktop, or when the
    /// WindowServer can't be asked.
    @MainActor
    public static func ownerBundleIDs() -> Set<String> {
        typealias MainConnection = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main,
              let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let connection: MainConnection = PrivateSymbol.lookup("CGSMainConnectionID", in: .skyLight),
              let copySpaces: CopySpaces = PrivateSymbol.lookup("CGSCopyManagedDisplaySpaces", in: .skyLight),
              let monitors = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]],
              let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let identifier = CFUUIDCreateString(nil, uuid) as String?
        else { return [] }
        return Set(ownerPIDs(monitors: monitors, displayIdentifier: identifier).compactMap {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier?.lowercased()
        })
    }

    /// Reads the owners out of what the WindowServer reports.
    ///
    /// With "Displays have separate Spaces" off there is one entry for all of
    /// them, called "Main", in place of one per display.
    ///
    /// An app alone in full screen is one `pid`. Two apps in Split View share
    /// one Space, which can carry its `pid` as a list, and names each side
    /// again under its tiles. Both count: a player on either side is being
    /// watched. Reading only a single number used to see no owner at all.
    static func ownerPIDs(monitors: [[String: Any]], displayIdentifier: String) -> Set<pid_t> {
        let monitor = monitors.first { $0["Display Identifier"] as? String == displayIdentifier }
            ?? monitors.first { $0["Display Identifier"] as? String == "Main" }
        guard let current = monitor?["Current Space"] as? [String: Any],
              let id = current["ManagedSpaceID"] as? Int,
              let spaces = monitor?["Spaces"] as? [[String: Any]],
              let space = spaces.first(where: { $0["ManagedSpaceID"] as? Int == id }),
              space["type"] as? Int == fullScreenType
        else { return [] }
        var owners = Set(pids(in: space["pid"]))
        let tiles = (space["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]] ?? []
        for tile in tiles { owners.formUnion(pids(in: tile["pid"])) }
        return owners
    }

    /// A `pid` as one number or as a list of them. Anything else is no one.
    private static func pids(in value: Any?) -> [pid_t] {
        let values: [Any] = (value as? [Any]) ?? (value.map { [$0] } ?? [])
        return values.compactMap { ($0 as? Int).flatMap { pid_t(exactly: $0) } }.filter { $0 > 0 }
    }
}

/// The apps filling the notched display, remembered between changes.
///
/// Asking the WindowServer usually took about a millisecond on a 2,000-ask
/// run, but one ask in a hundred took over twelve and the slowest near
/// thirty, on the main thread where the notch is drawn. Asked on every media
/// poll, once a second while music plays, those slow asks came round every
/// couple of minutes, long enough to risk a frame. The answer
/// only changes when something happens, so it is asked when something does:
/// the shell calls `forget()` on a Space change, a display change, an app
/// quitting and a wake. The next read asks again on the spot, so the answer
/// right after a change is never an old one. A read long after the last ask
/// asks again too, in case the system ever didn't say.
@MainActor
public final class FullScreenOwners {

    /// How long a remembered answer stands without any change being heard.
    public static let longestTrust: Duration = .seconds(10)

    private let ask: @MainActor () -> Set<String>
    private let now: () -> ContinuousClock.Instant
    private var answer: Set<String> = []
    private var askedAt: ContinuousClock.Instant?

    public init(
        ask: @escaping @MainActor () -> Set<String> = { FullScreenSpace.ownerBundleIDs() },
        now: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.ask = ask
        self.now = now
    }

    /// The apps filling the screen now, asking only when the remembered
    /// answer may be out of date.
    public func current() -> Set<String> {
        let moment = now()
        if let askedAt, moment - askedAt < Self.longestTrust { return answer }
        answer = ask()
        askedAt = moment
        return answer
    }

    /// Something changed that can change the answer.
    public func forget() {
        askedAt = nil
    }
}
