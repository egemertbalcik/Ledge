import Foundation
import LedgeHelperKit
import OSLog

/// The claim store on disk, and the lock that makes a privileged change one
/// thing rather than three.
///
/// One store for both builds of Ledge, at a fixed path, because the setting it
/// describes is machine-wide: a debug daemon and a release daemon that kept
/// separate books would each be certain nobody else had touched SleepDisabled.
///
/// The lock is held across the whole transaction — decide, journal, run
/// `pmset`, reap it, read back, journal the result — not merely across the
/// writes. A lock that only covered file access would let the other daemon read
/// the store in the gap between our journal and our `pmset`, see a claim for a
/// change that had not landed yet, and act on it.
final class FileClaimStore: ClaimStore {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake-helper")

    /// Where the real one lives. Used by `main` and by nothing else: every
    /// other caller has to say where it wants its store, so no test can reach
    /// this path by forgetting an argument.
    static let systemDirectory = URL(fileURLWithPath: "/Library/Application Support/com.egemert.ledge.keepawake",
                                     isDirectory: true)

    private let directory: URL
    private let claims: URL
    private let lockFile: URL
    /// Who the store must belong to. Root in the daemon; the test user in a
    /// test, which is the only reason it is a parameter — the check itself is
    /// the point, and a check that could not be exercised would not be one.
    private let owner: uid_t

    private var lockDescriptor: Int32?

    init(directory: URL, owner: uid_t = 0) {
        self.directory = directory
        self.claims = directory.appendingPathComponent("claims.json", isDirectory: false)
        self.lockFile = directory.appendingPathComponent("claims.lock", isDirectory: false)
        self.owner = owner
    }

    enum Trouble: Error, Equatable {
        /// The file is there and is not ours, or anyone but its owner can
        /// write to it. Ownership of whatever it describes is unknown.
        case notOurs(String)
        case unreadable(String)
        case couldNotWrite(String)
        /// What came back off the disk is not what was written.
        case readbackDisagreed
    }

    // MARK: - The lock

    func tryLock() -> Bool {
        if lockDescriptor != nil { return true }
        guard prepareDirectory() else { return false }

        let descriptor = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            Self.log.error("keep awake helper: the lock file would not open (\(errno))")
            return false
        }
        guard isSafe(descriptor) else {
            // Somebody else's file in our place. Acting on it would mean
            // taking a lock anybody could have taken too.
            close(descriptor)
            Self.log.error("keep awake helper: the lock file is not ours; doing nothing")
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }

    func unlock() {
        guard let descriptor = lockDescriptor else { return }
        lockDescriptor = nil
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    // MARK: - The file

    func load() throws -> ClaimLedger {
        guard FileManager.default.fileExists(atPath: claims.path) else { return .empty }
        let descriptor = open(claims.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Trouble.unreadable("open failed (\(errno))") }
        defer { close(descriptor) }
        guard isSafe(descriptor) else { throw Trouble.notOurs(claims.path) }

        let data: Data
        do { data = try Data(contentsOf: claims) } catch {
            throw Trouble.unreadable("\(error)")
        }
        guard !data.isEmpty else { return .empty }
        let ledger: ClaimLedger
        do { ledger = try JSONDecoder.claims.decode(ClaimLedger.self, from: data) } catch {
            throw Trouble.unreadable("\(error)")
        }
        // A file from a later version is not something to guess at: it may
        // describe a claim this build does not know how to put back.
        guard ledger.v <= ClaimLedger.currentVersion else {
            throw Trouble.unreadable("version \(ledger.v)")
        }
        return ledger
    }

    func save(_ ledger: ClaimLedger) throws {
        guard prepareDirectory() else { throw Trouble.couldNotWrite(directory.path) }
        let data = try JSONEncoder.claims.encode(ledger)
        let temporary = directory.appendingPathComponent("claims.json.writing", isDirectory: false)

        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Trouble.couldNotWrite("open failed (\(errno))") }

        var written = 0
        var failure: Trouble?
        data.withUnsafeBytes { bytes in
            while written < bytes.count {
                let count = write(descriptor, bytes.baseAddress! + written, bytes.count - written)
                guard count > 0 else {
                    failure = .couldNotWrite("write failed (\(errno))")
                    return
                }
                written += count
            }
        }
        // `F_FULLFSYNC` and not `fsync`, because fsync is allowed to leave the
        // bytes in the drive's own cache. A claim that does not survive a power
        // cut is not a claim: the Mac comes back with sleep disabled and
        // nothing on disk saying who did it.
        if failure == nil, fcntl(descriptor, F_FULLFSYNC) != 0 {
            failure = .couldNotWrite("fullfsync failed (\(errno))")
        }
        close(descriptor)
        if let failure {
            unlink(temporary.path)
            throw failure
        }

        guard rename(temporary.path, claims.path) == 0 else {
            unlink(temporary.path)
            throw Trouble.couldNotWrite("rename failed (\(errno))")
        }
        // The rename itself has to be durable too, or a power cut can leave the
        // directory entry pointing at the old file with the new one fsynced.
        let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        if directoryDescriptor >= 0 {
            _ = fcntl(directoryDescriptor, F_FULLFSYNC)
            close(directoryDescriptor)
        }

        // Read it back. Comparing bytes rather than decoded values on purpose:
        // the question is whether what is on the disk is what was meant to be,
        // and a comparison that went through the decoder would forgive a file
        // that had lost a field the decoder has a default for.
        guard let readBack = try? Data(contentsOf: claims), readBack == data else {
            throw Trouble.readbackDisagreed
        }
    }

    func moveAside() throws {
        guard FileManager.default.fileExists(atPath: claims.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let aside = directory.appendingPathComponent("claims.json.unreadable-\(stamp)",
                                                     isDirectory: false)
        guard rename(claims.path, aside.path) == 0 else {
            throw Trouble.couldNotWrite("could not set the store aside (\(errno))")
        }
        Self.log.notice("keep awake helper: an unreadable claim store was set aside")
    }

    // MARK: - Ownership

    /// Makes the directory if it is missing, and refuses to use one that
    /// belongs to somebody else.
    private func prepareDirectory() -> Bool {
        var status = stat()
        if stat(directory.path, &status) != 0 {
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { return false }
            guard stat(directory.path, &status) == 0 else { return false }
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { return false }
        return isSafe(status)
    }

    private func isSafe(_ descriptor: Int32) -> Bool {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return false }
        return isSafe(status)
    }

    /// Ours, and not writable by anybody else.
    ///
    /// Both halves matter. A store somebody else owns can be replaced under us
    /// between two of our own reads; one that is group- or world-writable can
    /// be edited by a process that could not otherwise disable sleep at all.
    private func isSafe(_ status: stat) -> Bool {
        status.st_uid == owner && (status.st_mode & 0o077) == 0
    }
}

extension JSONEncoder {
    static var claims: JSONEncoder {
        let encoder = JSONEncoder()
        // Dates here are read by people looking at a root-owned file to find
        // out what happened. Nothing compares them to a date held in memory,
        // so second precision is enough and legibility is worth more.
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var claims: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
