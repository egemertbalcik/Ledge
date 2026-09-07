import AppKit
import Foundation
import LedgeCore

/// Detects when the cursor is over the overlay.
///
/// Driven by mouse events, with a slow poll behind them.
///
/// It used to be the poll alone, thirty times a second for as long as the app
/// ran, whether or not the pointer had moved — which it has not, for most of
/// any day. That was the single largest piece of continuous work in the
/// process. Mouse-moved events cost nothing while the pointer is still and
/// arrive the instant it is not, which is both cheaper and quicker.
///
/// The poll stays as a backstop, several times a second instead of thirty. A
/// pointer can end up somewhere new without a single mouse-moved event: a drag
/// session in another app, a display waking at a different resolution, the
/// notch region itself changing shape underneath a cursor that never moved.
/// Those are rare, and a fifth of a second late is imperceptible; losing them
/// entirely is not.
///
/// Global monitors need Accessibility for *keyboard* events only — mouse
/// events are delivered without it, and this app holds the trust regardless.
///
/// Two callbacks, deliberately:
///
/// - `onInsideChanged` fires the instant the cursor crosses the boundary, and
///   drives click-through. It must not be debounced, or a fast click would land
///   in the window while it is still passing events through.
/// - `onSettled` fires after the open/close delay and drives the phase, so
///   brushing past the notch does not flash the overlay open.
@MainActor
public final class HoverTracker<Key: Equatable> {

    /// Backstop rate while outside, for the movement no event describes.
    private let idleInterval: TimeInterval = 1.0 / 5.0

    /// Backstop rate while inside, so leaving is noticed even if the pointer
    /// left in a way that posted nothing we can see.
    private let activeInterval: TimeInterval = 1.0 / 10.0

    /// The most often the event path will do the work. Fast movement posts
    /// events far quicker than anything can be drawn from them, and the hit
    /// test is not free; this bounds the event path to the rate the poll used
    /// to run at while inside.
    private let eventFloor: TimeInterval = 1.0 / 60.0

    private var timer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastTickAt: TimeInterval = 0
    /// Which display's overlay the cursor is on, not merely whether it is on
    /// one: only the panel under the cursor may stop being click-through.
    private var insideKey: Key?
    private var pendingSettle: DispatchWorkItem?

    /// Every display's resting region, in the order they should be tested.
    public var closedRegions: () -> [(key: Key, rect: CGRect)]
    /// The grown region of the display that is currently open. Only that one is
    /// ever asked, since only one overlay can be open at a time.
    public var openRegion: (Key) -> CGRect?
    public var openDelay: () -> TimeInterval
    public var closeDelay: () -> TimeInterval
    public var onInsideChanged: (Key?) -> Void
    public var onSettled: (Key?) -> Void

    public init(
        closedRegions: @escaping () -> [(key: Key, rect: CGRect)],
        openRegion: @escaping (Key) -> CGRect?,
        openDelay: @escaping () -> TimeInterval,
        closeDelay: @escaping () -> TimeInterval,
        onInsideChanged: @escaping (Key?) -> Void,
        onSettled: @escaping (Key?) -> Void
    ) {
        self.closedRegions = closedRegions
        self.openRegion = openRegion
        self.openDelay = openDelay
        self.closeDelay = closeDelay
        self.onInsideChanged = onInsideChanged
        self.onSettled = onSettled
    }

    public func start() {
        schedule(interval: idleInterval)
        startMonitors()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        pendingSettle?.cancel()
        pendingSettle = nil
    }

    /// Both monitors: the global one sees the pointer crossing other apps'
    /// windows, the local one sees it over ours — a click-through panel still
    /// counts as ours once it stops being click-through.
    private func startMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickIfDue() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.tickIfDue() }
            return event
        }
    }

    private func tickIfDue() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastTickAt >= eventFloor else { return }
        lastTickAt = now
        tick()
    }

    /// Forces the tracker's idea of "inside" to match reality.
    ///
    /// While a HUD slider drag is in flight the coordinator swallows exits, but
    /// this tracker has already committed `insideKey = nil` — and from nil it
    /// only ever notices *entries into closed regions*, so a cursor resting on
    /// the widened open bar produces no further events and no exit ever fires.
    /// The coordinator re-derives the true key when the drag ends and hands it
    /// back here.
    public func resync(to key: Key?) {
        pendingSettle?.cancel()
        pendingSettle = nil
        insideKey = key
        schedule(interval: key != nil ? activeInterval : idleInterval)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Tolerance lets the kernel coalesce these wake-ups with everything
        // else that fires around the same instant — the difference between a
        // poll that keeps the process out of idle all day and one that rides
        // along. Half the interval keeps the felt latency unchanged.
        timer.tolerance = interval * 0.5
        // .common so the poll keeps running while a menu is open or a window is
        // being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        lastTickAt = Date().timeIntervalSinceReferenceDate
        let hit = DisplayHitTest.hit(
            point: NSEvent.mouseLocation,
            current: insideKey,
            currentOpenRegion: insideKey.flatMap(openRegion),
            closedRegions: closedRegions()
        )
        guard hit != insideKey else { return }

        insideKey = hit
        schedule(interval: hit != nil ? activeInterval : idleInterval)
        onInsideChanged(hit)
        settle(hit, after: hit != nil ? openDelay() : closeDelay())
    }

    private func settle(_ value: Key?, after delay: TimeInterval) {
        pendingSettle?.cancel()
        guard delay > 0 else {
            onSettled(value)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            // Only commit if the cursor is still where it was when the timer
            // started — otherwise a quick in-and-out would still open it.
            guard let self, self.insideKey == value else { return }
            self.onSettled(value)
        }
        pendingSettle = item
        // Clamped like TimerBank: a hand-edited huge delay saturates the
        // deadline to the end of time and the hover never settles.
        let sane = delay.isFinite ? min(max(0, delay), 60) : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + sane, execute: item)
    }
}
