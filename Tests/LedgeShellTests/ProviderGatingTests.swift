import Foundation
import LedgeCore
import LedgeProviders
import LedgeUI
import Testing

@testable import LedgeShell

/// A provider that records whether it was ever started, so gating can be
/// proven by what did *not* run.
@MainActor
private final class SpyProvider: ActivityProvider {
    let identifier: String
    private(set) var started = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    init(identifier: String) { self.identifier = identifier }

    func start() -> AsyncStream<ProviderEvent> {
        started = true
        startCount += 1
        return AsyncStream { self.continuation = $0 }
    }

    func stop() { stopCount += 1; continuation?.finish(); continuation = nil }
}

@Suite("A provider waits for the permission it needs")
@MainActor
struct ProviderGatingTests {

    private func registration(_ id: String, _ permission: PermissionKind?) -> ProviderRegistration {
        ProviderRegistration(
            id: id,
            displayName: id,
            kind: .device,
            permission: permission,
            make: { SpyProvider(identifier: id) }
        )
    }

    private func coordinator(
        permitted: Set<PermissionKind>,
        onboarded: Bool = true
    ) -> ActivityCoordinator {
        let preferences = Preferences(store: MemoryPreferenceStore())
        // Tour completion does not substitute for a permission grant.
        preferences.hasCompletedOnboarding = onboarded
        return ActivityCoordinator(
            presentation: NotchPresentation(),
            preferences: preferences,
            isPermitted: { permitted.contains($0) }
        )
    }

    @Test("One needing nothing always runs")
    func unpermissionedProviderRuns() {
        let activities = coordinator(permitted: [])
        activities.register(registration("weather", nil))
        activities.startEnabled()
        #expect(activities.isProviderRunning("weather"))
    }

    /// It used to start regardless, then poll something that would never
    /// answer: no cards, no error, just work.
    @Test("One whose permission is refused does not start")
    func deniedProviderStaysDown() {
        let activities = coordinator(permitted: [])
        activities.register(registration("calendar", .calendars))
        activities.startEnabled()
        #expect(activities.isProviderRunning("calendar") == false)
    }

    @Test("With the permission held, it starts")
    func permittedProviderRuns() {
        let activities = coordinator(permitted: [.calendars])
        activities.register(registration("calendar", .calendars))
        activities.startEnabled()
        #expect(activities.isProviderRunning("calendar"))
    }

    @Test("Suspending stops it without recording it as switched off")
    func suspendingLeavesThePreferenceAlone() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.hasCompletedOnboarding = true
        let activities = ActivityCoordinator(
            presentation: NotchPresentation(),
            preferences: preferences,
            isPermitted: { _ in true }
        )
        activities.register(registration("calendar", .calendars))
        activities.startEnabled()
        #expect(activities.isProviderRunning("calendar"))

        activities.suspendProvider("calendar")
        #expect(activities.isProviderRunning("calendar") == false)
        #expect(
            preferences.isProviderEnabled("calendar", defaultEnabled: true),
            "the user still wants this card; they simply cannot have it yet"
        )
        // Which is what lets the grant bring it straight back.
        activities.restartProvider("calendar")
        #expect(activities.isProviderRunning("calendar"))
    }

    @Test("Deferring the tour does not block already authorized providers")
    func authorizedProvidersDoNotDependOnTour() {
        let activities = coordinator(permitted: [.calendars], onboarded: false)
        activities.register(registration("calendar", .calendars))
        activities.register(registration("weather", nil))
        activities.startEnabled()

        #expect(activities.isProviderRunning("calendar"))
        #expect(activities.isProviderRunning("weather"))
    }

    @Test("Denied providers cannot be constructed by toggle or reset", arguments: [false, true])
    func allEntryPointsRespectPermission(onboarded: Bool) {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.hasCompletedOnboarding = onboarded
        var constructions = 0
        var granted = false
        let activities = ActivityCoordinator(
            presentation: NotchPresentation(), preferences: preferences,
            isPermitted: { _ in granted }
        )
        activities.register(ProviderRegistration(
            id: "calendar", displayName: "Calendar", kind: .event, permission: .calendars,
            make: { constructions += 1; return SpyProvider(identifier: "calendar") }
        ))
        activities.startEnabled()
        activities.setProvider("calendar", enabled: false)
        activities.setProvider("calendar", enabled: true)
        preferences.resetToDefaults()
        activities.reconcileWithPreferences()
        #expect(constructions == 0)
        #expect(!activities.isProviderRunning("calendar"))
        granted = true
        activities.permissionChanged(.calendars, isGranted: true)
        #expect(constructions == 1)
        #expect(activities.isProviderRunning("calendar"))
        granted = false
        activities.reconcileWithPreferences()
        #expect(!activities.isProviderRunning("calendar"))
        #expect(preferences.isProviderEnabled("calendar"))
        activities.stop()
    }

    @Test("Optional media continues without restart when Automation becomes unavailable")
    func optionalMediaSurvivesLoss() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        var granted = true
        let provider = SpyProvider(identifier: "media")
        let activities = ActivityCoordinator(
            presentation: NotchPresentation(), preferences: preferences,
            isPermitted: { _ in granted }
        )
        activities.register(ProviderRegistration(
            id: "media", displayName: "Media", kind: .nowPlaying, permission: .automation,
            permissionIsOptional: true, make: { provider }
        ))
        activities.startEnabled()
        #expect(provider.startCount == 1)
        granted = false
        activities.permissionChanged(.automation, isGranted: false)
        #expect(activities.isProviderRunning("media"))
        #expect(provider.startCount == 1)
        #expect(provider.stopCount == 0)
        activities.setProvider("media", enabled: false)
        granted = true
        activities.permissionChanged(.automation, isGranted: true)
        #expect(!activities.isProviderRunning("media"), "a grant must not undo the user's off switch")
        activities.stop()
    }

    @Test("Location fallback runs before Done and rebuilds when Location is revoked")
    func fallbackRebuildsWithoutDisabling() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        var made: [SpyProvider] = []
        let activities = ActivityCoordinator(
            presentation: NotchPresentation(), preferences: preferences, isPermitted: { _ in false }
        )
        activities.register(ProviderRegistration(
            id: "weather", displayName: "Weather", kind: .weather, permission: .location,
            permissionIsOptional: true, make: {
                let provider = SpyProvider(identifier: "weather")
                made.append(provider)
                return provider
            }
        ))
        activities.startEnabled()
        #expect(made.count == 1)
        activities.permissionChanged(.location, isGranted: false)
        #expect(activities.isProviderRunning("weather"))
        #expect(made.count == 2)
        #expect(made.first?.stopCount == 1)
        activities.stop()
    }
}
