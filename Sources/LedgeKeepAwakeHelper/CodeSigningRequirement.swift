import Foundation
import Security

/// The check that decides who may talk to a root process.
enum CodeSigningRequirement {

    /// Whether `SecRequirement` can make sense of this string.
    ///
    /// Called before the string is handed to `NSXPCListener`, because the
    /// documented behaviour there for a malformed requirement is a fatal
    /// error — the daemon would trap at launch, launchd would restart it, and
    /// it would trap again. Compiling it here turns that into a log line and a
    /// clean exit, which is at least something an admin can read.
    static func compiles(_ requirement: String) -> Bool {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        return status == errSecSuccess && compiled != nil
    }
}
