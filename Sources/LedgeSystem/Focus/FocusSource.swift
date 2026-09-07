import Foundation
import LedgeCore
import os

/// The Focus mode currently active, if any.
public struct FocusSnapshot: Equatable, Sendable {
    public var identifier: String
    public var name: String
    public var symbolName: String

    public init(identifier: String, name: String, symbolName: String) {
        self.identifier = identifier
        self.name = name
        self.symbolName = symbolName
    }
}

/// Where Focus state comes from.
@MainActor
public protocol FocusSource: AnyObject {

    /// Whether the backing store can be read. False without Full Disk Access —
    /// and checking must never prompt, because nothing *can* prompt for FDA.
    var isReadable: Bool { get }

    /// The active Focus, or nil when none is on.
    func current() -> FocusSnapshot?

    func startWatching(_ onChange: @escaping () -> Void)
    func stopWatching()
}

/// Reads Focus state from `~/Library/DoNotDisturb/DB`.
///
/// Everything here is private file format, protected by Full Disk Access and
/// undocumented. Two rules follow:
///
/// - **Parse defensively.** Every field is optional, every decode is `try?`,
///   and an unrecognised shape yields nil rather than an error. This file *will*
///   change in some macOS update; when it does, the Focus card silently goes
///   away — it must never crash or spam the log.
/// - **Names can be missing.** A hard-coded fallback map covers the built-in
///   modes, so "Do Not Disturb" still reads as such even if the configuration
///   file becomes unreadable while the assertions file still parses.
///
/// Schema verified on macOS 26.4:
/// `Assertions.json` → `data[0].storeAssertionRecords[].assertionDetails
/// .assertionDetailsModeIdentifier`; `ModeConfigurations.json` →
/// `data[0].modeConfigurations[id].mode.{name, symbolImageName}`.
@MainActor
public final class FileFocusSource: FocusSource {

    private nonisolated static let log = Logger(subsystem: "com.egemert.ledge", category: "focus")

    private nonisolated static var databaseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    /// Names for the identifiers Apple ships, used when the configuration file
    /// cannot be read or does not list the mode.
    nonisolated static let builtInModes: [String: (name: String, symbol: String)] = [
        "com.apple.donotdisturb.mode.default": ("Do Not Disturb", "moon.fill"),
        "com.apple.focus.work": ("Work", "person.lanyardcard.fill"),
        "com.apple.focus.personal-time": ("Personal", "person.fill"),
        "com.apple.sleep.sleep-mode": ("Sleep", "bed.double.fill"),
        "com.apple.focus.reading": ("Reading", "book.closed.fill"),
        "com.apple.focus.gaming": ("Gaming", "gamecontroller.fill"),
        "com.apple.focus.fitness": ("Fitness", "figure.run"),
        "com.apple.focus.mindfulness": ("Mindfulness", "brain.head.profile"),
        "com.apple.focus.driving": ("Driving", "car.fill"),
        "com.apple.focus.reduce-interruptions": ("Reduce Interruptions", "moon.fill"),
    ]

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: Int32 = -1
    private var readyRetry: Task<Void, Never>?
    private var pendingOnChange: (() -> Void)?

    public init() {}

    public var isReadable: Bool {
        let path = Self.databaseDirectory.appendingPathComponent("Assertions.json")
        guard let handle = try? FileHandle(forReadingFrom: path) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil
    }

    /// Appends a line to `~/.ledge-focus-diag` when `LEDGE_FOCUS_DIAG=1`. Lets the
    /// Focus pipeline be traced live (does the watcher fire, does the active
    /// schema parse) without a debugger or a rebuild between attempts.
    nonisolated static func diag(_ message: String) {
        guard DebugSwitches.isOn("LEDGE_FOCUS_DIAG") else { return }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".ledge-focus-diag")
        if let data = (message + "\n").data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    public func current() -> FocusSnapshot? {
        let raw = read("Assertions.json")
        let identifier = Self.activeModeIdentifier(from: raw)
        Self.diag("current: bytes=\(raw?.count ?? -1) id=\(identifier ?? "nil")")
        guard let identifier else { return nil }

        let configured = Self.modeDetails(from: read("ModeConfigurations.json"))[identifier]
        let fallback = Self.builtInModes[identifier]

        return FocusSnapshot(
            identifier: identifier,
            name: configured?.name ?? fallback?.name ?? "Focus",
            symbolName: configured?.symbol ?? fallback?.symbol ?? "moon.fill"
        )
    }

    private func read(_ file: String) -> Data? {
        try? Data(contentsOf: Self.databaseDirectory.appendingPathComponent(file))
    }

    // MARK: - Parsing

    /// Pulled out and nonisolated so recorded fixtures can drive them in tests.

