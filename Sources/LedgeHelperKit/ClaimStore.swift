import Foundation

/// What one Ledge daemon has changed, or is about to change, on this Mac.
///
/// Written *before* the privileged change and cleared only *after* a restore
/// the daemon has read back. A crash in between leaves a claim for something
/// that may never have happened, which the next start sorts out in one read;
/// the other order would leave a Mac that cannot sleep and nothing on disk
/// saying why.
/// One run's outstanding privileged write against a record.
public struct WriterMark: Equatable, Sendable, Codable {
    /// The run that raised it — one lifetime of one helper, not the label.
    public var run: String
    /// The boot that run was born in.
    ///
    /// Deliberately the writer's own, not the record's. A record's session
    /// boot says when the obligation was made; a helper in this boot can act
    /// on an obligation from the last one, and only this field can say that
    /// its writer could not have died at the reboot.
    public var boot: String

    public init(run: String, boot: String) {
        self.run = run
        self.boot = boot
    }
}

public struct HelperClaim: Equatable, Sendable, Codable {

    /// The launchd label of the daemon that wrote it. The debug and release
    /// builds share this store because they share the setting it describes.
    public var holderLabel: String
    /// `kern.bootsessionuuid`. A claim from an earlier boot is always
    /// restored, whoever wrote it: nothing in this boot is relying on it.
    public var boot: String
    public var sessionID: String
    public var generation: Int
    /// Wall clock, fixed at the session's first hold. Nil means the hold runs
    /// until it is released or the lease lapses.
    public var deadline: Date?
    /// Monotonic, and the whole safety story. A daemon that stops hearing from
    /// its app stops holding, and the *other* daemon can see that too, because
    /// continuous time is system-wide within a boot.
    ///
    /// Zero means the holder has gone and only the cleanup is outstanding.
    public var leaseExpiryContinuousNs: UInt64
    /// Ledge wrote, or was about to write, `disablesleep 1`.
    public var sleepDisabledClaimed: Bool
    /// What Low Power Mode read as before Ledge touched it (2b). Nil means
    /// Ledge has not claimed it. Kept in the record now so a 2b daemon's claim
    /// is still legible to this one.
    public var lowPowerPrior: Int?
    /// Every run that has a privileged write outstanding against this
    /// record, and the boot each of those runs was born in.
    ///
    /// A `pmset` operation can be answered `.failed` while its child is still
    /// alive with the write ahead of it. The helper that started it keeps its
    /// own account of that in memory — and in-memory is exactly the wrong
    /// place, because the other build's helper reads this file, sees a lapsed
    /// claim, and has nothing to tell it that somebody's write has not landed.
    ///
    /// A *set*, because more than one run can be acting on one obligation: a
    /// helper that applied a setting and a peer that is putting it back can
    /// both have children in flight against the same record. One owner meant
    /// the second writer got in without adding itself, and then the first one
    /// retired what it thought was the only contribution — taking the record
    /// with it while the second child was still alive.
    ///
    /// Each mark carries the *writer's* birth boot, not this record's session
    /// boot. They are no longer the same thing once a current-boot helper
    /// starts acting on an old obligation, and reading the record's boot as
    /// the writer's is how a live writer came to be reclaimed as one that
    /// could not possibly still exist.
    ///
    /// While this is non-empty the record is nobody's to delete. Writing the
    /// setting back is still allowed; it is the *evidence* that has to
    /// survive.
    public var writers: [WriterMark]?

    public init(
        holderLabel: String,
        boot: String,
        sessionID: String,
        generation: Int,
        deadline: Date?,
        leaseExpiryContinuousNs: UInt64,
        sleepDisabledClaimed: Bool,
        lowPowerPrior: Int? = nil,
        writers: [WriterMark]? = nil
    ) {
        self.holderLabel = holderLabel
        self.boot = boot
        self.sessionID = sessionID
        self.generation = generation
        self.deadline = deadline
        self.leaseExpiryContinuousNs = leaseExpiryContinuousNs
        self.sleepDisabledClaimed = sleepDisabledClaimed
        self.lowPowerPrior = lowPowerPrior
        self.writers = writers
    }

    /// Whether somebody is still holding this, as opposed to leaving it behind
    /// for cleanup.
    ///
    /// A claim from another boot is never live: continuous time restarts at
    /// boot, so its expiry is not a number this boot can compare against.
    public func isLive(inBoot boot: String, atContinuousNanoseconds now: UInt64) -> Bool {
        self.boot == boot && now < leaseExpiryContinuousNs
    }

    /// Whether anything privileged has to be undone before this claim can go.
    public var needsRestore: Bool { sleepDisabledClaimed || lowPowerPrior != nil }

    /// Whether this record may be taken off the disk.
    ///
    /// Not while anybody has a write against it they cannot account for. A
    /// record kept too long costs one pointless restore; a record deleted
    /// while somebody's write is still coming costs the only account of what
    /// Ledge changed.
    public var mayBeRemoved: Bool { (writers ?? []).isEmpty }
}

/// Every claim on this Mac, by the daemon that made it.
///
/// Keyed by label because a daemon holds at most one claim: it serves one app,
/// and that app runs at most one Keep Awake session. Two entries means the two
/// builds are both installed, which is a thing that happens on the developer's
/// own Mac and must not end with either of them undoing the other's work.
public struct ClaimLedger: Equatable, Sendable, Codable {

    public static let currentVersion = 1

    public var v: Int
    public var claims: [String: HelperClaim]

    public init(v: Int = ClaimLedger.currentVersion, claims: [String: HelperClaim] = [:]) {
        self.v = v
        self.claims = claims
    }

    public static let empty = ClaimLedger()
}

/// The store, and the lock that makes a privileged change one thing rather
/// than three.
///
/// The lock does not protect the file. It protects the *transaction*: decide,
/// journal, spawn `pmset`, reap it, read back, journal the result. A lock held
/// only across the writes would let the other daemon read the store between
/// our journal and our `pmset`, see a claim for a change that has not landed,
/// and act on it.
///
/// The real implementation holds `flock(LOCK_EX)` on a lock file beside the
/// store, and the `pmset` child does **not** inherit that descriptor. A lock
/// lives for as long as any descriptor on the open file it was taken through,
/// so a child that inherited one would hold the lock for as long as it lived —
/// and a daemon that has been killed cannot kill its own orphan, which is a
/// wedge with no way out of it. The window that opens instead, where a daemon
/// dies mid-write and the lock is free while its orphan may still be running,
/// is covered by the claim: it is journalled before the child starts, its
/// lease outlasts any child by a wide margin, and the other daemon leaves a
/// live claim alone.
///
/// Nothing here blocks: a busy lock is an answer, not a wait.
public protocol ClaimStore: AnyObject {
    /// Never blocks. False means somebody else is mid-transaction.
    func tryLock() -> Bool
    func unlock()
    /// Called only under the lock. Throws when the file exists and cannot be
    /// understood; a missing file is an empty ledger, not an error.
    func load() throws -> ClaimLedger
    /// Called only under the lock. Durable before it returns: a claim that
    /// does not survive a power cut is not a claim.
    func save(_ ledger: ClaimLedger) throws
    /// Keeps an unreadable store instead of deleting it. Ownership of whatever
    /// it described is now unknown, and destroying the only evidence of that
    /// is not the daemon's call to make.
    func moveAside() throws
}
