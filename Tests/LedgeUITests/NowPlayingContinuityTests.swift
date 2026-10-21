import AppKit
import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// What the music ears and the card show while one song becomes another, or
/// while playback stops and starts. Each of these was a hard cut that the
/// rest of the card works to avoid: the ears dropped to a grey note and grey
/// bars until the new cover came, the card's bars fell flat in one frame on
/// pause, and two quick skips turned the card back on the placeholder between
/// two covers that were both in hand.
///
/// None of this may depend on how busy the main actor is. In the full suite
/// other suites share it, and a single `await` can take seconds — longer than
/// any fade, and longer than the ears' hold. So the frame that matters, the
/// first one after a change, is drawn in the same turn of the main actor as
/// the change itself (`firstFrame`), and a marker in the corner proves that
/// frame really shows the change. Only end states are waited for, by polling.
@Suite("Now Playing changes without a flash", .serialized)
@MainActor
struct NowPlayingContinuityTests {

    @Observable @MainActor
    final class Model {
        private(set) var payload: NowPlayingPayload
        /// Bumped with every change, and drawn as the marker's colour.
        private(set) var tick = 0
        init(_ payload: NowPlayingPayload) { self.payload = payload }
        func set(_ payload: NowPlayingPayload) {
            self.payload = payload
            tick += 1
        }
    }

    /// A 4 pt square, white on odd ticks: the proof that a captured frame
    /// already includes the change it is being asked about. Placed where the
    /// view under test draws nothing.
    private struct Marker: View {
        let model: Model
        let at: CGPoint
        var body: some View {
            Rectangle()
                .fill(model.tick % 2 == 1 ? Color.white : Color.black)
                .frame(width: 4, height: 4)
                .offset(x: at.x, y: at.y)
        }
    }

    private static let earsMarker = CGPoint(x: 158, y: 2)
    private static let artMarker = CGPoint(x: 0, y: 0)
    private static let cardMarker = CGPoint(x: 2, y: 158)

    private struct Ears: View {
        let model: Model
        var body: some View {
            CompactEarsView(
                activity: Activity(id: ActivityID(kind: .nowPlaying, source: "com.spotify.client"),
                                   createdAt: 0, payload: .nowPlaying(model.payload)),
                cutoutWidth: 180, inset: 10
            )
            .frame(width: 320, height: 40)
            .background(Color.black)
            .overlay(alignment: .topLeading) { Marker(model: model, at: NowPlayingContinuityTests.earsMarker) }
        }
    }

    private struct Artwork: View {
        let model: Model
        var body: some View {
            NowPlayingArtwork(payload: model.payload, size: 44, radius: 10)
                .frame(width: 60, height: 60)
                .background(Color.black)
                .overlay(alignment: .topLeading) { Marker(model: model, at: NowPlayingContinuityTests.artMarker) }
        }
    }

    private struct Card: View {
        let model: Model
        var body: some View {
            NowPlayingCardView(payload: model.payload, actions: NowPlayingActions())
                .frame(width: 270, height: 164, alignment: .top)
                .background(Color.black)
                .overlay(alignment: .topLeading) { Marker(model: model, at: NowPlayingContinuityTests.cardMarker) }
        }
    }

    @MainActor
    private struct Host {
        let window: NSWindow
        let view: NSView
        func close() { window.orderOut(nil); window.close() }
    }

    private func host(_ root: some View, size: CGSize) -> Host {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let view = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        view.sizingOptions = []
        view.frame = CGRect(origin: .zero, size: size)
        window.contentView = view
        window.orderFrontRegardless()
        return Host(window: window, view: view)
    }

    /// One frame captured with the time it was taken.
    private struct Frame {
        let pixels: (data: [UInt8], width: Int, height: Int)
        let scale: CGFloat
        /// Seconds from the change to the capture.
        let after: TimeInterval
    }

    /// Applies `change` and draws the first frame that includes it, without
    /// letting the main actor go: the run loop is turned here, synchronously,
    /// so no other suite's work can slip in between the change and the
    /// capture, and none of this view's own tasks can run either.
    ///
    /// What that frame can prove does not depend on timing: a cut already
    /// shows the end state on it, and a fade does not. How far a fade has
    /// got by then does depend on timing — on when the display link fires —
    /// so nothing here asserts that.
    private func firstFrame(_ host: Host, model: Model, marker: CGPoint,
                            after change: () -> Void) -> Frame {
        change()
        let start = Date()
        let tick = model.tick
        var frame = capture(host, since: start)
        // At least one turn, and until the marker shows this change.
        repeat {
            turnRunLoop(0.01)
            frame = capture(host, since: start)
        } while !shows(tick, in: frame, at: marker) && frame.after < 2
        #expect(shows(tick, in: frame, at: marker), "the captured frame includes the change")
        return frame
    }

