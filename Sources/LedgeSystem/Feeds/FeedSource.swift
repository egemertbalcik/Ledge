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
    /// A file over the limit is never read into memory at all.
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

    /// Every feed file there is right now, in a stable order.
    func files() -> [FeedFile]

    /// Calls back, on the main actor, when something in the folder may have
    /// changed. A hint rather than a diff: the caller reads `files()` again.
    func startWatching(_ onChange: @escaping () -> Void)
    func stopWatching()
}

/// Feed files in a folder, by default
/// `~/Library/Application Support/Ledge/Feeds/`.
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
/// the watcher holding the old one.
@MainActor
public final class FeedFolderSource: FeedSource {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "feeds")

    public nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ledge/Feeds", isDirectory: true)
    }

    /// How long a burst of events waits to be heard as one. A producer that
    /// writes a few files in a row should cost one read, not one each.
    static let coalesceDelay: Duration = .milliseconds(150)

    static let backstopInterval: Duration = .seconds(60)

    private let directory: URL
    private var onChange: (() -> Void)?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFileNumber: UInt64?
    private var debounce: Task<Void, Never>?
    private var backstop: Task<Void, Never>?

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

    public func files() -> [FeedFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> FeedFile? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile != false else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                let size = values?.fileSize ?? 0
                let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                guard size <= FeedParser.maxBytes else {
                    return FeedFile(name: name, data: nil, byteCount: size, modifiedAt: modified)
                }
                // Gone between the listing and the read: replaced or removed
                // by its producer. The folder will say so again.
                guard let data = try? Data(contentsOf: url) else { return nil }
                return FeedFile(name: name, data: data, modifiedAt: modified)
            }
    }

    // MARK: - Watching

    public func startWatching(_ onChange: @escaping () -> Void) {
        stopWatching()
        self.onChange = onChange
        openWatcher()
        backstop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backstopInterval)
                guard !Task.isCancelled, let self else { return }
                self.rescan()
            }
        }
    }

    public func stopWatching() {
        debounce?.cancel()
        debounce = nil
        backstop?.cancel()
        backstop = nil
        watcher?.cancel()
        watcher = nil
        watchedFileNumber = nil
        onChange = nil
    }

    /// The backstop's turn: make sure the watcher is on the folder that is
    /// there now, then say that something may have changed.
    private func rescan() {
        if watcher == nil || fileNumber() != watchedFileNumber {
            openWatcher()
        }
        onChange?()
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
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard !Task.isCancelled, let self else { return }
            self.onChange?()
        }
    }

    /// Which directory is at the path, so a folder deleted and made again can
    /// be told from the one the watcher is holding.
    private func fileNumber() -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.systemFileNumber] as? UInt64
    }
}

/// Fixed files, for tests.
@MainActor
public final class StubFeedSource: FeedSource {

    public var stored: [FeedFile]
    private var onChange: (() -> Void)?

    public init(files: [FeedFile] = []) {
        stored = files
    }

    public var isWatching: Bool { onChange != nil }

    public func files() -> [FeedFile] { stored }

    public func startWatching(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    public func stopWatching() {
        onChange = nil
    }

    /// Replaces what is on the "disk" and tells the watcher, the way a
    /// producer renaming a file into the folder would.
    public func set(_ files: [FeedFile]) {
        stored = files
        onChange?()
    }
}
