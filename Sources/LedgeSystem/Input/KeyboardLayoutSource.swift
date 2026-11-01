import Carbon
import Foundation
import os

/// The keyboard layout currently selected.
public struct KeyboardLayoutSnapshot: Equatable, Sendable {
    /// "Turkish", "ABC", "British" — what System Settings calls it.
    public var name: String
    /// The badge for the compact view: "TR", "EN" — or "TRQ" beside Turkish F.
    /// At most three characters, and unique among the enabled sources; see
    /// `KeyboardBadge`.
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
    private var enabledObserver: NSObjectProtocol?

    /// The enabled sources and the code each gets among them. Read when first
    /// needed and again whenever the list changes: whether Turkish Q is TR or
    /// TRQ depends on whether Turkish F is enabled beside it.
    private var enabled: [KeyboardSourceFacts] = []
    private var badges: [String: String]?

    public init() {}

    public func current() -> KeyboardLayoutSnapshot? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let facts = Self.facts(source) else { return nil }
        return KeyboardLayoutSnapshot(name: facts.name, code: badge(for: facts))
    }

    private func badge(for facts: KeyboardSourceFacts) -> String {
        // Not in the table: never read yet, or behind — a source added and
        // selected before the list notification landed. Read it again.
        if badges?[facts.id] == nil { rebuildBadges() }
        if let code = badges?[facts.id] { return code }
        // Still not on the list — a source macOS selected on its own. Worked
        // out with it added, so it gets a code no enabled source holds.
        return KeyboardBadge.code(for: facts, among: enabled)
    }

    private func rebuildBadges() {
        enabled = Self.enabledSources()
        badges = KeyboardBadge.codes(for: enabled)
    }

    /// The sources a switch can land on: layouts and input modes the user has
    /// enabled, not the palettes (Emoji & Symbols, Dictation) or an input
    /// method's own container, which cannot be selected.
    private static func enabledSources() -> [KeyboardSourceFacts] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
            as? [TISInputSource] else { return [] }
        return list.compactMap(facts)
    }

    private static func facts(_ source: TISInputSource) -> KeyboardSourceFacts? {
        guard let name = string(source, kTISPropertyLocalizedName) else { return nil }
        return KeyboardSourceFacts(
            id: string(source, kTISPropertyInputSourceID) ?? name,
            name: name,
            languages: property(source, kTISPropertyInputSourceLanguages) as? [String] ?? []
        )
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
        // The list, on its own: adding or removing a source changes which
        // codes are free, so the table is rebuilt — and only rebuilt. A list
        // change is not a switch, and the provider is not told one happened.
        enabledObserver = DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildBadges() }
        }
        Self.log.debug("keyboard: watching input-source changes")
    }

    public func stopWatching() {
        if let observer {
            DistributedNotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        if let enabledObserver {
            DistributedNotificationCenter.default.removeObserver(enabledObserver)
        }
        enabledObserver = nil
        // Unwatched, the list can change unseen; the next start reads it afresh.
        badges = nil
    }

    // No `deinit` cleanup: the observers are main-actor state and cannot be read
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
