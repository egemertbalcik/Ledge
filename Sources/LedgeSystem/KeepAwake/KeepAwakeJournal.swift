import Foundation
import LedgeCore
import OSLog

/// What is written down about a Keep Awake session.
///
/// A session is a system-wide power change that outlives the window it was
/// started from, so it has to be recorded somewhere a relaunch can find it.
/// The record is written *before* the thing it describes happens — the
/// assertion is only taken once the disk has agreed to remember it — so a
/// crash in between leaves a record of something that did not happen, which is
/// recoverable, rather than a hold nobody knows about, which is not.
public struct KeepAwakeRecord: Equatable, Sendable, Codable {

    public static let currentVersion = 1

    public enum State: String, Equatable, Sendable, Codable {
        case running
        case ended
    }

    public var v: Int
    public var id: String
    public var state: State
    public var startedAt: Date
    public var deadline: Date
    public var total: TimeInterval
    public var boot: String
    public var lidHoldRequested: Bool
    public var endReason: KeepAwakeEndReason?
    public var endedAt: Date?
    /// The session ended while no notch panel was on screen, so its summary
    /// has not been shown to anybody yet.
    public var summaryPending: Bool

    public init(
        v: Int = KeepAwakeRecord.currentVersion,
        id: String,
        state: State,
        startedAt: Date,
        deadline: Date,
        total: TimeInterval,
        boot: String,
        lidHoldRequested: Bool = false,
        endReason: KeepAwakeEndReason? = nil,
        endedAt: Date? = nil,
        summaryPending: Bool = false
    ) {
        self.v = v
        self.id = id
        self.state = state
        self.startedAt = startedAt
        self.deadline = deadline
        self.total = total
        self.boot = boot
        self.lidHoldRequested = lidHoldRequested
        self.endReason = endReason
        self.endedAt = endedAt
        self.summaryPending = summaryPending
    }

    public init(running session: KeepAwakeSession) {
        self.init(id: session.id, state: .running, startedAt: session.startedAt,
                  deadline: session.deadline, total: session.total, boot: session.bootID,
                  lidHoldRequested: session.lidHoldRequested)
    }

    public var session: KeepAwakeSession {
        KeepAwakeSession(id: id, startedAt: startedAt, deadline: deadline,
                         total: total, bootID: boot, lidHoldRequested: lidHoldRequested)
    }

    public func ended(_ reason: KeepAwakeEndReason, at date: Date, summaryPending: Bool) -> Self {
        var copy = self
        copy.state = .ended
        copy.endReason = reason
        copy.endedAt = date
        copy.summaryPending = summaryPending
        return copy
    }
}

/// Somewhere to keep the record.
///
/// Behind a protocol because every interesting rule in §6.1.1 is about what
/// happens when the disk says no, and a disk that always says yes cannot test
/// any of them.
public protocol KeepAwakeJournal: Sendable {
    /// Returns nil when there is no record. Throws when there is one that
    /// cannot be understood — the caller moves it aside rather than guessing.
    func read() throws -> KeepAwakeRecord?
    func write(_ record: KeepAwakeRecord) throws
    func clear() throws
    /// Keeps an unreadable file instead of deleting it. Somebody may want to
    /// know what was in it, and Ledge is not entitled to destroy it.
    func moveAside() throws
}

/// The real one: one small JSON file, replaced atomically.
///
/// Atomic replace gives a reader all of the old record or all of the new one,
/// never half of each. It does not survive power loss on its own, and it does
/// not have to: a power cut changes the boot id, and a session never crosses a
/// boot.
public struct FileKeepAwakeJournal: KeepAwakeJournal {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "keep-awake")

    private let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("keep-awake.json", isDirectory: false)
    }

    /// `~/Library/Application Support/Ledge/`, the same place the device
    /// catalogue keeps its own file.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Ledge", isDirectory: true)
    }

    public init() {
        self.init(directory: Self.defaultDirectory())
    }

    public func read() throws -> KeepAwakeRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let record = try JSONDecoder.keepAwake.decode(KeepAwakeRecord.self, from: data)
        // A file from a later version is not something to guess at.
        guard record.v <= KeepAwakeRecord.currentVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }

    public func write(_ record: KeepAwakeRecord) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder.keepAwake.encode(record).write(to: url, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func moveAside() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("keep-awake.json.unreadable-\(stamp)")
        try FileManager.default.moveItem(at: url, to: aside)
        Self.log.notice("keep awake: an unreadable journal was set aside")
    }
}

