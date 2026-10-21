import AppKit
import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// The rail moves rather than jumps.
///
/// A press reaches the card the way the app delivers it: the provider
/// publishes a new payload with no animation around it. The card is drawn in
/// a window twenty thousand points off every screen and photographed as it
/// goes; the beads are found in the pixels. Off sits at 17pt and Coffee at
/// 137.5pt on the 275pt card, so a frame with one bead, and only one,
/// anywhere in between is a bead travelling — and before the fix every
/// photograph had it at one end or the other, or one at each.
@Suite("The Keep Awake rail in motion", .serialized)
@MainActor
struct KeepAwakeRailMotionTests {

    @MainActor @Observable
    final class Box {
        var payload: KeepAwakePayload
        init(_ payload: KeepAwakePayload) { self.payload = payload }
    }

    struct Stage: View {
        let box: Box
        let reduceMotion: Bool
        var body: some View {
            KeepAwakeCardView(payload: box.payload)
                .frame(width: 275, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
                .transformEnvironment(\.self) { $0._accessibilityReduceMotion = reduceMotion }
        }
    }

    /// One photograph of the card, as plain sRGB bytes. Read pixel by pixel
    /// through the bitmap's own colour lookup, these tests cost enough in a
    /// debug build to starve the timing-sensitive suites running beside them.
    struct Frame {
        let w: Int, h: Int
        private let bytes: [UInt8]

        init?(_ rep: NSBitmapImageRep) {
            guard let image = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            w = image.width
            h = image.height
            var b = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            bytes = b
        }

        /// sRGB at (x, y), y = 0 at the top; black outside the frame.
        func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            guard x >= 0, y >= 0, x < w, y < h else { return (0, 0, 0) }
            let i = (y * w + x) * 4
            return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
        }
    }

    private static let off = KeepAwakePayload(phase: .ready, lid: .off)
    private static let coffee = KeepAwakePayload(phase: .running, isIndefinite: true, lid: .off)
    private static let lidPending = KeepAwakePayload(phase: .running, remaining: 7200, until: "16:30",
                                                     lidHeld: false, lidClosed: true, lid: .applying)
    private static let finished = KeepAwakePayload(phase: .finished(.endedByYou), isIndefinite: true,
                                                   lid: .off, resumable: 3600)

    /// Shows the card, publishes `to`, and photographs it for 0.5 s.
    private func film(from: KeepAwakePayload, to: KeepAwakePayload,
                      reduceMotion: Bool = false,
                      then: [(at: TimeInterval, payload: KeepAwakePayload)] = []) -> [Frame] {
        _ = NSApplication.shared
        let box = Box(from)
        let size = CGSize(width: 275, height: 150)
        let host = NSHostingView(rootView: Stage(box: box, reduceMotion: reduceMotion))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        box.payload = to
        var frames: [Frame] = []
        let start = Date()
        var later = then
        for i in 1 ... 30 {
            RunLoop.main.run(until: start.addingTimeInterval(Double(i) / 60))
            // Presses that follow, published at their time as the provider would.
            while let next = later.first, Date().timeIntervalSince(start) >= next.at {
                box.payload = next.payload
                later.removeFirst()
            }
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let frame = Frame(rep) { frames.append(frame) }
        }
        return frames
    }

    /// Where a card at rest on `payload` draws its bead.
    private func settled(_ payload: KeepAwakePayload) -> CGFloat? {
        film(from: payload, to: payload).last.flatMap(beadX)
    }

    /// Bead-white pixels around `x` (points), on the track's line and above
    /// the stop names, whose own tint fades when the chosen stop changes.
    private func whiteBead(_ rep: Frame, at x: CGFloat) -> Int {
        let scale = CGFloat(rep.w) / 275
        var n = 0
        for px in Int((x - 8) * scale) ..< Int((x + 8) * scale) {
            for y in Int(48 * scale) ..< Int(69 * scale) {
                let c = rep.rgb(px, y)
                if c.r > 0.7 && c.g > 0.7 && c.b > 0.7 { n += 1 }
            }
        }
        return n
    }

