import AppKit
import CoreGraphics
import Foundation
import LedgeCore
import SwiftUI
import Testing

@testable import LedgeUI

/// What the island looks like part-way through opening and closing.
///
/// Each test slows the shape's spring right down, so one frame taken a moment
/// after the change is unambiguously mid-flight, and then reads the pixels:
/// whether the departing card is still drawn, and whether anything is drawn on
/// the desktop below the island's edge.
@Suite("Island transitions", .serialized)
@MainActor
struct IslandTransitionTests {

    private static let geometry = NotchGeometry(
        screenSize: CGSize(width: 1512, height: 982),
        notchSize: CGSize(width: 185, height: 32),
        notchCenterX: 756,
        isHardwareNotch: true
    )

    /// Not grey and not black, so the island and its white content are the
    /// only neutral pixels in a frame.
    private static let backdrop = Color(red: 0.5, green: 0.3, blue: 0.5)

    private struct Host {
        let window: NSWindow
        let view: NSView
        let preferences: Preferences
        func close() { window.orderOut(nil); window.close() }
    }

    private func host(_ presentation: NotchPresentation, springResponse: Double = 3) -> Host {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let size = NotchLayout.panelSize(for: Self.geometry)
        let preferences = Preferences(store: MemoryPreferenceStore())
        // Several seconds instead of 0.38: a frame taken a quarter of a second
        // in is well inside the movement.
        preferences.springResponse = springResponse
        let root = ZStack(alignment: .top) {
            Self.backdrop
            NotchOverlayView(geometry: Self.geometry, preferences: preferences, presentation: presentation)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.waveformAnimationsEnabled, false)
        // Far off every screen, so nothing is ever drawn where anyone sees it.
        let origin = CGPoint(x: -20000, y: -20000)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: root)
        view.sizingOptions = []
        window.contentView = view
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        window.orderFrontRegardless()
        return Host(window: window, view: view, preferences: preferences)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// One frame of the island area, as measured pixels.
    private struct Frame {
        /// Island bottom on the centre column, in points.
        var islandHeight: CGFloat = 0
        /// Bright neutral pixels inside the island, below the cutout: card content.
        var content = 0
        /// Pixels below the island's edge that differ from the backdrop: anything
        /// drawn on the desktop rather than on the island.
        var belowIsland = 0
    }

    private func frame(_ host: Host) -> Frame {
        let size = host.view.bounds.size
        let rect = NSRect(x: size.width / 2 - 200, y: 0, width: 400, height: 260)
        guard let rep = host.view.bitmapImageRepForCachingDisplay(in: rect) else { return Frame() }
        host.view.cacheDisplay(in: rect, to: rep)
        guard let image = rep.cgImage else { return Frame() }
        let w = image.width, h = image.height
        let scale = CGFloat(h) / rect.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Row 0 is the top of the view.
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        func neutral(_ c: (Int, Int, Int)) -> Bool { max(c.0, c.1, c.2) - min(c.0, c.1, c.2) < 14 }
        func lum(_ c: (Int, Int, Int)) -> Int { (c.0 + c.1 + c.2) / 3 }

        let backdrop = rgb(2, h - 2)
        var bottom = 0
        for y in stride(from: h - 1, through: 0, by: -1) {
            let c = rgb(w / 2, y)
            if neutral(c), lum(c) < 60 { bottom = y + 1; break }
        }
        let cutout = Int((Self.geometry.notchSize.height + 2) * scale)
        var result = Frame(islandHeight: CGFloat(bottom) / scale)
        for y in 0..<h {
            for x in 0..<w {
                let c = rgb(x, y)
                if y >= cutout, y < bottom - 4, neutral(c), lum(c) > 160 { result.content += 1 }
                if y > bottom + 4,
                   abs(c.0 - backdrop.0) + abs(c.1 - backdrop.1) + abs(c.2 - backdrop.2) > 24 {
                    result.belowIsland += 1
                }
            }
        }
        return result
    }

    private func message() -> Activity {
        Activity(id: ActivityID(kind: .message, source: "test"), createdAt: 0,
                 payload: .message(MessagePayload(title: "Build finished", body: "Ledge is ready")))
    }

    /// A card with a second one queued, so the page dots are drawn.
    private func presentation(_ phase: NotchPhase) -> NotchPresentation {
        let presentation = NotchPresentation()
        presentation.count = 2
        presentation.selectedIndex = 0
        presentation.selected = message()
        presentation.phase = phase
        return presentation
    }

    /// The card leaving must still be visible while the island closes around
    /// it. Drawn under the fill, it vanished in the first frame and an empty
    /// black slab eased shut.
    @Test func closingCardStaysVisibleWhileTheIslandCloses() {
        let presentation = presentation(.expanded)
        let host = host(presentation)
        defer { host.close() }
        settle(1)
        let open = frame(host)
        #expect(open.content > 500, "the open card is drawn: \(open)")

        presentation.phase = .idle
        settle(0.25)
        let closing = frame(host)

        // Mid-close: the island has started to shrink and is still card-sized.
        #expect(closing.islandHeight < open.islandHeight - 1, "the close has started: \(closing)")
        #expect(closing.islandHeight > 70, "the island is still card-sized: \(closing)")
        #expect(closing.content > open.content / 2, "the departing card is still drawn: \(closing)")
    }

