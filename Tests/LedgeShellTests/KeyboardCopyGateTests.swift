import Foundation
import LedgeCore
import LedgeProviders
import LedgeSystem
import LedgeUI
import Testing

@testable import LedgeShell

/// The Settings switch, end to end: what the coordinator asks before it lets
/// a queued keyboard copy play.
///
/// A queued layout switch carries a copy of its card, because its own card
/// expires before anything it waits behind. Turning the indicator off took
/// the provider's cards away but not the copy, which could still flash once.
@Suite("The keyboard indicator turned off with a switch still queued", .timeLimit(.minutes(10)))
@MainActor
struct KeyboardCopyGateTests {

    private func until(_ condition: () -> Bool) async throws {
        while !condition() { try await Task.sleep(for: .milliseconds(1)) }
    }

    @Test("Turning the indicator off stops a queued copy; expiry alone does not")
    func theSettingGatesTheCopy() async throws {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.hasCompletedOnboarding = true
        let activities = ActivityCoordinator(
            presentation: NotchPresentation(), preferences: preferences, isPermitted: { _ in true }
        )
        let layout = StubKeyboardLayoutSource(value: KeyboardLayoutSnapshot(name: "Turkish Q", code: "TR"))
        activities.register(ProviderRegistration(
            id: "keyboard", displayName: "Keyboard Layout", kind: .keyboard,
            make: { KeyboardLayoutProvider(source: layout) }
        ))
        activities.startEnabled()
        activities.start()
        defer { activities.stop() }
        try #require(activities.isProviderRunning("keyboard"))

        layout.set(KeyboardLayoutSnapshot(name: "ABC", code: "EN"))
        let id = ActivityID(kind: .keyboard, source: "input")
        try await until { activities.activity(withID: id) != nil }
        let entry = PendingPeek(try #require(activities.activity(withID: id)), at: 0, byUser: false)

        // The real expiry timer takes the card off — the condition the copy
        // exists for — and the provider still stands behind it.
        try await until { activities.activity(withID: id) == nil }
        #expect(activities.isPublished(id))
        #expect(entry.card(live: nil, publisherRunning: activities.isPublished(id)) != nil)

        activities.setProvider("keyboard", enabled: false)
        try #require(!activities.isProviderRunning("keyboard"))
        #expect(!activities.isPublished(id))
        #expect(entry.card(live: nil, publisherRunning: activities.isPublished(id)) == nil)
    }
}
