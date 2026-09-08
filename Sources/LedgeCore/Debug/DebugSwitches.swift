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

    /// Whether a *tracing* switch is on. Unlike the switches above, this one
    /// answers in release builds too, from a preference rather than the
    /// environment: `defaults write com.egemert.ledge developer.trace.levels
    /// -bool true`.
    ///
    /// The separation is the point. `isOn` guards things that change what the
    /// app does — replaying fixtures, writing diagnostic files, dropping the
    /// screen-capture exclusion — and a shipped build must not be talkable
    /// into any of them. Tracing only adds lines to the system log, which is
    /// exactly what is needed to diagnose the copy somebody actually
    /// installed. Refusing that is how a bug report becomes a guess.
    ///
    /// - Parameter name: the trace's short name, e.g. "levels", "media".
    public static func tracing(_ name: String) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LEDGE_TRACE_\(name.uppercased())"] == "1" {
            return true
        }
        #endif
        return UserDefaults.standard.bool(forKey: "developer.trace.\(name)")
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
