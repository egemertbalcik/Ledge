import Foundation
import LedgeCore
import Testing
@testable import LedgeUI

/// The camera and the microphone each have a light in the ear. A single dot
/// used to show only the camera when both were on.
@Suite("Recording lights in the ear")
@MainActor
struct RecordingLightsTests {

    private func presentation(camera: Bool, microphone: Bool, resting: Bool = true) -> NotchPresentation {
        let presentation = NotchPresentation()
        if resting {
            presentation.nowPlaying = Activity(
                id: ActivityID(kind: .nowPlaying, source: "com.spotify.client"),
                createdAt: 0,
                payload: .nowPlaying(NowPlayingPayload(title: "Song", artist: "Artist", isPlaying: true))
            )
        }
        presentation.privacyActive = Activity(
            id: ActivityID(kind: .privacy, source: "privacy"),
            createdAt: 0,
            payload: .privacy(PrivacyPayload(cameraActive: camera, micActive: microphone))
        )
        return presentation
    }

    @Test("Both on shows both")
    func both() {
        #expect(presentation(camera: true, microphone: true).recordingLights(phase: .companion)
            == RecordingLights(camera: true, microphone: true))
    }

    @Test("Each alone shows alone")
    func alone() {
        #expect(presentation(camera: false, microphone: true).recordingLights(phase: .companion)
            == RecordingLights(camera: false, microphone: true))
        #expect(presentation(camera: true, microphone: false).recordingLights(phase: .companion)
            == RecordingLights(camera: true, microphone: false))
    }

    @Test("Neither on, or not resting, shows nothing")
    func nothing() {
        #expect(presentation(camera: false, microphone: false).recordingLights(phase: .companion) == nil)
        #expect(presentation(camera: true, microphone: true).recordingLights(phase: .idle) == nil)
    }

    /// Nothing resting means no ears to sit in: the lights don't float over
    /// an empty notch.
    @Test("With nothing resting beside the notch, no lights")
    func nothingResting() {
        let empty = presentation(camera: true, microphone: true, resting: false)
        #expect(empty.restingContent == nil, "the fixture left something resting")
        #expect(empty.recordingLights(phase: .companion) == nil)
    }

    @Test("A light alone sits centred")
    func centred() {
        #expect(RecordingLights(camera: true, microphone: false).cameraOffset == 0)
        #expect(RecordingLights(camera: false, microphone: true).microphoneOffset == 0)
    }

    @Test("Two stack around the centre, camera above, a gap apart")
    func stacked() {
        let both = RecordingLights(camera: true, microphone: true)
        #expect(both.cameraOffset < 0)
        #expect(both.microphoneOffset > 0)
        #expect(both.cameraOffset == -both.microphoneOffset)
        #expect(both.microphoneOffset - both.cameraOffset == RecordingLights.size + RecordingLights.gap)
    }

    @Test("What it says to VoiceOver names what is on")
    func label() {
        #expect(RecordingLights(camera: true, microphone: true).label == "Camera and microphone in use")
        #expect(RecordingLights(camera: true, microphone: false).label == "Camera in use")
        #expect(RecordingLights(camera: false, microphone: true).label == "Microphone in use")
    }

    // MARK: - Beside the satellite

    /// Music playing with a timer running: the timer takes the satellite and
    /// the trailing ear folds away, which used to cut the lights off.
    private func besideTimer(camera: Bool, microphone: Bool) -> NotchPresentation {
        let presentation = presentation(camera: camera, microphone: microphone)
        presentation.timerSession = Activity(
            id: ActivityID(kind: .timer, source: "timer"),
            createdAt: 0,
            payload: .timer(TimerPayload(label: "Focus", remaining: 600, total: 1_500, isRunning: true))
        )
        return presentation
    }

    @Test("Beside the satellite the island keeps room for the lights")
    func roomBesideTheSatellite() {
        let presentation = besideTimer(camera: false, microphone: true)
        #expect(presentation.satellite(phase: .companion) != nil, "the fixture never seated the timer")
        #expect(presentation.recordingLights(phase: .companion) != nil)
        #expect(presentation.recordingRoom(phase: .companion) == NotchLayout.recordingRoom)
    }

    @Test("No room is kept without lights, or without a satellite")
    func noRoomOtherwise() {
        let quiet = besideTimer(camera: false, microphone: false)
        #expect(quiet.satellite(phase: .companion) != nil, "the fixture never seated the timer")
        #expect(quiet.recordingRoom(phase: .companion) == 0)
        #expect(presentation(camera: true, microphone: true).recordingRoom(phase: .companion) == 0)
    }

    @Test("The satellite moves out by exactly the room, so its gap stays the same")
    func satelliteMovesByTheRoom() {
        let geometry = NotchGeometry(
            screenSize: CGSize(width: 1470, height: 956),
            notchSize: CGSize(width: 179, height: 32),
            notchCenterX: 735, isHardwareNotch: true
        )
        let size = CGSize(width: 400, height: 32)
        let plain = NotchLayout.satelliteRect(islandSize: size, geometry: geometry, gutterRadius: 8, offset: 5)
        let roomy = NotchLayout.satelliteRect(
            islandSize: size, geometry: geometry, gutterRadius: 8, offset: 5,
            recordingRoom: NotchLayout.recordingRoom
        )
        #expect(roomy.minX - plain.minX == NotchLayout.recordingRoom)
        #expect(roomy.size == plain.size)
        #expect(roomy.minY == plain.minY)
    }

    /// The view can't be animated in a test, so this reads it. Without a
    /// geometry group, a countdown redrawn mid-slide was placed where the
    /// satellite was headed while its disc was still on the way: the digits
    /// ran ahead of their circle.
    @Test("The satellite moves as one piece")
    func satelliteIsOnePiece() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let overlay = try String(
            contentsOf: root.appending(path: "Sources/LedgeUI/NotchOverlayView.swift"), encoding: .utf8
        )
        let start = try #require(overlay.range(of: "SatelliteView(content: content, diameter: seat.width)"))
        let after = overlay[start.upperBound...]
        let group = try #require(after.range(of: ".geometryGroup()"))
        let offset = try #require(after.range(of: ".offset(x: seat.minX)"))
        #expect(group.lowerBound < offset.lowerBound, "grouped before it is moved")
    }

    // MARK: - VoiceOver

    private func ears(recording: RecordingLights?) -> CompactEarsView {
        CompactEarsView(
            activity: Activity(
                id: ActivityID(kind: .nowPlaying, source: "com.spotify.client"), createdAt: 0,
                payload: .nowPlaying(NowPlayingPayload(title: "Song", artist: "Artist", isPlaying: true))
            ),
            cutoutWidth: 179, inset: 10, recording: recording
        )
    }

    @Test("VoiceOver hears the lights with what rests in the ears")
    func spokenWithTheEars() {
        let plain = ears(recording: nil).accessibilityDescription
        #expect(plain.contains("Song"))
        #expect(ears(recording: nil).spokenDescription == plain)
        #expect(ears(recording: RecordingLights(camera: false, microphone: true)).spokenDescription
            == "\(plain), microphone in use")
        #expect(ears(recording: RecordingLights(camera: true, microphone: true)).spokenDescription
            == "\(plain), camera and microphone in use")
    }

    /// The overlay can't be built in a test, so this reads it: the ears are
    /// told about the lights, and the lights don't speak a second time.
    @Test("The overlay hands the lights to the ears and hides the drawn ones")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let overlay = try String(
            contentsOf: root.appending(path: "Sources/LedgeUI/NotchOverlayView.swift"), encoding: .utf8
        )
        #expect(overlay.contains("recording: presentation.recordingLights(phase: phase),"))
        let lights = try #require(overlay.range(of: "RecordingLightsView(lights: lights)"))
        let after = overlay[lights.upperBound...].prefix(600)
        #expect(after.contains(".accessibilityHidden(true)"))
    }
}

