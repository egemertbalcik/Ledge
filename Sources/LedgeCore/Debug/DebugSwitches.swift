import Foundation

/// The development-only environment switches, in one place.
///
/// A debug build honours them; a release build compiles them out, so a
/// notarized Ledge cannot be talked into disabling its capture exclusion,
/// replaying fixture scenarios, or writing diagnostic files by setting a
/// variable in its environment. `LEDGE_NO_ADAPTER` is deliberately *not* here:
/// it is a user-facing escape hatch rather than a development switch.
public enum DebugSwitches {

    /// True when the named variable is "1" — in debug builds only.
    public static func isOn(_ name: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment[name] == "1"
        #else
        return false
        #endif
    }

    /// The variable's value — in debug builds only.
    public static func value(_ name: String) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment[name]
        #else
        return nil
        #endif
    }
}
