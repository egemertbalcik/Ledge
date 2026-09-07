import AppKit
import Foundation
import os

/// The hardware keys this watches.
public enum MediaKey: Int, Equatable, Sendable, CaseIterable {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case keyboardBacklightUp = 21
    case keyboardBacklightDown = 22

    /// Whether this key raises or lowers, for the direction of a step.
    public var delta: Int {
        switch self {
        case .soundUp, .brightnessUp, .keyboardBacklightUp: 1
        case .soundDown, .brightnessDown, .keyboardBacklightDown: -1
        case .mute: 0
        }
    }
}

/// Decodes a `NSSystemDefined` event into a key press.
///
/// Split out from the tap so the bit-twiddling can be tested without an event
/// tap, an Accessibility grant, or a real key press.
public enum MediaKeyDecoder {

    public struct Press: Equatable, Sendable {
        public let key: MediaKey
        public let isDown: Bool
        public let isRepeat: Bool
    }

    /// `data1` packs the key code in the high 16 bits, and the state in bits
    /// 8...15 — `0xA` for down, `0xB` for up. Bit 0 marks a key repeat.
    public static func decode(data1: Int) -> Press? {
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        guard let key = MediaKey(rawValue: keyCode) else { return nil }

        let state = (data1 & 0x0000_FF00) >> 8
        guard state == 0x0A || state == 0x0B else { return nil }

        return Press(
            key: key,
            isDown: state == 0x0A,
            isRepeat: (data1 & 0x1) == 1
        )
    }
}

/// Watches (and optionally swallows) the hardware volume and brightness keys.
///
/// **This is the one component that can break something the user relies on.**
/// In intercepting mode the tap returns nil, which is what stops macOS drawing
/// its own HUD — but it also means the key press is gone. If this app then
/// fails to apply the change, the key did nothing at all.
///
/// So the defaults are deliberately timid:
///
/// - Interception is **off** unless explicitly enabled. Observing volume via
///   CoreAudio needs no permission and no tap at all, so the ordinary HUD
///   costs nothing.
/// - Even when enabled, the tap is created `.listenOnly` unless suppression is
///   also on, so the keys keep working while the styling is evaluated.
/// - `.tapDisabledByTimeout` re-arms. macOS disables a tap whose callback ran
///   too slowly, and without re-arming the keys would stay dead until relaunch.
/// - Everything is torn down on `stop()`, and stopping is what happens if
///   anything goes wrong.
@MainActor
public final class MediaKeyInterceptor {

