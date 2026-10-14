import Foundation

/// What launchd starts the daemon with.
///
/// Both of these come from the job's `ProgramArguments`, which the app bundle's
/// own signature seals: whatever is in that plist was put there by the build
/// that is asking to be trusted. Neither is defaulted, because a daemon that
/// guesses either of them is a daemon that would accept a client it was never
/// told about.
struct HelperArguments: Equatable {

    /// The app's bundle identifier, as `--client`. The debug and release builds
    /// pass different ones, which is what gives them separate daemons.
    let clientIdentifier: String

    /// A code signing requirement string that a connecting client must
    /// satisfy, as `--requirement`.
    ///
    /// It is passed in rather than written here because the two identities
    /// Ledge is signed with have different team ids: a requirement compiled
    /// into this file would name one of them, and the other build would then
    /// silently refuse its own app. The build that signs the bundle is the only
    /// thing that knows which identity it used, so it is the thing that writes
    /// the requirement.
    let requirement: String

    /// The launchd label and the Mach service name, which are the same string.
    var label: String { "\(clientIdentifier).keepawake" }

    enum Problem: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case malformedIdentifier(String)

        var description: String {
            switch self {
            case .missing(let flag):
                "keep awake helper: \(flag) is required and was not given"
            case .malformedIdentifier(let value):
                "keep awake helper: \(value) is not a usable bundle identifier"
            }
        }
    }

    static func parse(_ arguments: [String]) throws -> HelperArguments {
        guard let client = value(of: "--client", in: arguments) else {
            throw Problem.missing("--client")
        }
        guard isBundleIdentifier(client) else { throw Problem.malformedIdentifier(client) }
        guard let requirement = value(of: "--requirement", in: arguments) else {
            throw Problem.missing("--requirement")
        }
        return HelperArguments(clientIdentifier: client, requirement: requirement)
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        let value = arguments[index + 1]
        return value.isEmpty || value.hasPrefix("--") ? nil : value
    }

    /// The identifier becomes a Mach service name, so it has to be the shape
    /// launchd advertised. Anything else means the plist and this binary
    /// disagree, and the daemon would sit there advertising a name nobody is
    /// looking for.
    private static func isBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        guard !value.hasPrefix("."), !value.hasSuffix("."), !value.contains("..") else {
            return false
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return value.allSatisfy(allowed.contains)
    }
}