extension JSONEncoder {
    static var keepAwake: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var keepAwake: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Runs journal work off the main thread, one piece at a time.
///
/// The writes are small, but "small" is a property of the data, not of the
/// disk: an atomic replace on a filesystem that has stopped answering blocks
/// for as long as it likes, and on the main actor that is the whole app frozen
/// — the quit timeout cannot help, because the actor it would need to run on is
/// the one that is stuck. Apple's responsiveness guidance is the same rule:
/// file I/O does not belong on the main thread.
///
/// Serial on purpose. The journal's correctness rests on later records
/// replacing earlier ones, so the order writes reach the disk has to be the
/// order they were asked for.
///
/// One of these covers a journal *file*, not a provider. Switching Keep Awake
/// off and on again builds a new provider, and a provider built per toggle
/// starts counting its revisions at one — so the old provider's last write,
/// still waiting on a slow disk, outranked nothing and replaced the new
/// provider's record with the end of a session nobody was running. Ownership
/// is the part that has to outlive the providers, so it lives here.
public actor KeepAwakeJournalWorker {

    private let journal: any KeepAwakeJournal
    private let owners = OwnerNumbers()
    private let admitted = AdmittedWrites()
    private let observeAdmissions: (@Sendable (String) -> Void)?

    /// - Parameter observeAdmissions: told about every write offered to the
    ///   disk. For a test that needs to know a session has asked a second
    ///   time; keeping that history here instead would mean the app
    ///   remembering every session it ever had, for a caller that does not
    ///   exist outside the tests.
    public init(_ journal: any KeepAwakeJournal,
                observeAdmissions: (@Sendable (String) -> Void)? = nil) {
        self.journal = journal
        self.observeAdmissions = observeAdmissions
    }

    /// Takes the next owner number.
    ///
    /// `nonisolated` because a provider takes one in its initialiser, which
    /// cannot await, and because handing out a number touches nothing the
    /// actor protects — the lock behind it is the whole of its state.
    public nonisolated func claim() -> Int { owners.next() }

    /// Where owner numbers come from.
    private final class OwnerNumbers: @unchecked Sendable {
        private let lock = NSLock()
        private var last = 0
        func next() -> Int {
            lock.withLock {
                last += 1
                return last
            }
        }
    }

    /// Says which sessions may still reach the disk.
    ///
    /// A write is admitted before its caller suspends and resolved when the
    /// caller hears back, so between those two points the session it names
    /// could still become the record. The caller that finishes first is not
    /// the authority on what the disk holds, and this is how it finds out it
    /// is not: whatever is still admitted keeps the note saying it is over.
    ///
    /// Shared by every provider over the journal, because a provider on its
    /// way out can be finishing a write while its replacement has one queued.
    private final class AdmittedWrites: @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [Int: String] = [:]
        private var last = 0
        private var landed = 0

        func admit(_ id: String) -> Int {
            lock.withLock {
                last += 1
                writes[last] = id
                return last
            }
        }

        func noteLanded() { lock.withLock { landed += 1 } }
        var landedCount: Int { lock.withLock { landed } }

        func resolve(_ token: Int) {
            lock.withLock { writes[token] = nil }
        }

        func ids(excluding token: Int) -> [String] {
            lock.withLock { writes.filter { $0.key != token }.map(\.value) }
        }
    }

    /// Takes note that a write is about to be attempted.
    ///
    /// `nonisolated` so a caller can do this *before* it suspends. Admitting
    /// inside the actor would leave the window this exists to cover.
    public nonisolated func admit(_ id: String) -> Int {
        observeAdmissions?(id)
        return admitted.admit(id)
    }

    /// The write has been answered, whether it landed, was refused or failed.
    public nonisolated func resolve(_ token: Int) { admitted.resolve(token) }

