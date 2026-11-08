import Darwin
import Foundation
import LedgeCore
import os

/// One file in the feeds folder, as found.
///
/// Bytes, not a parsed feed: what a file means is `LedgeCore`'s business, and
/// this layer's only job is to say what is on the disk.
public struct FeedFile: Equatable, Sendable {

    /// The file's name without its extension — a feed's id when the file
    /// names none of its own.
    public let name: String

    /// The contents, or nil when the file was too large to be worth reading.
    /// No more than `FeedParser.maxBytes + 1` bytes of a file are ever read.
    public let data: Data?

    /// How big the file is, for saying so in the log.
    public let byteCount: Int

    /// When the file was last written, in Unix seconds.
    public let modifiedAt: TimeInterval

    public init(name: String, data: Data?, byteCount: Int? = nil, modifiedAt: TimeInterval = 0) {
        self.name = name
        self.data = data
        self.byteCount = byteCount ?? data?.count ?? 0
        self.modifiedAt = modifiedAt
    }
}

/// Where feed files come from.
@MainActor
public protocol FeedSource: AnyObject {

    /// Starts watching, and hands over every feed file there is, on the main
    /// actor: once as soon as they have been read, and again whenever the
    /// folder may have changed. The reading itself happens wherever the
    /// source likes — for the folder, never on the main thread.
    func startWatching(_ onFiles: @escaping ([FeedFile]) -> Void)
    func stopWatching()
}

