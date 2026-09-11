import AppKit
import CoreGraphics
import Foundation
import LedgeCore
import os

/// One display Ledge can dim, and how.
public struct BrightnessDisplay: Equatable, Sendable, Identifiable {
    public var id: CGDirectDisplayID
    public var name: String
    public var isBuiltIn: Bool
    /// How this display's level is actually applied. See `Backend`.
    public var backend: DisplayBrightnessController.Backend

    /// Whether dimming it does anything a person can see.
    ///
    /// A Sidecar iPad and an AirPlay receiver are composited at the far end,
    /// so the Mac's gamma ramp never reaches the panel — and CoreGraphics
    /// accepts the ramp and reads it back as applied, which is what made this
    /// worth detecting rather than assuming. Measured on a Sidecar iPad: the
    /// ramp set to 0.45, read back as 0.45, screen unchanged.
    public var canDim: Bool

    public init(
        id: CGDirectDisplayID,
        name: String,
        isBuiltIn: Bool,
        backend: DisplayBrightnessController.Backend,
        canDim: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.backend = backend
        self.canDim = canDim
    }
}

/// Whether a display is a real panel or something composited elsewhere.
///
/// EDID vendor identifiers are three packed letters in sixteen bits, so a real
/// display's can never exceed `0xFFFF`. Measured on this Mac: the built-in
/// panel answers 1552 (Apple), a Dell U2713H answers 4268 (`0x10AC`), and a
/// Sidecar iPad answers 1,633,775,724 — which is not an EDID vendor at all.
///
/// Pure, so the rule can be tested against those numbers rather than against a
/// display being plugged in.
public enum DisplayReality {
    public static func isVirtual(vendorNumber: UInt32) -> Bool {
        vendorNumber > 0xFFFF
    }
}

