import Foundation
import LedgeCore
import SwiftUI
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

/// While the lights show, the trailing ear's content keeps out of their lane:
/// a long feed word or an outward nudge used to run under them.
@Suite("Trailing content gives the lights room")
@MainActor
struct TrailingEarLaneTests {

    private let ear: CGFloat = 48
    private var lane: CGFloat { RecordingLights.lane }

    private func place(_ width: CGFloat, nudge: CGFloat = 0, inward: CGFloat = 0,
                       lights: Bool = true) -> (x: CGFloat, width: CGFloat) {
        TrailingEarLayout.placement(earWidth: ear, contentWidth: width, nudge: nudge,
                                    inward: inward, lane: lights ? lane : 0)
    }

    @Test("The lane is the lights, their margin and four points before them")
    func laneSize() {
        #expect(lane - RecordingLights.edgeMargin - RecordingLights.size == 4)
    }

    @Test("Without lights the content sits where it always did")
    func noLights() {
        for nudge: CGFloat in [-20, -8, 0, 12] {
            let spot = place(42, nudge: nudge, inward: 2, lights: false)
            #expect(spot.x == (ear - 42) / 2 - 2 - nudge)
            #expect(spot.width == 42)
        }
    }

    @Test("Content that already stops short of the lights doesn't move")
    func fits() {
        #expect(place(20).x == 14)
        #expect(place(20).width == 20)
        // Inward nudges only take it further from them.
        #expect(place(30, nudge: 12).x == -3)
        // Ending exactly at the lane, as the waveform does, is room enough.
        let snug = ear - lane - 20
        #expect(place(20, nudge: (ear - 20) / 2 - snug).x == snug)
        // Nor is a rounding hair past it: the waveform must not twitch.
        let hair = snug + 0.2
        #expect(place(20, nudge: (ear - 20) / 2 - hair).x == hair)
    }

    @Test("Nudged outward, it comes back only as far as the lane")
    func pulledBack() {
        let spot = place(20, nudge: -12)
        #expect(spot.x + spot.width == ear - lane)
        #expect(spot.width == 20)
        #expect(spot.x >= (ear - 20) / 2)
    }

    @Test("Never further in than a nudge of zero puts it; then it gets less width")
    func shrinks() {
        let spot = place(42, inward: 1)
        #expect(spot.x == (ear - 42) / 2 - 1)
        #expect(spot.x + spot.width == ear - lane)
        let outward = place(42, nudge: -10, inward: 1)
        #expect(outward.x == spot.x)
        #expect(outward.width == spot.width)
    }

    /// Drawn for real, offscreen, at 2x: a bar that takes whatever width it
    /// is offered, up to 42, as a feed's word does. Returns the red columns,
    /// in pixels.
    private func drawn(lights: Bool, nudge: CGFloat = 0) throws -> ClosedRange<Int> {
        let view = TrailingEarLayout(nudge: nudge, inward: 0, lane: lights ? lane : 0) {
            Color(red: 1, green: 0, blue: 0).frame(maxWidth: 42).frame(height: 10)
        }
        .frame(width: ear, height: 10)
        .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(image.dataProvider?.data as Data?)
        let row = image.bytesPerRow * 10
        let step = image.bitsPerPixel / 8
        // Red in either byte order, and nothing half-covered.
        let red = (0..<image.width).filter { x in
            let pixel = row + x * step
            let first = data[pixel], second = data[pixel + 1], third = data[pixel + 2]
            return second < 40 && max(first, third) > 200 && min(first, third) < 40
        }
        let first = try #require(red.first)
        let last = try #require(red.last)
        return first...last
    }

    @Test("Drawn, the content ends before the lane only while the lights show")
    func drawnForReal() throws {
        #expect(try drawn(lights: false) == 6...89)
        let lit = try drawn(lights: true)
        #expect(lit == 6...Int((ear - lane) * 2) - 1)
        #expect(try drawn(lights: true, nudge: -10) == lit)
    }