    nonisolated static func activeModeIdentifier(from data: Data?) -> String? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["data"] as? [[String: Any]])?.first,
              let records = first["storeAssertionRecords"] as? [[String: Any]]
        else { return nil }

        for record in records {
            if let details = record["assertionDetails"] as? [String: Any],
               let identifier = details["assertionDetailsModeIdentifier"] as? String {
                return identifier
            }
        }
        return nil
    }

    nonisolated static func modeDetails(
        from data: Data?
    ) -> [String: (name: String, symbol: String)] {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["data"] as? [[String: Any]])?.first,
              let configurations = first["modeConfigurations"] as? [String: Any]
        else { return [:] }

        var result: [String: (String, String)] = [:]
        for (identifier, value) in configurations {
            guard let entry = value as? [String: Any],
                  let mode = entry["mode"] as? [String: Any]
            else { continue }
            result[identifier] = (
                mode["name"] as? String ?? Self.builtInModes[identifier]?.name ?? "Focus",
                mode["symbolImageName"] as? String
                    ?? Self.builtInModes[identifier]?.symbol ?? "moon.fill"
            )
        }
        return result
    }

    // MARK: - Watching

    public func startWatching(_ onChange: @escaping () -> Void) {
        stopWatching()
        pendingOnChange = onChange

        // Watch the directory, not a file: the files are replaced atomically on
        // change, which orphans a per-file descriptor after the first write.
        let descriptor = open(Self.databaseDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Either the directory does not exist yet — an account that never
            // toggled Focus has none — or it is there and unreadable, which
            // means Full Disk Access. Ledge does not ask for that: the Focus
            // card works from the Focus-status permission, and the database
            // only ever added the mode's *name*. So this is a note, not a
            // problem to solve.
            Self.log.notice("Focus database not readable — mode names will read as \"Focus\"")
            Self.diag("startWatching: OPEN FAILED path=\(Self.databaseDirectory.path) errno=\(errno)")
            // The directory can appear later — the first time this account
            // turns a Focus on — and on a Mac that happens to have granted
            // Full Disk Access for other reasons the names become readable
            // too. Worth noticing, not worth hurrying for.
            scheduleReadyRetry()
            return
        }
        watchedDescriptor = descriptor
        Self.diag("startWatching: watching fd=\(descriptor) path=\(Self.databaseDirectory.path)")

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .link, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                Self.diag("watcher fired")
                self?.coalesce(onChange)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    /// Waits for the Focus database to become readable, then starts watching
    /// and re-reads, so a Focus already on shows immediately.
    private func scheduleReadyRetry() {
        readyRetry?.cancel()
        readyRetry = Task { @MainActor [weak self] in
            // This is the steady state on most Macs, not a transient: nobody
            // is being asked for anything, so nothing is about to change in
            // the next few seconds. Start brisk in case a Focus is being set
            // up right now, then settle to a stat every few minutes.
            var delay: Double = 2
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 1.5, 300)
                guard let self, let onChange = self.pendingOnChange else { return }
                if self.isReadable {
                    Self.diag("readyRetry: database now readable — starting watch")
                    self.startWatching(onChange)  // now the open() succeeds
                    onChange()                    // surface a Focus already active
                    return
                }
            }
        }
    }

    /// Collapses a burst of file writes into one callback.
    ///
    /// macOS rewrites the DND database in several steps for a single Focus
    /// toggle, so the raw source fires repeatedly. Debouncing means the provider
    /// re-reads once, not four times, per change.
    private var debounce: DispatchWorkItem?

    private func coalesce(_ onChange: @escaping () -> Void) {
        debounce?.cancel()
        let item = DispatchWorkItem { onChange() }
        debounce = item
        // Short enough to feel immediate on a toggle, long enough to still
        // collapse the burst of writes macOS makes for a single change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    public func stopWatching() {
        debounce?.cancel()
        debounce = nil
        readyRetry?.cancel()
        readyRetry = nil
        pendingOnChange = nil
        watcher?.cancel()
        watcher = nil
        watchedDescriptor = -1
    }

    /// A last-resort close for the watch descriptor if the object is released
    /// without `stopWatching` being called. `DispatchSourceFileSystemObject` is
    /// `Sendable`, so cancelling it from the nonisolated `deinit` is safe, and
    /// its cancel handler closes the fd.
    deinit {
        watcher?.cancel()
    }
}

/// Fixed state, for tests.
@MainActor
public final class StubFocusSource: FocusSource {

    public var isReadable: Bool
    private var value: FocusSnapshot?
    private var onChange: (() -> Void)?

    public init(value: FocusSnapshot? = nil, isReadable: Bool = true) {
        self.value = value
        self.isReadable = isReadable
    }

    public func current() -> FocusSnapshot? {
        isReadable ? value : nil
    }

    public func set(_ value: FocusSnapshot?) {
        self.value = value
        onChange?()
    }

    public func startWatching(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    public func stopWatching() {
        onChange = nil
    }
}
