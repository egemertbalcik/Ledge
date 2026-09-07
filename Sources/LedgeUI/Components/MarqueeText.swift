import SwiftUI

/// Text that scrolls only when it does not fit.
///
/// A track title that fits must sit still — text that slides for no reason is
/// worse than truncation. So the width is measured first, and the animation
/// only exists when there is genuinely something hidden.
public struct MarqueeText: View {

    private let text: String
    private let font: Font
    private let kerning: CGFloat
    private let speed: Double
    private let gap: CGFloat
    private let startDelay: Double

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    /// When this text started scrolling.
    ///
    /// The offset used to be derived from absolute wall-clock time, which meant
    /// a new title appeared already part-way scrolled — `.id(text)` cannot reset
    /// something that is a pure function of the clock. Measuring from an epoch
    /// makes every title start at the beginning and honour the start delay.
    @State private var epoch: TimeInterval = Date().timeIntervalSinceReferenceDate

    public init(
        _ text: String,
        font: Font = .system(size: 13, weight: .semibold),
        kerning: CGFloat = 0,
        speed: Double = 26,
        gap: CGFloat = 34,
        startDelay: Double = 1.6
    ) {
        // A title is foreign data — an ID3 tag or calendar summary can be
        // megabytes. Laying that out on one unbroken line inside a 30 Hz
        // TimelineView is a main-thread hang; nothing legible needs more.
        self.text = text.count > 256 ? String(text.prefix(256)) : text
        self.font = font
        // Slightly tightened kerning on the title matches how iOS sets the
        // now-playing text.
        self.kerning = kerning
        self.speed = speed
        self.gap = gap
        self.startDelay = startDelay
    }

    private var overflows: Bool { textWidth > containerWidth + 1 }

    public var body: some View {
        GeometryReader { proxy in
            Group {
                if overflows {
                    scrolling(in: proxy.size.width)
                } else {
                    label.frame(width: proxy.size.width, alignment: .leading)
                }
            }
            .onAppear { containerWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, new in containerWidth = new }
            .onChange(of: text) { _, _ in
                // Reset both the scroll clock and the measured width. The width
                // belongs to the previous title, and judging `overflows` against
                // it makes a short title briefly render at the long title's
                // offset — visibly off-screen for a frame.
                epoch = Date().timeIntervalSinceReferenceDate
                textWidth = 0
            }
        }
        .frame(height: measuredHeight)
        .clipped()
    }

    private var measuredHeight: CGFloat { 17 }

    private var label: some View {
        Text(text)
            .font(font)
            .kerning(kerning)
            .lineLimit(1)
            .fixedSize()
            .background(
                // Measures the natural width so the decision to scroll is made
                // from the real layout rather than a character count.
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in textWidth = new }
                }
            )
    }

    private func scrolling(in width: CGFloat) -> some View {
        let cycle = textWidth + gap
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let period = (Double(cycle) / speed) + startDelay
            let sinceStart = max(0, context.date.timeIntervalSinceReferenceDate - epoch)
            let elapsed = max(0, sinceStart.truncatingRemainder(dividingBy: period) - startDelay)
            let offset = -CGFloat(elapsed * speed)

            HStack(spacing: gap) {
                label
                // A second copy so the text wraps around seamlessly instead of
                // snapping back to the start.
                label
            }
            .offset(x: offset)
            .frame(width: width, alignment: .leading)
        }
        // The text is redrawn from scratch when it changes, so a new track does
        // not inherit the previous one's scroll position.
        .id(text)
        // The second copy is a seam, not a second title: one element, read once.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
