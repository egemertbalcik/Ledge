import Foundation
import LedgeCore
import Testing

@testable import LedgeProviders
@testable import LedgeSystem

@Suite("Telling dictation from being recorded")
struct SystemSpeechTests {

    /// macOS publishes no "dictation is running" signal, so the only evidence
    /// is who holds the microphone. The daemon that serves it has been renamed
    /// across releases, so the test matches the family rather than a name.
    @Test("Apple's speech daemons read as system speech")
    func appleSpeechRecognised() {
        #expect(SystemRecordingSource.isSystemSpeech("com.apple.SpeechRecognitionCore"))
        #expect(SystemRecordingSource.isSystemSpeech("com.apple.speech.recognitionserver"))
        #expect(SystemRecordingSource.isSystemSpeech("com.apple.corespeechd"))
        #expect(SystemRecordingSource.isSystemSpeech("com.apple.assistant_service"))
        #expect(SystemRecordingSource.isSystemSpeech("com.apple.Siri"))
    }

    /// An app listening to you is a privacy fact and keeps the dot. Only the
    /// system's own speech input is the other thing.
    @Test("Apps are not, whatever they are for")
    func appsAreNotSpeech() {
        #expect(SystemRecordingSource.isSystemSpeech("us.zoom.xos") == false)
        #expect(SystemRecordingSource.isSystemSpeech("com.apple.Music") == false)
        #expect(SystemRecordingSource.isSystemSpeech("com.microsoft.teams") == false)
        // A third-party app is not granted the exemption by naming itself
        // after the feature.
        #expect(SystemRecordingSource.isSystemSpeech("com.example.dictation") == false)
    }

    @Test("Dictation is named, and a recording app is not")
    func payloadNamesIt() {
        let dictation = PrivacyPayload(micActive: true, isSystemSpeech: true)
        #expect(dictation.title == "Dictation")

        let recording = PrivacyPayload(micActive: true)
        #expect(recording.title == "Microphone")

        // The camera outranks it: something watching you is the more urgent
        // fact whatever else is happening.
        let both = PrivacyPayload(cameraActive: true, micActive: true, isSystemSpeech: true)
        #expect(both.title == "Camera & Mic")
    }

    @Test("An older stored card has no speech flag and reads as before")
    func decodesWithoutTheFlag() throws {
        let json = Data(#"{"cameraActive":false,"micActive":true}"#.utf8)
        let payload = try JSONDecoder().decode(PrivacyPayload.self, from: json)
        #expect(payload.isSystemSpeech == false)
        #expect(payload.title == "Microphone")
    }
}

@Suite("Dictation holds the ears while it listens")
@MainActor
struct DictationRestTests {

    private func dictation() -> Activity {
        Activity(
            id: PrivacyProvider.activityID, createdAt: 0,
            payload: .privacy(PrivacyPayload(micActive: true, isSystemSpeech: true))
        )
    }

    private func music(playing: Bool) -> Activity {
        Activity(
            id: ActivityID(kind: .nowPlaying, source: "spotify"), createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(title: "T", artist: "A", isPlaying: playing))
        )
    }

    /// Announced and gone is not enough: the useful thing is knowing it is
    /// still listening, for as long as it is.
    @Test("On a quiet island it takes the ears")
    func standingRests() {
        #expect(
            CompactRest.resolve(
                farewell: nil, playingNowPlaying: nil, runningTimer: nil,
                closeEvent: nil, nowPlaying: nil, selected: nil, standing: dictation()
            ) == dictation()
        )
    }

    @Test("Playing music keeps the island; dictation moves to the companion seat")
    func musicOutranksIt() {
        let playing = music(playing: true)
        #expect(
            CompactRest.resolve(
                farewell: nil, playingNowPlaying: playing, runningTimer: nil,
                closeEvent: nil, nowPlaying: playing, selected: nil, standing: dictation()
            ) == playing
        )
    }

    /// A recording light is urgent and a countdown is running out; dictation is
    /// a few seconds of the user's own doing.
    @Test("It is the last of the standing tenants")
    func ranksLastInTheSeat() {
        let privacy = SatelliteContent.privacy(camera: true, microphone: false)
        #expect(
            SatelliteArbiter.resolve(
                transient: nil, privacy: nil, timer: nil,
                timerIsMainIsland: false, dictation: .dictation
            ) == .dictation
        )
        #expect(
            SatelliteArbiter.resolve(
                transient: nil, privacy: privacy, timer: nil,
                timerIsMainIsland: false, dictation: .dictation
            ) == privacy
        )
    }
}

@Suite("A paused track stays dead until something un-pauses it")
@MainActor
struct LingerResurrectionTests {

    private func paused() -> Activity {
        Activity(
            id: ActivityID(kind: .nowPlaying, source: "com.apple.Safari"), createdAt: 0,
            payload: .nowPlaying(NowPlayingPayload(title: "A film", artist: "x", isPlaying: false))
        )
    }

    private func dictation() -> Activity {
        Activity(
            id: PrivacyProvider.activityID, createdAt: 0,
            payload: .privacy(PrivacyPayload(micActive: true, isSystemSpeech: true))
        )
    }

    /// The reported sequence: a video paused hours earlier claimed the ears two
    /// seconds after dictation started. The linger seat is fed by the
    /// coordinator, and feeding it required only that *something* was resting
    /// — so anything taking the island brought the corpse with it.
    @Test("An unrelated resident does not hand the ears to a stale track")
    func staleTrackStaysOut() {
        // What the coordinator now passes once the linger has run out: nothing.
        #expect(
            CompactRest.resolve(
                farewell: nil, playingNowPlaying: nil, runningTimer: nil,
                closeEvent: nil, nowPlaying: nil, selected: paused(), standing: dictation()
            ) == dictation()
        )
    }

    /// And while the linger *is* running, the track still has its seat — the
    /// courtesy is unchanged, only its bookkeeping.
    @Test("Inside its linger it still holds the ears")
    func freshPauseStillLingers() {
        #expect(
            CompactRest.resolve(
                farewell: nil, playingNowPlaying: nil, runningTimer: nil,
                closeEvent: nil, nowPlaying: paused(), selected: nil, standing: dictation()
            ) == paused()
        )
    }
}
