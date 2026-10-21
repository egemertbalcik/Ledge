import AppKit
import CoreGraphics
import Foundation
import LedgeCore
import Observation
import SwiftUI
import Testing

@testable import LedgeUI

/// The charger's ears when charging starts a second after the plug.
///
/// macOS reports the plug first and charging a moment later, and the provider
/// refreshes the same card in place — same id — so the ears' own swap never
/// runs. The percentage used to jump twelve points sideways in one frame to
/// make room for the ring.
@Suite("The charger's ears", .serialized)
@MainActor
struct ChargerEarTests {

    @MainActor @Observable
    final class Shown {
        var activity: Activity
        init(_ activity: Activity) { self.activity = activity }
    }

    struct Ears: View {
        let shown: Shown
        var body: some View {
            CompactEarsView(activity: shown.activity, cutoutWidth: 185, inset: 14)
                .frame(width: 340, height: 34)
                .background(Color.black)
                .environment(\.chargeChangeAnimation, Animation(HeldHalfway()))
        }
    }

    /// An animation that goes halfway and stays there.
    ///
    /// The ears' real third of a second cannot be sampled reliably in a test
    /// process: other suites hold the main thread for seconds at a time, and a
    /// frame meant to land mid-change can land long after it. Held halfway,
    /// the in-between is on screen for as long as it takes to look at it —
    /// and a change that does not animate at all is still a jump. It does end,
    /// after an hour: SwiftUI drops an animation that never says it is done,
    /// and the change then lands in one frame.
    struct HeldHalfway: CustomAnimation {
        func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
            time > 3600 ? nil : value.scaled(by: 0.5)
        }
    }

    private static func power(charging: Bool) -> Activity {
        Activity(id: ActivityID(kind: .power, source: "internal"), createdAt: 0,
                 payload: .power(PowerPayload(percentage: 0.8, isCharging: charging)))
    }

    private struct Host {
        let window: NSWindow
        let view: NSView
        func close() { window.orderOut(nil); window.close() }
    }

    private func host(_ shown: Shown) -> Host {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let size = CGSize(width: 340, height: 34)
        // Far off every screen, so nothing is ever drawn where anyone sees it.
        let origin = CGPoint(x: -20000, y: -20000)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: Ears(shown: shown).environment(\.colorScheme, .dark))
        view.sizingOptions = []
        window.contentView = view
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        window.orderFrontRegardless()
        return Host(window: window, view: view)
    }

    /// One still of the ears.
    private struct Still {
        /// The percentage's left edge, in points: the leftmost light neutral
        /// pixel in the trailing half. Light rather than white, so a label
        /// part-way through fading out still counts where it is.
        var readoutLeft: CGFloat?
        /// Green in the trailing half: the charging ring, at any strength.
        var ring = 0
    }

    private func still(_ host: Host) -> Still {
        let rect = host.view.bounds
        guard let rep = host.view.bitmapImageRepForCachingDisplay(in: rect) else { return Still() }
        host.view.cacheDisplay(in: rect, to: rep)
        guard let image = rep.cgImage else { return Still() }
        let w = image.width, h = image.height
        let scale = CGFloat(w) / rect.width
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var result = Still()
        for x in 0..<w {
            for y in 0..<h {
                let i = (y * w + x) * 4
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                if x < w / 2 { continue }
                if g > r + 30, g > b + 30, g > 40 { result.ring += 1 }
                if result.readoutLeft == nil, min(r, g, b) > 100, max(r, g, b) - min(r, g, b) < 24 {
                    result.readoutLeft = CGFloat(x) / scale
                }
            }
        }
        return result
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Polls until `done` holds or a few seconds pass, pumping the run loop.
    /// However long anything else holds the main thread, a held-halfway
    /// change is still halfway when this returns.
    private func settle(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { settle(0.05) }
    }

    /// The ring arrives beside the percentage and moves it over; the number
    /// does not jump to its new place in the frame charging starts.
    @Test func chargingStartingInPlaceMovesTheReadoutRatherThanJumpingIt() throws {
        // Where the percentage rests either side of the change.
        let resting = { (charging: Bool) -> Still in
            let host = self.host(Shown(Self.power(charging: charging)))
            defer { host.close() }
            self.settle(0.6)
            return self.still(host)
        }
        let plugged = resting(false)
        let charging = resting(true)
        let pluggedLeft = try #require(plugged.readoutLeft, "the percentage is drawn")
        let chargingLeft = try #require(charging.readoutLeft, "the percentage is drawn")
        #expect(chargingLeft > pluggedLeft + 6,
                "the ring pushes the percentage over: \(pluggedLeft) -> \(chargingLeft)")

        // The same card refreshed in place, held halfway through the change.
        let shown = Shown(Self.power(charging: false))
        let host = host(shown)
        defer { host.close() }
        settle(0.6)
        shown.activity = Self.power(charging: true)
        var moving = still(host)
        settle(until: {
            moving = still(host)
            return moving.ring > 0
        })
        #expect(plugged.ring == 0 && moving.ring > 0, "the change has reached the screen: a ring is being drawn")
        let movingLeft = try #require(moving.readoutLeft)

        #expect(movingLeft > pluggedLeft + 1.5 && movingLeft < chargingLeft - 1,
                "halfway through, the one percentage is between its places: \(pluggedLeft) -> \(movingLeft) -> \(chargingLeft)")
    }
}
