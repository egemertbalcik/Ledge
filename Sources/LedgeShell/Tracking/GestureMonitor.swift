import AppKit
import LedgeCore
import os

/// Turns AppKit scroll and middle-click events into gesture intents.
///
/// Local monitors only, so no Accessibility permission is needed: they see
/// events already routed to this app, which happens exactly when the panel is
/// interactive — that is, when the cursor is over the drawn shape.
@MainActor
public final class GestureMonitor {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "gestures")

    /// `addLocalMonitorForEvents` returns an opaque `Any?`, not a typed token.
    private var monitor: Any?
    private var recognizer: SwipeRecognizer

    public var onSwipe: (Swipe) -> Void = { _ in }
    public var onMiddleClick: () -> Void = {}

    /// Which windows these gestures apply to.
    ///
    /// A local monitor is app-wide, not panel-specific. Without this filter,
    /// scrolling the Settings window would be swallowed *and* fed to the swipe
    /// recogniser — the form would refuse to scroll while silently cycling
    /// activities behind it.
    public var shouldHandle: (NSWindow?) -> Bool = { _ in true }

    public init(threshold: Double, isNatural: Bool) {
        recognizer = SwipeRecognizer(threshold: threshold, isNatural: isNatural)
    }

    public func updateSettings(threshold: Double, isNatural: Bool) {
        recognizer.threshold = threshold
        recognizer.isNatural = isNatural
    }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recognizer.reset()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard shouldHandle(event.window) else { return event }

        switch event.type {
        case .otherMouseDown:
            // Button 2 is the middle button; higher numbers are extra side
            // buttons that should be left alone.
            guard event.buttonNumber == 2 else { return event }
            onMiddleClick()
            return nil

        case .scrollWheel:
            let sample = ScrollSample(
                dx: event.scrollingDeltaX,
                dy: event.scrollingDeltaY,
                timestamp: event.timestamp,
                isMomentum: event.momentumPhase != [],
                isEnded: event.phase.contains(.ended) || event.phase.contains(.cancelled)
            )
            switch recognizer.feed(sample) {
            case .swipe(let swipe):
                Self.log.debug("swipe \(String(describing: swipe), privacy: .public)")
                onSwipe(swipe)
                return nil
            case .pending:
                // Might still become a sideways swipe; hold on to it so the
                // gesture is not half-delivered to something else.
                return nil
            case .notOurs:
                // Vertical. Handed straight back, so a list inside a card — the
                // media card's outputs — scrolls as any list would. The notch
                // itself does nothing with it.
                return event
            }

        default:
            return event
        }
    }
}
