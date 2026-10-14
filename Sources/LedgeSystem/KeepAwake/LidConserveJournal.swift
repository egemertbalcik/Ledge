import Foundation
import LedgeCore
import OSLog

/// Somewhere to keep the record of what the lid close changed.
///
/// Behind a protocol for the same reason `KeepAwakeJournal` is: every rule
/// worth having here is about the disk saying no. A journal that always
/// succeeds cannot test the one rule that matters — that a refused write means
/// nothing is darkened at all.
/// Why a record could not be read.
///
/// The two are not the same and treating them alike is how the only account of
/// a user's brightness was thrown away: a file that cannot be *parsed* is
/// rubbish and can be set aside, while a file that cannot be *reached* is
/// almost certainly still exactly what it was a moment ago. Quarantining the
/// second one, or carrying on as though the journal were empty, replaces a
/// real prior with whatever the conserved Mac happens to read now.
public enum LidJournalTrouble: Error, Equatable, Sendable {
    /// There is a file and it is not a record this build understands.
    case unreadable
    /// The file could not be read at all — a disk that is not answering, a
    /// permission that has gone. Says nothing about the contents.
    case unavailable
}

public protocol LidConserveJournal: Sendable {
    /// Nil when there is no record. Throws when there is one that cannot be
    /// understood; the caller sets it aside rather than guessing at it.
    func read() throws -> LidConserveRecord?
    func write(_ record: LidConserveRecord) throws
    func clear() throws
    /// Keeps an unreadable file rather than deleting it. It is the only
    /// account of what may still be dark on this Mac, and destroying that is
    /// not Ledge's call.
    func moveAside() throws
}

/// The real one: a small JSON file beside the Keep Awake journal, replaced
/// atomically.
///
/// Its own file, not a field on `KeepAwakeRecord`. The two have different
/// lifetimes — a session can run for hours with the lid up and nothing
/// conserved, and a conserve outlives the session that caused it for exactly
/// as long as the restore takes — and a crash between them must leave each
/// legible on its own.
public struct FileLidConserveJournal: LidConserveJournal {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "lid")

    private let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("lid-conserve.json", isDirectory: false)
    }

    public init() {
        self.init(directory: FileKeepAwakeJournal.defaultDirectory())
    }

    public func read() throws -> LidConserveRecord? {
        // No existence check. `fileExists` answers false for a file whose
        // *parent directory* cannot be searched, and "absent" is the one
        // answer that authorises writing a new journal over the top — so a
        // permission problem read as absence replaced somebody's brightness
        // prior with the zero of an already-darkened Mac.
        //
        // Read, then classify the failure. Only an affirmative not-found is
        // absence; everything else is unresolved and refuses writes.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard Self.isAbsent(error) else { throw LidJournalTrouble.unavailable }
            return nil
        }
        do {
            let record = try JSONDecoder.keepAwake.decode(LidConserveRecord.self, from: data)
            // A file from a later version describes changes this build does
            // not know how to undo. Guessing at it is how a newer Ledge's
            // claim gets half-restored by an older one.
            guard record.v <= LidConserveRecord.currentVersion else {
                throw LidJournalTrouble.unreadable
            }
            return record
        } catch {
            throw LidJournalTrouble.unreadable
        }
    }

    public func write(_ record: LidConserveRecord) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder.keepAwake.encode(record).write(to: url, options: .atomic)
    }

    public func clear() throws {
        // Same rule. A removal that fails because the path cannot be reached
        // is not a successful clear, and reporting one would have the
        // conserver believe this Mac owes nothing.
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            guard Self.isAbsent(error) else { throw error }
        }
    }

    public func moveAside() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("lid-conserve.json.unreadable-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
        } catch {
            // Nothing there is nothing to set aside. Anything else is a move
            // that did not happen, and the caller has to know.
            guard Self.isAbsent(error) else { throw error }
            return
        }
        Self.log.notice("lid: an unreadable conserve record was set aside")
    }

    /// Whether a failure means the file is genuinely not there.
    ///
    /// The only answer that may authorise writing a fresh journal. A denied
    /// parent directory, a disk that has stopped answering and a path that
    /// cannot be resolved all look like absence to `fileExists` and are
    /// nothing of the kind.
    static func isAbsent(_ error: Error) -> Bool {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           cocoa.code == CocoaError.fileNoSuchFile.rawValue
            || cocoa.code == CocoaError.fileReadNoSuchFile.rawValue {
            return true
        }
        if cocoa.domain == NSPOSIXErrorDomain, cocoa.code == Int(ENOENT) { return true }
        // Foundation wraps the underlying POSIX error here on some paths.
        if let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isAbsent(underlying)
        }
        return false
    }
}