    /// The sessions of every other write that has been admitted and not yet
    /// answered — everything that may still become the record on disk.
    public nonisolated func mayStillReachDisk(excluding token: Int) -> [String] {
        admitted.ids(excluding: token)
    }

    /// Every session with a write admitted and not yet answered, this caller's
    /// included. What the room for another session has to be counted against:
    /// each of these may still need a name, and the journal is the only thing
    /// that can see all of them at once.
    public nonisolated func admittedSessionIDs() -> [String] { admitted.ids(excluding: 0) }

    /// How many writes have reached the disk, over every provider.
    ///
    /// Recovery compares this across its read: a read with nothing written
    /// before or after it describes what the disk holds now, and only then may
    /// it be used to decide which names are no longer protecting anything.
    public nonisolated func writesLanded() -> Int { admitted.landedCount }

    public func read() throws -> KeepAwakeRecord? {
        try journal.read()
    }

    /// Reads, and puts the file aside if it is this read that cannot
    /// understand it.
    ///
    /// One trip into the actor, because the two halves must not come apart: a
    /// quarantine decided out here waits its turn like any other call, and the
    /// turn it got could be after a perfectly good record had been written —
    /// so the file moved aside was the new one, and the start that wrote it
    /// was left holding an assertion nothing would ever find.
    public func readOrQuarantine() throws -> JournalRead {
        do {
            return JournalRead(record: try journal.read(), writtenBy: currentOwner,
                               landed: admitted.landedCount)
        } catch {
            try? journal.moveAside()
            throw error
        }
    }

    /// What the file holds, and who put it there.
    ///
    /// The owner matters because a provider on its way out may be reading long
    /// after its replacement has written: serial does not mean first-come, and
    /// Swift makes no promise about the order an actor takes its callers in.
    /// A record written by a newer owner is not the older one's to speak for.
    public struct JournalRead: Sendable {
        public let record: KeepAwakeRecord?
        /// Which owner last wrote this file, or 0 if nobody has in this
        /// process — which is what a record left by an earlier launch looks
        /// like.
        public let writtenBy: Int
        /// How many writes had reached the disk when this was read. What makes
        /// it possible to say whether the record is still the one somebody was
        /// talking about a moment ago: a write *attempted* since then proves
        /// nothing, a write that landed proves the record changed.
        public let landed: Int
    }

    /// Writes a record, unless something newer has already been written.
    ///
    /// The ordering decision lives here, at the point where the writes are
    /// actually serialised, and nowhere else. Deciding it on the caller's side
    /// — "is my revision newer than the last one persisted?" — is a read, an
    /// await, and then a write, and anything can happen in the middle: a retry
    /// that checked while it was still the newest arrives behind a newer start
    /// and overwrites it. Here the check and the write cannot be separated.
    ///
    /// An owner that has written anything retires every owner before it. Until
    /// then an older one may still write, which is what lets a provider on its
    /// way out take back a record nobody has replaced.
    ///
    /// - Parameter owner: the number its writer took from `claim()`.
    /// - Returns: whether this write was the one that landed. `false` means a
    ///   newer record already has the file, which is a success for the caller
    ///   — what it wanted on disk is superseded, not lost.
    @discardableResult
    public func write(_ record: KeepAwakeRecord, revision: Int, owner: Int) throws -> Bool {
        guard owner >= currentOwner else { return false }
        // A new owner's revisions start again at one, so the count of what the
        // previous owner wrote must not outrank them.
        let floor = owner > currentOwner ? 0 : lastWrittenRevision
        guard revision > floor else { return false }

        try journal.write(record)
        admitted.noteLanded()

        // Committed together, and only once the disk has taken it. Retiring
        // the previous owner before the write succeeded left its record on the
        // disk with its owner no longer allowed to take it back — the one
        // state nothing in the app can correct. Nothing can come between the
        // write and this: the actor is the only way in, and there is no
        // suspension point between them.
        currentOwner = owner
        lastWrittenRevision = revision
        return true
    }

    private var lastWrittenRevision = 0
    private var currentOwner = 0

