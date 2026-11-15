import AppKit
import Foundation
import LedgeCore
import os

/// Reads and sets the built-in panel's brightness.
///
/// Brightness has no public API and no change notification. Reading goes
/// through `DisplayServices`, a private framework, so every symbol is looked
/// up defensively. Nothing here watches for changes: whoever needs to know
/// asks, as the open Levels card does.
///
/// `DisplayServicesBrightnessChanged` no longer exists on macOS 26.4 — it did on
/// earlier releases. That is why setting brightness leaves Control Centre's own
/// slider stale until it next reads the value itself.
@MainActor
public final class BrightnessController {

    private typealias GetBrightness =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    public init() {}

    public nonisolated var isSupported: Bool {
        PrivateSymbol.exists("DisplayServicesGetBrightness", in: .displayServices)
    }

    /// The built-in display, which is the one the brightness keys act on.
    /// Not `CGMainDisplayID()`: that is whichever display carries the menu
    /// bar, and on a desk with the external monitor set as primary (or in
    /// clamshell) DisplayServices has no brightness for it — the readout
    /// never appeared and the Levels card seeded a made-up level. The
    /// built-in panel is found by asking; main is only the fallback.
    private nonisolated static var mainDisplay: CGDirectDisplayID {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success {
            for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }
        return CGMainDisplayID()
    }

    public nonisolated func level() -> Double? {
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
    public nonisolated func setLevel(_ level: Double) -> Bool {
        guard let set = PrivateSymbol.lookup(
            "DisplayServicesSetBrightness",
            in: .displayServices,
            as: SetBrightness.self
        ) else { return false }
        return set(Self.mainDisplay, Float(min(max(level, 0), 1))) == 0
    }

    public nonisolated func readout() -> HUDReadout? {
        guard let level = level() else { return nil }
        return HUDReadout(kind: .brightness, level: level)
    }
}
