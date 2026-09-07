import Foundation

/// Named timers, keyed so scheduling the same key twice replaces rather than
/// stacks.
///
/// That replacement rule is the point: it is what makes a re-fired HUD *extend*
/// its readout instead of queueing a second dismissal, and what stops an
/// activity that updates ten times a second from accumulating ten expiry timers.
@MainActor
public final class TimerBank<Key: Hashable & Sendable> {

    private var items: [Key: DispatchWorkItem] = [:]

    public var onFire: (Key) -> Void = { _ in }

    public init() {}

    public func schedule(_ key: Key, after delay: TimeInterval) {
        cancel(key)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Removed before firing, so a handler that reschedules the same key
            // is not immediately cancelled by its own completion.
            self.items[key] = nil
            self.onFire(key)
        }
        items[key] = item
        // A huge delay saturates DispatchTime to the end of time — a peek or
        // HUD that never retires. No phase timer has any business past a day.
        let sane = delay.isFinite ? min(max(0, delay), 86_400) : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + sane, execute: item)
    }

    public func cancel(_ key: Key) {
        items[key]?.cancel()
        items[key] = nil
    }

    public func cancelAll() {
        for item in items.values { item.cancel() }
        items.removeAll()
    }
}
