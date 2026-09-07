import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders

/// A provider under the test's control: it publishes exactly what it is told,
/// when it is told, so the hub's behaviour can be observed without timers or
/// system APIs.
@MainActor
private final class TestProvider: ActivityProvider {

    let identifier: String
    private(set) var startCount = 0
    private(set) var stopCount = 0

    private var continuation: AsyncStream<ProviderEvent>.Continuation?

    init(identifier: String) {
        self.identifier = identifier
    }

    func start() -> AsyncStream<ProviderEvent> {
        startCount += 1
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func retract(_ source: String, kind: ActivityKind = .message) {
        continuation?.yield(.retract(ActivityID(kind: kind, source: source)))
    }

    func publish(_ source: String, kind: ActivityKind = .message) {
        let id = ActivityID(kind: kind, source: source)
        continuation?.yield(.publish(Activity(
            id: id,
            createdAt: 0,
            payload: .message(MessagePayload(title: source))
        )))
    }
}

@Suite("Provider hub")
@MainActor
struct ProviderHubTests {

    /// Lets the hub's consuming task drain what a provider yielded.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test("Events reach the queue and notify")
    func eventsReachQueue() async {
        let hub = ProviderHub()
        let provider = TestProvider(identifier: "a")
        var notifications = 0
        hub.onChange = { _ in notifications += 1 }

        hub.add(provider)
        hub.start()
        provider.publish("one")
        await settle()

        #expect(hub.queue.count == 1)
        #expect(notifications >= 1)
    }

    @Test("Starting twice does not double-subscribe a provider")
    func startIsIdempotent() async {
        // A second `start()` used to be needed when a provider was added after
        // launch; it must not re-subscribe the ones already running, or every
        // event would be applied twice.
        let hub = ProviderHub()
        let provider = TestProvider(identifier: "a")
        hub.add(provider)

        hub.start()
        hub.start()

        #expect(provider.startCount == 1)
        #expect(hub.runningIdentifiers == ["a"])
    }

    @Test("A provider added after startup still gets started")
    func lateProviderStarts() async {
        let hub = ProviderHub()
        let first = TestProvider(identifier: "a")
        hub.add(first)
        hub.start()

        let second = TestProvider(identifier: "b")
        hub.add(second)
        hub.start()

        #expect(first.startCount == 1, "already-running provider must not restart")
        #expect(second.startCount == 1)
    }

    @Test("Removing a provider takes its activities off screen")
    func removeRetractsActivities() async {
        // The whole reason the hub tracks attribution. Cancelling the stream
        // stops new events, but anything already published would sit in the
        // queue with nothing left able to update or retract it.
        let hub = ProviderHub()
        let keep = TestProvider(identifier: "keep")
        let drop = TestProvider(identifier: "drop")
        hub.add(keep)
        hub.add(drop)
        hub.start()

        keep.publish("kept")
        drop.publish("dropped-one", kind: .device)
        drop.publish("dropped-two", kind: .power)
        await settle()
        #expect(hub.queue.count == 3)

        hub.remove("drop")

        #expect(hub.queue.count == 1)
        #expect(hub.queue.activities.map(\.id.source) == ["kept"])
        #expect(drop.stopCount == 1)
        #expect(keep.stopCount == 0, "removing one provider must not stop the others")
    }

    @Test("Removing leaves the selection on something that still exists")
    func removeKeepsSelectionValid() async {
        let hub = ProviderHub()
        let keep = TestProvider(identifier: "keep")
        let drop = TestProvider(identifier: "drop")
        hub.add(keep)
        hub.add(drop)
        hub.start()

        keep.publish("kept")
        drop.publish("dropped")
        await settle()

        hub.remove("drop")

        // Never a dangling id — the invariant the queue guarantees, checked
        // through the removal path specifically.
        if let selected = hub.queue.selectedID {
            #expect(hub.queue.activities.contains { $0.id == selected })
        }
    }

    @Test("Removing an unknown provider is a no-op")
    func removeUnknownIsSafe() async {
        let hub = ProviderHub()
        let provider = TestProvider(identifier: "a")
        hub.add(provider)
        hub.start()
        provider.publish("one")
        await settle()

        hub.remove("nonexistent")
        #expect(hub.queue.count == 1)
    }

    @Test("Removing deregisters, so re-enabling builds a fresh provider")
    func removeDeregisters() async {
        // Disabling tears the provider down rather than parking it. That is
        // deliberate: a disabled provider should hold no resources and do no
        // work, so re-enabling constructs a new one — which is exactly what
        // `ActivityCoordinator.setProvider` does with the registry factory.
        let hub = ProviderHub()
        hub.add(TestProvider(identifier: "a"))
        hub.start()
        hub.remove("a")

        #expect(hub.registeredIdentifiers.isEmpty)
        hub.start("a")
        #expect(hub.runningIdentifiers.isEmpty, "nothing to start until it is re-added")

        let replacement = TestProvider(identifier: "a")
        hub.add(replacement)
        hub.start("a")
        #expect(replacement.startCount == 1)
        #expect(hub.runningIdentifiers == ["a"])
    }

    @Test("Adding the same identifier twice replaces rather than duplicates")
    func addReplacesByIdentifier() async {
        let hub = ProviderHub()
        hub.add(TestProvider(identifier: "a"))
        hub.add(TestProvider(identifier: "a"))
        #expect(hub.registeredIdentifiers == ["a"])
    }