    public func clear() throws {
        try journal.clear()
    }

    public func moveAside() throws {
        try journal.moveAside()
    }
}

/// A note that a session ended, kept somewhere other than the journal.
///
/// It exists for one case: the journal refused the write that records an end.
/// Everything is released anyway, but a relaunch reading the old `running`
/// record would otherwise start the session again. The tombstone is written
/// through a different mechanism entirely — preferences, which is a different
/// daemon and a different file — so a disk problem that stops one has a fair
/// chance of not stopping the other.
public protocol KeepAwakeTombstone: Sendable {
    /// The sessions known to be over, whatever the journal still says.
    ///
    /// More than one, because for the length of a write there are two records
    /// the journal might be holding — the one that was there and the one on
    /// its way — and a cancellation arriving in that window cannot tell which.
    /// Naming only the newer one threw away the protection the older one was
    /// relying on; naming only the older one would lose the newer. Oldest
    /// first.
    func endedSessionIDs() -> [String]
    func set(_ ids: [String]) throws
}

/// The list is full, and nothing on it has been shown to be unnecessary.
public struct KeepAwakeTombstoneFull: Error {}

/// How many names the list keeps at once.
///
/// Reached only when the journal has been refusing writes for as long as it
/// takes to start this many sessions. The room is claimed before a session
/// starts rather than taken from the list afterwards.
public enum KeepAwakeTombstoneCapacity {
    public static let limit = 8
}

extension KeepAwakeTombstone {

    /// How many names are kept at once.
    public static var tombstoneLimit: Int { KeepAwakeTombstoneCapacity.limit }

    /// Adds a session to the list, keeping what is already there.
    ///
    /// Nothing is evicted to make room. Age says nothing about which name
    /// still matters: the oldest is as likely as any to be the one session the
    /// journal is still holding, and dropping that one is how a session that
    /// was explicitly ended comes back. A full list refuses instead, and the
    /// refusal cannot be reached while starts take their room in advance.
    public func add(_ id: String) throws {
        var ids = endedSessionIDs()
        guard !ids.contains(id) else { return }
        guard ids.count < Self.tombstoneLimit else { throw KeepAwakeTombstoneFull() }
        ids.append(id)
        try set(ids)
    }

    /// Drops every name but the given ones.
    public func keepOnly(_ ids: [String]) throws {
        let kept = endedSessionIDs().filter(ids.contains)
        guard kept != endedSessionIDs() else { return }
        try set(kept)
    }

    /// Whether another session may be started.
    ///
    /// Every session may come to need a name of its own, so the room for it is
    /// taken before the session is, and a session with nowhere to leave its
    /// name does not start at all. Refusing to start is recoverable — one
    /// write landing clears the list back to at most one name. Starting and
    /// then losing the evidence is not.
    public var hasRoomForAnotherSession: Bool {
        endedSessionIDs().count < Self.tombstoneLimit
    }
}

public struct DefaultsKeepAwakeTombstone: KeepAwakeTombstone {

    private let key = "keepAwake.endedSessionIDs"
    /// What the list was called when it was one name. Read on the way in, so a
    /// Mac that quit mid-session under the old build still knows not to resume
    /// what it had already ended.
    private let legacyKey = "keepAwake.endedSessionID"
    /// `UserDefaults` is thread-safe but not `Sendable`, and this type has to
    /// cross actors to be written from the provider. The suite name travels
    /// instead of the object.
    private let suite: String?

    public init(suite: String? = nil) {
        self.suite = suite
    }

    private var defaults: UserDefaults {
        suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public func endedSessionIDs() -> [String] {
        if let ids = defaults.stringArray(forKey: key) { return ids }
        return defaults.string(forKey: legacyKey).map { [$0] } ?? []
    }

    public func set(_ ids: [String]) throws {
        // The replacement first. Removing the old key before writing the new
        // one leaves a moment with neither, and a Mac that stops in it has
        // lost the only thing saying a session on disk is over.
        if ids.isEmpty {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: legacyKey)
        } else {
            defaults.set(ids, forKey: key)
            defaults.removeObject(forKey: legacyKey)
        }
    }
}
