import Foundation
import LedgeCore
import ObjectiveC
import os

/// The keyboard backlight, through `KeyboardBrightnessClient` in
/// CoreBrightness.
///
/// There is no public API for this and no promise that there will be one
/// tomorrow. The class is reached through the Objective-C runtime, which means
/// the arguments are pushed by hand, which means a method that has quietly
/// changed its signature is not a lookup failure but a call with the wrong
/// bytes in the registers.
///
/// So nothing is instantiated until the type encodings have been read off the
/// class and compared against the ones measured on a Mac. A mismatch skips the
/// keyboard entirely: no journal entry, nothing darkened, one line in the log
/// naming the method that moved. **Never darken a device you cannot restore.**
/// A keyboard at zero is a smaller problem than a panel at zero, but it is the
/// same problem, and the rule does not get softer for being cheaper.
public struct CoreBrightnessKeyboardBacklight: Backlight {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "lid")

    public let name = "keyboard"

    /// Measured on macOS 26.4 (25E246) with `class_copyMethodList`.
    ///
    /// Read as: `-brightnessForKeyboard:` returns a float and takes one 64-bit
    /// unsigned integer; `-setBrightness:forKeyboard:` returns a BOOL and takes
    /// a float and a 64-bit unsigned integer. The offsets are part of the
    /// encoding the runtime hands back, so they are part of what is compared —
    /// a changed offset means a changed frame.
    public static let expectedEncodings: [String: String] = [
        "copyKeyboardBacklightIDs": "@16@0:8",
        "isKeyboardBuiltIn:": "B24@0:8Q16",
        "brightnessForKeyboard:": "f24@0:8Q16",
        "setBrightness:forKeyboard:": "B28@0:8f16Q20",
    ]

    public static let className = "KeyboardBrightnessClient"

    public init() {}

    // MARK: - The gate

    /// Whether the class is the one these encodings were measured against.
    ///
    /// Computed each time rather than cached in a `let`: this is called once
    /// per conserve, a handful of times an hour, and a cached verdict is a
    /// verdict that was taken before the framework was loaded.
    public static func verdict() -> PrivateMethodGate.Verdict {
        PrivateMethodGate.check(
            className: className,
            expected: expectedEncodings,
            found: encodings()
        )
    }

    /// Every instance method on the class, by selector name.
    ///
    /// Nil when the class is not there. Note the framework is opened through
    /// `PrivateSymbol` first: `objc_getClass` only finds a class whose image
    /// has been loaded, and CoreBrightness is not linked.
    static func encodings() -> [String: String]? {
        guard PrivateSymbol.handle(for: .coreBrightness) != nil,
              let cls = objc_getClass(className) as? AnyClass
        else { return nil }

        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return [:] }
        defer { free(list) }

        var found: [String: String] = [:]
        for index in 0..<Int(count) {
            let method = list[index]
            let selector = NSStringFromSelector(method_getName(method))
            guard let encoding = method_getTypeEncoding(method) else { continue }
            found[selector] = String(cString: encoding)
        }
        return found
    }

    public var isAvailable: Bool {
        let verdict = Self.verdict()
        if !verdict.isOK {
            Self.log.notice(
                "lid: keyboard backlight skipped — \(verdict.reason, privacy: .public)"
            )
        }
        return verdict.isOK
    }

    // MARK: - Reading and writing

    public func level() -> Double? {
        typealias Read = @convention(c) (AnyObject, Selector, UInt64) -> Float
        guard let client = Self.client(),
              let keyboard = Self.builtInKeyboard(client),
              let read: Read = Self.implementation(of: Self.brightnessSelector, on: client)
        else { return nil }
        let value = read(client, Self.brightnessSelector, keyboard)
        guard value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    public func setLevel(_ level: Double) -> Bool {
        typealias Write = @convention(c) (AnyObject, Selector, Float, UInt64) -> ObjCBool
        guard let client = Self.client(),
              let keyboard = Self.builtInKeyboard(client),
              let write: Write = Self.implementation(of: Self.setBrightnessSelector, on: client)
        else { return false }
        return write(client, Self.setBrightnessSelector,
                     Float(min(max(level, 0), 1)), keyboard).boolValue
    }

    // MARK: - Reaching the class

    private static let brightnessSelector = NSSelectorFromString("brightnessForKeyboard:")
    private static let setBrightnessSelector = NSSelectorFromString("setBrightness:forKeyboard:")
    private static let idsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
    private static let builtInSelector = NSSelectorFromString("isKeyboardBuiltIn:")

    /// Builds one, and only once the gate has passed.
    ///
    /// The check is inside this function rather than at its call sites on
    /// purpose: there is then no way to reach `alloc` that does not go past it.
    private static func client() -> AnyObject? {
        guard verdict().isOK,
              let cls = objc_getClass(className) as? NSObject.Type
        else { return nil }
        return cls.init()
    }

    /// The built-in keyboard's backlight id.
    ///
    /// An external keyboard with a backlight is somebody else's keyboard on
    /// somebody else's desk; the one inside the closed machine is the only one
    /// burning power nobody can see. When none of them says it is built in,
    /// the first is taken — a Mac with exactly one backlight and a runtime
    /// that will not say which it is, which is still better served by
    /// darkening it than by leaving it lit.
    private static func builtInKeyboard(_ client: AnyObject) -> UInt64? {
        typealias Ids = @convention(c) (AnyObject, Selector) -> NSArray?
        typealias IsBuiltIn = @convention(c) (AnyObject, Selector, UInt64) -> ObjCBool
        guard let ids: Ids = implementation(of: idsSelector, on: client),
              let list = ids(client, idsSelector) as? [NSNumber],
              !list.isEmpty,
              let builtIn: IsBuiltIn = implementation(of: builtInSelector, on: client)
        else { return nil }

        for number in list {
            let id = number.uint64Value
            if builtIn(client, builtInSelector, id).boolValue { return id }
        }
        return list[0].uint64Value
    }

    /// One method's implementation, reinterpreted as a C function.
    ///
    /// Optional all the way down, by the same rule `PrivateSymbol` follows: a
    /// method that has gone must cost this one feature, never the app. The
    /// gate has already said these four are present and unchanged, so a nil
    /// here is a class that moved between the check and the call — which is
    /// one more reason there is no force-unwrap on the path.
    private static func implementation<T>(of selector: Selector, on client: AnyObject) -> T? {
        guard let method = class_getInstanceMethod(Swift.type(of: client), selector) else {
            return nil
        }
        return unsafeBitCast(method_getImplementation(method), to: T.self)
    }
}
