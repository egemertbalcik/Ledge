import AppKit
import Foundation
import LedgeCore
import os

/// Reads and sets display brightness, and notices when it changes.
///
/// Brightness has no public API and no change notification, which shapes the
/// design twice over:
///
/// - Reading goes through `DisplayServices`, a private framework, so every
///   symbol is looked up defensively.
/// - There is nothing to subscribe to, so changes are found by polling. The
///   poll is slow when nothing is happening and quickens only after a change,
///   because the interesting moment is a burst of key presses, not the hours in
///   between.
///
/// `DisplayServicesBrightnessChanged` no longer exists on macOS 26.4 — it did on
/// earlier releases. That is why setting brightness leaves Control Centre's own
/// slider stale until it next reads the value itself.
@MainActor
public final class BrightnessController {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "brightness")

    private typealias GetBrightness =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    public var onChange: (HUDReadout) -> Void = { _ in }

    private var timer: Timer?
    private var lastLevel: Double?
    private var quickPollsRemaining = 0

    /// The resting beat, watching for brightness moved by something other than
    /// this app — an ambient-light adjustment, the Touch Bar, another utility.
    ///
    /// Twice a second, with no tolerance, was one of the few things keeping
    /// this process out of idle around the clock: a private-framework read
    /// every half second, all day, for a number that changes a handful of
    /// times a week. Two seconds with generous tolerance costs a fiftieth as
    /// many wake-ups, and a key press does not wait for it — that path drops
    /// straight to `activeInterval` for its burst.
    private let idleInterval: TimeInterval = 2.0
    private let activeInterval: TimeInterval = 1.0 / 20.0

    public init() {}

    public var isSupported: Bool {
        PrivateSymbol.exists("DisplayServicesGetBrightness", in: .displayServices)
    }

    /// The built-in display, which is the one the brightness keys act on.
    /// Not `CGMainDisplayID()`: that is whichever display carries the menu
    /// bar, and on a desk with the external monitor set as primary (or in
    /// clamshell) DisplayServices has no brightness for it — the readout
    /// never appeared and the Levels card seeded a made-up level. The
    /// built-in panel is found by asking; main is only the fallback.
    private static var mainDisplay: CGDirectDisplayID {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success {
            for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }
        return CGMainDisplayID()
    }

    public func level() -> Double? {
        guard let get = PrivateSymbol.lookup(
            "DisplayServicesGetBrightness",
            in: .displayServices,
            as: GetBrightness.self
        ) else { return nil }

        var value: Float = 0
        // `min`/`max` do not clamp NaN, so finiteness is checked separately.
        guard get(Self.mainDisplay, &value) == 0, value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    @discardableResult
    public func setLevel(_ level: Double) -> Bool {
        guard let set = PrivateSymbol.lookup(
            "DisplayServicesSetBrightness",
            in: .displayServices,
            as: SetBrightness.self
        ) else { return false }
        return set(Self.mainDisplay, Float(min(max(level, 0), 1))) == 0
    }

    public func readout() -> HUDReadout? {
        guard let level = level() else { return nil }
        return HUDReadout(kind: .brightness, level: level)
    }

    // MARK: - Watching

    public func startWatching() {
        stopWatching()
        guard isSupported else {
            Self.log.notice("DisplayServicesGetBrightness unavailable — brightness HUD disabled")
            return
        }
        lastLevel = level()
        schedule(interval: idleInterval)
    }

    public func stopWatching() {
        timer?.invalidate()
        timer = nil
        quickPollsRemaining = 0
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The resting beat may drift to ride along with other wake-ups; the
        // burst that follows a key press may not — it is what draws the bar.
        timer.tolerance = interval >= 1 ? interval * 0.5 : 0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A manual key step is 1/16 (0.0625). Ambient auto-brightness moves in far
    /// smaller, gradual increments. A change at least this large in one tick is
    /// therefore a key press, not the light sensor — which is how the HUD is
    /// shown only when the *user* changes brightness, never when the room does.
    ///
    /// There is no public API to distinguish the two, so this magnitude test is
    /// the honest best. When Accessibility is granted the interceptor drives the
    /// HUD from the actual key event and this is only a display-sync backstop.
    private let manualStep: Double = 0.045

    private func tick() {
        guard let current = level() else { return }

        guard let last = lastLevel else {
            lastLevel = current
            return
        }

        let delta = abs(current - last)

        // Floating-point noise: nothing changed.
        if delta < 0.001 {
            if quickPollsRemaining > 0 {
                quickPollsRemaining -= 1
                if quickPollsRemaining == 0 { schedule(interval: idleInterval) }
            }
            return
        }

        lastLevel = current

        // Only a manual-sized step shows the HUD. An ambient ramp — even one
        // that happens to land inside the fast-poll window a keypress opened —
        // must not surface as if the user pressed a key.
        guard delta >= manualStep else {
            // Let the fast-poll window decay on its own; do not re-arm it for an
            // ambient tick, or a slow ramp would hold the poll at 20 Hz.
            if quickPollsRemaining > 0 {
                quickPollsRemaining -= 1
                if quickPollsRemaining == 0 { schedule(interval: idleInterval) }
            }
            return
        }

        // A manual step. Speed up briefly so the rest of a held press tracks
        // smoothly rather than in half-second jumps.
        if quickPollsRemaining == 0 { schedule(interval: activeInterval) }
        quickPollsRemaining = 40

        onChange(HUDReadout(kind: .brightness, level: current))
    }
}

