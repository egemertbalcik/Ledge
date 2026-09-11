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
    private var wheel: WheelNavigator

    public var onSwipe: (Swipe) -> Void = { _ in }
    public var onMiddleClick: () -> Void = {}

    /// Whether something under the pointer wants the wheel more than the notch
    /// does — the media card's list of outputs, above all. While that is true
    /// the wheel is handed straight back, so the list scrolls as any list
    /// would and the cards stay where they are.
    public var wheelBelongsToContent: () -> Bool = { false }

    /// Which windows these gestures apply to.
    ///
    /// A local monitor is app-wide, not panel-specific. Without this filter,
    /// scrolling the Settings window would be swallowed *and* fed to the swipe
    /// recogniser — the form would refuse to scroll while silently cycling
    /// activities behind it.
    public var shouldHandle: (NSWindow?) -> Bool = { _ in true }

    public init(threshold: Double, isNatural: Bool) {
        recognizer = SwipeRecognizer(threshold: threshold, isNatural: isNatural)
        wheel = WheelNavigator(isNatural: isNatural)
    }

    public func updateSettings(threshold: Double, isNatural: Bool) {
        recognizer.threshold = threshold
        recognizer.isNatural = isNatural
        // The wheel follows the same scroll-direction setting; the swipe
        // threshold is a trackpad distance and means nothing to it.
        wheel.isNatural = isNatural
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
        wheel.reset()
    }

    /// Internal rather than private so the decisions below can be tested with
    /// real `NSEvent`s: which device an event came from, what a line is worth,
    /// and whether the event is swallowed or handed back. That is exactly
    /// where a wheel reporting lines instead of points went unnoticed.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard shouldHandle(event.window) else { return event }

        switch event.type {
        case .otherMouseDown:
            // Button 2 is the middle button; higher numbers are extra side
            // buttons that should be left alone.
            guard event.buttonNumber == 2 else { return event }
            onMiddleClick()
            return nil

        case .scrollWheel:
            // A wheel has no touch phase and no momentum; a trackpad and a
            // Magic Mouse always report one. That is the whole test, and it
            // leaves every trackpad gesture exactly as it was.
            let hasPhase = event.phase != [] || event.momentumPhase != []
            if WheelNavigator.isWheel(hasPhase: hasPhase, isMomentum: event.momentumPhase != []) {
                // Whatever is scrollable under the pointer comes first.
                guard !wheelBelongsToContent() else { return event }
                // A notched wheel reports *lines*, one per click, not points:
                // taken at face value a click is worth 1 against a threshold
                // measured in points, and a card would have cost ten clicks.
                // High-resolution and smooth wheels set the precise flag and do
                // report points.
                let dy = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY
                    : event.scrollingDeltaY * WheelNavigator.linePoints
                if let swipe = wheel.feed(ScrollSample(
                    dx: event.scrollingDeltaX,
                    dy: dy,
                    timestamp: event.timestamp
                )) {
                    Self.log.debug("wheel \(String(describing: swipe), privacy: .public)")
                    onSwipe(swipe)
                    return nil
                }
                // Not enough movement yet. Handed back rather than swallowed:
                // a wheel that cannot reach a card should still reach whatever
                // is behind it, and swallowing every event would make the
                // notch a hole that quietly eats scrolling.
                return event
            }

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
