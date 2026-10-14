import Foundation
import LedgeCore
import Security
import ServiceManagement
import os

/// Whether this copy of Ledge could have the lid-closed helper, and whether it
/// does.
///
/// Read-only, deliberately and completely. Nothing here registers, installs,
/// approves or launches anything: it looks at the bundle it is running from
/// and at what launchd already thinks, and answers a question. Installing is a
/// separate act with a separate consent, and a probe that quietly installed
/// would be the worst possible version of this file.
/// Not main-actor isolated: nothing it does needs the main thread — a bundle
/// lookup, a static code signature, a file check, a launchd query — and the
/// lid holder that asks it is an actor of its own. Pinning it to the main actor
/// would make every reading a hop, and make an actor wait on the UI.
enum KeepAwakeHelperInstall {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake-helper")

    /// The daemon's property list, as it is named inside the app bundle.
    ///
    /// Derived from this bundle's own identifier rather than written out,
    /// because that is how the packaging script names it — and because the
    /// debug build and the release build have to end up with different labels
    /// or they would be two daemons claiming to be the same one. A constant
    /// here would be right for exactly one of them.
    static var plistName: String {
        "\(Bundle.main.bundleIdentifier ?? "com.egemert.ledge").keepawake.plist"
    }

    static func current() -> KeepAwakeHelperInstallation {
        reading(
            isDistributable: isDistributable,
            // Only asked once the build could use the answer. `SMAppService`
            // is not consulted at all for a bundle that has no daemon in it.
            hasDaemonPlist: { hasDaemonPlist },
            isRegistered: { SMAppService.daemon(plistName: plistName).status == .enabled }
        )
    }

    /// The three readings, and what they add up to. Separated from the three
    /// system calls that produce them because the order is the part worth
    /// arguing about, and the calls answer differently on every Mac.
    ///
    /// The build comes first: a Mac that cannot install the helper at all is a
    /// different sentence from one that merely has not yet, and finding that
    /// out by pressing a button and watching it fail is how a feature comes to
    /// look broken rather than unavailable.
    ///
    /// `requiresApproval` — and everything else launchd might say — is *not*
    /// installed. Unlike a login item, where waiting for approval still means
    /// the app launches, a daemon that has not been approved holds nothing,
    /// and a card that said it was set up would be promising a hold that
    /// cannot happen.
    static func reading(isDistributable: Bool,
                        hasDaemonPlist: () -> Bool,
                        isRegistered: () -> Bool) -> KeepAwakeHelperInstallation {
        guard isDistributable else { return .unsignedBuild }
        guard hasDaemonPlist() else { return .notInstalled }
        return isRegistered() ? .installed : .notInstalled
    }

    /// Whether macOS would entertain registering a daemon from this bundle.
    ///
    /// An ad-hoc signature — which is what a local `swift build` produces, and
    /// what `codesign -s -` leaves behind — carries no team identifier, and
    /// `SMAppService` will not register a privileged daemon out of one. So the
    /// absence of a team identifier is the whole test: it is the same fact
    /// macOS is going to check, asked before the user presses anything.
    private static var isDistributable: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code)
            == errSecSuccess, let code
        else {
            log.notice("keep awake helper: this build has no code signature to read")
            return false
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess,
            let signing = info as? [String: Any],
            let team = signing[kSecCodeInfoTeamIdentifier as String] as? String,
            !team.isEmpty
        else { return false }
        return true
    }

    /// Whether the daemon is even in this bundle to be installed from.
    ///
    /// A build made before the packaging scripts learnt to put it there has
    /// nothing to register, and asking `SMAppService` about a plist that is
    /// not there would get the same answer by a longer road.
    private static var hasDaemonPlist: Bool {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons")
            .appendingPathComponent(plistName)
        return FileManager.default.fileExists(atPath: url.path)
    }
}

/// Installing and removing the helper.
///
/// Separate from the reading above, and deliberately so: everything in
/// `KeepAwakeHelperInstall` answers questions and changes nothing, which is
/// what makes it safe to call on every settings refresh. These two change the
/// system, run only from a press, and are the only code in Ledge that asks
/// macOS to run anything as root.
enum KeepAwakeHelperSetup {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake-helper")

    /// What happened, in terms the settings pane can say out loud.
    enum Outcome: Equatable {
        /// Registered and already enabled.
        case installed
        /// Taken back out.
        case removed
        /// Registered, and now waiting for the user in System Settings.
        ///
        /// Not a failure and not success: a daemon awaiting approval holds
        /// nothing at all, so saying "set up" here would promise a hold that
        /// cannot happen.
        case needsApproval
        /// macOS refused, with its own words kept.
        case refused(String)
    }

    /// Asks macOS to install the daemon.
    ///
    /// Never called except from a press. Registration is a request, not an
    /// act: macOS puts the daemon in front of the user in System Settings and
    /// nothing runs as root until they allow it there.
    static func register() -> Outcome {
        let service = SMAppService.daemon(plistName: KeepAwakeHelperInstall.plistName)
        do {
            try service.register()
        } catch {
            // An already-registered service throws rather than saying so, and
            // that is not a failure worth showing anybody.
            if service.status == .enabled { return .installed }
            if service.status == .requiresApproval { return .needsApproval }
            log.error("keep awake: the helper would not register: \(error.localizedDescription, privacy: .public)")
            return .refused(error.localizedDescription)
        }
        return service.status == .enabled ? .installed : .needsApproval
    }

    /// Takes the daemon back out.
    ///
    /// `mayUnregister` is the caller's to check first: a daemon with a claim
    /// still waiting to be put back is the one thing that must stay registered,
    /// because it is the only thing that can put it back. Unregistering then
    /// would leave a Mac that cannot sleep and nothing left to fix it.
    static func unregister() -> Outcome {
        let service = SMAppService.daemon(plistName: KeepAwakeHelperInstall.plistName)
        do {
            try service.unregister()
        } catch {
            log.error("keep awake: the helper would not unregister: \(error.localizedDescription, privacy: .public)")
            return .refused(error.localizedDescription)
        }
        return .removed
    }

    /// Opens the pane where the user approves it.
    static func showApproval() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
