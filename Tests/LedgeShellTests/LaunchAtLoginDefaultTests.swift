import Foundation
import LedgeCore
import Testing

@testable import LedgeShell

/// Launch at login is on by default for a new install, and only for one.
@Suite("Launch at login by default")
@MainActor
struct LaunchAtLoginDefaultTests {

    private static let installed = URL(fileURLWithPath: "/Applications/Ledge.app")

    @Test("A new install from Applications turns it on")
    func newInstallTurnsOn() {
        #expect(LoginItemService.shouldTurnOnForNewInstall(
            alreadyOffered: false, hasStoredLaunchAtLogin: false, hasCompletedOnboarding: false,
            bundleURL: Self.installed, isReleaseBuild: true))
    }

    /// Somebody on 1.2.x whose tour was still open when Ledge quit: onboarding
    /// says unfinished, but every earlier launch wrote the login preference.
    @Test("An earlier version's user with an unfinished tour is left alone")
    func unfinishedTourFromEarlierVersionUntouched() {
        #expect(!LoginItemService.shouldTurnOnForNewInstall(
            alreadyOffered: false, hasStoredLaunchAtLogin: true, hasCompletedOnboarding: false,
            bundleURL: Self.installed, isReleaseBuild: true))
    }

    /// The signal has to be something every earlier launch really wrote.
    @Test("The launch reads the stored login preference before reconciling it")
    func storedPreferenceIsReadFirst() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Sources/LedgeApp/AppDelegate.swift"), encoding: .utf8)
        let read = try #require(source.range(of: "hasStoredLaunchAtLogin: preferences.hasStoredValue(Prefs.launchAtLogin.name)"))
        let reconcile = try #require(source.range(of: "preferences.launchAtLogin = LoginItemService.isEnabled"))
        #expect(read.upperBound <= reconcile.lowerBound)
    }

    /// The reconcile writes the key on every launch, which is what makes its
    /// absence mean a new install.
    @Test("Setting the login preference stores it")
    func reconcileStoresTheKey() {
        let store = MemoryPreferenceStore()
        let preferences = Preferences(store: store)
        #expect(!preferences.hasStoredValue(Prefs.launchAtLogin.name))
        preferences.launchAtLogin = false
        #expect(preferences.hasStoredValue(Prefs.launchAtLogin.name))
    }

    /// Once offered, switching it off sticks.
    @Test("Never offered twice")
    func offeredOnce() {
        #expect(!LoginItemService.shouldTurnOnForNewInstall(
            alreadyOffered: true, hasStoredLaunchAtLogin: false, hasCompletedOnboarding: false,
            bundleURL: Self.installed, isReleaseBuild: true))
    }

    /// An existing user's "off" may be a choice: it is left alone.
    @Test("An existing user is left as they are")
    func existingUserUntouched() {
        #expect(!LoginItemService.shouldTurnOnForNewInstall(
            alreadyOffered: false, hasStoredLaunchAtLogin: false, hasCompletedOnboarding: true,
            bundleURL: Self.installed, isReleaseBuild: true))
    }

    @Test("A development build never adds itself")
    func developmentBuildStaysOff() {
        #expect(!LoginItemService.shouldTurnOnForNewInstall(
            alreadyOffered: false, hasStoredLaunchAtLogin: false, hasCompletedOnboarding: false,
            bundleURL: Self.installed, isReleaseBuild: false))
    }

    @Test("Not from a disk image, an external drive or a translocated copy", arguments: [
        "/Volumes/Ledge/Ledge.app",
        "/Volumes/External SSD/Applications/Ledge.app",
        "/private/var/folders/xy/abc/T/AppTranslocation/1234-5678/d/Ledge.app",
    ])
    func vanishingLocationsStayOff(path: String) {
        #expect(!LoginItemService.shouldTurnOnForNewInstall(
            alreadyOffered: false, hasStoredLaunchAtLogin: false, hasCompletedOnboarding: false,
            bundleURL: URL(fileURLWithPath: path), isReleaseBuild: true))
    }

    /// The flag is spent before the request, and both come before the
    /// reconcile, so the switch in General shows what this launch did.
    @Test("The launch spends the offer, asks, then reconciles")
    func launchOrder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "Sources/LedgeApp/AppDelegate.swift"), encoding: .utf8)
        let decide = try #require(source.range(of: "LoginItemService.shouldTurnOnForNewInstall("))
        let spend = try #require(source.range(of: "preferences.launchAtLoginOffered = true"))
        let ask = try #require(source.range(of: "LoginItemService.setEnabled(true)"))
        let reconcile = try #require(source.range(of: "preferences.launchAtLogin = LoginItemService.isEnabled"))
        #expect(decide.upperBound <= spend.lowerBound)
        #expect(spend.upperBound <= ask.lowerBound)
        #expect(ask.upperBound <= reconcile.lowerBound)
    }
}
