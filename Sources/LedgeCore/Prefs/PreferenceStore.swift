import CoreGraphics
import Foundation

/// A typed preference key: name plus the value used when nothing is stored.
public struct PrefKey<Value: PreferenceValue>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// Types that can round-trip through a preference store.
public protocol PreferenceValue: Sendable, Equatable {
    static func read(from defaults: UserDefaults, key: String) -> Self?
    func write(to defaults: UserDefaults, key: String)
}

extension Bool: PreferenceValue {
    public static func read(from defaults: UserDefaults, key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }
    public func write(to defaults: UserDefaults, key: String) {
        defaults.set(self, forKey: key)
    }
}

extension Int: PreferenceValue {
    public static func read(from defaults: UserDefaults, key: String) -> Int? {
        defaults.object(forKey: key) as? Int
    }
    public func write(to defaults: UserDefaults, key: String) {
        defaults.set(self, forKey: key)
    }
}

extension Double: PreferenceValue {
    public static func read(from defaults: UserDefaults, key: String) -> Double? {
        defaults.object(forKey: key) as? Double
    }
    public func write(to defaults: UserDefaults, key: String) {
        defaults.set(self, forKey: key)
    }
}

extension CGFloat: PreferenceValue {
    public static func read(from defaults: UserDefaults, key: String) -> CGFloat? {
        (defaults.object(forKey: key) as? Double).map { CGFloat($0) }
    }
    public func write(to defaults: UserDefaults, key: String) {
        defaults.set(Double(self), forKey: key)
    }
}

extension String: PreferenceValue {
    public static func read(from defaults: UserDefaults, key: String) -> String? {
        defaults.string(forKey: key)
    }
    public func write(to defaults: UserDefaults, key: String) {
        defaults.set(self, forKey: key)
    }
}

/// Where preferences live. Abstracted so tests never touch the real domain.
public protocol PreferenceStoring: AnyObject {
    func value<Value>(for key: PrefKey<Value>) -> Value
    func set<Value>(_ value: Value, for key: PrefKey<Value>)
    func removeAll(named names: [String])
    /// Whether the key has ever been written — for values seeded from the
    /// system exactly once, so a user's explicit choice survives relaunches.
    func hasValue(named name: String) -> Bool
}

public final class UserDefaultsPreferenceStore: PreferenceStoring {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func value<Value>(for key: PrefKey<Value>) -> Value {
        Value.read(from: defaults, key: key.name) ?? key.defaultValue
    }

    public func set<Value>(_ value: Value, for key: PrefKey<Value>) {
        value.write(to: defaults, key: key.name)
    }

    public func removeAll(named names: [String]) {
        for name in names { defaults.removeObject(forKey: name) }
    }

    public func hasValue(named name: String) -> Bool {
        defaults.object(forKey: name) != nil
    }
}

/// In-memory store for tests and previews.
public final class MemoryPreferenceStore: PreferenceStoring {

    private var storage: [String: Any] = [:]

    public init() {}

    public func value<Value>(for key: PrefKey<Value>) -> Value {
        storage[key.name] as? Value ?? key.defaultValue
    }

    public func set<Value>(_ value: Value, for key: PrefKey<Value>) {
        storage[key.name] = value
    }

    public func hasValue(named name: String) -> Bool {
        storage[name] != nil
    }

    public func removeAll(named names: [String]) {
        for name in names { storage.removeValue(forKey: name) }
    }
}