/// Feed files in a folder, by default `~/Library/Application Support/Ledge/Feeds/`.
///
/// Other programs are invited to write here, so nothing in it is trusted, and
/// Ledge itself never writes here beyond making the folder.
///
/// Producers replace a file by writing a temporary one beside it and renaming
/// it over the original, so a reader never sees half a file. That is also why
/// the *folder* is watched and not the files: a rename gives the name a new
/// inode, and a descriptor held on the old one hears nothing more, while the
/// folder hears every rename into it.
///
/// A slow rescan stands behind the watcher. It costs a directory listing a
/// minute, and covers a producer that writes in place — which the folder
/// cannot hear — and a folder that was deleted and made again, which leaves
/// the watcher holding the old one. It is also how a feed goes stale, since
/// nothing on the disk changes when a deadline passes.
///
/// Everything here is untrusted: whatever wrote the folder, nothing in it may
/// stall the app. So the folder is read off the main thread, at most
/// `maxFiles` files of it, each opened once without following links or
/// waiting, checked to be a plain file, and read no further than the size
/// limit.
@MainActor
public final class FeedFolderSource: FeedSource {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "feeds")

    public nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ledge/Feeds", isDirectory: true)
    }

    /// The most files read, first by name. A card per file, and a glance does
    /// not have room for more; past it the folder is someone's job queue, and
    /// reading all of it on every change is what made the notch stutter.
    public nonisolated static let maxFiles = 16

    /// How long a burst of events waits to be heard as one. A producer that
    /// writes a few files in a row should cost one read, not one each.
    static let coalesceDelay: Duration = .milliseconds(150)

    /// The longest a burst is held back, however long it goes on. Without it a
    /// producer that wrote faster than `coalesceDelay` was never heard until
    /// the backstop, a minute later.
    static let longestCoalesce: Duration = .seconds(1)

    static let backstopInterval: Duration = .seconds(60)

    private let directory: URL
    private var onFiles: (([FeedFile]) -> Void)?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFileNumber: UInt64?
    private var debounce: Task<Void, Never>?
    private var burstStarted: ContinuousClock.Instant?
    private var backstop: Task<Void, Never>?

    /// Bumped by every start and stop, so a read that finishes after a stop
    /// is dropped instead of delivered.
    private var generation = 0
    private var readInFlight = false
    private var readAgain = false
    private var lastOverflow = 0
    /// What was last said about each name that could not be read, so a link
    /// sitting in the folder is logged once and not on every scan.
    private var lastRefused: [String: String] = [:]

    /// Nothing touches the disk until `startWatching`: the registry builds a
    /// provider just to ask its name, and a feature that is switched off must
    /// not make a folder.
    public init(directory: URL = FeedFolderSource.defaultDirectory()) {
        self.directory = directory
    }

    deinit {
        watcher?.cancel()
    }

    // MARK: - Reading

    /// Every feed file in the folder right now, read on the calling thread.
    /// The source itself only ever calls this off the main thread.
    public nonisolated func files() -> [FeedFile] {
        Self.read(directory).files
    }

    struct Reading: Sendable {
        var files: [FeedFile]
        /// Names past the first `maxFiles` files, counted and never opened.
        var overflow: Int
        /// Why each name that could not be read was turned away, by file
        /// name: a link, a pipe, a folder, a file that would not open.
        var refused: [String: String] = [:]
    }

    nonisolated static func read(_ directory: URL) -> Reading {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return Reading(files: [], overflow: 0)
        }
        let candidates = names
            .filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == "json" }
            .sorted()
        var files: [FeedFile] = []
        var overflow = 0
        var refused: [String: String] = [:]
        for name in candidates {
            // Once the cards are full the rest are only counted. Opening them
            // just to say how many there were cost a folder of two thousand
            // files two thousand reads on every change.
            if files.count == maxFiles {
                overflow += 1
                continue
            }
            let path = directory.appendingPathComponent(name).path
            let stem = (name as NSString).deletingPathExtension
            guard let file = readFile(atPath: path, name: stem) else {
                refused[name] = refusal(atPath: path)
                continue
            }
            files.append(file)
        }
        return Reading(files: files, overflow: overflow, refused: refused)
    }

    /// Why `readFile` turned a name away, for the log. Asked only after it
    /// has, so a folder of good files never pays for it.
    nonisolated static func refusal(atPath path: String) -> String {
        var status = stat()
        guard lstat(path, &status) == 0 else { return "it could not be opened" }
        switch status.st_mode & S_IFMT {
        case S_IFLNK: return "it is a link, and links are not followed"
        case S_IFREG: return "it could not be opened"
        default: return "it is not a plain file"
        }
    }

    /// One file, opened once and judged by what was opened, never by what the
    /// listing said a moment earlier: a name can be swapped for a link, a
    /// pipe or something enormous between the two.
    ///
    /// - `O_NOFOLLOW`: a link is refused, wherever it points.
    /// - `O_NONBLOCK`: opening a pipe returns at once instead of waiting for
    ///   a writer that may never come.
    /// - Only a regular file is read, and no more than one byte past the
    ///   limit, so a file that grew after `fstat` is still caught.
    ///
    /// Nil for anything that is not a plain file that could be opened.
    nonisolated static func readFile(atPath path: String, name: String) -> FeedFile? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = TimeInterval(status.st_mtimespec.tv_sec)
            + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        let size = Int(status.st_size)
        guard size <= FeedParser.maxBytes else {
            return FeedFile(name: name, data: nil, byteCount: size, modifiedAt: modified)
        }

        let capacity = FeedParser.maxBytes + 1
        var buffer = [UInt8](repeating: 0, count: capacity)
        var total = 0
        while total < capacity {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress! + total, capacity - total)
            }
            if count > 0 {
                total += count
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        guard total <= FeedParser.maxBytes else {
            return FeedFile(name: name, data: nil, byteCount: total, modifiedAt: modified)
        }
        return FeedFile(name: name, data: Data(buffer[0..<total]), modifiedAt: modified)
    }

    // MARK: - Watching

    public func startWatching(_ onFiles: @escaping ([FeedFile]) -> Void) {
        stopWatching()
        self.onFiles = onFiles
        generation += 1
        openWatcher()
        requestRead()
        backstop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backstopInterval)
                guard !Task.isCancelled, let self else { return }
                self.backstopTick()
            }
        }
    }

    public func stopWatching() {
        debounce?.cancel()
        debounce = nil
        burstStarted = nil
        backstop?.cancel()
        backstop = nil
        watcher?.cancel()
        watcher = nil
        watchedFileNumber = nil
        onFiles = nil
        generation += 1
        readAgain = false
    }

    /// The backstop's turn: make sure the watcher is on the folder that is
    /// there now, then read it.
    private func backstopTick() {
        if watcher == nil || fileNumber() != watchedFileNumber {
            openWatcher()
        }
        requestRead()
    }

    /// Reads the folder off the main thread and delivers it back here. One
    /// read at a time; a request that arrives during one is folded into a
    /// single read after it.
    private func requestRead() {
        guard onFiles != nil else { return }
        guard !readInFlight else {
            readAgain = true
            return
        }
        readInFlight = true
        let directory = directory
        let started = generation
        Task { @MainActor [weak self] in
            let reading = await Task.detached(priority: .utility) {
                Self.read(directory)
            }.value
            self?.finishRead(reading, generation: started)
        }
    }

    private func finishRead(_ reading: Reading, generation started: Int) {
        readInFlight = false
        if started == generation, let onFiles {
            if reading.overflow != lastOverflow {
                lastOverflow = reading.overflow
                if reading.overflow > 0 {
                    Self.log.notice("""
                        feeds: \(reading.overflow, privacy: .public) files past the first \
                        \(Self.maxFiles, privacy: .public) were not read
                        """)
                }
            }
            for (name, reason) in reading.refused.sorted(by: { $0.key < $1.key })
            where lastRefused[name] != reason {
                Self.log.notice("feed \(name, privacy: .public) skipped: \(reason, privacy: .public)")
            }
            lastRefused = reading.refused
            onFiles(reading.files)
        }
        if readAgain {
            readAgain = false
            requestRead()
        }
    }

    private func openWatcher() {
        watcher?.cancel()
        watcher = nil
        watchedFileNumber = nil

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.log.notice("feeds folder could not be made: \(error.localizedDescription, privacy: .public)")
            return
        }
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.log.notice("feeds folder could not be watched (errno \(errno, privacy: .public))")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.heard() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        watchedFileNumber = fileNumber()
    }

    private func heard() {
        // The folder itself going away leaves the watcher on a directory
        // nobody can reach. Let the backstop find the new one.
        if !FileManager.default.fileExists(atPath: directory.path) {
            watcher?.cancel()
            watcher = nil
            watchedFileNumber = nil
        }
        let now = ContinuousClock.now
        let started = burstStarted ?? now
        burstStarted = started
        debounce?.cancel()
        // A burst that has gone on long enough is read now, and the wait
        // starts again with whatever comes after.
        if now - started >= Self.longestCoalesce {
            burstStarted = nil
            debounce = nil
            requestRead()
            return
        }
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard !Task.isCancelled, let self else { return }
            self.burstStarted = nil
            self.requestRead()
        }
    }

    /// Which directory is at the path, so a folder deleted and made again can
    /// be told from the one the watcher is holding.
    private func fileNumber() -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.systemFileNumber] as? UInt64
    }
}

/// Fixed files, for tests. Delivers at once and on every `set`, the way the
/// folder would after its read.
@MainActor
public final class StubFeedSource: FeedSource {

    public var stored: [FeedFile]
    private var onFiles: (([FeedFile]) -> Void)?

    public init(files: [FeedFile] = []) {
        stored = files
    }

    public var isWatching: Bool { onFiles != nil }

    public func files() -> [FeedFile] { stored }

    public func startWatching(_ onFiles: @escaping ([FeedFile]) -> Void) {
        self.onFiles = onFiles
        onFiles(stored)
    }

    public func stopWatching() {
        onFiles = nil
    }

    /// Replaces what is on the "disk" and tells the watcher, the way a
    /// producer renaming a file into the folder would.
    public func set(_ files: [FeedFile]) {
        stored = files
        onFiles?(files)
    }
}
