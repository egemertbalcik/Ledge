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

/// What Ledge's own privacy card is allowed to say while Ledge itself is
/// showing the user their own face.
///
/// The watcher can only see that *a* camera is running, never whose, so
/// without this the self-view would announce itself — a card reading "Camera
/// in use" over a live picture of the person reading it.
@Suite("The privacy card and Ledge's own camera")
@MainActor
struct PrivacySelfViewTests {

    private func collect(
        _ provider: PrivacyProvider,
        while body: () async -> Void
    ) async -> [ProviderEvent] {
        let stream = provider.start()
        await body()
        provider.stop()
        var events: [ProviderEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test("Ledge's own self-view is not announced")
    func ownCameraIsQuiet() async {
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 }, uncoverGrace: 0.2)

        let events = await collect(provider) {
            provider.selfViewChanged(true, device: "built-in.front")
            source.set(RecordingState(camera: true, cameraIDs: ["built-in.front"]))
        }

        #expect(events.isEmpty, "the picture is the indicator; a card about it is noise")
    }

    @Test("A camera that wins the race to start is still announced")
    func foreignCameraWinsTheRace() async {
        // Reported by review: between the press and Ledge's own hardware
        // appearing, another application's camera can be the first thing in
        // the reading. Counted, that first camera looked like Ledge's and was
        // hidden; named, it is a stranger's and is not.
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 }, uncoverGrace: 0.2)

        let events = await collect(provider) {
            provider.selfViewChanged(true, device: "built-in.front")
            source.set(RecordingState(camera: true, cameraIDs: ["studio.display"]))
        }

        guard case .publish(let activity)? = events.last,
              case .privacy(let payload) = activity.payload else {
            Issue.record("expected the other application's camera to be published")
            return
        }
        #expect(payload.cameraActive)
    }

    @Test("A preview closed and reopened is still Ledge's own camera")
    func rapidReopenIsStillOurs() async {
        // The other direction the count got wrong: a preview closed and
        // reopened before the watcher saw the gap announced Ledge's own
        // camera as a stranger's.
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 }, uncoverGrace: 0.2)

        let events = await collect(provider) {
            provider.selfViewChanged(true, device: "built-in.front")
            source.set(RecordingState(camera: true, cameraIDs: ["built-in.front"]))
            provider.selfViewChanged(false)
            provider.selfViewChanged(true, device: "built-in.front")
            // The watcher never saw a reading without the camera in it.
            source.set(RecordingState(camera: true, cameraIDs: ["built-in.front"]))
            await provider.settleCover()
        }

        #expect(events.isEmpty, "Ledge must not announce its own preview")
    }

    @Test("Another application on the same camera is announced")
    func sharedCameraIsAnnounced() async {
        // The one thing a device's running state cannot say — whether
        // somebody else is reading the same lens — comes from
        // `isInUseByAnotherApplication`. When it says yes, nothing is
        // covered: a picture in the notch explains Ledge's own use of a
        // camera, not anybody else's.
        let source = StubRecordingSource()
        let provider = PrivacyProvider(
            source: source,
            now: { 100 },
            uncoverGrace: 0.2,
            sharedWithAnotherApp: { true }
        )

        let events = await collect(provider) {
            provider.selfViewChanged(true, device: "built-in.front")
            source.set(RecordingState(camera: true, cameraIDs: ["built-in.front"]))
        }

        guard case .publish(let activity)? = events.last,
              case .privacy(let payload) = activity.payload else {
            Issue.record("expected the shared camera to be published")
            return
        }
        #expect(payload.cameraActive)
    }

    @Test("Another application joining and leaving the same camera is noticed both ways")
    func sharingChangesAreNoticed() async {
        // Reported by review: whether somebody else is on Ledge's camera
        // moves while the hardware reading does not — the same device is
        // running throughout — so a dedupe that looked only at the reading
        // skipped the change, and the card hid a camera for as long as the
        // preview lasted.
        var shared = false
        let source = StubRecordingSource()
        let provider = PrivacyProvider(
            source: source,
            now: { 100 },
            uncoverGrace: 0.2,
            sharedWithAnotherApp: { shared }
        )

        let events = await collect(provider) {
            provider.selfViewChanged(true, device: "built-in.front")
            source.set(RecordingState(camera: true, cameraIDs: ["built-in.front"]))

            // A meeting app takes the same camera. Nothing about the devices
            // changes; only who is reading one.
            shared = true
            provider.recheck()

            // And lets go again.
            shared = false
            provider.recheck()
        }

        let kinds = events.map { event -> String in
            switch event {
            case .publish: "publish"
            case .retract: "retract"
            default: "other"
            }
        }
        #expect(
            kinds == ["publish", "retract"],
            "the card appears when the camera is shared and goes when it is not (got \(kinds))"
        )
    }

    @Test("A camera that starts while the preview is up is announced")
    func foreignCameraArrivingDuringThePreview() async {
        // The moment a privacy indicator exists for: something else reaches
        // for a camera while the user is looking at their own face.
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 }, uncoverGrace: 0.2)

        let events = await collect(provider) {
            provider.selfViewChanged(true, device: "built-in.front")
            source.set(RecordingState(camera: true, cameraIDs: ["built-in.front"]))
            source.set(RecordingState(camera: true, cameraIDs: ["built-in.front", "studio.display"]))
        }

        guard case .publish(let activity)? = events.last,
              case .privacy(let payload) = activity.payload else {
            Issue.record("expected the second camera to be published")
            return
        }
        #expect(payload.cameraActive)
    }

    @Test("A camera somebody else already had is still announced")
    func foreignCameraSurvivesTheCover() async {
        // The cover is only ever about a change Ledge caused. Something else
        // was already recording when the segment was pressed, and that is
        // exactly what the card exists to say.
        let source = StubRecordingSource(value: RecordingState(camera: true, cameraIDs: ["studio.display"]))
        let provider = PrivacyProvider(source: source, now: { 100 }, uncoverGrace: 0.2)

        let events = await collect(provider) {
            provider.selfViewChanged(true, device: "built-in.front")
            // Ledge's own camera joins the one already running.
            source.set(RecordingState(camera: true, microphone: true, cameraIDs: ["studio.display", "built-in.front"]))
        }

        guard case .publish(let activity)? = events.last,
              case .privacy(let payload) = activity.payload else {
            Issue.record("expected a published privacy card")
            return
        }
        #expect(payload.cameraActive)
    }

    @Test("The microphone is never covered")
    func microphoneIsNeverCovered() async {
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 }, uncoverGrace: 0.2)

        let events = await collect(provider) {
            provider.selfViewChanged(true, device: "built-in.front")
            source.set(RecordingState(camera: true, microphone: true, cameraIDs: ["built-in.front"]))
        }

        guard case .publish(let activity)? = events.last,
              case .privacy(let payload) = activity.payload else {
            Issue.record("expected a published privacy card")
            return
        }
        #expect(payload.micActive)
        #expect(payload.cameraActive == false, "only Ledge's own camera is covered")
    }

    @Test("A meeting app taking the camera at Join is announced")
    func handoverIsAnnounced() async {
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 }, uncoverGrace: 0.2)

        let events = await collect(provider) {
            provider.selfViewChanged(true, device: "built-in.front")
            source.set(RecordingState(camera: true, cameraIDs: ["built-in.front"]))

            // Join: Ledge lets go, and the meeting app takes the camera
            // before Ledge's own session has finished stopping. The cover
            // waits for one honest reading rather than ending on the spot —
            // and the reading says the camera is still on, so the card says
            // so too.
            provider.selfViewChanged(false)
            // Waited out, not slept out: when the cover ends, the reading —
            // which still says a camera is on, because the meeting app has
            // it — is the one the card acts on.
            await provider.settleCover()
        }

        guard case .publish(let activity)? = events.last,
              case .privacy(let payload) = activity.payload else {
            Issue.record("expected the handover to be published")
            return
        }
        #expect(payload.cameraActive)
    }

    @Test("Closing the self-view with nothing else running publishes nothing")
    func quietAfterClosing() async {
        let source = StubRecordingSource()
        let provider = PrivacyProvider(source: source, now: { 100 }, uncoverGrace: 0.2)

        let events = await collect(provider) {
            provider.selfViewChanged(true, device: "built-in.front")
            source.set(RecordingState(camera: true, cameraIDs: ["built-in.front"]))
            // Ledge's session stops, and the watcher catches up.
            source.set(RecordingState(camera: false, cameraIDs: []))
            provider.selfViewChanged(false)
            await provider.settleCover()
        }

        #expect(events.isEmpty)
    }

}
