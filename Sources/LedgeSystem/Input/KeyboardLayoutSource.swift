import Carbon
import Foundation
import os

/// The keyboard layout currently selected.
public struct KeyboardLayoutSnapshot: Equatable, Sendable {
    /// "Turkish", "ABC", "British" — what System Settings calls it.
    public var name: String
    /// A two-letter tag for the compact view: "TR", "EN".
    public var code: String

    public init(name: String, code: String) {
        self.name = name
        self.code = code
    }
}

/// Where the selected keyboard layout comes from.
@MainActor
public protocol KeyboardLayoutWatching: AnyObject {
    func current() -> KeyboardLayoutSnapshot?
    func startWatching(_ onChange: @escaping @MainActor () -> Void)
    func stopWatching()
}

/// Reads the selected layout from Text Input Sources and notices switches.
///
/// Fully event-driven: `kTISNotifySelectedKeyboardInputSourceChanged` is posted
/// on the *distributed* notification centre on every switch, so there is nothing
/// to poll. macOS itself shows only a small menu-bar flag that is easy to miss,
/// which is the whole reason this card exists.
@MainActor
public final class KeyboardLayoutSource: KeyboardLayoutWatching {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keyboard")

    private var observer: NSObjectProtocol?

    public init() {}

    public func current() -> KeyboardLayoutSnapshot? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let name = Self.string(source, kTISPropertyLocalizedName) else { return nil }
        return KeyboardLayoutSnapshot(name: name, code: Self.code(for: source, name: name))
    }

    /// Prefer the source's own language tag — it is what distinguishes two
    /// layouts that share a script — and fall back to the name's initials so a
    /// layout reporting no language still gets a legible badge.
    private static func code(for source: TISInputSource, name: String) -> String {
        if let languages = property(source, kTISPropertyInputSourceLanguages)
            as? [String], let first = languages.first, !first.isEmpty {
            // "en-GB" and "tr" both reduce to the leading subtag.
            let base = first.split(separator: "-").first.map(String.init) ?? first
            if base.count >= 2 { return String(base.prefix(2)).uppercased() }
        }
        let initials = name.split(separator: " ").compactMap(\.first)
        return String(initials.prefix(2)).uppercased()
    }

    private static func string(_ source: TISInputSource, _ key: CFString!) -> String? {
        property(source, key) as? String
    }

    private static func property(_ source: TISInputSource, _ key: CFString!) -> Any? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    public func startWatching(_ onChange: @escaping @MainActor () -> Void) {
        stopWatching()
        observer = DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in
            // Read on the next turn of the run loop. Measured on macOS 26:
            // `TISCopyCurrentKeyboardInputSource` already reports the new source
            // by the time this fires, so no settling delay is needed.
            Task { @MainActor in onChange() }
        }
        Self.log.debug("keyboard: watching input-source changes")
    }

    public func stopWatching() {
        if let observer {
            DistributedNotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    // No `deinit` cleanup: the observer is main-actor state and cannot be read
    // from a nonisolated deinit. The provider's `stop()` is what unregisters,
    // and it always runs — the stream's `onTermination` guarantees it.
}

/// Fixed layout, for tests.
@MainActor
public final class StubKeyboardLayoutSource: KeyboardLayoutWatching {
    private var value: KeyboardLayoutSnapshot?
    private var onChange: (@MainActor () -> Void)?

    public init(value: KeyboardLayoutSnapshot? = nil) {
        self.value = value
    }

    public func current() -> KeyboardLayoutSnapshot? { value }

    public func set(_ value: KeyboardLayoutSnapshot?) {
        self.value = value
        onChange?()
    }

    public func startWatching(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    public func stopWatching() { onChange = nil }
}