/// Reads and sets brightness per display.
///
/// The built-in panel has a real backlight that `DisplayServices` drives. An
/// external display usually does not answer to anything public, so its level is
/// applied by scaling the display's gamma ramp instead.
///
/// Two consequences of the gamma approach are load-bearing and not obvious:
///
/// - **A gamma ramp only lives as long as the process that set it.** macOS
///   restores the ColorSync ramp the moment the setting process exits, so this
///   is only viable inside a resident app. (This cost an hour of "the write
///   succeeded but nothing happened" — a probe that set the ramp and exited
///   immediately had its work undone before the screen could redraw.)
/// - **Gamma dims the signal, not the backlight.** Contrast genuinely drops, and
///   at very low levels the picture would posterise, which is why the floor is
///   clamped well above zero rather than allowing a black screen the user cannot
///   see well enough to undo.
///
/// DDC/CI — the protocol that *would* drive a real external backlight — is
/// deliberately not attempted. It was probed thoroughly on this hardware: writes
/// are accepted and silently discarded and every read fails, which is also why
/// MonitorControl only affects this monitor across the lower half of its range
/// (that half is its own software dimming; the upper half is DDC, and does
/// nothing here). Shipping a DDC path that works on some unknown subset of
/// monitors, cannot be verified, and fights the gamma path is worse than one
/// mechanism that always works.
@MainActor
public final class DisplayBrightnessController {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "brightness")

    public enum Backend: Equatable, Sendable {
        /// The real backlight, via `DisplayServices`. Built-in panels.
        case backlight
        /// A scaled gamma ramp held by this process. External displays.
        case gamma
    }

    private typealias GetBrightness =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// Gamma levels currently applied, by display. The ramp is not readable back
    /// as a level, so this is the only record of where an external display sits.
    private var gammaLevels: [CGDirectDisplayID: Double] = [:]

    /// Levels keyed by a display's identity rather than its id, so they survive
    /// unplugging: `CGDirectDisplayID` is only stable while connected.
    private var rememberedLevels: [String: Double] = [:]

    private var reconfigureRegistered = false

    /// The last enumeration, reused until the display configuration changes.
    ///
    /// `displays()` walks every online display *and* `NSScreen.screens`, and it
    /// sits on the slider's drag path — which called it twice per frame. The set
    /// of displays cannot change without a reconfiguration, and that already
    /// has a callback, so caching is exact rather than merely close enough.
    private var cachedDisplays: [BrightnessDisplay]?

    /// True after `releaseAll` until the feature is used again: remembered
    /// levels must not be re-applied by a reconfiguration callback while the
    /// user has the feature switched off.
    private var suspended = false

    /// Below this a gamma-dimmed screen is too dark to comfortably undo, and
    /// colour banding becomes obvious. Matches the spirit of MonitorControl
    /// refusing zero software brightness by default.
    public static let gammaFloor: Double = 0.18

    public init() {}

    // MARK: - Enumeration

    /// Every online display, built-in first. Cached; see `cachedDisplays`.
    public func displays() -> [BrightnessDisplay] {
        if let cachedDisplays { return cachedDisplays }
        let fresh = enumerateDisplays()
        cachedDisplays = fresh
        // A display list is only safe to cache while something invalidates it.
        registerForReconfiguration()
        return fresh
    }

    private func enumerateDisplays() -> [BrightnessDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }

        let screens = NSScreen.screens
        return ids.prefix(Int(count)).compactMap { id -> BrightnessDisplay? in
            // A mirrored secondary draws nothing of its own; showing it as a
            // separate row would offer a slider that appears to do nothing.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let name = screens.first { Self.displayID(of: $0) == id }?.localizedName
                ?? (isBuiltIn ? "Built-in Display" : "Display")
            return BrightnessDisplay(
                id: id,
                name: name,
                isBuiltIn: isBuiltIn,
                backend: isBuiltIn ? .backlight : .gamma,
                // The built-in panel has a real backlight. Everything else is
                // dimmed with a gamma ramp, which only reaches a panel the Mac
                // is actually driving.
                canDim: isBuiltIn || !DisplayReality.isVirtual(vendorNumber: CGDisplayVendorNumber(id))
            )
        }
        .sorted { $0.isBuiltIn && !$1.isBuiltIn }
    }

    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The display the cursor is on — which is the one the brightness keys
    /// should act on.
    ///
    /// `NSEvent.mouseLocation` is in Cocoa's bottom-left coordinates, so it is
    /// compared against `NSScreen.frame` directly rather than against the
    /// CoreGraphics bounds, which are top-left.
    public func displayUnderCursor() -> BrightnessDisplay? {
        let point = NSEvent.mouseLocation
        let all = displays()
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
        if let screen, let id = Self.displayID(of: screen),
           let match = all.first(where: { $0.id == id }) {
            return match
        }
        // Off every screen (possible mid-hotplug): fall back to the main display
        // rather than silently doing nothing.
        return all.first { $0.id == CGMainDisplayID() } ?? all.first
    }

    // MARK: - Reading

    public func level(of display: BrightnessDisplay) -> Double? {
        switch display.backend {
        case .backlight:
            guard let get = PrivateSymbol.lookup(
                "DisplayServicesGetBrightness",
                in: .displayServices,
                as: GetBrightness.self
            ) else { return nil }
            var value: Float = 0
            // `min`/`max` do not clamp NaN, so finiteness is checked separately.
            guard get(display.id, &value) == 0, value.isFinite else { return nil }
            return Double(min(max(value, 0), 1))
        case .gamma:
            if let applied = gammaLevels[display.id] { return applied }
            // Nothing applied yet this session: an untouched display is at full,
            // unless a previous session left a remembered level.
            return rememberedLevels[Self.identity(of: display.id)] ?? 1
        }
    }

    // MARK: - Writing

    @discardableResult
    public func setLevel(_ level: Double, on display: BrightnessDisplay) -> Bool {
        // NaN survives the min/max clamps below and would poison the gamma
        // table (black screen) or DisplayServices. Refuse it outright.
        guard level.isFinite else { return false }
        switch display.backend {
        case .backlight:
            guard let set = PrivateSymbol.lookup(
                "DisplayServicesSetBrightness",
                in: .displayServices,
                as: SetBrightness.self
            ) else { return false }
            return set(display.id, Float(min(max(level, 0), 1))) == 0
        case .gamma:
            let clamped = min(max(level, Self.gammaFloor), 1)
            guard applyGamma(clamped, to: display.id) else { return false }
            suspended = false
            gammaLevels[display.id] = clamped
            rememberedLevels[Self.identity(of: display.id)] = clamped
            registerForReconfiguration()
            return true
        }
    }

    /// A linear scale of the identity ramp. Deliberately not a gamma *curve*:
    /// scaling keeps relative tone reproduction intact, so the picture reads as
    /// dimmer rather than washed out.
    private func applyGamma(_ level: Double, to id: CGDirectDisplayID) -> Bool {
        let size = 256
        var table = [CGGammaValue](repeating: 0, count: size)
        for index in 0..<size {
            table[index] = CGGammaValue(Double(index) / Double(size - 1) * level)
        }
        var red = table, green = table, blue = table
        return CGSetDisplayTransferByTable(id, UInt32(size), &red, &green, &blue) == .success
    }

    // MARK: - Persistence across unplugging

    /// Vendor/model/serial, which stay put across reconnects — unlike the id.
    private static func identity(of id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    /// Levels to persist, as `identity=level` pairs.
    public func encodedLevels() -> String {
        rememberedLevels
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
    }

    public func loadLevels(_ encoded: String) {
        rememberedLevels = [:]
        for pair in encoded.split(separator: ",") {
            let parts = pair.split(separator: "=")
            // `Double("nan")` parses, and min/max pass NaN straight through —
            // a hand-edited default then reached `Int()` in the HUD panel and
            // the Levels card and took the app down on every launch.
            guard parts.count == 2, let value = Double(parts[1]), value.isFinite else { continue }
            rememberedLevels[String(parts[0])] = min(max(value, Self.gammaFloor), 1)
        }
    }

    /// Re-applies remembered levels to the displays currently attached. Called at
    /// launch and after a display change, because a freshly attached display
    /// starts at the identity ramp.
    public func restoreRememberedLevels() {
        suspended = false
        for display in displays() where display.backend == .gamma {
            guard let level = rememberedLevels[Self.identity(of: display.id)], level < 1 else { continue }
            if applyGamma(level, to: display.id) {
                gammaLevels[display.id] = level
            }
        }
        if !gammaLevels.isEmpty { registerForReconfiguration() }
    }

    // MARK: - Holding the ramp

    /// macOS resets gamma on resolution changes, sleep/wake and hot-plug, so the
    /// applied level has to be re-asserted afterwards or an external display
    /// silently snaps back to full.
    private func registerForReconfiguration() {
        guard !reconfigureRegistered else { return }
        reconfigureRegistered = true
        CGDisplayRegisterReconfigurationCallback(
            displayReconfigured, Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Hands the registration back.
    ///
    /// The callback holds an *unretained* pointer to this object, so leaving it
    /// registered past the controller's life would leave CoreGraphics calling
    /// into freed memory. Nothing recreates the controller today — it is a
    /// `let` on a coordinator that lives as long as the app — but that is a
    /// property of today's ownership, not a guarantee.
    private func unregisterForReconfiguration() {
        guard reconfigureRegistered else { return }
        reconfigureRegistered = false
        CGDisplayRemoveReconfigurationCallback(
            displayReconfigured, Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Invalidates the cached list and re-asserts the applied levels.
    fileprivate func configurationChanged() {
        cachedDisplays = nil
        reapply()
    }

    private func reapply() {
        // After releaseAll, a listing call (the brightness keys asking which
        // display the cursor is on) may re-register this callback for cache
        // invalidation — but the remembered levels must not sneak back onto
        // the glass until the feature is deliberately re-engaged.
        guard !suspended else { return }
        for display in displays() where display.backend == .gamma {
            guard let level = gammaLevels[display.id]
                ?? rememberedLevels[Self.identity(of: display.id)], level < 1 else { continue }
            _ = applyGamma(level, to: display.id)
            gammaLevels[display.id] = level
        }
    }

    /// Hands every ramp back to ColorSync. Without this a quit would leave the
    /// external display dim until something else reset it — except that macOS
    /// does that for us on exit; this is for an orderly shutdown and for the
    /// user switching the feature off. Remembered levels survive (they are the
    /// cross-session persistence); `suspended` keeps them from re-applying.
    public func releaseAll() {
        suspended = true
        unregisterForReconfiguration()
        cachedDisplays = nil
        gammaLevels.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }
}


/// Free function so the *same* pointer can be handed to both the register and
/// remove calls — CoreGraphics matches registrations on it, and a closure
/// literal would produce a different one each time, making removal silently
/// fail.
private func displayReconfigured(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    // Only once the change has landed. The "begin" pass reports the *old*
    // configuration, and re-applying there would be undone immediately.
    guard flags.contains(.setModeFlag) || flags.contains(.addFlag)
        || flags.contains(.enabledFlag) || flags.contains(.desktopShapeChangedFlag)
    else { return }
    let controller = Unmanaged<DisplayBrightnessController>
        .fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in controller.configurationChanged() }
}