    @Test("An id another provider still publishes survives a removal")
    func removeKeepsSharedIDs() async {
        // Two providers can legitimately own the same id — a fixture scenario
        // and the real provider for the same kind. Disabling one must not take
        // down a card the other is still standing behind.
        let hub = ProviderHub()
        let real = TestProvider(identifier: "real")
        let fixture = TestProvider(identifier: "fixture")
        hub.add(real)
        hub.add(fixture)
        hub.start()

        real.publish("internal", kind: .power)
        fixture.publish("internal", kind: .power)
        await settle()
        #expect(hub.queue.count == 1, "same id dedupes to one activity")

        hub.remove("fixture")
        #expect(hub.queue.count == 1, "the real provider still owns it")

        hub.remove("real")
        #expect(hub.queue.isEmpty, "now nobody owns it")
    }

    @Test("Attribution is tracked per provider, not asked of it")
    func attributionFollowsRetraction() async {
        // The hub watches the event stream, so a provider that retracts its own
        // activity is not later credited with it.
        let hub = ProviderHub()
        let provider = TestProvider(identifier: "a")
        hub.add(provider)
        hub.start()

        provider.publish("gone")
        await settle()
        provider.retract("gone")
        await settle()
        #expect(hub.queue.isEmpty)

        // Removing must not resurrect or misbehave over an id already gone.
        hub.remove("a")
        #expect(hub.queue.isEmpty)
    }
}

@Suite("Provider registry")
@MainActor
struct ProviderRegistryTests {

    private func registrations() -> [ProviderRegistration] {
        ProviderRegistry.all(nowPlayingProvider: { TestProvider(identifier: "nowplaying") })
    }

    @Test("Every registration builds a provider whose identifier is its id")
    func identifiersMatchWhatTheyBuild() {
        // Nothing in the type system ties a registration's id to the identifier
        // its provider reports, and `ProviderHub` keys on the *provider's*. So a
        // registration whose id merely looks right makes
        // `setProvider(_:enabled:)` a silent no-op: the settings toggle moves
        // and the provider keeps running. Two had drifted exactly that way
        // ("airpods" vs "airpods-proximity", "nowPlaying" vs "nowplaying"), so
        // this is a regression test, not a hypothetical one.
        for registration in registrations() {
            let built = registration.make()
            #expect(
                built.identifier == registration.id,
                """
                registration "\(registration.id)" builds a provider identifying \
                as "\(built.identifier)" — enabling or disabling it would do nothing
                """
            )
        }
    }

    @Test("Every registration has a unique id")
    func idsAreUnique() {
        // Ids are persisted in the disabled-providers preference, so a
        // collision would make one provider's toggle silently control another.
        let ids = registrations().map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Descriptors fold in the user's choice and the permission state")
    func descriptorsReflectState() {
        let descriptors = ProviderRegistry.descriptors(
            registrations(),
            isEnabled: { _ in false },
            isPermitted: { _ in false }
        )
        #expect(descriptors.allSatisfy { !$0.isEnabled })
        // Now Playing needs Automation, so an ungranted permission marks it
        // unavailable even though it is registered.
        #expect(descriptors.contains { $0.permission == .automation && !$0.isAvailable })
    }

    @Test("A provider needing no permission is always available")
    func permissionlessIsAlwaysAvailable() {
        let registration = ProviderRegistration(
            id: "free",
            displayName: "Free",
            kind: .power,
            permission: nil,
            make: { TestProvider(identifier: "free") }
        )
        let descriptors = ProviderRegistry.descriptors(
            [registration],
            isEnabled: { _ in true },
            isPermitted: { _ in false }
        )
        #expect(descriptors[0].isAvailable)
    }
}

@Suite("Provider preferences")
@MainActor
struct ProviderPreferenceTests {

    @Test("Providers are enabled unless explicitly disabled")
    func enabledByDefault() {
        // Only the exceptions are stored, so a newly added provider is on
        // without touching preferences at all.
        let preferences = Preferences(store: MemoryPreferenceStore())
        #expect(preferences.isProviderEnabled("anythingAtAll"))
    }

    @Test("Disabling round-trips through the store")
    func disableRoundTrips() {
        let store = MemoryPreferenceStore()
        let first = Preferences(store: store)
        first.setProvider("battery", enabled: false)
        first.setProvider("bluetooth", enabled: false)

        let reloaded = Preferences(store: store)
        #expect(!reloaded.isProviderEnabled("battery"))
        #expect(!reloaded.isProviderEnabled("bluetooth"))
        #expect(reloaded.isProviderEnabled("nowPlaying"))
    }

    @Test("Re-enabling removes it from the stored set")
    func reEnableClears() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.setProvider("battery", enabled: false)
        preferences.setProvider("battery", enabled: true)
        #expect(preferences.isProviderEnabled("battery"))
        #expect(preferences.disabledProviders.isEmpty)
    }

    @Test("The stored string is stable regardless of toggle order")
    func storedOrderIsStable() {
        // Sorted on write, so flipping toggles does not churn user defaults
        // with reorderings of the same set.
        let a = Preferences(store: MemoryPreferenceStore())
        a.setProvider("zebra", enabled: false)
        a.setProvider("alpha", enabled: false)

        let b = Preferences(store: MemoryPreferenceStore())
        b.setProvider("alpha", enabled: false)
        b.setProvider("zebra", enabled: false)

        #expect(a.disabledProviders == b.disabledProviders)
    }

    @Test("Whitespace and empty entries in a hand-edited value are tolerated")
    func toleratesHandEditedValue() {
        // The key is plain text in user defaults; someone will edit it by hand.
        let store = MemoryPreferenceStore()
        store.set(" battery , , bluetooth ", for: Prefs.disabledProviders)
        let preferences = Preferences(store: store)
        #expect(preferences.disabledProviderIDs == ["battery", "bluetooth"])
    }
}
