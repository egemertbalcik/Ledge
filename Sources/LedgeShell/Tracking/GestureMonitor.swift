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
    private var detents = ScrollDetents()
    private var stroke = SidewaysStroke()
    private var claims = ScrollClaims()

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
        detents.reset()
        stroke.reset()
    }

    /// A control under the pointer takes scrolling for itself, from whoever
    /// had it.
    ///
    /// One of the Keep Awake length's numbers takes vertical scrolling: it
    /// moves the number and never the cards, and a sideways swipe still moves
    /// between cards. The timer's open rule takes sideways strokes that begin
    /// on it, and hands vertical ones back.
    public func claimScroll(_ claim: ScrollClaim) {
        claims.claim(claim)
        claimChanged()
    }

    /// The owner gives the scrolling back. A card can only give back what it
    /// holds; see `ScrollClaims`.
    public func releaseScroll(_ owner: ScrollClaim.Owner) {
        guard claims.release(owner) else { return }
        claimChanged()
    }

    /// The pointer left the notch: nothing in it can still be under the
    /// pointer, whatever the cards were last told.
    public func releaseAllScroll() {
        guard claims.releaseAll() else { return }
        claimChanged()
    }

    /// The control under the pointer changed. What the last one left short of
    /// a step is not owed to the next, and a stroke it took is not the next
    /// one's either.
    private func claimChanged() {
        detents.reset()
        stroke.reset()
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
            if let claim = claims.current {
                switch claim.axis {
                case .vertical:
                    if scroll(claim.step, by: event) { return nil }
                case .horizontal:
                    return scrollSideways(claim.step, by: event)
                }
            }

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

            return act(on: recognizer.feed(Self.sample(of: event)), event)

        default:
            return event
        }
    }

    /// A trackpad event, reduced to what the gesture rules need.
    private static func sample(of event: NSEvent) -> ScrollSample {
        ScrollSample(
            dx: event.scrollingDeltaX,
            dy: event.scrollingDeltaY,
            timestamp: event.timestamp,
            isMomentum: event.momentumPhase != [],
            isEnded: event.phase.contains(.ended) || event.phase.contains(.cancelled)
        )
    }

    /// What the notch does with a trackpad event the recogniser has judged.
    private func act(on outcome: ScrollOutcome, _ event: NSEvent) -> NSEvent? {
        switch outcome {
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
    }

    /// Scrolling over a number. True when the event was the number's, and
    /// is swallowed whether or not it completed a step: handed back, it
    /// would page the cards behind a number the user is in the middle of
    /// setting.
    private func scroll(_ number: (Int) -> Void, by event: NSEvent) -> Bool {
        let isMomentum = event.momentumPhase != []
        let hasPhase = event.phase != [] || isMomentum
        let up = Self.physicalUp(
            event.scrollingDeltaY, invertedFromDevice: event.isDirectionInvertedFromDevice
        )

        if WheelNavigator.isWheel(hasPhase: hasPhase, isMomentum: isMomentum) {
            // A wheel has one axis. A tilt sideways is not the number's.
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }
            // A notched wheel reports lines, one per click; a high-resolution
            // one reports points.
            let travel = event.hasPreciseScrollingDeltas ? up : up * WheelNavigator.linePoints
            let steps = detents.feedWheel(travel, at: event.timestamp)
            if steps != 0 { number(steps) }
            return true
        }

        // A trackpad. Every event of the stroke goes to the swipe recogniser,
        // which decides once per gesture whether it is sideways. Deciding per
        // event let a slanted, mostly vertical stroke through: the recogniser
        // saw only its sideways pieces, never the vertical travel that would
        // have ruled the swipe out, and paged the card away mid-question.
        switch recognizer.feed(Self.sample(of: event)) {
        case .swipe(let swipe):
            Self.log.debug("swipe \(String(describing: swipe), privacy: .public)")
            onSwipe(swipe)
        case .pending:
            // Not decided yet, or sideways and not far enough to page.
            break
        case .notOurs:
            // Vertical, for the whole stroke. Coasting after a flick is the
            // hand having let go: a number that kept counting afterwards would
            // land somewhere nobody chose.
            guard !isMomentum else { break }
            let steps = detents.feed(up, step: ScrollDetents.trackpadStep)
            if steps != 0 { number(steps) }
        }
        return true
    }

    /// Scrolling over the timer's open rule: the event as the notch hands it
    /// on, nil when it is swallowed.
    ///
    /// Positive steps are more minutes. The rule moves with the hand, as it
    /// does under a drag: fingers left pull it left, which brings the larger
    /// numbers under the marker.
    private func scrollSideways(_ rule: (Int) -> Void, by event: NSEvent) -> NSEvent? {
        let isMomentum = event.momentumPhase != []
        let hasPhase = event.phase != [] || isMomentum
        let inverted = event.isDirectionInvertedFromDevice

        if WheelNavigator.isWheel(hasPhase: hasPhase, isMomentum: isMomentum) {
            // A wheel turns the rule whichever way it is built to turn: a
            // plain wheel rolls up for more, a sideways one — a tilt, a thumb
            // wheel — moves the rule as fingers would.
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // Nothing to turn by. Handed back, as the cards' own wheel would.
            guard dx != 0 || dy != 0 else { return event }
            let more = abs(dy) >= abs(dx)
                ? Self.physicalUp(dy, invertedFromDevice: inverted)
                : -Self.physicalRight(dx, invertedFromDevice: inverted)
            let travel = event.hasPreciseScrollingDeltas ? more : more * WheelNavigator.linePoints
            let steps = detents.feedWheel(travel, at: event.timestamp)
            if steps != 0 { rule(steps) }
            return nil
        }

        // Every event of the stroke goes to the swipe recogniser as well,
        // whoever ends up acting on it. A stroke the rule turns down is then
        // judged on all of its travel, exactly as it would be anywhere else on
        // the card. Fed only what the rule turned down, the recogniser missed
        // the first few vertical points the rule spent judging, and a stroke
        // that started up and turned sideways paged the card from the rule
        // when it would have paged nothing beside it.
        let sample = Self.sample(of: event)
        let outcome = recognizer.feed(sample)
        switch stroke.feed(
            sample,
            began: event.phase.contains(.began),
            coastEnded: event.momentumPhase.contains(.ended)
                || event.momentumPhase.contains(.cancelled)
        ) {
        case .undecided:
            return nil
        case .notOurs:
            return act(on: outcome, event)
        case .sideways(let dx):
            // The recogniser's verdict is not acted on: the stroke is the
            // rule's, however far sideways it goes.
            let more = -Self.physicalRight(dx, invertedFromDevice: inverted)
            let steps = detents.feed(more, step: ScrollDetents.rulerStep)
            if steps != 0 { rule(steps) }
            return nil
        }
    }

    /// Which way the hand moved, positive for up: fingers up on a trackpad,
    /// a wheel rolled away.
    ///
    /// A number goes up when the hand does, the same as dragging it, so this
    /// reads the device and not the "match my trackpad" setting the cards
    /// follow. With natural scrolling the delta is reported against the
    /// hand — fingers up arrive negative — and the event says when it is.
    static func physicalUp(_ deltaY: Double, invertedFromDevice: Bool) -> Double {
        invertedFromDevice ? -deltaY : deltaY
    }

    /// Which way the hand moved sideways, positive for right.
    ///
    /// The reported delta says where the content goes, and with natural
    /// scrolling the content goes with the fingers: fingers right arrive
    /// positive. With it off they arrive negative. The swipe recogniser reads
    /// the same sign the same way.
    static func physicalRight(_ deltaX: Double, invertedFromDevice: Bool) -> Double {
        invertedFromDevice ? deltaX : -deltaX
    }
}
