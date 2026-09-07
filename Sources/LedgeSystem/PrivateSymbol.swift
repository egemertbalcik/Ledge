import Foundation

/// Safe access to symbols that Apple does not promise to keep.
///
/// The rule for this whole target: **never force-unwrap a `dlsym`**. macOS 26.4
/// already dropped one symbol this project would otherwise have relied on
/// (`DisplayServicesBrightnessChanged`). A missing symbol must cost one feature,
/// not the app.
public enum PrivateSymbol {

    /// Frameworks we load lazily, by path.
    public enum Library: String, Sendable, CaseIterable {
        case mediaRemote = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        case displayServices = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        case coreBrightness = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handles: [Library: UnsafeMutableRawPointer] = [:]

    /// Opens a private framework, caching the handle. Returns nil rather than
    /// trapping if the framework has moved or been removed.
    public static func handle(for library: Library) -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = handles[library] { return cached }
        guard let handle = dlopen(library.rawValue, RTLD_LAZY) else { return nil }
        handles[library] = handle
        return handle
    }

    /// Looks up a symbol and reinterprets it as `T`, or nil if it is absent.
    ///
    /// The caller is responsible for `T` matching the real ABI — get this wrong
    /// and you get a crash at call time, not here.
    public static func lookup<T>(_ name: String, in library: Library, as type: T.Type = T.self) -> T? {
        guard let handle = handle(for: library),
              let symbol = dlsym(handle, name)
        else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// Whether a symbol exists, for capability reporting at startup.
    public static func exists(_ name: String, in library: Library) -> Bool {
        guard let handle = handle(for: library) else { return false }
        return dlsym(handle, name) != nil
    }
}

/// What this build can actually do on the machine it is running on.
///
/// Logged at launch so a regression after a macOS update is one line in the log
/// rather than an afternoon of guessing.
public struct SystemCapabilities: Sendable {

    public let hasMediaRemote: Bool
    public let hasDisplayServicesBrightness: Bool
    public let hasKeyboardBrightness: Bool

    public static func probe() -> SystemCapabilities {
        SystemCapabilities(
            hasMediaRemote: PrivateSymbol.exists("MRMediaRemoteSendCommand", in: .mediaRemote),
            hasDisplayServicesBrightness: PrivateSymbol.exists("DisplayServicesGetBrightness", in: .displayServices),
            hasKeyboardBrightness: PrivateSymbol.handle(for: .coreBrightness) != nil
        )
    }

    public var summary: String {
        """
        capabilities: mediaRemote=\(hasMediaRemote) \
        displayServicesBrightness=\(hasDisplayServicesBrightness) \
        keyboardBrightness=\(hasKeyboardBrightness)
        """
    }
}