    /// Top of the Off stop's grey mark, in points: where the rail is.
    private func railTop(_ rep: Frame, at x: CGFloat) -> CGFloat? {
        let scale = CGFloat(rep.w) / 275
        let px = Int(x * scale)
        for y in Int(45 * scale) ..< Int(110 * scale) {
            let c = rep.rgb(px, y)
            let grey = abs(c.r - c.b) < 0.04
            if grey, c.r > 0.18, c.r < 0.36 { return CGFloat(y) / scale }
        }
        return nil
    }

    /// Every bead in the frame, by centre in points.
    ///
    /// A bead is a run of neighbouring columns, in the rail's band, each with
    /// tan or white ink spanning more height than the track, the stop marks
    /// or the labels could make. Each run is one bead. Averaging every such
    /// column instead read a disc fading on Coffee beside a ring fading in on
    /// Lid shut as one bead halfway between them — the very regression these
    /// tests exist to catch.
    ///
    /// Tan and white are measured apart: the tan fill on the track above a
    /// white stop name spans the band too, and is not a bead.
    private func beads(_ rep: Frame) -> [CGFloat] {
        let scale = CGFloat(rep.w) / 275
        var runs: [[Int]] = []
        for x in 0 ..< rep.w {
            var tan = (top: -1, bottom: -1), white = (top: -1, bottom: -1)
            for y in Int(45 * scale) ..< Int(75 * scale) {
                let c = rep.rgb(x, y)
                // Low enough to keep the waiting ring at the faint end of
                // its breath, which is 0.4 of the tint.
                if c.r > 0.25 && c.r > c.b + 0.1 { if tan.top < 0 { tan.top = y }; tan.bottom = y }
                if c.r > 0.7 && c.g > 0.7 && c.b > 0.7 { if white.top < 0 { white.top = y }; white.bottom = y }
            }
            let tall = 10 * scale
            guard (tan.top >= 0 && CGFloat(tan.bottom - tan.top + 1) >= tall)
                || (white.top >= 0 && CGFloat(white.bottom - white.top + 1) >= tall) else { continue }
            // A one-pixel gap is antialiasing, not the space between two beads.
            if let last = runs.last?.last, x - last <= 2 { runs[runs.count - 1].append(x) } else { runs.append([x]) }
        }
        return runs.map { CGFloat($0.reduce(0, +)) / CGFloat($0.count) / scale }
    }

    /// The bead's centre in points, when the frame has exactly one.
    private func beadX(_ rep: Frame) -> CGFloat? {
        let found = beads(rep)
        return found.count == 1 ? found[0] : nil
    }

    /// Whether some frame has one bead, and only one, well clear of both stops.
    private func travelled(_ frames: [Frame], from start: CGFloat, to end: CGFloat) -> Bool {
        frames.contains { frame in
            let found = beads(frame)
            return found.count == 1 && found[0] > min(start, end) + 12 && found[0] < max(start, end) - 12
        }
    }

    /// Films up to three times, until `seen` finds the in-between it is
    /// looking for, and hands back the last film.
    ///
    /// An in-between lasts a fifth of a second at most. A test process kept
    /// off the main thread that long — the full suite runs beside other
    /// builds — photographs only the two ends, which looks exactly like a
    /// cut. A real cut shows no in-between on any attempt.
    private func caught(_ take: () -> [Frame],
                        _ seen: ([Frame]) -> Bool) -> (Bool, [Frame]) {
        var frames: [Frame] = []
        for _ in 0 ..< 3 {
            frames = take()
            if seen(frames) { return (true, frames) }
        }
        return (false, frames)
    }

