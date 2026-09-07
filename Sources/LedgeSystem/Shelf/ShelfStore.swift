import AppKit
import Foundation
import QuickLookThumbnailing
import LedgeCore
import os

/// Holds the files parked in the notch.
///
/// The app is not sandboxed, so a dropped URL is directly readable and none of
/// the security-scoped bookmark machinery is needed. Only the *paths* are
/// persisted: icons are re-derived on load, and a file that moved or was deleted
/// while Ledge was closed simply drops out rather than becoming a dead tile.
@MainActor
public final class ShelfStore {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "shelf")

    /// A generous cap. The shelf is a staging area, not a file manager, and an
    /// unbounded row of tiles would run off the screen.
    public static let capacity = 12

    public private(set) var items: [ShelfItem] = []

    /// Fires whenever the contents change, so the provider can republish.
    public var onChange: () -> Void = {}

    private let load: () -> String
    private let save: (String) -> Void
    private let fileManager: FileManager

    public init(
        load: @escaping () -> String,
        save: @escaping (String) -> Void,
        fileManager: FileManager = .default
    ) {
        self.load = load
        self.save = save
        self.fileManager = fileManager
        restore()
    }

    public var isEmpty: Bool { items.isEmpty }

    // MARK: - Editing

    /// How long an automatically-added screenshot stays.
    ///
    /// A day: long enough that yesterday's screenshot is still there when it
    /// turns out to be wanted, short enough that the shelf is not a filing
    /// cabinet. Only what Ledge put there itself is on a clock — a file the
    /// user dropped stays until they take it out.
    public static let screenshotLifetime: TimeInterval = 24 * 60 * 60

    /// Adds files, ignoring ones already present. Returns how many were new.
    ///
    /// - Parameter expiresAfter: seconds until the entry removes itself, or
    ///   nil for one that stays.
    @discardableResult
    public func add(_ urls: [URL], expiresAfter: TimeInterval? = nil) -> Int {
        var added = 0
        let expiry = expiresAfter.map { Date().timeIntervalSinceReferenceDate + $0 }
        for url in urls {
            // A dropped web link is not a file: `url.path` of https://host/etc
            // is "/etc", and the shelf would have parked a local directory it
            // was never handed.
            guard url.isFileURL else { continue }
            let path = url.path
            guard !items.contains(where: { $0.path == path }) else { continue }
            guard var item = Self.item(for: url, fileManager: fileManager) else { continue }
            item.expiresAt = expiry
            items.append(item)
            added += 1
        }
        if items.count > Self.capacity {
            // Oldest out first: the newest drop is what the user is looking at.
            items.removeFirst(items.count - Self.capacity)
        }
        if added > 0 {
            Self.log.notice("shelf: added \(added, privacy: .public) item(s)")
            persist()
            onChange()
            for url in urls { refineIcon(forPath: url.path) }
        }
        return added
    }

    public func remove(path: String) {
        guard items.contains(where: { $0.path == path }) else { return }
        items.removeAll { $0.path == path }
        persist()
        onChange()
    }

    public func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        persist()
        onChange()
    }

    /// Drops entries whose time is up.
    ///
    /// Run on the same occasions as `pruneMissing` — whenever the shelf is
    /// about to be looked at — rather than on a timer of its own. A shelf
    /// nobody is looking at does not need tidying, and a tile that has just
    /// expired is only wrong once somebody can see it.
    @discardableResult
    public func pruneExpired(now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Int {
        let survivors = items.filter { item in
            guard let expiresAt = item.expiresAt else { return true }
            return expiresAt > now
        }
        let dropped = items.count - survivors.count
        guard dropped > 0 else { return 0 }
        items = survivors
        Self.log.notice("shelf: \(dropped, privacy: .public) item(s) timed out")
        persist()
        onChange()
        return dropped
    }

    /// Drops entries whose file has since disappeared. Cheap enough to run
    /// whenever the shelf is shown.
    public func pruneMissing() {
        let survivors = items.filter { !isConfirmedGone($0.path) }
        guard survivors.count != items.count else { return }
        items = survivors
        persist()
        onChange()
    }

    /// Deleted versus unreachable: a file on an unmounted external volume is
    /// not gone, and forgetting it would empty the shelf every time a drive
    /// is ejected. Only a file whose volume is present yet which is absent is
    /// treated as deleted.
    private func isConfirmedGone(_ path: String) -> Bool {
        guard !fileManager.fileExists(atPath: path) else { return false }
        guard path.hasPrefix("/Volumes/") else { return true }
        let volume = "/Volumes/" + path.dropFirst("/Volumes/".count).prefix { $0 != "/" }
        return fileManager.fileExists(atPath: volume)
    }

    // MARK: - Persistence

    /// Paths are stored in one preference (`PrefKey` supports no arrays),
    /// joined on the unit separator: a newline is a *legal* APFS filename
    /// character and splitting on it corrupted such paths. Legacy
    /// newline-joined values still restore.
    private static let pathSeparator = "\u{1F}"
    /// Splits an entry's path from its expiry. A different control character
    /// from the one between entries, so neither can be mistaken for the other.
    private static let expirySeparator = "\u{1E}"

    /// Re-reads the persisted list, replacing the live one — for a reset (or
    /// an external edit) that changed the preference underneath the store,
    /// which would otherwise keep the old items and write them straight back.
    public func reload() {
        items = []
        restore()
        onChange()
    }

    private func restore() {
        let stored = load()
        guard !stored.isEmpty else { return }
        // Legacy values (newline-joined) contain no unit separator; a value
        // written by this build does. Splitting on *both* unconditionally
        // would re-corrupt a newline-bearing filename the new format encodes
        // fine — and then prune its fragments as confirmed-gone.
        let separator = stored.contains(Self.pathSeparator) ? Self.pathSeparator : "\n"
        let entries = stored
            .components(separatedBy: separator)
            .filter { !$0.isEmpty }
        items = entries.compactMap { entry in
            let parts = entry.components(separatedBy: Self.expirySeparator)
            let path = parts[0]
            let expiresAt = parts.count > 1 ? TimeInterval(parts[1]) : nil
            if var item = Self.item(for: URL(fileURLWithPath: path), fileManager: fileManager) {
                item.expiresAt = expiresAt
                return item
            }
            // Confirmed deleted since last launch: silently forgotten, so the
            // stored list cannot accumulate rubbish for ever.
            guard !isConfirmedGone(path) else { return nil }
            // Volume not mounted right now: keep the seat with a bare tile;
            // the icon refines if the drive returns.
            return ShelfItem(
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                isDirectory: false,
                iconData: nil,
                expiresAt: expiresAt
            )
        }
        if items.count != entries.count { persist() }
        // A shelf restored after a night away may hold screenshots whose day
        // ran out while the Mac was asleep.
        pruneExpired()
        for item in items { refineIcon(forPath: item.path) }
    }

    private func persist() {
        // A trailing separator marks the format even for a single item —
        // without it, one parked file whose name contains a newline stored
        // no separator at all, was sniffed as legacy, and split apart.
        // Each entry is its path, and — for one on a clock — the record
        // separator and the instant it expires. An entry with no separator is
        // one that stays, which is also what every previously stored entry is.
        let joined = items
            .map { item in
                guard let expiresAt = item.expiresAt else { return item.path }
                return "\(item.path)\(Self.expirySeparator)\(expiresAt)"
            }
            .joined(separator: Self.pathSeparator)
        save(joined.isEmpty ? "" : joined + Self.pathSeparator)
    }

    // MARK: - Building

    /// Turns a URL into a shelf entry, rendering the Finder icon to PNG bytes so
    /// it can cross into `LedgeCore` (which may not see AppKit).
    /// Replaces an item's icon with a real QuickLook thumbnail once one is
    /// rendered — the generic file icon shows instantly, the preview follows.
    /// A white "PNG" document glyph for a screenshot read as a blank tile;
    /// the actual image is what tells two screenshots apart.
    private func refineIcon(forPath path: String) {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 64, height: 64),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let thumbnail else { return }
            let image = NSImage(cgImage: thumbnail.cgImage, size: .zero)
            guard let data = Self.pngData(from: image) else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let index = self.items.firstIndex(where: { $0.path == path })
                else { return }
                self.items[index].iconData = data
                self.onChange()
            }
        }
    }

    nonisolated static func item(for url: URL, fileManager: FileManager) -> ShelfItem? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)

        return ShelfItem(
            path: url.path,
            name: url.lastPathComponent,
            isDirectory: isDirectory.boolValue,
            iconData: pngData(from: icon)
        )
    }

    private nonisolated static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
