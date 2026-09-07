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
    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    init(identifier: String) { self.identifier = identifier }

    func start() -> AsyncStream<ProviderEvent> {
        started = true
        return AsyncStream { self.continuation = $0 }
    }

    func stop() { continuation?.finish() }
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
        // These tests are about permissions. Onboarding is its own gate, in
        // front of this one, and has its own test below.
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

    /// A fresh Mac met the Automation dialog seconds after launch, before the
    /// welcome tour had said what Ledge was — because a provider started and
    /// asked. Nothing that touches a permission may run until the tour is done,
    /// however freely the permission itself would have been given.
    @Test("Nothing that needs a permission runs before the welcome tour")
    func permissionedProvidersWaitForOnboarding() {
        let activities = coordinator(permitted: [.calendars], onboarded: false)
        activities.register(registration("calendar", .calendars))
        activities.register(registration("weather", nil))
        activities.startEnabled()

        #expect(activities.isProviderRunning("calendar") == false)
        // The ones that ask for nothing still run: the notch is alive behind
        // the tour window, which is the first thing it shows off.
        #expect(activities.isProviderRunning("weather"))
    }
}
