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

    /// What the file actually said: a mode, nothing, or a shape this version
    /// does not know. `current()` collapses the last two into nil, which is
    /// the right answer for drawing a card and the wrong one for deciding
    /// whether to fall back.
    func reading() -> FocusReading

    func startWatching(_ onChange: @escaping () -> Void)
    func stopWatching()
}

/// What a Focus source managed to establish.
///
/// Separate from `FocusSnapshot?` because "nothing is on" and "I could not
/// understand this" are different facts with different consequences: the first
/// is authoritative and should override a stale fallback, the second means
/// this source knows nothing and another one should answer.
public enum FocusReading: Equatable, Sendable {
    case on(FocusSnapshot)
    case off
    case unintelligible
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
/// .assertionDetailsModeIdentifier`, with `storeAssertionRecords` absent when
/// no Focus is on; `ModeConfigurations.json` →
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
        if case .on(let snapshot) = reading() { return snapshot }
        return nil
    }

    public func reading() -> FocusReading {
        let raw = read("Assertions.json")
        let assertions = Self.assertions(from: raw)
        Self.diag("current: bytes=\(raw?.count ?? -1) assertions=\(assertions)")

        switch assertions {
        case .unintelligible:
            // Readable bytes we cannot make sense of. Saying "no Focus" here
            // would be a guess wearing the clothes of an answer.
            return .unintelligible
        case .inactive:
            return .off
        case .active(let identifier):
            let configured = Self.modeDetails(from: read("ModeConfigurations.json"))[identifier]
            let fallback = Self.builtInModes[identifier]
            return .on(FocusSnapshot(
                identifier: identifier,
                name: configured?.name ?? fallback?.name ?? "Focus",
                symbolName: configured?.symbol ?? fallback?.symbol ?? "moon.fill"
            ))
        }
    }

    private func read(_ file: String) -> Data? {
        try? Data(contentsOf: Self.databaseDirectory.appendingPathComponent(file))
    }

    // MARK: - Parsing

    /// Pulled out and nonisolated so recorded fixtures can drive them in tests.

    /// What the assertions file had to say.
    ///
    /// Three answers, not two. "No Focus is on" and "this file is not in a
    /// shape I know" both used to come back as nil, and the caller could only
    /// read that as Focus-off — so a schema change in a future macOS would not
    /// break Focus loudly, it would quietly report every Focus as off and
    /// suppress the public fallback that would otherwise have covered it.
    public enum Assertions: Equatable, Sendable {
        /// Understood, and this mode is on.
        case active(String)
        /// Understood, and nothing is on. Authoritative: it overrides a stale
        /// fallback saying otherwise.
        case inactive
        /// Not in a shape this version knows — bytes that are not JSON, or
        /// JSON without the records this reads. Says nothing either way, so
        /// the caller must fall back rather than conclude.
        case unintelligible
    }

    nonisolated static func assertions(from data: Data?) -> Assertions {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["data"] as? [[String: Any]])?.first
        else { return .unintelligible }

        guard let records = first["storeAssertionRecords"] as? [[String: Any]] else {
            // This is what macOS actually writes when no Focus is on: the
            // records key is left out, and only the invalidation records of
            // the Focus that ended remain. Reading that as unknown let a stale
            // public reading say a Focus was still on. Without either key it
            // is a shape this version does not know.
            let isKnownOffShape = first["storeInvalidationRecords"] is [Any]
                || first["storeInvalidationRequestRecords"] is [Any]
            return isKnownOffShape ? .inactive : .unintelligible
        }

        for record in records {
            if let details = record["assertionDetails"] as? [String: Any],
               let identifier = details["assertionDetailsModeIdentifier"] as? String {
                return .active(identifier)
            }
        }
        // The shape is right and carries no assertion: nothing is on.
        return .inactive
    }

    nonisolated static func activeModeIdentifier(from data: Data?) -> String? {
        if case .active(let identifier) = assertions(from: data) { return identifier }
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
            // Either Ledge has not been given the folder, or the directory
            // simply does not exist yet — an account that has never turned a
            // Focus on has none.
            Self.log.notice("""
                Focus database not readable — the card will follow the timer, and \
                modes will read as "Focus". Settings offers the folder.
                """)
            Self.diag("startWatching: OPEN FAILED path=\(Self.databaseDirectory.path) errno=\(errno)")
            // The folder can be given at any moment from Settings, and the
            // directory itself appears the first time this account turns a
            // Focus on. Either way, start watching without a relaunch.
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

    /// Access has just been given: look again now rather than when the backoff
    /// next comes round.
    ///
    /// The retry below settles to half a minute between attempts, which is
    /// right for waiting on something nobody has been asked for — and wrong
    /// for the moment straight after the user hands over the folder, where it
    /// showed as up to thirty seconds of the app ignoring their Focus. The
    /// user did something; answer immediately.
    public func recheckAccess() {
        guard let onChange = pendingOnChange else { return }
        readyRetry?.cancel()
        readyRetry = nil
        guard isReadable else { return scheduleReadyRetry() }
        startWatching(onChange)
        onChange()
    }

    /// Waits for the database to become readable, then starts watching and
    /// re-reads, so a Focus already on shows immediately.
    private func scheduleReadyRetry() {
        readyRetry?.cancel()
        readyRetry = Task { @MainActor [weak self] in
            // This is the steady state on most Macs — nobody has been asked
            // for the folder, and the account may never have turned a Focus on
            // — so it settles to a slow idle rather than stat-ing forever.
            // `recheckAccess()` covers the one moment that matters.
            var delay: Double = 2
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 1.5, 30)
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
    /// Set to stage the case the file can be opened and not understood.
    public var isUnintelligible: Bool
    private var onChange: (() -> Void)?

    public init(
        value: FocusSnapshot? = nil,
        isReadable: Bool = true,
        isUnintelligible: Bool = false
    ) {
        self.value = value
        self.isReadable = isReadable
        self.isUnintelligible = isUnintelligible
    }

    public func current() -> FocusSnapshot? {
        isReadable ? value : nil
    }

    public func reading() -> FocusReading {
        guard isReadable, !isUnintelligible else { return .unintelligible }
        return value.map(FocusReading.on) ?? .off
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
