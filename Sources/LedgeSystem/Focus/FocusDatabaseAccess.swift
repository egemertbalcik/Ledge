import Foundation
import os

/// Access to the Focus database folder, bought with one open panel rather than
/// with Full Disk Access.
///
/// `~/Library/DoNotDisturb/DB` is where macOS records which Focus is on, and
/// reading it is what makes the Focus card *immediate* — the folder can be
/// watched, so the card follows the switch instead of a poll — and what gives
/// the mode its own name instead of the word "Focus".
///
/// The obvious way in is Full Disk Access, and it is a bad bargain: it grants
/// access to every file the user owns in exchange for one folder, it cannot be
/// prompted for, and macOS quits the app the moment it is granted. The
/// alternative, measured rather than assumed: a folder the user picks in an
/// `NSOpenPanel` becomes readable to this app even though it is TCC-protected,
/// and stays readable across launches. Verified on macOS 26 with a signed app
/// holding no permissions at all — refused before the pick, 2,382 bytes read
/// after it, and read again by a fresh process with no panel shown.
///
/// A security-scoped bookmark is kept as well. The plain grant has always come
/// back on its own in testing; the bookmark is the belt to that pair of braces,
/// and costs one resolve at launch.
///
/// This type holds no policy about *asking*: presenting a panel is AppKit's
/// business and belongs to the shell. Here it is only the bookmark, the URL it
/// resolves to, and the scope that has to be held open while the folder is read.
public final class FocusDatabaseAccess: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "focus")

    /// Where the database lives, and so what the panel should be pointed at.
    public static var databaseFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    private let bookmark: () -> String
    private let storeBookmark: (String) -> Void

    /// The URL whose scope is currently held open, so it can be closed again.
    private var scoped: URL?

    public init(bookmark: @escaping () -> String, storeBookmark: @escaping (String) -> Void) {
        self.bookmark = bookmark
        self.storeBookmark = storeBookmark
    }

    deinit {
        scoped?.stopAccessingSecurityScopedResource()
    }

    /// Resolves the stored bookmark and holds its scope open for the process's
    /// lifetime. Called once at startup, before anything tries to read.
    ///
    /// A stale bookmark is re-made rather than discarded: the folder has not
    /// moved, and the grant behind it is still good.
    public func restore() {
        guard scoped == nil, !bookmark().isEmpty else { return }
        guard let data = Data(base64Encoded: bookmark()) else {
            Self.log.notice("focus folder: stored bookmark is not readable — ignoring it")
            return
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            Self.log.notice("focus folder: bookmark did not resolve — the folder will be asked for again")
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            Self.log.notice("focus folder: scope refused for \(url.path, privacy: .public)")
            return
        }
        scoped = url
        if stale { remember(url) }
        Self.log.notice("focus folder: access restored")
    }

    /// Records the folder the user just picked. The bookmark is what survives a
    /// reboot; the grant that comes with the pick is what makes it work today.
    public func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            Self.log.notice("focus folder: could not make a bookmark for \(url.path, privacy: .public)")
            return
        }
        storeBookmark(data.base64EncodedString())
        if scoped == nil, url.startAccessingSecurityScopedResource() {
            scoped = url
        }
        Self.log.notice("focus folder: access granted by the user")
    }

    /// Forgets the folder. The TCC grant behind it is the system's to keep or
    /// drop; this only stops Ledge acting as though it has one.
    public func forget() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        storeBookmark("")
    }

    /// Whether the database can actually be read right now.
    ///
    /// Asked of the filesystem rather than of the bookmark: Full Disk Access
    /// granted for unrelated reasons answers yes here too, and a grant that has
    /// been withdrawn answers no however good the bookmark looks.
    public var isReadable: Bool {
        let file = Self.databaseFolder.appendingPathComponent("ModeConfigurations.json")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1)) != nil
    }
}