    @Test("The lane ends four points before where the lights are drawn")
    func laneMeetsTheLights() {
        // Ears are padded by the gutter, so their outer edge is the island's
        // width less the gutter: the edge the lane is measured from.
        let island: CGFloat = 300, gutter: CGFloat = 10
        #expect(island - gutter - lane + RecordingLights.clearance
            == RecordingLights.earEndX(islandWidth: island, gutter: gutter))
        #expect(RecordingLights.earEndX(islandWidth: island, gutter: gutter) + RecordingLights.size
            + RecordingLights.edgeMargin == island - gutter)
    }

    @Test("Beside the satellite the lights sit centred in the room kept for them")
    func besideSatellite() {
        let island: CGFloat = 300, gutter: CGFloat = 10, ear: CGFloat = 48
        let cutout = island - gutter - ear
        let x = RecordingLights.besideSatelliteX(islandWidth: island, gutter: gutter, earWidth: ear)
        #expect(x - cutout == cutout + NotchLayout.recordingRoom - (x + RecordingLights.size))
        #expect(x > cutout)
        #expect(x + RecordingLights.size < cutout + NotchLayout.recordingRoom)
    }

    @Test("A ring is no wider than it is offered; without lights that never binds")
    func ringFitsItsWidth() {
        #expect(FeedEar.diameter(forHeight: 38.5, width: 23.5) == 23.5)
        #expect(FeedEar.diameter(forHeight: 38.5, width: 60) == FeedEar.diameter(forHeight: 38.5))
        #expect(FeedEar.diameter(forHeight: 38.5, width: .nan) == FeedEar.diameter(forHeight: 38.5))
        // The tallest ring is narrower than the narrowest ear.
        for height: CGFloat in [20, 32.5, 38.5, 60, 200] {
            #expect(FeedEar.diameter(forHeight: height, width: NotchLayout.sanitizedEarWidth(0))
                == FeedEar.diameter(forHeight: height))
        }
    }

    /// The real ears, with a feed's ring and words on the right, at the
    /// narrowest ear on a 14-inch Pro: 36 × 1.03 wide, 38.5 tall. Returns the
    /// rightmost painted column of the trailing ear, in points, and the
    /// painted width there.
    private func feedRing(lights: Bool) throws -> (right: CGFloat, width: CGFloat) {
        let ear: CGFloat = 36 * 1.03, cutout: CGFloat = 180, inset: CGFloat = 10
        let island = inset * 2 + ear * 2 + cutout
        let feed = Activity(
            id: ActivityID(kind: .feeds, source: "test"), createdAt: 0,
            payload: .feeds(FeedPayload(title: "Limits", compactTrailing: "91",
                                        compactTrailingFraction: 1,
                                        updatedAt: Date().timeIntervalSince1970))
        )
        let view = CompactEarsView(
            activity: feed, cutoutWidth: cutout, inset: inset,
            recording: lights ? RecordingLights(camera: false, microphone: true) : nil
        )
        .frame(width: island, height: 38.5)
        .background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(image.dataProvider?.data as Data?)
        let step = image.bitsPerPixel / 8
        let start = Int((inset + ear + cutout) * 2)
        let painted = (start..<image.width).filter { x in
            (0..<image.height).contains { y in
                let pixel = y * image.bytesPerRow + x * step
                return Int(data[pixel]) + Int(data[pixel + 1]) + Int(data[pixel + 2]) > 90
            }
        }
        let first = try #require(painted.first)
        let last = try #require(painted.last)
        return (CGFloat(last + 1) / 2, CGFloat(last + 1 - first) / 2)
    }

    @Test("A narrow ear's ring clears the light, and is full size without one")
    func narrowEarRing() throws {
        let ear: CGFloat = 36 * 1.03, inset: CGFloat = 10
        let island = inset * 2 + ear * 2 + 180
        let plain = try feedRing(lights: false)
        // Full size: the ring as tall as the ear allows.
        #expect(abs(plain.width - FeedEar.diameter(forHeight: 38.5)) <= 1)
        let lit = try feedRing(lights: true)
        // Clear of the drawn light by the clearance, give or take a pixel.
        let light = RecordingLights.earEndX(islandWidth: island, gutter: inset)
        #expect(lit.right <= light - RecordingLights.clearance + 0.5)
        #expect(lit.width < plain.width)
    }

    /// The ears hand the layout the lane only while there are lights.
    @Test("The ears clear the lane only while lights show")
    func wiring() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ears = try String(
            contentsOf: root.appending(path: "Sources/LedgeUI/Cards/CompactEarsView.swift"), encoding: .utf8
        )
        #expect(ears.contains("lane: recording == nil ? 0 : RecordingLights.lane"))
        #expect(ears.contains("nudge: trailingOffset,\n                inward: inwardNudge,"))
    }
}