    /// Draws `view` in a card-sized window off every screen and photographs it.
    private func still(_ view: some View) -> Frame? {
        _ = NSApplication.shared
        let size = CGSize(width: 275, height: 150)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.black))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return Frame(rep)
    }

    @Test("A disc fading out on Coffee while a ring fades in on Lid shut is not a bead travelling")
    func twoFadingBeadsAreNotTravel() throws {
        // The defect the travel tests exist to catch, drawn directly: the
        // card's own tint and bead sizes, on the rail's line, at the two
        // stops a settled card uses.
        let start = try #require(settled(Self.coffee))
        let end = try #require(settled(Self.lidPending))
        let tint = KeepAwakeCardView.tint
        let frames = try [1.0, 0.75, 0.5, 0.25, 0.0].map { left in
            try #require(still(ZStack(alignment: .topLeading) {
                Circle().fill(tint)
                    .frame(width: 14, height: 14)
                    .offset(x: start - 7, y: 52)
                    .opacity(left)
                Circle().fill(Color.black)
                    .overlay(Circle().strokeBorder(tint, lineWidth: 1.5))
                    .frame(width: 14, height: 14)
                    .offset(x: end - 7, y: 52)
                    .opacity(1 - left)
            }))
        }
        // Reached: the halfway frame really does hold both beads, one per stop.
        let halfway = beads(frames[2])
        #expect(halfway.count == 2, "both beads should be found: \(halfway)")
        #expect(halfway.contains { abs($0 - start) < 3 } && halfway.contains { abs($0 - end) < 3 },
                "one bead on each stop: \(halfway)")
        // And the travel check refuses it.
        #expect(!travelled(frames, from: start, to: end), "two fading beads read as travel: \(frames.map(beads))")
    }

    @Test("Off to Coffee: the bead travels")
    func offToCoffeeTravels() throws {
        let start = try #require(settled(Self.off))
        let end = try #require(settled(Self.coffee))
        let (moved, frames) = caught({ film(from: Self.off, to: Self.coffee) }) {
            travelled($0, from: start, to: end) && $0.allSatisfy { beads($0).count <= 1 }
        }
        let seen = frames.map(beads)
        // Reached: the bead ends where a card at rest on Coffee draws it.
        let last = try #require(frames.last.flatMap(beadX))
        #expect(abs(last - end) < 1, "the bead should end on Coffee (\(end)), got \(seen)")
        // One bead the whole way, never one leaving and another arriving.
        #expect(seen.allSatisfy { $0.count <= 1 }, "two beads at once: \(seen)")
        // And on its way it was well clear of both stops.
        #expect(moved, "the bead jumped: \(seen)")
    }

    @Test("Coffee to Lid shut: the bead travels while it turns into a ring")
    func coffeeToLidTravels() throws {
        let start = try #require(settled(Self.coffee))
        let end = try #require(settled(Self.lidPending))
        let (moved, frames) = caught({ film(from: Self.coffee, to: Self.lidPending) }) {
            travelled($0, from: start, to: end) && $0.allSatisfy { beads($0).count <= 1 }
        }
        let seen = frames.map(beads)
        let last = try #require(frames.last.flatMap(beadX))
        #expect(abs(last - end) < 1, "the bead should end on Lid shut (\(end)), got \(seen)")
        // One bead in flight between the stops. A disc fading out on Coffee
        // while a ring fades in on the far stop is two beads, and fails here.
        #expect(seen.allSatisfy { $0.count <= 1 }, "two beads at once: \(seen)")
        #expect(moved, "the bead never left Coffee: \(seen)")
    }

    @Test("The figure arriving moves the rail down, rather than jumping it")
    func railGlidesWhenTheFigureArrives() throws {
        let off = try #require(settled(Self.off))
        let before = try #require(film(from: Self.coffee, to: Self.coffee).last.flatMap { railTop($0, at: off) })
        let after = try #require(film(from: Self.lidPending, to: Self.lidPending).last.flatMap { railTop($0, at: off) })
        // Reached: a timed hold's figure really does sit the rail lower.
        #expect(after - before > 4, "the rail should move down: \(before) -> \(after)")
        let (glided, frames) = caught({ film(from: Self.coffee, to: Self.lidPending) }) {
            $0.compactMap { self.railTop($0, at: off) }.contains { $0 > before + 1 && $0 < after - 1 }
        }
        let tops = frames.compactMap { railTop($0, at: off) }
        #expect(glided, "the rail jumped: \(tops)")
    }

    @Test("Under Reduce Motion the bead fades across, neither sliding nor cutting")
    func reducedFades() throws {
        let start = try #require(settled(Self.off))
        let end = try #require(settled(Self.coffee))
        let full = whiteBead(film(from: Self.off, to: Self.off).last!, at: start)
        // The sentence under the rail fades too: some frame of its band is
        // neither the old sentence nor the new one.
        func sentence(_ rep: Frame) -> Data {
            let scale = CGFloat(rep.w) / 275
            var bytes: [UInt8] = []
            for y in stride(from: Int(92 * scale), to: min(rep.h, Int(125 * scale)), by: 1) {
                for x in stride(from: 0, to: rep.w, by: 3) {
                    bytes.append(UInt8((rep.rgb(x, y).r * 255).rounded()))
                }
            }
            return Data(bytes)
        }
        let first = sentence(film(from: Self.off, to: Self.off).last!)
        func beadFading(_ frames: [Frame]) -> Bool {
            frames.map { whiteBead($0, at: start) }.contains { $0 > 0 && $0 < full * 9 / 10 }
        }
        func sentenceFading(_ frames: [Frame]) -> Bool {
            let final = sentence(frames.last!)
            return frames.dropLast().contains { let s = sentence($0); return s != first && s != final }
        }
        let (faded, frames) = caught({ film(from: Self.off, to: Self.coffee, reduceMotion: true) }) {
            beadFading($0) && sentenceFading($0)
        }
        // Reached: it does end on Coffee, with nothing left on Off, and the
        // sentence did change.
        let last = try #require(frames.last.flatMap(beadX))
        #expect(abs(last - end) < 1)
        #expect(whiteBead(frames.last!, at: start) == 0)
        #expect(first != sentence(frames.last!), "the sentence should change")
        // Never in between.
        // Every bead counts: here two are expected at once, one fading on
        // each stop, and neither may be between them.
        let all = frames.flatMap(beads)
        #expect(!all.contains { $0 > start + 12 && $0 < end - 12 }, "it slid: \(frames.map(beads))")
        // And the Off bead and the old sentence were seen part-way gone.
        #expect(faded, "it cut: full \(full), \(frames.map { whiteBead($0, at: start) })")
    }

    /// How much of the sentence in `ref` is drawn in `rep`, 0 to 1: its own
    /// glyph pixels — those `other` never lights — against their brightness
    /// at rest, averaged.
    private func sentenceShown(_ rep: Frame, of ref: Frame,
                               not other: Frame) -> Double {
        let scale = CGFloat(rep.w) / 275
        func lum(_ r: Frame, _ x: Int, _ y: Int) -> Double {
            let c = r.rgb(x, y)
            return c.r * 0.3 + c.g * 0.59 + c.b * 0.11
        }
        var sum = 0.0, n = 0
        for y in Int(92 * scale) ..< min(rep.h, Int(128 * scale)) {
            for x in stride(from: 0, to: rep.w, by: 1) {
                let own = lum(ref, x, y)
                guard own > 0.28 else { continue }
                var clash = false
                for dy in -2 ... 2 { for dx in -2 ... 2 where lum(other, x + dx, y + dy) > 0.14 { clash = true } }
                if clash { continue }
                sum += min(1, lum(rep, x, y) / own)
                n += 1
            }
        }
        return n == 0 ? 0 : sum / Double(n)
    }

    @Test("The sentence under the rail goes out before the new one comes in", arguments: [false, true])
    func sentenceNeverOverprints(reduceMotion: Bool) throws {
        let old = try #require(film(from: Self.off, to: Self.off, reduceMotion: reduceMotion).last)
        let new = try #require(film(from: Self.coffee, to: Self.coffee, reduceMotion: reduceMotion).last)
        let frames = film(from: Self.off, to: Self.coffee, reduceMotion: reduceMotion)
        let shown = frames.map { (sentenceShown($0, of: old, not: new), sentenceShown($0, of: new, not: old)) }
        // Reached: the old sentence is gone and the new one fully in.
        let last = try #require(shown.last)
        #expect(last.0 < 0.1 && last.1 > 0.9, "the sentence never changed: \(shown)")
        // And no frame drew both: the worse of the two is what can be read.
        let worst = shown.map { min($0.0, $0.1) }.max() ?? 1
        #expect(worst < 0.1, "both sentences at once, worst \(worst): \(shown)")
    }

    @Test("Pressing back and forth never brings a leaving sentence back over the arriving one")
    func rapidPressesNeverOverprint() throws {
        let old = try #require(film(from: Self.off, to: Self.off).last)
        let new = try #require(film(from: Self.coffee, to: Self.coffee).last)
        // Coffee, Off, Coffee, a press every 60 ms.
        let frames = film(from: Self.off, to: Self.coffee,
                          then: [(0.06, Self.off), (0.12, Self.coffee)])
        let shown = frames.map { (sentenceShown($0, of: old, not: new), sentenceShown($0, of: new, not: old)) }
        let last = try #require(shown.last)
        #expect(last.0 < 0.1 && last.1 > 0.9, "it should settle on Coffee's sentence: \(shown)")
        let worst = shown.map { min($0.0, $0.1) }.max() ?? 1
        #expect(worst < 0.1, "both sentences at once, worst \(worst): \(shown)")
    }

    /// How much of the third stop's name in `ref` is drawn in `rep`, 0 to 1,
    /// wherever the rail has carried it: grey and white pixels only, so the
    /// tan ring beside it never counts as a word.
    private func thirdLabelShown(_ rep: Frame, of ref: Frame, not other: Frame,
                                 shifts: ClosedRange<Int>) -> Double {
        let scale = CGFloat(rep.w) / 275
        func lum(_ r: Frame, _ x: Int, _ y: Int) -> Double {
            let c = r.rgb(x, y)
            return abs(c.r - c.b) > 0.06 ? 0 : c.r * 0.3 + c.g * 0.59 + c.b * 0.11
        }
        var glyphs: [(Int, Int, Double)] = []
        for y in Int(64 * scale) ..< Int(100 * scale) {
            for x in Int(170 * scale) ..< rep.w {
                let own = lum(ref, x, y)
                guard own > 0.28 else { continue }
                var clash = false
                for dy in -2 ... 2 { for dx in -2 ... 2 where lum(other, x + dx, y + dy) > 0.14 { clash = true } }
                if !clash { glyphs.append((x, y, own)) }
            }
        }
        guard !glyphs.isEmpty else { return 0 }
        func level(_ f: Frame) -> Double {
            shifts.map { dy in
                glyphs.reduce(0.0) { $0 + min(1, lum(f, $1.0, $1.1 + dy) / $1.2) } / Double(glyphs.count)
            }.max() ?? 0
        }
        // What the other name scores by lying over this one's place.
        let floor = level(other)
        return max(0, (level(rep) - floor) / max(0.01, 1 - floor))
    }

    @Test("The third stop's name goes out before the new one comes in, while the rail moves")
    func thirdLabelNeverOverprints() throws {
        let old = try #require(film(from: Self.coffee, to: Self.coffee).last)
        let new = try #require(film(from: Self.lidPending, to: Self.lidPending).last)
        // The rail moves down about 9pt: the old name can be anywhere from
        // where it was to there, the new one anywhere back up from its place.
        let travel = Int(10 * CGFloat(old.w) / 275)
        // A cross-fade of a short word overlaps for a frame or two, which one
        // film can step over; three films cannot all miss it.
        for _ in 0 ..< 3 {
            let shown = film(from: Self.coffee, to: Self.lidPending).map {
                (thirdLabelShown($0, of: old, not: new, shifts: 0 ... travel),
                 thirdLabelShown($0, of: new, not: old, shifts: -travel ... 0))
            }
            let last = try #require(shown.last)
            #expect(last.0 < 0.1 && last.1 > 0.9, "the name never changed: \(shown)")
            let worst = shown.map { min($0.0, $0.1) }.max() ?? 1
            #expect(worst < 0.05, "both names at once, worst \(worst): \(shown)")
        }
    }

    @Test("Ending swaps the face over time, not in one frame")
    func endingIsNotACut() {
        // The Resume capsule's tan, counted in the button row.
        func resume(_ rep: Frame) -> Int {
            var n = 0
            for y in stride(from: 0, to: rep.h, by: 2) {
                for x in stride(from: rep.w / 2, to: rep.w, by: 2) {
                    let c = rep.rgb(x, y)
                    if c.r > 0.55 && c.r > c.b + 0.2 { n += 1 }
                }
            }
            return n
        }
        func partly(_ counts: [Int]) -> Bool {
            let final = counts.last ?? 0
            return counts.contains { $0 > final / 10 && $0 < final * 8 / 10 }
        }
        let (swapped, frames) = caught({ film(from: Self.coffee, to: Self.finished) }) { partly($0.map(resume)) }
        let counts = frames.map(resume)
        // Reached: the finished face is up at the end.
        #expect((counts.last ?? 0) > 50, "the Finished face never arrived: \(counts)")
        // Some frame shows it partly there.
        #expect(swapped, "the face cut: \(counts)")
    }
}
