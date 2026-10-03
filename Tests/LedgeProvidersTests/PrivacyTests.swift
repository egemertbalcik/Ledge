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

/// Dictation used to be a thing Ledge detected, published, described and drew
/// differently. All of that is gone. What remains is an exclusion with no
/// interface: dictation produces no indicator at all, not even a microphone
/// one (see `RecordingWatcher.microphoneHeld(by:)`). These tests are the floor
/// under the removal — the genuine indicators must still work.
@Suite("Recording indicators after the dictation removal")
@MainActor
struct RecordingIndicatorTests {

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

    @Test("A microphone holder is published as the microphone indicator")
    func microphonePublishes() async {
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 })
        let events = await collect(provider) {
            source.set(RecordingState(microphone: true))
        }
        guard case .publish(let activity)? = events.last,
              case .privacy(let payload) = activity.payload
        else {
            Issue.record("expected a privacy publish")
            return
        }
        #expect(payload.micActive)
        #expect(payload.cameraActive == false)
        #expect(payload.title == "Microphone")
    }

    @Test("The camera, and both together, are published too")
    func cameraAndBoth() {
        #expect(PrivacyPayload(cameraActive: true).title == "Camera")
        #expect(PrivacyPayload(cameraActive: true, micActive: true).title == "Camera & Mic")
    }

    /// The satellite has one recording case and no second reading of it.
    @Test("The satellite carries the recording indicator and nothing beside it")
    func satelliteCarriesPrivacy() {
        let indicator = SatelliteContent.privacy(camera: false, microphone: true)
        #expect(SatelliteArbiter.resolve(
            transient: nil, privacy: indicator, timer: nil, timerIsMainIsland: false
        ) == indicator)
    }

    /// A card stored by a version that recorded the speech flag must still
    /// read. The flag is not decoded: what is on screen comes from the live
    /// reading, never from a stored one.
    @Test("A stored payload from before the removal still decodes")
    func oldPayloadDecodes() throws {
        let json = Data(#"{"cameraActive":false,"micActive":true,"isSystemSpeech":true}"#.utf8)
        let payload = try JSONDecoder().decode(PrivacyPayload.self, from: json)
        #expect(payload.micActive)
        #expect(payload.title == "Microphone", "the flag is not read, and nothing is hidden by it")
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
