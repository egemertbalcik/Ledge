import CoreAudio
import CoreMediaIO
import Foundation
import LedgeAudioListen
import os

/// The C token. Unchecked because a raw pointer carries no isolation of its
/// own; what makes it safe is that exactly one holder ever has it.
struct ListenerToken: @unchecked Sendable, Equatable {
    let raw: OpaquePointer
}

enum ListenerTree: Sendable {
    case audio, camera
}

func removeListenerToken(_ token: ListenerToken, tree: ListenerTree) -> OSStatus {
    switch tree {
    case .audio: ledge_audio_listen_remove(token.raw)
    case .camera: ledge_cmio_listen_remove(token.raw)
    }
}

func abandonListenerToken(_ token: ListenerToken, tree: ListenerTree) {
    switch tree {
    case .audio: ledge_audio_listen_abandon(token.raw)
    case .camera: ledge_cmio_listen_abandon(token.raw)
    }
}

/// Takes a registration off, and keeps trying, for as long as that takes.
///
/// It is deliberately **not** owned by the `AudioListener` that started it. The
/// wrapper can be released the instant after `cancel()` — that is the ordinary
/// case, a listener dropped from an array — and a retry that captured the
/// wrapper weakly would find it gone and give up, leaving the registration
/// installed. That is the same leak this whole file exists to prevent, arriving
/// by a different door.
///
/// So the cleanup owns itself until it is finished. One of these exists per
/// registration being removed, it holds the exact token, and it lets go only
/// when CoreAudio has accepted the removal, the object is known to have gone,
/// or the budget is spent.
final class ListenerCleanup: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "audio")

    /// Attempts before a registration is treated as terminally stuck. Bounded
    /// on purpose: an unbounded retry is a second runaway.
    static let maximumAttempts = 4

    private let token: ListenerToken
    private let tree: ListenerTree
    private let queue: DispatchQueue
    private let describe: String
    private var attempts = 0
    /// How the removal is actually performed. Substituted in tests so the
    /// retry-ownership property — that cleanup outlives the wrapper that
    /// started it — can be exercised without a HAL that fails on demand.
    private let performRemoval: @Sendable (ListenerToken, ListenerTree) -> OSStatus
    private let performAbandon: @Sendable (ListenerToken, ListenerTree) -> Void
    /// How long to wait before attempt `n`. A quarter-second step in the app,
    /// because a HAL that just refused is unlikely to change its mind within a
    /// frame; near-zero in tests, which should not spend real seconds asleep.
    private let backoff: @Sendable (Int) -> TimeInterval

    /// Holds itself alive across the retries. Cleared when finished, which is
    /// what lets the object go.
    private var keepAlive: ListenerCleanup?

    init(
        token: ListenerToken,
        tree: ListenerTree,
        queue: DispatchQueue,
        describe: String,
        remove: @escaping @Sendable (ListenerToken, ListenerTree) -> OSStatus = removeListenerToken,
        abandon: @escaping @Sendable (ListenerToken, ListenerTree) -> Void = abandonListenerToken,
        backoff: @escaping @Sendable (Int) -> TimeInterval = { Double($0) * 0.25 }
    ) {
        self.token = token
        self.tree = tree
        self.queue = queue
        self.describe = describe
        self.performRemoval = remove
        self.performAbandon = abandon
        self.backoff = backoff
    }

    /// Starts the removal. Returns immediately; the work happens on the
    /// registration's own queue, so a retry cannot race a callback in flight.
    func begin() {
        keepAlive = self
        queue.async { [self] in attempt() }
    }

    private func attempt() {
        attempts += 1
        let status = performRemoval(token, tree)

        if status == noErr {
            finish()
            return
        }

        // A device or process that has gone is not a failure to retry: nothing
        // will ever match it again, and the storage is ours to reclaim.
        if status == kAudioHardwareBadObjectError {
            performAbandon(token, tree)
            Self.log.debug("listener's object had already gone — \(self.describe, privacy: .public)")
            finish()
            return
        }

        guard attempts >= Self.maximumAttempts else {
            let delay = backoff(attempts)
            Self.log.notice("""
                retrying listener removal — \(self.describe, privacy: .public) \
                status \(status, privacy: .public) attempt \(self.attempts, privacy: .public)
                """)
            queue.asyncAfter(deadline: .now() + delay) { [self] in attempt() }
            return
        }

        // Terminal. The registration is, as far as anything here can tell,
        // still installed: CoreAudio holds the block and the queue until a
        // matching removal, and ours has stopped matching. Freeing the token
        // now would throw away the only identity that could ever remove it, so
        // it is quarantined instead — and the quarantine is what tells the
        // watchers to stop making replacements.
        ListenerQuarantine.shared.hold(token, tree: tree, describe: describe, abandon: performAbandon)
        finish()
    }

    private func finish() {
        keepAlive = nil
    }
}