    /// Turns the run loop without giving up the main actor: SwiftUI's
    /// updates and animations move on, while every task waits — the views'
    /// own and every other suite's.
    private func turnRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ host: Host, since start: Date) -> Frame {
        let rect = host.view.bounds
        let rep = host.view.bitmapImageRepForCachingDisplay(in: rect)!
        host.view.cacheDisplay(in: rect, to: rep)
        let image = rep.cgImage!
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Frame(pixels: (data, w, h), scale: CGFloat(w) / rect.width,
                     after: Date().timeIntervalSince(start))
    }

    private func shows(_ tick: Int, in frame: Frame, at marker: CGPoint) -> Bool {
        let p = frame.pixels
        let x = Int((marker.x + 2) * frame.scale), y = Int((marker.y + 2) * frame.scale)
        let lit = p.data[(y * p.width + x) * 4] > 128
        return lit == (tick % 2 == 1)
    }

    /// Lets the views' own main-actor tasks and the run loop move on.
    private func wait(_ seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Polls until `done` holds for a fresh frame. Returns the last frame.
    ///
    /// Bounded by turns, not by the clock. Another suite can hold the main
    /// actor for many seconds; a deadline then passed while this was waiting
    /// behind it, and the loop gave up on its next wake before the view's own
    /// task — queued behind it too — had had its turn. Each turn here gives
    /// the main actor away, so whatever is ready runs before the next look.
    private func eventually(_ host: Host, _ done: (Frame) -> Bool) async -> Frame {
        let start = Date()
        var frame = capture(host, since: start)
        for _ in 0..<200 where !done(frame) {
            await wait(0.05)
            frame = capture(host, since: start)
        }
        return frame
    }

    private struct Census {
        var red = 0, blue = 0, green = 0, grey = 0
        /// Mean of the lit pixels, so a blend reads as a blend.
        var mean = (r: 0.0, g: 0.0, b: 0.0)
    }

    private func census(_ frame: Frame, in rect: CGRect) -> Census {
        let p = frame.pixels, s = frame.scale
        var c = Census()
        var lit = 0, sr = 0, sg = 0, sb = 0
        for y in Int(rect.minY * s)..<min(Int(rect.maxY * s), p.height) {
            for x in Int(rect.minX * s)..<min(Int(rect.maxX * s), p.width) {
                let i = (y * p.width + x) * 4
                let r = Int(p.data[i]), g = Int(p.data[i + 1]), b = Int(p.data[i + 2])
                if max(r, g, b) > 40 { lit += 1; sr += r; sg += g; sb += b }
                if r > 170, g < 110, b < 110 { c.red += 1 }
                else if b > 170, r < 110 { c.blue += 1 }
                else if g > 150, r < 120, b < 150 { c.green += 1 }
                else if abs(r - g) < 12, abs(g - b) < 14, r > 40, r < 200 { c.grey += 1 }
            }
        }
        if lit > 0 { c.mean = (Double(sr) / Double(lit), Double(sg) / Double(lit), Double(sb) / Double(lit)) }
        return c
    }

    /// How far a mean colour has travelled from one end state to the other,
    /// read on the blue channel, which every change here moves the most.
    private func progress(_ now: Census, from: Census, to: Census) -> Double {
        (now.mean.b - from.mean.b) / (to.mean.b - from.mean.b)
    }

    /// The tallest lit column inside a rect, in pixels.
    private func tallest(_ frame: Frame, in rect: CGRect) -> Int {
        let p = frame.pixels, s = frame.scale
        var best = 0
        for x in Int(rect.minX * s)..<min(Int(rect.maxX * s), p.width) {
            var run = 0
            for y in Int(rect.minY * s)..<min(Int(rect.maxY * s), p.height) {
                let i = (y * p.width + x) * 4
                if (Int(p.data[i]) + Int(p.data[i + 1]) + Int(p.data[i + 2])) / 3 > 120 { run += 1 }
            }
            best = max(best, run)
        }
        return best
    }

    private static func cover(_ colour: NSColor) -> Data {
        let size = NSSize(width: 60, height: 60)
        let image = NSImage(size: size)
        image.lockFocus()
        colour.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    private static let redCover = cover(.systemRed)
    private static let blueCover = cover(.systemBlue)
    private static let greenCover = cover(.systemGreen)
    private static let red = AccentColor(red: 0.95, green: 0.2, blue: 0.2)
    private static let blue = AccentColor(red: 0.15, green: 0.35, blue: 0.98)

    private static func song(_ title: String, playing: Bool = true, art: Data? = nil,
                             accent: AccentColor = .neutral) -> NowPlayingPayload {
        NowPlayingPayload(
            title: title, artist: "Artist", isPlaying: playing, elapsed: 30, duration: 200,
            sourceName: "Spotify", accent: accent, itemKey: "spotify|\(title)",
            artworkKey: "spotify|\(title)#cover", artworkData: art, ownerIsApp: true
        )
    }

    private static let earsSize = CGSize(width: 320, height: 40)
    private static let tile = CGRect(x: 10, y: 0, width: 70, height: 40)
    private static let bars = CGRect(x: 240, y: 0, width: 70, height: 40)
    private static let face = CGRect(x: 8, y: 8, width: 44, height: 44)

    @Test("The ears keep the last cover and colour while the next song's cover is on its way")
    func earsHoldTheLastCover() async {
        let model = Model(Self.song("A", art: Self.redCover, accent: Self.red))
        let ears = host(Ears(model: model), size: Self.earsSize)
        defer { ears.close() }
        let start = await eventually(ears) { census($0, in: Self.tile).red > 100 }
        #expect(census(start, in: Self.tile).red > 100, "song A's red cover is on the tile to begin with")

        // As the provider publishes an uncached song: the title first, with
        // no cover and the neutral accent.
        _ = firstFrame(ears, model: model, marker: Self.earsMarker) { model.set(Self.song("B")) }
        // Longer than any fade, still without letting the main actor go: a
        // fade to the placeholder would be over by now, and the hold's own
        // task cannot have run.
        turnRunLoop(0.3)
        let frame = capture(ears, since: Date())
        let tile = census(frame, in: Self.tile)
        let bars = census(frame, in: Self.bars)
        #expect(tile.red > 100 && tile.grey < 40, "the tile still wears A's cover, not the grey note: \(tile)")
        #expect(bars.red > 10 && bars.grey < 10, "the bars keep A's colour, not grey: \(bars)")
    }

    @Test("A song that has no cover at all still settles on the placeholder")
    func earsSettleWithoutACover() async {
        let model = Model(Self.song("A", art: Self.redCover, accent: Self.red))
        let ears = host(Ears(model: model), size: Self.earsSize)
        defer { ears.close() }
        let start = await eventually(ears) { census($0, in: Self.tile).red > 100 }
        #expect(census(start, in: Self.tile).red > 100, "song A's cover is on the tile to begin with")

        _ = firstFrame(ears, model: model, marker: Self.earsMarker) { model.set(Self.song("B")) }
        // Polled: under load the hold's own task runs late, and what matters
        // is that it ends, not to the millisecond.
        let end = await eventually(ears) { census($0, in: Self.tile).grey > 100 }
        let tile = census(end, in: Self.tile)
        #expect(tile.red == 0 && tile.grey > 100, "the hold ran out and the note placeholder is up: \(tile)")
    }

    @Test("When the next song's cover comes, tile and colour cross-fade to it together")
    func earsCrossFadeToTheNewCover() async {
        let model = Model(Self.song("A", art: Self.redCover, accent: Self.red))
        let ears = host(Ears(model: model), size: Self.earsSize)
        defer { ears.close() }
        let a = await eventually(ears) { census($0, in: Self.tile).red > 100 }
        #expect(census(a, in: Self.tile).red > 100, "song A's cover is on the tile to begin with")

        // B with no cover, then its cover, both inside one turn of the main
        // actor: the hold cannot run out between them however busy the suite.
        var standingIn = Census()
        let frame = firstFrame(ears, model: model, marker: Self.earsMarker) {
            model.set(Self.song("B"))
            turnRunLoop(0.3)
            standingIn = census(capture(ears, since: Date()), in: Self.tile)
            model.set(Self.song("B", art: Self.blueCover, accent: Self.blue))
        }
        #expect(standingIn.red > 100, "A's cover is standing in while B's loads: \(standingIn)")

        let b = await eventually(ears) { census($0, in: Self.tile).blue > 100 }
        #expect(census(b, in: Self.tile).blue > 100, "and B's cover is up at the end")

        let tile = progress(census(frame, in: Self.tile), from: census(a, in: Self.tile), to: census(b, in: Self.tile))
        let bars = progress(census(frame, in: Self.bars), from: census(a, in: Self.bars), to: census(b, in: Self.bars))
        // A cut is already at the end state on the first frame with the change
        // in it. A fade has not got there yet.
        #expect(tile < 0.9, "tile \(Int(frame.after * 1000)) ms after the cover came: \(tile)")
        #expect(bars < 0.9, "bars \(Int(frame.after * 1000)) ms after the cover came: \(bars)")
    }

    @Test("A cover that arrives late cross-fades onto the card instead of cutting in")
    func lateCoverCrossFades() async {
        let model = Model(Self.song("A"))
        let art = host(Artwork(model: model), size: CGSize(width: 60, height: 60))
        defer { art.close() }
        let placeholder = await eventually(art) { census($0, in: Self.face).grey > 400 }
        #expect(census(placeholder, in: Self.face).grey > 400, "the placeholder is up while the cover loads")

        let frame = firstFrame(art, model: model, marker: Self.artMarker) {
            model.set(Self.song("A", art: Self.blueCover, accent: Self.red))
        }
        let cover = await eventually(art) { census($0, in: Self.face).blue > 1_500 }
        #expect(census(cover, in: Self.face).blue > 1_500, "the cover is there at the end")

        let travelled = progress(census(frame, in: Self.face),
                                 from: census(placeholder, in: Self.face), to: census(cover, in: Self.face))
        // A cut is already the cover on the first frame with it; a fade is not.
        #expect(travelled < 0.9, "\(Int(frame.after * 1000)) ms after the cover came: \(travelled)")
    }

    @Test("Two quick skips turn once onto the newest cover, never onto the placeholder")
    func quickSkipsNeverLandOnThePlaceholder() async {
        let model = Model(Self.song("A", art: Self.redCover))
        let art = host(Artwork(model: model), size: CGSize(width: 60, height: 60))
        defer { art.close() }
        let start = await eventually(art) { census($0, in: Self.face).red > 1_500 }
        #expect(census(start, in: Self.face).red > 1_500, "song A's cover is up to begin with")

        // Both changes inside the turn's out-leg, whatever the suite is doing.
        _ = firstFrame(art, model: model, marker: Self.artMarker) {
            model.set(Self.song("B", art: Self.blueCover))
            turnRunLoop(0.05)
            model.set(Self.song("C", art: Self.greenCover))
        }
        // Watched until the card has settled on C. A frame mid-turn may be
        // anything narrow; a full grey face is the placeholder.
        var sawPlaceholder = false
        let end = await eventually(art) { frame in
            let seen = census(frame, in: Self.face)
            if seen.grey > 1_200 { sawPlaceholder = true }
            return seen.green > 1_500
        }
        #expect(census(end, in: Self.face).green > 1_500, "the card ends on C, the newest cover")
        #expect(!sawPlaceholder, "the grey note never turned in between two covers")
    }

    @Test("The card's bars settle on pause instead of dropping flat in one frame")
    func cardBarsSettle() async {
        let model = Model(Self.song("A", art: Self.redCover))
        let card = host(Card(model: model), size: CGSize(width: 270, height: 164))
        defer { card.close() }
        let eq = CGRect(x: 222, y: 6, width: 44, height: 38)
        let resting = 6 // 3 pt at 2x
        let playing = await eventually(card) { tallest($0, in: eq) > resting + 4 }
        #expect(tallest(playing, in: eq) > resting + 4, "the bars are up while it plays")

        let frame = firstFrame(card, model: model, marker: Self.cardMarker) {
            model.set(Self.song("A", playing: false, art: Self.redCover))
        }
        #expect(tallest(frame, in: eq) > resting + 2,
                "\(Int(frame.after * 1000)) ms after the pause the bars are still up, not flat")
        let rest = await eventually(card) { tallest($0, in: eq) <= resting + 1 }
        #expect(tallest(rest, in: eq) <= resting + 1, "and then they settle onto the line")
    }
}
