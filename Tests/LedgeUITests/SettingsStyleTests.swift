import AppKit
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// What the settings window's shared controls actually draw.
///
/// Drawn through `NSHostingView` rather than `ImageRenderer`: a grouped
/// `Form` is AppKit underneath, and `ImageRenderer` photographs its controls
/// as placeholder glyphs — which is exactly how a slider could spend months
/// drawing at half the width of its own row without any test noticing.
///
/// Said plainly, because it matters when this test passes: it is a smoke
/// test, not a guard. Removing `labelsHidden()` or the width — the two
/// modifiers that fixed the real pane — leaves it passing, because this
/// harness does not reproduce whatever in the full pane made the form keep a
/// label column. What it does catch is a slider that stops being drawn, or
/// one that shrinks to a corner. The real evidence is a rendered pane, by
/// eye.
@Suite("The settings window's controls", .serialized)
@MainActor
struct SettingsStyleTests {

    /// Paints a view offscreen and hands back its pixels.
    private func pixels(
        _ view: some View,
        width: CGFloat,
        height: CGFloat
    ) -> (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int)? {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        let w = image.width
        let h = image.height
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let context = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (bytes, w, h, bytesPerRow)
    }

    /// The shape the sliders are really used in: a section with a header, a
    /// sentence underneath, and a switch above them — which is what makes a
    /// grouped `Form` decide there is a label column to keep.
    private struct OneSlider: View {
        @State var value = 0.5
        @State var flag = true
        var body: some View {
            SettingsPage {
                Section {
                    Toggle("Keep these apps at full speed", isOn: $flag)
                    SettingsNote("A sentence about the section above.")
                }
                Section {
                    LabeledSlider("Length", value: $value, in: 0...1, format: "%.2f")
                } header: {
                    Text("Length")
                } footer: {
                    SettingsNote("What the question opens on.")
                }
            }
        }
    }

    @Test("A slider runs the width of its row, not half of it")
    func sliderSpansItsRow() throws {
        let width: CGFloat = 520
        let shot = try #require(pixels(OneSlider(), width: width, height: 320))
        // The widest bright run on any single scanline is the slider's
        // track. Taking the widest *row* rather than the brightest pixels
        // anywhere keeps the value badge and the title out of it: both are
        // bright, and both are narrow.
        var bestWidth = 0
        var bestLeft = 0
        for y in 0..<shot.height {
            var left = shot.width
            var right = -1
            for x in 0..<shot.width {
                let i = y * shot.bytesPerRow + x * 4
                let luminance = Int(shot.bytes[i]) + Int(shot.bytes[i + 1]) + Int(shot.bytes[i + 2])
                guard luminance > 230 else { continue }
                left = min(left, x)
                right = max(right, x)
            }
            guard right > left else { continue }
            if right - left > bestWidth {
                bestWidth = right - left
                bestLeft = left
            }
        }
        #expect(bestWidth > 0, "no slider was drawn at all")
        let scale = CGFloat(shot.width) / width
        let leftInPoints = CGFloat(bestLeft) / scale
        let widthInPoints = CGFloat(bestWidth) / scale
        #expect(
            widthInPoints > width * 0.7,
            "the slider is \(Int(widthInPoints))pt wide in a \(Int(width))pt row"
        )
        #expect(
            leftInPoints < width / 3,
            "the slider starts \(Int(leftInPoints))pt in: it is drawing in the trailing part of its row"
        )
    }
}