    // Nonisolated: read from the tap callback, which is not on an actor.
    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "mediakeys")

    /// Return true to swallow the press. Only consulted when suppressing.
    public var onPress: (MediaKeyDecoder.Press) -> Bool = { _ in false }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isSuppressing = false

    public init() {}

    public var isRunning: Bool { eventTap != nil }

    /// Whether the app can actually intercept media keys right now.
    ///
    /// One question, one answer, asked of the live system — and asked in the
    /// only way that is honest: by creating the *same* tap `start()` will
    /// create, and seeing whether the system hands one over.
    ///
    /// Two wrong answers were possible before, and the app gave both:
    ///
    /// - `AXIsProcessTrusted()` reads a per-process cache filled on the first
    ///   call. A grant *revoked* while the app runs never reaches it, so the
    ///   app believed it was suppressing the system readout long after the tap
    ///   had been killed.
    /// - A probe tap asking for no events at all — a session tap, listen-only,
    ///   over a mask holding only `.null` — is granted to *anybody*. It is not
    ///   a permission check, it is a formality that always succeeds, so the
    ///   app also believed it was trusted when it had never been granted
    ///   anything. That one told every new user their Accessibility permission
    ///   was already in place, and hid the button that would have granted it.
    ///
    /// What makes this version a real question is that it asks for something
    /// only the grant can buy: the HID tap, as a `.defaultTap` — the right to
    /// *swallow* a key press rather than watch it go by. Torn down at once;
    /// this is a question, not a subscription. Cheap enough for the settings
    /// pane's poll, and the only thing any decision here consults.
    public static var isTrusted: Bool {
        guard let probe = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << systemDefinedType.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else { return false }
        CFMachPortInvalidate(probe)
        return true
    }

    /// Prompts for Accessibility. Shows the system dialogue, so only call it
    /// from an explicit user action.
    @discardableResult
    public static func requestTrust() -> Bool {
        // The `kAXTrustedCheckOptionPrompt` global is a mutable var, which
        // Swift 6 rejects as shared mutable state. The key's value is stable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Starts the tap.
    ///
    /// - Parameter suppressSystemHUD: when true the tap can swallow presses,
    ///   which suppresses the system HUD. When false it only listens, and the
    ///   system behaves exactly as it would without this app.
    @discardableResult
    public func start(suppressSystemHUD: Bool) -> Bool {
        stop()
        guard Self.isTrusted else {
            Self.log.notice("not trusted for Accessibility — media keys not watched")
            return false
        }

        isSuppressing = suppressSystemHUD

        let mask = CGEventMask(1 << Self.systemDefinedType.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<MediaKeyInterceptor>
                .fromOpaque(userInfo).takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            // Listen-only cannot swallow anything, which is exactly the point
            // when suppression is off.
            options: suppressSystemHUD ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.log.error("failed to create event tap")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        startHealthCheck()
        Self.log.notice("media key tap started (suppressing=\(suppressSystemHUD, privacy: .public))")
        return true
    }

    /// How often to confirm the tap is still listening. Measured in the field:
    /// macOS had been disabling it (`kCGEventTapDisabledByTimeout`) when the
    /// callback ran late, which is what "the volume keys stopped working"
    /// looks like from the outside.
    private static let healthInterval: TimeInterval = 5

    private var healthCheck: Task<Void, Never>?

    /// Re-arms a tap the system switched off.
    ///
    /// The callback already re-arms when it is *told* about the disable, and
    /// that remains the fast path. This is the backstop for the case that
    /// notice is the very thing that arrives late — a tap disabled while the
    /// main thread is busy leaves the keys dead until something else wakes the
    /// callback, and nothing else will if the only keys the user is pressing
    /// are the ones this tap swallows.
    private func startHealthCheck() {
        healthCheck?.cancel()
        healthCheck = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.healthInterval))
                guard let self, !Task.isCancelled, let tap = self.eventTap else { return }
                guard !CGEvent.tapIsEnabled(tap: tap) else { continue }
                Self.log.error("event tap found disabled — re-arming")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    public func stop() {
        healthCheck?.cancel()
        healthCheck = nil
        // Invalidate, not merely disable: `start()` calls `stop()` and then
        // creates a fresh tap, and `apply()` re-runs on every HUD preference
        // change — a disabled-but-live mach port per toggle is a slow leak in
        // a process that lives for weeks (mirrors `deinit`).
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        runLoopSource = nil
        eventTap = nil
        isSuppressing = false
    }

    isolated deinit {
        // The tap holds an *unretained* pointer back to this object. Today the
        // interceptor lives as long as the app, but were it ever released
        // without `stop()`, the still-enabled HID tap would call into freed
        // memory on the next media key. Invalidation here closes that door.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource { CFRunLoopSourceInvalidate(runLoopSource) }
    }

    /// `NSSystemDefined`. Not exposed as a `CGEventType` case, so the raw
    /// value is used directly.
    private nonisolated static let systemDefinedType = CGEventType(rawValue: 14) ?? .null

    /// Runs on the run-loop thread the tap source was added to — the main one.
    ///
    /// Deliberately `nonisolated`: a `CGEvent` is not `Sendable`, so it must
    /// never be captured by a closure that crosses an actor boundary. Only
    /// `Sendable` values cross, and the event itself stays on this thread.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback was too slow, or after certain
        // user input. Re-arming here is the difference between a momentary
        // hiccup and the volume keys staying dead until the app is relaunched.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.log.error("event tap disabled (\(type.rawValue, privacy: .public)) — re-arming")
            MainActor.assumeIsolated { reArm() }
            return Unmanaged.passUnretained(event)
        }

        guard type == Self.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8,
              let press = MediaKeyDecoder.decode(data1: nsEvent.data1)
        else { return Unmanaged.passUnretained(event) }

        // Only ever swallow when both suppressing *and* the handler says it
        // took responsibility for the change. Anything else passes through, so
        // a key the app does not understand still does what it always did.
        let shouldSwallow = MainActor.assumeIsolated { () -> Bool in
            let handled = onPress(press)
            return isSuppressing && handled
        }
        return shouldSwallow ? nil : Unmanaged.passUnretained(event)
    }

    private func reArm() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}