    /// Nothing is drawn below a growing island: the hairline and the page dots
    /// used to appear at the finished card's size and wait for the shape.
    @Test func openingDrawsNothingBelowTheIsland() {
        let presentation = presentation(.idle)
        let host = host(presentation)
        defer { host.close() }
        settle(1)

        presentation.phase = .hover
        settle(1)
        let opening = frame(host)

        let finalHeight = presentation.cardSize(
            preferences: Preferences(store: MemoryPreferenceStore()), geometry: Self.geometry, phase: .hover
        ).height
        #expect(opening.islandHeight > 40, "the island has started to grow: \(opening)")
        #expect(opening.islandHeight < finalHeight - 20, "the island is still growing: \(opening)")
        #expect(opening.belowIsland == 0, "nothing hangs below the island: \(opening)")
    }

    /// The page dots go with the island when it closes, rather than staying at
    /// the old bottom edge while it retracts.
    @Test func closingLeavesNothingBelowTheIsland() {
        let presentation = presentation(.expanded)
        let host = host(presentation)
        defer { host.close() }
        settle(1)
        #expect(frame(host).belowIsland == 0, "the open card has nothing below it")

        presentation.phase = .idle
        settle(0.5)
        let closing = frame(host)

        #expect(closing.islandHeight > 40, "the island is still closing: \(closing)")
        #expect(closing.islandHeight < 110, "the island has moved up from the open edge: \(closing)")
        #expect(closing.belowIsland == 0, "nothing hangs below the island: \(closing)")
    }

    // MARK: A card's first open

    private func focus() -> Activity {
        Activity(id: ActivityID(kind: .focus, source: "test"), createdAt: 0,
                 payload: .focus(FocusPayload(name: "Do Not Disturb", symbolName: "moon.fill", isActive: true)))
    }

    private func shelf() -> Activity {
        Activity(id: ActivityID(kind: .shelf, source: "test"), createdAt: 0,
                 payload: .shelf(ShelfPayload(items: (1...2).map {
                     ShelfItem(path: "/tmp/ledge-test-\($0)", name: "Example \($0)")
                 })))
    }

    private func weather() -> Activity {
        Activity(id: ActivityID(kind: .weather, source: "test"), createdAt: 0,
                 payload: .weather(WeatherPayload(temperatureCelsius: 18, symbolName: "sun.max.fill",
                                                  condition: "Clear", city: "Istanbul",
                                                  highCelsius: 21, lowCelsius: 12)))
    }

    /// A spring for the first-open tests, slow enough that a frame meant for
    /// its first tenth of a second still shows its first moments when it lands
    /// a minute late — other suites in the process can hold the main thread
    /// for seconds — while a silently applied measurement is a step at once.
    private static let glacial: Double = 1000

    /// A card peeking, never opened, so it has never measured itself.
    private func peeking(_ card: Activity) -> NotchPresentation {
        let presentation = NotchPresentation()
        presentation.count = 1
        presentation.selected = card
        presentation.peeked = card
        presentation.phase = .peek
        return presentation
    }

    /// The Focus card is 36 points under the unmeasured estimate. Applied
    /// silently, that came off the start of the opening spring and put the
    /// island above the cutout: the peek's ears blinked out.
    @Test func aSmallerCardOpensFromThePeekOnItsFirstOpen() {
        let card = focus()
        let presentation = peeking(card)
        let host = host(presentation, springResponse: Self.glacial)
        defer { host.close() }
        settle(1)
        let peek = frame(host)
        #expect(peek.islandHeight > 30, "the peek is drawn: \(peek)")
        #expect(!presentation.hasMeasured(card.id), "the card has never been opened")

        presentation.phase = .hover
        settle(0.1)
        let opening = frame(host)

        #expect(presentation.hasMeasured(card.id), "the card has measured itself")
        #expect(opening.islandHeight >= peek.islandHeight - 1,
                "the island grows out of the peek instead of vanishing: \(peek) -> \(opening)")
    }

    /// The Shelf is 16 points over the estimate; silently, those 16 were a jump
    /// in the first frame.
    @Test func aTallerCardDoesNotJumpOnItsFirstOpen() {
        let card = shelf()
        let presentation = peeking(card)
        let host = host(presentation, springResponse: Self.glacial)
        defer { host.close() }
        settle(1)
        let peek = frame(host)
        #expect(peek.islandHeight > 30, "the peek is drawn: \(peek)")
        #expect(!presentation.hasMeasured(card.id), "the card has never been opened")

        presentation.phase = .hover
        settle(0.1)
        let opening = frame(host)

        #expect(presentation.hasMeasured(card.id), "the card has measured itself")
        #expect(opening.islandHeight < peek.islandHeight + 8,
                "early in a glacial spring the island has barely moved: \(peek) -> \(opening)")
    }

    /// Cycling to a card for the first time: the island was already springing
    /// down from the weather card when the Shelf's measurement arrived.
    @Test func cyclingToAnUnmeasuredCardDoesNotJump() {
        let presentation = NotchPresentation()
        presentation.count = 2
        presentation.selected = weather()
        presentation.phase = .hover
        let host = host(presentation)
        defer { host.close() }
        settle(1)
        // The slowed spring takes several seconds to finish opening.
        settle(6)
        let before = frame(host)
        #expect(before.islandHeight > 170, "the taller weather card is open: \(before)")

        let card = shelf()
        host.preferences.springResponse = Self.glacial
        presentation.selected = card
        presentation.selectedIndex = 1
        settle(0.1)
        let switching = frame(host)

        #expect(presentation.hasMeasured(card.id), "the card has measured itself")
        #expect(switching.islandHeight <= before.islandHeight + 1,
                "the island only ever shrinks towards the Shelf: \(before) -> \(switching)")
    }
}
