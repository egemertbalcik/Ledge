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

    /// The bundle identifier of the app filling the notched display, or nil
    /// when that display is showing an ordinary desktop.
    @MainActor
    public static func ownerBundleID() -> String? {
        typealias MainConnection = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main,
              let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let connection: MainConnection = PrivateSymbol.lookup("CGSMainConnectionID", in: .skyLight),
              let copySpaces: CopySpaces = PrivateSymbol.lookup("CGSCopyManagedDisplaySpaces", in: .skyLight),
              let monitors = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]],
              let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let identifier = CFUUIDCreateString(nil, uuid) as String?,
              let pid = ownerPID(monitors: monitors, displayIdentifier: identifier)
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Reads the owner out of what the WindowServer reports.
    ///
    /// With "Displays have separate Spaces" off there is one entry for all of
    /// them, called "Main", in place of one per display.
    static func ownerPID(monitors: [[String: Any]], displayIdentifier: String) -> pid_t? {
        let monitor = monitors.first { $0["Display Identifier"] as? String == displayIdentifier }
            ?? monitors.first { $0["Display Identifier"] as? String == "Main" }
        guard let current = monitor?["Current Space"] as? [String: Any],
              let id = current["ManagedSpaceID"] as? Int,
              let spaces = monitor?["Spaces"] as? [[String: Any]],
              let space = spaces.first(where: { $0["ManagedSpaceID"] as? Int == id }),
              space["type"] as? Int == fullScreenType,
              let pid = space["pid"] as? Int
        else { return nil }
        return pid_t(exactly: pid)
    }
}