/// Registrations that could not be removed, kept rather than freed.
///
/// Two jobs. It preserves the token — the only identity CoreAudio would match —
/// in case a later attempt can succeed. And it is a signal: a watcher that sees
/// the quarantine filling is a watcher whose replacements are accumulating
/// inside CoreAudio, and it should stop making them rather than repeat the
/// original failure in slow motion.
final class ListenerQuarantine: @unchecked Sendable {

    private static let log = Logger(subsystem: "com.egemert.ledge", category: "audio")

    static let shared = ListenerQuarantine()

    /// Past this many stuck registrations, a watcher should stop replacing
    /// them. Small: more than a couple means something is systematically wrong,
    /// and carrying on is how a leak becomes a hang.
    static let replacementBudget = 4

    private struct Entry {
        let token: ListenerToken
        let tree: ListenerTree
        /// How to free this one. Held with the entry so a token that never came
        /// from the real C shim is never handed to it.
        let abandon: @Sendable (ListenerToken, ListenerTree) -> Void
    }

    private struct State {
        var entries: [Entry] = []
        /// Tokens dropped because even the quarantine has a ceiling.
        var released = 0
    }

    /// The quarantine itself is bounded: an unbounded list of tokens nobody
    /// will free is its own leak.
    private static let ceiling = 64

    private let state = OSAllocatedUnfairLock(initialState: State())

    func hold(
        _ token: ListenerToken,
        tree: ListenerTree,
        describe: String,
        abandon: @escaping @Sendable (ListenerToken, ListenerTree) -> Void = abandonListenerToken
    ) {
        let overflowed = state.withLock { s -> Bool in
            guard s.entries.count < Self.ceiling else {
                s.released += 1
                return true
            }
            s.entries.append(Entry(token: token, tree: tree, abandon: abandon))
            return false
        }
        if overflowed {
            // Storage reclaimed; the native registration stays. Said plainly
            // rather than hidden, because at this point the process is in a
            // state worth restarting.
            abandon(token, tree)
            Self.log.error("""
                listener quarantine is full — freeing the token for \
                \(describe, privacy: .public) and leaving its registration installed
                """)
        } else {
            Self.log.error("""
                could not remove a listener after \(ListenerCleanup.maximumAttempts, privacy: .public) \
                attempts — \(describe, privacy: .public); it stays registered
                """)
        }
    }

    var count: Int { state.withLock { $0.entries.count } }
    var releasedCount: Int { state.withLock { $0.released } }

    /// Whether a watcher should still be making replacement registrations.
    var acceptsReplacements: Bool { count < Self.replacementBudget }

    /// Tests only: empties the quarantine so one case cannot colour the next.
    func resetForTesting() {
        let entries = state.withLock { s -> [Entry] in
            defer { s.entries = []; s.released = 0 }
            return s.entries
        }
        for entry in entries { entry.abandon(entry.token, entry.tree) }
    }
}
