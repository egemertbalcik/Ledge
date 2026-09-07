import AppKit
import Foundation

/// Watches the Caps Lock state system-wide.
///
/// A global `flagsChanged` monitor: it observes without intercepting, so no
/// event tap is needed — but macOS only delivers key-class events to global
/// monitors of a process trusted for Accessibility, and on a fresh Mac Ledge
/// is not. So the monitor is the fast path, and a slow poll of the HID
/// modifier state (`CGEventSource.flagsState`, which needs no grant) is the
/// path that makes Caps Lock work for everyone. The poll runs only while the
/// grant is missing; a stranger's first launch gets the feature, and a
/// trusted Mac keeps the instant one.
@MainActor
public protocol CapsLockWatching: AnyObject {
    func startWatching(_ onChange: @escaping @MainActor (_ isOn: Bool) -> Void)
    func stopWatching()
}

@MainActor
public final class CapsLockSource: CapsLockWatching {

    private var monitor: Any?
    /// Global monitors never see events routed to our *own* process — toggling
    /// Caps Lock while typing in Ledge's settings window went unnoticed and the
    /// remembered state went stale. A local monitor covers exactly that gap.
    private var localMonitor: Any?
    /// The last state delivered, so key-repeat and unrelated modifier events
    /// (flagsChanged fires for every modifier) do not re-announce.
    private var lastState: Bool?

    public init() {}

    /// The no-grant fallback: reads the HID modifier state a few times a
    /// second. Cheap (one syscall), tolerant, and only while untrusted.
    private var poll: Timer?

    public func startWatching(_ onChange: @escaping @MainActor (_ isOn: Bool) -> Void) {
        stopWatching()
        lastState = NSEvent.modifierFlags.contains(.capsLock)
        if !AXIsProcessTrusted() {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let flags = CGEventSource.flagsState(.hidSystemState)
                    self.deliver(flags.contains(.maskAlphaShift) ? [.capsLock] : [], onChange)
                }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            poll = timer
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.deliver(event.modifierFlags, onChange)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.deliver(event.modifierFlags, onChange)
            }
            return event
        }
    }

    private func deliver(
        _ flags: NSEvent.ModifierFlags,
        _ onChange: @MainActor (_ isOn: Bool) -> Void
    ) {
        let isOn = flags.contains(.capsLock)
        guard isOn != lastState else { return }
        lastState = isOn
        onChange(isOn)
    }

    public func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        poll?.invalidate()
        poll = nil
        lastState = nil
    }
}
