import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

@Suite("Privacy provider")
@MainActor
struct PrivacyProviderTests {

    private func collect(
        _ provider: PrivacyProvider,
        while body: () -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("Nothing recording publishes nothing")
    func idleIsSilent() async {
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 })
        let events = await collect(provider) {}
        #expect(events.isEmpty)
    }

    @Test("The camera coming on publishes a standing card")
    func cameraPublishes() async {
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 })

        let events = await collect(provider) {
            source.set(RecordingState(camera: true))
        }

        guard case .publish(let activity)? = events.last else {
            Issue.record("expected a publish")
            return
        }
        #expect(activity.id == ActivityID(kind: .privacy, source: "system"))
        #expect(activity.expiresAfter == nil, "it must not time out while still recording")
        #expect(activity.priority > ActivityKind.message.defaultPriority)
        guard case .privacy(let payload) = activity.payload else {
            Issue.record("expected a privacy payload")
            return
        }
        #expect(payload.cameraActive)
        #expect(payload.micActive == false)
    }

    @Test("Recording already in progress at launch is still announced")
    func announcesStateAtLaunch() async {
        // Unlike a Focus mode, an active camera is not a settled fact the user
        // chose and forgot — it is worth showing immediately.
        let source = StubRecordingSource(value: RecordingState(microphone: true))
        let provider = PrivacyProvider(source: source, now: { 100 })
        let events = await collect(provider) {}
        #expect(events.count == 1)
    }

    @Test("Stopping everything retracts the card")
    func retractsWhenIdle() async {
        let source = StubRecordingSource(value: RecordingState(camera: true))
        let provider = PrivacyProvider(source: source, now: { 100 })
        let events = await collect(provider) {
            source.set(RecordingState())
        }
        #expect(events.contains(.retract(ActivityID(kind: .privacy, source: "system"))))
    }

    @Test("An unchanged state does not republish, so the safety poll is free")
    func repeatedSameStateIsQuiet() async {
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 })
        let events = await collect(provider) {
            source.set(RecordingState(camera: true))
            source.set(RecordingState(camera: true))
            source.set(RecordingState(camera: true))
        }
        #expect(events.count == 1)
    }

    @Test("Adding the microphone to an active camera republishes")
    func upgradeRepublishes() async {
        let source = StubRecordingSource(value: RecordingState(camera: true))
        let provider = PrivacyProvider(source: source, now: { 100 })
        let events = await collect(provider) {
            source.set(RecordingState(camera: true, microphone: true))
        }
        guard case .publish(let activity) = events.last else {
            Issue.record("expected a publish")
            return
        }
        guard case .privacy(let payload) = activity.payload else { return }
        #expect(payload.cameraActive && payload.micActive)
        #expect(payload.title == "Camera & Mic")
    }
}

@Suite("Provider default enablement")
@MainActor
struct ProviderDefaultEnablementTests {

    @Test("A provider that is off by default stays off until switched on")
    func offByDefaultIsHonoured() {
        // This was silently broken: the preference stored only the disabled
        // set, so anything never touched read as enabled regardless.
        let preferences = Preferences(store: MemoryPreferenceStore())
        #expect(preferences.isProviderEnabled("airpods", defaultEnabled: false) == false)
        #expect(preferences.isProviderEnabled("battery", defaultEnabled: true))
    }

    @Test("Switching an off-by-default provider on survives")
    func explicitEnableSticks() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.setProvider("airpods", enabled: true)
        #expect(preferences.isProviderEnabled("airpods", defaultEnabled: false))
    }

    @Test("Switching an on-by-default provider off survives")
    func explicitDisableSticks() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.setProvider("battery", enabled: false)
        #expect(preferences.isProviderEnabled("battery", defaultEnabled: true) == false)
    }

    @Test("Toggling back and forth ends where it started")
    func togglingRoundTrips() {
        let preferences = Preferences(store: MemoryPreferenceStore())
        preferences.setProvider("airpods", enabled: true)
        preferences.setProvider("airpods", enabled: false)
        #expect(preferences.isProviderEnabled("airpods", defaultEnabled: false) == false)
        preferences.setProvider("airpods", enabled: true)
        #expect(preferences.isProviderEnabled("airpods", defaultEnabled: false))
    }
}
